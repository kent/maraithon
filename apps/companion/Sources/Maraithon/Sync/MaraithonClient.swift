import Foundation
import Compression

/// HTTP client for the Maraithon server. Lives outside any actor so the
/// sync engine can call into it from background tasks. Auth bearer is
/// resolved at call-time via the `tokenProvider` closure so the client
/// never caches plaintext on its own.
///
/// Base URL is read from `MaraithonBaseURL` in Info.plist with a fallback
/// to the production vanity domain.
struct MaraithonClient: Sendable {
    /// Resolves the bearer token at call time. Returning `nil` causes
    /// `unauthorized` errors before the request is even sent, which keeps
    /// the failure mode consistent with a server 401.
    typealias TokenProvider = @Sendable () async -> String?

    /// Pluggable HTTP transport so tests can mock the network without
    /// `URLProtocol` plumbing. The default uses `URLSession.shared`.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let tokenProvider: TokenProvider
    let transport: Transport
    let userAgent: String

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping TokenProvider,
        transport: @escaping Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)"
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
    }

    // MARK: - Endpoints

    func whoami() async throws -> DeviceAuth.Account {
        let request = try await makeRequest(
            method: "GET",
            path: "/api/v1/companion/whoami",
            body: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        // Server returns the account fields flat (email + device_name + …).
        return try JSONDecoder().decode(DeviceAuth.Account.self, from: data)
    }

    func ingest(batch: IngestBatch) async throws -> SyncOutcome {
        let bodyData = try JSONEncoder().encode(batch)
        let gzipped = try Gzip.compress(bodyData)
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/messages",
            body: gzipped,
            extraHeaders: ["Content-Encoding": "gzip", "Content-Type": "application/json"]
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)
        return SyncOutcome(accepted: decoded.accepted, duplicate: decoded.duplicate, invalid: decoded.invalid)
    }

    func purgeDeviceMessages(deviceId: UUID) async throws {
        let request = try await makeRequest(
            method: "DELETE",
            path: "/api/v1/companion/devices/\(deviceId.uuidString)/messages",
            body: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
    }

    /// Deletes synced data for the current Mac without unpairing it.
    /// Passing `nil` deletes every supported source; passing a source id
    /// such as `notes` deletes only that source.
    func purgeDeviceData(deviceId: UUID, source: String? = nil) async throws -> DeviceDataPurgeResponse {
        var path = "/api/v1/companion/devices/\(deviceId.uuidString)/data"
        if let source, !source.isEmpty {
            path += "/\(source)"
        }
        let request = try await makeRequest(
            method: "DELETE",
            path: path,
            body: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(DeviceDataPurgeResponse.self, from: data)
    }

    /// Lists every device paired to the calling user. Used by the
    /// `Devices` settings tab to render the row-per-Mac table and to
    /// surface per-source counts so the user can audit what each device
    /// has uploaded.
    func listDevices() async throws -> DevicesListResponse {
        let request = try await makeRequest(
            method: "GET",
            path: "/api/v1/companion/devices",
            body: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DevicesListResponse.self, from: data)
    }

    /// Revokes a paired device's bearer token. The companion app uses
    /// this for the "Sign out from this Mac" trash button; the server
    /// keeps the row around (with `revoked_at` set) so the user can audit
    /// it in the admin UI.
    func revokeDevice(id: String) async throws {
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/devices/\(id)/revoke",
            body: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
    }

    /// Cross-source semantic + substring recall. Wraps the server-side
    /// `RecallAnywhere` tool so the desktop Recall panel can surface the
    /// same unified search the assistant uses on the chat surface.
    func recall(query: String, limit: Int = 20) async throws -> RecallResponse {
        let body = try JSONEncoder().encode(RecallRequest(query: query, limit: limit))
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/recall",
            body: body,
            extraHeaders: ["Content-Type": "application/json"]
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecallResponse.self, from: data)
    }

    // MARK: - Request shaping

    func makeRequest(
        method: String,
        path: String,
        body: Data?,
        queryItems: [URLQueryItem] = [],
        extraHeaders: [String: String] = [:]
    ) async throws -> URLRequest {
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: path)
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw MaraithonClientError.invalidResponse
            }
            components.queryItems = queryItems
            guard let queryURL = components.url else {
                throw MaraithonClientError.invalidResponse
            }
            url = queryURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = body
        return request
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MaraithonClientError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw MaraithonClientError.unauthorized
        case 400..<500:
            throw MaraithonClientError.clientError(status: http.statusCode, body: String(data: data, encoding: .utf8))
        default:
            throw MaraithonClientError.serverError(status: http.statusCode)
        }
    }

    // MARK: - Defaults

    static let defaultBaseURL: URL = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "MaraithonBaseURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        // Force-unwrap is fine here: literal URL known at compile time.
        return URL(string: "https://maraithon.com")!
    }()

    static let defaultTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }
}

