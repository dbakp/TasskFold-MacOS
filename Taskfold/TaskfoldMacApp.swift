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
    private var tint: Color { Color.adaptiveAccent(accent) }

    init() {
        #if DEBUG
        // Fixture launches are force-quit by the test runner, which leaves window-restoration state that can
        // restore "no windows" on the next launch. Ignore it for fixtures so every test starts with a window.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting") || arguments.contains("--preview") || TeamEditorNativeFixture.enabled || ProcessInfo.processInfo.environment["TASKFOLD_TRACE"] == "1" {
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        }
        #endif
        // One store per process: App Intents and notification actions act on the same data the window shows.
        let store = Store.shared
        NativeCalendarAuthorization.install()
        _store = State(initialValue: store)
        _workspace = State(initialValue: Workspace(store: store))
    }

    @ViewBuilder private var mainContent: some View {
        #if DEBUG
        if ProjectAdoptionNativeFixture.enabled { ProjectAdoptionNativeFixtureView() }
        else if TeamEditorNativeFixture.enabled { TeamEditorNativeFixtureView() }
        else if TeamOrganizationFixture.enabled { NavigationStack { TeamOrganizationView() } }
        else if WebhookManagementFixture.enabled { NavigationStack { WebhookAccessView(fixture: true) } }
        else if AutomationManagementFixture.enabled { NavigationStack { AutomationAccessView(fixture: true) } }
        else if AccountRemovalNativeFixture.enabled { AccountRemovalProofView() }
        else if LocationHandoffNativeFixture.enabled {
            LocationHandoffSendView(request: .init(taskID: LocationHandoffNativeFixture.taskID, workspace: .init(account: store.userID, generation: store.workspaceGeneration)))
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--handoff-autonomous-proof") {
                        await store.runLocationHandoffSenderProof()
                        NSApplication.shared.terminate(nil)
                    }
                }
        } else { RootView() }
        #else
        RootView()
        #endif
    }
    var body: some Scene {
        WindowGroup("Taskfold") {
            mainContent
                .safeAreaInset(edge: .top, spacing: 0) { AccountRemovalRecoveryBanner().environment(store) }
                .task {
                    #if DEBUG
                    if TeamEditorNativeFixture.enabled || TeamOrganizationFixture.enabled || AutomationManagementFixture.enabled || AccountRemovalNativeFixture.enabled { return }
                    #endif
                    await store.resumeAccountRemovals()
                }
                .environment(store)
                .environment(workspace)
                .tint(tint)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .frame(minWidth: 820, minHeight: 520)
                // Widget and notification URLs should reuse an open workspace window.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1380, height: 840)
        .windowToolbarStyle(.unified)
        .commands { TaskfoldCommands(workspace: workspace, store: store) }

        Settings {
            SettingsView().environment(store).environment(workspace).tint(tint)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        }
    }
}

/// Shared synchronously with every open inspector before macOS may terminate.
@MainActor final class TerminationSaveRequest {
    static let notification = Notification.Name("Taskfold.savePendingInspectorEdits")
    var hasUnsavedEdits = false
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let request = TerminationSaveRequest()
        NotificationCenter.default.post(name: TerminationSaveRequest.notification, object: request)
        if !Store.shared.flushEditorSessions() { request.hasUnsavedEdits = true }
        return request.hasUnsavedEdits ? .terminateCancel : .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        ReminderCategory.register(minutes: Store.shared.reminderSnoozeMinutes)
        #if DEBUG
        if ProcessInfo.processInfo.environment["TASKFOLD_TRACE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let text = NSApp.windows.map { "\($0.className) visible=\($0.isVisible) \($0.frame)" }.joined(separator: "\n")
                try? Data("windows: \(NSApp.windows.count)\n\(text)".utf8).write(to: FileManager.default.temporaryDirectory.appending(path: "trace-windows.txt"))
            }
        }
        #endif
    }
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Store.shared.receivedRemoteReminderToken(deviceToken) }
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Store.shared.failedRemoteReminderToken() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.categoryIdentifier == FocusFinish.category || notification.request.identifier.hasPrefix(FocusFinish.prefix) {
            let receipt = FocusFinishReceipt(info: notification.request.content.userInfo)
            let valid = await MainActor.run { receipt.map { Store.shared.validFocusFinish($0) } ?? false }
            return valid ? [.banner, .sound] : []
        }
        guard notification.request.content.categoryIdentifier == ReminderCategory.identifier || notification.request.identifier.hasPrefix(ReminderRequest.prefix) else { return [.banner, .sound] }
        let valid = await MainActor.run { Store.shared.validReminder(notification.request.content.userInfo) != nil }
        return valid ? [.banner, .sound] : []
    }
    /// Reminder actions mirror iOS: complete, snooze for the displayed delay, or move to tomorrow.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == FocusFinish.category || response.notification.request.identifier.hasPrefix(FocusFinish.prefix) {
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier, let receipt = FocusFinishReceipt(info: response.notification.request.content.userInfo) else { return }
            // Retain a bounded receipt until Root has loaded the receiving workspace on a cold launch.
            await MainActor.run { NotificationRoute.shared.focusReceipt = receipt }
            return
        }
        #if DEBUG
        await MacNotificationResponseHoldFixture.shared.hold(account: response.notification.request.content.userInfo["accountID"] as? String ?? "", action: response.actionIdentifier)
        #endif
        if let route = await Store.shared.handleReminder(response.notification.request.content.userInfo, action: response.actionIdentifier) {
            await MainActor.run { NotificationRoute.shared.taskRequest = route }
        }
        #if DEBUG
        await MainActor.run { MacNotificationResponseHoldFixture.shared.finished(account: Store.shared.userID) }
        #endif
    }
}

