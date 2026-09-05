import XCTest
@testable import Maraithon

private func http(_ status: Int, url: URL = URL(string: "https://x")!) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

final class VoiceMemosIngestTests: XCTestCase {

    func testPushSendsExpectedHeadersAndPath() async throws {
        let captured = CapturedIngestRequest()
        let responseBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok-xyz" },
            transport: { req in
                await captured.record(req)
                return (responseBody, http(200))
            }
        )

        let payload = VoiceMemoPayload(
            guid: "VM-1",
            localId: "p:1",
            title: "Standup",
            durationSeconds: 12,
            fileSizeBytes: 1234,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let outcome = try await ingest.push(deviceId: UUID(), voiceMemos: [payload])
        XCTAssertEqual(outcome.accepted, 1)
        XCTAssertEqual(outcome.duplicate, 0)

        let last = await captured.last
        let req = try XCTUnwrap(last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/companion/voice-memos")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-xyz")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(req.httpBody)
        XCTAssertGreaterThan(body.count, 2)
        // gzip magic bytes
        XCTAssertEqual(body[0], 0x1f)
        XCTAssertEqual(body[1], 0x8b)
    }

    func testEmptyBatchSkipsTransport() async throws {
        let counter = VoiceMemoSendCounter()
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        let outcome = try await ingest.push(deviceId: UUID(), voiceMemos: [])
        XCTAssertEqual(outcome.accepted, 0)
        XCTAssertEqual(outcome.duplicate, 0)
        let didSend = await counter.value
        XCTAssertFalse(didSend, "Empty batches must not hit the network")
    }

