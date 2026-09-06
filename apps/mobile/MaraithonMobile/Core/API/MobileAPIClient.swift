import Foundation

enum MobileAPIError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case unauthorized
    /// Conditional GET signal: the server answered 304 because the stored
    /// ETag still matches, so the caller's local copy is already current.
    /// Not a user-facing failure; sync paths catch it and return early.
    case notModified
    case server(String)
    case serverResponse(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Maraithon could not build that request."
        case .invalidResponse:
            return "Maraithon returned an unexpected response."
        case .unauthorized:
            return "Sign-in expired. Sign in again."
        case .notModified:
            return "Content is already up to date."
        case .server(let message):
            return message
        case .serverResponse(_, let message):
            return message
        }
    }

    var isNotFound: Bool {
        switch self {
        case .server("not_found"):
            return true
        case .serverResponse(let code, _):
            return code == "not_found"
        default:
            return false
        }
    }
}

struct MobileAPIClient: Sendable {
    typealias RequestBody = [String: JSONValue]

    /// Invoked whenever any request comes back HTTP 401. SessionStore assigns
    /// this so an expired session forces a sign-out instead of stranding the
    /// user on silently failing screens.
    @MainActor static var unauthorizedHandler: (() -> Void)?

    struct MagicLinkResponse: Decodable, Sendable {
        struct MagicLink: Decodable, Sendable {
            let email: String
            let expiresInSeconds: TimeInterval
            let delivery: String?

            enum CodingKeys: String, CodingKey {
                case email
                case expiresInSeconds = "expires_in_seconds"
                case delivery
            }
        }

        let magicLink: MagicLink

        enum CodingKeys: String, CodingKey {
            case magicCode = "magic_code"
            case magicLink = "magic_link"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let magicCode = try container.decodeIfPresent(MagicLink.self, forKey: .magicCode) {
                magicLink = magicCode
            } else {
                magicLink = try container.decode(MagicLink.self, forKey: .magicLink)
            }
        }
    }

    struct AuthResponse: Decodable, Sendable {
        let sessionToken: String
        let user: RemoteUser

        enum CodingKeys: String, CodingKey {
            case sessionToken = "session_token"
            case user
        }
    }

    struct MeResponse: Decodable, Sendable {
        let user: RemoteUser
    }

    struct TodosResponse: Decodable, Sendable {
        let todos: [RemoteTodo]
        /// Optional so old servers without pagination support still decode;
        /// its absence means the single response is the full collection.
        let pagination: Pagination?

        struct Pagination: Decodable, Sendable {
            let limit: Int?
            let offset: Int?
            let count: Int?
            let nextOffset: Int?

            enum CodingKeys: String, CodingKey {
                case limit
                case offset
                case count
                case nextOffset = "next_offset"
            }
        }
    }

    /// A fully accumulated todos listing. `isComplete` is false only when the
    /// pagination hard cap was hit, meaning the server may hold more rows than
    /// were fetched; callers must not delete-reconcile against a capped list.
    struct TodoListing: Sendable {
        let todos: [RemoteTodo]
        let isComplete: Bool
    }

    /// Endpoint keys for the ETag store. Todos keys vary by `include_cards`
    /// because the two variants return different payloads: a 304 earned by a
    /// cards-off sync must not suppress the first cards-on sync. Bump the key
    /// version whenever persisted rows need a mandatory one-time backfill.
    enum ETagKey {
        static let people = "people"
        static let chatThreads = "chat-threads"

        static func todos(includeCards: Bool) -> String {
            // Older validators may describe a page set that never reached SwiftData.
            includeCards ? "todos.v4.cards" : "todos.v4"
        }
    }

    /// Clears every stored ETag. Called automatically when a request comes
    /// back 401 (session expired -> forced sign-out) so the next account never
    /// sees a false 304 minted for the previous one.
    static func clearETags() {
        ETagStore.shared.clearAll()
    }

    struct TodoActivityResponse: Decodable, Sendable {
        let activity: [RemoteTodoActivity]
    }

    struct TodoResponse: Decodable, Sendable {
        let todo: RemoteTodo
    }

    struct TodoReplyResponse: Decodable, Sendable {
        let todo: RemoteTodo
        let completed: Bool
        let sentTo: String?

        enum CodingKeys: String, CodingKey {
            case todo
            case completed
            case sentTo = "sent_to"
        }
    }

    struct TodoActionResponse: Decodable, Sendable {
        let todo: RemoteTodo
        let action: String
    }

    struct AcknowledgementResponse: Decodable, Sendable {
        let ok: Bool
    }

    struct GoalsResponse: Decodable, Sendable {
        let goals: [RemoteGoal]
    }

    struct GoalResponse: Decodable, Sendable {
        let goal: RemoteGoal
    }

    struct GoalProgressResponse: Decodable, Sendable {
        let progressUpdate: RemoteGoalProgressUpdate

        enum CodingKeys: String, CodingKey {
            case progressUpdate = "progress_update"
        }
    }

    struct GoalReviewRunResponse: Decodable, Sendable {
        let reviewRun: RemoteGoalReviewRun

        enum CodingKeys: String, CodingKey {
            case reviewRun = "review_run"
        }
    }

    struct PeopleResponse: Decodable, Sendable {
        let people: [RemotePerson]
    }

    struct PersonResponse: Decodable, Sendable {
        let person: RemotePerson
    }

    struct ReconnectResponse: Decodable, Sendable {
        let suggestions: [RemoteReconnectSuggestion]
    }