@MainActor @Observable
final class NotificationRoute {
    static let shared = NotificationRoute()
    var taskRequest: ReminderTaskRoute?
    var focusReceipt: FocusFinishReceipt?
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            CommandMenu("Fixture") {
                Button("Report Native Layout") { DebugDiagnostics.report(workspace) }
                    .keyboardShortcut("d", modifiers: [.command, .option, .control])
            }
        }
        #endif
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
                Button("This Weekend") { if let day = store.datePhraseDay("this weekend") { workspace.reschedule(workspace.actionSelection, to: Dates.day(day), label: "the weekend") } }.disabled(store.datePhrasePreferences == nil)
                Button("Next Week") { if let day = store.datePhraseDay("next week") { workspace.reschedule(workspace.actionSelection, to: Dates.day(day), label: "next week") } }.disabled(store.datePhrasePreferences == nil)
                Divider()
                Button("Remove Date") { workspace.reschedule(workspace.actionSelection, to: nil, label: "") }
            }.disabled(workspace.actionSelection.isEmpty)
            Button("Edit Deadlines…") { workspace.editDeadlines(workspace.actionSelection) }.keyboardShortcut("d", modifiers: [.command, .option, .shift]).disabled(workspace.actionSelection.isEmpty)
            Button("Assign Shared Tasks…") { workspace.assignSharedSelection(workspace.actionSelection) }.disabled(!store.hasSharedTaskSelection(workspace.actionSelection))
            Button("Edit Shared Labels…") { workspace.editSharedLabels(workspace.actionSelection) }.disabled(!store.hasSharedTaskSelection(workspace.actionSelection))
            Button("Edit Estimates…") { workspace.editEstimates(workspace.actionSelection) }.disabled(workspace.actionSelection.isEmpty)
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
            Button("Welcome Tour") { workspace.onboarding = true }.disabled(!store.signedIn)
            Button("Taskfold Help") { NSWorkspace.shared.open(URL(string: "https://github.com/dbakp/TasskFold-MacOS")!) }
        }
    }
    private var completeTitle: String {
        let tasks = workspace.selectedTasks
        if tasks.count > 1 { return tasks.allSatisfy(\.completed) ? "Reopen Tasks" : "Complete Tasks" }
        return tasks.first?.completed == true ? "Reopen Task" : "Complete Task"
    }
}

#if DEBUG
/// Holds one real OS callback only in an explicitly opted-in isolated Mac test app.
@MainActor @Observable final class MacNotificationResponseHoldFixture {
    static let shared = MacNotificationResponseHoldFixture()
    static var enabled: Bool {
        Bundle.main.bundleIdentifier == "com.dbakp.taskfold.mac.p0notificationtests" &&
            ProcessInfo.processInfo.arguments.contains("--notification-callback-hold-testing")
    }
    private(set) var phase = "Idle"
    private(set) var account = ""
    private(set) var action = ""
    private(set) var receiver = ""
    private var armed = false
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Never>?
    var status: String { [phase, account, action, receiver].joined(separator: "|") }
    func arm() {
        guard Self.enabled, continuation == nil else { return }
        account = ""; action = ""; receiver = ""; armed = true; phase = "Armed"
    }
    func hold(account: String, action: String) async {
        guard Self.enabled, armed else { return }
        armed = false; self.account = account; self.action = action
        await withCheckedContinuation { continuation in
            self.continuation = continuation; phase = "Held"
        }
        phase = "Resumed"
    }
    func release() {
        guard Self.enabled, let continuation else { return }
        self.continuation = nil; phase = "Released"; continuation.resume()
    }
    func finished(account: String) {
        guard Self.enabled, phase == "Resumed" else { return }
        receiver = account; phase = "Handled"
    }
}

#endif
