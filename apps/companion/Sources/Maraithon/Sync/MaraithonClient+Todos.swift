/// Todo requests fetch every page before replacing the visible collection.
/// Mutations stay scoped to the paired device's authenticated user.
import Foundation

extension MaraithonClient {
    func createTodo(_ draft: CompanionTodoDraft) async throws -> CompanionTodoDetailsResponse {
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/todos",
            body: try JSONEncoder().encode(draft),
            extraHeaders: ["Content-Type": "application/json"]
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompanionTodoDetailsResponse.self, from: data)
    }

    func listTodos(
        filter: TodoListFilter,
        query: String? = nil
    ) async throws -> CompanionTodosResponse {
        var offset = 0
        var todos: [CompanionTodo] = []
        var seenIDs = Set<String>()

        // Bound a malformed server response without presenting a partial list
        // as complete. Fifty pages accommodates 10,000 todos per filter.
        for _ in 0..<50 {
            try Task.checkCancellation()
            let page = try await todoPage(filter: filter, query: query, offset: offset)
            for todo in page.todos where seenIDs.insert(todo.id).inserted {
                todos.append(todo)
            }

            guard let nextOffset = page.pagination.nextOffset else {
                return CompanionTodosResponse(
                    todos: todos,
                    pagination: CompanionTodoPagination(
                        limit: page.pagination.limit,
                        offset: 0,
                        count: todos.count,
                        nextOffset: nil
                    )
                )
            }
            guard nextOffset > offset, !page.todos.isEmpty else {
                throw MaraithonClientError.invalidResponse
            }
            offset = nextOffset
        }
        throw MaraithonClientError.invalidResponse
    }

    /// Lists Todos through the paired-device bearer surface. The server
    /// derives the account from the token; the client never sends a user id.
    private func todoPage(
        filter: TodoListFilter,
        query: String?,
        offset: Int
    ) async throws -> CompanionTodosResponse {
        var queryItems = [
            URLQueryItem(name: "status", value: filter.rawValue),
            URLQueryItem(name: "sort", value: filter == .active ? "rank" : "updated"),
            URLQueryItem(name: "dir", value: "desc"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "include_cards", value: "false"),
            URLQueryItem(name: "open_cards_only", value: "true")
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        let request = try await makeRequest(
            method: "GET",
            path: "/api/v1/companion/todos",
            body: nil,
            queryItems: queryItems
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompanionTodosResponse.self, from: data)
    }

    /// Fetches richer source context only for the item being inspected.
    func todoDetails(id: String) async throws -> CompanionTodoDetailsResponse {
        let request = try await makeRequest(
            method: "GET",
            path: "/api/v1/companion/todos/\(id)",
            body: nil,
            queryItems: [URLQueryItem(name: "include_cards", value: "true")]
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        let details = try JSONDecoder().decode(CompanionTodoDetailsResponse.self, from: data)
        guard details.todo.id == id else { throw MaraithonClientError.invalidResponse }
        return details
    }

    /// Completes, dismisses, or reopens a Todo through the paired-device
    /// least-privilege action surface.
    func updateTodo(id: String, action: CompanionTodoAction) async throws -> CompanionTodoActionResponse {
        let request = try await makeRequest(
            method: "POST",
            path: "/api/v1/companion/todos/\(id)/actions/\(action.rawValue)",
            body: nil
        )
        let (data, response) = try await transport(request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompanionTodoActionResponse.self, from: data)
    }

}