    struct RemoteReconnectSuggestion: Decodable, Equatable, Sendable, Identifiable {
        let person: RemotePerson
        let category: String
        let headline: String
        let reason: String
        let suggestedAction: String?
        let daysSinceLast: Int?
        let cadenceDays: Int?
        let communicationScore: Int?
        let overdue: Bool
        let openWork: [RemoteOpenWork]

        var id: String { person.id }

        enum CodingKeys: String, CodingKey {
            case person
            case category
            case headline
            case reason
            case suggestedAction = "suggested_action"
            case daysSinceLast = "days_since_last"
            case cadenceDays = "cadence_days"
            case communicationScore = "communication_score"
            case overdue
            case openWork = "open_work"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            person = try container.decode(RemotePerson.self, forKey: .person)
            category = try container.decode(String.self, forKey: .category)
            headline = try container.decode(String.self, forKey: .headline)
            reason = try container.decode(String.self, forKey: .reason)
            suggestedAction = try container.decodeIfPresent(String.self, forKey: .suggestedAction)
            daysSinceLast = try container.decodeIfPresent(Int.self, forKey: .daysSinceLast)
            cadenceDays = try container.decodeIfPresent(Int.self, forKey: .cadenceDays)
            communicationScore = try container.decodeIfPresent(Int.self, forKey: .communicationScore)
            overdue = try container.decodeIfPresent(Bool.self, forKey: .overdue) ?? false
            openWork = try container.decodeIfPresent([RemoteOpenWork].self, forKey: .openWork) ?? []
        }
    }

