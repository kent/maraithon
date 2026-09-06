import Foundation

/// User-facing copy for non-source companion app failures.
///
/// Network clients and server endpoints keep diagnostic errors precise for
/// logs and tests. This mapper is the UI boundary for Recall, Settings, and
/// other companion-level views: no HTTP bodies, enum dumps, or transport
/// domains should reach the screen.
struct CompanionErrorCopy {
    private static let requestFallback = "Request did not complete. Please try again."
    private static let serverFallback = "Maraithon hit a cloud service problem. Retry in a moment."

    static func message(for error: Error) -> String {
        switch error {
        case MaraithonClientError.unauthorized:
            return "Reconnect Maraithon to continue."
        case MaraithonClientError.invalidResponse:
            return "Maraithon returned an unexpected response. Update the app before continuing."
        case let MaraithonClientError.clientError(status, body):
            if let serverMessage = serverBodyMessage(from: body) {
                return serverMessage
            }
            return clientMessage(status: status)
        case let MaraithonClientError.serverError(status):
            return serverMessage(status: status)
        case MaraithonClientError.transport:
            return "Connection issue. Retry when you are online."
        default:
            return requestFallback
        }
    }

    static func message(for reason: String) -> String {
        let lower = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if lower.isEmpty {
            return requestFallback
        }

        if lower.contains("unauthorized") || lower.contains("401") || lower == "no_token" {
            return "Reconnect Maraithon to continue."
        }

        if lower.contains("timeout") || lower.contains("timed out") {
            return "Connection timed out. Retry when the network is stable."
        }

        if lower.contains("servererror") || lower.contains("status: 5") {
            return serverFallback
        }

        if lower.contains("nsurlerrordomain")
            || lower.contains("could not connect")
            || lower.contains("network")
            || lower.contains("offline")
            || lower.contains("transport(") {
            return "Connection issue. Retry when you are online."
        }

        if lower.contains("invalidresponse")
            || lower.contains("decodefailure")
            || lower.contains("decodingerror")
            || lower.contains("json") {
            return "Maraithon returned an unexpected response. Update the app before continuing."
        }

        if looksTechnical(reason) {
            return requestFallback
        }

        return reason
    }

    private static func clientMessage(status: Int) -> String {
        switch status {
        case 401:
            return "Reconnect Maraithon to continue."
        case 404:
            return "That item is no longer available. Refresh before continuing."
        case 408:
            return "Connection timed out. Retry when the network is stable."
        case 409:
            return "The request was out of date. Refresh before continuing."
        case 413:
            return "That request was too large. Try fewer items."
        case 429:
            return "Maraithon is busy right now. Retry in a moment."
        default:
            return requestFallback
        }
    }

    private static func serverMessage(status: Int) -> String {
        if status >= 500 {
            return serverFallback
        }

        return requestFallback
    }

    private static func looksTechnical(_ value: String) -> Bool {
        if value.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil {
            return true
        }

        let lower = value.lowercased()
        let markers = [
            "optional(",
            "error domain=",
            "clienterror(",
            "servererror(",
            "status:",
            "status=",
            "http ",
            "{",
            "}",
            "[",
            "]",
            "=>",
            "stacktrace",
            "token=",
            "token:",
            "token ",
            "access_token",
            "refresh_token",
            "authorization",
            "bearer",
            "secret",
            "password",
            "api_key",
            "apikey",
            "client_secret",
            "private_key",
            "postgrex",
            "phoenix",
            "exception"
        ]

        return markers.contains { lower.contains($0) }
    }

    private static func serverBodyMessage(from body: String?) -> String? {
        guard
            let body,
            let data = body.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data)
        else {
            return nil
        }

        for candidate in [envelope.message, envelope.error] {
            if let safe = safeServerText(candidate) {
                return safe
            }
        }

        return nil
    }

    private static func safeServerText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, !looksTechnical(trimmed) else {
            return nil
        }

        return trimmed
    }
}

private struct ServerErrorEnvelope: Decodable {
    let error: String?
    let message: String?
}
