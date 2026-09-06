import Foundation
import Observation

/// Main-actor state for the account-backed Todo list. It keeps paired-device
/// data in memory only and clears it immediately when auth is rejected.
@Observable
@MainActor
final class TodosStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    typealias UnauthorizedHandler = @MainActor @Sendable () -> Void

    private(set) var todos: [CompanionTodo] = []
    private(set) var phase: Phase = .idle
    private(set) var pendingActionIDs: Set<String> = []
    private(set) var lastUpdatedAt: Date?
    private(set) var loadingDetailIDs: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    var filter: TodoListFilter = .active
    var query: String = ""

    private let client: MaraithonClient
    private let eventLog: EventLog
    private let unauthorizedHandler: UnauthorizedHandler
    private var loadGeneration = 0
    private var accountGeneration = 0
    private var detailRequestTokens: [String: UUID] = [:]

    init(
        client: MaraithonClient,
        eventLog: EventLog,
        unauthorizedHandler: @escaping UnauthorizedHandler
    ) {
        self.client = client
        self.eventLog = eventLog
        self.unauthorizedHandler = unauthorizedHandler
    }

    var isLoading: Bool {
        phase == .loading
    }

    func create(_ draft: CompanionTodoDraft) async throws -> CompanionTodo {
        let generation = accountGeneration
        eventLog.debug("todos.create_started", source: .cloud)
        do {
            let response = try await client.createTodo(draft)
            guard generation == accountGeneration else { throw CancellationError() }
            loadGeneration += 1
            if filter != .active || normalizedQuery != nil { todos = [] }
            filter = .active
            query = ""
            apply(response.todo)
            phase = .loaded
            eventLog.info("todos.create_finished", source: .cloud, payload: ["todo_id": response.todo.id])
            return response.todo
        } catch MaraithonClientError.unauthorized {
            if generation == accountGeneration { rejectToken() }
            throw MaraithonClientError.unauthorized
        } catch {
            eventLog.warning("todos.create_failed", source: .cloud)
            throw error
        }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let requestedFilter = filter
        let requestedQuery = normalizedQuery

        phase = .loading
        eventLog.debug(
            "todos.load_started",
            source: .cloud,
            payload: ["filter": requestedFilter.rawValue]
        )

        do {
            let response = try await client.listTodos(
                filter: requestedFilter,
                query: requestedQuery
            )
            guard generation == loadGeneration else { return }

            todos = response.todos
            detailErrors = [:]
            lastUpdatedAt = Date()
            phase = .loaded
            eventLog.info(
                "todos.load_finished",
                source: .cloud,
                payload: [
                    "filter": requestedFilter.rawValue,
                    "count": String(response.todos.count)
                ]
            )
        } catch MaraithonClientError.unauthorized {
            guard generation == loadGeneration else { return }
            rejectToken()
        } catch {
            guard generation == loadGeneration else { return }
            let message = CompanionErrorCopy.message(for: error)
            phase = .failed(message: message)
            eventLog.warning(
                "todos.load_failed",
                source: .cloud,
                payload: ["error": String(describing: error)]
            )
        }
    }

    func loadDetails(for todo: CompanionTodo) async {
        guard todo.actionCard == nil else { return }
        let generation = loadGeneration
        let requestToken = UUID()
        detailRequestTokens[todo.id] = requestToken
        loadingDetailIDs.insert(todo.id)
        detailErrors.removeValue(forKey: todo.id)
        eventLog.debug("todos.details_started", source: .cloud, payload: ["todo_id": todo.id])

        defer {
            if detailRequestTokens[todo.id] == requestToken {
                detailRequestTokens.removeValue(forKey: todo.id)
                loadingDetailIDs.remove(todo.id)
            }
        }

        do {
            let response = try await client.todoDetails(id: todo.id)
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  detailRequestTokens[todo.id] == requestToken,
                  todos.first(where: { $0.id == todo.id }) == todo else { return }
            apply(response.todo)
            eventLog.debug("todos.details_finished", source: .cloud, payload: ["todo_id": todo.id])
        } catch MaraithonClientError.unauthorized {
            guard !Task.isCancelled, generation == loadGeneration,
                  detailRequestTokens[todo.id] == requestToken else { return }
            rejectToken()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration,
                  detailRequestTokens[todo.id] == requestToken else { return }
            detailErrors[todo.id] = CompanionErrorCopy.message(for: error)
            eventLog.warning("todos.details_failed", source: .cloud, payload: ["todo_id": todo.id])
        }
    }

    func performPrimaryAction(on todo: CompanionTodo) async {
        let action: CompanionTodoAction
        if todo.canMarkDone {
            action = .done
        } else if todo.canReopen {
            action = .reopen
        } else {
            return
        }

        await perform(action, on: todo)
    }

    func perform(_ action: CompanionTodoAction, on todo: CompanionTodo) async {
        guard !pendingActionIDs.contains(todo.id) else { return }

        pendingActionIDs.insert(todo.id)
        defer { pendingActionIDs.remove(todo.id) }

        do {
            let response = try await client.updateTodo(id: todo.id, action: action)
            apply(response.todo)
            phase = .loaded
            eventLog.info(
                "todos.action_finished",
                source: .cloud,
                payload: ["action": action.rawValue, "todo_id": todo.id]
            )
        } catch MaraithonClientError.unauthorized {
            rejectToken()
        } catch {
            phase = .failed(message: CompanionErrorCopy.message(for: error))
            eventLog.warning(
                "todos.action_failed",
                source: .cloud,
                payload: [
                    "action": action.rawValue,
                    "todo_id": todo.id,
                    "error": String(describing: error)
                ]
            )
        }
    }

    func clear() {
        accountGeneration += 1
        loadGeneration += 1
        todos = []
        pendingActionIDs = []
        loadingDetailIDs = []
        detailErrors = [:]
        detailRequestTokens = [:]
        lastUpdatedAt = nil
        phase = .idle
        filter = .active
        query = ""
    }

    private var normalizedQuery: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func apply(_ todo: CompanionTodo) {
        let remainsVisible = switch filter {
        case .active:
            todo.status == "open" || todo.status == "snoozed"
        case .done:
            todo.status == "done"
        }

        if remainsVisible {
            if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                todos[index] = todo
            } else {
                todos.insert(todo, at: 0)
            }
        } else {
            todos.removeAll { $0.id == todo.id }
        }
        lastUpdatedAt = Date()
    }

    private func rejectToken() {
        clear()
        eventLog.warning("todos.unauthorized", source: .auth)
        unauthorizedHandler()
    }
}
