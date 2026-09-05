import XCTest
@testable import Maraithon

/// Tests for `RealtimeChannel`. We inject a mock `RealtimeWebSocket`
/// so the entire join / push / heartbeat flow runs without touching
/// `URLSession`.
final class RealtimeChannelTests: XCTestCase {

    func testStartConnectsJoinsTopicAndReachesConnected() async throws {
        let device = UUID()
        let mock = MockSocket()

        // Server-side script: respond to the first frame (the phx_join)
        // with `status: "ok"`. We capture every frame the client sends so
        // we can assert on the topic.
        await mock.onSend { [weak mock] frame in
            guard let parsed = Self.parseFrame(frame) else { return }
            let topic = parsed.topic
            let event = parsed.event
            let ref = parsed.ref
            if event == "phx_join" {
                let reply = Self.replyFrame(
                    joinRef: parsed.joinRef,
                    ref: ref,
                    topic: topic,
                    status: "ok",
                    response: [:]
                )
                await mock?.deliver(.text(reply))
            }
        }

        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: device,
            tokenProvider: { "tok-xyz" },
            socketFactory: { _ in mock },
            heartbeatInterval: .seconds(60),
            log: nil
        )

        await channel.start()
        try await Self.waitForConnected(channel)

        let isConnected = await channel.isConnected
        XCTAssertTrue(isConnected)

        let frames = await mock.sentFrames
        XCTAssertFalse(frames.isEmpty)
        let join = try XCTUnwrap(frames.first.flatMap(Self.parseFrame))
        XCTAssertEqual(join.topic, "companion:device:\(device.uuidString.lowercased())")
        XCTAssertEqual(join.event, "phx_join")

