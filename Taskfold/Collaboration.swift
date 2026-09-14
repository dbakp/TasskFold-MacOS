import SwiftUI

extension Workspace {
    static func clearingAssignments(_ task: Record) -> Record {
        var result = task; result["assigned_to"] = .null
        if !task["subtasks"].list.isEmpty {
            result["subtasks"] = .array(task["subtasks"].list.map { .object(clearingAssignments(Record($0.object)).fields) })
        }
        return result
    }

    func rootTask(_ id: String) -> Record? {
        store.record("tasks", id: Self.subtaskPath(id)?.first ?? id)
    }
    func parentTitle(_ id: String) -> String? {
        guard Self.subtaskPath(id) != nil else { return nil }
        return rootTask(id)?.title
    }
    var assignedTasks: [Record] {
        var result: [Record] = []
        func visit(_ task: Record, depth: Int) {
            if task.string("assigned_to").lowercased() == store.userID.lowercased() { result.append(task) }
            guard depth < 2 else { return }
            for (index, value) in task["subtasks"].list.enumerated() {
                let id = childID(parent: task.id, value: value, index: index)
                if let child = taskRecord(id) { visit(child, depth: depth + 1) }
            }
        }
        for task in store.tasks { visit(task, depth: 0) }
        return result
    }
    func assignmentProject(_ task: Record, contextID: String? = nil) -> String {
        let id = contextID ?? task.id
        return Self.subtaskPath(id) == nil ? task.string("project_id") : rootTask(id)?.string("project_id") ?? ""
    }
    func assignmentMembers(_ task: Record, contextID: String? = nil) -> [Record] {
        let project = assignmentProject(task, contextID: contextID)
        if project.isEmpty { return [store.accountIdentity] }
        let accepted = Set(store.rows("project_collaborators").filter { $0.string("project_id") == project && $0.string("status") == "accepted" }.map { $0.string("user_id").lowercased() } + [store.record("projects", id: project)?.string("user_id").lowercased() ?? ""])
        var members = (projectMembers[project] ?? []).filter { store.localMode || accepted.contains($0.string("user_id").lowercased()) }
        // Everyone viewing the project can assign themselves even while the directory loads.
        if !members.contains(where: { $0.string("user_id").lowercased() == store.userID.lowercased() }) {
            members.insert(store.accountIdentity, at: 0)
        }
        return members.map { $0.string("user_id").lowercased() == store.userID.lowercased() ? store.accountIdentity : $0 }
    }
    func assigneeName(_ task: Record, contextID: String? = nil) -> String {
        let id = task.string("assigned_to")
        if id.isEmpty { return "Unassigned" }
        if id.lowercased() == store.userID.lowercased() { return store.accountName }
        return assignmentMembers(task, contextID: contextID).first { $0.string("user_id").lowercased() == id.lowercased() }?.string("display_name") ?? "Project member"
    }
    func assign(_ id: String, to user: String) {
        updateTasks([id], fields: ["assigned_to": user.isEmpty ? .null : .string(user)], name: user.isEmpty ? "Remove Assignment" : "Assign Task")
    }
    func loadProjectMembers() async { await refreshMemberDirectory() }

}

struct AssigneeMenu: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(Workspace.self) private var workspace
    let task: Record
    var contextID: String? = nil
    var selected = false
    var showsName = false
    var select: (String) -> Void
    private var name: String { workspace.assigneeName(task, contextID: contextID) }
    private var identity: Record {
        if task.string("assigned_to").lowercased() == workspace.store.userID.lowercased() { return workspace.store.accountIdentity }
        return workspace.assignmentMembers(task, contextID: contextID).first { $0.string("user_id") == task.string("assigned_to") } ?? Record(["display_name": .string(name)])
    }
    @State private var choosing = false
    @State private var photoLoaded = false
    var body: some View {
        Button { choosing.toggle() } label: {
            HStack(spacing: 5) {
                if task.string("assigned_to").isEmpty { Image(systemName: "person.crop.circle.badge.plus") }
                else { PersonAvatar(person: identity, size: showsName ? 22 : 20, didLoad: { photoLoaded = $0 }).accessibilityHidden(true) }
                if showsName { Text(name).lineLimit(1) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.foregroundStyle(selected ? Color(nsColor: controlActiveState == .inactive ? .labelColor : .alternateSelectedControlTextColor) : .secondary)
        }
        .buttonStyle(.borderless).fixedSize()
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
        .accessibilityValue(task.string("assigned_to").isEmpty ? "" : photoLoaded ? "Photo loaded" : "Photo placeholder")
        .help("Assigned to \(name)").accessibilityLabel("Assigned to \(name)")
        .accessibilityIdentifier(showsName ? "taskAssignee" : "assignee-" + task.id)
        .popover(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Assign task").font(.headline)
                Button("Unassigned") { select(""); choosing = false }
                Divider()
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(workspace.assignmentMembers(task, contextID: contextID).enumerated()), id: \.offset) { _, member in
                            let id = member.string("user_id")
                            Button { select(id); choosing = false } label: {
                                HStack(spacing: 10) {
                                    PersonAvatar(person: member, size: 30).accessibilityHidden(true)
                                    Text(member.string("display_name").isEmpty ? "Project member" : member.string("display_name")).foregroundStyle(.primary)
                                    Spacer()
                                    if id == task.string("assigned_to") { Image(systemName: "checkmark") }
                                }.padding(6).contentShape(.rect)
                            }.buttonStyle(.plain).accessibilityIdentifier("assign-member-" + id)
                        }
                    }
                }.frame(maxHeight: 240)
                if let error = workspace.memberLoadError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button("Refresh Members") { Task { await workspace.refreshMemberDirectory(force: [workspace.assignmentProject(task, contextID: contextID)]) } }
                    .disabled(workspace.store.localMode)
            }.padding(16).frame(width: 270)
        }
    }

}

struct ConflictReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conflict: SyncConflict
    private var keys: [String] { conflict.mutation.fields.keys.sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review conflicting edit").font(.title2.weight(.semibold))
            Text(conflict.remote.title).font(.headline)
            Text("Your edit is saved on this Mac. Choose which version to use for this edit; changes to other fields and items will be kept.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(key.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                            LabeledContent("On this Mac") { Text(summary(conflict.mutation.fields[key] ?? .null)).textSelection(.enabled) }
                            LabeledContent("Shared version") { Text(summary(conflict.remote[key])).textSelection(.enabled) }
                        }
                    }
                }
            }.frame(maxHeight: 300)
            HStack {
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Shared Edit") { store.resolveConflict(keepLocal: false); dismiss() }.accessibilityIdentifier("useSharedEdit")
                Button("Keep My Edit") { store.resolveConflict(keepLocal: true); dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("keepMyEdit")
            }
        }.padding(24).frame(width: 560)
    }
    private func summary(_ value: JSON) -> String {
        switch value {
        case .null: return "None"
        case .string(let text): return text.isEmpty ? "Empty" : text
        case .bool(let flag): return flag ? "Yes" : "No"
        case .number(let number): return String(format: "%g", number)
        case .array(let items): return items.isEmpty ? "No items" : items.map(summary).joined(separator: "\n")
        case .object(let fields):
            return fields.keys.sorted().filter { !["id", "authorId", "data"].contains($0) }.map { "\($0): \(summary(fields[$0]!))" }.joined(separator: " · ")
        }
    }
}
