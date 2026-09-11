import SwiftUI
import AppKit

/// Routes Space, Return, and Escape to the selection when no text field is editing. Table-backed lists on macOS
/// do not reliably forward these keys to SwiftUI key handlers, and putting them on menu items would intercept
/// typing everywhere, so a local event monitor is the Mac-native way to give them list semantics.
struct KeyRouter: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handle(event) ? nil : event }
            }
            .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
    @MainActor private func handle(_ event: NSEvent) -> Bool {
        guard !workspace.finderPresented, let window = event.window, window.isKeyWindow,
              window == NSApp.mainWindow, window.attachedSheet == nil, !(window.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 49: // Space
            guard !workspace.actionSelection.isEmpty else { return false }
            workspace.toggle(workspace.actionSelection); return true
        case 36, 76: // Return, Enter
            guard workspace.actionSelection.count == 1, let id = workspace.actionSelection.first else { return false }
            workspace.open(id); return true
        case 53: // Escape
            guard !workspace.actionSelection.isEmpty else { return false }
            workspace.finderTaskID = nil; workspace.selection = []; return true
        default: return false
        }
    }
}
