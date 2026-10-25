import SwiftUI

struct TeamProjectManagementView: View {
    let teamID: String
    var projectID: String?
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var browser: TeamProjectBrowser?
    @State private var commands: TeamProjectCommandModel?
    @State private var loadedScope: String?
    @State private var editing: TeamProjectEditRequest?
    @State private var recentTaskMoves = false
    @State private var moving: TeamProjectMoveRequest?
    @State private var preparing = false
    @State private var reviewError: String?
    @State private var clearing: TeamProjectCommand?
    private var scope: String? {
        #if DEBUG
        if TeamProjectFixture.enabled { return "synthetic-projects-" + TeamMembershipFixture.account }
        #endif
        guard phase == .active, store.teamOrganizationReadable, let origin = try? store.backend.accountRemovalOrigin else { return nil }
        return "\(store.userID)|\(origin)|\(store.workspaceGeneration)|\(store.workspaceReadRevision)|\(store.backend.reminderSessionIncarnation)"
    }
    var body: some View {
        Group {
            if let scope, scope == loadedScope, let browser {
                if browser.loading { ProgressView("Refreshing projects…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    List {
                        commandStatus
                        if store.teamTaskMovesAvailable { Section { Button("Recent task moves", systemImage: "arrow.left.arrow.right") { recentTaskMoves = true }.accessibilityIdentifier("openRecentTeamTaskMoves") } }
                        if preparing { Section { ProgressView("Reviewing project branch…") } }
                        if let reviewError { Section { Label(reviewError, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) } }
                        if let message = browser.message { Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) } }
                        else if let detail = browser.detail { projectDetail(detail) }
                        else if let team = browser.team {
                            Section { Text(team.team.name).font(.title2.bold()); Text("Projects you can access in this team").foregroundStyle(.secondary) }
                            if browser.projects.isEmpty { Section { Text("No projects yet").foregroundStyle(.secondary) } }
                            ForEach(browser.projects, id: \.id) { project in
                                NavigationLink { TeamProjectManagementView(teamID: teamID, projectID: project.id) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(project.name ?? "Project \(project.id.suffix(8))").font(.headline).fixedSize(horizontal: false, vertical: true)
                                        Text("\(project.role.title) · \(project.visibility == .team ? "Team-visible" : "Private")").font(.caption).foregroundStyle(.secondary)
                                        if let archive = project.archive { Label(archive.title, systemImage: archive.effective ? "archivebox" : "circle").font(.caption).foregroundStyle(.secondary) }
                                        if let hierarchy = project.hierarchy { Text(parentTitle(hierarchy, projects: browser.projects)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                        if let folder = project.folder, let name = team.folders.first(where: { $0.id == folder })?.name { Label(name, systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical, 5)
                                }.accessibilityIdentifier("teamProject-\(project.id)")
                            }
                        }
                    }.refreshable { await browser.refresh(project: projectID) }
                }
            } else { ContentUnavailableView("Projects unavailable", systemImage: "folder", description: Text("Return to the original synced workspace to view this team.")) }
        }
        .sheet(isPresented: $recentTaskMoves) { TeamTaskMoveView() }
        .navigationTitle(projectID == nil ? "Projects" : browser?.detail?.access.name ?? "Project")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth: 540, idealWidth: 660, minHeight: 500)
        #endif
        .toolbar {
            if scope != nil, scope == loadedScope, browser?.loading == false, commands?.pending == nil, commands?.busy == false, let team = browser?.team {
                if projectID == nil, team.team.role != .guest, !team.team.archived, browser?.setupPaused == false {
                    ToolbarItem { Button("New project", systemImage: "plus") { begin(.create) }.accessibilityIdentifier("teamNewProject") }
                } else if browser?.detail?.editable == true {
                    ToolbarItem { Button("Project settings", systemImage: "slider.horizontal.3") { begin(.settings) }.accessibilityIdentifier("teamProjectSettings") }
                }
            }
            ToolbarItem { Button { Task { await browser?.refresh(project: projectID) } } label: { Label("Refresh projects", systemImage: "arrow.clockwise") }.disabled(scope == nil || browser?.loading == true || commands?.busy == true) }
        }
        .task(id: scope) { await start() }
        .onDisappear { browser?.invalidate(); commands?.close() }
        .sheet(item: $editing) { request in
            if let commands { TeamProjectEditSheet(request: request, model: commands, current: { scope == request.scope && scope == loadedScope }) }
        }
        .sheet(item: $moving) { request in
            if let commands {
                TeamProjectMoveSheet(request: request, model: commands, current: { scope == request.scope && loadedScope == request.scope && browser?.detail?.access == request.detail.access }, review: { parent in
                    try await hierarchyReview(team: request.team, project: request.detail.access.id, parent: parent, action: .move)
                })
            }
        }
        .confirmationDialog("Clear saved project request?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            if let command = clearing { Button("Clear saved request", role: .destructive) { Task { await commands?.clearReviewedRequest(command) } } }
        } message: { Text("Check the latest project first. Clearing this device’s saved request does not undo a change that may already have been accepted.") }
        .onChange(of: commands?.receipt) { _, receipt in
            guard receipt != nil, scope == loadedScope else { return }; editing = nil; moving = nil
            Task { await browser?.refresh(project: projectID) }
            #if DEBUG
            if TeamProjectFixture.enabled { return }
            #endif
            let account = store.userID, generation = store.workspaceGeneration, session = store.backend.reminderSessionIncarnation
            Task { guard account == store.userID, generation == store.workspaceGeneration, session == store.backend.reminderSessionIncarnation else { return }; await store.sync() }
        }
    }
    @ViewBuilder private var commandStatus: some View {
        if let commands {
            if let pending = commands.pending {
                Section("Saved project request") {
                    Text(pending.action.title).font(.headline)
                    if let name = pending.body["name"]?.text { Text(name).fixedSize(horizontal: false, vertical: true) }
                    if let raw = pending.body["visibility"]?.text, let visibility = TeamProjectVisibility(rawValue: raw) {
                        Text(visibility == .team ? "Requested visibility: Team-visible" : "Requested visibility: Private").font(.callout)
                        if pending.body["folder_id"] == .null { Text("Requested folder: No folder").font(.callout) }
                        else if let id = pending.body["folder_id"]?.text {
                            if let folder = browser?.team?.folders.first(where: { $0.id == id }) { Text("Requested folder: \(folder.name)").font(.callout) }
                            else { Text("Requested folder reference: \(id)").font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    if pending.action.hierarchical {
                        Text(pending.body["parent_id"] == .null ? "Destination: Team level" : "Destination: Selected project").font(.callout)
                        Text("Retry keeps the exact destination and branch you reviewed.").font(.callout).foregroundStyle(.secondary)
                    }
                    if let count = pending.body["affected_count"]?.integer { Text("Reviewed branch: \(count == 1 ? "1 project" : "\(count) projects"). Tasks and explicit subproject archive settings are preserved.").font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if let user = pending.body["user_id"]?.text { Text("Member reference: \(user)").font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true) }
                    if let role = pending.body["role"]?.text { Text("Requested access: \(role.capitalized)").font(.callout) }
                    Text("The result is uncertain. Retry sends the same saved request, even after relaunch.").font(.callout).foregroundStyle(.secondary)
                    if !pending.canRetry { Text("This review has expired. Check the project before clearing it.").foregroundStyle(.secondary) }
                    Button("Retry saved request") { Task { await commands.retry() } }.disabled(commands.busy || !pending.canRetry).accessibilityIdentifier("teamProjectRetry")
                    NavigationLink("Check latest project") { TeamProjectManagementView(teamID: pending.team, projectID: pending.project) }
                    Button("Clear saved request", role: .destructive) { clearing = pending }.disabled(commands.busy)
                }
            }
            if let message = commands.message { Section { Text(message).foregroundStyle(.secondary) } }
            if let success = commands.success { Section {
                Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityIdentifier("teamProjectSuccess")
                if commands.appliedAction == .createSubproject, let receipt = commands.receipt {
                    NavigationLink("Open subproject") { TeamProjectManagementView(teamID: teamID, projectID: receipt.project) }.accessibilityIdentifier("teamOpenSubproject")
                }
            } }
            if commands.busy { Section { ProgressView("Saving project change…") } }
        }
    }
    @ViewBuilder private func projectDetail(_ detail: TeamProjectManagementDetail) -> some View {
        Section {
            Text(detail.access.name ?? "Project \(detail.access.id.suffix(8))").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            if let archive = detail.access.archive { Label(archive.title, systemImage: archive.effective ? "archivebox" : "circle").accessibilityIdentifier("teamProjectArchiveStatus") }
            if let hierarchy = detail.access.hierarchy {
                if let parent = hierarchy.parent { NavigationLink("Open parent project") { TeamProjectManagementView(teamID: teamID, projectID: parent) }.accessibilityIdentifier("teamOpenParent") }
                else { Text(hierarchy.parentUnavailable ? "Parent project unavailable" : "Team-level project").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("teamProjectParentStatus") }
            }
            Text("Your access: \(detail.access.role.title)").foregroundStyle(.secondary)
            Label(detail.access.visibility == .team ? "Team-visible" : "Private", systemImage: detail.access.visibility == .team ? "person.2" : "lock")
            if let folder = detail.access.folder, let name = browser?.team?.folders.first(where: { $0.id == folder })?.name { Label(name, systemImage: "folder") }
            Text(detail.access.visibility == .team ? "Team members have Editor access unless a project override changes it. Guests need explicit access." : "Only people with project access, plus the team owner and admins, can view this project.").font(.callout).foregroundStyle(.secondary)
        }
        if detail.access.canManageAccess, let archive = detail.access.archive {
            Section("Organize project") {
                if detail.editable { Button("Rename project", systemImage: "pencil") { begin(.rename) }.accessibilityIdentifier("teamProjectRename") }
                if detail.editable, detail.access.hierarchy != nil {
                    Button("New subproject", systemImage: "folder.badge.plus") { begin(.createSubproject) }.accessibilityIdentifier("teamNewSubproject")
                    Button("Move project", systemImage: "arrow.turn.down.right") { beginMove(detail) }.accessibilityIdentifier("teamMoveProject")
                }
                if archive.own {
                    if detail.editable && !archive.inherited { Button("Reopen project", systemImage: "tray.and.arrow.up") { begin(.unarchive) }.accessibilityIdentifier("teamProjectReopen") }
                    else if archive.inherited { Text("Reopen the parent project first.").foregroundStyle(.secondary) }
                } else { Button("Archive project", systemImage: "archivebox") { begin(.archive) }.accessibilityIdentifier("teamProjectArchive") }
            }.disabled(preparing || commands?.pending != nil || commands?.busy == true)
        }
        Section { Text("Task editing isn’t available in this preview.").foregroundStyle(.secondary) }
        if detail.access.canManageAccess {
            Section {
                ForEach(detail.members) { member in
                    let person = identity(member)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.title(account: detail.access.account)).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(person.subtitle(account: detail.access.account)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(detail.effective(member)?.title ?? "No project access").font(.subheadline).foregroundStyle(.secondary)
                        if member.role.directoryVisible { Text("Managed through their team role").font(.caption).foregroundStyle(.secondary) }
                        else if commands?.pending == nil {
                            VStack(alignment: .leading, spacing: 8) {
                                if !detail.roles(for: member).isEmpty { Button("Change access") { begin(.setAccess, member: member) }.accessibilityIdentifier("teamProjectAccess-\(member.id)") }
                                if detail.canReset(member) { Button("Reset to team permissions") { begin(.resetAccess, member: member) }.accessibilityIdentifier("teamProjectReset-\(member.id)") }
                            }.buttonStyle(.borderless).disabled(commands?.busy == true)
                        }
                    }.padding(.vertical, 5)
                }
            } header: { Text("Project access") } footer: { Text("Profile names are chosen by members. Email is shown only when your team role allows it. Project management does not grant access to other projects.") }
        }
    }
    private func identity(_ member: TeamOrganizationDetail.Member) -> TeamOrganizationDetail.Member {
        var person = member
        if let known = browser?.team?.members.first(where: { $0.id == member.id && $0.role == member.role }) {
            person.verifiedEmail = known.verifiedEmail
            if person.displayName == nil { person.displayName = known.displayName }
        }
        return person
    }
    private func begin(_ action: TeamProjectCommand.Action, member: TeamOrganizationDetail.Member? = nil) {
        guard !preparing, let scope, scope == loadedScope, let team = browser?.team, let commands, commands.current, commands.pending == nil, !commands.busy else { return }
        let detail = browser?.detail
        if action == .create { guard team.team.role != .guest, !team.team.archived, browser?.setupPaused == false else { return } }
        else {
            guard let detail, detail.access.canManageAccess else { return }
            if action == .settings || action == .rename || action == .unarchive || action.hierarchical { guard detail.editable else { return } }
            if action == .rename || action.structural { guard let archive = detail.access.archive else { return }; if action.structural { guard archive.own != (action == .archive), action != .unarchive || !archive.inherited else { return } } }
            if action == .setAccess { guard let member, !detail.roles(for: member).isEmpty else { return } }
            if action == .resetAccess { guard let member, detail.canReset(member) else { return } }
        }
        reviewError = nil
        if action == .createSubproject, let detail, detail.access.hierarchy != nil {
            preparing = true
            let newProject = UUID().uuidString.lowercased()
            Task { @MainActor in
                defer { preparing = false }
                do {
                    let reviewed = try await hierarchyReview(team: team, project: newProject, parent: detail.access.id, action: action)
                    guard self.scope == scope, loadedScope == scope, browser?.detail?.access == detail.access, commands.current, commands.pending == nil,
                          reviewed.parentRevision == detail.access.revision, reviewed.teamRevision == team.team.revision else { throw CancellationError() }
                    editing = TeamProjectEditRequest(scope: scope, team: team, detail: detail, action: action, member: nil, review: nil, hierarchy: reviewed, destinationName: detail.access.name ?? "Selected project")
                } catch { if self.scope == scope, loadedScope == scope { reviewError = "This parent couldn’t be reviewed. Refresh and check your management access." } }
            }
        } else if action.structural, let detail {
            preparing = true
            Task { @MainActor in
                defer { preparing = false }
                do {
                    let review: TeamProjectStructureReview
                    #if DEBUG
                    if TeamProjectFixture.enabled { review = try TeamProjectFixture.review(project: detail.access.id, action: action) }
                    else { review = try await store.backend.teamProjectStructureReview(team: teamID, project: detail.access.id, action: action, account: team.account, origin: team.origin) }
                    #else
                    review = try await store.backend.teamProjectStructureReview(team: teamID, project: detail.access.id, action: action, account: team.account, origin: team.origin)
                    #endif
                    guard self.scope == scope, loadedScope == scope, browser?.detail?.access == detail.access, commands.current, commands.pending == nil,
                          review.revision == detail.access.revision, review.teamRevision == team.team.revision, review.archive == detail.access.archive else { throw CancellationError() }
                    editing = TeamProjectEditRequest(scope: scope, team: team, detail: detail, action: action, member: nil, review: review)
                } catch {
                    if self.scope == scope, loadedScope == scope { reviewError = "This project branch couldn’t be reviewed. Refresh and check that you can manage every subproject." }
                }
            }
        } else { editing = TeamProjectEditRequest(scope: scope, team: team, detail: detail, action: action, member: member.map(identity), review: nil) }
    }
    private func parentTitle(_ hierarchy: TeamProjectHierarchy, projects: [TeamProjectAccess]) -> String {
        if hierarchy.parentUnavailable { return "Parent project unavailable" }
        guard let parent = hierarchy.parent else { return "Team level" }
        return projects.first(where: { $0.id == parent })?.name.map { "In \($0)" } ?? "Subproject"
    }
    private func beginMove(_ detail: TeamProjectManagementDetail) {
        guard !preparing, let scope, scope == loadedScope, detail.editable, detail.access.hierarchy != nil,
              commands?.current == true, commands?.pending == nil, commands?.busy == false, let team = browser?.team,
              let picker = makeBrowser(captured: scope) else { return }
        moving = TeamProjectMoveRequest(scope: scope, team: team, detail: detail, browser: picker)
    }
    private func hierarchyReview(team: TeamOrganizationDetail, project: String, parent: String?, action: TeamProjectCommand.Action) async throws -> TeamProjectHierarchyReview {
        #if DEBUG
        if TeamProjectFixture.enabled { return try TeamProjectFixture.hierarchy(project: project, parent: parent, action: action) }
        #endif
        return try await store.backend.teamProjectHierarchyReview(team: teamID, project: project, parent: parent, action: action, account: team.account, origin: team.origin)
    }
    private func makeBrowser(captured: String) -> TeamProjectBrowser? {
        #if DEBUG
        if TeamProjectFixture.enabled { return TeamProjectFixture.browser() }
        #endif
        let account = store.userID; guard let origin = try? store.backend.accountRemovalOrigin else { return nil }; let backend = store.backend
        return TeamProjectBrowser(account: account, origin: origin, team: teamID, current: { scope == captured }, fence: { try await backend.workspaceBoundary(account: account).raw["token"]!.text }, readTeam: { try await backend.teamOrganizationDetail(team: teamID, account: account, origin: origin) }, page: { try await backend.teamProjectPage(team: teamID, account: account, origin: origin, after: $0) }, detail: { try await backend.teamProjectManagementDetail(team: teamID, project: $0, account: account, origin: origin) })
    }
    @MainActor private func start() async {
        browser?.invalidate(); commands?.close(); browser = nil; commands = nil; loadedScope = nil
        guard let captured = scope else { return }
        #if DEBUG
        if TeamProjectFixture.enabled {
            browser = TeamProjectFixture.browser(); commands = TeamProjectFixture.commands(); loadedScope = captured
            await commands?.load(); await browser?.refresh(project: projectID); return
        }
        #endif
        let account = store.userID; guard let origin = try? store.backend.accountRemovalOrigin else { return }; let backend = store.backend
        browser = makeBrowser(captured: captured)
        commands = TeamProjectCommandModel(account: account, origin: origin, vault: store.teamProjectCommandVault, service: backend, isCurrent: { scope == captured }); loadedScope = captured
        await commands?.load(); await browser?.refresh(project: projectID)
    }
}
private struct TeamProjectEditRequest: Identifiable {
    let id = UUID()
    let scope: String
    let team: TeamOrganizationDetail
    let detail: TeamProjectManagementDetail?
    let action: TeamProjectCommand.Action
    let member: TeamOrganizationDetail.Member?
    let review: TeamProjectStructureReview?
    var hierarchy: TeamProjectHierarchyReview? = nil
    var destinationName: String? = nil
}
private struct TeamProjectEditSheet: View {
    let request: TeamProjectEditRequest
    let model: TeamProjectCommandModel
    let current: () -> Bool
    var changeDestination: (() -> Void)? = nil
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var name = ""
    @State private var visibility: TeamProjectVisibility
    @State private var folder: String?
    @State private var role: TeamProjectRole
    @State private var error: String?
    init(request: TeamProjectEditRequest, model: TeamProjectCommandModel, current: @escaping () -> Bool, changeDestination: (() -> Void)? = nil) {
        self.request = request; self.model = model; self.current = current; self.changeDestination = changeDestination
        _name = State(initialValue: request.action == .rename ? request.detail?.access.name ?? "" : "")
        _visibility = State(initialValue: request.action == .createSubproject ? .private : request.detail?.access.visibility ?? .private); _folder = State(initialValue: request.action == .createSubproject ? nil : request.detail?.access.folder)
        _role = State(initialValue: request.member.flatMap { request.detail?.grants[$0.id] ?? request.detail?.effective($0) } ?? .viewer)
    }
    private var screenTitle: String {
        guard textSize.isAccessibilitySize else { return request.action.title }
        switch request.action { case .rename: return "Rename"; case .archive: return "Archive"; case .unarchive: return "Reopen"; case .settings: return "Settings"; case .setAccess: return "Access"; case .resetAccess: return "Reset access"; case .create: return "New project"; case .move: return "Move"; case .createSubproject: return "Subproject" }
    }
    private var canConfirm: Bool {
        switch request.action {
        case .move: return request.hierarchy != nil
        case .createSubproject: return request.hierarchy != nil && (try? TeamOrganizationValue.name(.string(name.trimmingCharacters(in: .whitespacesAndNewlines)))) != nil
        case .archive, .unarchive: return request.review != nil
        case .rename: return name.trimmingCharacters(in: .whitespacesAndNewlines) != request.detail?.access.name && (try? TeamOrganizationValue.name(.string(name.trimmingCharacters(in: .whitespacesAndNewlines)))) != nil
        case .create: return (try? TeamOrganizationValue.name(.string(name.trimmingCharacters(in: .whitespacesAndNewlines)))) != nil
        case .settings: return visibility != request.detail?.access.visibility || folder != request.detail?.access.folder
        case .setAccess:
            guard let id = request.member?.id else { return false }; return request.detail?.grants[id] != role
        case .resetAccess: return true
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if current(), model.current {
                    if request.action.creation || request.action == .rename { Section { TextField("Project name", text: $name).focused($nameFocused).submitLabel(.done).onSubmit { nameFocused = false }.accessibilityIdentifier("teamProjectName") } }
                    else { Section { Text(request.detail?.access.name ?? "Project").font(.headline) } }
                    if let hierarchy = request.hierarchy {
                        Section("Review project branch") {
                            Label(hierarchy.count == 1 ? "1 project" : "\(hierarchy.count) projects", systemImage: "folder.badge.gearshape").font(.headline).accessibilityIdentifier("teamProjectHierarchyCount")
                            Text("Destination: \(request.destinationName ?? "Selected project")").font(.headline).lineLimit(nil).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("teamProjectDestination")
                            if hierarchy.destinationArchived { Label("This destination is archived. The project and its tasks will stay hidden from active views until the archived parent branch is reopened.", systemImage: "archivebox").lineLimit(nil).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("teamHierarchyArchiveWarning") }
                            if hierarchy.archived { Text("This project keeps its own archived status.").lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                            if let changeDestination { Button("Change destination", action: changeDestination).disabled(model.busy || model.pending != nil).accessibilityIdentifier("teamChangeDestination") }
                            Text(request.action == .createSubproject ? "Choose visibility and a folder for the new project. Parent permissions do not carry over." : "All tasks, discussions and files stay saved. Each project keeps its permissions, folder and own archive setting.")
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let review = request.review {
                        Section("Review project branch") {
                            Label(review.count == 1 ? "1 project" : "\(review.count) projects", systemImage: "folder.badge.gearshape").font(.headline).accessibilityIdentifier("teamProjectBranchCount")
                            Text(request.action == .archive ? "This project and its subprojects will be hidden from active task views. All tasks, discussions and files stay saved." : "This project will return to active views. Subprojects that were archived individually will stay archived.")
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            Text("Each subproject keeps its own archive setting. No task is completed, rescheduled or deleted.").font(.callout).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if request.action.creation || request.action == .settings {
                        Section {
                            choice("Private", detail: "Explicit project access, plus the team owner and admins.", selected: visibility == .private, id: "teamProjectPrivate") { visibility = .private }
                            choice("Team-visible", detail: "Team members default to Editor. Guests still need explicit access.", selected: visibility == .team, id: "teamProjectVisible") { visibility = .team }
                        } header: { Text("Visibility") }
                        Section {
                            choice("No folder", detail: "Keep this project outside team folders.", selected: folder == nil, id: "teamProjectNoFolder") { folder = nil }
                            ForEach(request.team.folders) { value in choice(value.name, detail: "", selected: folder == value.id, id: "teamProjectFolder-\(value.id)") { folder = value.id } }
                        } header: { Text("Folder") }
                    }
                    if let member = request.member {
                        Section {
                            Text(member.title(account: request.team.account)).font(.headline).accessibilityIdentifier("teamProjectTarget")
                            if let email = member.verifiedEmail { Text(verbatim: email).lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                            Text(member.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).accessibilityIdentifier("teamProjectTargetAccount")
                            if member.id == request.team.account { Text("This changes your own access. You may need a team admin to restore management permissions.").foregroundStyle(.secondary) }
                        } header: { Text("Member") }
                        if request.action == .setAccess {
                            Section { ForEach(member.role == .guest ? [TeamProjectRole.editor, .viewer] : TeamProjectRole.allCases, id: \.rawValue) { value in choice(value.title, detail: roleDescription(value), selected: role == value, id: "teamProjectRole-\(value.rawValue)") { role = value } } }
                        } else { Section { Text(request.detail?.resetDescription(member) ?? "Review the team’s default permissions.").foregroundStyle(.secondary) } }
                    }
                    if let error { Section { Text(error).foregroundStyle(.secondary) } }
                    if model.busy { Section { ProgressView("Saving project change…") } }
                } else { ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Return to the original workspace and review this change again.")) }
            }
            .accessibilityIdentifier("teamProjectReviewForm")
            .navigationTitle(screenTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .formStyle(.grouped).frame(width: 520, height: 560)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) { Button(request.action.creation ? "Create" : "Confirm") { Task { await submit() } }.disabled(!canConfirm || !current() || !model.current || model.pending != nil || model.busy).accessibilityIdentifier("teamProjectConfirm") }
            }.interactiveDismissDisabled(model.busy)
        }
    }
    private func choice(_ title: String, detail: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(alignment: .top, spacing: 12) { VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline).fixedSize(horizontal: false, vertical: true); if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }; Spacer(minLength: 8); if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityHidden(true) } }.padding(.vertical, 4) }.buttonStyle(.plain).accessibilityLabel(title).accessibilityHint(detail).accessibilityValue(selected ? "Selected" : "").accessibilityIdentifier(id)
    }
    private func roleDescription(_ role: TeamProjectRole) -> String {
        switch role { case .manager: "Manage this project’s settings and access."; case .editor: "Edit this project’s tasks when team task editing is available."; case .viewer: "Read this project without editing it." }
    }
    @MainActor private func submit() async {
        guard canConfirm, current(), model.current else { return }
        do {
            let settings = request.action.creation || request.action == .settings
            let command = try TeamProjectCommand(account: request.team.account, origin: request.team.origin, action: request.action, team: request.team.team.id, project: request.hierarchy?.project ?? request.detail?.access.id ?? UUID().uuidString.lowercased(), teamRevision: request.team.team.revision, revision: request.action.creation ? nil : request.detail?.access.revision, name: request.action.creation || request.action == .rename ? name : nil, visibility: settings ? visibility : nil, folder: settings ? folder : nil, user: request.member?.id, role: request.action == .setAccess ? role : nil, review: request.review, hierarchy: request.hierarchy)
            await model.send(command)
            if model.pending != nil || model.success != nil { dismiss() } else { error = model.message ?? "The change couldn’t be saved. Try again." }
        } catch { self.error = "This change couldn’t be prepared. Check the project and try again." }
    }
}

private struct TeamProjectMoveRequest: Identifiable {
    let id = UUID()
    let scope: String
    let team: TeamOrganizationDetail
    let detail: TeamProjectManagementDetail
    let browser: TeamProjectBrowser
}
private struct TeamProjectMoveSheet: View {
    let request: TeamProjectMoveRequest
    let model: TeamProjectCommandModel
    let current: () -> Bool
    let review: (String?) async throws -> TeamProjectHierarchyReview
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var prepared: TeamProjectEditRequest?
    @State private var preparing = false
    @State private var error: String?
    private var valid: Bool {
        current() && model.current && model.pending == nil && request.browser.team?.team.revision == request.team.team.revision &&
        request.browser.projects.first(where: { $0.id == request.detail.access.id }) == request.detail.access
    }
    var body: some View {
        Group {
            if let prepared { TeamProjectEditSheet(request: prepared, model: model, current: current, changeDestination: { self.prepared = nil; error = nil }) }
            else {
                NavigationStack {
                    List {
                        if !current() || !model.current { Section { Text("Return to the original workspace and review this move again.") } }
                        else if !loaded || request.browser.loading { Section { ProgressView("Finding destinations…") } }
                        else if let message = request.browser.message { Section { Text(message).foregroundStyle(.secondary); Button("Try again") { Task { await request.browser.refresh() } } } }
                        else if !valid { Section { Text("The project changed. Close this screen and refresh before moving it.").foregroundStyle(.secondary) } }
                        else {
                            Section { Text("Choose where to move \(request.detail.access.name ?? "this project"). Its subprojects move with it.").lineLimit(nil).fixedSize(horizontal: false, vertical: true) }
                            if request.detail.access.hierarchy?.parent != nil || request.detail.access.hierarchy?.parentUnavailable == true {
                                Section { Button("Team level", systemImage: "square.grid.2x2") { prepare(parent: nil, name: "Team level") }.accessibilityIdentifier("teamMoveTopLevel") }
                            }
                            Section("Projects you manage") {
                                let options = TeamProjectMoveOptions.destinations(for: request.detail.access, in: request.browser.projects)
                                if options.isEmpty { Text("No other destinations available").foregroundStyle(.secondary) }
                                ForEach(options, id: \.id) { project in
                                    Button { prepare(parent: project.id, name: project.name ?? "Selected project") } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(project.name ?? "Project \(project.id.suffix(8))").font(.headline).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                            if let archive = project.archive { Text(archive.title).font(.caption).foregroundStyle(.secondary) }
                                            if options.filter({ $0.name == project.name }).count > 1 { Text("Project reference: \(project.id.suffix(8))").font(.caption).foregroundStyle(.secondary) }
                                        }.padding(.vertical, 4)
                                    }.accessibilityIdentifier("teamMoveTo-\(project.id)")
                                }
                            }
                        }
                        if preparing { Section { ProgressView("Reviewing project branch…") } }
                        if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true) } }
                    }
                    .accessibilityIdentifier("teamProjectDestinationList")
                    .disabled(preparing)
                    .navigationTitle("Move project")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #else
                    .frame(width: 520, height: 560)
                    #endif
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                }
            }
        }
        .task { await request.browser.refresh(); loaded = true }
        .onDisappear { request.browser.invalidate() }
    }
    private func prepare(parent: String?, name: String) {
        guard valid, !preparing else { return }; preparing = true; error = nil
        Task { @MainActor in
            defer { preparing = false }
            do {
                let result = try await review(parent)
                guard valid, result.parent == parent, result.revision == request.detail.access.revision,
                      result.teamRevision == request.team.team.revision else { throw CancellationError() }
                if let parent { guard result.parentRevision == request.browser.projects.first(where: { $0.id == parent })?.revision else { throw CancellationError() } }
                prepared = TeamProjectEditRequest(scope: request.scope, team: request.team, detail: request.detail, action: .move, member: nil, review: nil, hierarchy: result, destinationName: name)
            } catch { if current(), model.current { self.error = "This branch couldn’t be reviewed. Close and refresh, then check that you can manage every subproject and the destination." } }
        }
    }
}

