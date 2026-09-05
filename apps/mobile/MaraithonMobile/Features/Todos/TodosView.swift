import SwiftData
import SwiftUI

struct TodosView: View {
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \TodoItem.updatedAt, order: .reverse) private var todos: [TodoItem]
    @State private var filter: TodoFilter = .needsAction
    @State private var searchText = ""
    @State private var isAddingTodo = false
    @State private var editingTodo: TodoItem?
    @State private var selectedTodo: TodoItem?
    @State private var actionErrorMessage: String?
    @State private var refreshErrorMessage: String?
    @State private var isRefreshing = false
    @State private var workLists: TodoWorkLists?

    private var emptyState: TodoEmptyState {
        filter.emptyState(searchText: searchText, hasAnyWork: !todos.isEmpty)
    }

    /// Cheap content fingerprint compared in `onChange`; identity-based array
    /// equality would miss in-place edits like completing a todo.
    private var todoSignature: Int {
        TodoListSignature.signature(for: todos)
    }

    private var currentWorkLists: TodoWorkLists {
        workLists ?? TodoWorkLists(todos: todos, filter: filter, searchText: searchText)
    }

    var body: some View {
        let lists = currentWorkLists
        NavigationStack {
            VStack(spacing: 0) {
                TodoFilterStrip(selection: $filter, counts: lists.counts)

                if let refreshErrorMessage {
                    SyncIssueBanner(
                        message: refreshErrorMessage,
                        retry: { Task { await refreshLatestWork(force: true) } },
                        dismiss: { self.refreshErrorMessage = nil }
                    )
                }

                if let actionErrorMessage {
                    SyncIssueBanner(
                        title: TodosViewCopy.actionWarningTitle,
                        message: actionErrorMessage,
                        buttonTitle: nil,
                        retry: nil,
                        dismissAccessibilityLabel: TodosViewCopy.dismissActionWarningAccessibilityLabel,
                        dismiss: { self.actionErrorMessage = nil }
                    )
                }

                List {
                    if lists.filtered.isEmpty {
                        ContentUnavailableView(
                            emptyState.title,
                            systemImage: emptyState.systemImage,
                            description: Text(emptyState.description)
                        )
                    } else {
                        ForEach(lists.filtered) { todo in
                            TodoRow(todo: todo) {
                                toggle(todo)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedTodo = todo
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    toggle(todo)
                                } label: {
                                    Label(
                                        todo.isCompleted ? "Reopen" : "Complete",
                                        systemImage: todo.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle"
                                    )
                                }
                                .tint(todo.isCompleted ? .orange : .green)

                                if todo.attentionMode == .monitor, todo.isActive {
                                    Button {
                                        markNeedsAction(todo)
                                    } label: {
                                        Label("Act now", systemImage: "exclamationmark.circle")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(todo)
                                } label: {
                                    Label(TodosViewCopy.dismissActionLabel, systemImage: "trash")
                                }

                                Button {
                                    editingTodo = todo
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)

                                if todo.status == .open {
                                    Button {
                                        snooze(todo)
                                    } label: {
                                        Label("Snooze", systemImage: "clock")
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                        .onDelete(perform: deleteTodos)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(filter.navigationTitle)
            .searchable(text: $searchText, prompt: filter.searchPrompt)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingTodo = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add work item")
                }
            }
            .sheet(isPresented: $isAddingTodo) {
                TodoEditorView()
            }
            .sheet(item: $editingTodo) { todo in
                TodoEditorView(todo: todo)
            }
            .navigationDestination(item: $selectedTodo) { todo in
                TodoDetailView(todo: todo)
            }
            .task {
                rebuildWorkLists()
                await refreshLatestWork()
            }
            .onChange(of: todoSignature) { _, _ in
                rebuildWorkLists()
            }
            .onChange(of: searchText) { _, _ in
                rebuildWorkLists()
            }
            .onChange(of: filter) { _, _ in
                rebuildWorkLists()
            }
            .refreshable {
                // An explicit pull is a demand for fresh data; bypass the
                // conditional (ETag) fast path.
                await refreshLatestWork(force: true)
            }
            .onAppear(perform: applyRequestedFilterIfNeeded)
            .onChange(of: appNavigation.requestedTodoFilter) { _, _ in
                applyRequestedFilterIfNeeded()
            }
        }
    }

    private func rebuildWorkLists() {
        workLists = TodoWorkLists(todos: todos, filter: filter, searchText: searchText)
    }

    private func refreshLatestWork(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await ProductionDataSync.refreshTodos(
                sessionStore: sessionStore,
                modelContext: modelContext,
                includeCards: true,
                force: force
            )
            refreshErrorMessage = nil
        } catch {
            refreshErrorMessage = "Could not refresh work. \(MobileErrorCopy.message(for: error))"
        }
    }

    private func toggle(_ todo: TodoItem) {
        let completed = !todo.isCompleted
        actionErrorMessage = nil
        todo.setCompleted(completed)
        guard saveLocalWorkChange(failureMessage: TodosViewCopy.localUpdateFailedMessage) else {
            return
        }

        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        Task { @MainActor in
            do {
                let remote = if completed {
                    try await MobileAPIClient().performTodoAction(
                        sessionToken: sessionToken,
                        id: todo.id,
                        action: "done"
                    )
                } else {
                    try await MobileAPIClient().updateTodo(
                        sessionToken: sessionToken,
                        id: todo.id,
                        payload: ["status": .string("open")]
                    )
                }
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
            } catch {
                todo.setCompleted(!completed)
                if saveLocalWorkChange(failureMessage: TodosViewCopy.restoreFailedMessage) {
                    actionErrorMessage = todoActionMessage("Could not update work item.", error: error)
                }
            }
        }
    }

    private func deleteTodos(at offsets: IndexSet) {
        let filtered = currentWorkLists.filtered
        let todosToDelete = offsets.compactMap { index in
            filtered.indices.contains(index) ? filtered[index] : nil
        }
        todosToDelete.forEach(delete)
    }

    private func delete(_ todo: TodoItem) {
        actionErrorMessage = nil

        guard let sessionToken = sessionStore.user?.sessionToken else {
            modelContext.delete(todo)
            _ = saveLocalWorkChange(failureMessage: TodosViewCopy.localDeleteFailedMessage)
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
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteDeleteSaveFailedMessage)
            } catch let error as MobileAPIError where error.isNotFound {
                modelContext.delete(todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteDeleteSaveFailedMessage)
            } catch {
                actionErrorMessage = todoActionMessage(TodosViewCopy.remoteDismissFailedPrefix, error: error)
            }
        }
    }

    private func snooze(_ todo: TodoItem) {
        actionErrorMessage = nil
        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "snooze",
                    snoozedUntil: Calendar.current.date(byAdding: .day, value: 1, to: Date())
                )
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
            } catch {
                actionErrorMessage = todoActionMessage(TodosViewCopy.remoteSnoozeFailedPrefix, error: error)
            }
        }
    }

    private func markNeedsAction(_ todo: TodoItem) {
        actionErrorMessage = nil
        guard let sessionToken = sessionStore.user?.sessionToken else { return }

        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().performTodoAction(
                    sessionToken: sessionToken,
                    id: todo.id,
                    action: "important"
                )
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalWorkChange(failureMessage: TodosViewCopy.remoteUpdateSaveFailedMessage)
            } catch {
                actionErrorMessage = todoActionMessage(TodosViewCopy.remoteImportanceFailedPrefix, error: error)
            }
        }
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requestedFilter = appNavigation.requestedTodoFilter else { return }
        filter = requestedFilter
        appNavigation.requestedTodoFilter = nil
    }

    private func todoActionMessage(_ prefix: String, error: Error) -> String {
        "\(prefix) \(MobileErrorCopy.message(for: error))"
    }

    @discardableResult
    private func saveLocalWorkChange(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            actionErrorMessage = failureMessage
            return false
        }
    }
}

