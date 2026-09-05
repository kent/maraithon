import Foundation
import SwiftData

enum ChatSyncError: LocalizedError, Equatable {
    case missingSession
    case emptyMessage
    case emptyThreadTitle
    case pollingTimedOut
    case failedMessageStateNotSaved
    case assistantResponseFailed(String?)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Sign in again to keep chatting with Maraithon."
        case .emptyMessage:
            return "Enter a message before sending."
        case .emptyThreadTitle:
            return "Enter a chat name before saving."
        case .pollingTimedOut:
            return "Maraithon is still working on your answer. Refresh this chat in a moment."
        case .failedMessageStateNotSaved:
            return "Message was not sent. Refresh this chat before sending again."
        case .assistantResponseFailed(let message):
            return MobileErrorCopy.assistantRunFailureMessage(for: message)
        }
    }
}

@MainActor
struct ChatSyncService {
    private let api: any MobileChatAPI
    private let now: () -> Date
    private let pollIntervalNanoseconds: UInt64
    private let maxPollAttempts: Int

    private let maxConsecutivePollFailures = 5

    private static let metadataEncoder = JSONEncoder()

    init(
        api: any MobileChatAPI = MobileAPIClient(),
        now: @escaping () -> Date = Date.init,
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        maxPollAttempts: Int = 180
    ) {
        self.api = api
        self.now = now
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPollAttempts = maxPollAttempts
    }

    func refreshThreads(
        modelContext: ModelContext,
        sessionStore: SessionStore,
        force: Bool = false
    ) async throws {
        let sessionToken = try sessionToken(from: sessionStore)

        let remoteThreads: [MobileAPIClient.RemoteChatThread]
        do {
            remoteThreads = try await api.listChatThreads(
                sessionToken: sessionToken,
                conditional: !force
            )
        } catch MobileAPIError.notModified {
            // The thread collection is unchanged; skip the merge and the
            // delete-reconcile entirely.
            return
        }

        let localThreads = try localThreadsByRemoteID(modelContext: modelContext)

        for remoteThread in remoteThreads {
            try merge(
                remoteThread,
                modelContext: modelContext,
                preferredThread: localThreads[remoteThread.id],
                localThreadsByRemoteID: localThreads
            )
        }

        // A short (non-truncated) page is the complete remote list, so local
        // threads that vanished remotely should be removed. A full page may be
        // truncated and omit live threads beyond it; never delete on that
        // evidence alone. Threads without a remoteID are local-only drafts.
        if remoteThreads.count < MobileAPIClient.chatThreadsPageLimit {
            let remoteIDs = Set(remoteThreads.map(\.id))
            for (remoteID, thread) in localThreads where !remoteIDs.contains(remoteID) {
                modelContext.delete(thread)
            }
        }

        try modelContext.save()
    }

    func refreshThread(
        _ thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        guard let remoteID = thread.remoteID else { return }
        let sessionToken = try sessionToken(from: sessionStore)
        let remoteThread = try await api.getChatThread(sessionToken: sessionToken, id: remoteID)
        try merge(
            remoteThread,
            modelContext: modelContext,
            preferredThread: thread,
            reconcileMessages: true
        )
        try modelContext.save()
    }