    func testPushSplitsBatchesBelowTheCommonUncompressedBodyBudget() async throws {
        let captured = CapturedIngestRequest()
        let budget = 600
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                let compressed = try XCTUnwrap(req.httpBody)
                let body = try Gzip.decompress(compressed)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let count = (object["voice_memos"] as? [[String: Any]])?.count ?? 0
                let response = try JSONEncoder().encode(
                    IngestResponse(accepted: count, duplicate: 0)
                )
                return (response, http(200))
            },
            bodyBudgetBytes: budget
        )

        let payloads = (1...3).map { index in
            VoiceMemoPayload(
                guid: "VM-\(index)",
                localId: "p:\(index)",
                title: "Memo \(index)",
                durationSeconds: 30,
                fileSizeBytes: 1,
                createdAt: Date(timeIntervalSince1970: 0),
                transcript: String(repeating: "a", count: 180)
            )
        }

        let outcome = try await ingest.push(deviceId: UUID(), voiceMemos: payloads)
        XCTAssertEqual(outcome.accepted, payloads.count)

        let requests = await captured.all
        XCTAssertGreaterThan(requests.count, 1)
        for request in requests {
            let compressed = try XCTUnwrap(request.httpBody)
            let body = try Gzip.decompress(compressed)
            XCTAssertLessThanOrEqual(body.count, budget)
        }
    }

    func testPushOmitsAudioOverTheServerCapButKeepsMetadata() async throws {
        let captured = CapturedIngestRequest()
        let responseBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { req in
                await captured.record(req)
                return (responseBody, http(200))
            },
            bodyBudgetBytes: 2_000,
            audioBudgetBytes: 3
        )
        let payload = VoiceMemoPayload(
            guid: "VM-OVERSIZE",
            localId: "p:42",
            title: "Keep this metadata",
            durationSeconds: 90,
            fileSizeBytes: 4,
            createdAt: Date(timeIntervalSince1970: 0),
            audioBytesBase64: Data([1, 2, 3, 4]).base64EncodedString(),
            audioMime: "audio/m4a",
            transcript: "Keep this transcript"
        )

        _ = try await ingest.push(deviceId: UUID(), voiceMemos: [payload])

        let last = await captured.last
        let request = try XCTUnwrap(last)
        let compressed = try XCTUnwrap(request.httpBody)
        let body = try Gzip.decompress(compressed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let memos = try XCTUnwrap(object["voice_memos"] as? [[String: Any]])
        let memo = try XCTUnwrap(memos.first)
        XCTAssertNil(memo["audio_bytes"])
        XCTAssertEqual(memo["audio_truncated"] as? Bool, true)
        XCTAssertEqual(memo["guid"] as? String, "VM-OVERSIZE")
        XCTAssertEqual(memo["title"] as? String, "Keep this metadata")
        XCTAssertEqual(memo["transcript"] as? String, "Keep this transcript")
    }

    func testTransportBatcherRejectsCapPlusOneInTheSameBase64Bucket() throws {
        let atCapAudio = Data([1, 2, 3, 4]).base64EncodedString()
        let capPlusOneAudio = Data([1, 2, 3, 4, 5]).base64EncodedString()
        XCTAssertEqual(atCapAudio.utf8.count, capPlusOneAudio.utf8.count)

        let payloads = [
            VoiceMemoPayload(
                guid: "VM-AT-CAP",
                localId: "p:1",
                title: "At cap",
                durationSeconds: 1,
                fileSizeBytes: 4,
                createdAt: Date(timeIntervalSince1970: 0),
                audioBytesBase64: atCapAudio,
                audioMime: "audio/m4a"
            ),
            VoiceMemoPayload(
                guid: "VM-CAP-PLUS-ONE",
                localId: "p:2",
                title: "Keep metadata",
                durationSeconds: 1,
                fileSizeBytes: 5,
                createdAt: Date(timeIntervalSince1970: 0),
                audioBytesBase64: capPlusOneAudio,
                audioMime: "audio/m4a"
            ),
            VoiceMemoPayload(
                guid: "VM-INVALID-BASE64",
                localId: "p:3",
                title: "Keep invalid metadata",
                durationSeconds: 1,
                fileSizeBytes: 3,
                createdAt: Date(timeIntervalSince1970: 0),
                audioBytesBase64: "%%%%",
                audioMime: "audio/m4a"
            )
        ]

        let batches = try VoiceMemosTransportBatcher(
            bodyBudgetBytes: 2_000,
            audioBudgetBytes: 4
        ).batches(deviceId: UUID(), voiceMemos: payloads)
        let shaped = Dictionary(uniqueKeysWithValues: batches.flatMap { $0 }.map { ($0.guid, $0) })
        let atCap = try XCTUnwrap(shaped["VM-AT-CAP"])
        let capPlusOne = try XCTUnwrap(shaped["VM-CAP-PLUS-ONE"])
        let invalid = try XCTUnwrap(shaped["VM-INVALID-BASE64"])

        XCTAssertEqual(atCap.audioBytesBase64, atCapAudio)
        XCTAssertFalse(atCap.audioTruncated)
        XCTAssertNil(capPlusOne.audioBytesBase64)
        XCTAssertTrue(capPlusOne.audioTruncated)
        XCTAssertEqual(capPlusOne.title, "Keep metadata")
        XCTAssertNil(invalid.audioBytesBase64)
        XCTAssertTrue(invalid.audioTruncated)
        XCTAssertEqual(invalid.title, "Keep invalid metadata")
    }

    func testRealtimeSendFailureFallsBackToHTTP() async throws {
        let device = UUID()
        let mock = MockSocket()
        await mock.onSend { [weak mock] frame in
            guard frame.contains("phx_join"),
                  let data = frame.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [Any?],
                  values.count >= 3
            else { return }
            let reply: [Any?] = [
                values[0],
                values[1],
                values[2],
                "phx_reply",
                ["status": "ok", "response": [:]] as [String: Any]
            ]
            let replyData = try! JSONSerialization.data(withJSONObject: reply)
            await mock?.deliver(.text(String(decoding: replyData, as: UTF8.self)))
        }
        let channel = RealtimeChannel(
            baseURL: URL(string: "https://example.test")!,
            deviceId: device,
            tokenProvider: { "tok" },
            socketFactory: { _ in mock },
            heartbeatInterval: .seconds(60),
            log: nil
        )
        await channel.start()
        try await waitForConnected(channel)
        await mock.failNextSend()

        let captured = CapturedIngestRequest()
        let responseBody = try JSONEncoder().encode(IngestResponse(accepted: 1, duplicate: 0))
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { request in
                await captured.record(request)
                return (responseBody, http(200))
            },
            realtime: channel
        )
        let payload = VoiceMemoPayload(
            guid: "VM-FALLBACK",
            localId: "p:1",
            title: nil,
            durationSeconds: 1,
            fileSizeBytes: 1,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let outcome = try await ingest.push(deviceId: device, voiceMemos: [payload])
        XCTAssertEqual(outcome.accepted, 1)
        let last = await captured.last
        XCTAssertNotNil(last)
        await channel.stop()
    }

    func testServerErrorIsTypedAsRetriable() async {
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { "tok" },
            transport: { _ in (Data(), http(500)) }
        )
        do {
            _ = try await ingest.push(
                deviceId: UUID(),
                voiceMemos: [VoiceMemoPayload(
                    guid: "g", localId: "p:1", title: nil,
                    durationSeconds: 1, fileSizeBytes: 1, createdAt: Date()
                )]
            )
            XCTFail("Expected server error")
        } catch let err as MaraithonClientError {
            XCTAssertTrue(err.isRetriable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingTokenShortCircuits() async {
        let counter = VoiceMemoSendCounter()
        let ingest = VoiceMemosIngest(
            baseURL: URL(string: "https://example.test")!,
            tokenProvider: { nil },
            transport: { _ in
                await counter.mark()
                return (Data(), http(200))
            }
        )
        do {
            _ = try await ingest.push(
                deviceId: UUID(),
                voiceMemos: [VoiceMemoPayload(
                    guid: "g", localId: "p:1", title: nil,
                    durationSeconds: 1, fileSizeBytes: 1, createdAt: Date()
                )]
            )
            XCTFail("Expected unauthorized")
        } catch MaraithonClientError.unauthorized {
            let didSend = await counter.value
            XCTAssertFalse(didSend, "Should short-circuit before sending")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func waitForConnected(
        _ channel: RealtimeChannel,
        timeoutMillis: Int = 1_000
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1_000)
        while Date() < deadline {
            if await channel.isConnected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("channel never reached .connected")
    }
}

/// Actor wrapper so the mock transport closure can store the last request
/// from any execution context.
actor CapturedIngestRequest {
    private(set) var last: URLRequest?
    private(set) var all: [URLRequest] = []
    func record(_ request: URLRequest) {
        last = request
        all.append(request)
    }
}

/// Voice-Memos-scoped flag for "did the transport closure get called". The
/// iMessage suite already has a `SendCounter`; sharing it would couple two
/// otherwise-independent test files at the target level.
actor VoiceMemoSendCounter {
    private(set) var value: Bool = false
    func mark() { value = true }
}
