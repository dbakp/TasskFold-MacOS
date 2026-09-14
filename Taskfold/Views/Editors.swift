import SwiftUI

/// Project and label editor presented as a compact sheet.
struct NamedEditor: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let table: String
    @State var record: Record
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    private let palette = [("Rose", "#e31e4b"), ("Red", "#ef4444"), ("Orange", "#f97316"), ("Green", "#22c55e"), ("Blue", "#3b82f6"), ("Purple", "#8b5cf6"), ("Teal", "#14b8a6"), ("Gray", "#6b7280")]
    private var isNew: Bool { store.record(table, id: record.id) == nil }
    private var noun: String { table == "projects" ? "Project" : "Label" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New \(noun)" : "Edit \(noun)").font(.headline)
            Form {
                TextField("Name", text: Binding(get: { record.name }, set: { record["name"] = .string($0) })).focused($nameFocused).accessibilityIdentifier("recordName")
                    .onSubmit { if canSave { save() } }
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        ForEach(palette, id: \.1) { name, hex in
                            Button { record["color"] = .string(hex) } label: {
                                Circle().fill(Color.project(hex)).frame(width: 20, height: 20)
                                    .overlay { if record.string("color") == hex { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                            }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(record.string("color") == hex ? .isSelected : [])
                        }
                    }
                }
                if table == "projects" { TextField("Description", text: Binding(get: { record.string("description") }, set: { record["description"] = .string($0) }), axis: .vertical).lineLimit(2...4) }
            }.formStyle(.columns)
            HStack {
                if !isNew && (table != "projects" || record.string("user_id") == store.userID) {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canSave).accessibilityIdentifier("saveRecord")
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { nameFocused = true }
        .confirmationDialog("Delete this \(noun.lowercased())?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                workspace.run("Delete \(noun)") { store.remove(table, record.id) }
                if workspace.section == (table == "projects" ? .project(record.id) : .label(record.id)) { workspace.section = .today }
                dismiss()
            }
        } message: { if table == "projects" { Text("Its tasks move to Inbox.") } }
    }
    private var canSave: Bool { !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func save() {
        record["name"] = .string(record.name.trimmingCharacters(in: .whitespacesAndNewlines))
        if workspace.save(table, record, name: isNew ? "Add \(noun)" : "Edit \(noun)") {
            if isNew { workspace.section = table == "projects" ? .project(record.id) : .label(record.id) }
            dismiss()
        }
    }
}

/// Manage a project's sections in a sheet: rename inline, reorder by drag, add, delete.
struct SectionsEditor: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let projectID: String
    @State private var name = ""
    private var sections: [Record] { store.rows("sections").filter { $0.string("project_id") == projectID }.sorted { $0["order_index"].integer < $1["order_index"].integer } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sections").font(.headline)
            List {
                ForEach(sections) { section in
                    HStack {
                        TextField("Section name", text: Binding(get: { store.record("sections", id: section.id)?.name ?? section.name }, set: { var changed = section; changed["name"] = .string($0); workspace.save("sections", changed, name: "Rename Section") })).textFieldStyle(.plain)
                        Button { workspace.run("Delete Section") { store.remove("sections", section.id) } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).accessibilityLabel("Delete \(section.name)")
                    }
                }
                .onMove { source, destination in var list = sections; list.move(fromOffsets: source, toOffset: destination); workspace.run("Reorder Sections") { for (i, var row) in list.enumerated() { row["order_index"] = .number(Double(i)); store.save("sections", row) } } }
                if sections.isEmpty { Text("No sections yet.").foregroundStyle(.secondary) }
            }.frame(minHeight: 160)
            HStack {
                TextField("New section", text: $name).onSubmit(add)
                Button("Add", action: add).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 380)
    }
    private func add() {
        let row = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "project_id": .string(projectID), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "order_index": .number(Double(sections.count))])
        if workspace.save("sections", row, name: "Add Section") { name = "" }
    }
}

