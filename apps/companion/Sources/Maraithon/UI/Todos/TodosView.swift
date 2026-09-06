import SwiftUI

/// Account-backed work list for the paired Mac. It mirrors the web Todo
/// surface's Gmail-style keyboard workflow while keeping all account data in
/// the main-actor store.
struct TodosView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var activeTodoID: String?
    @State private var markedTodoIDs: Set<String> = []
    @State private var inspectorShown = false
    @State private var shortcutHelpShown = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = env.todos

        VStack(alignment: .leading, spacing: 0) {
            TodosHeaderView(
                store: store,
                showShortcuts: { shortcutHelpShown = true }
            )
            Divider()
            controls(store: store)
            Divider()
            content(store: store)
        }
        .navigationTitle("Todos")
        .focusedSceneValue(\.todoShortcutActions, focusedShortcutActions(store: store))
        .inspector(isPresented: $inspectorShown) {
            TodoDetailView(
                todo: activeTodo,
                isWorking: activeTodo.map { store.pendingActionIDs.contains($0.id) } ?? false,
                isLoadingDetails: activeTodo.map { store.loadingDetailIDs.contains($0.id) } ?? false,
                detailError: activeTodoID.flatMap { store.detailErrors[$0] },
                primaryAction: { performPrimaryAction(store: store) },
                dismissAction: { perform(.dismiss, store: store) },
                retryDetails: {
                    if let todo = activeTodo { Task { await store.loadDetails(for: todo) } }
                }
            )
            .inspectorColumnWidth(
                min: Tokens.Layout.todoInspectorMinWidth,
                ideal: Tokens.Layout.todoInspectorIdealWidth,
                max: Tokens.Layout.todoInspectorMaxWidth
            )
        }
        .sheet(isPresented: $shortcutHelpShown) {
            TodoShortcutHelpView()
        }
        .task {
            if store.phase == .idle {
                await store.load()
            }
            reconcileSelection(store.todos)
        }
        .onChange(of: store.todos.map(\.id)) { _, _ in
            reconcileSelection(store.todos)
        }
        .task(id: inspectorShown ? "\(activeTodoID ?? ""):\(store.lastUpdatedAt?.timeIntervalSinceReferenceDate ?? 0)" : nil) {
            guard inspectorShown, let todo = activeTodo else { return }
            await store.loadDetails(for: todo)
        }
    }

    private var activeTodo: CompanionTodo? {
        guard let activeTodoID else { return nil }
        return env.todos.todos.first(where: { $0.id == activeTodoID })
    }

    private func controls(store: TodosStore) -> some View {
        @Bindable var store = store

        return HStack(spacing: Tokens.Spacing.small) {
            HStack(spacing: Tokens.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search title, next action, or source", text: $store.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        Task { await store.load() }
                    }
                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                        Task { await store.load() }
                    } label: {
                        Label("Clear search", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Tokens.Spacing.small)
            .padding(.vertical, Tokens.Spacing.xsmall)
            .background(.background, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }

            Picker("Status", selection: $store.filter) {
                ForEach(TodoListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            .onChange(of: store.filter) { _, _ in
                Task { await store.load() }
            }

            Button("Search") {
                Task { await store.load() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.small)
        .background(.bar)
    }

    @ViewBuilder
    private func content(store: TodosStore) -> some View {
        if case .failed(let message) = store.phase, store.todos.isEmpty {
            ContentUnavailableView {
                Label("Todos could not load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await store.load() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.todos.isEmpty, store.phase == .loaded {
            ContentUnavailableView(
                TodosCopy.emptyTitle(filter: store.filter, query: store.query),
                systemImage: store.filter == .active ? "checkmark.circle" : "clock.arrow.circlepath",
                description: Text(TodosCopy.emptyDescription(filter: store.filter, query: store.query))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if case .failed(let message) = store.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(StatusTone.attention.color)
                        .padding(.horizontal, Tokens.Spacing.large)
                        .padding(.vertical, Tokens.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                    Divider()
                }

                List(selection: $activeTodoID) {
                    ForEach(store.todos) { todo in
                        TodoRow(
                            todo: todo,
                            isMarked: markedTodoIDs.contains(todo.id),
                            isWorking: store.pendingActionIDs.contains(todo.id),
                            action: {
                                Task {
                                    await store.performPrimaryAction(on: todo)
                                    reconcileSelection(store.todos)
                                }
                            }
                        )
                        .tag(todo.id)
                    }
                }
                .listStyle(.inset)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    handleArrowKey(press, store: store)
                }
                .onKeyPress(.return) {
                    handle(.open, store: store)
                    return .handled
                }
                .onKeyPress(.escape) {
                    let wasShown = inspectorShown
                    handle(.back, store: store)
                    return wasShown ? .handled : .ignored
                }
            }
        }
    }

    private func focusedShortcutActions(store: TodosStore) -> TodoShortcutActions? {
        guard !searchFocused, !shortcutHelpShown else { return nil }
        return TodoShortcutActions { shortcut in
            handle(shortcut, store: store)
        }
    }

    private func handle(_ shortcut: TodoShortcut, store: TodosStore) {
        switch shortcut {
        case .next:
            moveActiveTodo(by: 1, in: store.todos)
        case .previous:
            moveActiveTodo(by: -1, in: store.todos)
        case .open:
            inspectorShown = activeTodo != nil
        case .back:
            inspectorShown = false
        case .select:
            toggleActiveTodoMark()
        case .complete:
            perform(.done, store: store)
        case .dismiss:
            perform(.dismiss, store: store)
        case .search:
            searchFocused = true
        case .help:
            shortcutHelpShown = true
        }
    }

    private func handleArrowKey(_ press: KeyPress, store: TodosStore) -> KeyPress.Result {
        switch press.key {
        case .rightArrow, .downArrow:
            moveActiveTodo(by: 1, in: store.todos)
        case .leftArrow, .upArrow:
            moveActiveTodo(by: -1, in: store.todos)
        default:
            return .ignored
        }
        return .handled
    }

    private func moveActiveTodo(by offset: Int, in todos: [CompanionTodo]) {
        guard !todos.isEmpty else { return }
        guard let activeTodoID,
              let index = todos.firstIndex(where: { $0.id == activeTodoID }) else {
            self.activeTodoID = todos.first?.id
            return
        }

        let targetIndex = index + offset
        guard todos.indices.contains(targetIndex) else { return }
        self.activeTodoID = todos[targetIndex].id
    }

    private func toggleActiveTodoMark() {
        guard let activeTodoID else { return }
        if markedTodoIDs.contains(activeTodoID) {
            markedTodoIDs.remove(activeTodoID)
        } else {
            markedTodoIDs.insert(activeTodoID)
        }
    }

    private func perform(_ action: CompanionTodoAction, store: TodosStore) {
        guard let todo = activeTodo else { return }
        guard action != .done || todo.canMarkDone else { return }
        guard action != .dismiss || todo.canDismiss else { return }

        Task {
            await store.perform(action, on: todo)
            markedTodoIDs.remove(todo.id)
            reconcileSelection(store.todos)
        }
    }

    private func performPrimaryAction(store: TodosStore) {
        guard let todo = activeTodo else { return }
        Task {
            await store.performPrimaryAction(on: todo)
            markedTodoIDs.remove(todo.id)
            reconcileSelection(store.todos)
        }
    }

    private func reconcileSelection(_ todos: [CompanionTodo]) {
        let visibleIDs = Set(todos.map(\.id))
        markedTodoIDs.formIntersection(visibleIDs)

        if let activeTodoID, visibleIDs.contains(activeTodoID) {
            return
        }

        activeTodoID = todos.first?.id
        if activeTodoID == nil {
            inspectorShown = false
        }
    }
}