/// Derived list state for the Todos tab, rebuilt only when the todos content,
/// search text, or filter changes instead of on every body pass.
private struct TodoWorkLists {
    let filtered: [TodoItem]
    let counts: TodoFilterCounts

    init(todos: [TodoItem], filter: TodoFilter, searchText: String) {
        filtered = TodoFiltering.filter(todos, by: filter, searchText: searchText)
        counts = TodoFiltering.counts(in: todos, searchText: searchText)
    }
}

enum TodosViewCopy {
    static let actionWarningTitle = "Work item update was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss work item warning"
    static let dismissActionLabel = "Dismiss"
    static let localUpdateFailedMessage = "Could not update the work item on this device. Your work list stayed unchanged."
    static let localDeleteFailedMessage = "Could not dismiss the work item on this device. Your work list stayed unchanged."
    static let remoteDismissFailedPrefix = "Could not dismiss work item."
    static let remoteSnoozeFailedPrefix = "Could not snooze work item."
    static let remoteImportanceFailedPrefix = "Could not move work item to needs action."
    static let remoteUpdateSaveFailedMessage = "Maraithon updated the work item. Refresh work to show the latest state on this device."
    static let remoteDeleteSaveFailedMessage = "Maraithon dismissed the work item. Refresh work to remove it from this device."
    static let restoreFailedMessage = "Could not restore the work item after the update failed. Refresh work to show the latest state."

    static var localSaveFailureLabels: [String] {
        [
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            dismissActionLabel,
            localUpdateFailedMessage,
            localDeleteFailedMessage,
            remoteDismissFailedPrefix,
            remoteSnoozeFailedPrefix,
            remoteImportanceFailedPrefix,
            remoteUpdateSaveFailedMessage,
            remoteDeleteSaveFailedMessage,
            restoreFailedMessage
        ]
    }
}
