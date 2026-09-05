import SwiftUI

/// Focused action bridge that makes unmodified Gmail-style commands active
/// only while the Todo surface owns the scene.
struct TodoShortcutActions {
    let perform: (TodoShortcut) -> Void

    struct Key: FocusedValueKey {
        typealias Value = TodoShortcutActions
    }
}

extension FocusedValues {
    var todoShortcutActions: TodoShortcutActions? {
        get { self[TodoShortcutActions.Key.self] }
        set { self[TodoShortcutActions.Key.self] = newValue }
    }
}