struct CollaboratorsView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Record
    @State private var collaborators: [Record] = []
    @State private var email = ""
    @State private var busy = false
    @State private var message: String?
    private var roster: [Record] {
        var rows = collaborators
        var identities = (workspace.projectMembers[project.id] ?? []).map {
            $0.string("user_id") == store.userID ? store.accountIdentity : $0
        }
        if !identities.contains(where: { $0.string("user_id") == store.userID }),
           owner || collaborators.contains(where: { $0.string("user_id") == store.userID && $0.string("status") == "accepted" }) {
            identities.append(store.accountIdentity)
        }
        for index in rows.indices where rows[index].string("status") == "accepted" {
            if let identity = identities.first(where: { $0.string("user_id") == rows[index].string("user_id") }) {
                for key in ["display_name", "avatar_url"] where !identity.string(key).isEmpty { rows[index][key] = identity[key] }
            }
        }
        if !rows.contains(where: { $0.string("user_id") == project.string("user_id") }), let identity = identities.first(where: { $0.string("user_id") == project.string("user_id") }) {
            var owner = identity; owner["id"] = .string("owner:" + project.id); owner["role"] = .string("owner"); owner["status"] = .string("accepted"); rows.insert(owner, at: 0)
        }
        return rows
    }
    private var owner: Bool { project.string("user_id") == store.userID }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Collaborators · \(project.name)").font(.headline)
            if owner {
                HStack {
                    TextField("Email address", text: $email).textContentType(.emailAddress).onSubmit { Task { await invite() } }
                    Button("Send Invitation") { Task { await invite() } }.disabled(busy || !email.contains("@"))
                }
            }
            List(roster) { person in
                HStack {
                    PersonAvatar(person: person, size: 30)
                    VStack(alignment: .leading) {
                        Text(person.string("display_name").isEmpty ? person.string("invited_email") : person.string("display_name"))
                        Text(person.string("status").capitalized + " · " + person.string("role")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if owner && person.string("role") != "owner" { Button("Remove", role: .destructive) { Task { await remove(person) } }.disabled(busy) }
                }
            }.frame(minHeight: 160)
            if collaborators.isEmpty && !busy { Text("No collaborators yet").foregroundStyle(.secondary) }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if !owner {
                    Button("Leave Project", role: .destructive) {
                        Task {
                            do { _ = try await store.backend.request("/rest/v1/project_collaborators?project_id=eq.\(project.id)&user_id=eq.\(store.userID)", method: "DELETE"); await store.sync(); dismiss() }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 460).task { await load() }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let data = try await store.backend.request("/rest/v1/rpc/get_project_collaborators_safe", method: "POST", body: ["_project_id": .string(project.id)])
            collaborators = try JSONDecoder().decode([Record].self, from: data)
            await store.sync()
            await workspace.refreshMemberDirectory(force: [project.id])
        } catch { message = error.localizedDescription }
    }
    private func invite() async {
        busy = true; message = nil
        let invitee = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await store.backend.request("/rest/v1/project_collaborators", method: "POST", body: ["project_id": .string(project.id), "invited_email": .string(invitee), "invited_by": .string(store.userID)])
            email = ""; message = "Invitation created."
            do {
                _ = try await store.backend.request("/functions/v1/send-invitation-email", method: "POST", body: ["inviteeEmail": .string(invitee), "projectName": .string(project.name), "projectColor": project["color"], "inviterName": .string(store.profile.string("display_name").isEmpty ? store.email : store.profile.string("display_name")), "inviterEmail": .string(store.email), "appUrl": .string("taskfold://invitations")])
                message = "Invitation sent."
            } catch { message = "Invitation created, but its email could not be delivered. The invite is available in Taskfold." }
        } catch { message = error.localizedDescription }
        await load()
    }
    private func remove(_ person: Record) async {
        busy = true
        do { _ = try await store.backend.request("/rest/v1/project_collaborators?id=eq.\(person.id)", method: "DELETE") } catch { message = error.localizedDescription }
        await load()
    }
}

struct InvitationsView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Store.self) private var store
    @State private var busy = false
    private var invitations: [Record] { store.rows("project_collaborators").filter { $0.string("status") == "pending" && ($0.string("user_id") == store.userID || $0.string("invited_email").lowercased() == store.email.lowercased()) } }
    var body: some View {
        Group {
            if invitations.isEmpty {
                ContentUnavailableView("You're up to date", systemImage: "envelope.open", description: Text("Project invitations appear here."))
            } else {
                List(invitations) { invitation in
                    HStack {
                        Text(store.record("projects", id: invitation.string("project_id"))?.name ?? "Project invitation").font(.headline)
                        Spacer()
                        Button("Accept") { respond(invitation, status: "accepted") }.buttonStyle(.borderedProminent)
                        Button("Decline", role: .destructive) { respond(invitation, status: "declined") }.buttonStyle(.bordered)
                    }.disabled(busy).padding(.vertical, 4)
                }
            }
        }.task { await store.sync() }
    }
    private func respond(_ invitation: Record, status: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                var body: [String: JSON] = ["status": .string(status)]
                if status == "accepted" { body["accepted_at"] = .string(Dates.timestamp()) }
                _ = try await store.backend.request("/rest/v1/project_collaborators?id=eq.\(invitation.id)", method: "PATCH", body: body)
                await store.sync()
                await workspace.refreshMemberDirectory(force: [invitation.string("project_id")])
            } catch { store.error = error.localizedDescription }
        }
    }
}

struct TodoistImportView: View {
    @Environment(Store.self) private var store
    @State private var token = ""
    @State private var preview: Record?
    @State private var result: Record?
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text("Bring your projects, sections, labels, tasks, subtasks, and comments into Taskfold.")
                SecureField("Todoist API token", text: $token).onChange(of: token) { _, _ in preview = nil; result = nil }
                Button("Preview Import") { run(previewOnly: true) }.disabled(busy || token.isEmpty)
            }
            if let preview {
                Section("Ready to import") {
                    ForEach(preview["counts"].object.keys.sorted(), id: \.self) { key in LabeledContent(key.capitalized, value: "\(preview["counts"].object[key]?.integer ?? 0)") }
                    Button("Import into Taskfold") { run(previewOnly: false) }.disabled(busy)
                }
            }
            if let result {
                Section("Import complete") { ForEach(result.fields.keys.sorted(), id: \.self) { key in if case .number(let value) = result[key] { LabeledContent(key, value: "\(Int(value))") } } }
            }
            if busy { HStack { ProgressView().controlSize(.small); Text("This may take a moment…") } }
            if let message { Text(message).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
    private func run(previewOnly: Bool) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                let data = try await store.backend.request("/functions/v1/import-todoist", method: "POST", body: ["userToken": .string(token), "preview": .bool(previewOnly)])
                let row = try JSONDecoder().decode(Record.self, from: data)
                if previewOnly { preview = row } else { result = row; preview = nil; await store.sync() }
            } catch { message = error.localizedDescription }
        }
    }
}
