import SwiftUI

/// Kept out of release navigation until organization rollout is ready.
enum TeamOrganizationAvailability {
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "TaskfoldTeamsEnabled") as? Bool == true }
}

struct TeamOrganizationView: View {
    var teamID: String?
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var browser: TeamOrganizationBrowser?
    @State private var loadedScope: String?
    @State private var commands: TeamOrganizationCommandModel?
    @State private var editing: TeamOrganizationEditRequest?
    @State private var clearing: TeamOrganizationCommand?


    private var scope: String? {
        #if DEBUG
        if TeamOrganizationFixture.enabled { return "synthetic-team-overview" }
        #endif
        guard phase == .active, store.teamOrganizationReadable, let origin = try? store.backend.accountRemovalOrigin else { return nil }
        return "\(store.userID)|\(origin)|\(store.workspaceGeneration)|\(store.workspaceReadRevision)|\(store.backend.reminderSessionIncarnation)"
    }
    var body: some View {
        Group {
            if let scope, scope == loadedScope, let browser {
                if browser.loading { ProgressView("Refreshing teams…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let message = browser.message { List { commandStatus; Section { unavailable(message, retry: true) } } }
                else if let detail = browser.detail { detailView(detail) }
                else if let overview = browser.overview { overviewView(overview) }
                else { unavailable("Refresh to view your teams.", retry: true) }
            } else { unavailable("Open your synced account to view its teams.", retry: false) }
        }
        .navigationTitle(teamID == nil ? "Teams" : (scope != nil && scope == loadedScope ? browser?.detail?.team.name : nil) ?? "Team")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth: 540, idealWidth: 660, minHeight: 500)
        #endif
        .toolbar {
            if teamID == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            if scope != nil, scope == loadedScope, commands?.current == true, commands?.pending == nil, commands?.busy == false, browser?.loading == false {
                if teamID == nil, let overview = browser?.overview, overview.enabled {
                    ToolbarItem { Button("New team", systemImage: "plus") { begin(.create) }.accessibilityIdentifier("teamCreate") }
                } else if let detail = browser?.detail, browser?.setupEnabled == true {
                    ToolbarItem { Menu("Manage team", systemImage: "ellipsis.circle") {
                        if detail.team.role.directoryVisible && !detail.team.archived {
                            Button("Rename team", systemImage: "pencil") { begin(.rename) }
                            Button("New folder", systemImage: "folder.badge.plus") { begin(.folderCreate) }
                        }
                        if detail.team.role == .owner {
                            Button(detail.team.archived ? "Reopen team" : "Archive team", systemImage: "archivebox") { begin(detail.team.archived ? .unarchive : .archive) }
                        }
                    }.accessibilityIdentifier("teamManage") }
                }
            }
            ToolbarItem { Button { Task { await browser?.refresh(team: teamID) } } label: { Label("Refresh teams", systemImage: "arrow.clockwise") }.disabled(scope == nil || browser?.loading == true || commands?.busy == true) }
        }
        .task(id: scope) { await start() }
        .onDisappear { browser?.invalidate(); commands?.close() }
        .sheet(item: $editing) { request in
            if let commands { TeamOrganizationEditSheet(request: request, model: commands, current: { scope == request.scope && scope == loadedScope }) }
        }
        .confirmationDialog("Clear saved request?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            if let reviewed = clearing { Button("Clear saved request", role: .destructive) { Task { await commands?.clearReviewedRequest(reviewed) } } }
        } message: { Text("Review the latest team details first. Clearing this device’s saved request does not cancel or undo a change that may already have been made.") }
        .onChange(of: commands?.receipt) { _, receipt in
            guard receipt != nil else { return }
            Task {
                #if DEBUG
                if !TeamOrganizationFixture.enabled { await store.sync() }
                #else
                await store.sync()
                #endif
                await browser?.refresh(team: teamID)
            }
        }
    }
    private func unavailable(_ text: String, retry: Bool) -> some View {
        ContentUnavailableView {
            Label("Your teams", systemImage: "person.3")
        } description: { Text(text) } actions: {
            if retry { Button("Try again") { Task { await browser?.refresh(team: teamID) } } }
        }
    }
    private func overviewView(_ overview: TeamOrganizationOverview) -> some View {
        List {
            commandStatus
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "person.3.sequence.fill").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                    Text("A place for shared work").font(.title2.bold())
                    Text("See the teams you belong to and how each one is organized.").foregroundStyle(.secondary)
                }.padding(.vertical, 12).listRowBackground(Color.accentColor.opacity(0.07))
            }
            if !overview.enabled {
                Section { Label("Team setup is paused. Existing team details are still available.", systemImage: "pause.circle").font(.callout).foregroundStyle(.secondary) }
            }
            if overview.teams.isEmpty {
                Section { ContentUnavailableView("No teams yet", systemImage: "person.3", description: Text("Your teams will appear here when you join one.")) }
            } else {
                let active = overview.teams.filter { !$0.archived }
                let archived = overview.teams.filter(\.archived)
                if !active.isEmpty { Section("Your teams") { ForEach(active) { teamRow($0) } } }
                if !archived.isEmpty { Section("Archived") { ForEach(archived) { teamRow($0) } } }
            }
            let offers = overview.invitations.filter { $0.expires > Date() }
            if !offers.isEmpty {
                Section {
                    ForEach(offers) { offer in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(offer.name, systemImage: "envelope").font(.headline)
                            Text("Invited as \(offer.role.title.lowercased()) · Expires \(offer.expires.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                } header: { Text("Invitations") } footer: { Text("This preview shows your pending invitations. Responses aren’t available here yet.") }
            }
        }
        .refreshable { await browser?.refresh() }
        .accessibilityIdentifier("teamOverview")
    }
    private func teamRow(_ team: TeamOrganization) -> some View {
        NavigationLink { TeamOrganizationView(teamID: team.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: team.archived ? "archivebox" : "person.2.fill").foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) { Text(team.name).font(.headline); Text(team.role.title).font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 5)
        }.accessibilityIdentifier("team-\(team.id)")
    }
    private func detailView(_ detail: TeamOrganizationDetail) -> some View {
        List {
            commandStatus
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(detail.team.name, systemImage: "person.3.fill").font(.title2.bold())
                    Text("Your role: \(detail.team.role.title)").foregroundStyle(.secondary)
                    if detail.team.archived { Label("Archived", systemImage: "archivebox").font(.callout).foregroundStyle(.secondary) }
                }.padding(.vertical, 10).listRowBackground(Color.accentColor.opacity(0.07))
            }
            if detail.team.role != .guest {
                Section {
                    if detail.folders.isEmpty { Text("No folders yet").foregroundStyle(.secondary) }
                    ForEach(detail.folders) { folder in
                        HStack {
                            Label(folder.name, systemImage: "folder").padding(.vertical, 3)
                            Spacer()
                            if detail.team.role.directoryVisible, !detail.team.archived, browser?.setupEnabled == true, commands?.pending == nil {
                                Menu { Button("Rename folder") { begin(.folderRename, folder: folder) }; Button("Remove folder", role: .destructive) { begin(.folderRemove, folder: folder) } } label: { Image(systemName: "ellipsis") }
                                    .accessibilityLabel("Manage \(folder.name)").accessibilityIdentifier("folderManage-\(folder.id)").disabled(commands?.busy == true)
                            }
                        }
                    }
                } header: { Text("Folders") } footer: { Text("Folders organize the team. Project access is managed separately.") }
            }
            if detail.team.role.directoryVisible {
                Section("Members") {
                    ForEach(detail.members) { member in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(member.id == detail.account ? "You" : "Member \(member.id.suffix(8))").font(.headline)
                                if member.id != detail.account { Text("Name not shared").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            Text(member.role.title).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
                let pending = detail.invitations.filter { $0.expires > Date() }
                if !pending.isEmpty {
                    Section("Pending invitations") {
                        ForEach(pending) { invitation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(invitation.email).textSelection(.enabled)
                                Text("\(invitation.role.title) · Expires \(invitation.expires.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Section { Label("The member directory is visible to team owners and admins.", systemImage: "person.crop.circle.badge.checkmark").font(.callout).foregroundStyle(.secondary) }
            }
            if let transfer = detail.transfer, transfer.expires > Date() {
                Section("Ownership") {
                    Label(transfer.target == detail.account ? "You’ve been offered ownership" : "Ownership transfer pending", systemImage: "person.badge.key")
                    Text("Expires \(transfer.expires.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { await browser?.refresh(team: teamID) }
        .accessibilityIdentifier("teamDetails")
    }
    @ViewBuilder private var commandStatus: some View {
        if let commands, commands.current {
            if let pending = commands.pending {
                Section("Saved team request") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(pending.action.title, systemImage: "clock.arrow.circlepath").font(.headline)
                        if let name = pending.name { Text(name) }
                        Text("The change may already have reached your team. Retry sends this same request; it won’t create a replacement.").font(.callout).foregroundStyle(.secondary)
                        if !pending.canRetry { Text("This request has expired. Check the latest team before clearing it.").foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                    Button("Retry saved request") { Task { await commands.retry() } }.disabled(commands.busy || !pending.canRetry).accessibilityIdentifier("teamRetry")
                    NavigationLink("Check latest team") { TeamOrganizationView(teamID: pending.team) }
                    Button("Clear saved request", role: .destructive) { clearing = pending }.disabled(commands.busy)
                }
            }
            if let message = commands.message { Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityIdentifier("teamCommandMessage") } }
            if let success = commands.success { Section { Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityIdentifier("teamCommandSuccess") } }
            if commands.busy { Section { ProgressView("Saving team change…") } }
        }
    }
    private func begin(_ action: TeamOrganizationCommand.Action, folder: TeamOrganizationDetail.Folder? = nil) {
        guard let scope, scope == loadedScope, let commands, commands.current, !commands.busy, commands.pending == nil else { return }
        if action == .create {
            guard browser?.overview?.enabled == true else { return }
            editing = TeamOrganizationEditRequest(scope: scope, account: commands.account, origin: commands.origin, action: action, team: UUID().uuidString.lowercased(), revision: nil, folder: nil, name: "")
        } else if let detail = browser?.detail, browser?.setupEnabled == true {
            guard detail.team.role.directoryVisible,
                  ![TeamOrganizationCommand.Action.archive, .unarchive].contains(action) || detail.team.role == .owner,
                  action == .unarchive ? detail.team.archived : !detail.team.archived,
                  !action.needsFolder || detail.folders.contains(where: { $0.id == folder?.id }) else { return }
            editing = TeamOrganizationEditRequest(scope: scope, account: detail.account, origin: detail.origin, action: action, team: detail.team.id, revision: detail.team.revision, folder: folder?.id, name: folder?.name ?? ([TeamOrganizationCommand.Action.rename, .archive, .unarchive].contains(action) ? detail.team.name : ""))
        }
    }
    @MainActor private func start() async {
        browser?.invalidate(); commands?.close(); browser = nil; commands = nil; loadedScope = nil
        guard let captured = scope else { return }
        #if DEBUG
        if TeamOrganizationFixture.enabled {
            browser = TeamOrganizationFixture.browser(); commands = TeamOrganizationFixture.commands(); loadedScope = captured
            await commands?.load(); await browser?.refresh(team: teamID); return
        }
        #endif
        let account = store.userID
        guard let origin = try? store.backend.accountRemovalOrigin else { return }
        let backend = store.backend
        browser = TeamOrganizationBrowser(account: account, origin: origin, current: { scope == captured },
            overview: { try await backend.teamOrganizationOverview(account: account, origin: origin) },
            detail: { try await backend.teamOrganizationDetail(team: $0, account: account, origin: origin) })
        commands = TeamOrganizationCommandModel(account: account, origin: origin, vault: store.teamOrganizationCommandVault, service: backend, isCurrent: { scope == captured })
        loadedScope = captured
        await commands?.load()
        await browser?.refresh(team: teamID)
    }
}

private struct TeamOrganizationEditRequest: Identifiable {
    let id = UUID()
    let scope: String
    let account: String
    let origin: String
    let action: TeamOrganizationCommand.Action
    let team: String
    let revision: Double?
    let folder: String?
    let name: String
}
private struct TeamOrganizationEditSheet: View {
    let request: TeamOrganizationEditRequest
    let model: TeamOrganizationCommandModel
    let current: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    init(request: TeamOrganizationEditRequest, model: TeamOrganizationCommandModel, current: @escaping () -> Bool) {
        self.request = request; self.model = model; self.current = current; _name = State(initialValue: request.name)
    }
    private var validName: Bool { !request.action.needsName || (try? TeamOrganizationValue.name(.string(name.trimmingCharacters(in: .whitespacesAndNewlines)))) != nil }
    var body: some View {
        NavigationStack {
            Form {
                if current(), model.current {
                    if request.action.needsName {
                        Section { TextField("Name", text: $name).accessibilityIdentifier("teamChangeName") }
                    } else if !request.name.isEmpty { Section { Text(request.name).font(.headline) } }
                    Section { Text(explanation).foregroundStyle(.secondary) }
                    if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) } }
                    if model.busy { Section { ProgressView("Saving…") } }
                } else { ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Return to the original workspace and review this change again.")) }
            }
            .navigationTitle(request.action.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .formStyle(.grouped)
            .frame(width: 520, height: 340)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.action.needsName ? "Save" : "Confirm") { Task { await submit() } }
                        .disabled(!current() || !model.current || model.busy || !validName || model.pending != nil).accessibilityIdentifier("teamConfirmChange")
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }
    private var explanation: String {
        switch request.action {
        case .create: return "Create a shared home for your team. Existing personal projects stay where they are."
        case .rename: return "Update the name everyone in this team sees."
        case .archive: return "Archive this team and pause ordinary changes. The team and its saved work remain available."
        case .unarchive: return "Reopen this team so people with permission can make changes again."
        case .folderCreate: return "Add a folder to organize your team. Project access is managed separately."
        case .folderRename: return "Update this folder’s name for everyone in the team."
        case .folderRemove: return "Remove this folder. Projects and tasks are kept."
        }
    }
    @MainActor private func submit() async {
        guard current(), model.current, validName else { return }
        do {
            let command = try TeamOrganizationCommand(account: request.account, origin: request.origin, action: request.action, team: request.team, revision: request.revision, name: request.action.needsName ? name : nil, folder: request.folder)
            await model.send(command)
            if model.pending != nil || model.success != nil { dismiss() }
            else { error = model.message ?? "The change couldn’t be saved. Try again." }
        } catch { self.error = "Choose a name between 1 and 100 characters, without line breaks." }
    }
}

#if DEBUG
/// Synthetic state and private retry storage live only inside the exact isolated
/// app container. This peer never signs in, contacts a service or touches tasks.
enum TeamOrganizationFixture {
    static var management: Bool {
        ["com.dbakp.taskfold.workflowteststeamcommands", "com.dbakp.taskfold.mac.workflowteststeamcommands"].contains(Bundle.main.bundleIdentifier ?? "") && ProcessInfo.processInfo.arguments.contains("--team-command-testing")
    }
    static var enabled: Bool {
        management || (["com.dbakp.taskfold.workflowteststeams", "com.dbakp.taskfold.mac.workflowteststeams"].contains(Bundle.main.bundleIdentifier ?? "") && ProcessInfo.processInfo.arguments.contains("--team-overview-testing"))
    }
    static let account = "ea300000-0000-4000-8000-000000000001"
    static let team = "ea300000-0000-4000-8000-000000000002"
    static let origin = "https://synthetic.example"
    static var row: [String: JSON] { ["id": .string(team), "name": .string("Design studio"), "role": .string("owner"), "state": .string("active"), "revision": .number(3)] }
    @MainActor private static let peer = TeamOrganizationFixturePeer()
    @MainActor static func browser() -> TeamOrganizationBrowser {
        TeamOrganizationBrowser(account: account, origin: origin, current: { enabled }, overview: { try peer.overview() }, detail: { try peer.detail($0) })
    }
    @MainActor static func commands() -> TeamOrganizationCommandModel {
        TeamOrganizationCommandModel(account: account, origin: origin, vault: TeamOrganizationCommandVault(io: TeamOrganizationFixtureIO()), service: peer, isCurrent: { enabled })
    }
}
private struct TeamOrganizationFixtureIO: CalendarSecureItemIO {
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("TeamCommandFixture", isDirectory: true) }
    private func file(_ key: String) -> URL { Self.root.appendingPathComponent(key + ".json") }
    func read(key: String) throws -> Data? { let file = file(key); return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil }
    func write(_ data: Data, key: String) throws { try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true); try data.write(to: file(key), options: .atomic) }
    func remove(key: String) throws { let file = file(key); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
}
@MainActor private final class TeamOrganizationFixturePeer: TeamOrganizationCommandService {
    private var file: URL { TeamOrganizationFixtureIO.root.appendingPathComponent("peer.json") }
    private func read() throws -> [String: JSON] {
        if TeamOrganizationFixture.management, FileManager.default.fileExists(atPath: file.path) { return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: file)) }
        return ["teams": .object([TeamOrganizationFixture.team: .object(TeamOrganizationFixture.row)]),
                "folders": .object([TeamOrganizationFixture.team: .array([
                    .object(["id": .string("ea300000-0000-4000-8000-000000000003"), "name": .string("Product design"), "position": .number(0)]),
                    .object(["id": .string("ea300000-0000-4000-8000-000000000004"), "name": .string("Launch planning"), "position": .number(1)])])]), "requests": .object([:]), "receipts": .object([:]), "lost_folder_reply": .bool(false)]
    }
    private func write(_ raw: [String: JSON]) throws {
        try FileManager.default.createDirectory(at: TeamOrganizationFixtureIO.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(raw).write(to: file, options: .atomic)
    }
    func overview() throws -> TeamOrganizationOverview {
        let raw = try read()
        let teams = raw["teams"]!.object.values.sorted { $0.object["name"]!.text < $1.object["name"]!.text }
        return try TeamOrganizationOverview(list: ["enabled": .bool(TeamOrganizationFixture.management), "teams": .array(teams)], invitations: ["enabled": .bool(TeamOrganizationFixture.management), "invitations": .array([])], account: TeamOrganizationFixture.account, origin: TeamOrganizationFixture.origin)
    }
    func detail(_ team: String) throws -> TeamOrganizationDetail {
        let data = try read()
        guard var raw = data["teams"]!.object[team]?.object, !raw.isEmpty else { throw TeamOrganizationCommandFailure(code: "PT404") }
        raw["folders"] = data["folders"]!.object[team] ?? .array([])
        raw["members"] = .array([.object(["user_id": .string(TeamOrganizationFixture.account), "role": .string("owner")])]); raw["invitations"] = .array([])
        return try TeamOrganizationDetail(raw, team: team, account: TeamOrganizationFixture.account, origin: TeamOrganizationFixture.origin)
    }
    func teamOrganizationCommand(_ command: TeamOrganizationCommand) async throws -> TeamOrganizationCommandReceipt {
        guard TeamOrganizationFixture.management, command.account == TeamOrganizationFixture.account, command.origin == TeamOrganizationFixture.origin else { throw CancellationError() }
        var data = try read(), requests = data["requests"]!.object, receipts = data["receipts"]!.object
        let request: JSON = .object(["action": .string(command.action.rawValue), "body": .object(command.body)])
        if let old = requests[command.id] {
            guard old == request, case .object(let receipt)? = receipts[command.id] else { throw TeamOrganizationCommandFailure(code: "PT409") }
            return try command.confirmed(receipt)
        }
        var teams = data["teams"]!.object, folders = data["folders"]!.object
        var team = teams[command.team]?.object ?? [:], list = folders[command.team]?.list ?? []
        if command.action == .create { guard team.isEmpty else { throw TeamOrganizationCommandFailure(code: "PT409") }; team = ["id": .string(command.team), "role": .string("owner"), "name": command.body["name"]!, "state": .string("active"), "revision": .number(1)] }
        else {
            guard team["revision"] == command.body["revision"], team["state"] == .string(command.action == .unarchive ? "archived" : "active") else { throw TeamOrganizationCommandFailure(code: "PT409") }
            team["revision"] = .number(Double(team["revision"]!.integer + 1))
        }
        var receipt: [String: JSON] = ["id": .string(command.team), "revision": team["revision"]!, "state": .string(command.action == .archive ? "archived" : "active")]
        switch command.action {
        case .create: break
        case .rename: team["name"] = command.body["name"]
        case .archive: team["state"] = .string("archived")
        case .unarchive: team["state"] = .string("active")
        case .folderCreate:
            let id = UUID().uuidString.lowercased()
            list.append(.object(["id": .string(id), "name": command.body["name"]!, "position": .number(Double((list.map { $0.object["position"]!.integer }.max() ?? -1) + 1))])); receipt["folder_id"] = .string(id)
        case .folderRename, .folderRemove:
            guard let i = list.firstIndex(where: { $0.object["id"] == command.body["folder_id"] }) else { throw TeamOrganizationCommandFailure(code: "PT404") }
            if command.action == .folderRemove { list.remove(at: i) }
            else { var folder = list[i].object; folder["name"] = command.body["name"]; list[i] = .object(folder) }
        }
        let result = try command.confirmed(receipt)
        teams[command.team] = .object(team); folders[command.team] = .array(list)
        requests[command.id] = request; receipts[command.id] = .object(receipt)
        data["teams"] = .object(teams); data["folders"] = .object(folders); data["requests"] = .object(requests); data["receipts"] = .object(receipts)
        if command.action == .folderCreate, data["lost_folder_reply"] == .bool(false), ProcessInfo.processInfo.arguments.contains("--team-command-lose-folder-reply") {
            data["lost_folder_reply"] = .bool(true); try write(data); throw URLError(.networkConnectionLost)
        }
        try write(data); return result
    }
}
#endif
