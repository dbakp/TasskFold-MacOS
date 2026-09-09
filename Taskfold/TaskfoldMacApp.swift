import SwiftUI
import UserNotifications

@main
struct TaskfoldMacApp: App {
    @State private var store: Store
    @State private var workspace: Workspace
    @AppStorage("appearance") private var appearance = "system"
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let store = Store()
        _store = State(initialValue: store)
        _workspace = State(initialValue: Workspace(store: store))
    }

    var body: some Scene {
        WindowGroup("Taskfold") {
            RootView()
                .environment(store)
                .environment(workspace)
                .tint(.taskfold)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1220, height: 780)
        .windowToolbarStyle(.unified)
        .commands { TaskfoldCommands(workspace: workspace, store: store) }

        Settings {
            SettingsView().environment(store).environment(workspace).tint(.taskfold)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let id = response.notification.request.content.userInfo["taskID"] as? String {
            await MainActor.run { NotificationRoute.shared.taskID = id }
        }
    }
}

@MainActor @Observable
final class NotificationRoute {
    static let shared = NotificationRoute()
    var taskID: String?
}

/// Menu bar commands mirror every keyboard shortcut in the window so they are discoverable and scriptable.
struct TaskfoldCommands: Commands {
    let workspace: Workspace
    let store: Store
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { workspace.quickAddFocusRequest += 1 }.keyboardShortcut("n", modifiers: .command)
            Button("New Project…") { workspace.newProjectRequest += 1 }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Search Tasks") { workspace.searchPresented = true }.keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Task") {
            // Space and Return are handled by the focused list itself so typing in text fields is never intercepted.
            Button(completeTitle) { workspace.toggle(workspace.selection) }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(workspace.selection.isEmpty)
            Button("Edit Task") { if let id = workspace.selection.first, workspace.selection.count == 1 { workspace.open(id) } }.keyboardShortcut("e", modifiers: .command).disabled(workspace.selection.count != 1)
            Divider()
            Menu("Reschedule") {
                Button("Today") { workspace.reschedule(workspace.selection, to: Dates.day(Date()), label: "today") }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Tomorrow") { workspace.reschedule(workspace.selection, to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }.keyboardShortcut("t", modifiers: [.command, .option, .shift])
                Button("This Weekend") { workspace.reschedule(workspace.selection, to: Dates.day(Workspace.next(weekday: 7)), label: "the weekend") }
                Button("Next Week") { workspace.reschedule(workspace.selection, to: Dates.day(Workspace.next(weekday: 2)), label: "next week") }
                Divider()
                Button("Remove Date") { workspace.reschedule(workspace.selection, to: nil, label: "") }
            }.disabled(workspace.selection.isEmpty)
            Menu("Move to Project") {
                Button("Inbox") { workspace.move(workspace.selection, toProject: "") }
                ForEach(store.projects) { project in Button(project.name) { workspace.move(workspace.selection, toProject: project.id) } }
            }.disabled(workspace.selection.isEmpty)
            Menu("Priority") {
                ForEach(1...4, id: \.self) { n in
                    Button(n == 4 ? "None" : "Priority \(n)") { workspace.setPriority(workspace.selection, n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
                }
            }.disabled(workspace.selection.isEmpty)
            Button("Duplicate") { workspace.duplicate(workspace.selection) }.keyboardShortcut("d", modifiers: .command).disabled(workspace.selection.isEmpty)
            Divider()
            Button("Delete") { workspace.delete(workspace.selection) }.keyboardShortcut(.delete, modifiers: .command).disabled(workspace.selection.isEmpty)
        }
        CommandGroup(before: .sidebar) {
            Button("Today") { workspace.section = .today }.keyboardShortcut("1", modifiers: .command)
            Button("Inbox") { workspace.section = .inbox }.keyboardShortcut("2", modifiers: .command)
            Button("Upcoming") { workspace.section = .upcoming }.keyboardShortcut("3", modifiers: .command)
            Button("Calendar") { workspace.section = .calendar }.keyboardShortcut("4", modifiers: .command)
            Button("All Tasks") { workspace.section = .all }.keyboardShortcut("5", modifiers: .command)
            Divider()
            Button(workspace.inspectorShown ? "Hide Inspector" : "Show Inspector") { workspace.inspectorShown.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Sync Now") { Task { await store.sync() } }.keyboardShortcut("r", modifiers: .command).disabled(store.localMode || !store.signedIn)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Taskfold Help") { NSWorkspace.shared.open(URL(string: "https://github.com/dbakp/taskfold-ios")!) }
        }
    }
    private var completeTitle: String {
        let tasks = workspace.selectedTasks
        if tasks.count > 1 { return tasks.allSatisfy(\.completed) ? "Reopen Tasks" : "Complete Tasks" }
        return tasks.first?.completed == true ? "Reopen Task" : "Complete Task"
    }
}
