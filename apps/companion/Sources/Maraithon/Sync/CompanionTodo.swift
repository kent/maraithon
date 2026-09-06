import Foundation

/// Least-privilege Todo filters exposed by the paired-device API.
enum TodoListFilter: String, CaseIterable, Identifiable, Sendable {
    case active
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "Active"
        case .done: return "Done"
        }
    }
}

/// Public Todo projection returned by the companion API. This intentionally
/// models only user-facing fields and ignores internal metadata.
struct CompanionTodo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let source: String
    let attentionMode: String?
    let title: String
    let summary: String?
    let nextAction: String?
    var notes: String? = nil
    let dueAt: String?
    let priority: Int
    let status: String
    let snoozedUntil: String?
    let updatedAt: String?
    let actionCard: CompanionTodoActionCard?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case attentionMode = "attention_mode"
        case title
        case summary
        case nextAction = "next_action"
        case notes
        case dueAt = "due_at"
        case priority
        case status
        case snoozedUntil = "snoozed_until"
        case updatedAt = "updated_at"
        case actionCard = "action_card"
    }

    var recommendedMove: String? {
        Self.nonblank(actionCard?.nextBestAction) ?? Self.nonblank(nextAction)
    }

    var dueDate: Date? { Self.parseDate(dueAt) }
    var updatedDate: Date? { Self.parseDate(updatedAt) }

    var canMarkDone: Bool { status == "open" || status == "snoozed" }
    var canReopen: Bool { status == "done" }
    var canDismiss: Bool { status == "open" || status == "snoozed" }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

/// High-signal action-card fields shared with the web and mobile work-item
/// surfaces. The server may add fields without breaking this decoder.
struct CompanionTodoActionCard: Codable, Hashable, Sendable {
    let headline: String?
    let decisionPrompt: String?
    let whyNow: String?
    let nextBestAction: String?
    let draftPreview: String?
    let sourceContext: String?
    let evidenceExcerpt: String?
    let sourceAction: CompanionTodoSourceAction?

    enum CodingKeys: String, CodingKey {
        case headline
        case decisionPrompt = "decision_prompt"
        case whyNow = "why_now"
        case nextBestAction = "next_best_action"
        case draftPreview = "draft_preview"
        case sourceContext = "source_context"
        case evidenceExcerpt = "evidence_excerpt"
        case sourceAction = "source_action"
    }
}

struct CompanionTodoSourceAction: Codable, Hashable, Sendable {
    let openURL: String?
    let openLabel: String?
    let draftText: String?

    enum CodingKeys: String, CodingKey {
        case openURL = "open_url"
        case openLabel = "open_label"
        case draftText = "draft_text"
    }

    var destination: URL? {
        guard let openURL, let url = URL(string: openURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http", "slack", "sms"].contains(scheme) else { return nil }
        return url
    }
}

struct CompanionTodoDetailsResponse: Codable, Sendable {
    let todo: CompanionTodo
}

struct CompanionTodosResponse: Codable, Sendable {
    let todos: [CompanionTodo]
    let pagination: CompanionTodoPagination
}

struct CompanionTodoPagination: Codable, Sendable {
    let limit: Int
    let offset: Int
    let count: Int
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case limit
        case offset
        case count
        case nextOffset = "next_offset"
    }
}

enum CompanionTodoAction: String, Sendable {
    case done
    case dismiss
    case reopen
}

struct CompanionTodoActionResponse: Codable, Sendable {
    let action: String
    let todo: CompanionTodo
}
