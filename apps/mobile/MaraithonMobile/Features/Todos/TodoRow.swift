import SwiftUI

struct TodoRow: View {
    let todo: TodoItem
    let onToggle: () -> Void

    /// Built once per row construction; the body reads it several times and
    /// each construction runs the copy-cleaning pipeline over ~8 fields.
    private let decisionContext: TodoDecisionContext

    init(todo: TodoItem, onToggle: @escaping () -> Void) {
        self.todo = todo
        self.onToggle = onToggle
        self.decisionContext = TodoDecisionContext(todo: todo)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 6) {
                Text(todo.title)
                    .font(.headline)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)

                if let rowContext = decisionContext.rowContext {
                    Text(rowContext)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let rowReason = decisionContext.rowReason {
                    Text(rowReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let nextAction = decisionContext.rowMove {
                    Label(nextAction, systemImage: "arrow.turn.down.right")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if todo.status == .snoozed {
                        StatusPill(title: TodoStatus.snoozed.title, tint: .orange)
                    } else if todo.attentionMode == .monitor, todo.isActive {
                        StatusPill(title: TodoAttentionMode.monitor.title, tint: .teal)
                    }

                    if let signal = TodoDecisionSignals.signalPillTitle(for: todo) {
                        StatusPill(title: signal, tint: .purple)
                    }

                    if todo.priority == .critical || todo.priority == .high {
                        StatusPill(title: todo.priority.title, tint: todo.priority.tint)
                    }

                    if let dueDate = todo.dueDate {
                        Label(dueText(for: dueDate), systemImage: dueSystemImage(for: dueDate))
                            .font(.caption)
                            .foregroundStyle(dueTint(for: dueDate))
                            .lineLimit(1)
                    }

                    if let contact = todo.contact {
                        Label(contact.name, systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let sourceLabel = sourceLabel {
                    Label(sourceLabel, systemImage: "tray.full")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func dueText(for dueDate: Date) -> String {
        TodoRowCopy.dueText(for: todo, dueDate: dueDate)
    }

    private var sourceLabel: String? {
        let label = todo.sourceProviderLabel ?? todo.sourceSystem
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func dueSystemImage(for dueDate: Date) -> String {
        guard !todo.isCompleted else { return "calendar" }
        if TodoRowCopy.isStaleKeepClose(todo) {
            return "questionmark.circle"
        }
        let calendar = Calendar.current
        if dueDate < Date(), !calendar.isDateInToday(dueDate) {
            return "clock.badge.exclamationmark"
        }
        if calendar.isDateInToday(dueDate) {
            return "calendar.badge.clock"
        }
        return "calendar"
    }

    private func dueTint(for dueDate: Date) -> Color {
        guard !todo.isCompleted else { return .secondary }
        if TodoRowCopy.isStaleKeepClose(todo) {
            return .secondary
        }
        let calendar = Calendar.current
        if dueDate < Date(), !calendar.isDateInToday(dueDate) {
            return .orange
        }
        if calendar.isDateInToday(dueDate) {
            return .blue
        }
        return .secondary
    }
}

struct TodoDecisionContext: Equatable {
    let contextSummary: String?
    let decisionPrompt: String?
    let notesContext: String?
    let whyNow: String?
    let sourceContext: String?
    let preparedMove: String?
    let draftPreview: String?
    let rowMove: String?
    let evidence: String?

    init(todo: TodoItem) {
        let brief = todo.todoBrief
        let title = Self.cleanedText(todo.title)
        let notes = Self.cleanedText(todo.notes)
        let nextAction = Self.cleanedText(todo.displayNextAction)
        let contextSummary = Self.uniqueText(
            brief?.situation ?? todo.decisionContextSummary,
            excludingCleaned: [title, notes, nextAction]
        )
        let decisionPrompt = Self.uniqueText(
            todo.decisionPrompt,
            excludingCleaned: [title, notes, nextAction, contextSummary]
        )
        let preparedMove = Self.uniqueText(
            brief?.recommendation ?? todo.nextBestAction,
            excludingCleaned: [title, notes, nextAction, contextSummary, decisionPrompt]
        )

        self.contextSummary = contextSummary
        self.decisionPrompt = decisionPrompt
        self.notesContext = Self.uniqueCleanedText(
            notes,
            excludingCleaned: [title, nextAction, contextSummary, decisionPrompt]
        )
        self.whyNow = Self.cleanedText(brief?.whyItMatters ?? todo.whyNow)
        self.sourceContext = Self.cleanedText(todo.sourceContext)
        self.preparedMove = preparedMove
        self.draftPreview = Self.uniqueText(
            todo.draftPreview,
            excludingCleaned: [title, notes, nextAction, contextSummary, decisionPrompt, preparedMove]
        )
        self.rowMove = preparedMove ?? nextAction
        self.evidence = Self.cleanedText(todo.evidenceExcerpt)
    }

    var rowContext: String? {
        contextSummary ?? decisionPrompt ?? notesContext
    }

    var rowReason: String? {
        let rowDecisionPrompt = contextSummary == nil ? nil : decisionPrompt

        let reason = [rowDecisionPrompt, whyNow, sourceContext]
            .compactMap { $0 }
            .joined(separator: " ")

        return reason.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    var hasChiefOfStaffContext: Bool {
        contextSummary != nil ||
            decisionPrompt != nil ||
            whyNow != nil ||
            sourceContext != nil ||
            preparedMove != nil ||
            draftPreview != nil ||
            evidence != nil
    }

    private static func uniqueText(_ value: String?, excludingCleaned values: [String?]) -> String? {
        uniqueCleanedText(cleanedText(value), excludingCleaned: values)
    }

    private static func uniqueCleanedText(_ cleaned: String?, excludingCleaned values: [String?]) -> String? {
        guard let cleaned else { return nil }
        let isDuplicate = values.contains { other in
            guard let other else { return false }
            return cleaned.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return isDuplicate ? nil : cleaned
    }

    private static func cleanedText(_ value: String?) -> String? {
        ChiefOfStaffCopy.clean(value)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TodoRowCopy {
    static func dueText(
        for todo: TodoItem,
        dueDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard !todo.isCompleted else {
            return dueDate.formatted(AppFormatters.shortDate)
        }

        if todo.status == .snoozed, let snoozedUntil = todo.snoozedUntil {
            return "Snoozed until \(snoozedUntil.formatted(AppFormatters.shortDate))"
        }

        // Stale keep/close cards should not scream "Past due" urgency — the
        // product ask is keep-or-dismiss, and due dates on those rows are often
        // older than the saved open-work age.
        if isStaleKeepClose(todo) {
            return "Needs keep/close"
        }

        if dueDate < now, !calendar.isDate(dueDate, inSameDayAs: now) {
            return "Past due \(AppFormatters.relativeString(for: dueDate, relativeTo: now))"
        }

        if calendar.isDate(dueDate, inSameDayAs: now) {
            return "Today"
        }

        return dueDate.formatted(AppFormatters.shortDate)
    }

    static func isStaleKeepClose(_ todo: TodoItem) -> Bool {
        guard let prompt = ChiefOfStaffCopy.clean(todo.decisionPrompt)?.lowercased() else {
            return false
        }

        return prompt.contains("keep it active if it still matters")
            || prompt.contains("dismiss it so it stops resurfacing")
            || prompt.contains("should this older")
    }
}
