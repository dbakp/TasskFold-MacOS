import SwiftUI
import UserNotifications

@main
struct TaskfoldMacApp: App {
    @State private var store: Store
    @State private var workspace: Workspace
    @AppStorage("appearance") private var appearance = "system"
    /// Read here so a new accent re-renders the scene; `Color.taskfold` resolves it everywhere else.
    @AppStorage("accent") private var accent = "rose"
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var tint: Color { Color.accents.first { $0.key == accent }?.color ?? Color.accents[0].color }

    init() {
        #if DEBUG
        // Fixture launches are force-quit by the test runner, which leaves window-restoration state that can
        // restore "no windows" on the next launch. Ignore it for fixtures so every test starts with a window.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting") || arguments.contains("--preview") || ProcessInfo.processInfo.environment["TASKFOLD_TRACE"] == "1" {
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        }
        #endif
        // One store per process: App Intents and notification actions act on the same data the window shows.
        let store = Store.shared
        _store = State(initialValue: store)
        _workspace = State(initialValue: Workspace(store: store))
    }

    var body: some Scene {
        WindowGroup("Taskfold") {
            RootView()
                .environment(store)
                .environment(workspace)
                .tint(tint)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1380, height: 840)
        .windowToolbarStyle(.unified)
        .commands { TaskfoldCommands(workspace: workspace, store: store) }

        Settings {
            SettingsView().environment(store).environment(workspace).tint(tint)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        ReminderCategory.register()
        #if DEBUG
        if ProcessInfo.processInfo.environment["TASKFOLD_TRACE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let text = NSApp.windows.map { "\($0.className) visible=\($0.isVisible) \($0.frame)" }.joined(separator: "\n")
                try? Data("windows: \(NSApp.windows.count)\n\(text)".utf8).write(to: FileManager.default.temporaryDirectory.appending(path: "trace-windows.txt"))
            }
        }
        #endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    /// Reminder actions mirror iOS: complete, snooze an hour, or move to tomorrow, straight from the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["taskID"] as? String else { return }
        switch response.actionIdentifier {
        case ReminderCategory.complete:
            await MainActor.run { if let task = Store.shared.record("tasks", id: id), !task.completed { Store.shared.toggle(task) } }
        case ReminderCategory.snoozeHour:
            await ReminderCategory.snooze(response.notification.request.content, taskID: id, by: 3600)
        case ReminderCategory.tomorrow:
            await MainActor.run {
                if let task = Store.shared.record("tasks", id: id), let due = task.due, let next = Calendar.current.date(byAdding: .day, value: 1, to: max(due, Calendar.current.startOfDay(for: Date()))) {
                    Store.shared.update([id], fields: ["due_date": .string(Dates.day(next))])
                }
            }
        default:
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
    @Environment(\.openSettings) private var openSettings
    let workspace: Workspace
    let store: Store
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { workspace.quickAddFocusRequest += 1 }.keyboardShortcut("n", modifiers: .command)
            Button("New Project…") { workspace.newProjectRequest += 1 }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Search Everywhere…") { workspace.finderPresented = true }.keyboardShortcut("f", modifiers: .command)
            Button("Find Commands…") { workspace.finderPresented = true }.keyboardShortcut("k", modifiers: .command)
            Button("Filter Current List") { workspace.searchPresented = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace.section == .calendar)
        }
        CommandMenu("Account") {
            Button("Manage Account…") { workspace.settingsTab = .account; openSettings() }
            if store.localMode || !store.signedIn {
                Button("Sign In…") { workspace.settingsTab = .account; workspace.signInRequested = true; openSettings() }
            }
            Button("Import from Todoist…") { workspace.settingsTab = .imports; openSettings() }
            Button("Invitations…") { workspace.settingsTab = .invitations; openSettings() }
        }
        CommandMenu("Task") {
            // Space and Return are handled by the focused list itself so typing in text fields is never intercepted.
            Button(completeTitle) { workspace.toggle(workspace.actionSelection) }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(workspace.actionSelection.isEmpty)
            Button("Edit Task") { if let id = workspace.actionSelection.first, workspace.actionSelection.count == 1 { workspace.open(id) } }.keyboardShortcut("e", modifiers: .command).disabled(workspace.actionSelection.count != 1)
            Divider()
            Menu("Reschedule") {
                Button("Today") { workspace.reschedule(workspace.actionSelection, to: Dates.day(Date()), label: "today") }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Tomorrow") { workspace.reschedule(workspace.actionSelection, to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }.keyboardShortcut("t", modifiers: [.command, .option, .shift])
                Button("This Weekend") { workspace.reschedule(workspace.actionSelection, to: Dates.day(Workspace.next(weekday: 7)), label: "the weekend") }
                Button("Next Week") { workspace.reschedule(workspace.actionSelection, to: Dates.day(Workspace.next(weekday: 2)), label: "next week") }
                Divider()
                Button("Remove Date") { workspace.reschedule(workspace.actionSelection, to: nil, label: "") }
            }.disabled(workspace.actionSelection.isEmpty)
            Menu("Move to Project") {
                Button("Inbox") { workspace.move(workspace.actionSelection, toProject: "") }
                ForEach(store.projects) { project in Button(project.name) { workspace.move(workspace.actionSelection, toProject: project.id) } }
            }.disabled(workspace.actionSelection.isEmpty)
            Menu("Priority") {
                ForEach(1...4, id: \.self) { n in
                    Button(n == 4 ? "None" : "Priority \(n)") { workspace.setPriority(workspace.actionSelection, n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
                }
            }.disabled(workspace.actionSelection.isEmpty)
            Button("Duplicate") { workspace.duplicate(workspace.actionSelection) }.keyboardShortcut("d", modifiers: .command).disabled(workspace.actionSelection.isEmpty)
            Divider()
            Button("Delete") { workspace.delete(workspace.actionSelection) }.keyboardShortcut(.delete, modifiers: .command).disabled(workspace.actionSelection.isEmpty)
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
            Button("Plan Your Day…") { workspace.planning = .day }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(!store.signedIn)
            Button("Review This Week…") { workspace.planning = .week }.keyboardShortcut("w", modifiers: [.command, .option]).disabled(!store.signedIn)
            Divider()
            Button("Sync Now") { Task { await store.sync() } }.keyboardShortcut("r", modifiers: .command).disabled(store.localMode || !store.signedIn)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Taskfold Help") { NSWorkspace.shared.open(URL(string: "https://github.com/dbakp/TaskFold-iOS")!) }
        }
    }
    private var completeTitle: String {
        let tasks = workspace.selectedTasks
        if tasks.count > 1 { return tasks.allSatisfy(\.completed) ? "Reopen Tasks" : "Complete Tasks" }
        return tasks.first?.completed == true ? "Reopen Task" : "Complete Task"
    }
}
