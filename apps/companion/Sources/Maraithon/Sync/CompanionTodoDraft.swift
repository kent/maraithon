/// Manual todo input retains a draft UUID so a retry cannot create a duplicate.
import Foundation

struct CompanionTodoDraft: Encodable, Sendable {
    let requestID: UUID
    let title: String
    let notes: String?
    let nextAction: String?
    let priority: Int
    let dueAt: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case title, notes, priority
        case nextAction = "next_action"
        case dueAt = "due_at"
    }
}
