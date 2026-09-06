import SwiftUI

/// User-facing Todo labels shared by the Mac list and inspector.
enum TodosCopy {
    static func resultCount(_ count: Int, filter: TodoListFilter) -> String {
        let noun = count == 1 ? "work item" : "work items"
        return "\(count) \(filter == .active ? "active" : "completed") \(noun)"
    }

    static func emptyTitle(filter: TodoListFilter, query: String) -> String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching Todos"
        }
        return filter == .active ? "Your open work list is clear" : "No completed work yet"
    }

    static func emptyDescription(filter: TodoListFilter, query: String) -> String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try another title, next action, or source."
        }
        if filter == .active {
            return "Maraithon will surface commitments when the next move is clear."
        }
        return "Completed work will appear here and can be reopened."
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "gmail": return "Gmail"
        case "google_calendar": return "Google Calendar"
        case "imessage": return "iMessage"
        case "browser_history": return "Browser History"
        case "voice_memos": return "Voice Memos"
        case "manual": return "Added by you"
        default:
            return source
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func attentionLabel(_ value: String?) -> String {
        value == "monitor" ? "Watching" : "Needs action"
    }

    static func statusLabel(_ value: String) -> String {
        switch value {
        case "open": return "Open"
        case "snoozed": return "Snoozed"
        case "done": return "Done"
        case "dismissed": return "Dismissed"
        default: return value.capitalized
        }
    }

    static func priorityLabel(_ priority: Int) -> String {
        switch priority {
        case 90...: return "Critical"
        case 75...: return "High"
        default: return "Normal"
        }
    }

    static func dueLabel(_ date: Date?, active: Bool = true) -> String {
        guard let date else { return "No due date" }
        if active && date < Date() {
            return "Overdue " + date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func dueTone(_ date: Date?, active: Bool = true) -> StatusTone {
        guard active, let date else { return .muted }
        return date < Date() ? .error : .muted
    }
}
