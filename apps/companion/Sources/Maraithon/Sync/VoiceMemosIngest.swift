import Foundation

/// Voice-Memos-specific HTTP client. Posts to
/// `POST /api/v1/companion/voice-memos` using the same auth + transport
/// shape as `MaraithonClient`, but kept as a separate type so the
/// iMessage-owned client doesn't grow new surface area while the Voice
/// Memos server contract is still settling.
///
/// Design choice (per the Voice Memos team brief): rather than threading
/// the voice-memos payload through `SyncEngine.enqueue` / `drain` — which
/// today hard-codes the `IngestBatch.messages` field name — we POST
/// directly. The trade-off: voice memos don't get the durable-queue retry
/// the engine provides for iMessage. The `VoiceMemosSource` mitigates this
/// by only advancing its cursor after the POST returns success, so the
/// next poll re-tries the same batch on failure. Once the engine grows a
/// generic `enqueue(source:envelopes:)` we can fold this back in.
struct VoiceMemosIngest: Sendable {
    /// Leave headroom below Bandit's 8,000,000-byte WebSocket message cap
    /// and the server's 8 MiB inflated HTTP-body cap. The budget applies to
    /// the uncompressed JSON envelope shared by both transports.
    nonisolated static let maximumBodyBytes = 7_500_000

    /// Keep the client aligned with `Maraithon.LocalVoiceMemos` so audio the
    /// server would discard never consumes frame or request-body capacity.
    nonisolated static let maximumAudioBytes = 5 * 1024 * 1024

    /// Closure invoked after a successful push so the source can be
    /// mirrored into Spotlight. See `NotesIngest.SpotlightHook` — same
    /// contract: best-effort, errors are swallowed by the caller.
    typealias SpotlightHook = @Sendable ([VoiceMemoPayload]) async -> Void

    let baseURL: URL
    let tokenProvider: MaraithonClient.TokenProvider
    let transport: MaraithonClient.Transport
    let userAgent: String
    let path: String
    /// Optional realtime channel. Same fallback contract as
    /// `NotesIngest`: a connected channel is preferred, transport-style
    /// failures route to HTTP.
    let realtime: RealtimeChannel?
    /// Optional Spotlight hook (see `SpotlightHook`).
    let spotlight: SpotlightHook?
    let bodyBudgetBytes: Int
    let audioBudgetBytes: Int

    init(
        baseURL: URL = MaraithonClient.defaultBaseURL,
        tokenProvider: @escaping MaraithonClient.TokenProvider,
        transport: @escaping MaraithonClient.Transport = MaraithonClient.defaultTransport,
        userAgent: String = "MaraithonCompanion/1.0 (macOS)",
        path: String = "/api/v1/companion/voice-memos",
        realtime: RealtimeChannel? = nil,
        spotlight: SpotlightHook? = nil,
        bodyBudgetBytes: Int = VoiceMemosIngest.maximumBodyBytes,
        audioBudgetBytes: Int = VoiceMemosIngest.maximumAudioBytes
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
        self.path = path
        self.realtime = realtime
        self.spotlight = spotlight
        self.bodyBudgetBytes = max(bodyBudgetBytes, 1)
        self.audioBudgetBytes = max(audioBudgetBytes, 0)
    }

    /// Push a batch. Returns the server's accepted/duplicate counts so the
    /// source can log them; on transport / 5xx failures the source surfaces
    /// `.error` through its status publisher and the next poll cycle will
    /// re-attempt from the same cursor.
    func push(deviceId: UUID, voiceMemos: [VoiceMemoPayload]) async throws -> SyncOutcome {
        guard !voiceMemos.isEmpty else {
            return SyncOutcome(accepted: 0, duplicate: 0)
        }

        let batches = try VoiceMemosTransportBatcher(
            bodyBudgetBytes: bodyBudgetBytes,
            audioBudgetBytes: audioBudgetBytes
        ).batches(deviceId: deviceId, voiceMemos: voiceMemos)
        var aggregate = SyncOutcome(accepted: 0, duplicate: 0)

        for batch in batches {
            let outcome = try await pushBatch(deviceId: deviceId, voiceMemos: batch)
            aggregate = SyncOutcome(
                accepted: aggregate.accepted + outcome.accepted,
                duplicate: aggregate.duplicate + outcome.duplicate,
                invalid: aggregate.invalid + outcome.invalid
            )
        }

        if let spotlight {
            await spotlight(voiceMemos)
        }
        return aggregate
    }

