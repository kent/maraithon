import Foundation

/// Thin Phoenix Channels client over `URLSessionWebSocketTask`.
///
/// Connects to the server-side `MaraithonWeb.CompanionSocket` mounted at
/// `/companion/socket/websocket`, joins the device's topic
/// (`companion:device:<deviceId>`) with the bearer token in the join
/// params, and exposes an async `push(event:payload:)` that returns the
/// server's reply.
///
/// Library choice: we deliberately do NOT pull in SwiftPhoenixClient.
/// The wire protocol we need is small — heartbeat, join, push with
/// per-message refs — and `URLSessionWebSocketTask` covers it without
/// adding a SwiftPM dependency that would also need to live in
/// `project.yml`. The trade-off: more code in this file, but no new
/// framework to embed and no risk of clashing with the strict Swift 6
/// concurrency mode the project compiles under.
///
/// Fallback behaviour: callers (the `*Ingest` helpers) check
/// `isConnected` before each push. If we drop mid-batch the next push
/// fails fast (the actor surfaces `RealtimeChannelError.notConnected`)
/// and the caller falls back to HTTP. Cursor advancement is unchanged —
/// the source only advances after a successful 2xx response from
/// whichever transport delivered the batch.
actor RealtimeChannel {
    /// Lifecycle status the UI can observe via `statusStream`. The
    /// `disconnected` variant carries an optional reason for log /
    /// diagnostics surfaces.
    enum Status: Equatable, Sendable {
        case disconnected(reason: String?)
        case connecting
        case connected
    }

    /// Reply shape mirrored from the server's
    /// `Maraithon.LocalX.ingest_batch/3` result map. `filtered` is only
    /// populated for `ingest:browser_history`; other batches leave it
    /// at zero on the wire.
    struct Outcome: Sendable, Equatable {
        let accepted: Int
        let duplicate: Int
        let invalid: Int
        let filtered: Int
    }

    enum RealtimeChannelError: Error, Equatable, Sendable {
        case notConnected
        case joinFailed(reason: String)
        case serverError(reason: String)
        case decodeFailure
        case closed
        case pushTimeout
        case sendFailed
    }

    /// Pluggable WebSocket factory so tests can inject a mock without
    /// going through `URLSession`. The default uses `URLSession.shared`.
    typealias SocketFactory = @Sendable (URL) -> any RealtimeWebSocket

    private let baseURL: URL
    private let deviceId: UUID
    private let tokenProvider: MaraithonClient.TokenProvider
    private let socketFactory: SocketFactory
    private let heartbeatInterval: Duration
    private let log: ((String, [String: String]) -> Void)?

    private var socket: (any RealtimeWebSocket)?
    private var status: Status = .disconnected(reason: nil)
    private var joinRef: Int = 0
    private var msgRef: Int = 0
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var statusContinuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private var topic: String { "companion:device:\(deviceId.uuidString.lowercased())" }
    private var explicitlyStopped: Bool = false

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        deviceId: UUID,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        socketFactory: SocketFactory? = nil,
        heartbeatInterval: Duration = .seconds(30),
        log: ((String, [String: String]) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.deviceId = deviceId
        self.tokenProvider = tokenProvider
        self.socketFactory = socketFactory ?? RealtimeChannel.defaultSocketFactory
        self.heartbeatInterval = heartbeatInterval
        self.log = log
    }

    /// Snapshot of the current status. `isConnected` is the property
    /// `*Ingest` helpers consult before electing the channel.
    var isConnected: Bool { status == .connected }

    /// Read-only status snapshot for log surfaces. Use `statusStream` for
    /// continuous observation.
    var currentStatus: Status { status }

    /// Continuous status stream. The UI / log subscribes once and reacts
    /// to every transition. Each call returns its own stream — multiple
    /// observers are supported.
    func statusStream() -> AsyncStream<Status> {
        AsyncStream { continuation in
            let id = UUID()
            statusContinuations[id] = continuation
            continuation.yield(status)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStatusContinuation(id) }
            }
        }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }

    /// Open the websocket, fetch a bearer token, and join the device
    /// topic. Idempotent: calling `start` while already connected /
    /// connecting is a no-op.
    func start() async {
        explicitlyStopped = false
        if case .connected = status { return }
        if case .connecting = status { return }
        await connectOnce()
    }

    /// Tear the connection down. Cancels in-flight pushes and prevents
    /// auto-reconnect until `start` is called again.
    func stop() async {
        explicitlyStopped = true
        await teardown(reason: "stop")
    }

    /// Push an ingest event. Returns the server's `Outcome` on a
    /// successful `{:reply, {:ok, _}, _}` reply, or throws on
    /// `{:reply, {:error, _}, _}` / transport failures.
    ///
    /// Transport failures are normalized to `RealtimeChannelError` cases so
    /// ingest callers can reliably fall back to HTTP. Explicit error replies
    /// remain `serverError(reason:)` for callers that need the server reason.
    func push(event: String, payload: [String: Any]) async throws -> Outcome {
        guard case .connected = status, let socket else {
            throw RealtimeChannelError.notConnected
        }

        msgRef += 1
        let ref = "\(msgRef)"
        let frame: [Any?] = [
            "\(joinRef)",
            ref,
            topic,
            event,
            payload
        ]
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeChannelError.decodeFailure
        }

        let response: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            pending[ref] = continuation
            Task {
                do {
                    try await socket.send(text: text)
                } catch {
                    if let cont = pending.removeValue(forKey: ref) {
                        cont.resume(throwing: RealtimeChannelError.sendFailed)
                    }
                }
            }
            // Push timeout: WebSocket frames over a quota (or a server
            // that quietly drops oversize messages) leave us waiting on
            // a reply that never arrives. After 30s we trip the
            // continuation with `pushTimeout` so the caller can fall
            // back to HTTP instead of stalling the source cycle.
            Task { [ref] in
                try? await Task.sleep(for: .seconds(30))
                guard let cont = pending.removeValue(forKey: ref) else { return }
                cont.resume(throwing: RealtimeChannelError.pushTimeout)
            }
        }

        return try Self.decodeOutcome(from: response)
    }

    // MARK: - Internal lifecycle

    private func connectOnce() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(reason: "reconnect")
        socket = nil
        pending.values.forEach { $0.resume(throwing: RealtimeChannelError.closed) }
        pending.removeAll()

        update(status: .connecting)

        guard let token = await tokenProvider(), !token.isEmpty else {
            update(status: .disconnected(reason: "no_token"))
            scheduleReconnect()
            return
        }

        guard let url = makeURL(token: token) else {
            update(status: .disconnected(reason: "invalid_url"))
            return
        }

        let websocket = socketFactory(url)
        self.socket = websocket
        await websocket.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            try await joinTopic(socket: websocket)
            reconnectAttempt = 0
            update(status: .connected)
            startHeartbeat()
        } catch {
            log?("realtime.join_failed", ["error": String(describing: error)])
            await teardown(reason: "join_failed")
            scheduleReconnect()
        }
    }

    private func joinTopic(socket: any RealtimeWebSocket) async throws {
        joinRef += 1
        msgRef += 1
        let ref = "\(msgRef)"
        let frame: [Any?] = [
            "\(joinRef)",
            ref,
            topic,
            "phx_join",
            [:] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeChannelError.decodeFailure
        }

        // We use the same `pending[ref]` dispatch table as `push`. The
        // discarded `[String: Any]` payload here is fine — `phx_reply`
        // for a join carries no data we need beyond status=ok.
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pending[ref] = continuation
            Task {
                do {
                    try await socket.send(text: text)
                } catch {
                    if let cont = pending.removeValue(forKey: ref) {
                        cont.resume(throwing: RealtimeChannelError.sendFailed)
                    }
                }
            }
        }
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                handle(message: message)
            } catch {
                guard !Task.isCancelled else { return }
                log?("realtime.receive_error", ["error": String(describing: error)])
                await teardown(reason: "receive_error")
                scheduleReconnect()
                return
            }
        }
    }

    private func handle(message: RealtimeMessage) {
        let text: String
        switch message {
        case .text(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        }
        guard let raw = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: raw, options: []) as? [Any?],
              parsed.count >= 5
        else {
            return
        }
        // Phoenix v2 long-poll-and-websocket-shared shape:
        // [join_ref, ref, topic, event, payload]
        let ref = parsed[1] as? String
        let event = parsed[3] as? String
        let payload = parsed[4] as? [String: Any] ?? [:]
        guard event == "phx_reply", let ref else {
            return
        }
        guard let cont = pending.removeValue(forKey: ref) else { return }
        let response = payload["response"] as? [String: Any] ?? [:]
        switch payload["status"] as? String {
        case "ok":
            cont.resume(returning: response)
        case "error":
            let reason = (response["reason"] as? String) ?? "unknown"
            cont.resume(throwing: RealtimeChannelError.serverError(reason: reason))
        default:
            cont.resume(throwing: RealtimeChannelError.decodeFailure)
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.heartbeatInterval
                try? await Task.sleep(for: interval)
                await self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard case .connected = status, let socket else { return }
        msgRef += 1
        let frame: [Any?] = [nil, "\(msgRef)", "phoenix", "heartbeat", [:] as [String: Any]]
        if let data = try? JSONSerialization.data(withJSONObject: frame, options: []),
           let text = String(data: data, encoding: .utf8) {
            try? await socket.send(text: text)
        }
    }

    private func teardown(reason: String) async {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(reason: reason)
        socket = nil
        pending.values.forEach { $0.resume(throwing: RealtimeChannelError.closed) }
        pending.removeAll()
        update(status: .disconnected(reason: reason))
    }

    private func scheduleReconnect() {
        guard !explicitlyStopped else { return }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let capped = min(attempt, 6)
        let base = pow(2.0, Double(capped))
        let jitter = Double.random(in: 0...1)
        let seconds = min(60.0, base + jitter)
        log?(
            "realtime.reconnect_scheduled",
            ["attempt": "\(attempt)", "delay_s": String(format: "%.1f", seconds)]
        )
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledReconnect()
        }
    }

    private func runScheduledReconnect() async {
        reconnectTask = nil
        await connectOnce()
    }

    private func update(status newStatus: Status) {
        status = newStatus
        for continuation in statusContinuations.values {
            continuation.yield(newStatus)
        }
    }

    private func makeURL(token: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let originalScheme = components?.scheme?.lowercased()
        components?.scheme = (originalScheme == "https" || originalScheme == "wss") ? "wss" : "ws"
        components?.path = "/companion/socket/websocket"
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
            // Phoenix.Socket requires `vsn=2.0.0` for the "v2" envelope
            // format we encode above; this is the same wire format
            // SwiftPhoenixClient targets so we'd be sending equivalent
            // frames either way.
            URLQueryItem(name: "vsn", value: "2.0.0")
        ]
        return components?.url
    }

    private static func decodeOutcome(from response: [String: Any]) throws -> Outcome {
        let accepted = (response["accepted"] as? Int) ?? 0
        let duplicate = (response["duplicate"] as? Int) ?? 0
        let invalid = (response["invalid"] as? Int) ?? 0
        let filtered = (response["filtered"] as? Int) ?? 0
        return Outcome(
            accepted: accepted,
            duplicate: duplicate,
            invalid: invalid,
            filtered: filtered
        )
    }

    private static let defaultSocketFactory: SocketFactory = { url in
        URLSessionRealtimeWebSocket(url: url)
    }
}

