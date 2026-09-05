import Foundation

enum TodoFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case open
    case needsAction
    case watching
    case decisions
    case today
    case overdue
    case upcoming
    case snoozed
    case completed

    var id: String { rawValue }

    static var allCases: [TodoFilter] {
        [.needsAction, .watching, .decisions, .today, .overdue, .snoozed, .completed, .all]
    }

    var title: String {
        switch self {
        case .all: "All"
        case .open: "Active"
        case .needsAction: "Act now"
        case .watching: "Watching"
        case .decisions: "Decisions"
        case .today: "Today"
        case .overdue: "Past due"
        case .upcoming: "Upcoming"
        case .snoozed: "Snoozed"
        case .completed: "Done"
        }
    }

    var navigationTitle: String {
        switch self {
        case .all: "All Work"
        case .open: "Active Work"
        case .needsAction: "Needs Action"
        case .watching: "Watching"
        case .decisions: "Decisions"
        case .today: "Today"
        case .overdue: "Past-due work"
        case .upcoming: "Upcoming"
        case .snoozed: "Snoozed"
        case .completed: "Completed"
        }
    }

    var searchPrompt: String {
        switch self {
        case .all: "Search work"
        case .open: "Search active work"
        case .needsAction: "Search work needing action"
        case .watching: "Search watched work"
        case .decisions: "Search decisions"
        case .today: "Search today's work"
        case .overdue: "Search past-due work"
        case .upcoming: "Search upcoming work"
        case .snoozed: "Search snoozed work"
        case .completed: "Search completed work"
        }
    }

    func emptyState(searchText: String, hasAnyWork: Bool) -> TodoEmptyState {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !query.isEmpty {
            return TodoEmptyState(
                title: "No matching work",
                systemImage: "magnifyingglass",
                description: "No \(searchScopeLabel) matches \"\(query)\". Clear search or switch filters."
            )
        }

        if !hasAnyWork {
            return TodoEmptyState(
                title: "No work yet",
                systemImage: "checklist",
                description: "Add a follow-up or ask Maraithon to turn messages, notes, and meetings into next actions."
            )
        }

        switch self {
        case .all:
            return TodoEmptyState(
                title: "No work matches this filter",
                systemImage: "checklist",
                description: "Switch filters, add a follow-up, or ask Maraithon to keep a commitment visible."
            )
        case .open:
            return TodoEmptyState(
                title: "No active work",
                systemImage: "checklist",
                description: "Nothing is open or snoozed. Add a follow-up, or ask Maraithon to keep the next commitment visible."
            )
        case .needsAction:
            return TodoEmptyState(
                title: "Nothing needs action",
                systemImage: "checkmark.circle",
                description: "Your active work is handled for now. Watching and snoozed items remain available in their filters."
            )
        case .watching:
            return TodoEmptyState(
                title: "Nothing being watched",
                systemImage: "eye",
                description: "Items Maraithon is monitoring without asking you to act will appear here."
            )
        case .decisions:
            return TodoEmptyState(
                title: "No decisions waiting",
                systemImage: "checkmark.seal",
                description: "Decision work appears here when Maraithon has enough context to ask for a call, approval, or keep-or-close choice."
            )
        case .today:
            return TodoEmptyState(
                title: "No work due today",
                systemImage: "calendar",
                description: "No saved work in this filter is due today. Move one open item into today when the next decision belongs there."
            )
        case .overdue:
            return TodoEmptyState(
                title: "No past-due work",
                systemImage: "clock.badge.checkmark",
                description: "No saved work is past due in this filter. Today will keep decision-ready work visible."
            )
        case .upcoming:
            return TodoEmptyState(
                title: "No upcoming work",
                systemImage: "calendar.badge.clock",
                description: "Future-dated commitments appear here once a due date is set."
            )
        case .snoozed:
            return TodoEmptyState(
                title: "No snoozed work",
                systemImage: "clock",
                description: "Work you pause will remain here until it is ready to return."
            )
        case .completed:
            return TodoEmptyState(
                title: "No completed work",
                systemImage: "checkmark.circle",
                description: "Closed items appear here after you mark work done."
            )
        }
    }

    private var searchScopeLabel: String {
        switch self {
        case .all: "work"
        case .open: "active work"
        case .needsAction: "work needing action"
        case .watching: "watched work"
        case .decisions: "decisions"
        case .today: "work due today"
        case .overdue: "past-due work"
        case .upcoming: "upcoming work"
        case .snoozed: "snoozed work"
        case .completed: "completed work"
        }
    }
}

