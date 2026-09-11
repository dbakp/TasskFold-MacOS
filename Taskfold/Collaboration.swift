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
        if project.isEmpty { return [Record(["user_id": .string(store.userID), "display_name": .string("Me")])] }
        var members = projectMembers[project] ?? []
        // Everyone viewing the project can assign themselves even while the directory loads.
        if !members.contains(where: { $0.string("user_id").lowercased() == store.userID.lowercased() }) {
            members.insert(Record(["user_id": .string(store.userID), "display_name": .string("Me")]), at: 0)
        }
        return members
    }
    func assigneeName(_ task: Record, contextID: String? = nil) -> String {
        let id = task.string("assigned_to")
        if id.isEmpty { return "Unassigned" }
        if id.lowercased() == store.userID.lowercased() { return "Me" }
        return assignmentMembers(task, contextID: contextID).first { $0.string("user_id").lowercased() == id.lowercased() }?.string("display_name") ?? "Member unavailable"
    }
    func assign(_ id: String, to user: String) {
        updateTasks([id], fields: ["assigned_to": user.isEmpty ? .null : .string(user)], name: user.isEmpty ? "Remove Assignment" : "Assign Task")
    }
    func loadProjectMembers() async {
        guard store.signedIn, !store.localMode else { return }
        let account = store.userID
        var members: [String: [Record]] = [:]
        do {
            for project in store.projects {
                let data = try await store.backend.request("/rest/v1/rpc/taskfold_project_members", method: "POST", body: ["_project_id": .string(project.id)])
                guard !Task.isCancelled, store.userID == account else { return }
                members[project.id] = try JSONDecoder().decode([Record].self, from: data)
            }
            projectMembers = members; memberLoadError = nil
        } catch { if store.userID == account { memberLoadError = "Couldn’t load project members. Connect and sync to try again." } }
    }
}

struct AssigneeMenu: View {
    @Environment(Workspace.self) private var workspace
    let task: Record
    var contextID: String? = nil
    var selected = false
    var showsName = false
    var select: (String) -> Void
    private var name: String { workspace.assigneeName(task, contextID: contextID) }
    var body: some View {
        Menu {
            Button("Unassigned") { select("") }
            Divider()
            ForEach(Array(workspace.assignmentMembers(task, contextID: contextID).enumerated()), id: \.offset) { _, member in
                let id = member.string("user_id")
                Button {
                    select(id)
                } label: {
                    if id == task.string("assigned_to") { Label(member.string("display_name"), systemImage: "checkmark") }
                    else { Text(member.string("display_name")) }
                }
            }
            if let error = workspace.memberLoadError {
                Divider()
                Text(error)
                Button("Reload Members") { Task { await workspace.loadProjectMembers() } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: task.string("assigned_to").isEmpty ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                if showsName { Text(name).lineLimit(1) }
            }.foregroundStyle(selected ? Color.white : .secondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Assigned to \(name)")
        .accessibilityLabel("Assigned to \(name)")
        .accessibilityIdentifier(showsName ? "taskAssignee" : "assignee-" + task.id)
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
