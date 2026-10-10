import SwiftUI
#if DEBUG
import UserNotifications
#endif

struct FocusSessionRequest: Identifiable {
    var id = UUID()
    var workspace: WorkspaceBinding
}
private struct FocusSessionActionKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var openFocusSession: () -> Void {
        get { self[FocusSessionActionKey.self] }
        set { self[FocusSessionActionKey.self] = newValue }
    }
}

struct FocusSessionView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: FocusSessionRequest
    @State private var selectedTask: FocusTaskCatalog.Choice?
    @State private var choosingTask = false
    @State private var minutes = 25
    @State private var message: String?
    @State private var replacing = false
    @State private var replacementBase: Record?
    private var activeWorkspace: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) && store.focusAvailable }
    private var choices: [FocusTaskCatalog.Choice] { guard activeWorkspace else { return [] }; return FocusTaskCatalog(tasks: store.tasks, projects: store.projects, sections: store.rows("sections")).choices }
    private var currentChoice: FocusTaskCatalog.Choice? { choices.first { $0.id == selectedTask?.id && $0.generation == selectedTask?.generation } }
    private func taskContext(_ task: Record) -> String { FocusTaskCatalog.context(task, tasks: store.tasks, projects: store.projects, sections: store.rows("sections")) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !activeWorkspace {
                        ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Close Focus and reopen it in your current workspace."))
                    } else if let conflict = store.focusSyncConflict {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in conflictReview(conflict) }
                    } else if let row = store.focusRecord, !FocusSessionChange.validRow(row, account: store.userID) {
                        ContentUnavailableView("Refresh Focus", systemImage: "arrow.clockwise", description: Text("This session could not be read. Refresh your workspace before changing it."))
                    } else {
                        if let row = store.focusRecord, let session = FocusSessionChange.session(in: row, account: store.userID) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in sessionCard(session, row: row, now: context.date) }
                        } else {
                            Label("One task. A little uninterrupted time.", systemImage: "timer").font(.title2.weight(.semibold))
                            Text("Choose a task and give it your attention. The timer continues when you close Taskfold.").foregroundStyle(.secondary)
                        }
                        newSession
                    }
                    if activeWorkspace { finishAlerts }
                    #if DEBUG
                    if store.userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--focus-finish-testing") { finishFixture }
                    if store.userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--focus-catalog-seed") { selectionFixture }
                    #endif
                    if let message { Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusError") }
                }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Focus session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closeFocusSession") } }
            .task { await store.reschedule() }
            .onAppear {
                if let session = store.focusSession, let task = choices.first(where: { $0.id == session.taskID }) {
                    selectedTask = task; minutes = session.durationSeconds / 60
                }
            }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
            .sheet(isPresented: $choosingTask) {
                FocusTaskChooser(workspace: request.workspace, selectedID: currentChoice?.id) { task in
                    guard activeWorkspace, FocusTaskCatalog.selectable(task, tasks: store.tasks) else { return }
                    selectedTask = task; choosingTask = false; message = nil
                }
            }
            .confirmationDialog("Replace the current session?", isPresented: $replacing, titleVisibility: .visible) {
                Button("Start new session") { start(expected: replacementBase) }
            } message: { Text("The current timer will be replaced. Your task stays unchanged.") }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 580, minHeight: 540)
        #endif
    }
    #if DEBUG
    private var selectionFixture: some View {
        VStack {
            Text("Selected task: " + (currentChoice?.id ?? "none")).accessibilityIdentifier("focusSelectedTaskFixture")
            Button("Recreate selected task fixture") {
                guard activeWorkspace, let choice = currentChoice, var task = store.tasks.first(where: { $0.id.lowercased() == choice.id }) else { return }
                task["task_generation"] = .string(UUID().uuidString.lowercased())
                _ = store.commit([
                    Mutation(table: "tasks", recordID: task.id, method: "DELETE", fields: [:]),
                    Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields, insertOnly: true)
                ], remember: false)
            }.accessibilityIdentifier("focusRecreateSelectedFixture")
        }
    }
    @State private var fixturePending = -1
    private var finishFixture: some View {
        VStack {
            Text("Pending Focus alerts: \(fixturePending)").accessibilityIdentifier("focusPendingAlerts")
            Button("Refresh scheduled alerts") { Task {
                fixturePending = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { $0.identifier.hasPrefix(FocusFinish.prefix) }.count
            } }.accessibilityIdentifier("focusRefreshAlerts")
            Button("Finish soon fixture") {
                guard activeWorkspace, let task = choices.first, let session = try? FocusSession(taskID: task.id, minutes: 1, now: Date().addingTimeInterval(-45)) else { return }
                _ = store.changeFocus(session, expected: store.focusRecord, workspace: request.workspace)
            }.accessibilityIdentifier("focusFinishSoon")
        }
    }
    #endif
    private var finishAlerts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Alert when Focus finishes", isOn: Binding(get: { store.focusAlertsEnabled }, set: { enabled in
                guard activeWorkspace else { return }
                if enabled { Task { await store.enableFocusAlerts() } } else { store.disableFocusAlerts() }
            })).disabled(store.requestingFocusAlerts || store.requestingNotifications).frame(minHeight: 44).accessibilityIdentifier("focusAlerts")
            Text(store.focusAlertStatus).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusAlertStatus")
            Text("Enable on each device where you want a finish alert. The alert opens your session; task completion is up to you.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ReminderSystemSettingsButton()
        }
    }
    private var newSession: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your next session").font(.headline)
            if choices.isEmpty { Text("Add an open task to start focusing.").foregroundStyle(.secondary) }
            else {
                Button { choosingTask = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(currentChoice?.title ?? "Choose a task").font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            if let choice = currentChoice { Text(choice.context).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
                    }.frame(minHeight: 44).contentShape(.rect)
                }.buttonStyle(.bordered).accessibilityIdentifier("focusTaskPicker")
                if selectedTask != nil && currentChoice == nil {
                    Text("The selected task changed or is no longer open. Choose it again.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusSelectionStatus")
                }
                #if os(iOS)
                HStack {
                    Text("\(minutes) \(minutes == 1 ? "minute" : "minutes")").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusDuration")
                    Spacer()
                    Button { minutes -= 1 } label: { Image(systemName: "minus").frame(minWidth: 44, minHeight: 44) }.disabled(minutes == 1).accessibilityLabel("Shorter Focus session")
                    Button { minutes += 1 } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }.disabled(minutes == 180).accessibilityLabel("Longer Focus session")
                }
                #else
                Stepper(value: $minutes, in: 1...180) { Text("\(minutes) \(minutes == 1 ? "minute" : "minutes")").fixedSize(horizontal: false, vertical: true) }.accessibilityIdentifier("focusDuration")
                #endif
                Button {
                    let row = store.focusRecord
                    if let session = store.focusSession, session.status != .stopped && !session.finished(at: Date()) {
                        replacementBase = row; replacing = true
                    } else { start(expected: row) }
                } label: { Label("Start Focus", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).disabled(currentChoice == nil)
                    .accessibilityIdentifier("startFocus")
            }
            Text(store.localMode ? "Saved on this device." : store.pendingCount > 0 ? "Changes are saved here and waiting to sync. Open Taskfold on both devices to receive the latest session." : "Your session syncs with your workspace.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func sessionCard(_ session: FocusSession, row: Record?, now: Date) -> some View {
        let task = store.tasks.first { $0.id.lowercased() == session.taskID }
        return VStack(alignment: .leading, spacing: 16) {
            Label(session.status == .stopped ? "Session ended" : session.finished(at: now) ? "Time well spent" : session.status == .paused ? "Paused" : "Time to focus", systemImage: "timer")
                .font(.headline).foregroundStyle(.secondary).accessibilityIdentifier("focusStatus")
            Text(task?.title ?? "Task unavailable").font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusTaskTitle")
            if let task { Text(taskContext(task)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusTaskContext") }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.status == .stopped ? "Time spent" : "Time remaining")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("focusClockMeaning")
                // Ended widgets show whole seconds spent; retain that meaning in the full session.
                Text(clock(session.status == .stopped ? TimeInterval(session.elapsed(at: now) / 1000) : session.remaining(at: now)))
                    .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold)).accessibilityIdentifier("focusRemaining")
            }
            ProgressView(value: Double(session.elapsed(at: now)), total: Double(session.durationSeconds * 1000)).tint(.accentColor)
            if task == nil || task?.completed == true {
                Text(task == nil ? "The task was removed or is no longer available. You can end the session and choose another task." : "This task is completed. You can end the session and choose another task.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if session.finished(at: now) {
                Text("Your timer is finished. Complete the task when its work is done, or start another session.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if session.status != .stopped {
                if !session.finished(at: now) && task?.completed == false {
                    Button {
                        change(expected: row) { session.status == .paused ? try session.resumed(at: Date()) : try session.paused(at: Date()) }
                    } label: { Label(session.status == .paused ? "Resume" : "Pause", systemImage: session.status == .paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("pauseResumeFocus")
                }
                Button { change(expected: row) { try session.stopped(at: Date()) } } label: { Text("End session").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered).accessibilityIdentifier("endFocus")
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
    }
    private func conflictReview(_ conflict: FocusSyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Focus changed on another device", systemImage: "exclamationmark.icloud").font(.title2.weight(.semibold))
            Text("Choose the session to continue with. Your later task edits will stay saved.").foregroundStyle(.secondary)
            if let session = store.focusSession { comparison(session, heading: "This device") } else { Text("This device: no session") }
            if let session = FocusSessionChange.session(in: conflict.remote, account: store.userID) { comparison(session, heading: "Synced session") } else { Text("Synced session: no session") }
            Button { resolve(conflict, keepLocal: false) } label: { Text("Use synced session").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent).accessibilityIdentifier("useSyncedFocus")
            Button { resolve(conflict, keepLocal: true) } label: { Text("Keep this device's session").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).accessibilityIdentifier("keepLocalFocus")
            Button { dismiss() } label: { Text("Decide later").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityIdentifier("deferFocusReview")
        }
    }
    private func comparison(_ session: FocusSession, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline)
            Text(store.tasks.first { $0.id.lowercased() == session.taskID }?.title ?? "Task unavailable").fixedSize(horizontal: false, vertical: true)
            if let task = store.tasks.first(where: { $0.id.lowercased() == session.taskID }) { Text(taskContext(task)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("\(clock(session.remaining(at: Date()))) remaining · \(session.finished(at: Date()) ? "Finished" : session.status.rawValue.capitalized)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
    private func clock(_ seconds: TimeInterval) -> String {
        let remaining = Int(ceil(seconds)); return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
    private func start(expected: Record?) {
        guard activeWorkspace, let choice = currentChoice, FocusTaskCatalog.selectable(choice, tasks: store.tasks) else {
            message = "Choose an open task from your current workspace."; return
        }
        change(expected: expected) { try FocusSession(taskID: choice.id, minutes: minutes) }
    }
    private func change(expected: Record?, _ make: () throws -> FocusSession) {
        do {
            let session = try make()
            if store.changeFocus(session, expected: expected, workspace: request.workspace) { message = nil }
            else { message = store.error; store.error = nil }
        } catch { message = error.localizedDescription }
    }
    private func resolve(_ conflict: FocusSyncConflict, keepLocal: Bool) {
        guard activeWorkspace else { return }
        if store.resolveFocusConflict(id: conflict.id, keepLocal: keepLocal) { message = nil }
        else { message = store.error; store.error = nil }
    }
}

private struct FocusTaskChooser: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @FocusState private var searching: Bool
    let workspace: WorkspaceBinding
    let selectedID: String?
    let choose: (FocusTaskCatalog.Choice) -> Void
    private var choices: [FocusTaskCatalog.Choice] {
        guard workspace.matches(account: store.userID, generation: store.workspaceGeneration), store.focusAvailable else { return [] }
        return FocusTaskCatalog(tasks: store.tasks, projects: store.projects, sections: store.rows("sections"), search: search).choices
    }
    var body: some View {
        let choices = self.choices
        return NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search tasks", text: $search, axis: .vertical).lineLimit(1...3).autocorrectionDisabled()
                        .focused($searching).submitLabel(.search).onSubmit { searching = false }
                        .onChange(of: search) { _, query in
                            if query.contains(where: { $0.isNewline }) {
                                search = query.filter { !$0.isNewline }; searching = false
                            }
                        }
                        .accessibilityLabel("Search tasks, projects, sections or notes")
                        .accessibilityIdentifier("focusTaskSearch")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.plain).accessibilityLabel("Clear task search").accessibilityIdentifier("clearFocusTaskSearch")
                    }
                }.padding(.horizontal, 12).frame(minHeight: 44).background(.quaternary, in: RoundedRectangle(cornerRadius: 14)).padding()
                List {
                    ForEach(choices) { choice in
                        FocusTaskChoiceRow(choice: choice, selected: choice.id == selectedID) { choose(choice) }
                    }
                }.listStyle(.plain).accessibilityIdentifier("focusTaskChoices")
                    .overlay { if choices.isEmpty { ContentUnavailableView("No matching tasks", systemImage: "magnifyingglass", description: Text("Try another task, project or section name.")) } }
            }.navigationTitle("Choose a task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelFocusTaskChoice") } }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 500, minHeight: 520)
        #endif
    }
}

private struct FocusTaskChoiceRow: View {
    @Environment(\.dynamicTypeSize) private var textSize
    let choice: FocusTaskCatalog.Choice
    let selected: Bool
    let choose: () -> Void
    private var excerpt: String { String(choice.description.prefix(240)) }
    private var spokenLabel: String {
        choice.title + ", " + choice.context + (excerpt.isEmpty ? "" : ", " + excerpt)
    }
    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(choice.title).font(.body.weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text(choice.context).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !excerpt.isEmpty {
                        Text(excerpt).font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(textSize.isAccessibilitySize ? nil : 2).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.taskfold).accessibilityHidden(true) }
            }.frame(minHeight: 44).contentShape(.rect)
        }.buttonStyle(.plain)
            .accessibilityLabel(spokenLabel)
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityIdentifier("focusTaskChoice-" + choice.id)
    }
}
