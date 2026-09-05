import Foundation

extension MobileAPIClient {
    private struct PushDeviceResponse: Decodable, Sendable {
        struct Device: Decodable, Sendable {
            let id: String
            let status: String
        }

        let device: Device
    }

    private struct PushEmptyResponse: Decodable, Sendable {}

    func registerPushDevice(
        sessionToken: String,
        deviceToken: String,
        appVersion: String? = nil,
        environment: String? = nil
    ) async throws {
        var body: RequestBody = [
            "device_token": .string(deviceToken),
            "platform": .string("ios"),
        ]

        if let appVersion {
            body["app_version"] = .string(appVersion)
        }

        if let environment {
            body["environment"] = .string(environment)
        }

        let _: PushDeviceResponse = try await send(
            path: "/push/devices",
            method: "POST",
            sessionToken: sessionToken,
            body: body,
            responseType: PushDeviceResponse.self
        )
    }

    func unregisterPushDevice(sessionToken: String, deviceToken: String) async throws {
        let _: PushEmptyResponse = try await send(
            path: "/push/devices/\(deviceToken)",
            method: "DELETE",
            sessionToken: sessionToken,
            responseType: PushEmptyResponse.self
        )
    }
}
