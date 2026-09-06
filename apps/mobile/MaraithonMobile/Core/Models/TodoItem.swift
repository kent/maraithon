import Foundation
import SwiftData

@Model
final class TodoItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var nextAction: String?
    var priorityRawValue: String
    var dueDate: Date?
    var isCompleted: Bool
    /// Optional raw values preserve lightweight migration for existing stores.
    /// `status` falls back to the legacy completion flag until the first sync.
    var statusRawValue: String?
    var attentionModeRawValue: String?
    var kindRawValue: String?
    var snoozedUntil: Date?
    var createdAt: Date
    /// Nonoptional default keeps the additive field eligible for SwiftData's
    /// lightweight migration; the first v2 todo sync backfills server time.
    var updatedAt: Date = Date()
    var completedAt: Date?
    /// Optional for lightweight migration; refreshed from public todo metadata.
    var resolutionNote: String?
    var decisionPrompt: String?
    var decisionContextSummary: String?
    var whyNow: String?
    var sourceContext: String?
    var nextBestAction: String?
    var draftPreview: String?
    var evidenceExcerpt: String?
    var cardHeadline: String?
    var rankReason: String?
    var estimatedEffort: String?
    var actionPlan: String?
    var ownerLabel: String?
    var sourceOccurredAt: Date?
    var todoBriefData: Data?
    var sourceSystem: String?
    var sourceProvider: String?
    var sourceProviderLabel: String?
    var sourceOpenURLString: String?
    var sourceOpenLabel: String?
    var draftText: String?
    var draftKind: String?
    var draftRecipient: String?
    var draftRecipientHandle: String?
    var sourceSubject: String?
    var sourceContextData: Data?
    @Relationship(deleteRule: .nullify, inverse: \CRMContact.todos) var contact: CRMContact?

    var priority: TodoPriority {
        get { TodoPriority(rawValue: priorityRawValue) ?? .medium }
        set { priorityRawValue = newValue.rawValue }
    }

    var status: TodoStatus {
        get {
            if isCompleted { return .done }
            return TodoStatus(rawValue: statusRawValue ?? "") ?? .open
        }
        set {
            statusRawValue = newValue.rawValue
            isCompleted = newValue == .done
        }
    }

    var attentionMode: TodoAttentionMode {
        get { TodoAttentionMode(rawValue: attentionModeRawValue ?? "") ?? .actNow }
        set { attentionModeRawValue = newValue.rawValue }
    }

    var isActive: Bool {
        status == .open || status == .snoozed
    }

    var needsActionNow: Bool {
        status == .open && attentionMode == .actNow
    }

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        nextAction: String? = nil,
        priority: TodoPriority = .medium,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        status: TodoStatus? = nil,
        attentionMode: TodoAttentionMode = .actNow,
        kind: String? = nil,
        snoozedUntil: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        resolutionNote: String? = nil,
        decisionPrompt: String? = nil,
        decisionContextSummary: String? = nil,
        whyNow: String? = nil,
        sourceContext: String? = nil,
        nextBestAction: String? = nil,
        draftPreview: String? = nil,
        evidenceExcerpt: String? = nil,
        cardHeadline: String? = nil,
        rankReason: String? = nil,
        estimatedEffort: String? = nil,
        actionPlan: String? = nil,
        ownerLabel: String? = nil,
        sourceOccurredAt: Date? = nil,
        todoBriefData: Data? = nil,
        sourceSystem: String? = nil,
        sourceProvider: String? = nil,
        sourceProviderLabel: String? = nil,
        sourceOpenURLString: String? = nil,
        sourceOpenLabel: String? = nil,
        draftText: String? = nil,
        draftKind: String? = nil,
        draftRecipient: String? = nil,
        draftRecipientHandle: String? = nil,
        sourceSubject: String? = nil,
        sourceContextData: Data? = nil,
        contact: CRMContact? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.nextAction = nextAction
        self.priorityRawValue = priority.rawValue
        self.dueDate = dueDate
        self.isCompleted = status == .done || isCompleted
        self.statusRawValue = (status ?? (isCompleted ? .done : .open)).rawValue
        self.attentionModeRawValue = attentionMode.rawValue
        self.kindRawValue = kind
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.resolutionNote = resolutionNote
        self.decisionPrompt = decisionPrompt
        self.decisionContextSummary = decisionContextSummary
        self.whyNow = whyNow
        self.sourceContext = sourceContext
        self.nextBestAction = nextBestAction
        self.draftPreview = draftPreview
        self.evidenceExcerpt = evidenceExcerpt
        self.cardHeadline = cardHeadline
        self.rankReason = rankReason
        self.estimatedEffort = estimatedEffort
        self.actionPlan = actionPlan
        self.ownerLabel = ownerLabel
        self.sourceOccurredAt = sourceOccurredAt
        self.todoBriefData = todoBriefData
        self.sourceSystem = sourceSystem
        self.sourceProvider = sourceProvider
        self.sourceProviderLabel = sourceProviderLabel
        self.sourceOpenURLString = sourceOpenURLString
        self.sourceOpenLabel = sourceOpenLabel
        self.draftText = draftText
        self.draftKind = draftKind
        self.draftRecipient = draftRecipient
        self.draftRecipientHandle = draftRecipientHandle
        self.sourceSubject = sourceSubject
        self.sourceContextData = sourceContextData
        self.contact = contact
    }

    var sourceAction: TodoSourceAction? {
        let context = storedSourceContext
        let action = TodoSourceAction(
            provider: sourceProvider,
            providerLabel: sourceProviderLabel,
            openURLString: sourceOpenURLString,
            openLabel: sourceOpenLabel,
            draftText: isActive ? draftText : nil,
            draftKind: isActive ? draftKind : nil,
            recipient: draftRecipient,
            recipientHandle: draftRecipientHandle,
            subject: sourceSubject,
            participants: context?.participants ?? [],
            conversation: context?.conversation ?? []
        )
        return action.isEmpty ? nil : action
    }

    /// Memoizes the decoded source-context payload; `sourceAction` reads it on
    /// every row render. The box keeps cache writes off observed properties and
    /// self-invalidates when `sourceContextData` changes.
    @Transient private var sourceContextCache = DecodedSourceContextCache()

    /// `JSONDecoder` is stateless after configuration and safe to share.
    private static let sourceContextDecoder = JSONDecoder()

    var storedSourceContext: TodoStoredSourceContext? {
        guard let sourceContextData else { return nil }

        if sourceContextCache.raw == sourceContextData {
            return sourceContextCache.decoded
        }

        let decoded = try? Self.sourceContextDecoder.decode(TodoStoredSourceContext.self, from: sourceContextData)
        sourceContextCache.raw = sourceContextData
        sourceContextCache.decoded = decoded
        return decoded
    }

    @Transient private var todoBriefCache = DecodedTodoBriefCache()

    private static let todoBriefDecoder = JSONDecoder()

    var todoBrief: TodoBriefSnapshot? {
        guard let todoBriefData else { return nil }

        if todoBriefCache.raw == todoBriefData {
            return todoBriefCache.decoded
        }

        let decoded = try? Self.todoBriefDecoder.decode(TodoBriefSnapshot.self, from: todoBriefData)
        todoBriefCache.raw = todoBriefData
        todoBriefCache.decoded = decoded
        return decoded
    }

    func setSourceContext(participants: [CardParticipant], conversation: [CardConversationMessage]) {
        if participants.isEmpty && conversation.isEmpty {
            sourceContextData = nil
            return
        }

        sourceContextData = try? JSONEncoder().encode(
            TodoStoredSourceContext(participants: participants, conversation: conversation)
        )
    }

    var displayNextAction: String? {
        guard let action = nextAction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !action.isEmpty else {
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if action.caseInsensitiveCompare(trimmedTitle) == .orderedSame ||
            action.caseInsensitiveCompare(trimmedNotes) == .orderedSame {
            return nil
        }

        return action
    }

    func setCompleted(_ completed: Bool, at date: Date = Date()) {
        status = completed ? .done : .open
        completedAt = completed ? date : nil
        snoozedUntil = nil
        updatedAt = date
    }
}

/// Per-instance memo for the decoded `sourceContextData` payload. A
/// reference-type box keeps cache writes off the model's observed properties.
private final class DecodedSourceContextCache {
    var raw: Data?
    var decoded: TodoStoredSourceContext?
}

private final class DecodedTodoBriefCache {
    var raw: Data?
    var decoded: TodoBriefSnapshot?
}

/// Codable bundle persisted on TodoItem for participants + conversation.
struct TodoStoredSourceContext: Codable, Equatable, Sendable {
    var participants: [CardParticipant] = []
    var conversation: [CardConversationMessage] = []
}