#if DEBUG
/// Exact isolated test namespace only. No real Auth, Keychain, task or mail calls.
@MainActor private enum TeamProjectFixture {
    static var enabled: Bool { TeamMembershipFixture.enabled && ProcessInfo.processInfo.arguments.contains("--team-project-testing") }
    static let projectTeam = TeamMembershipFixture.team
    static let folder = "ea320000-0000-4000-8000-000000000011"
    static let actors = [TeamMembershipFixture.owner, TeamMembershipFixture.admin, TeamMembershipFixture.member, TeamMembershipFixture.guest]
    static func teamRole(_ account: String) -> String { account == TeamMembershipFixture.owner ? "owner" : account == TeamMembershipFixture.admin ? "admin" : account == TeamMembershipFixture.guest ? "guest" : "member" }
    static func name(_ account: String) -> String { account == TeamMembershipFixture.owner ? "Alex Rivera" : account == TeamMembershipFixture.guest ? "Jordan Vale" : "Sam Chen" }
    private static let peer = TeamProjectFixturePeer()
    static func browser() -> TeamProjectBrowser {
        TeamProjectBrowser(account: TeamMembershipFixture.account, origin: TeamMembershipFixture.origin, team: projectTeam, current: { enabled }, fence: { try peer.fence() }, readTeam: { try peer.team() }, page: { try peer.page(after: $0) }, detail: { try peer.detail($0) })
    }
    static func review(project: String, action: TeamProjectCommand.Action) throws -> TeamProjectStructureReview { try peer.review(project, action: action) }
    static func hierarchy(project: String, parent: String?, action: TeamProjectCommand.Action) throws -> TeamProjectHierarchyReview { try peer.hierarchy(project, parent: parent, action: action) }
    static func commands() -> TeamProjectCommandModel { TeamProjectCommandModel(account: TeamMembershipFixture.account, origin: TeamMembershipFixture.origin, vault: TeamProjectCommandVault(io: TeamProjectFixtureIO()), service: peer, isCurrent: { enabled }) }
}
private struct TeamProjectFixtureIO: CalendarSecureItemIO {
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("TeamProjectFixture", isDirectory: true) }
    func read(key: String) throws -> Data? { let url = Self.root.appendingPathComponent(key + ".json"); return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
    func write(_ data: Data, key: String) throws { try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true); try data.write(to: Self.root.appendingPathComponent(key + ".json"), options: .atomic) }
    func remove(key: String) throws { let url = Self.root.appendingPathComponent(key + ".json"); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
@MainActor private final class TeamProjectFixturePeer: TeamProjectCommandService {
    private var file: URL { TeamProjectFixtureIO.root.appendingPathComponent("peer.json") }
    private var account: String { TeamMembershipFixture.account }
    private var didReset = false
    private func read() throws -> [String: JSON] {
        if !didReset {
            didReset = true
            if TeamProjectFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-project-reset-fixture"), FileManager.default.fileExists(atPath: TeamProjectFixtureIO.root.path) { try FileManager.default.removeItem(at: TeamProjectFixtureIO.root) }
        }
        if FileManager.default.fileExists(atPath: file.path) { return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: file)) }
        var seed: [String: JSON] = [:]
        if ProcessInfo.processInfo.arguments.contains("--team-project-seed") {
            let id = "ea330000-0000-4000-8000-000000000001"
            seed[id] = .object(["id": .string(id), "team_id": .string(TeamProjectFixture.projectTeam), "name": .string("Reading room"), "visibility": .string("private"), "folder_id": .null, "revision": .number(1), "creator_id": .string(TeamMembershipFixture.owner), "grants": .object([TeamMembershipFixture.owner: .string("manager")])])
        }
        if ProcessInfo.processInfo.arguments.contains("--team-project-hierarchy-seed") {
            let root = "ea330000-0000-4000-8000-000000000001"
            for (id, title, parent, archived, creator) in [("ea330000-0000-4000-8000-000000000002", "Design workshop", Optional<String>.none, true, TeamMembershipFixture.admin), ("ea330000-0000-4000-8000-000000000003", "Reference shelf", Optional(root), true, TeamMembershipFixture.member)] {
                seed[id] = .object(["id": .string(id), "team_id": .string(TeamProjectFixture.projectTeam), "name": .string(title), "visibility": .string("private"), "folder_id": .null, "revision": .number(1), "parent_id": parent.map(JSON.string) ?? .null, "is_archived": .bool(archived), "ancestor_archived": .bool(false), "creator_id": .string(creator), "grants": .object([TeamMembershipFixture.owner: .string("manager")])])
            }
        }
        return ["projects": .object(seed), "receipts": .object([:]), "history": .array([]), "lost": .bool(false)]
    }
    private func write(_ data: [String: JSON]) throws { try FileManager.default.createDirectory(at: TeamProjectFixtureIO.root, withIntermediateDirectories: true); try JSONEncoder().encode(data).write(to: file, options: .atomic) }
    func fence() throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return CalendarOAuthConfiguration.digest(try encoder.encode(read()).base64EncodedString() + account + String(TeamMembershipFixture.setupEnabled)) }
    func team() throws -> TeamOrganizationDetail {
        let role = TeamProjectFixture.teamRole(account)
        var raw: [String: JSON] = ["id": .string(TeamProjectFixture.projectTeam), "name": .string("Design studio"), "role": .string(role), "state": .string("active"), "revision": .number(3)]
        if role != "guest" { raw["folders"] = .array([.object(["id": .string(TeamProjectFixture.folder), "name": .string("Design systems"), "position": .number(0)])]) }
        if ["owner", "admin"].contains(role) {
            raw["members"] = .array(TeamProjectFixture.actors.map { .object(["user_id": .string($0), "role": .string(TeamProjectFixture.teamRole($0)), "display_name": .string(TeamProjectFixture.name($0)), "verified_email": .string(TeamMembershipFixture.email($0))]) }); raw["invitations"] = .array([])
        }
        return try TeamOrganizationDetail(raw, team: TeamProjectFixture.projectTeam, account: account, origin: TeamMembershipFixture.origin)
    }
    private func role(_ row: [String: JSON]) -> String? {
        let team = TeamProjectFixture.teamRole(account)
        if ["owner", "admin"].contains(team) { return "manager" }
        return row["grants"]?.object[account]?.text ?? (team == "member" && row["visibility"] == .string("team") ? "editor" : nil)
    }
    private func presentation(_ row: [String: JSON], projects: [String: JSON]) -> [String: JSON]? {
        guard let projectRole = role(row) else { return nil }
        let parent = row["parent_id"] ?? .null
        let unavailable = parent != .null && projects[parent.text].map { role($0.object) == nil } != false
        return row.filter { !["grants", "creator_id"].contains($0.key) }.merging(["project_hierarchy_protocol": .number(1), "parent_id": unavailable ? .null : parent, "parent_unavailable": .bool(unavailable)]) { _, b in b }.merging(["project_state_protocol": .number(1), "is_archived": row["is_archived"] ?? .bool(false), "ancestor_archived": row["ancestor_archived"] ?? .bool(false)]) { _, b in b }.merging(["role": .string(projectRole), "can_edit_tasks": .bool(false), "can_manage_access": .bool(projectRole == "manager")]) { _, b in b }
    }
    private var context: [String: JSON] { ["protocol": .number(1), "account": .string(account), "team_id": .string(TeamProjectFixture.projectTeam), "team_revision": .number(3), "team_state": .string("active"), "setup_paused": .bool(!TeamMembershipFixture.setupEnabled)] }
    func page(after: String?) throws -> TeamProjectPage {
        let projects = try read()["projects"]!.object
        let rows = projects.values.compactMap { presentation($0.object, projects: projects) }.filter { after == nil || $0["id"]!.text > after! }.sorted { $0["id"]!.text < $1["id"]!.text }
        var raw = context; raw["task_writes_enabled"] = .bool(false); raw["projects"] = .array(Array(rows.prefix(50)).map(JSON.object)); raw["next_cursor"] = rows.count > 50 ? rows[49]["id"] : .null
        return try TeamProjectPage(raw, account: account, origin: TeamMembershipFixture.origin, team: TeamProjectFixture.projectTeam, after: after)
    }
    func detail(_ id: String) throws -> TeamProjectManagementDetail {
        let projects = try read()["projects"]!.object
        guard let row = projects[id]?.object, let visible = presentation(row, projects: projects) else { throw TeamProjectAccessUnavailable() }
        var raw = context.merging(visible) { _, b in b }
        if role(row) == "manager" {
            raw["grants"] = .array(row["grants"]!.object.sorted { $0.key < $1.key }.map { .object(["user_id": .string($0.key), "role": $0.value]) })
            raw["eligible_members"] = .array(TeamProjectFixture.actors.map { .object(["user_id": .string($0), "role": .string(TeamProjectFixture.teamRole($0)), "display_name": .string(TeamProjectFixture.name($0))]) })
        }
        return try TeamProjectManagementDetail(raw, account: account, origin: TeamMembershipFixture.origin, team: TeamProjectFixture.projectTeam, project: id)
    }
    func review(_ id: String, action: TeamProjectCommand.Action) throws -> TeamProjectStructureReview {
        guard action.structural, let detail = try? detail(id), detail.access.canManageAccess, let archive = detail.access.archive else { throw TeamProjectCommand.invalid }
        var raw = context
        raw["id"] = .string(id); raw["operation"] = .string(action.rawValue); raw["revision"] = .number(detail.access.revision)
        raw["project_state_protocol"] = .number(1); raw["is_archived"] = .bool(archive.own); raw["ancestor_archived"] = .bool(archive.inherited)
        raw["tree_token"] = .string(try fence()); raw["affected_count"] = .number(Double(try branch(id, projects: read()["projects"]!.object).count))
        return try TeamProjectStructureReview(raw, account: account, origin: TeamMembershipFixture.origin, team: TeamProjectFixture.projectTeam, project: id, action: action)
    }
    private func branch(_ root: String, projects: [String: JSON]) throws -> [String] {
        var result: [String] = [], queue = [(root, 1)]
        while !queue.isEmpty {
            let (id, depth) = queue.removeFirst()
            guard result.count < 1000, depth <= 20, !result.contains(id), let row = projects[id]?.object, role(row) == "manager" else { throw TeamProjectCommand.invalid }
            result.append(id)
            queue += projects.keys.sorted().filter { projects[$0]?.object["parent_id"] == .string(id) }.map { ($0, depth + 1) }
        }
        return result
    }
    func hierarchy(_ id: String, parent: String?, action: TeamProjectCommand.Action) throws -> TeamProjectHierarchyReview {
        guard action.hierarchical, TeamMembershipFixture.setupEnabled, TeamProjectFixture.teamRole(account) != "guest" else { throw TeamProjectCommand.invalid }
        let projects = try read()["projects"]!.object, row = projects[id]?.object
        let ids: [String]
        if action == .move { ids = try branch(id, projects: projects); guard (row?["parent_id"] ?? .null) != (parent.map(JSON.string) ?? .null) else { throw TeamProjectCommand.invalid } }
        else { guard row == nil, parent != nil else { throw TeamProjectCommand.invalid }; ids = [id] }
        var parentRevision: JSON = .null, inherited = false
        if let parent {
            guard !ids.contains(parent), let target = projects[parent]?.object, role(target) == "manager" else { throw TeamProjectCommand.invalid }
            parentRevision = target["revision"]!; inherited = target["is_archived"] == .bool(true) || target["ancestor_archived"] == .bool(true)
        }
        var raw = context
        raw.merge(["project_hierarchy_protocol": .number(1), "id": .string(id), "operation": .string(action.rawValue), "revision": action.creation ? .null : row!["revision"]!, "parent_id": parent.map(JSON.string) ?? .null, "parent_revision": parentRevision, "tree_token": .string(try fence()), "affected_count": .number(Double(ids.count)), "is_archived": row?["is_archived"] ?? .bool(false), "destination_archived": .bool(inherited)]) { _, b in b }
        return try TeamProjectHierarchyReview(raw, account: account, origin: TeamMembershipFixture.origin, team: TeamProjectFixture.projectTeam, project: id, action: action)
    }
    func teamProjectCommand(_ command: TeamProjectCommand) async throws -> TeamProjectCommandReceipt {
        guard command.account == account, command.origin == TeamMembershipFixture.origin, command.team == TeamProjectFixture.projectTeam, command.retryable(at: Date()) else { throw TeamOrganizationCommandFailure(code: "42501") }
        var data = try read(), projects = data["projects"]!.object, receipts = data["receipts"]!.object
        var row = projects[command.project]?.object
        guard command.action.creation ? (TeamProjectFixture.teamRole(account) != "guest" && (row == nil || row.map({ role($0) == "manager" }) == true)) : row.map({ role($0) == "manager" }) == true else { throw TeamOrganizationCommandFailure(code: "42501") }
        let encoded = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(command))
        if let old = receipts[command.id]?.object { guard old["command"] == encoded else { throw TeamOrganizationCommandFailure(code: "PT409") }; return try command.confirmed(old["result"]!.object) }
        guard command.body["team_revision"] == .number(3), command.action.creation ? row == nil : command.body["revision"] == row?["revision"] else { throw TeamOrganizationCommandFailure(code: "PT409") }
        if !TeamMembershipFixture.setupEnabled {
            guard command.action == .archive || (command.action == .resetAccess && { () -> Bool in
                guard let user = command.body["user_id"]?.text, let grant = row?["grants"]?.object[user], row?["visibility"] == .string("private") || TeamProjectFixture.teamRole(user) == "guest" || grant == .string("manager") else { return false }; return true
            }()) else { throw TeamOrganizationCommandFailure(code: "PT503") }
        }
        var revision = Double(row?["revision"]?.integer ?? 0)
        var affected = [command.project]
        switch command.action {
        case .move, .createSubproject:
            let parent = try TeamProjectValue.optionalID(command.body["parent_id"])
            let reviewed = try hierarchy(command.project, parent: parent, action: command.action)
            guard reviewed.commandFields.allSatisfy({ command.body[$0.key] == $0.value }) else { throw TeamOrganizationCommandFailure(code: "PT409") }
            if command.action == .createSubproject {
                guard command.body["folder_id"] == .null || command.body["folder_id"] == .string(TeamProjectFixture.folder) else { throw TeamProjectCommand.invalid }
                row = ["id": .string(command.project), "team_id": .string(command.team), "name": command.body["name"]!, "visibility": command.body["visibility"]!, "folder_id": command.body["folder_id"]!, "creator_id": .string(account), "grants": .object([account: .string("manager")]), "is_archived": .bool(false)]
            } else { affected = try branch(command.project, projects: projects) }
            row?["parent_id"] = command.body["parent_id"]; row?["ancestor_archived"] = .bool(reviewed.destinationArchived)
        case .create: row = ["id": .string(command.project), "team_id": .string(command.team), "name": command.body["name"]!, "grants": .object([account: .string("manager")])]; fallthrough
        case .settings:
            if command.body["folder_id"] != .null && command.body["folder_id"] != .string(TeamProjectFixture.folder) { throw TeamOrganizationCommandFailure(code: "22023") }
            row?["visibility"] = command.body["visibility"]; row?["folder_id"] = command.body["folder_id"]
        case .rename: row?["name"] = command.body["name"]
        case .archive, .unarchive:
            let reviewed = try review(command.project, action: command.action)
            guard command.body["tree_token"] == .string(reviewed.token), command.body["affected_count"] == .number(Double(reviewed.count)) else { throw TeamOrganizationCommandFailure(code: "PT409") }
            row?["is_archived"] = .bool(command.action == .archive)
        case .setAccess, .resetAccess:
            let user = command.body["user_id"]!.text
            guard TeamProjectFixture.actors.contains(user), !["owner", "admin"].contains(TeamProjectFixture.teamRole(user)) else { throw TeamOrganizationCommandFailure(code: "42501") }
            var grants = row!["grants"]!.object
            if command.action == .resetAccess { guard grants.removeValue(forKey: user) != nil else { throw TeamOrganizationCommandFailure(code: "PT404") } }
            else { guard !(TeamProjectFixture.teamRole(user) == "guest" && command.body["role"] == .string("manager")) else { throw TeamOrganizationCommandFailure(code: "22023") }; grants[user] = command.body["role"] }
            row?["grants"] = .object(grants)
        }
        if command.action.structural { affected = try branch(command.project, projects: projects) }
        revision += 1; row?["revision"] = .number(revision); projects[command.project] = .object(row!)
        if command.action.hierarchical || command.action.structural {
            for id in affected where id != command.project {
                var child = projects[id]!.object
                let parent = projects[child["parent_id"]!.text]!.object
                child["ancestor_archived"] = .bool(parent["is_archived"] == .bool(true) || parent["ancestor_archived"] == .bool(true))
                child["revision"] = .number(Double(child["revision"]!.integer + 1)); projects[id] = .object(child)
            }
        }
        var result: [String: JSON] = ["protocol": .number(1), "account": .string(account), "team_id": .string(command.team), "id": .string(command.project), "request_id": .string(command.id), "team_revision": .number(3), "revision": .number(revision)]
        if command.action.structural { result["project_state_protocol"] = .number(1); result["is_archived"] = .bool(command.action == .archive); result["ancestor_archived"] = row?["ancestor_archived"] ?? .bool(false); result["affected_count"] = command.body["affected_count"] }
        if command.action.hierarchical { result["project_hierarchy_protocol"] = .number(1); result["parent_id"] = command.body["parent_id"]; result["affected_count"] = command.body["affected_count"]; result["is_archived"] = row?["is_archived"] ?? .bool(false); result["ancestor_archived"] = row?["ancestor_archived"] ?? .bool(false) }
        receipts[command.id] = .object(["command": encoded, "result": .object(result)])
        data["projects"] = .object(projects); data["receipts"] = .object(receipts); data["history"] = .array(data["history"]!.list + [.object(["action": .string(command.action.rawValue), "request_id": .string(command.id), "account": .string(account)])]); try write(data)
        if command.action == .settings, data["lost"] == .bool(false), ProcessInfo.processInfo.arguments.contains("--team-project-lose-settings-reply") { data["lost"] = .bool(true); try write(data); throw URLError(.networkConnectionLost) }
        if command.action == .archive, data["archive_lost"] != .bool(true), ProcessInfo.processInfo.arguments.contains("--team-project-lose-archive-reply") { data["archive_lost"] = .bool(true); try write(data); throw URLError(.networkConnectionLost) }
        if command.action.hierarchical, data[command.action.rawValue + "_lost"] != .bool(true), ProcessInfo.processInfo.arguments.contains("--team-project-lose-hierarchy-reply") { data[command.action.rawValue + "_lost"] = .bool(true); try write(data); throw URLError(.networkConnectionLost) }
        return try command.confirmed(result)
    }
}
#endif
