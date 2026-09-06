import SwiftUI
import AppKit

/// Inspector for the active Todo. It exposes the same source-backed facts and
/// resolution actions without inventing a second editing surface.
struct TodoDetailView: View {
    let todo: CompanionTodo?
    let isWorking: Bool
    let isLoadingDetails: Bool
    let detailError: String?
    let primaryAction: () -> Void
    let dismissAction: () -> Void
    let retryDetails: () -> Void

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
                    if todo.canMarkDone {
                        LabeledContent("Attention", value: TodosCopy.attentionLabel(todo.attentionMode))
                    }
                    LabeledContent("Priority", value: TodosCopy.priorityLabel(todo.priority))
                    LabeledContent("Due", value: TodosCopy.dueLabel(todo.dueDate, active: todo.canMarkDone))
                }

                if let notes = todo.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Notes") {
                        Text(notes).textSelection(.enabled)
                    }
                }

                sourceContext(for: todo)

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

    @ViewBuilder
    private func sourceContext(for todo: CompanionTodo) -> some View {
        if let card = todo.actionCard {
            Section("Source context") {
                if let whyNow = card.whyNow, !whyNow.isEmpty {
                    Text(whyNow)
                }
                if let excerpt = card.evidenceExcerpt, !excerpt.isEmpty, excerpt != todo.summary {
                    Text(excerpt).textSelection(.enabled)
                }
                if let source = card.sourceContext, !source.isEmpty {
                    Text(source).foregroundStyle(.secondary)
                }
                if let action = card.sourceAction, let destination = action.destination {
                    Link(destination: destination) {
                        Label(action.openLabel ?? "Open source", systemImage: "arrow.up.right")
                    }
                }
            }
            if let draft = card.sourceAction?.draftText ?? card.draftPreview, !draft.isEmpty {
                Section("Suggested reply") {
                    Text(draft).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                    } label: {
                        Label("Copy reply", systemImage: "doc.on.doc")
                    }
                }
            }
        } else if isLoadingDetails {
            Section {
                ProgressView("Loading source context").controlSize(.small)
            }
        } else if let detailError {
            Section("Source context") {
                Label(detailError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StatusTone.attention.color)
                Button("Retry", action: retryDetails)
            }
        }
    }

    private func primaryActionTitle(_ todo: CompanionTodo) -> String {
        todo.canReopen ? "Reopen" : "Done"
    }

    private func primaryActionIcon(_ todo: CompanionTodo) -> String {
        todo.canReopen ? "arrow.uturn.backward" : "checkmark"
    }
}