    struct RemoteOpenWork: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
    }

    struct RemoteUser: Decodable, Equatable, Sendable {
        let id: String
        let email: String
        let sessionExpiresAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case email
            case sessionExpiresAt = "session_expires_at"
        }
    }

    struct RemoteTodo: Decodable, Equatable, Sendable {
        let id: String
        let source: String?
        let kind: String?
        let attentionMode: String?
        let title: String
        let summary: String?
        let nextAction: String?
        let dueAt: Date?
        let notes: String?
        let actionPlan: String?
        let ownerLabel: String?
        let priority: Int?
        let status: String
        let snoozedUntil: Date?
        let closedAt: Date?
        let sourceOccurredAt: Date?
        let insertedAt: Date?
        let updatedAt: Date?
        let brief: RemoteTodoBrief?
        let actionCard: RemoteActionCard?
        let hasActionCardField: Bool
        let relatedPeople: [RemoteRelatedPerson]

        enum CodingKeys: String, CodingKey {
            case id
            case source
            case kind
            case attentionMode = "attention_mode"
            case title
            case summary
            case nextAction = "next_action"
            case dueAt = "due_at"
            case notes
            case actionPlan = "action_plan"
            case ownerLabel = "owner_label"
            case priority
            case status
            case snoozedUntil = "snoozed_until"
            case closedAt = "closed_at"
            case sourceOccurredAt = "source_occurred_at"
            case insertedAt = "inserted_at"
            case updatedAt = "updated_at"
            case brief
            case actionCard = "action_card"
            case relatedPeople = "related_people"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            attentionMode = try container.decodeIfPresent(String.self, forKey: .attentionMode)
            title = try container.decode(String.self, forKey: .title)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            actionPlan = try container.decodeIfPresent(String.self, forKey: .actionPlan)
            ownerLabel = try container.decodeIfPresent(String.self, forKey: .ownerLabel)
            priority = try container.decodeIfPresent(Int.self, forKey: .priority)
            status = try container.decode(String.self, forKey: .status)
            snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
            closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
            sourceOccurredAt = try container.decodeIfPresent(Date.self, forKey: .sourceOccurredAt)
            insertedAt = try container.decodeIfPresent(Date.self, forKey: .insertedAt)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            brief = try container.decodeIfPresent(RemoteTodoBrief.self, forKey: .brief)
            actionCard = try container.decodeIfPresent(RemoteActionCard.self, forKey: .actionCard)
            hasActionCardField = container.contains(.actionCard)
            relatedPeople = try container.decodeIfPresent([RemoteRelatedPerson].self, forKey: .relatedPeople) ?? []
        }

        init(
            id: String,
            source: String? = nil,
            kind: String? = nil,
            attentionMode: String? = nil,
            title: String,
            summary: String?,
            nextAction: String?,
            dueAt: Date?,
            notes: String?,
            actionPlan: String? = nil,
            ownerLabel: String? = nil,
            priority: Int?,
            status: String,
            snoozedUntil: Date? = nil,
            closedAt: Date?,
            sourceOccurredAt: Date? = nil,
            insertedAt: Date? = nil,
            updatedAt: Date? = nil,
            brief: RemoteTodoBrief? = nil,
            actionCard: RemoteActionCard? = nil,
            hasActionCardField: Bool = true,
            relatedPeople: [RemoteRelatedPerson] = []
        ) {
            self.id = id
            self.source = source
            self.kind = kind
            self.attentionMode = attentionMode
            self.title = title
            self.summary = summary
            self.nextAction = nextAction
            self.dueAt = dueAt
            self.notes = notes
            self.actionPlan = actionPlan
            self.ownerLabel = ownerLabel
            self.priority = priority
            self.status = status
            self.snoozedUntil = snoozedUntil
            self.closedAt = closedAt
            self.sourceOccurredAt = sourceOccurredAt
            self.insertedAt = insertedAt
            self.updatedAt = updatedAt
            self.brief = brief
            self.actionCard = actionCard
            self.hasActionCardField = hasActionCardField
            self.relatedPeople = relatedPeople
        }
    }

    struct RemoteTodoBrief: Decodable, Equatable, Sendable {
        let whyItMatters: String?
        let situation: String?
        let recommendation: String?
        let steps: [String]
        let openQuestions: [String]
        let effort: String?
        let generatedAt: Date?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case whyItMatters = "why_it_matters"
            case situation
            case recommendation
            case steps
            case openQuestions = "open_questions"
            case effort
            case generatedAt = "generated_at"
            case model
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            whyItMatters = try container.decodeIfPresent(String.self, forKey: .whyItMatters)
            situation = try container.decodeIfPresent(String.self, forKey: .situation)
            recommendation = try container.decodeIfPresent(String.self, forKey: .recommendation)
            steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
            openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
            effort = try container.decodeIfPresent(String.self, forKey: .effort)
            generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
            model = try container.decodeIfPresent(String.self, forKey: .model)
        }
    }

    struct RemoteGoal: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let category: String
        let status: String
        let title: String
        let desiredOutcome: String?
        let why: String?
        let successMetric: String?
        let priority: Int?
        let sensitivity: String
        let proactiveVisibility: String
        let reviewCadence: String
        let startsOn: String?
        let targetAt: String?
        let lastReviewedAt: String?
        let nextReviewAt: String?
        let linkedWorkCount: Int
        let linkedPeopleCount: Int
        let latestProgress: RemoteGoalProgressSummary?
        let progressUpdates: [RemoteGoalProgressUpdate]
        let links: [RemoteGoalLink]
        let reviewRuns: [RemoteGoalReviewRun]
        let insertedAt: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case category
            case status
            case title
            case desiredOutcome = "desired_outcome"
            case why
            case successMetric = "success_metric"
            case priority
            case sensitivity
            case proactiveVisibility = "proactive_visibility"
            case reviewCadence = "review_cadence"
            case startsOn = "starts_on"
            case targetAt = "target_at"
            case lastReviewedAt = "last_reviewed_at"
            case nextReviewAt = "next_review_at"
            case linkedWorkCount = "linked_work_count"
            case linkedPeopleCount = "linked_people_count"
            case latestProgress = "latest_progress"
            case progressUpdates = "progress_updates"
            case links
            case reviewRuns = "review_runs"
            case insertedAt = "inserted_at"
            case updatedAt = "updated_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            category = try container.decode(String.self, forKey: .category)
            status = try container.decode(String.self, forKey: .status)
            title = try container.decode(String.self, forKey: .title)
            desiredOutcome = try container.decodeIfPresent(String.self, forKey: .desiredOutcome)
            why = try container.decodeIfPresent(String.self, forKey: .why)
            successMetric = try container.decodeIfPresent(String.self, forKey: .successMetric)
            priority = try container.decodeIfPresent(Int.self, forKey: .priority)
            sensitivity = try container.decode(String.self, forKey: .sensitivity)
            proactiveVisibility = try container.decode(String.self, forKey: .proactiveVisibility)
            reviewCadence = try container.decode(String.self, forKey: .reviewCadence)
            startsOn = try container.decodeIfPresent(String.self, forKey: .startsOn)
            targetAt = try container.decodeIfPresent(String.self, forKey: .targetAt)
            lastReviewedAt = try container.decodeIfPresent(String.self, forKey: .lastReviewedAt)
            nextReviewAt = try container.decodeIfPresent(String.self, forKey: .nextReviewAt)
            linkedWorkCount = try container.decodeIfPresent(Int.self, forKey: .linkedWorkCount) ?? 0
            linkedPeopleCount = try container.decodeIfPresent(Int.self, forKey: .linkedPeopleCount) ?? 0
            latestProgress = try container.decodeIfPresent(RemoteGoalProgressSummary.self, forKey: .latestProgress)
            progressUpdates = try container.decodeIfPresent([RemoteGoalProgressUpdate].self, forKey: .progressUpdates) ?? []
            links = try container.decodeIfPresent([RemoteGoalLink].self, forKey: .links) ?? []
            reviewRuns = try container.decodeIfPresent([RemoteGoalReviewRun].self, forKey: .reviewRuns) ?? []
            insertedAt = try container.decodeIfPresent(String.self, forKey: .insertedAt)
            updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        }
    }

    struct RemoteGoalProgressSummary: Decodable, Equatable, Sendable {
        let progressState: String?
        let summary: String?
        let occurredAt: String?

        enum CodingKeys: String, CodingKey {
            case progressState = "progress_state"
            case summary
            case occurredAt = "occurred_at"
        }
    }

    struct RemoteGoalProgressUpdate: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let goalID: String
        let source: String
        let summary: String
        let progressState: String
        let confidence: Double?
        let evidence: [String: JSONValue]
        let metadata: [String: JSONValue]
        let occurredAt: String?
        let insertedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case goalID = "goal_id"
            case source
            case summary
            case progressState = "progress_state"
            case confidence
            case evidence
            case metadata
            case occurredAt = "occurred_at"
            case insertedAt = "inserted_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            goalID = try container.decode(String.self, forKey: .goalID)
            source = try container.decode(String.self, forKey: .source)
            summary = try container.decode(String.self, forKey: .summary)
            progressState = try container.decode(String.self, forKey: .progressState)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
            evidence = try container.decodeIfPresent([String: JSONValue].self, forKey: .evidence) ?? [:]
            metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
            occurredAt = try container.decodeIfPresent(String.self, forKey: .occurredAt)
            insertedAt = try container.decodeIfPresent(String.self, forKey: .insertedAt)
        }
    }

    struct RemoteGoalLink: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let goalID: String
        let resourceType: String
        let resourceID: String
        let relationship: String
        let source: String
        let confidence: Double?
        let metadata: [String: JSONValue]
        let insertedAt: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case goalID = "goal_id"
            case resourceType = "resource_type"
            case resourceID = "resource_id"
            case relationship
            case source
            case confidence
            case metadata
            case insertedAt = "inserted_at"
            case updatedAt = "updated_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            goalID = try container.decode(String.self, forKey: .goalID)
            resourceType = try container.decode(String.self, forKey: .resourceType)
            resourceID = try container.decode(String.self, forKey: .resourceID)
            relationship = try container.decode(String.self, forKey: .relationship)
            source = try container.decode(String.self, forKey: .source)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
            metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
            insertedAt = try container.decodeIfPresent(String.self, forKey: .insertedAt)
            updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        }
    }

    struct RemoteGoalReviewRun: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let goalID: String?
        let trigger: String
        let status: String
        let startedAt: String?
        let finishedAt: String?
        let sourceSummary: [String: JSONValue]
        let result: [String: JSONValue]
        let error: [String: JSONValue]
        let metadata: [String: JSONValue]
        let insertedAt: String?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case goalID = "goal_id"
            case trigger
            case status
            case startedAt = "started_at"
            case finishedAt = "finished_at"
            case sourceSummary = "source_summary"
            case result
            case error
            case metadata
            case insertedAt = "inserted_at"
            case updatedAt = "updated_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            goalID = try container.decodeIfPresent(String.self, forKey: .goalID)
            trigger = try container.decode(String.self, forKey: .trigger)
            status = try container.decode(String.self, forKey: .status)
            startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
            finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
            sourceSummary = try container.decodeIfPresent([String: JSONValue].self, forKey: .sourceSummary) ?? [:]
            result = try container.decodeIfPresent([String: JSONValue].self, forKey: .result) ?? [:]
            error = try container.decodeIfPresent([String: JSONValue].self, forKey: .error) ?? [:]
            metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
            insertedAt = try container.decodeIfPresent(String.self, forKey: .insertedAt)
            updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        }
    }

    struct RemoteBrief: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let cadence: String
        let title: String
        let summary: String?
        let body: String?
        let status: String
        let scheduledFor: Date?
        let sentAt: Date?
        let linkedTodoIDs: [String]
        let insertedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case cadence
            case title
            case summary
            case body
            case status
            case scheduledFor = "scheduled_for"
            case sentAt = "sent_at"
            case linkedTodoIDs = "linked_todo_ids"
            case insertedAt = "inserted_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            cadence = try container.decode(String.self, forKey: .cadence)
            title = try container.decode(String.self, forKey: .title)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending"
            scheduledFor = try container.decodeIfPresent(Date.self, forKey: .scheduledFor)
            sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
            linkedTodoIDs = try container.decodeIfPresent([String].self, forKey: .linkedTodoIDs) ?? []
            insertedAt = try container.decodeIfPresent(Date.self, forKey: .insertedAt)
        }

        var referenceDate: Date? {
            scheduledFor ?? insertedAt
        }
    }

    private struct BriefsResponse: Decodable, Sendable {
        let briefs: [RemoteBrief]
    }

    func listBriefs(sessionToken: String, limit: Int = 8) async throws -> [RemoteBrief] {
        let clampedLimit = max(1, min(limit, 30))
        let response: BriefsResponse = try await send(
            path: "/briefs?limit=\(clampedLimit)",
            sessionToken: sessionToken,
            responseType: BriefsResponse.self
        )
        return response.briefs
    }

    struct RemoteRelatedPerson: Decodable, Equatable, Sendable {
        let id: String
        let displayName: String?
        let relationship: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case relationship
        }
    }

    struct RemoteTodoActivity: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let eventType: String
        let actorType: String
        let actorID: String?
        let actorLabel: String?
        let todoID: String?
        let todoTitle: String?
        let todoSource: String?
        let metadata: [String: StringValue]
        let occurredAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case eventType = "event_type"
            case actorType = "actor_type"
            case actorID = "actor_id"
            case actorLabel = "actor_label"
            case todoID = "todo_id"
            case todoTitle = "todo_title"
            case todoSource = "todo_source"
            case metadata
            case occurredAt = "occurred_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            eventType = try container.decode(String.self, forKey: .eventType)
            actorType = try container.decode(String.self, forKey: .actorType)
            actorID = try container.decodeIfPresent(String.self, forKey: .actorID)
            actorLabel = try container.decodeIfPresent(String.self, forKey: .actorLabel)
            todoID = try container.decodeIfPresent(String.self, forKey: .todoID)
            todoTitle = try container.decodeIfPresent(String.self, forKey: .todoTitle)
            todoSource = try container.decodeIfPresent(String.self, forKey: .todoSource)
            metadata = try container.decodeIfPresent([String: StringValue].self, forKey: .metadata) ?? [:]
            occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        }

        init(
            id: String,
            eventType: String,
            actorType: String,
            actorID: String? = nil,
            actorLabel: String? = nil,
            todoID: String? = nil,
            todoTitle: String? = nil,
            todoSource: String? = nil,
            metadata: [String: StringValue] = [:],
            occurredAt: Date
        ) {
            self.id = id
            self.eventType = eventType
            self.actorType = actorType
            self.actorID = actorID
            self.actorLabel = actorLabel
            self.todoID = todoID
            self.todoTitle = todoTitle
            self.todoSource = todoSource
            self.metadata = metadata
            self.occurredAt = occurredAt
        }
    }

    struct RemoteActionCard: Decodable, Equatable, Sendable {
        struct ContextItem: Decodable, Equatable, Sendable {
            let label: String?
            let value: String?
        }

        struct SourceAction: Decodable, Equatable, Sendable {
            let provider: String?
            let providerLabel: String?
            let openURL: String?
            let openLabel: String?
            let draftText: String?
            let draftKind: String?
            let recipient: String?
            let recipientHandle: String?
            let subject: String?
            let participants: [CardParticipant]
            let conversation: [CardConversationMessage]

            enum CodingKeys: String, CodingKey {
                case provider
                case providerLabel = "provider_label"
                case openURL = "open_url"
                case openLabel = "open_label"
                case draftText = "draft_text"
                case draftKind = "draft_kind"
                case recipient
                case recipientHandle = "recipient_handle"
                case subject
                case participants
                case conversation
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                provider = try container.decodeIfPresent(String.self, forKey: .provider)
                providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel)
                openURL = try container.decodeIfPresent(String.self, forKey: .openURL)
                openLabel = try container.decodeIfPresent(String.self, forKey: .openLabel)
                draftText = try container.decodeIfPresent(String.self, forKey: .draftText)
                draftKind = try container.decodeIfPresent(String.self, forKey: .draftKind)
                recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
                recipientHandle = try container.decodeIfPresent(String.self, forKey: .recipientHandle)
                subject = try container.decodeIfPresent(String.self, forKey: .subject)
                participants = try container.decodeIfPresent([CardParticipant].self, forKey: .participants) ?? []
                conversation = try container.decodeIfPresent([CardConversationMessage].self, forKey: .conversation) ?? []
            }
        }

        let headline: String?
        let decisionPrompt: String?
        let contextItems: [ContextItem]
        let whyNow: String?
        let rankReason: String?
        let attentionMode: String?
        let sourceContext: String?
        let nextBestAction: String?
        let draftPreview: String?
        let evidenceExcerpt: String?
        let estimatedEffort: String?
        let sourceAction: SourceAction?

        enum CodingKeys: String, CodingKey {
            case headline
            case decisionPrompt = "decision_prompt"
            case contextItems = "context_items"
            case whyNow = "why_now"
            case rankReason = "rank_reason"
            case attentionMode = "attention_mode"
            case sourceContext = "source_context"
            case nextBestAction = "next_best_action"
            case draftPreview = "draft_preview"
            case evidenceExcerpt = "evidence_excerpt"
            case estimatedEffort = "estimated_effort"
            case sourceAction = "source_action"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            headline = try container.decodeIfPresent(String.self, forKey: .headline)
            decisionPrompt = try container.decodeIfPresent(String.self, forKey: .decisionPrompt)
            contextItems = try container.decodeIfPresent([ContextItem].self, forKey: .contextItems) ?? []
            whyNow = try container.decodeIfPresent(String.self, forKey: .whyNow)
            rankReason = try container.decodeIfPresent(String.self, forKey: .rankReason)
            attentionMode = try container.decodeIfPresent(String.self, forKey: .attentionMode)
            sourceContext = try container.decodeIfPresent(String.self, forKey: .sourceContext)
            nextBestAction = try container.decodeIfPresent(String.self, forKey: .nextBestAction)
            draftPreview = try container.decodeIfPresent(String.self, forKey: .draftPreview)
            evidenceExcerpt = try container.decodeIfPresent(String.self, forKey: .evidenceExcerpt)
            estimatedEffort = try container.decodeIfPresent(String.self, forKey: .estimatedEffort)
            sourceAction = try container.decodeIfPresent(SourceAction.self, forKey: .sourceAction)
        }

        init(
            headline: String? = nil,
            decisionPrompt: String? = nil,
            contextItems: [ContextItem] = [],
            whyNow: String? = nil,
            rankReason: String? = nil,
            attentionMode: String? = nil,
            sourceContext: String? = nil,
            nextBestAction: String? = nil,
            draftPreview: String? = nil,
            evidenceExcerpt: String? = nil,
            estimatedEffort: String? = nil,
            sourceAction: SourceAction? = nil
        ) {
            self.headline = headline
            self.decisionPrompt = decisionPrompt
            self.contextItems = contextItems
            self.whyNow = whyNow
            self.rankReason = rankReason
            self.attentionMode = attentionMode
            self.sourceContext = sourceContext
            self.nextBestAction = nextBestAction
            self.draftPreview = draftPreview
            self.evidenceExcerpt = evidenceExcerpt
            self.estimatedEffort = estimatedEffort
            self.sourceAction = sourceAction
        }
    }

    struct RemotePerson: Decodable, Equatable, Sendable {
        let id: String
        let displayName: String
        let contactDetails: [String: [String]]
        let relationship: String?
        let status: String
        let notes: String?
        let metadata: [String: StringValue]
        let lastInteractionAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case contactDetails = "contact_details"
            case relationship
            case status
            case notes
            case metadata
            case lastInteractionAt = "last_interaction_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decode(String.self, forKey: .displayName)
            relationship = try container.decodeIfPresent(String.self, forKey: .relationship)
            status = try container.decode(String.self, forKey: .status)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            metadata = try container.decodeIfPresent([String: StringValue].self, forKey: .metadata) ?? [:]
            lastInteractionAt = try container.decodeIfPresent(Date.self, forKey: .lastInteractionAt)

            let flexibleDetails = try container.decodeIfPresent(
                [String: FlexibleStringArray].self,
                forKey: .contactDetails
            ) ?? [:]
            contactDetails = flexibleDetails.mapValues(\.values)
        }
    }

    struct FlexibleStringArray: Decodable, Equatable, Sendable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let values = try? container.decode([String].self) {
                self.values = values
            } else if let value = try? container.decode(String.self), !value.isEmpty {
                self.values = [value]
            } else {
                self.values = []
            }
        }
    }

    enum StringValue: Decodable, Equatable, Sendable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(Double.self) {
                self = .double(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .string("")
            }
        }

        var string: String? {
            switch self {
            case .string(let value): value
            case .int(let value): String(value)
            case .double(let value): String(value)
            case .bool(let value): String(value)
            }
        }

        var decimal: Decimal? {
            switch self {
            case .string(let value): Decimal(string: value)
            case .int(let value): Decimal(value)
            case .double(let value): Decimal(value)
            case .bool: nil
            }
        }
    }

    let baseURL: URL
    let session: URLSession

    /// Shared session with bounded timeouts so a slow or hung request never leaves the
    /// UI spinning indefinitely (the default `.shared` request timeout is 60s).
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL = AppConfiguration.mobileAPIBaseURL, session: URLSession = MobileAPIClient.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func requestMagicLink(email: String) async throws -> MagicLinkResponse {
        try await send(
            path: "/auth/magic-link",
            method: "POST",
            body: ["email": .string(email)],
            responseType: MagicLinkResponse.self
        )
    }

    func consumeMagicLink(token: String) async throws -> AuthResponse {
        try await send(
            path: "/auth/magic/\(token)",
            method: "POST",
            responseType: AuthResponse.self
        )
    }

    func consumeMagicCode(code: String) async throws -> AuthResponse {
        try await send(
            path: "/auth/magic-code",
            method: "POST",
            body: ["code": .string(code)],
            responseType: AuthResponse.self
        )
    }

    func me(sessionToken: String) async throws -> MeResponse {
        try await send(path: "/me", sessionToken: sessionToken, responseType: MeResponse.self)
    }

    func signOut(sessionToken: String) async throws {
        let _: EmptyResponse = try await send(
            path: "/session",
            method: "DELETE",
            sessionToken: sessionToken,
            responseType: EmptyResponse.self
        )
    }

    struct IdentityResponse: Decodable, Sendable {
        struct Identity: Decodable, Sendable, Identifiable {
            let confirmed: Bool
            let displayName: String?
            let emails: [String]
            let phones: [String]

            var id: String {
                ([displayName ?? ""] + emails + phones).joined(separator: "|")
            }

            enum CodingKeys: String, CodingKey {
                case confirmed
                case displayName = "display_name"
                case emails
                case phones
            }
        }

        let identity: Identity
    }

    func getIdentity(sessionToken: String) async throws -> IdentityResponse.Identity {
        let response: IdentityResponse = try await send(
            path: "/identity",
            sessionToken: sessionToken,
            responseType: IdentityResponse.self
        )
        return response.identity
    }

    func confirmIdentity(
        sessionToken: String,
        displayName: String?,
        emails: [String],
        phones: [String]
    ) async throws -> IdentityResponse.Identity {
        let response: IdentityResponse = try await send(
            path: "/identity",
            method: "PUT",
            sessionToken: sessionToken,
            body: [
                "display_name": .string(displayName ?? ""),
                "emails": .array(emails.map { .string($0) }),
                "phones": .array(phones.map { .string($0) })
            ],
            responseType: IdentityResponse.self
        )
        return response.identity
    }

    func listTodos(sessionToken: String, includeCards: Bool = true) async throws -> [RemoteTodo] {
        try await listTodos(sessionToken: sessionToken, includeCards: includeCards, conditional: false).todos
    }

    /// Fetches the full todos collection page by page.
    ///
    /// When `conditional` is true the first page carries `If-None-Match`; a 304
    /// there means the whole collection is unchanged and
    /// `MobileAPIError.notModified` is thrown. Follow-up pages are never
    /// conditional. Old servers that lack pagination return no `pagination`
    /// key; that single response is treated as the complete set.
    func listTodos(
        sessionToken: String,
        includeCards: Bool,
        conditional: Bool
    ) async throws -> TodoListing {
        let pageSize = 500
        // Hard cap keeps a misbehaving endpoint (e.g. one that ignores offset)
        // from looping forever; 10 pages x 500 is far beyond any real queue.
        let maxPages = 10
        var offset = 0
        var todos: [RemoteTodo] = []

        for page in 0..<maxPages {
            try Task.checkCancellation()

            // Keep pagination compatible with old servers. The card scope is
            // opt-in so older app builds retain full closed-item context.
            let offsetQuery = offset > 0 ? "&offset=\(offset)" : ""
            let cardScopeQuery = includeCards ? "&open_cards_only=true" : ""
            let response: TodosResponse = try await send(
                path: "/todos?limit=\(pageSize)\(offsetQuery)&status=all&sort=rank&dir=desc&include_cards=\(includeCards)\(cardScopeQuery)",
                sessionToken: sessionToken,
                etagKey: (conditional && page == 0) ? ETagKey.todos(includeCards: includeCards) : nil,
                responseType: TodosResponse.self
            )

            todos.append(contentsOf: response.todos)

            // No pagination object -> old server; the response is the full set.
            guard response.pagination != nil else {
                return TodoListing(todos: todos, isComplete: true)
            }

            if response.todos.count < pageSize {
                return TodoListing(todos: todos, isComplete: true)
            }

            offset += pageSize
        }

        return TodoListing(todos: todos, isComplete: false)
    }

    func listGoals(
        sessionToken: String,
        status: String = "active",
        category: String = "all",
        query: String? = nil,
        limit: Int = 200
    ) async throws -> [RemoteGoal] {
        let clampedLimit = max(1, min(limit, 200))
        var queryItems = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "limit", value: String(clampedLimit))
        ]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        let response: GoalsResponse = try await send(
            path: Self.path("/goals", queryItems: queryItems),
            sessionToken: sessionToken,
            responseType: GoalsResponse.self
        )
        return response.goals
    }

    func getGoal(sessionToken: String, id: String) async throws -> RemoteGoal {
        let response: GoalResponse = try await send(
            path: "/goals/\(id)",
            sessionToken: sessionToken,
            responseType: GoalResponse.self
        )
        return response.goal
    }

    func createGoal(sessionToken: String, payload: RequestBody) async throws -> RemoteGoal {
        let response: GoalResponse = try await send(
            path: "/goals",
            method: "POST",
            sessionToken: sessionToken,
            body: ["goal": .object(payload)],
            responseType: GoalResponse.self
        )
        return response.goal
    }

    func updateGoal(sessionToken: String, id: String, payload: RequestBody) async throws -> RemoteGoal {
        let response: GoalResponse = try await send(
            path: "/goals/\(id)",
            method: "PATCH",
            sessionToken: sessionToken,
            body: ["goal": .object(payload)],
            responseType: GoalResponse.self
        )
        return response.goal
    }

    func archiveGoal(sessionToken: String, id: String) async throws -> RemoteGoal {
        let response: GoalResponse = try await send(
            path: "/goals/\(id)",
            method: "DELETE",
            sessionToken: sessionToken,
            responseType: GoalResponse.self
        )
        return response.goal
    }

    func recordGoalProgress(
        sessionToken: String,
        goalID: String,
        payload: RequestBody
    ) async throws -> RemoteGoalProgressUpdate {
        let response: GoalProgressResponse = try await send(
            path: "/goals/\(goalID)/progress",
            method: "POST",
            sessionToken: sessionToken,
            body: ["progress": .object(payload)],
            responseType: GoalProgressResponse.self
        )
        return response.progressUpdate
    }

    func reviewGoal(sessionToken: String, goalID: String) async throws -> RemoteGoalReviewRun {
        let response: GoalReviewRunResponse = try await send(
            path: "/goals/\(goalID)/review",
            method: "POST",
            sessionToken: sessionToken,
            responseType: GoalReviewRunResponse.self
        )
        return response.reviewRun
    }

    func listTodoActivity(sessionToken: String, limit: Int = 100) async throws -> [RemoteTodoActivity] {
        let clampedLimit = max(1, min(limit, 200))
        let response: TodoActivityResponse = try await send(
            path: "/todo-activity?limit=\(clampedLimit)",
            sessionToken: sessionToken,
            responseType: TodoActivityResponse.self
        )
        return response.activity
    }

    func createTodo(sessionToken: String, payload: RequestBody) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos?include_cards=true",
            method: "POST",
            sessionToken: sessionToken,
            body: ["todo": .object(payload)],
            responseType: TodoResponse.self
        )
        return response.todo
    }

    func updateTodo(sessionToken: String, id: UUID, payload: RequestBody) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos/\(id.uuidString.lowercased())?include_cards=true",
            method: "PATCH",
            sessionToken: sessionToken,
            body: ["todo": .object(payload)],
            responseType: TodoResponse.self
        )
        return response.todo
    }

    func markTodoOpened(sessionToken: String, id: UUID) async throws {
        let _: AcknowledgementResponse = try await send(
            path: "/todos/\(id.uuidString.lowercased())/opened",
            method: "POST",
            sessionToken: sessionToken,
            responseType: AcknowledgementResponse.self
        )
    }

    func sendTodoReply(
        sessionToken: String,
        id: UUID,
        subject: String?,
        body: String
    ) async throws -> TodoReplyResponse {
        var payload: RequestBody = ["body": .string(body)]
        if let subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["subject"] = .string(subject)
        }

        return try await send(
            path: "/todos/\(id.uuidString.lowercased())/reply",
            method: "POST",
            sessionToken: sessionToken,
            body: payload,
            responseType: TodoReplyResponse.self
        )
    }

    func performTodoAction(
        sessionToken: String,
        id: UUID,
        action: String,
        snoozedUntil: Date? = nil,
        note: String? = nil
    ) async throws -> RemoteTodo {
        var body: RequestBody = [:]
        if let snoozedUntil {
            body["snoozed_until"] = .string(Self.iso8601.format(snoozedUntil))
        }
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["note"] = .string(note)
        }

        let response: TodoActionResponse = try await send(
            path: "/todos/\(id.uuidString.lowercased())/actions/\(action)?include_cards=true",
            method: "POST",
            sessionToken: sessionToken,
            body: body,
            responseType: TodoActionResponse.self
        )
        return response.todo
    }

    func deleteTodo(sessionToken: String, id: UUID) async throws -> RemoteTodo {
        let response: TodoResponse = try await send(
            path: "/todos/\(id.uuidString.lowercased())",
            method: "DELETE",
            sessionToken: sessionToken,
            responseType: TodoResponse.self
        )
        return response.todo
    }

    /// Fetches the full people collection page by page. When `conditional` is
    /// true the first page carries `If-None-Match`; a 304 there means the whole
    /// collection is unchanged and `MobileAPIError.notModified` is thrown.
    func listPeople(sessionToken: String, conditional: Bool = false) async throws -> [RemotePerson] {
        let pageSize = 500
        // Hard cap keeps a misbehaving endpoint (e.g. one that ignores offset)
        // from looping forever; 20 pages x 500 is far beyond any real CRM here.
        let maxPages = 20
        var offset = 0
        var people: [RemotePerson] = []

        for page in 0..<maxPages {
            try Task.checkCancellation()

            let response: PeopleResponse = try await send(
                path: "/people?limit=\(pageSize)&offset=\(offset)&status=all",
                sessionToken: sessionToken,
                etagKey: (conditional && page == 0) ? ETagKey.people : nil,
                responseType: PeopleResponse.self
            )

            people.append(contentsOf: response.people)

            if response.people.count < pageSize {
                break
            }

            offset += pageSize
        }

        return people
    }

    func reconnectSuggestions(
        sessionToken: String,
        limit: Int = 12
    ) async throws -> [RemoteReconnectSuggestion] {
        let response: ReconnectResponse = try await send(
            path: "/people/reconnect?limit=\(limit)",
            sessionToken: sessionToken,
            responseType: ReconnectResponse.self
        )
        return response.suggestions
    }

    func createPerson(sessionToken: String, payload: RequestBody) async throws -> RemotePerson {
        let response: PersonResponse = try await send(
            path: "/people",
            method: "POST",
            sessionToken: sessionToken,
            body: ["person": .object(payload)],
            responseType: PersonResponse.self
        )
        return response.person
    }

    func updatePerson(sessionToken: String, id: UUID, payload: RequestBody) async throws -> RemotePerson {
        let response: PersonResponse = try await send(
            path: "/people/\(id.uuidString.lowercased())",
            method: "PATCH",
            sessionToken: sessionToken,
            body: ["person": .object(payload)],
            responseType: PersonResponse.self
        )
        return response.person
    }

    func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        sessionToken: String? = nil,
        body: RequestBody? = nil,
        etagKey: String? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        let baseString = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString
            : baseURL.absoluteString + "/"
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let base = URL(string: baseString),
              let url = URL(string: relativePath, relativeTo: base)?.absoluteURL
        else {
            throw MobileAPIError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MaraithonMobile/1.0", forHTTPHeaderField: "User-Agent")

        if let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        if let etagKey, let etag = ETagStore.shared.etag(for: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            // We do our own revalidation; URLCache must not answer the
            // conditional request from a cached 200 behind our back.
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(JSONValue.object(body))
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MobileAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            if let etagKey {
                // Store the fresh validator; a 200 without one means the
                // server stopped supporting ETags, so drop the stale value
                // instead of replaying it forever.
                ETagStore.shared.set(httpResponse.value(forHTTPHeaderField: "ETag"), for: etagKey)
            }
            // 204-style responses carry no body; any all-optional/empty
            // Decodable should succeed rather than choking on zero bytes.
            if data.isEmpty, let empty = try? Self.decoder.decode(Response.self, from: Data("{}".utf8)) {
                return empty
            }
            return try Self.decoder.decode(Response.self, from: data)
        case 304:
            throw MobileAPIError.notModified
        case 401:
            // The session is gone; stored validators belong to it and must not
            // survive into the next sign-in. Full sign-out clearing can
            // piggyback on SessionStore later, but this covers the forced
            // sign-out path today.
            Self.clearETags()
            Task { @MainActor in
                MobileAPIClient.unauthorizedHandler?()
            }
            throw MobileAPIError.unauthorized
        default:
            if let error = try? Self.decoder.decode(ServerError.self, from: data) {
                if let message = error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty
                {
                    throw MobileAPIError.serverResponse(
                        code: error.error ?? "request_failed",
                        message: message
                    )
                }

                if let code = error.error {
                    throw MobileAPIError.server(code)
                }
            }

            throw MobileAPIError.server("request_failed")
        }
    }

    private static let encoder = JSONEncoder()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date.")
        }
        return decoder
    }()

    private struct ServerError: Decodable, Sendable {
        let error: String?
        let message: String?
    }

    private struct EmptyResponse: Decodable, Sendable {
        init() {}
    }

    nonisolated private static func path(_ path: String, queryItems: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = queryItems
        return components.string ?? path
    }

    private static let iso8601WithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    nonisolated static func date(from value: String) -> Date? {
        if let date = try? iso8601WithFractionalSeconds.parse(value) {
            return date
        }

        if let date = try? iso8601.parse(value) {
            return date
        }

        guard !hasExplicitTimeZone(value) else { return nil }
        let utcValue = value + "Z"

        if let date = try? iso8601WithFractionalSeconds.parse(utcValue) {
            return date
        }

        return try? iso8601.parse(utcValue)
    }

    nonisolated private static func hasExplicitTimeZone(_ value: String) -> Bool {
        value.hasSuffix("Z") ||
            value.range(of: #"[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil
    }
}