    func openTodoThread(
        for todo: TodoItem,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws -> ChatThread {
        let sessionToken = try sessionToken(from: sessionStore)
        let remoteThread = try await api.getOrCreateTodoChatThread(
            sessionToken: sessionToken,
            todoID: todo.id
        )
        let thread = try merge(
            remoteThread,
            modelContext: modelContext,
            reconcileMessages: true
        )
        try modelContext.save()
        return thread
    }

    func renameThread(
        _ thread: ChatThread,
        title rawTitle: String,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        guard let title = ChatThreadNaming.manualTitle(for: rawTitle) else {
            throw ChatSyncError.emptyThreadTitle
        }

        if let remoteID = thread.remoteID {
            let sessionToken = try sessionToken(from: sessionStore)
            let remoteThread = try await api.updateChatThread(
                sessionToken: sessionToken,
                id: remoteID,
                title: title
            )
            try merge(
                remoteThread,
                modelContext: modelContext,
                preferredThread: thread,
                reconcileMessages: true
            )
        } else {
            thread.title = title
            thread.updatedAt = now()
        }

        try modelContext.save()
    }

    @discardableResult
    func send(
        _ text: String,
        in thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws -> UUID? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ChatSyncError.emptyMessage }

        let sessionToken = try sessionToken(from: sessionStore)
        let clientMessageID = UUID()
        let userMessage = optimisticUserMessage(body: body, clientMessageID: clientMessageID, thread: thread)

        modelContext.insert(userMessage)
        thread.messages.append(userMessage)
        thread.updatedAt = now()
        thread.syncStatus = .syncing

        if thread.title == ChatThreadNaming.defaultTitle {
            thread.title = ChatThreadNaming.title(for: body)
        }

        try modelContext.save()

        let response: MobileAPIClient.ChatMessageResponse

        do {
            let remoteThread = try await ensureRemoteThread(
                thread,
                sessionToken: sessionToken,
                modelContext: modelContext
            )

            response = try await api.sendChatMessage(
                sessionToken: sessionToken,
                threadID: remoteThread.id,
                clientMessageID: clientMessageID,
                body: body
            )

            try merge(
                response.thread,
                modelContext: modelContext,
                preferredThread: thread,
                reconcileMessages: true
            )
            if let run = response.run {
                apply(run, to: thread)
            }

            try modelContext.save()
        } catch {
            userMessage.deliveryState = .failed
            thread.syncStatus = .failed
            thread.updatedAt = now()
            do {
                try modelContext.save()
            } catch {
                throw ChatSyncError.failedMessageStateNotSaved
            }
            throw error
        }

        if let run = response.run,
           shouldSurfaceRunFailure(run, in: thread) {
            throw ChatSyncError.assistantResponseFailed(run.error)
        }

        return response.run?.runStatus.isPending == true ? response.run?.id : thread.pendingRunID
    }