    private func pushBatch(deviceId: UUID, voiceMemos: [VoiceMemoPayload]) async throws -> SyncOutcome {
        let body = VoiceMemoIngestBody(
            deviceId: deviceId,
            source: "voice_memos",
            voiceMemos: voiceMemos
        )
        if let realtime, await realtime.isConnected {
            do {
                let payload = try Self.realtimePayload(from: body)
                let outcome = try await realtime.push(event: "ingest:voice_memos", payload: payload)
                return SyncOutcome(
                    accepted: outcome.accepted,
                    duplicate: outcome.duplicate,
                    invalid: outcome.invalid
                )
            } catch is RealtimeChannel.RealtimeChannelError {
                // Any realtime-channel failure falls back to HTTP. The
                // channel is best-effort; HTTP is the reliable transport.
                // This includes `serverError(reason:)` cases like
                // "unmatched topic" the server emits when its channel
                // state diverges from ours after a reconnect.
            }
        }
        let bodyData = try Self.encoder.encode(body)
        let gzipped = try Gzip.compress(bodyData)

        guard let token = await tokenProvider(), !token.isEmpty else {
            throw MaraithonClientError.unauthorized
        }
        var url = baseURL
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = gzipped

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw MaraithonClientError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw MaraithonClientError.unauthorized
        case 400..<500:
            throw MaraithonClientError.clientError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        default:
            throw MaraithonClientError.serverError(status: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(IngestResponse.self, from: data)
        return SyncOutcome(accepted: decoded.accepted, duplicate: decoded.duplicate, invalid: decoded.invalid)
    }

    /// Shared encoder configured to emit ISO-8601 dates. The server expects
    /// strict ISO-8601 UTC; centralising the choice here means future
    /// formatting tweaks (fractional seconds, time-zone normalization) live
    /// in one place.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Mirrors the HTTP encoder so the realtime channel ships the exact
    /// same wire shape — same `_at` ISO-8601 dates, same snake_case keys.
    private static func realtimePayload(from body: VoiceMemoIngestBody) throws -> [String: Any] {
        let data = try encoder.encode(body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaraithonClientError.invalidResponse
        }
        return object
    }
}

/// Per-recording payload. Matches the server contract field names exactly
/// via `CodingKeys`. `title` is nullable on the wire so the server can
/// distinguish "no user-set title" from "empty string".
///
/// v1.5 adds the audio + transcript fields. All four are optional on the
/// wire so older clients (and rows where the audio file was missing or
/// over the cap) still ingest cleanly — the server treats missing audio
/// the same as nil audio.
struct VoiceMemoPayload: Codable, Sendable, Equatable {
    let guid: String
    let localId: String
    let title: String?
    let durationSeconds: Double
    let fileSizeBytes: Int64
    let createdAt: Date
    /// Base64-encoded `.m4a` bytes. `nil` when the audio was over the
    /// per-record size cap (see `VoiceMemosSource.maxAudioBytes`) or
    /// otherwise unreadable.
    let audioBytesBase64: String?
    /// `audio/m4a` for Voice Memos recordings. Wire-explicit so the
    /// server doesn't have to guess.
    let audioMime: String?
    /// True when bytes were intentionally omitted because either the
    /// per-record audio cap or the aggregate transport budget was reached.
    let audioTruncated: Bool
    /// On-device transcript. `nil` when speech recognition isn't
    /// authorized or available — the audio still uploads.
    let transcript: String?
    /// Engine label, e.g. `"sf_speech"`.
    let transcriptEngine: String?
    /// BCP-47 locale, e.g. `"en-US"`.
    let transcriptLang: String?
    /// Optional on-device summary of `transcript`. Generated client-side
    /// by ``OnDeviceSummarizer`` when a transcript is available so the
    /// cloud has a compact, search-friendly description alongside the
    /// raw text. Additive on the wire — older servers ignore it.
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case guid
        case localId = "local_id"
        case title
        case durationSeconds = "duration_seconds"
        case fileSizeBytes = "file_size_bytes"
        case createdAt = "created_at"
        case audioBytesBase64 = "audio_bytes"
        case audioMime = "audio_mime"
        case audioTruncated = "audio_truncated"
        case transcript
        case transcriptEngine = "transcript_engine"
        case transcriptLang = "transcript_lang"
        case summary
    }

    init(
        guid: String,
        localId: String,
        title: String?,
        durationSeconds: Double,
        fileSizeBytes: Int64,
        createdAt: Date,
        audioBytesBase64: String? = nil,
        audioMime: String? = nil,
        audioTruncated: Bool = false,
        transcript: String? = nil,
        transcriptEngine: String? = nil,
        transcriptLang: String? = nil,
        summary: String? = nil
    ) {
        self.guid = guid
        self.localId = localId
        self.title = title
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
        self.createdAt = createdAt
        self.audioBytesBase64 = audioBytesBase64
        self.audioMime = audioMime
        self.audioTruncated = audioTruncated
        self.transcript = transcript
        self.transcriptEngine = transcriptEngine
        self.transcriptLang = transcriptLang
        self.summary = summary
    }

    func omittingAudioAsTruncated() -> VoiceMemoPayload {
        VoiceMemoPayload(
            guid: guid,
            localId: localId,
            title: title,
            durationSeconds: durationSeconds,
            fileSizeBytes: fileSizeBytes,
            createdAt: createdAt,
            audioBytesBase64: nil,
            audioMime: audioMime,
            audioTruncated: true,
            transcript: transcript,
            transcriptEngine: transcriptEngine,
            transcriptLang: transcriptLang,
            summary: summary
        )
    }
}

/// Envelope of the full request body. Module-internal so the transport
/// batcher can measure the exact same JSON that the ingest helper sends.
struct VoiceMemoIngestBody: Codable, Sendable {
    let deviceId: UUID
    let source: String
    let voiceMemos: [VoiceMemoPayload]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case source
        case voiceMemos = "voice_memos"
    }
}