struct TodoEmptyState: Equatable {
    let title: String
    let systemImage: String
    let description: String
}

struct TodoFilterCounts: Equatable {
    let all: Int
    let open: Int
    let needsAction: Int
    let watching: Int
    let decisions: Int
    let today: Int
    let overdue: Int
    let upcoming: Int
    let snoozed: Int
    let completed: Int

    func value(for filter: TodoFilter) -> Int {
        switch filter {
        case .all: all
        case .open: open
        case .needsAction: needsAction
        case .watching: watching
        case .decisions: decisions
        case .today: today
        case .overdue: overdue
        case .upcoming: upcoming
        case .snoozed: snoozed
        case .completed: completed
        }
    }
}

enum TodoFiltering {
    /// Single pass over the todos with per-filter accumulators; the previous
    /// implementation ran the full filter pipeline seven times.
    static func counts(
        in todos: [TodoItem],
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodoFilterCounts {
        let query = normalizedQuery(searchText)
        var all = 0
        var open = 0
        var needsAction = 0
        var watching = 0
        var decisions = 0
        var today = 0
        var overdue = 0
        var upcoming = 0
        var snoozed = 0
        var completed = 0

        for todo in todos {
            guard matchesSearch(todo, query: query) else { continue }

            all += 1

            if todo.status == .done {
                completed += 1
            }

            if todo.isActive {
                open += 1
            }

            if todo.needsActionNow {
                needsAction += 1
            }

            if todo.isActive, todo.attentionMode == .monitor {
                watching += 1
            }

            if todo.status == .snoozed {
                snoozed += 1
            }

            if TodoDecisionSignals.needsDecision(todo) {
                decisions += 1
            }

            if todo.needsActionNow, let dueDate = todo.dueDate {
                if calendar.isDate(dueDate, inSameDayAs: now) {
                    today += 1
                } else if dueDate < now {
                    overdue += 1
                } else if dueDate > now {
                    upcoming += 1
                }
            }
        }

        return TodoFilterCounts(
            all: all,
            open: open,
            needsAction: needsAction,
            watching: watching,
            decisions: decisions,
            today: today,
            overdue: overdue,
            upcoming: upcoming,
            snoozed: snoozed,
            completed: completed
        )
    }

    static func filter(
        _ todos: [TodoItem],
        by filter: TodoFilter,
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TodoItem] {
        let query = normalizedQuery(searchText)

        return todos.filter { todo in
            guard matchesSearch(todo, query: query) else { return false }

            switch filter {
            case .all:
                return true
            case .open:
                return todo.isActive
            case .needsAction:
                return todo.needsActionNow
            case .watching:
                return todo.isActive && todo.attentionMode == .monitor
            case .decisions:
                return TodoDecisionSignals.needsDecision(todo)
            case .today:
                guard let dueDate = todo.dueDate else { return false }
                return todo.needsActionNow && calendar.isDate(dueDate, inSameDayAs: now)
            case .overdue:
                guard let dueDate = todo.dueDate else { return false }
                return todo.needsActionNow && dueDate < now && !calendar.isDate(dueDate, inSameDayAs: now)
            case .upcoming:
                guard let dueDate = todo.dueDate else { return false }
                return todo.needsActionNow && dueDate > now && !calendar.isDate(dueDate, inSameDayAs: now)
            case .snoozed:
                return todo.status == .snoozed
            case .completed:
                return todo.status == .done
            }
        }.sorted(by: rankedBefore)
    }

    /// Mirrors the server's authoritative `sort=rank` ordering for offline
    /// filtering: needs-action first, then priority, due date, and freshness.
    private static func rankedBefore(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        let lhsAttention = lhs.attentionMode == .actNow ? 0 : 1
        let rhsAttention = rhs.attentionMode == .actNow ? 0 : 1
        if lhsAttention != rhsAttention { return lhsAttention < rhsAttention }

        if lhs.priority != rhs.priority {
            return priorityWeight(lhs.priority) > priorityWeight(rhs.priority)
        }

        switch (lhs.dueDate, rhs.dueDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func priorityWeight(_ priority: TodoPriority) -> Int {
        switch priority {
        case .critical: 4
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    static func overdueCount(
        in todos: [TodoItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        filter(todos, by: .overdue, now: now, calendar: calendar).count
    }

    private static func normalizedQuery(_ searchText: String) -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matchesSearch(_ todo: TodoItem, query: String) -> Bool {
        guard !query.isEmpty else { return true }

        if todo.title.lowercased().contains(query) { return true }
        if todo.notes.lowercased().contains(query) { return true }
        if let nextAction = todo.nextAction, nextAction.lowercased().contains(query) { return true }
        if todo.priority.title.lowercased().contains(query) { return true }

        if let contact = todo.contact {
            if contact.name.lowercased().contains(query) { return true }
            if contact.company.lowercased().contains(query) { return true }
        }

        return false
    }
}

/// Content fingerprint over the todo fields that feed derived list state
/// (filters, counts, decision signals, focus queues). Views compare it in
/// `onChange` to decide when a cached snapshot must be rebuilt; identity-based
/// array equality would miss in-place edits like completing a todo.
enum TodoListSignature {
    static func signature(for todos: [TodoItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(todos.count)

        for todo in todos {
            hasher.combine(todo.id)
            hasher.combine(todo.title)
            hasher.combine(todo.notes)
            hasher.combine(todo.nextAction)
            hasher.combine(todo.isCompleted)
            hasher.combine(todo.statusRawValue)
            hasher.combine(todo.attentionModeRawValue)
            hasher.combine(todo.snoozedUntil)
            hasher.combine(todo.dueDate)
            hasher.combine(todo.priorityRawValue)
            hasher.combine(todo.updatedAt)
            hasher.combine(todo.decisionPrompt)
            hasher.combine(todo.decisionContextSummary)
            hasher.combine(todo.whyNow)
            hasher.combine(todo.sourceContext)
            hasher.combine(todo.nextBestAction)
            hasher.combine(todo.draftPreview)
            hasher.combine(todo.evidenceExcerpt)
            hasher.combine(todo.rankReason)
            hasher.combine(todo.todoBriefData)
            hasher.combine(todo.sourceSystem)
        }

        return hasher.finalize()
    }
}

enum TodoDecisionSignals {
    static func needsDecision(_ todo: TodoItem) -> Bool {
        guard todo.needsActionNow else { return false }

        if let decisionPrompt = ChiefOfStaffCopy.clean(todo.decisionPrompt),
           !isGenericDecisionPrompt(decisionPrompt) {
            return true
        }

        if waitingSignal(in: todo.whyNow) ||
            waitingSignal(in: todo.notes) ||
            waitingSignal(in: todo.decisionContextSummary) {
            return true
        }

        // Action-card presence alone is not a decision. Require a real call
        // (waiting language or a concrete decision prompt). Stale keep/close
        // cards still qualify via their keep-or-dismiss prompt once cleaned
        // of the generic template, or via waitingSignal/whyNow below.
        if hasSignalText(todo.nextBestAction),
           hasSignalText(todo.evidenceExcerpt),
           waitingSignal(in: todo.whyNow) || waitingSignal(in: todo.notes) {
            return true
        }

        // Keep/close confirmation is an intentional Decision even when the
        // prompt template is otherwise treated as generic elsewhere.
        if TodoRowCopy.isStaleKeepClose(todo) {
            return true
        }

        return false
    }

    static func signalPillTitle(for todo: TodoItem) -> String? {
        needsDecision(todo) ? "Decision" : nil
    }

    private static func isGenericDecisionPrompt(_ value: String) -> Bool {
        let normalized = normalize(value)

        let genericPrompts = [
            "handle this now snooze it or dismiss it",
            "keep it active if it still matters or dismiss it so it stops resurfacing"
        ]

        return genericPrompts.contains(normalized)
    }

    private static func waitingSignal(in value: String?) -> Bool {
        guard let value else { return false }
        let lower = value.lowercased()

        return [
            "waiting",
            "needs your reply",
            "needs your decision",
            "needs operator attention",
            "no later reply",
            "you owe",
            "you need to approve",
            "before noon",
            "before today",
            "before tomorrow",
            "due today"
        ].contains { lower.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func hasSignalText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
