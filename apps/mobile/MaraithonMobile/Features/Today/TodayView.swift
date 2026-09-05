import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TodoItem.updatedAt, order: .reverse) private var todos: [TodoItem]
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    @State private var editingTodo: TodoItem?
    @State private var refreshErrorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var isRefreshing = false
    @State private var briefs: [MobileAPIClient.RemoteBrief] = []
    @State private var snapshot: TodaySnapshot?

    private var recentThreads: [ChatThread] {
        Array(threads.prefix(3))
    }

    private var todayBrief: MobileAPIClient.RemoteBrief? {
        briefs.first { brief in
            guard let date = brief.referenceDate else { return false }
            return Calendar.current.isDateInToday(date)
        }
    }

    private var previousBriefs: [MobileAPIClient.RemoteBrief] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return briefs.filter { brief in
            guard let date = brief.referenceDate else { return false }
            return !Calendar.current.isDateInToday(date) && date >= cutoff
        }
    }

    /// Cheap content fingerprint over the fields the snapshot derives from.
    /// `onChange` compares it every body pass; identity-based array equality
    /// would miss in-place edits like completing a todo.
    private var todoSignature: Int {
        TodoListSignature.signature(for: todos)
    }

    var body: some View {
        let snapshot = self.snapshot ?? TodaySnapshot(todos: todos)
        NavigationStack {
            List {
                if let refreshErrorMessage {
                    Section {
                        SyncIssueBanner(
                            message: refreshErrorMessage,
                            retry: { Task { await refreshLatestData(force: true) } },
                            dismiss: { self.refreshErrorMessage = nil }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                if let actionErrorMessage {
                    Section {
                        SyncIssueBanner(
                            title: TodayViewCopy.actionWarningTitle,
                            message: actionErrorMessage,
                            buttonTitle: nil,
                            retry: nil,
                            dismissAccessibilityLabel: TodayViewCopy.dismissActionWarningAccessibilityLabel,
                            dismiss: { self.actionErrorMessage = nil }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                briefingHeroSection(snapshot.brief)
                briefingGroupSections(snapshot.briefingGroups)

                Section(TodayViewCopy.actionSectionTitle) {
                    VStack(spacing: 1) {
                        CommandRow(
                            title: TodayViewCopy.askMaraithonTitle,
                            subtitle: TodayViewCopy.askMaraithonSubtitle,
                            value: "",
                            systemImage: "sparkles",
                            tint: .purple
                        ) {
                            appNavigation.showChat(prompt: ChiefOfStaffPrompt.planDay.message)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.decisionsTitle,
                            subtitle: TodayViewCopy.decisionsSubtitle,
                            value: "\(snapshot.metrics.decisionTodos)",
                            systemImage: "checkmark.seal",
                            tint: .purple
                        ) {
                            appNavigation.showTodos(.decisions)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.openWorkTitle,
                            subtitle: TodayViewCopy.openWorkSubtitle,
                            value: "\(snapshot.metrics.openTodos)",
                            systemImage: "circle",
                            tint: .blue
                        ) {
                            appNavigation.showTodos(.needsAction)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.overdueTitle,
                            subtitle: TodayViewCopy.overdueSubtitle,
                            value: "\(snapshot.metrics.overdueTodos)",
                            systemImage: "clock.badge.exclamationmark",
                            tint: .orange
                        ) {
                            appNavigation.showTodos(.overdue)
                        }
                        Divider().padding(.leading, 48)
                        CommandRow(
                            title: TodayViewCopy.dueTodayTitle,
                            subtitle: TodayViewCopy.dueTodaySubtitle,
                            value: "\(snapshot.metrics.dueTodayTodos)",
                            systemImage: "calendar.badge.clock",
                            tint: .indigo
                        ) {
                            appNavigation.showTodos(.today)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                }

                Section(TodayViewCopy.focusSectionTitle) {
                    if snapshot.focusItems.isEmpty {
                        ContentUnavailableView(
                            TodayViewCopy.emptyFocusTitle,
                            systemImage: "sparkles",
                            description: Text(TodayViewCopy.emptyFocusDescription)
                        )
                    } else {
                        ForEach(snapshot.focusItems) { item in
                            focusRow(for: item, todosByID: snapshot.todosByID)
                        }
                    }
                }

                previousBriefingsSection

                Section(TodayViewCopy.recentChatsSectionTitle) {
                    if recentThreads.isEmpty {
                        ContentUnavailableView(
                            TodayViewCopy.emptyRecentChatsTitle,
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(TodayViewCopy.emptyRecentChatsDescription)
                        )
                    } else {
                        ForEach(recentThreads) { thread in
                            NavigationLink {
                                ChatDetailView(thread: thread)
                            } label: {
                                ChatThreadRow(thread: thread)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(12)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountMenuButton()
                }
            }
            .sheet(item: $editingTodo) { todo in
                TodoEditorView(todo: todo)
            }
            .task {
                self.snapshot = TodaySnapshot(todos: todos)
                await refreshLatestData()
            }
            .onChange(of: todoSignature) { _, _ in
                self.snapshot = TodaySnapshot(todos: todos)
            }
            .refreshable {
                // An explicit pull is a demand for fresh data; bypass the
                // conditional (ETag) fast path.
                await refreshLatestData(force: true)
            }
        }
    }

    private func refreshLatestData(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // The briefs fetch is a pure network read; run it alongside the
        // SwiftData sync instead of after it.
        let sessionToken = sessionStore.user?.sessionToken
        async let fetchedBriefs = Self.fetchBriefs(sessionToken: sessionToken)

        do {
            try await ProductionDataSync.refreshAll(
                sessionStore: sessionStore,
                modelContext: modelContext,
                includeCards: true,
                force: force
            )
            refreshErrorMessage = nil
        } catch {
            refreshErrorMessage = "Could not refresh your latest brief. \(MobileErrorCopy.message(for: error))"
        }

        if let fetched = await fetchedBriefs {
            briefs = fetched
        }
    }

    private static func fetchBriefs(sessionToken: String?) async -> [MobileAPIClient.RemoteBrief]? {
        guard let sessionToken else { return nil }
        return try? await MobileAPIClient().listBriefs(sessionToken: sessionToken)
    }

    private func briefingHeroSection(_ engineBrief: TodayBrief) -> some View {
        Section {
            if let todayBrief {
                NavigationLink {
                    BriefDetailView(brief: todayBrief)
                } label: {
                    MorningBriefingCard(brief: todayBrief)
                }
                .buttonStyle(.plain)
            } else {
                TodayBriefCard(
                    greeting: greeting,
                    brief: engineBrief
                ) {
                    navigate(to: engineBrief.destination)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func briefingGroupSections(_ groups: [BriefingGroups.Group]) -> some View {
        ForEach(groups) { group in
            Section(group.title) {
                ForEach(group.todos) { todo in
                    NavigationLink {
                        TodoDetailView(todo: todo)
                    } label: {
                        TodoRow(todo: todo) {
                            completeFocusTodo(todo)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var previousBriefingsSection: some View {
        if !previousBriefs.isEmpty {
            Section(MorningBriefingCopy.previousSectionTitle) {
                ForEach(previousBriefs) { pastBrief in
                    NavigationLink {
                        BriefDetailView(brief: pastBrief)
                    } label: {
                        PreviousBriefRow(brief: pastBrief)
                    }
                }
            }
        }
    }

    private func navigate(to destination: TodayDestination) {
        switch destination {
        case .todos(let filter):
            appNavigation.showTodos(filter)
        case .chat:
            appNavigation.showChat()
        }
    }

    @ViewBuilder
    private func focusRow(for item: TodayFocusItem, todosByID: [UUID: TodoItem]) -> some View {
        switch item.kind {
        case .todo:
            if let todo = todosByID[item.referenceID] {
                NavigationLink {
                    TodoDetailView(todo: todo)
                } label: {
                    TodayFocusRow(item: item)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        completeFocusTodo(todo)
                    } label: {
                        Label(TodayViewCopy.completeFocusActionLabel, systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        dismissFocusTodo(todo)
                    } label: {
                        Label(TodayViewCopy.dismissFocusActionLabel, systemImage: "trash")
                    }

                    Button {
                        editingTodo = todo
                    } label: {
                        Label(TodayViewCopy.editFocusActionLabel, systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            } else {
                TodayFocusRow(item: item)
            }
        }
    }

    private func completeFocusTodo(_ todo: TodoItem) {
        actionErrorMessage = nil
        todo.setCompleted(true)
        guard saveLocalFocusChange(failureMessage: TodayViewCopy.localCompleteFailedMessage) else {
            return
        }

        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "done"
                )
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalFocusChange(failureMessage: TodayViewCopy.remoteCompleteSaveFailedMessage)
            } catch {
                todo.setCompleted(false)
                if saveLocalFocusChange(failureMessage: TodayViewCopy.restoreFocusFailedMessage) {
                    actionErrorMessage = focusActionMessage(
                        TodayViewCopy.remoteCompleteFailedPrefix,
                        error: error
                    )
                }
            }
        }
    }

    private func dismissFocusTodo(_ todo: TodoItem) {
        actionErrorMessage = nil

        guard let sessionToken = sessionStore.user?.sessionToken else {
            modelContext.delete(todo)
            _ = saveLocalFocusChange(failureMessage: TodayViewCopy.localDismissFailedMessage)
            return
        }

        Task { @MainActor in
            do {
                _ = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "dismiss"
                )
                modelContext.delete(todo)
                _ = saveLocalFocusChange(failureMessage: TodayViewCopy.remoteDismissSaveFailedMessage)
            } catch let error as MobileAPIError where error.isNotFound {
                modelContext.delete(todo)
                _ = saveLocalFocusChange(failureMessage: TodayViewCopy.remoteDismissSaveFailedMessage)
            } catch {
                actionErrorMessage = focusActionMessage(
                    TodayViewCopy.remoteDismissFailedPrefix,
                    error: error
                )
            }
        }
    }

    private func focusActionMessage(_ prefix: String, error: Error) -> String {
        "\(prefix) \(MobileErrorCopy.message(for: error))"
    }

    @discardableResult
    private func saveLocalFocusChange(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            actionErrorMessage = failureMessage
            return false
        }
    }

    private var greeting: String {
        let name = sessionStore.user?.email
            .split(separator: "@")
            .first
            .map(String.init)?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized

        if let name, !name.isEmpty {
            return "Good \(daypart), \(name)"
        }

        return "Good \(daypart)"
    }

    private var daypart: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "morning"
        case 12..<17:
            return "afternoon"
        default:
            return "evening"
        }
    }
}

/// One derived snapshot of everything the Today body reads from the todos
/// query. Rebuilt only when the todo content signature changes, so the body no
/// longer runs the O(n) work-engine passes on every render.
private struct TodaySnapshot {
    let metrics: TodayMetrics
    let brief: TodayBrief
    let focusItems: [TodayFocusItem]
    let briefingGroups: [BriefingGroups.Group]
    let todosByID: [UUID: TodoItem]

    init(todos: [TodoItem]) {
        metrics = TodayWorkEngine.metrics(todos: todos)
        brief = TodayWorkEngine.brief(todos: todos)
        focusItems = TodayWorkEngine.focusQueue(todos: todos)
        briefingGroups = BriefingGroups.groups(todos: todos)
        todosByID = Dictionary(todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

enum TodayViewCopy {
    static let actionSectionTitle = "Next actions"
    static let focusSectionTitle = "Today's focus"
    static let recentChatsSectionTitle = "Recent chats"
    static let actionWarningTitle = "Focus action was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss focus action warning"
    static let askMaraithonTitle = "Ask Maraithon"
    static let askMaraithonSubtitle = "Plan, draft, or prioritize"
    static let decisionsTitle = "Decisions"
    static let decisionsSubtitle = "Calls waiting on you"
    static let openWorkTitle = "Needs action"
    static let openWorkSubtitle = "Ranked work waiting on you"
    static let overdueTitle = "Past due"
    static let overdueSubtitle = "Needs action"
    static let dueTodayTitle = "Due today"
    static let dueTodaySubtitle = "Before tomorrow"
    static let emptyFocusTitle = "Nothing needs your review right now"
    static let emptyFocusDescription = "No saved decision, deadline, or open work item is waiting. Maraithon will surface the next concrete move when one appears."
    static let emptyRecentChatsTitle = "No recent chats"
    static let emptyRecentChatsDescription = "Start a chat when you need a draft, summary, or prioritization pass."
    static let completeFocusActionLabel = "Done"
    static let dismissFocusActionLabel = "Dismiss"
    static let editFocusActionLabel = "Edit"
    static let localCompleteFailedMessage = "Could not complete the focus item on this device. Today stayed unchanged."
    static let localDismissFailedMessage = "Could not dismiss the focus item on this device. Today stayed unchanged."
    static let remoteCompleteFailedPrefix = "Could not complete the focus item."
    static let remoteDismissFailedPrefix = "Could not dismiss the focus item."
    static let remoteCompleteSaveFailedMessage = "Maraithon completed the focus item. Refresh Today to show the latest state on this device."
    static let remoteDismissSaveFailedMessage = "Maraithon dismissed the focus item. Refresh Today to remove it from this device."
    static let restoreFocusFailedMessage = "Could not restore the focus item after the update failed. Refresh Today to show the latest state."

    static var actionLabels: [String] {
        [
            actionSectionTitle,
            focusSectionTitle,
            recentChatsSectionTitle,
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            askMaraithonTitle,
            askMaraithonSubtitle,
            decisionsTitle,
            decisionsSubtitle,
            openWorkTitle,
            openWorkSubtitle,
            overdueTitle,
            overdueSubtitle,
            dueTodayTitle,
            dueTodaySubtitle,
            emptyFocusTitle,
            emptyFocusDescription,
            emptyRecentChatsTitle,
            emptyRecentChatsDescription,
            completeFocusActionLabel,
            dismissFocusActionLabel,
            editFocusActionLabel,
            localCompleteFailedMessage,
            localDismissFailedMessage,
            remoteCompleteFailedPrefix,
            remoteDismissFailedPrefix,
            remoteCompleteSaveFailedMessage,
            remoteDismissSaveFailedMessage,
            restoreFocusFailedMessage
        ]
    }
}

private struct TodayBriefCard: View {
    let greeting: String
    let brief: TodayBrief
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: brief.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(brief.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(brief.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    HStack(spacing: 4) {
                        Text(brief.actionTitle)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(brief.title). \(brief.subtitle). \(brief.actionTitle).")
    }
}

private struct TodayFocusRow: View {
    let item: TodayFocusItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28)
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch item.kind {
        case .todo: .orange
        }
    }
}
