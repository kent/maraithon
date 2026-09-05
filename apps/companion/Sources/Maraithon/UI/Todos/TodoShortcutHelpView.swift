import SwiftUI

/// Native reference sheet for every Gmail-style Todo shortcut shared with the
/// web app.
struct TodoShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Move") {
                    shortcut("Next Todo", keys: "J  ↓  →")
                    shortcut("Previous Todo", keys: "K  ↑  ←")
                    shortcut("Open active Todo", keys: "O  Return")
                    shortcut("Back to the list", keys: "U  Esc")
                }

                Section("Process") {
                    shortcut("Select active Todo", keys: "X")
                    shortcut("Mark done", keys: "E")
                    shortcut("Dismiss", keys: "#")
                }

                Section("Find") {
                    shortcut("Focus search", keys: "/")
                    shortcut("Show keyboard shortcuts", keys: "?")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Keyboard Shortcuts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
        .frame(
            minWidth: Tokens.Layout.shortcutHelpMinWidth,
            minHeight: Tokens.Layout.shortcutHelpMinHeight
        )
    }

    private func shortcut(_ label: String, keys: String) -> some View {
        LabeledContent(label) {
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