/// Decoded WebSocket frame surface used by `RealtimeChannel`. Modeled as
/// an enum (rather than `URLSessionWebSocketTask.Message`) so tests can
/// drive both text + data without depending on the system type.
enum RealtimeMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Protocol the channel uses to drive the underlying transport. Real
/// builds use `URLSessionRealtimeWebSocket`; tests pass an actor-based
/// mock. The protocol is intentionally minimal — send a string, await
/// the next message, cancel.
protocol RealtimeWebSocket: Sendable {
    func resume() async
    func send(text: String) async throws
    func receive() async throws -> RealtimeMessage
    func cancel(reason: String)
}

/// Production `URLSessionWebSocketTask` adapter. Each `receive()` reads
/// one frame; the channel runs the receive loop on its own Task.
final class URLSessionRealtimeWebSocket: RealtimeWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let session = URLSession(configuration: .default)
        self.task = session.webSocketTask(with: url)
    }

    func resume() async {
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> RealtimeMessage {
        let message = try await task.receive()
        switch message {
        case .string(let value):
            return .text(value)
        case .data(let value):
            return .data(value)
        @unknown default:
            return .text("")
        }
    }

    func cancel(reason: String) {
        task.cancel(with: .goingAway, reason: reason.data(using: .utf8))
    }
}
