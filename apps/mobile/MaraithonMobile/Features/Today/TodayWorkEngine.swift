import Foundation

struct TodayMetrics: Equatable {
    let openTodos: Int
    let decisionTodos: Int
    let dueTodayTodos: Int
    let overdueTodos: Int
}

enum TodayDestination: Equatable {
    case todos(TodoFilter)
    case chat
}

struct TodayBrief: Equatable {
    let title: String
    let subtitle: String
    let actionTitle: String
    let systemImage: String
    let destination: TodayDestination
}

struct TodayFocusItem: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case todo
    }

    let kind: Kind
    let referenceID: UUID
    let title: String
    let subtitle: String
    let detail: String?
    let systemImage: String
    let priority: Int

    var id: String {
        "\(kind.rawValue)-\(referenceID.uuidString)"
    }
}

private struct TodayFocusCandidate {
    let title: String
    let sortTier: Int
    let updatedAt: Date
    let priority: Int
    let item: () -> TodayFocusItem
}

enum TodayWorkEngine {
    static func metrics(
        todos: [TodoItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodayMetrics {
        TodayMetrics(
            openTodos: TodoFiltering.filter(todos, by: .needsAction, now: now, calendar: calendar).count,
            decisionTodos: TodoFiltering.filter(todos, by: .decisions, now: now, calendar: calendar).count,
            dueTodayTodos: TodoFiltering.filter(todos, by: .today, now: now, calendar: calendar).count,
            overdueTodos: TodoFiltering.overdueCount(in: todos, now: now, calendar: calendar)
        )
    }

    static func brief(
        todos: [TodoItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodayBrief {
        let metrics = metrics(todos: todos, now: now, calendar: calendar)
        let overdueTodos = TodoFiltering.filter(todos, by: .overdue, now: now, calendar: calendar)
        let dueTodayTodos = TodoFiltering.filter(todos, by: .today, now: now, calendar: calendar)
        let openTodos = TodoFiltering.filter(todos, by: .needsAction, now: now, calendar: calendar)
        let overdueIDs = Set(overdueTodos.map(\.id))
        let currentOpenTodos = openTodos.filter { !overdueIDs.contains($0.id) }

        if metrics.dueTodayTodos > 0 {
            return TodayBrief(
                title: "Handle today's commitments",
                subtitle: dueTodayBriefSubtitle(
                    count: metrics.dueTodayTodos,
                    lead: topTodo(dueTodayTodos)
                ),
                actionTitle: "Review today's work",
                systemImage: "calendar.badge.clock",
                destination: .todos(.today)
            )
        }

        if !currentOpenTodos.isEmpty {
            return TodayBrief(
                title: "Review your latest work",
                subtitle: openWorkBriefSubtitle(
                    count: currentOpenTodos.count,
                    lead: topTodo(currentOpenTodos)
                ),
                actionTitle: "Review work needing action",
                systemImage: "tray.full",
                destination: .todos(.needsAction)
            )
        }

        if metrics.overdueTodos > 0 {
            return TodayBrief(
                title: "Resolve past-due work",
                subtitle: overdueBriefSubtitle(
                    count: metrics.overdueTodos,
                    lead: topTodo(overdueTodos)
                ),
                actionTitle: "Review past-due work",
                systemImage: "clock.badge.exclamationmark",
                destination: .todos(.overdue)
            )
        }

        return TodayBrief(
            title: "Nothing needs your review right now",
            subtitle: "No saved decision, deadline, or open work item is waiting. Ask Maraithon for a fresh priority call, draft, or summary when you need one.",
            actionTitle: "Start a review",
            systemImage: "sparkles",
            destination: .chat
        )
    }

    static func focusQueue(
        todos: [TodoItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TodayFocusItem] {
        let todoItems = todos.compactMap { todo -> TodayFocusCandidate? in
            guard todo.needsActionNow else { return nil }

            let dueToday = todo.dueDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            let overdue = todo.dueDate.map {
                $0 < now && !calendar.isDate($0, inSameDayAs: now)
            } ?? false
            let sortTier = dueToday ? 3 : (overdue ? 1 : 2)

            if let dueDate = todo.dueDate, overdue {
                let priority = 100 + priorityWeight(for: todo.priority)
                return TodayFocusCandidate(
                    title: todo.title,
                    sortTier: sortTier,
                    updatedAt: todo.updatedAt,
                    priority: priority
                ) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Handle, move, or dismiss it."
                        ),
                        detail: todoFocusDetail(
                            for: todo,
                            context: overdueFocusContext(for: todo, dueDate: dueDate, now: now, calendar: calendar)
                        ),
                        systemImage: "clock.badge.exclamationmark",
                        priority: priority
                    )
                }
            }

            if TodoDecisionSignals.needsDecision(todo) {
                let priority = 88 + priorityWeight(for: todo.priority)
                return TodayFocusCandidate(
                    title: todo.title,
                    sortTier: sortTier,
                    updatedAt: todo.updatedAt,
                    priority: priority
                ) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Make the call, delegate it, or dismiss it."
                        ),
                        detail: todoFocusDetail(
                            for: todo,
                            context: decisionFocusContext(for: todo, now: now, calendar: calendar)
                        ),
                        systemImage: "checkmark.seal",
                        priority: priority
                    )
                }
            }

            if todo.dueDate != nil, dueToday {
                let priority = 80 + priorityWeight(for: todo.priority)
                return TodayFocusCandidate(
                    title: todo.title,
                    sortTier: sortTier,
                    updatedAt: todo.updatedAt,
                    priority: priority
                ) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Finish, move, or reschedule it before tomorrow."
                        ),
                        detail: todoFocusDetail(for: todo, context: "Due today"),
                        systemImage: todo.priority.symbolName,
                        priority: priority
                    )
                }
            }

            if todo.priority == .critical || todo.priority == .high {
                let priority = todo.priority == .critical ? 85 : 65
                return TodayFocusCandidate(
                    title: todo.title,
                    sortTier: sortTier,
                    updatedAt: todo.updatedAt,
                    priority: priority
                ) {
                    TodayFocusItem(
                        kind: .todo,
                        referenceID: todo.id,
                        title: todo.title,
                        subtitle: todoFocusSubtitle(
                            for: todo,
                            fallbackAction: "Decide, delegate, or schedule a concrete next move."
                        ),
                        detail: todoFocusDetail(for: todo, context: "\(todo.priority.title) priority"),
                        systemImage: todo.priority.symbolName,
                        priority: priority
                    )
                }
            }

            let priority = 40 + priorityWeight(for: todo.priority)
            return TodayFocusCandidate(
                title: todo.title,
                sortTier: sortTier,
                updatedAt: todo.updatedAt,
                priority: priority
            ) {
                TodayFocusItem(
                    kind: .todo,
                    referenceID: todo.id,
                    title: todo.title,
                    subtitle: todoFocusSubtitle(
                        for: todo,
                        fallbackAction: "Choose the next move, schedule it, or dismiss it."
                    ),
                    detail: todoFocusDetail(for: todo, context: "Open work"),
                    systemImage: todo.priority.symbolName,
                    priority: priority
                )
            }
        }

        return todoItems
            .sorted {
                if $0.sortTier != $1.sortTier {
                    return $0.sortTier > $1.sortTier
                }
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(6)
            .map { $0.item() }
    }

    private static func priorityWeight(for priority: TodoPriority) -> Int {
        switch priority {
        case .critical: 25
        case .high: 15
        case .medium: 8
        case .low: 0
        }
    }

    private static func overdueBriefSubtitle(count: Int, lead: TodoItem?) -> String {
        guard let title = briefTitle(for: lead) else {
            return "\(count) past-due \(plural("work item", count)) \(needsVerb(count)) a decision. Handle, move, or dismiss \(objectPronoun(count))."
        }

        if count == 1 {
            return "\(title) is past due. \(briefMove(for: lead) ?? "Handle, move, or dismiss it.")"
        }

        if let move = briefMove(for: lead) {
            return "\(count) past-due work items need a decision. Start with \(title): \(move)"
        }

        return "\(count) past-due work items need a decision. Start with \(title)."
    }

    private static func dueTodayBriefSubtitle(count: Int, lead: TodoItem?) -> String {
        guard let title = briefTitle(for: lead) else {
            return "\(count) \(plural("work item", count)) \(isVerb(count)) due today."
        }

        if count == 1 {
            return "\(title) is due today. \(briefMove(for: lead) ?? "Move it before tomorrow or reschedule it.")"
        }

        if let move = briefMove(for: lead) {
            return "\(count) work items are due today. Start with \(title): \(move)"
        }

        return "\(count) work items are due today. Start with \(title)."
    }

    private static func openWorkBriefSubtitle(count: Int, lead: TodoItem?) -> String {
        guard let title = briefTitle(for: lead) else {
            return "\(count) open \(plural("work item", count)) \(needsVerb(count)) a date, next action, or close decision."
        }

        if count == 1 {
            if let move = briefMove(for: lead) {
                return "\(title): \(move)"
            }

            if lead?.dueDate != nil {
                return "\(title) needs a next action or close decision."
            }

            return "\(title) needs a date, next action, or close decision."
        }

        if let move = briefMove(for: lead) {
            return "\(count) open work items need triage. Start with \(title): \(move)"
        }

        return "\(count) open work items need triage. Start with \(title)."
    }

    private static func topTodo(_ todos: [TodoItem]) -> TodoItem? {
        todos.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            if $0.priority != $1.priority {
                return priorityWeight(for: $0.priority) > priorityWeight(for: $1.priority)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }.first
    }

    private static func briefTitle(for todo: TodoItem?) -> String? {
        cleanedText(todo?.title)
    }

    private static func briefMove(for todo: TodoItem?) -> String? {
        let move =
            cleanedText(todo?.nextBestAction) ??
            cleanedText(todo?.displayNextAction) ??
            cleanedText(todo?.decisionPrompt)

        return move.map(sentence)
    }

    private static func todoFocusSubtitle(
        for todo: TodoItem,
        fallbackAction: String
    ) -> String {
        if let decisionPrompt = cleanedText(todo.decisionPrompt) {
            return decisionPrompt
        }

        guard let nextAction = cleanedText(todo.displayNextAction) else {
            return "Next: \(sentence(fallbackAction))"
        }

        return "Next: \(sentence(nextAction))"
    }

    private static func todoFocusDetail(for todo: TodoItem, context: String?) -> String? {
        let decisionContext = TodoDecisionContext(todo: todo)
        let context = cleanedText(context).map(sentence)
        let whyNow = decisionContext.whyNow.map(sentence)
        let evidence = decisionContext.evidence.map { sentence(truncate($0, limit: 140)) }
        let sourceContext = decisionContext.sourceContext

        return [context, whyNow, evidence, sourceContext]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfBlank
    }

    private static func decisionFocusContext(
        for todo: TodoItem,
        now: Date,
        calendar: Calendar
    ) -> String {
        if let dueDate = todo.dueDate {
            if dueDate < now, !calendar.isDate(dueDate, inSameDayAs: now) {
                return "Decision waiting. \(dueSubtitle(for: dueDate, now: now))"
            }

            if calendar.isDate(dueDate, inSameDayAs: now) {
                return "Decision waiting. Due today"
            }
        }

        return "Decision waiting"
    }

    private static func overdueFocusContext(
        for todo: TodoItem,
        dueDate: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        if hasExplicitDecisionCard(todo) {
            return decisionFocusContext(for: todo, now: now, calendar: calendar)
        }

        return dueSubtitle(for: dueDate, now: now)
    }

    private static func hasExplicitDecisionCard(_ todo: TodoItem) -> Bool {
        let context = TodoDecisionContext(todo: todo)

        if context.decisionPrompt != nil {
            return true
        }

        return context.preparedMove != nil && context.evidence != nil
    }

    private static func dueSubtitle(for dueDate: Date, now: Date) -> String {
        "Due \(AppFormatters.relativeString(for: dueDate, relativeTo: now))"
    }

    private static func plural(_ singular: String, _ count: Int, plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? "\(singular)s")
    }

    private static func needsVerb(_ count: Int) -> String {
        count == 1 ? "needs" : "need"
    }

    private static func isVerb(_ count: Int) -> String {
        count == 1 ? "is" : "are"
    }

    private static func objectPronoun(_ count: Int) -> String {
        count == 1 ? "it" : "them"
    }

    private static func cleanedText(_ value: String?) -> String? {
        ChiefOfStaffCopy.clean(value)
    }

    private static func sentence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
            return trimmed
        }
        return "\(trimmed)."
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }

        let index = value.index(value.startIndex, offsetBy: limit)
        return "\(value[..<index].trimmingCharacters(in: .whitespacesAndNewlines))..."
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
