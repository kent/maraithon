import XCTest
@testable import Maraithon

/// v1.5 wire-payload tests for `VoiceMemosSource`: audio bytes get
/// base64-encoded, oversize files degrade to metadata-only, and the
/// injected transcriber's outcome decides which transcript fields land
/// on the wire. The pre-v1.5 tests in `VoiceMemosSourceTests` cover the
/// polling + cursor mechanics; these tests stay laser-focused on
/// payload shaping so the seams are obvious when something regresses.
final class VoiceMemosSourceV15Tests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var defaultsSuite: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-memos-v15-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("CloudRecordings.db")

        defaultsSuiteName = "com.maraithon.companion.voice_memos.v15.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaultsSuite)
        defaultsSuite.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaultsSuite?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testEncodesAudioBytesAndAttachesTranscript() async throws {
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 1,
                uniqueID: "VM-AUDIO",
                customLabel: "Daily note",
                dateSeconds: 779_500_000,
                durationSeconds: 30,
                relativePath: "20260301 120000.m4a",
                fileBytes: 1024
            )
        ])

        let transcriber = makeTranscriber(
            outcome: .success(text: "hello brave new world", locale: "en-US", engine: "sf_speech")
        )

        let env = makeEnvironment(transcriber: transcriber)
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        let payload = try XCTUnwrap(batches.first?.payloads.first)
        // (autoclosure-safe: snapshot was awaited above and stored in a let)
        XCTAssertEqual(payload.guid, "VM-AUDIO")
        XCTAssertEqual(payload.audioMime, "audio/m4a")
        XCTAssertEqual(payload.transcript, "hello brave new world")
        XCTAssertEqual(payload.transcriptEngine, "sf_speech")
        XCTAssertEqual(payload.transcriptLang, "en-US")

        let b64 = try XCTUnwrap(payload.audioBytesBase64)
        let decoded = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertEqual(decoded.count, 1024)
    }

    @MainActor
    func testOversizeAudioFallsBackToMetadataOnly() async throws {
        // Cap is 5 MB by default; cap to 512 bytes here so the fixture
        // doesn't have to write multi-megabyte zeroed files.
        let cap: Int64 = 512
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 1,
                uniqueID: "VM-BIG",
                customLabel: nil,
                dateSeconds: 779_500_000,
                durationSeconds: 600,
                relativePath: "huge.m4a",
                fileBytes: Int(cap) + 1
            )
        ])

        let env = makeEnvironment(
            transcriber: makeTranscriber(outcome: .unavailable(reason: "test_skip")),
            maxAudioBytes: cap
        )
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        let payload = try XCTUnwrap(batches.first?.payloads.first)
        XCTAssertNil(
            payload.audioBytesBase64,
            "Oversize audio must be dropped client-side so the server flags audio_truncated"
        )
        XCTAssertTrue(payload.audioTruncated)
        XCTAssertEqual(
            payload.audioMime,
            "audio/m4a",
            "Mime stays present even when bytes are dropped so the server has it"
        )
        XCTAssertNil(payload.transcript)
    }

    @MainActor
    func testMissingTranscriberStillUploadsAudio() async throws {
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 1,
                uniqueID: "VM-NO-TX",
                customLabel: "untranscribed",
                dateSeconds: 779_500_000,
                durationSeconds: 5,
                relativePath: "small.m4a",
                fileBytes: 64
            )
        ])

        let env = makeEnvironment(
            transcriber: makeTranscriber(outcome: .unavailable(reason: "speech_recognition_denied"))
        )
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        let payload = try XCTUnwrap(batches.first?.payloads.first)
        XCTAssertNotNil(payload.audioBytesBase64)
        XCTAssertNil(payload.transcript)
        XCTAssertNil(payload.transcriptEngine)
        XCTAssertNil(payload.transcriptLang)
        XCTAssertEqual(
            env.source.statusPublisher.displayedState(),
            .needsAttention(reason: "voice_memos_speech_not_authorized")
        )
    }

    @MainActor
    func testSiriAndDictationDisabledKeepsAudioSyncingButShowsGuidance() async throws {
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 1,
                uniqueID: "VM-SIRI-OFF",
                customLabel: "local transcript gated",
                dateSeconds: 779_500_000,
                durationSeconds: 12,
                relativePath: "siri-off.m4a",
                fileBytes: 128
            )
        ])

        let env = makeEnvironment(
            transcriber: makeTranscriber(
                outcome: .failed(
                    reason: "Error Domain=kLSRErrorDomain Code=201 \"Siri and Dictation are disabled\""
                )
            )
        )
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        let payload = try XCTUnwrap(batches.first?.payloads.first)
        XCTAssertNotNil(payload.audioBytesBase64)
        XCTAssertNil(payload.transcript)
        XCTAssertNil(env.source.statusPublisher.activeIssue)
        XCTAssertEqual(
            env.source.statusPublisher.state,
            .needsAttention(reason: "voice_memos_speech_disabled")
        )
    }

    @MainActor
    func testEmptyTranscriptionRecordsEngineButNoText() async throws {
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 1,
                uniqueID: "VM-SILENT",
                customLabel: "silent clip",
                dateSeconds: 779_500_000,
                durationSeconds: 5,
                relativePath: "silent.m4a",
                fileBytes: 64
            )
        ])

        let env = makeEnvironment(
            transcriber: makeTranscriber(outcome: .empty(locale: "en-US", engine: "sf_speech"))
        )
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        let payload = try XCTUnwrap(batches.first?.payloads.first)
        XCTAssertNil(payload.transcript)
        XCTAssertEqual(payload.transcriptEngine, "sf_speech")
        XCTAssertEqual(payload.transcriptLang, "en-US")
    }

    @MainActor
    func testAudioReadFailureAndGrowthRaceDegradeGracefully() async throws {
        try VoiceMemosFixture.build(at: dbURL, rows: [
            VoiceMemosFixture.Row(
                pk: 1,
                uniqueID: "VM-READ-FAIL",
                customLabel: nil,
                dateSeconds: 779_500_000,
                durationSeconds: 5,
                relativePath: "racey.m4a",
                fileBytes: 64
            ),
            VoiceMemosFixture.Row(
                pk: 2,
                uniqueID: "VM-GREW",
                customLabel: "Keep growing metadata",
                dateSeconds: 779_500_001,
                durationSeconds: 6,
                relativePath: "growing.m4a",
                fileBytes: 64
            )
        ])

        let cap: Int64 = 512
        let env = makeEnvironment(
            transcriber: makeTranscriber(outcome: .unavailable(reason: "test_skip")),
            audioReader: { url in
                if url.lastPathComponent == "growing.m4a" {
                    return Data(repeating: 0, count: Int(cap) + 1)
                }
                throw NSError(domain: "test", code: 1)
            },
            maxAudioBytes: cap
        )
        try await env.source.syncNow()

        let batches = await env.collector.snapshot()
        let payloads = try XCTUnwrap(batches.first?.payloads)
        let readFailure = try XCTUnwrap(payloads.first { $0.guid == "VM-READ-FAIL" })
        XCTAssertNil(readFailure.audioBytesBase64, "read failure → no audio bytes on the wire")
        XCTAssertEqual(readFailure.audioMime, "audio/m4a")
        XCTAssertFalse(readFailure.audioTruncated)

        let grew = try XCTUnwrap(payloads.first { $0.guid == "VM-GREW" })
        XCTAssertNil(grew.audioBytesBase64)
        XCTAssertEqual(grew.audioMime, "audio/m4a")
        XCTAssertTrue(grew.audioTruncated)
        XCTAssertEqual(grew.title, "Keep growing metadata")
        XCTAssertEqual(env.source.statusPublisher.activeIssue?.severity, .error)
    }

    // MARK: - Helpers

    private func makeTranscriber(outcome: VoiceMemosTranscriber.Outcome) -> VoiceMemosTranscriber {
        VoiceMemosTranscriber(
            recognizerFactory: { _ in
                StubV15Recognizer(outcome: outcome)
            },
            authorizationProbe: {
                switch outcome {
                case .unavailable: return .denied
                default: return .authorized
                }
            }
        )
    }

    @MainActor
    private struct Environment {
        let source: VoiceMemosSource
        let collector: VoiceMemosBatchCollector
        let deviceId: UUID
    }

    @MainActor
    private func makeEnvironment(
        transcriber: VoiceMemosTranscriber,
        audioReader: (@Sendable (URL) throws -> Data)? = nil,
        maxAudioBytes: Int64 = VoiceMemosSource.maxAudioBytes
    ) -> Environment {
        let log = EventLog(capacity: 128)
        let collector = VoiceMemosBatchCollector()
        let deviceId = UUID()
        let cursor = VoiceMemosCursor(defaults: defaultsSuite)
        let reader: @Sendable (URL) throws -> Data = audioReader ?? { url in
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        let source = VoiceMemosSource(
            databaseURL: dbURL,
            cursor: cursor,
            eventLog: log,
            deviceIdProvider: { deviceId },
            pollInterval: 3600,
            batchLimit: 200,
            transcriber: transcriber,
            audioReader: reader,
            maxAudioBytes: maxAudioBytes,
            outbox: { deviceId, payloads in
                await collector.append(deviceId: deviceId, payloads: payloads)
                return SyncOutcome(accepted: payloads.count, duplicate: 0)
            }
        )
        return Environment(source: source, collector: collector, deviceId: deviceId)
    }
}

/// Stub recognizer that maps a desired `Outcome` straight back. Lives in
/// this file (vs. shared) because the transcriber tests already have
/// their own stub tuned to the lower-level `SpeechRecognizing` knobs.
private struct StubV15Recognizer: SpeechRecognizing {
    let outcome: VoiceMemosTranscriber.Outcome

    var isAvailable: Bool { true }
    var supportsOnDeviceRecognition: Bool { true }

    func recognize(url: URL) async throws -> String {
        switch outcome {
        case .success(let text, _, _): return text
        case .empty: return ""
        case .unavailable: return ""
        case .failed(let reason):
            throw NSError(
                domain: "stub",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
    }
}
