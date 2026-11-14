import SwiftUI

/// The blocker rows and "Add blocker" button for one saved task, shared by the iOS editor and the Mac inspector.
/// The picker reuses the shared task search; links save immediately (like comments) rather than with the
/// editor's draft, because they are separate synced rows.
struct TaskDependencyRows: View {
    @Environment(Store.self) private var store
    let taskID: String
    @State private var picking = false

    var body: some View {
        let lines = store.blockerLines(for: taskID)
        Group {
            ForEach(lines) { line in
                HStack(spacing: 8) {
                    Image(systemName: line.completed ? "checkmark.circle" : line.readable ? "lock" : "eye.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(line.title).strikethrough(line.completed).italic(!line.readable).lineLimit(2)
                        .foregroundStyle(line.completed || !line.readable ? .secondary : .primary)
                    Spacer(minLength: 0)
                    Button { _ = store.removeDependency(id: line.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Remove blocker \(line.title)").accessibilityIdentifier("removeBlocker-" + line.id)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(line.completed ? "Completed" : "")
            }
            Button("Add blocker", systemImage: "plus.circle") { picking = true }
                .disabled(lines.count >= TaskDependencies.maximumBlockers)
                .accessibilityIdentifier("addBlocker")
        }
        .sheet(isPresented: $picking) { TaskDependencyPicker(taskID: taskID) }
    }
}

/// List section for the iOS editor. Team workspace tasks and unsaved tasks do not show it.
struct TaskDependenciesSection: View {
    @Environment(Store.self) private var store
    let taskID: String

    var body: some View {
        if store.supportsDependencies(taskID: taskID) {
            let count = store.blockerLines(for: taskID).count
            Section {
                TaskDependencyRows(taskID: taskID)
            } header: {
                Text("Blocked by")
            } footer: {
                Text((count == 0 ? "" : "\(count) of \(TaskDependencies.maximumBlockers). ") + "Hidden from Today and Upcoming until every blocker is completed or deleted.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Searches open tasks with the shared search; loops, existing blockers and the cap are filtered out.
struct TaskDependencyPicker: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: String
    @State private var text = ""

    var body: some View {
        let found = store.dependencyCandidates(for: taskID, search: text)
        NavigationStack {
            List {
                Section {
                    TextField("Search tasks", text: $text).autocorrectionDisabled().accessibilityIdentifier("blockerSearch")
                }
                Section {
                    ForEach(found, id: \.id) { task in
                        Button {
                            if store.addDependency(task: taskID, blockedBy: task.id) { dismiss() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).lineLimit(2)
                                if let project = store.record("projects", id: task.string("project_id")) {
                                    Text(project.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if found.isEmpty { Text(text.isEmpty ? "No tasks available" : "No matching tasks").foregroundStyle(.secondary) }
                } footer: { Text("Only open tasks that would not create a loop are listed.") }
            }
            .navigationTitle("Blocked by")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

#if os(macOS)
/// A short free-text "Waiting on" note (for example "Anna's reply"), saved when the field is submitted or loses focus.
struct TaskWaitingOnField: View {
    @Environment(Store.self) private var store
    let task: Record
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Label("Waiting on", systemImage: "hourglass").foregroundStyle(.secondary)
            TextField("Person or thing", text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
                .onChange(of: text) { _, now in
                    // The database caps the note; stop typing at the same limit.
                    if now.unicodeScalars.count > TaskDependencies.maximumWaitingOnLength { text = String(String.UnicodeScalarView(now.unicodeScalars.prefix(TaskDependencies.maximumWaitingOnLength))) }
                }
                .accessibilityLabel("Waiting on").accessibilityIdentifier("waitingOn")
        }
        .onAppear { text = task.string("waiting_on") }
        .onChange(of: task.id) { _, _ in text = task.string("waiting_on") }
        .onChange(of: task.string("waiting_on")) { _, remote in if !focused { text = remote } }
    }
    private func commit() {
        guard store.record("tasks", id: task.id) != nil else { return }
        _ = store.setWaitingOn(taskID: task.id, note: text)
        text = store.record("tasks", id: task.id)?.string("waiting_on") ?? ""
    }
}
#endif