    func pollPendingRun(
        in thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        guard let runID = thread.pendingRunID else { return }
        let sessionToken = try sessionToken(from: sessionStore)
        var consecutiveFailures = 0

        // Exponential backoff (1x, 2x, 5x, then capped at 10x the base
        // interval) keeps the total wall-clock budget the same as the old
        // fixed-interval loop while cutting request and radio churn.
        let baseInterval = Duration.nanoseconds(pollIntervalNanoseconds)
        let totalBudget = baseInterval * maxPollAttempts
        var elapsed = Duration.zero
        var attempt = 0

        while elapsed < totalBudget {
            try Task.checkCancellation()

            do {
                let run = try await api.getChatRun(sessionToken: sessionToken, id: runID)

                if run.runStatus.isPending {
                    // Skip the save entirely when the poll changed nothing;
                    // most pending ticks are no-ops.
                    if applyReportingChanges(run, to: thread) {
                        try modelContext.save()
                    }
                } else {
                    // Refresh the thread first so the assistant reply and the
                    // pending-state clear land in one merge.
                    try await refreshThread(thread, modelContext: modelContext, sessionStore: sessionStore)
                    if shouldSurfaceRunFailure(run, in: thread) {
                        throw ChatSyncError.assistantResponseFailed(run.error)
                    }
                    return
                }

                consecutiveFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ChatSyncError {
                throw error
            } catch {
                // Transient request failures must not strand the chat in a
                // frozen pending state; keep polling unless they persist.
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutivePollFailures {
                    throw error
                }
            }

            let delay = baseInterval * Self.backoffMultiplier(attempt: attempt)
            // Task.sleep(for:) throws on cancellation, keeping the poll
            // responsive to view teardown.
            try await Task.sleep(for: delay)
            elapsed += delay
            attempt += 1
        }

        throw ChatSyncError.pollingTimedOut
    }

    private static func backoffMultiplier(attempt: Int) -> Int {
        switch attempt {
        case 0: 1
        case 1: 2
        case 2: 5
        default: 10
        }
    }

    func decidePreparedAction(
        _ actionID: UUID,
        decision: ChatActionDecision,
        in thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        let sessionToken = try sessionToken(from: sessionStore)
        let response = try await api.decidePreparedAction(
            sessionToken: sessionToken,
            id: actionID,
            decision: decision,
            clientMessageID: UUID(),
            draftEdits: nil
        )
        try merge(
            response.thread,
            modelContext: modelContext,
            preferredThread: thread,
            reconcileMessages: true
        )
        try modelContext.save()
    }

    func decidePreparedAction(
        _ action: ChatMessageAction,
        in thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        let sessionToken = try sessionToken(from: sessionStore)
        let response = try await api.decidePreparedAction(
            sessionToken: sessionToken,
            id: action.actionID,
            decision: action.decision ?? .confirm,
            clientMessageID: UUID(),
            draftEdits: action.draftEdits
        )
        try merge(
            response.thread,
            modelContext: modelContext,
            preferredThread: thread,
            reconcileMessages: true
        )
        try modelContext.save()
    }

    func deleteMessage(
        _ message: ChatMessage,
        from thread: ChatThread,
        modelContext: ModelContext,
        sessionStore: SessionStore
    ) async throws {
        if let remoteThreadID = thread.remoteID, let remoteMessageID = message.remoteID {
            let sessionToken = try sessionToken(from: sessionStore)
            let remoteThread = try await api.deleteChatMessage(
                sessionToken: sessionToken,
                threadID: remoteThreadID,
                messageID: remoteMessageID
            )
            try merge(
                remoteThread,
                modelContext: modelContext,
                preferredThread: thread,
                reconcileMessages: true
            )
        } else {
            deleteLocalMessage(message, from: thread, modelContext: modelContext)
            thread.updatedAt = now()
        }

        try modelContext.save()
    }

    @discardableResult
    private func ensureRemoteThread(
        _ thread: ChatThread,
        sessionToken: String,
        modelContext: ModelContext
    ) async throws -> MobileAPIClient.RemoteChatThread {
        if let remoteID = thread.remoteID {
            return try await api.getChatThread(sessionToken: sessionToken, id: remoteID)
        }

        let remoteThread = try await api.createChatThread(
            sessionToken: sessionToken,
            title: thread.title,
            clientThreadID: thread.id
        )
        try merge(
            remoteThread,
            modelContext: modelContext,
            preferredThread: thread,
            reconcileMessages: true
        )
        try modelContext.save()
        return remoteThread
    }

    @discardableResult
    private func merge(
        _ remoteThread: MobileAPIClient.RemoteChatThread,
        modelContext: ModelContext,
        preferredThread: ChatThread? = nil,
        localThreadsByRemoteID: [UUID: ChatThread]? = nil,
        reconcileMessages: Bool = false
    ) throws -> ChatThread {
        let thread = try localThread(
            for: remoteThread,
            modelContext: modelContext,
            preferredThread: preferredThread,
            localThreadsByRemoteID: localThreadsByRemoteID
        )

        thread.remoteID = remoteThread.id
        thread.title = remoteThread.title.isEmpty ? thread.title : remoteThread.title
        thread.remoteStatusRawValue = remoteThread.status
        thread.syncStatus = .synced
        thread.lastSyncedAt = now()
        thread.updatedAt = remoteThread.updatedAt ?? remoteThread.lastTurnAt ?? thread.updatedAt

        if let pendingRun = remoteThread.pendingRun, pendingRun.runStatus.isPending {
            apply(pendingRun, to: thread)
        } else {
            thread.pendingRunID = nil
            thread.pendingRunWorkSummary = nil
        }

        let remoteMessageList = remoteMessages(from: remoteThread)
        var messagesByRemoteID = thread.messages.reduce(into: [UUID: ChatMessage]()) { result, message in
            guard let remoteID = message.remoteID else { return }
            result[remoteID] = message
        }
        var messagesByClientID = thread.messages.reduce(into: [UUID: ChatMessage]()) { result, message in
            guard let clientMessageID = message.clientMessageID else { return }
            result[clientMessageID] = message
        }

        if reconcileMessages {
            removeMessagesMissingFromRemote(
                remoteMessageList,
                from: thread,
                modelContext: modelContext
            )
        }

        for remoteMessage in remoteMessageList {
            try merge(
                remoteMessage,
                into: thread,
                modelContext: modelContext,
                messagesByRemoteID: &messagesByRemoteID,
                messagesByClientID: &messagesByClientID
            )
        }

        return thread
    }

    private func remoteMessages(from remoteThread: MobileAPIClient.RemoteChatThread) -> [MobileAPIClient.RemoteChatMessage] {
        var seenIDs = Set<UUID>()
        let messages = remoteThread.messages + (remoteThread.latestMessage.map { [$0] } ?? [])

        return messages.filter { message in
            seenIDs.insert(message.id).inserted
        }
    }

    private func localThread(
        for remoteThread: MobileAPIClient.RemoteChatThread,
        modelContext: ModelContext,
        preferredThread: ChatThread?,
        localThreadsByRemoteID: [UUID: ChatThread]?
    ) throws -> ChatThread {
        if let preferredThread {
            return preferredThread
        }

        if let localThreadsByRemoteID {
            if let existing = localThreadsByRemoteID[remoteThread.id] {
                return existing
            }
        } else {
            let remoteThreadID = remoteThread.id
            var descriptor = FetchDescriptor<ChatThread>(
                predicate: #Predicate { $0.remoteID == remoteThreadID }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                return existing
            }
        }

        let thread = ChatThread(
            title: remoteThread.title,
            updatedAt: remoteThread.updatedAt ?? remoteThread.lastTurnAt ?? now(),
            remoteID: remoteThread.id,
            remoteStatusRawValue: remoteThread.status,
            syncStatus: .synced,
            lastSyncedAt: now()
        )
        modelContext.insert(thread)
        return thread
    }

    private func localThreadsByRemoteID(modelContext: ModelContext) throws -> [UUID: ChatThread] {
        let threads = try modelContext.fetch(FetchDescriptor<ChatThread>())
        return threads.reduce(into: [:]) { result, thread in
            guard let remoteID = thread.remoteID else { return }
            result[remoteID] = thread
        }
    }

    private func merge(
        _ remoteMessage: MobileAPIClient.RemoteChatMessage,
        into thread: ChatThread,
        modelContext: ModelContext,
        messagesByRemoteID: inout [UUID: ChatMessage],
        messagesByClientID: inout [UUID: ChatMessage]
    ) throws {
        let message = localMessage(
            for: remoteMessage,
            messagesByRemoteID: messagesByRemoteID,
            messagesByClientID: messagesByClientID
        ) ?? {
            let message = ChatMessage(
                body: remoteMessage.body,
                sentAt: remoteMessage.sentAt ?? now(),
                role: role(from: remoteMessage.role),
                remoteID: remoteMessage.id,
                clientMessageID: remoteMessage.clientMessageID,
                deliveryState: deliveryState(from: remoteMessage.deliveryState),
                turnKind: remoteMessage.turnKind,
                messageClass: remoteMessage.messageClass,
                remoteRunID: remoteMessage.runID,
                thread: thread
            )
            modelContext.insert(message)
            thread.messages.append(message)
            return message
        }()

        message.remoteID = remoteMessage.id
        message.clientMessageID = remoteMessage.clientMessageID ?? message.clientMessageID
        message.body = remoteMessage.body
        message.sentAt = remoteMessage.sentAt ?? message.sentAt
        message.role = role(from: remoteMessage.role)
        message.deliveryState = deliveryState(from: remoteMessage.deliveryState)
        message.turnKind = remoteMessage.turnKind
        message.messageClass = remoteMessage.messageClass
        message.remoteRunID = remoteMessage.runID
        message.structuredData = try encodedMetadata(for: remoteMessage)
        try applyLinkedTodo(remoteMessage.linkedTodo, modelContext: modelContext)

        messagesByRemoteID[remoteMessage.id] = message
        if let clientMessageID = message.clientMessageID {
            messagesByClientID[clientMessageID] = message
        }
    }

    private func localMessage(
        for remoteMessage: MobileAPIClient.RemoteChatMessage,
        messagesByRemoteID: [UUID: ChatMessage],
        messagesByClientID: [UUID: ChatMessage]
    ) -> ChatMessage? {
        if let match = messagesByRemoteID[remoteMessage.id] {
            return match
        }

        if let clientMessageID = remoteMessage.clientMessageID {
            return messagesByClientID[clientMessageID]
        }

        return nil
    }

    private func removeMessagesMissingFromRemote(
        _ remoteMessages: [MobileAPIClient.RemoteChatMessage],
        from thread: ChatThread,
        modelContext: ModelContext
    ) {
        let remoteIDs = Set(remoteMessages.map(\.id))
        let messagesToDelete = thread.messages.filter { message in
            message.remoteID.map { !remoteIDs.contains($0) } == true
        }

        for message in messagesToDelete {
            deleteLocalMessage(message, from: thread, modelContext: modelContext)
        }
    }

    private func deleteLocalMessage(
        _ message: ChatMessage,
        from thread: ChatThread,
        modelContext: ModelContext
    ) {
        thread.messages.removeAll { $0.id == message.id }
        modelContext.delete(message)
    }

    /// Applies the run to the thread and reports whether anything actually
    /// changed, so pollers can skip redundant saves.
    private func applyReportingChanges(_ run: MobileAPIClient.RemoteChatRun, to thread: ChatThread) -> Bool {
        let before = (thread.pendingRunID, thread.pendingRunWorkSummary, thread.remoteStatusRawValue)
        apply(run, to: thread)
        return before != (thread.pendingRunID, thread.pendingRunWorkSummary, thread.remoteStatusRawValue)
    }

    private func apply(_ run: MobileAPIClient.RemoteChatRun, to thread: ChatThread) {
        if run.runStatus.isPending {
            thread.pendingRunID = run.id
            thread.pendingRunWorkSummary = encodedWorkSummary(run.workSummary)
        } else {
            thread.pendingRunID = nil
            thread.pendingRunWorkSummary = nil
        }
        thread.remoteStatusRawValue = run.status
    }

    private func shouldSurfaceRunFailure(_ run: MobileAPIClient.RemoteChatRun, in thread: ChatThread) -> Bool {
        guard run.runStatus == .failed else { return false }

        return !thread.messages.contains { message in
            message.role == .assistant && message.remoteRunID == run.id
        }
    }

    private func optimisticUserMessage(
        body: String,
        clientMessageID: UUID,
        thread: ChatThread
    ) -> ChatMessage {
        ChatMessage(
            body: body,
            sentAt: now(),
            role: .user,
            clientMessageID: clientMessageID,
            deliveryState: .sending,
            turnKind: "user_message",
            thread: thread
        )
    }

    private func encodedMetadata(for remoteMessage: MobileAPIClient.RemoteChatMessage) throws -> Data {
        let metadata = ChatMessageStoredMetadata(
            actions: remoteMessage.actions.map {
                ChatMessageAction(
                    actionID: $0.id,
                    kind: $0.kind,
                    label: $0.label,
                    decisionRawValue: $0.decision,
                    style: $0.style
                )
            },
            draftCard: ChatDraftCard(remoteMessage.structuredData["draft_card"]),
            linkedTodo: remoteMessage.linkedTodo,
            workSummary: remoteMessage.workSummary,
            structuredData: publicStructuredData(remoteMessage.structuredData)
        )
        return try Self.metadataEncoder.encode(metadata)
    }

    private func publicStructuredData(_ structuredData: [String: JSONValue]) -> [String: JSONValue] {
        structuredData.filter { key, _ in
            key == "calculation" || key == "draft_card"
        }
    }

    private func applyLinkedTodo(_ linkedTodo: JSONValue?, modelContext: ModelContext) throws {
        guard let todoData = linkedTodo?.object,
              let idText = todoData["id"]?.string,
              let id = UUID(uuidString: idText) else {
            return
        }

        var descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let todo = try modelContext.fetch(descriptor).first else { return }

        if todoData["status"]?.string == "dismissed" {
            modelContext.delete(todo)
            return
        }

        if let title = todoData["title"]?.string, !title.isEmpty {
            todo.title = title
        }

        if let notes = todoData["notes"]?.string ?? todoData["summary"]?.string {
            todo.notes = notes
        }

        todo.nextAction = todoData["next_action"]?.string ?? todo.nextAction

        if let priorityValue = todoData["priority"]?.int {
            todo.priority = priority(from: priorityValue)
        }

        if let dueAt = date(from: todoData["due_at"]) {
            todo.dueDate = dueAt
        }

        if let status = todoData["status"]?.string {
            todo.status = TodoStatus(rawValue: status) ?? .open
            todo.completedAt = todo.status == .done ? (date(from: todoData["closed_at"]) ?? now()) : nil
            todo.snoozedUntil = date(from: todoData["snoozed_until"])
        }

        if let attentionMode = todoData["attention_mode"]?.string {
            todo.attentionMode = TodoAttentionMode(rawValue: attentionMode) ?? .actNow
        }
        todo.updatedAt = date(from: todoData["updated_at"]) ?? now()
    }

    private func priority(from value: Int) -> TodoPriority {
        switch value {
        case 90...: .critical
        case 75..<90: .high
        case 50..<75: .medium
        default: .low
        }
    }

    private func date(from value: JSONValue?) -> Date? {
        guard let string = value?.string else { return nil }
        return MobileAPIClient.date(from: string)
    }

    private func encodedWorkSummary(_ workSummary: ChatWorkSummary?) -> Data? {
        guard let workSummary else { return nil }
        return try? Self.metadataEncoder.encode(workSummary)
    }

    private func sessionToken(from sessionStore: SessionStore) throws -> String {
        guard let sessionToken = sessionStore.user?.sessionToken else {
            throw ChatSyncError.missingSession
        }
        return sessionToken
    }

    private func role(from rawValue: String) -> ChatRole {
        ChatRole(rawValue: rawValue) ?? .assistant
    }

    private func deliveryState(from rawValue: String?) -> ChatDeliveryState {
        ChatDeliveryState(rawValue: rawValue ?? "") ?? .delivered
    }
}