        await channel.stop()
    }

    func testPushReturnsServerOutcome() async throws {
        let device = UUID()
        let mock = MockSocket()

        await mock.onSend { [weak mock] frame in
            guard let parsed = Self.parseFrame(frame) else { return }
            let response: [String: Any] = parsed.event == "ingest:notes"
                ? ["accepted": 2, "duplicate": 0, "invalid": 0]
                : [:]
            let reply = Self.replyFrame(
                joinRef: parsed.joinRef,
                ref: parsed.ref,
                topic: parsed.topic,
                status: "ok",
                response: response
            )
            await mock?.deliver(.text(reply))
        }

        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: device,
            tokenProvider: { "tok" },
            socketFactory: { _ in mock },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        await channel.start()
        try await Self.waitForConnected(channel)

        let outcome = try await channel.push(
            event: "ingest:notes",
            payload: ["device_id": device.uuidString, "source": "notes", "notes": []]
        )
        XCTAssertEqual(outcome.accepted, 2)
        XCTAssertEqual(outcome.duplicate, 0)
        await channel.stop()
    }

    func testPushBeforeStartThrowsNotConnected() async {
        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: UUID(),
            tokenProvider: { "tok" },
            socketFactory: { _ in MockSocket() },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        do {
            _ = try await channel.push(event: "ingest:notes", payload: [:])
            XCTFail("Expected notConnected")
        } catch RealtimeChannel.RealtimeChannelError.notConnected {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testServerErrorReplyThrows() async throws {
        let device = UUID()
        let mock = MockSocket()
        await mock.onSend { [weak mock] frame in
            guard let parsed = Self.parseFrame(frame) else { return }
            if parsed.event == "phx_join" {
                await mock?.deliver(.text(
                    Self.replyFrame(
                        joinRef: parsed.joinRef,
                        ref: parsed.ref,
                        topic: parsed.topic,
                        status: "ok",
                        response: [:]
                    )
                ))
            } else {
                await mock?.deliver(.text(
                    Self.replyFrame(
                        joinRef: parsed.joinRef,
                        ref: parsed.ref,
                        topic: parsed.topic,
                        status: "error",
                        response: ["reason": "messages_required"]
                    )
                ))
            }
        }

        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: device,
            tokenProvider: { "tok" },
            socketFactory: { _ in mock },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        await channel.start()
        try await Self.waitForConnected(channel)

        do {
            _ = try await channel.push(event: "ingest:messages", payload: [:])
            XCTFail("Expected server error")
        } catch RealtimeChannel.RealtimeChannelError.serverError(let reason) {
            XCTAssertEqual(reason, "messages_required")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        await channel.stop()
    }

    func testMissingTokenLeavesStatusDisconnected() async throws {
        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.com")!,
            deviceId: UUID(),
            tokenProvider: { nil },
            socketFactory: { _ in MockSocket() },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        await channel.start()
        // Give the connect Task a tick to advance.
        try? await Task.sleep(for: .milliseconds(20))
        let status = await channel.currentStatus
        if case .disconnected = status {
            // ok
        } else {
            XCTFail("Expected disconnected, got \(status)")
        }
        await channel.stop()
    }

    // MARK: - Helpers

    /// Parse a Phoenix v2 frame: `[join_ref, ref, topic, event, payload]`.
    nonisolated private static func parseFrame(_ text: String) -> Frame? {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any?],
              arr.count >= 5
        else { return nil }
        return Frame(
            joinRef: arr[0] as? String,
            ref: (arr[1] as? String) ?? "",
            topic: (arr[2] as? String) ?? "",
            event: (arr[3] as? String) ?? "",
            payload: arr[4] as? [String: Any] ?? [:]
        )
    }

    /// Build a v2 `phx_reply` frame.
    nonisolated private static func replyFrame(
        joinRef: String?,
        ref: String,
        topic: String,
        status: String,
        response: [String: Any]
    ) -> String {
        let payload: [String: Any] = ["status": status, "response": response]
        let frame: [Any?] = [joinRef, ref, topic, "phx_reply", payload]
        let data = try! JSONSerialization.data(withJSONObject: frame, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private static func waitForConnected(
        _ channel: RealtimeChannel,
        timeoutMillis: Int = 1_000
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1000)
        while Date() < deadline {
            if await channel.isConnected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let status = await channel.currentStatus
        XCTFail("channel never reached .connected (status=\(status))")
    }

    struct Frame {
        let joinRef: String?
        let ref: String
        let topic: String
        let event: String
        let payload: [String: Any]
    }
}

/// Mock `RealtimeWebSocket` driven by tests. `onSend` is the hook the
/// test sets up to script server replies; `deliver` queues a message
/// for the next `receive()`. Marked `@unchecked Sendable` because all
/// state is funneled through the `queue` actor.
final class MockSocket: RealtimeWebSocket, @unchecked Sendable {
    private let inbox = Inbox()
    private let sendHook = SendHook()

    func resume() async {}

    func send(text: String) async throws {
        try await sendHook.fire(frame: text)
    }

    func receive() async throws -> RealtimeMessage {
        try await inbox.next()
    }

    func cancel(reason: String) {
        Task { await inbox.cancel() }
    }

    func deliver(_ message: RealtimeMessage) async {
        await inbox.enqueue(message)
    }

    func onSend(_ handler: @escaping @Sendable (String) async -> Void) async {
        await sendHook.set(handler)
    }

    func failNextSend() async {
        await sendHook.failNext()
    }

    var sentFrames: [String] {
        get async { await sendHook.frames }
    }
}

/// Queue of inbound messages waiting to be read by `receive()`. If a
/// reader is waiting when a message arrives we hand it over directly;
/// otherwise we buffer.
private actor Inbox {
    private var buffer: [RealtimeMessage] = []
    private var waiters: [CheckedContinuation<RealtimeMessage, Error>] = []
    private var cancelled = false

    func enqueue(_ message: RealtimeMessage) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: message)
        } else {
            buffer.append(message)
        }
    }

    func next() async throws -> RealtimeMessage {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if cancelled {
            throw URLError(.cancelled)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func cancel() {
        cancelled = true
        for waiter in waiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
        waiters.removeAll()
    }
}

/// Captures sent frames + invokes the user-supplied script.
private actor SendHook {
    private(set) var frames: [String] = []
    private var handler: (@Sendable (String) async -> Void)?
    private var shouldFailNext = false

    func set(_ handler: @escaping @Sendable (String) async -> Void) {
        self.handler = handler
    }

    func failNext() {
        shouldFailNext = true
    }

    func fire(frame: String) async throws {
        frames.append(frame)
        if shouldFailNext {
            shouldFailNext = false
            throw URLError(.networkConnectionLost)
        }
        if let handler {
            await handler(frame)
        }
    }
}