/// Typed errors so callers (`SyncEngine`, `DeviceAuth`) can switch on
/// failure shape rather than match strings.
enum MaraithonClientError: Error, Equatable {
    case unauthorized
    case clientError(status: Int, body: String?)
    case serverError(status: Int)
    case invalidResponse
    case transport(message: String)

    var isRetriable: Bool {
        switch self {
        case .serverError, .transport: return true
        case .unauthorized, .clientError, .invalidResponse: return false
        }
    }
}

// MARK: - Wire shapes

/// Ingest payload — matches the spec's `POST /api/v1/companion/messages`
/// body. The companion app builds it once per batch.
struct IngestBatch: Codable, Sendable {
    let deviceId: UUID
    let source: String
    let messages: [SyncEnvelope]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case messages
    }
}

struct IngestResponse: Codable, Sendable {
    let accepted: Int
    let duplicate: Int
    let invalid: Int

    init(accepted: Int, duplicate: Int, invalid: Int = 0) {
        self.accepted = accepted
        self.duplicate = duplicate
        self.invalid = invalid
    }

    enum CodingKeys: String, CodingKey {
        case accepted
        case duplicate
        case invalid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decode(Int.self, forKey: .accepted)
        duplicate = try container.decode(Int.self, forKey: .duplicate)
        invalid = try container.decodeIfPresent(Int.self, forKey: .invalid) ?? 0
    }
}

struct DeviceDataPurgeResponse: Codable, Sendable, Hashable {
    let deleted: [String: Int]

    var totalDeleted: Int {
        deleted.values.reduce(0, +)
    }
}

/// Body for `POST /api/v1/companion/recall`. Mirrors the server tool
/// schema: `{ query, limit }` (sources omitted = all sources).
struct RecallRequest: Codable, Sendable {
    let query: String
    let limit: Int
}

/// Wire shape for one ranked recall hit. Matches the per-source
/// envelope `Maraithon.Tools.RecallAnywhereHelpers.score_hit/2`
/// returns.
struct RecallResult: Codable, Sendable, Identifiable, Hashable {
    let source: String
    let id: String?
    let title: String?
    let snippet: String?
    let timestamp: Date?
    let score: Double
}

/// Server response envelope for the recall endpoint.
struct RecallResponse: Codable, Sendable {
    let query: String
    let count: Int
    let results: [RecallResult]
    let sourcesSearched: [String]
    let partialSources: [String]
    let latencyMs: Int

    enum CodingKeys: String, CodingKey {
        case query, count, results
        case sourcesSearched = "sources_searched"
        case partialSources = "partial_sources"
        case latencyMs = "latency_ms"
    }
}

/// One device row in the `GET /api/v1/companion/devices` response.
/// Server returns flat JSON with snake-case keys; we expose camelCase
/// to SwiftUI views.
struct CompanionDevice: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let deviceId: String
    let deviceName: String?
    let lastSeenAt: Date?
    let pairedAt: Date?
    let revokedAt: Date?
    let isCurrent: Bool
    let counts: SourceCounts

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case deviceName = "device_name"
        case lastSeenAt = "last_seen_at"
        case pairedAt = "paired_at"
        case revokedAt = "revoked_at"
        case isCurrent = "is_current"
        case counts
    }
}

/// Per-source counts for a single device. Matches the keys returned by
/// `Maraithon.Companion.Devices.enrich_with_stats/1` on the server.
struct SourceCounts: Codable, Sendable, Hashable {
    let messages: Int
    let notes: Int
    let voiceMemos: Int
    let calendarEvents: Int
    let reminders: Int
    let contacts: Int
    let files: Int
    let browserVisits: Int

    enum CodingKeys: String, CodingKey {
        case messages = "messages_count"
        case notes = "notes_count"
        case voiceMemos = "voice_memos_count"
        case calendarEvents = "calendar_events_count"
        case reminders = "reminders_count"
        case contacts = "contacts_count"
        case files = "files_count"
        case browserVisits = "browser_visits_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        notes = try container.decodeIfPresent(Int.self, forKey: .notes) ?? 0
        voiceMemos = try container.decodeIfPresent(Int.self, forKey: .voiceMemos) ?? 0
        calendarEvents = try container.decodeIfPresent(Int.self, forKey: .calendarEvents) ?? 0
        reminders = try container.decodeIfPresent(Int.self, forKey: .reminders) ?? 0
        contacts = try container.decodeIfPresent(Int.self, forKey: .contacts) ?? 0
        files = try container.decodeIfPresent(Int.self, forKey: .files) ?? 0
        browserVisits = try container.decodeIfPresent(Int.self, forKey: .browserVisits) ?? 0
    }

    var total: Int {
        messages + notes + voiceMemos + calendarEvents + reminders + contacts + files + browserVisits
    }
}

/// Wire shape for `GET /api/v1/companion/devices`.
struct DevicesListResponse: Codable, Sendable {
    let currentDeviceId: String
    let devices: [CompanionDevice]

    enum CodingKeys: String, CodingKey {
        case currentDeviceId = "current_device_id"
        case devices
    }
}
