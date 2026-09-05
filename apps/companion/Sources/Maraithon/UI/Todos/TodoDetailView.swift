import SwiftUI

/// Inspector for the active Todo. It exposes the same source-backed facts and
/// resolution actions without inventing a second editing surface.
struct TodoDetailView: View {
    let todo: CompanionTodo?
    let isWorking: Bool
    let primaryAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        if let todo {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                        Text(todo.title)
                            .font(.title2.weight(.semibold))
                        if let move = todo.recommendedMove {
                            Text(move)
                                .font(.body)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let summary = todo.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                    }
                }

                Section("Details") {
                    LabeledContent("Status", value: TodosCopy.statusLabel(todo.status))
                    LabeledContent("Source", value: TodosCopy.sourceLabel(todo.source))
                    LabeledContent("Attention", value: TodosCopy.attentionLabel(todo.attentionMode))
                    LabeledContent("Priority", value: TodosCopy.priorityLabel(todo.priority))
                    LabeledContent("Due", value: TodosCopy.dueLabel(todo.dueDate))
                }

                Section("Actions") {
                    HStack(spacing: Tokens.Spacing.small) {
                        Button {
                            primaryAction()
                        } label: {
                            Label(primaryActionTitle(todo), systemImage: primaryActionIcon(todo))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || (!todo.canMarkDone && !todo.canReopen))

                        if todo.canDismiss {
                            Button {
                                dismissAction()
                            } label: {
                                Label("Dismiss", systemImage: "archivebox")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Todo selected",
                systemImage: "checklist",
                description: Text("Choose a Todo to inspect its next move and source context.")
            )
        }
    }

    private func primaryActionTitle(_ todo: CompanionTodo) -> String {
        todo.canReopen ? "Reopen" : "Done"
    }

    private func primaryActionIcon(_ todo: CompanionTodo) -> String {
        todo.canReopen ? "arrow.uturn.backward" : "checkmark"
    }
}
