import Foundation
import SwiftUI

enum TodoPriority: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case critical

    var id: String { rawValue }

    static var allCases: [TodoPriority] {
        [.critical, .high, .medium, .low]
    }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Normal"
        case .high: "High"
        case .critical: "Critical"
        }
    }

    var symbolName: String {
        switch self {
        case .low: "arrow.down.circle"
        case .medium: "equal.circle"
        case .high: "exclamationmark.circle"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .low: .secondary
        case .medium: .blue
        case .high: .orange
        case .critical: .red
        }
    }
}

enum TodoStatus: String, Codable, CaseIterable, Identifiable {
    case open
    case snoozed
    case done
    case dismissed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .snoozed: "Snoozed"
        case .done: "Done"
        case .dismissed: "Dismissed"
        }
    }
}

enum TodoAttentionMode: String, Codable, CaseIterable, Identifiable {
    case actNow = "act_now"
    case monitor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actNow: "Needs action"
        case .monitor: "Watching"
        }
    }
}

enum ContactStatus: String, Codable, CaseIterable, Identifiable {
    case lead
    case active
    case atRisk
    case closed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lead: "New"
        case .active: "Active"
        case .atRisk: "Needs Care"
        case .closed: "Archived"
        }
    }

    var tint: Color {
        switch self {
        case .lead: .indigo
        case .active: .green
        case .atRisk: .orange
        case .closed: .secondary
        }
    }
}

enum DealStage: String, Codable, CaseIterable, Identifiable {
    case prospect
    case qualified
    case proposal
    case won
    case lost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prospect: "New"
        case .qualified: "Known"
        case .proposal: "Follow-up"
        case .won: "Close"
        case .lost: "Archived"
        }
    }

    var tint: Color {
        switch self {
        case .prospect: .cyan
        case .qualified: .blue
        case .proposal: .purple
        case .won: .green
        case .lost: .secondary
        }
    }
}

enum ChatRole: String, Codable, CaseIterable, Identifiable {
    case user
    case assistant
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: "You"
        case .assistant: "Assistant"
        case .system: "System"
        }
    }
}

enum ChatSyncStatus: String, Codable, CaseIterable, Identifiable {
    case local
    case syncing
    case synced
    case failed

    var id: String { rawValue }
}

enum ChatDeliveryState: String, Codable, CaseIterable, Identifiable {
    case sending
    case sent
    case delivered
    case failed

    var id: String { rawValue }
}

enum ChatActionDecision: String, Codable, CaseIterable, Identifiable {
    case confirm
    case reject

    var id: String { rawValue }
}

enum ChatRunStatus: String, Codable, CaseIterable, Identifiable {
    case queued
    case running
    case completed
    case degraded
    case failed
    case waitingConfirmation = "waiting_confirmation"

    var id: String { rawValue }

    var isPending: Bool {
        switch self {
        case .queued, .running:
            true
        case .completed, .degraded, .failed, .waitingConfirmation:
            false
        }
    }
}
