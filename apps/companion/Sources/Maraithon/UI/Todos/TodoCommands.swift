import SwiftUI

/// Native menu commands for the web Todo surface's unmodified Gmail-style
/// shortcuts. Arrow, Return, and Escape aliases are handled by the focused
/// list so standard text editing keeps precedence.
struct TodoCommands: Commands {
    @FocusedValue(\.todoShortcutActions) private var actions

    var body: some Commands {
        CommandMenu("Todos") {
            Button("Next Todo") { perform(.next) }
                .keyboardShortcut("j", modifiers: [])
                .disabled(actions == nil)
            Button("Previous Todo") { perform(.previous) }
                .keyboardShortcut("k", modifiers: [])
                .disabled(actions == nil)

            Divider()

            Button("Open Active Todo") { perform(.open) }
                .keyboardShortcut("o", modifiers: [])
                .disabled(actions == nil)
            Button("Back to Todo List") { perform(.back) }
                .keyboardShortcut("u", modifiers: [])
                .disabled(actions == nil)
            Button("Select Active Todo") { perform(.select) }
                .keyboardShortcut("x", modifiers: [])
                .disabled(actions == nil)

            Divider()

            Button("Mark Active Todo Done") { perform(.complete) }
                .keyboardShortcut("e", modifiers: [])
                .disabled(actions == nil)
            Button("Dismiss Active Todo") { perform(.dismiss) }
                .keyboardShortcut("3", modifiers: .shift)
                .disabled(actions == nil)

            Divider()

            Button("Search Todos") { perform(.search) }
                .keyboardShortcut("/", modifiers: [])
                .disabled(actions == nil)
            Button("Todo Keyboard Shortcuts") { perform(.help) }
                .keyboardShortcut("/", modifiers: .shift)
                .disabled(actions == nil)
        }
    }

    private func perform(_ shortcut: TodoShortcut) {
        actions?.perform(shortcut)
    }
}
