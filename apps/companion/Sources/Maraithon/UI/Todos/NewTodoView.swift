/// A native manual-entry sheet preserves the draft and retry identity on failure.
import SwiftUI

struct NewTodoView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TodosStore
    let onCreated: (CompanionTodo) -> Void

    @State private var requestID = UUID()
    @State private var title = ""
    @State private var notes = ""
    @State private var nextAction = ""
    @State private var priority = 50
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAction: String { nextAction.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        (4...240).contains(trimmedTitle.count) && notes.count <= 8_000
            && (trimmedAction.isEmpty || (4...1_000).contains(trimmedAction.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            Text("New Todo").font(.title2.weight(.semibold))
            Form {
                TextField("Title", text: $title)
                    .focused($titleFocused)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                TextField("Next action", text: $nextAction, axis: .vertical)
                    .lineLimit(2...4)
                Picker("Priority", selection: $priority) {
                    Text("Low").tag(25)
                    Text("Normal").tag(50)
                    Text("High").tag(90)
                }
                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .disabled(isSaving)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if !title.isEmpty && !(4...240).contains(trimmedTitle.count) {
                Text("Use 4–240 characters for the title.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !trimmedAction.isEmpty && !(4...1_000).contains(trimmedAction.count) {
                Text("Use 4–1,000 characters for the next action, or leave it blank.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if notes.count > 8_000 {
                Text("Keep notes under 8,000 characters.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: Tokens.Spacing.small) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(isSaving ? "Saving…" : "Add Todo") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !canSave)
            }
        }
        .padding(Tokens.Spacing.large)
        .frame(width: Tokens.Layout.todoEditorWidth)
        .interactiveDismissDisabled(isSaving)
        .task { titleFocused = true }
    }

    private func save() async {
        guard !isSaving, canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = CompanionTodoDraft(
            requestID: requestID,
            title: trimmedTitle,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            nextAction: trimmedAction.isEmpty ? nil : trimmedAction,
            priority: priority,
            dueAt: hasDueDate ? ISO8601DateFormatter().string(from: dueDate) : nil
        )
        do {
            let todo = try await store.create(draft)
            onCreated(todo)
            dismiss()
        } catch {
            errorMessage = CompanionErrorCopy.message(for: error)
        }
    }
}
