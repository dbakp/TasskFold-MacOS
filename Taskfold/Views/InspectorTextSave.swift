import Foundation

/// When the Mac inspector's 0.6 s autosave should wait. A team task's title and notes commit when the field is left,
/// on Return, on switching tasks, on closing the inspector and on quit, because every team save is a reviewed edit with
/// its own `team_task_edits` row and `task.updated` webhook. Per-keystroke saves would flood both.
/// Non-text fields (date, priority, assignee, ...) are discrete edits and keep saving at once; personal tasks keep the debounce.
enum InspectorTextSave {
    static let textKeys: Set<String> = ["title", "description"]

    /// True when an edit of `changedKeys` should not start the debounce: a team task, a text field has focus, and
    /// only text changed. The text then waits for the commit points above.
    static func defersAutosave(isTeamTask: Bool, textFieldFocused: Bool, changedKeys: Set<String>) -> Bool {
        isTeamTask && textFieldFocused && !changedKeys.isEmpty && changedKeys.isSubset(of: textKeys)
    }
}
