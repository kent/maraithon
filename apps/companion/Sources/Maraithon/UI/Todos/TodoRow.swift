import SwiftUI

/// Compact, keyboard-selectable Todo row with visible marked state and one
/// quiet primary action.
struct TodoRow: View {
    let todo: CompanionTodo
    let isMarked: Bool
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
            Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isMarked ? Color.accentColor : Color.secondary)
                .accessibilityLabel(isMarked ? "Selected" : "Not selected")

            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                HStack(spacing: Tokens.Spacing.small) {
                    Text(todo.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if todo.status == "snoozed" {
                        Label("Snoozed", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(StatusTone.attention.color)
                    }
                    if todo.priority >= 75 {
                        Text(todo.priority >= 90 ? "Critical" : "High")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(todo.priority >= 90 ? StatusTone.error.color : StatusTone.attention.color)
                    }
                }

                if let move = todo.recommendedMove {
                    Text("Next: \(move)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let summary = todo.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text(TodosCopy.sourceLabel(todo.source))
                    .font(.callout)
                Text(TodosCopy.attentionLabel(todo.attentionMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .leading)

            Text(TodosCopy.dueLabel(todo.dueDate))
                .font(.caption)
                .foregroundStyle(TodosCopy.dueTone(todo.dueDate).color)
                .frame(width: 96, alignment: .leading)

            Button(actionTitle) {
                action()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isWorking || (!todo.canMarkDone && !todo.canReopen))
            .frame(width: 72, alignment: .trailing)
            .overlay {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .opacity(isWorking ? 0.65 : 1)
        }
        .padding(.vertical, Tokens.Spacing.xsmall)
        .accessibilityElement(children: .contain)
    }

    private var actionTitle: String {
        todo.canReopen ? "Reopen" : "Done"
    }
}
