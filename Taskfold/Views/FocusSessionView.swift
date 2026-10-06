import SwiftUI

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
    @State private var taskID = ""
    @State private var minutes = 25
    @State private var message: String?
    @State private var replacing = false
    @State private var replacementBase: Record?
    private var activeWorkspace: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) && store.focusAvailable }
    private var choices: [Record] { store.tasks.filter { !$0.completed }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
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
                    if let message { Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusError") }
                }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .navigationTitle("Focus session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closeFocusSession") } }
            .onAppear {
                if let session = store.focusSession, choices.contains(where: { $0.id.lowercased() == session.taskID }) {
                    taskID = session.taskID; minutes = session.durationSeconds / 60
                }
            }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
            .confirmationDialog("Replace the current session?", isPresented: $replacing, titleVisibility: .visible) {
                Button("Start new session") { start(expected: replacementBase) }
            } message: { Text("The current timer will be replaced. Your task stays unchanged.") }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 580, minHeight: 540)
        #endif
    }
    private var newSession: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your next session").font(.headline)
            if choices.isEmpty { Text("Add an open task to start focusing.").foregroundStyle(.secondary) }
            else {
                Picker("Task", selection: $taskID) {
                    Text("Choose a task").tag("")
                    ForEach(choices) { task in Text(task.title).tag(task.id.lowercased()) }
                }.accessibilityIdentifier("focusTaskPicker")
                #if os(iOS)
                HStack {
                    Text("\(minutes) minutes").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusDuration")
                    Spacer()
                    Button { minutes -= 1 } label: { Image(systemName: "minus").frame(minWidth: 44, minHeight: 44) }.disabled(minutes == 1).accessibilityLabel("Shorter Focus session")
                    Button { minutes += 1 } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }.disabled(minutes == 180).accessibilityLabel("Longer Focus session")
                }
                #else
                Stepper(value: $minutes, in: 1...180) { Text("\(minutes) minutes").fixedSize(horizontal: false, vertical: true) }.accessibilityIdentifier("focusDuration")
                #endif
                Button {
                    let row = store.focusRecord
                    if let session = store.focusSession, session.status != .stopped && !session.finished(at: Date()) {
                        replacementBase = row; replacing = true
                    } else { start(expected: row) }
                } label: { Label("Start Focus", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).disabled(taskID.isEmpty || !choices.contains { $0.id.lowercased() == taskID })
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
            Text(clock(session.remaining(at: now))).font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold)).accessibilityIdentifier("focusRemaining")
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
            Text("\(clock(session.remaining(at: Date()))) remaining · \(session.finished(at: Date()) ? "Finished" : session.status.rawValue.capitalized)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
    private func clock(_ seconds: TimeInterval) -> String {
        let remaining = Int(ceil(seconds)); return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
    private func start(expected: Record?) { change(expected: expected) { try FocusSession(taskID: taskID, minutes: minutes) } }
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
