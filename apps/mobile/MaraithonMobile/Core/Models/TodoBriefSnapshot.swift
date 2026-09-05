import Foundation

/// The current server-authored brief for a work item. It is stored as one
/// Codable value so the server can evolve the brief independently of the
/// SwiftData schema while the high-signal fields remain available offline.
struct TodoBriefSnapshot: Codable, Equatable, Sendable {
    let whyItMatters: String?
    let situation: String?
    let recommendation: String?
    let steps: [String]
    let openQuestions: [String]
    let effort: String?
    let generatedAt: Date?
    let model: String?

    var effortLabel: String? {
        switch effort {
        case "under_2_min": "Under 2 minutes"
        case "under_15_min": "Under 15 minutes"
        case "longer": "Needs a focused block"
        default: nil
        }
    }
}
