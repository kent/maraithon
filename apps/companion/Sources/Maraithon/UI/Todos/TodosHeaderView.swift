import SwiftUI

/// Compact Todo header with refresh state and a discoverable shortcut guide.
struct TodosHeaderView: View {
    let store: TodosStore
    let showShortcuts: () -> Void
    let createTodo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text("Todos")
                    .font(.title2.weight(.semibold))
                Text(TodosCopy.resultCount(store.todos.count, filter: store.filter))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: createTodo) {
                Label("New Todo", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing Todos")
            }
            Button {
                showShortcuts()
            } label: {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                Task { await store.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.medium)
    }
}
