import Foundation

/// Packs voice-memo payloads under the shared realtime/HTTP body budget,
/// preserving metadata even when audio must be omitted.
struct VoiceMemosTransportBatcher: Sendable {
    enum BatchingError: Error, Equatable, Sendable {
        case metadataExceedsBodyBudget(guid: String)
    }

    let bodyBudgetBytes: Int
    let audioBudgetBytes: Int

    /// Greedily packs records into envelopes that fit both transports. Audio
    /// is the only field we may omit: all identity, timing, transcript, and
    /// summary metadata remains intact. If metadata alone exceeds the bounded
    /// contract, fail explicitly so the source cursor remains retryable.
    func batches(
        deviceId: UUID,
        voiceMemos: [VoiceMemoPayload]
    ) throws -> [[VoiceMemoPayload]] {
        var batches: [[VoiceMemoPayload]] = []
        var current: [VoiceMemoPayload] = []

        for original in voiceMemos {
            let payload = enforceAudioBudget(original)
            let candidate = current + [payload]

            if try bodyFits(deviceId: deviceId, voiceMemos: candidate) {
                current = candidate
                continue
            }

            if !current.isEmpty {
                batches.append(current)
                current = []
            }

            if try bodyFits(deviceId: deviceId, voiceMemos: [payload]) {
                current = [payload]
                continue
            }

            guard payload.audioBytesBase64 != nil else {
                throw BatchingError.metadataExceedsBodyBudget(guid: payload.guid)
            }

            let metadataOnly = payload.omittingAudioAsTruncated()
            guard try bodyFits(deviceId: deviceId, voiceMemos: [metadataOnly]) else {
                throw BatchingError.metadataExceedsBodyBudget(guid: payload.guid)
            }
            current = [metadataOnly]
        }

        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    private func enforceAudioBudget(_ payload: VoiceMemoPayload) -> VoiceMemoPayload {
        guard let encodedAudio = payload.audioBytesBase64 else { return payload }
        guard let decodedBytes = decodedAudioByteCount(encodedAudio),
              decodedBytes <= audioBudgetBytes else {
            return payload.omittingAudioAsTruncated()
        }
        return payload
    }

    /// Returns the exact decoded byte count for canonical padded base64
    /// without allocating a second copy of the audio. Invalid base64 fails
    /// closed so malformed bytes never bypass the per-record transport cap.
    private func decodedAudioByteCount(_ encodedAudio: String) -> Int? {
        let bytes = encodedAudio.utf8
        guard bytes.count.isMultiple(of: 4) else { return nil }

        var padding = 0
        var sawPadding = false
        var lastSextet = 0

        for byte in bytes {
            if byte == 0x3D { // "="
                sawPadding = true
                padding += 1
                guard padding <= 2 else { return nil }
                continue
            }

            guard !sawPadding, let sextet = Self.base64Sextet(byte) else {
                return nil
            }
            lastSextet = sextet
        }

        // Canonical padding requires the unused low bits in the final
        // sextet to be zero. This rejects strings a permissive decoder might
        // otherwise normalize to a different byte sequence.
        if padding == 1, !lastSextet.isMultiple(of: 4) { return nil }
        if padding == 2, !lastSextet.isMultiple(of: 16) { return nil }

        let (decodedWithPadding, overflow) = (bytes.count / 4).multipliedReportingOverflow(by: 3)
        guard !overflow else { return nil }
        return decodedWithPadding - padding
    }

    private static func base64Sextet(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x41...0x5A: // A...Z
            Int(byte - 0x41)
        case 0x61...0x7A: // a...z
            Int(byte - 0x61) + 26
        case 0x30...0x39: // 0...9
            Int(byte - 0x30) + 52
        case 0x2B: // +
            62
        case 0x2F: // /
            63
        default:
            nil
        }
    }

    private func bodyFits(deviceId: UUID, voiceMemos: [VoiceMemoPayload]) throws -> Bool {
        let body = VoiceMemoIngestBody(
            deviceId: deviceId,
            source: "voice_memos",
            voiceMemos: voiceMemos
        )
        return try Self.encoder.encode(body).count <= bodyBudgetBytes
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
