import Foundation
import SwiftData

@MainActor
enum ProductionDataSync {
    static func refreshAll(
        sessionStore: SessionStore,
        modelContext: ModelContext,
        includeCards: Bool = true,
        force: Bool = false
    ) async throws {
        // People enrich todo rows, but Today's core freshness is the work queue.
        // Do not let a relationship refresh hiccup block the todo refresh and
        // surface a stale-data warning for the whole screen.
        try? await refreshPeople(sessionStore: sessionStore, modelContext: modelContext, force: force)
        try await refreshTodos(
            sessionStore: sessionStore,
            modelContext: modelContext,
            includeCards: includeCards,
            force: force
        )
    }

    static func refreshTodos(
        sessionStore: SessionStore,
        modelContext: ModelContext,
        includeCards: Bool = true,
        force: Bool = false
    ) async throws {
        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        // The first page supplies a validator for the entire collection. Keep it
        // only after every page has been fetched and the local merge is saved;
        // otherwise a later 304 could hide an interrupted sync indefinitely.
        var keepValidator = false
        defer {
            if !keepValidator {
                ETagStore.shared.set(nil, for: MobileAPIClient.ETagKey.todos(includeCards: includeCards))
            }
        }

        let listing: MobileAPIClient.TodoListing
        do {
            listing = try await MobileAPIClient().listTodos(
                sessionToken: sessionToken,
                includeCards: includeCards,
                conditional: !force
            )
        } catch MobileAPIError.notModified {
            // The server vouched the collection is unchanged; skip the merge
            // and the save entirely.
            keepValidator = true
            return
        }
        let remoteTodos = listing.todos

        // All regex-heavy string cleaning runs off the main actor; the loop
        // below only assigns precomputed values to @Model objects.
        let preparedTodos = await Task.detached(priority: .userInitiated) {
            prepare(remoteTodos)
        }.value

        let localTodos = try modelContext.fetch(FetchDescriptor<TodoItem>())
        let localByID = Dictionary(localTodos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localContacts = try modelContext.fetch(FetchDescriptor<CRMContact>())
        let contactsByID = Dictionary(localContacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenRemoteIDs = Set<UUID>()

        for prepared in preparedTodos {
            seenRemoteIDs.insert(prepared.id)

            guard prepared.keep else {
                if let todo = localByID[prepared.id] {
                    modelContext.delete(todo)
                }
                continue
            }

            if let todo = localByID[prepared.id] {
                apply(prepared, to: todo, includeCards: includeCards, contactsByID: contactsByID)
            } else {
                modelContext.insert(todoItem(from: prepared, contactsByID: contactsByID))
            }
        }

        // Reconcile deletions only against a complete listing; a capped
        // (truncated) listing may omit live remote rows.
        if listing.isComplete {
            for todo in localTodos where !seenRemoteIDs.contains(todo.id) {
                modelContext.delete(todo)
            }
        }

        try modelContext.save()
        keepValidator = listing.isComplete
    }

    static func refreshPeople(
        sessionStore: SessionStore,
        modelContext: ModelContext,
        force: Bool = false
    ) async throws {
        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        let remotePeople: [MobileAPIClient.RemotePerson]
        do {
            remotePeople = try await MobileAPIClient().listPeople(
                sessionToken: sessionToken,
                conditional: !force
            )
        } catch MobileAPIError.notModified {
            return
        }
        let localContacts = try modelContext.fetch(FetchDescriptor<CRMContact>())
        let localByID = Dictionary(localContacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenRemoteIDs = Set<UUID>()

        for remotePerson in remotePeople {
            guard let id = UUID(uuidString: remotePerson.id) else { continue }
            seenRemoteIDs.insert(id)
            if let contact = localByID[id] {
                apply(remotePerson, to: contact)
            } else {
                modelContext.insert(contact(from: remotePerson, id: id))
            }
        }

        for contact in localContacts where !seenRemoteIDs.contains(contact.id) {
            modelContext.delete(contact)
        }

        try modelContext.save()
    }

    /// Snapshot of a remote todo with every string already cleaned. Built off
    /// the main actor so the MainActor merge loop only assigns values.
    struct PreparedTodo: Sendable {
        let id: UUID
        let keep: Bool
        let title: String
        let notes: String
        let nextAction: String?
        let priority: TodoPriority
        let dueDate: Date?
        let isCompleted: Bool
        let status: TodoStatus
        let attentionMode: TodoAttentionMode
        let kind: String?
        let snoozedUntil: Date?
        let createdAt: Date?
        let updatedAt: Date?
        let completedAt: Date?
        let actionPlan: String?
        let ownerLabel: String?
        let sourceOccurredAt: Date?
        let todoBriefData: Data?
        let hasActionCardField: Bool
        let relatedPersonIDs: [UUID]
        let sourceSystem: String?
        let card: PreparedCard
    }

    struct PreparedCard: Sendable {
        let headline: String?
        let decisionPrompt: String?
        let decisionContextSummary: String?
        let whyNow: String?
        let rankReason: String?
        let sourceContext: String?
        let nextBestAction: String?
        let draftPreview: String?
        let evidenceExcerpt: String?
        let estimatedEffort: String?
        let sourceProvider: String?
        let sourceProviderLabel: String?
        let sourceOpenURLString: String?
        let sourceOpenLabel: String?
        let draftText: String?
        let draftKind: String?
        let draftRecipient: String?
        let draftRecipientHandle: String?
        let sourceSubject: String?
        let sourceContextData: Data?
    }

    /// Performs ALL string cleaning (the regex-heavy ChiefOfStaffCopy passes)
    /// for a page of remote todos. Nonisolated so callers can run it off the
    /// main actor before handing the results to the MainActor merge.
    nonisolated static func prepare(_ remoteTodos: [MobileAPIClient.RemoteTodo]) -> [PreparedTodo] {
        remoteTodos.compactMap { remoteTodo in
            UUID(uuidString: remoteTodo.id).map { prepare(remoteTodo, id: $0) }
        }
    }

    nonisolated static func prepare(_ remoteTodo: MobileAPIClient.RemoteTodo, id: UUID) -> PreparedTodo {
        let status = TodoStatus(rawValue: remoteTodo.status) ?? .open
        let attentionMode = TodoAttentionMode(
            rawValue: remoteTodo.attentionMode ?? remoteTodo.actionCard?.attentionMode ?? ""
        ) ?? .actNow

        return PreparedTodo(
            id: id,
            keep: shouldKeepRemoteTodo(remoteTodo),
            title: remoteTodo.title,
            notes: remoteTodo.notes ?? remoteTodo.summary ?? "",
            nextAction: remoteTodo.nextAction,
            priority: priority(from: remoteTodo.priority),
            dueDate: remoteTodo.dueAt,
            isCompleted: status == .done,
            status: status,
            attentionMode: attentionMode,
            kind: cleanedText(remoteTodo.kind),
            snoozedUntil: remoteTodo.snoozedUntil,
            createdAt: remoteTodo.insertedAt,
            updatedAt: remoteTodo.updatedAt,
            completedAt: remoteTodo.closedAt,
            actionPlan: cleanedText(remoteTodo.actionPlan),
            ownerLabel: cleanedText(remoteTodo.ownerLabel),
            sourceOccurredAt: remoteTodo.sourceOccurredAt,
            todoBriefData: encodedBrief(remoteTodo.brief),
            hasActionCardField: remoteTodo.hasActionCardField,
            relatedPersonIDs: remoteTodo.relatedPeople.compactMap { UUID(uuidString: $0.id) },
            sourceSystem: cleanedText(remoteTodo.source),
            card: preparedCard(from: remoteTodo.actionCard)
        )
    }

    nonisolated private static func preparedCard(
        from actionCard: MobileAPIClient.RemoteActionCard?
    ) -> PreparedCard {
        PreparedCard(
            headline: cleanedText(actionCard?.headline),
            decisionPrompt: cleanedText(actionCard?.decisionPrompt),
            decisionContextSummary: actionCardContextSummary(actionCard),
            whyNow: cleanedText(actionCard?.whyNow),
            rankReason: cleanedText(actionCard?.rankReason),
            sourceContext: cleanedText(actionCard?.sourceContext),
            nextBestAction: cleanedText(actionCard?.nextBestAction),
            draftPreview: cleanedText(actionCard?.draftPreview),
            evidenceExcerpt: cleanedText(actionCard?.evidenceExcerpt),
            estimatedEffort: cleanedText(actionCard?.estimatedEffort),
            sourceProvider: cleanedText(actionCard?.sourceAction?.provider),
            sourceProviderLabel: cleanedText(actionCard?.sourceAction?.providerLabel),
            sourceOpenURLString: cleanedText(actionCard?.sourceAction?.openURL),
            sourceOpenLabel: cleanedText(actionCard?.sourceAction?.openLabel),
            draftText: cleanedText(actionCard?.sourceAction?.draftText),
            draftKind: cleanedText(actionCard?.sourceAction?.draftKind),
            draftRecipient: cleanedText(actionCard?.sourceAction?.recipient),
            draftRecipientHandle: cleanedText(actionCard?.sourceAction?.recipientHandle),
            sourceSubject: cleanedText(actionCard?.sourceAction?.subject),
            sourceContextData: encodedSourceContext(actionCard?.sourceAction)
        )
    }

    static func apply(
        _ remoteTodo: MobileAPIClient.RemoteTodo,
        to todo: TodoItem,
        includeCards: Bool = true,
        contactsByID: [UUID: CRMContact]? = nil
    ) {
        apply(
            prepare(remoteTodo, id: todo.id),
            to: todo,
            includeCards: includeCards,
            contactsByID: contactsByID
        )
    }

    static func apply(
        _ prepared: PreparedTodo,
        to todo: TodoItem,
        includeCards: Bool = true,
        contactsByID: [UUID: CRMContact]? = nil
    ) {
        todo.title = prepared.title
        todo.notes = prepared.notes
        todo.nextAction = prepared.nextAction
        todo.priority = prepared.priority
        todo.dueDate = prepared.dueDate
        todo.status = prepared.status
        todo.attentionMode = prepared.attentionMode
        todo.kindRawValue = prepared.kind
        todo.snoozedUntil = prepared.snoozedUntil
        if let createdAt = prepared.createdAt {
            todo.createdAt = createdAt
        }
        if let updatedAt = prepared.updatedAt {
            todo.updatedAt = updatedAt
        }
        todo.completedAt = prepared.completedAt
        todo.actionPlan = prepared.actionPlan
        todo.ownerLabel = prepared.ownerLabel
        todo.sourceOccurredAt = prepared.sourceOccurredAt
        todo.todoBriefData = prepared.todoBriefData
        if let contactsByID {
            todo.contact = relatedContact(personIDs: prepared.relatedPersonIDs, contactsByID: contactsByID)
        }
        todo.sourceSystem = prepared.sourceSystem
        // A cards-omitted refresh must not wipe existing decision-card context. The
        // collection API also deliberately omits cards from closed rows, even when
        // open-row cards were requested, so key presence is part of the contract.
        if includeCards && prepared.hasActionCardField {
            apply(prepared.card, to: todo)
        }
    }

    static func apply(_ remotePerson: MobileAPIClient.RemotePerson, to contact: CRMContact) {
        contact.name = remotePerson.displayName
        contact.company = company(from: remotePerson)
        contact.email = firstContactValue(remotePerson.contactDetails, key: "emails") ?? ""
        contact.phone = firstContactValue(remotePerson.contactDetails, key: "phones") ?? ""
        contact.status = status(from: remotePerson)
        contact.dealStage = dealStage(from: remotePerson)
        contact.dealValue = remotePerson.metadata["deal_value"]?.decimal ?? 0
        contact.lastContactedAt = remotePerson.lastInteractionAt
        contact.notes = remotePerson.notes ?? ""
    }

    static func todoPayload(
        title: String,
        notes: String,
        priority: TodoPriority,
        dueDate: Date?,
        isCompleted: Bool,
        nextAction: String? = nil,
        relatedPersonID: UUID? = nil
    ) -> MobileAPIClient.RequestBody {
        let nextAction = cleanedText(nextAction) ?? cleanedText(title) ?? cleanedText(notes) ?? "Review this item."

        var payload: MobileAPIClient.RequestBody = [
            "source": .string("mobile"),
            "kind": .string("general"),
            "attention_mode": .string(TodoAttentionMode.actNow.rawValue),
            "title": .string(title),
            "summary": .string(notes.isEmpty ? title : notes),
            "next_action": .string(nextAction),
            "notes": .string(notes),
            "priority": .int(priorityValue(from: priority)),
            "status": .string(isCompleted ? "done" : "open")
        ]

        if let dueDate {
            payload["due_at"] = .string(isoString(for: dueDate))
        }

        if let relatedPersonID {
            payload["person_id"] = .string(relatedPersonID.uuidString.lowercased())
        }

        return payload
    }

    static func nextActionForTodoPayload(
        title: String,
        notes: String,
        requestedNextAction: String? = nil,
        existingTitle: String? = nil,
        existingNotes: String? = nil,
        existingNextAction: String? = nil
    ) -> String {
        if let requestedNextAction = cleanedText(requestedNextAction) {
            return requestedNextAction
        }

        if let existingNextAction = cleanedText(existingNextAction),
           !sameText(existingNextAction, existingTitle),
           !sameText(existingNextAction, existingNotes) {
            return existingNextAction
        }

        return cleanedText(title) ?? cleanedText(notes) ?? "Review this item."
    }

    static func personPayload(
        name: String,
        company: String,
        email: String,
        phone: String,
        status: ContactStatus,
        dealStage: DealStage,
        dealValue: Decimal,
        notes: String,
        lastContactedAt: Date? = nil
    ) -> MobileAPIClient.RequestBody {
        let relationship = company.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: MobileAPIClient.RequestBody = [
            "display_name": .string(name),
            "relationship": .string(relationship.isEmpty ? "Personal" : relationship),
            "email": .string(email),
            "notes": .string(notes),
            "metadata": .object([
                "mobile_status": .string(status.rawValue),
                "deal_stage": .string(dealStage.rawValue),
                "deal_value": .string(NSDecimalNumber(decimal: dealValue).stringValue)
            ])
        ]

        if !phone.isEmpty {
            payload["phone"] = .string(phone)
        }

        if let lastContactedAt {
            payload["last_interaction_at"] = .string(isoString(for: lastContactedAt))
        }

        return payload
    }

    static func personPayload(from contact: CRMContact) -> MobileAPIClient.RequestBody {
        personPayload(
            name: contact.name,
            company: contact.company,
            email: contact.email,
            phone: contact.phone,
            status: contact.status,
            dealStage: contact.dealStage,
            dealValue: contact.dealValue,
            notes: contact.notes,
            lastContactedAt: contact.lastContactedAt
        )
    }

    nonisolated static func shouldKeepRemoteTodo(_ remoteTodo: MobileAPIClient.RemoteTodo) -> Bool {
        remoteTodo.status != "dismissed"
    }

    static func todo(
        from remoteTodo: MobileAPIClient.RemoteTodo,
        id: UUID,
        contactsByID: [UUID: CRMContact]? = nil
    ) -> TodoItem {
        todoItem(from: prepare(remoteTodo, id: id), contactsByID: contactsByID)
    }

    static func todoItem(
        from prepared: PreparedTodo,
        contactsByID: [UUID: CRMContact]? = nil
    ) -> TodoItem {
        // Unknown timestamps belong at the bottom rather than appearing fresh
        // on every sync. Existing rows retain their local values in `apply`.
        let createdAt = prepared.createdAt ?? prepared.updatedAt ?? .distantPast

        return TodoItem(
            id: prepared.id,
            title: prepared.title,
            notes: prepared.notes,
            nextAction: prepared.nextAction,
            priority: prepared.priority,
            dueDate: prepared.dueDate,
            isCompleted: prepared.isCompleted,
            status: prepared.status,
            attentionMode: prepared.attentionMode,
            kind: prepared.kind,
            snoozedUntil: prepared.snoozedUntil,
            createdAt: createdAt,
            updatedAt: prepared.updatedAt ?? createdAt,
            completedAt: prepared.completedAt,
            decisionPrompt: prepared.card.decisionPrompt,
            decisionContextSummary: prepared.card.decisionContextSummary,
            whyNow: prepared.card.whyNow,
            sourceContext: prepared.card.sourceContext,
            nextBestAction: prepared.card.nextBestAction,
            draftPreview: prepared.card.draftPreview,
            evidenceExcerpt: prepared.card.evidenceExcerpt,
            cardHeadline: prepared.card.headline,
            rankReason: prepared.card.rankReason,
            estimatedEffort: prepared.card.estimatedEffort,
            actionPlan: prepared.actionPlan,
            ownerLabel: prepared.ownerLabel,
            sourceOccurredAt: prepared.sourceOccurredAt,
            todoBriefData: prepared.todoBriefData,
            sourceSystem: prepared.sourceSystem,
            sourceProvider: prepared.card.sourceProvider,
            sourceProviderLabel: prepared.card.sourceProviderLabel,
            sourceOpenURLString: prepared.card.sourceOpenURLString,
            sourceOpenLabel: prepared.card.sourceOpenLabel,
            draftText: prepared.card.draftText,
            draftKind: prepared.card.draftKind,
            draftRecipient: prepared.card.draftRecipient,
            draftRecipientHandle: prepared.card.draftRecipientHandle,
            sourceSubject: prepared.card.sourceSubject,
            sourceContextData: prepared.card.sourceContextData,
            contact: contactsByID.flatMap { relatedContact(personIDs: prepared.relatedPersonIDs, contactsByID: $0) }
        )
    }

    nonisolated private static let sourceContextEncoder = JSONEncoder()
    nonisolated private static let todoBriefEncoder = JSONEncoder()

    nonisolated private static func encodedBrief(
        _ brief: MobileAPIClient.RemoteTodoBrief?
    ) -> Data? {
        guard let brief else { return nil }

        let snapshot = TodoBriefSnapshot(
            whyItMatters: cleanedText(brief.whyItMatters),
            situation: cleanedText(brief.situation),
            recommendation: cleanedText(brief.recommendation),
            steps: brief.steps.compactMap(cleanedText),
            openQuestions: brief.openQuestions.compactMap(cleanedText),
            effort: cleanedText(brief.effort),
            generatedAt: brief.generatedAt,
            model: cleanedText(brief.model)
        )

        return try? todoBriefEncoder.encode(snapshot)
    }

    nonisolated private static func encodedSourceContext(
        _ sourceAction: MobileAPIClient.RemoteActionCard.SourceAction?
    ) -> Data? {
        guard let sourceAction,
              !(sourceAction.participants.isEmpty && sourceAction.conversation.isEmpty)
        else {
            return nil
        }

        return try? sourceContextEncoder.encode(
            TodoStoredSourceContext(
                participants: sourceAction.participants,
                conversation: sourceAction.conversation
            )
        )
    }

    private static func apply(_ card: PreparedCard, to todo: TodoItem) {
        todo.cardHeadline = card.headline
        todo.decisionPrompt = card.decisionPrompt
        todo.decisionContextSummary = card.decisionContextSummary
        todo.whyNow = card.whyNow
        todo.rankReason = card.rankReason
        todo.sourceContext = card.sourceContext
        todo.nextBestAction = card.nextBestAction
        todo.draftPreview = card.draftPreview
        todo.evidenceExcerpt = card.evidenceExcerpt
        todo.estimatedEffort = card.estimatedEffort
        todo.sourceProvider = card.sourceProvider
        todo.sourceProviderLabel = card.sourceProviderLabel
        todo.sourceOpenURLString = card.sourceOpenURLString
        todo.sourceOpenLabel = card.sourceOpenLabel
        todo.draftText = card.draftText
        todo.draftKind = card.draftKind
        todo.draftRecipient = card.draftRecipient
        todo.draftRecipientHandle = card.draftRecipientHandle
        todo.sourceSubject = card.sourceSubject
        todo.sourceContextData = card.sourceContextData
    }

    static func contact(from remotePerson: MobileAPIClient.RemotePerson, id: UUID) -> CRMContact {
        CRMContact(
            id: id,
            name: remotePerson.displayName,
            company: company(from: remotePerson),
            email: firstContactValue(remotePerson.contactDetails, key: "emails") ?? "",
            phone: firstContactValue(remotePerson.contactDetails, key: "phones") ?? "",
            status: status(from: remotePerson),
            dealValue: remotePerson.metadata["deal_value"]?.decimal ?? 0,
            dealStage: dealStage(from: remotePerson),
            lastContactedAt: remotePerson.lastInteractionAt,
            notes: remotePerson.notes ?? ""
        )
    }

    nonisolated private static func priority(from value: Int?) -> TodoPriority {
        switch value ?? 50 {
        case 90...: .critical
        case 75..<90: .high
        case 50..<75: .medium
        default: .low
        }
    }

    private static func priorityValue(from priority: TodoPriority) -> Int {
        switch priority {
        case .critical: 95
        case .high: 80
        case .medium: 55
        case .low: 20
        }
    }

    private static func status(from remotePerson: MobileAPIClient.RemotePerson) -> ContactStatus {
        switch remotePerson.status {
        case "archived", "merged":
            return .closed
        default:
            break
        }

        if let mobileStatus = remotePerson.metadata["mobile_status"]?.string,
           let status = ContactStatus(rawValue: mobileStatus) {
            return status
        }

        return .active
    }

    private static func dealStage(from remotePerson: MobileAPIClient.RemotePerson) -> DealStage {
        if let value = remotePerson.metadata["deal_stage"]?.string,
           let stage = DealStage(rawValue: value) {
            return stage
        }
        return .prospect
    }

    private static func company(from remotePerson: MobileAPIClient.RemotePerson) -> String {
        let relationship = remotePerson.relationship?.trimmingCharacters(in: .whitespacesAndNewlines)
        return relationship?.isEmpty == false ? relationship! : ""
    }

    private static func firstContactValue(_ values: [String: [String]], key: String) -> String? {
        values[key]?.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func relatedContact(
        personIDs: [UUID],
        contactsByID: [UUID: CRMContact]
    ) -> CRMContact? {
        personIDs.lazy.compactMap { contactsByID[$0] }.first
    }

    private static func isoString(for date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false).format(date)
    }

    nonisolated private static func cleanedText(_ value: String?) -> String? {
        ChiefOfStaffCopy.clean(value)
    }

    nonisolated private static func actionCardContextSummary(_ actionCard: MobileAPIClient.RemoteActionCard?) -> String? {
        guard let actionCard else { return nil }

        let values = actionCard.contextItems.compactMap { item in
            cleanedText(item.value)
        }

        guard !values.isEmpty else { return nil }

        let uniqueValues = values.reduce(into: [String]()) { result, value in
            let duplicate = result.contains { existing in
                existing.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            if !duplicate {
                result.append(value)
            }
        }

        return uniqueValues.joined(separator: " · ")
    }

    private static func sameText(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs = cleanedText(rhs) else { return false }
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
