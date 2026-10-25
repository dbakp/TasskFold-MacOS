import SwiftUI

/// Recovery is account-bound and remains reachable when a team/rollout disappears.
struct SavedProjectTransferLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var showing = false
    @State private var reload = UUID()
    private var lifecycle: String { "\(store.userID)|\(store.workspaceGeneration)|\(store.backend.reminderSessionIncarnation)|\(phase == .active)|\(reload)" }
    var body: some View {
        // Keep the entry mounted so its private-recovery task can run after
        // launch, including when ordinary team navigation is unavailable.
        Group {
            if store.projectTransferRecoveryAvailable {
                Section { Button(visible ? "Saved project transfer" : "Project transfers", systemImage: "tray.and.arrow.up") { showing = true }.accessibilityIdentifier("savedProjectTransfer") }
            }
        }
        .task(id: lifecycle) {
            visible = false
            guard phase == .active, store.projectTransferRecoveryAvailable, let origin = try? store.backend.accountRemovalOrigin else { return }
            let account = store.userID, captured = lifecycle
            do { let value = try await store.projectAdoptionVault.pending(account: account, origin: origin); guard captured == lifecycle else { return }; visible = value != nil }
            catch { guard captured == lifecycle else { return }; visible = true }
        }
        .sheet(isPresented: $showing, onDismiss: { reload = UUID() }) { TeamProjectAdoptionView() }
    }
}

struct TeamProjectAdoptionView: View {
    var team: TeamOrganizationDetail?
    var destinations: [TeamProjectAccess] = []
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var model: TeamProjectAdoptionModel?
    @State private var loaded: String?
    @State private var selected: Set<String> = []
    @State private var visibility: TeamProjectVisibility = .private
    @State private var folder = ""
    @State private var parent = ""
    @State private var inspection: TeamProjectAdoptionInspection?
    @State private var choices: [String: TeamProjectAdoptionDecision.Choice] = [:]
    @State private var review: TeamProjectAdoptionReview?
    @State private var stamp: String?
    @State private var epoch = UUID()
    @State private var preparing = false
    @State private var message: String?
    @State private var clearing: TeamProjectAdoptionCommand?
    @AccessibilityFocusState(for: .voiceOver) private var resultFocused: Bool
    @State private var accepted: TeamProjectAdoptionReceipt?
    @State private var needsRefresh = false
    private var lifecycle: String { "\(store.userID)|\(store.workspaceGeneration)|\(store.backend.reminderSessionIncarnation)|\((try? store.backend.accountRemovalOrigin) ?? "")" }
    private var current: Bool { loaded == lifecycle && store.projectTransferRecoveryAvailable && phase == .active }
    private var reviewCurrent: Bool {
        guard current, let i = inspection, let stamp else { return false }
        return store.projectTransferAuthorStamp(i.scope, projects: i.projects.map(\.id)) == stamp
    }
    var body: some View {
        NavigationStack {
            List {
                if current, let model {
                    if let accepted { success(accepted) }
                    else if !model.recoveryLoaded {
                        Section {
                            Label("Check saved transfers first", systemImage: "tray.and.arrow.up")
                            Text("This device’s private recovery must be read before starting another transfer. Any saved request is kept.").foregroundStyle(.secondary)
                            Button("Check saved transfer") { Task { await model.load() } }.disabled(model.busy)
                        }
                    }
                    else if let pending = model.pending { recovery(pending, model: model) }
                    else if let i = inspection {
                        if reviewCurrent {
                            header(i.teamName)
                            contents(i)
                            if let review { finalReview(review) }
                            else { decisions(i) }
                        } else {
                            Section {
                                Label("Refresh this review", systemImage: "arrow.clockwise").font(.headline)
                                Text("Saved work, open editors or project access changed. Finish any edits, then review the current projects again.").foregroundStyle(.secondary)
                                Button("Choose projects again") { resetReview() }
                            }
                        }
                    } else if let team, team.account == store.userID, team.origin == (try? store.backend.accountRemovalOrigin), team.team.role != .guest, !team.team.archived, store.projectTransferAuthoringAvailable {
                        header(team.team.name)
                        sourceChoices
                        Section("Team location") {
                            Picker("Who can see these projects", selection: $visibility) { Text("Private").tag(TeamProjectVisibility.private); Text("Team-visible").tag(TeamProjectVisibility.team) }
                            Text(visibility == .private ? "Only project grants and team administrators provide access." : "Team members have editor access unless a project grant overrides it. Guests need an explicit grant.").font(.footnote).foregroundStyle(.secondary)
                            Picker("Folder", selection: $folder) { Text("No folder").tag(""); ForEach(team.folders, id: \.id) { Text($0.name).tag($0.id) } }
                            Picker("Parent project", selection: $parent) { Text("Team level").tag(""); ForEach(destinations.filter { $0.role == .manager }, id: \.id) { Text($0.name ?? "Project \($0.id.suffix(8))").tag($0.id) } }
                        }
                        Section {
                            Button("Review contents and access", systemImage: "person.2.badge.gearshape") { Task { await inspect() } }.disabled(selected.isEmpty || preparing).accessibilityIdentifier("inspectProjectTransfer")
                            Text("Save or discard queued work and close task editors for these projects before continuing.").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Section { ContentUnavailableView("No saved transfer", systemImage: "tray", description: Text("Transfers you need to confirm appear here. Start a new transfer from a team’s project list.")) }
                    }
                    if let message = model.message { Section { Text(message).foregroundStyle(.secondary) } }
                } else { Section { ContentUnavailableView("Transfer unavailable", systemImage: "person.crop.circle", description: Text("Return to the original synced account to continue.")) } }
                if let message, current { Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
                #if DEBUG
                if ProjectAdoptionNativeFixture.enabled { Section("Isolated test control") { Button("Change saved source") { store.changeProjectAdoptionFixtureSource() }.accessibilityIdentifier("changeProjectTransferSource") } }
                #endif
                if preparing || model?.busy == true { Section { ProgressView(model?.busy == true ? "Confirming transfer…" : "Reviewing projects…") } }
            }
            .accessibilityIdentifier("projectTransferForm")
            .navigationTitle("Bring projects to a team")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 560, idealWidth: 660, minHeight: 540)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(accepted != nil ? "Done" : model?.pending != nil ? "Close" : "Cancel") { dismiss() }.disabled(preparing || model?.busy == true).accessibilityIdentifier("closeProjectTransfer") } }
            .interactiveDismissDisabled(preparing || model?.busy == true)
            .task(id: lifecycle) { await start() }
            .onChange(of: phase) { _, value in if value != .active { epoch = UUID(); preparing = false; inspection = nil; review = nil; choices = [:]; stamp = nil } else if model?.receipt != nil { Task { await received() } } }
            .onDisappear { epoch = UUID(); model?.close() }
            .confirmationDialog("Clear this saved transfer?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
                if let c = clearing { Button("Clear saved request", role: .destructive) { Task { await model?.clear(c) } } }
            } message: { Text("Check the latest projects first. This removes the retry from this device; it does not undo a transfer that may already have succeeded.") }
        }
    }
    private func header(_ name: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "folder.badge.person.crop").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Make room for shared work").font(.title2.weight(.semibold))
                Text("Bring a personal project branch into \(name), with its history and details intact.").foregroundStyle(.secondary)
                Label("Review first. Transfer together.", systemImage: "checkmark.shield").font(.callout)
            }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }.listRowBackground(Color.accentColor.opacity(0.07))
    }
    private var sourceChoices: some View {
        Section {
            ForEach(store.personalTransferProjects, id: \.id) { project in
                Button {
                    if !selected.insert(project.id).inserted { selected.remove(project.id) }
                } label: {
                    HStack { Image(systemName: selected.contains(project.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(project.id) ? Color.accentColor : Color.secondary); Text(project.string("name")).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true); Spacer(); if project["is_archived"] == .bool(true) { Image(systemName: "archivebox").foregroundStyle(.secondary) } }
                }.disabled(preparing || (!selected.contains(project.id) && selected.count >= 100)).accessibilityLabel(project.string("name")).accessibilityValue(selected.contains(project.id) ? "Selected" : "Not selected").accessibilityIdentifier("transferProject-\(project.id)")
            }
            if store.personalTransferProjects.isEmpty { Text("No owned personal projects are available.").foregroundStyle(.secondary) }
        } header: { Text("Choose project branches") } footer: { Text("Every descendant is included, along with archived projects and completed work. Select separate branches; the review lists everything that moves.") }
    }
    private func contents(_ i: TeamProjectAdoptionInspection) -> some View {
        Section("What comes with you") {
            LabeledContent("Projects", value: String(i.projects.count))
            LabeledContent("Tasks, including completed", value: String(i.contents["counts"]?.object["tasks"]?.integer ?? 0))
            LabeledContent("Discussion comments", value: String(i.contents["counts"]?.object["task_comments"]?.integer ?? 0))
            LabeledContent("Attachments, including subtasks", value: String(i.contents["attachments"]?.integer ?? 0))
            DisclosureGroup("All affected projects") {
                ForEach(i.projects) { p in
                    VStack(alignment: .leading, spacing: 3) { Text(p.name ?? "Project \(p.id.suffix(8))").font(.headline); Text(p.depth == 1 ? "Selected branch" : "Subproject · Level \(p.depth)").font(.caption).foregroundStyle(.secondary); if p.archived { Label("Stays archived", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) } else if i.inheritsArchiveAfter(p) { Label("Archived with parent", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) } else if p.inherited { Text("Inherited archive will clear at this destination").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }.padding(.vertical, 4)
                }
            }
            if i.destinationArchived { Label("The destination is archived. These projects will inherit that state.", systemImage: "archivebox").foregroundStyle(.secondary) }
            Text("Notes, dates, checklists and saved history stay with their task. External links keep their provider’s access rules.").font(.footnote).foregroundStyle(.secondary)
        }.accessibilityIdentifier("projectTransferContents")
    }
    private func decisions(_ i: TeamProjectAdoptionInspection) -> some View {
        Group {
            Section("Personal collaborators") {
                ForEach(i.people) { person in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.email ?? "Collaborator \(person.user?.suffix(8) ?? "")").font(.headline)
                        Text(i.projects.first(where: { $0.id == person.project })?.name ?? "Selected project").font(.caption).foregroundStyle(.secondary)
                        Picker("Resulting personal grant", selection: Binding<String>(get: { choices[person.decisionID!]?.rawValue ?? "" }, set: { choices[person.decisionID!] = TeamProjectAdoptionDecision.Choice(rawValue: $0) })) {
                            Text("Choose access…").tag("")
                            if person.eligible { Text("Keep as editor").tag("editor"); Text("Keep as viewer").tag("viewer") }
                            Text("Retire personal access").tag("retire")
                        }.accessibilityIdentifier("transferAccess-\(person.project)-\(person.user!)")
                        if !person.eligible { Text("Not currently an eligible member of this team. This transfer will not invite them.").font(.footnote).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                if i.people.isEmpty { Text("No accepted personal collaborators need a decision.").foregroundStyle(.secondary) }
                Text("Retiring a personal grant does not remove access supplied by team visibility or an administrator role. The next step shows the effective access.").font(.footnote).foregroundStyle(.secondary)
                Text("All \(i.collaborators.count) personal invitation records will close, including pending invitations. No team membership or invitation is created.").font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("Review the transfer") { Task { await prepareReview(i) } }.disabled(preparing || choices.count != i.people.count).accessibilityIdentifier("reviewProjectTransfer"); Button("Back to projects") { resetReview() } }
        }
    }
    private func finalReview(_ r: TeamProjectAdoptionReview) -> some View {
        Group {
            Section("Reviewed destination") {
                LabeledContent("Team", value: r.inspection.teamName)
                LabeledContent("Visibility", value: r.inspection.scope.visibility == .private ? "Private" : "Team-visible")
                LabeledContent("Folder", value: r.inspection.scope.folder.flatMap { id in team?.folders.first(where: { $0.id == id })?.name } ?? (r.inspection.scope.folder == nil ? "No folder" : "Selected folder"))
                LabeledContent("Parent project", value: r.inspection.scope.parent.flatMap { id in destinations.first(where: { $0.id == id })?.name } ?? (r.inspection.scope.parent == nil ? "Team level" : "Selected project"))
            }
            Section("Access after transfer") {
                ForEach(r.decisions) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.inspection.people.first(where: { $0.decisionID == d.id })?.email ?? "Collaborator \(d.user.suffix(8))").font(.headline)
                        Text("\(d.choice.title) · Effective access: \(r.effectiveRoles[d.id]?.title ?? "None")").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Assignments cleared", value: String(r.assignmentsCleared))
                LabeledContent("Personal invitations closed", value: String(r.invitationsClosed))
                Text("You become a manager of these projects. Team administrators retain management access.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if r.needsFileCustody { Label("Some files need a custody review before this branch can transfer.", systemImage: "paperclip.badge.ellipsis").foregroundStyle(.secondary) }
                if r.needsIntegrationPause { Label("Personal email or webhook connections need a pause or destination review first.", systemImage: "link.badge.plus").foregroundStyle(.secondary) }
                if !r.inspection.commitSupported && !r.needsFileCustody && !r.needsIntegrationPause { Text("Project transfers have not been enabled for this service yet.").foregroundStyle(.secondary) }
                Text("These projects will belong to the team. Returning them to personal ownership is a separate transfer; there is no automatic Undo.").font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Transfer \(r.inspection.projects.count == 1 ? "project" : "\(r.inspection.projects.count) projects") to team", systemImage: "folder.badge.arrow.forward") { Task { await confirm(r) } }.buttonStyle(.borderedProminent).disabled(preparing || model?.busy == true || !r.canCommit || r.expires <= Date()).accessibilityIdentifier("confirmProjectTransfer")
                Button("Back to access choices") { review = nil }
            }
        }
    }
    private func recovery(_ c: TeamProjectAdoptionCommand, model: TeamProjectAdoptionModel) -> some View {
        Section("Saved transfer") {
            Label("The result needs confirmation", systemImage: "tray.and.arrow.up").font(.headline)
            Text("\(c.projects.count) reviewed projects · \(c.scope.visibility == .private ? "Private" : "Team-visible")")
            Text("Retry sends the exact saved request, even if the review expired or team access changed. Task contents are refreshed separately.").font(.callout).foregroundStyle(.secondary)
            Button("Retry saved transfer") { Task { await model.retry(); await received() } }.disabled(model.busy).accessibilityIdentifier("retryProjectTransfer")
            if TeamOrganizationAvailability.enabled { NavigationLink("Check latest projects") { TeamProjectManagementView(teamID: c.scope.team) } }
            Button("Review clearing this request", role: .destructive) { clearing = c }.disabled(model.busy).accessibilityIdentifier("clearProjectTransfer")
        }
    }
    private func success(_ r: TeamProjectAdoptionReceipt) -> some View {
        Section {
            Label("Projects transferred", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.tint).accessibilityIdentifier("projectTransferSuccess").accessibilityFocused($resultFocused).onAppear { resultFocused = true }
            Text("The service confirmed all \(r.command.projects.count) projects. Their identities and saved history are preserved.")
            if needsRefresh { Text("The transfer is confirmed. Refresh the workspace to review current access and any preserved drafts.").foregroundStyle(.secondary); if store.accessRecoveryPending { AccessRecoveryBanner() }; Button("Refresh workspace") { Task { preparing = true; needsRefresh = !(await store.refreshAfterProjectTransfer(r)); preparing = false } }.disabled(preparing) }
            else { Text("Your current accessible projects have been refreshed.").foregroundStyle(.secondary) }
        }
    }
    private func resetReview() { epoch = UUID(); inspection = nil; review = nil; stamp = nil; choices = [:]; message = nil }
    private func start() async {
        model?.close(); resetReview(); selected = []; accepted = nil; preparing = false
        guard store.projectTransferRecoveryAvailable, let origin = try? store.backend.accountRemovalOrigin else { loaded = nil; model = nil; return }
        let captured = lifecycle, account = store.userID, workspace = WorkspaceBinding(account: account, generation: store.workspaceGeneration), session = store.backend.reminderSessionIncarnation
        let value = TeamProjectAdoptionModel(account: account, origin: origin, vault: store.projectAdoptionVault, service: store.backend, current: { store.projectTransferContext(account: account, origin: origin, workspace: workspace, session: session) })
        model = value; loaded = captured; await value.load()
    }
    private func inspect() async {
        guard current, !preparing, let team, team.account == store.userID, team.origin == (try? store.backend.accountRemovalOrigin), let origin = try? store.backend.accountRemovalOrigin else { return }
        do {
            let scope = try TeamProjectAdoptionScope(account: store.userID, origin: origin, team: team.team.id, roots: Array(selected), visibility: visibility, folder: folder.isEmpty ? nil : folder, parent: parent.isEmpty ? nil : parent)
            guard let before = store.projectTransferAuthorStamp(scope, projects: scope.roots) else { throw TeamProjectAdoptionValue.invalid }
            let id = UUID(); epoch = id; preparing = true; message = nil; defer { if epoch == id { preparing = false } }
            let i = try await store.backend.inspectProjectAdoption(scope)
            guard current, epoch == id, before == store.projectTransferAuthorStamp(scope, projects: i.projects.map(\.id)) else { throw TeamProjectAdoptionValue.invalid }
            inspection = i; stamp = before; choices = [:]; review = nil
        } catch { guard current else { return }; message = "The contents couldn’t be reviewed. Finish any pending sync or task edits, then refresh the team and try again." }
    }
    private func prepareReview(_ i: TeamProjectAdoptionInspection) async {
        guard reviewCurrent, !preparing else { return }
        let id = UUID(); epoch = id; preparing = true; message = nil; defer { if epoch == id { preparing = false } }
        do {
            let d = try i.people.map { person -> TeamProjectAdoptionDecision in guard let choice = choices[person.decisionID!], let user = person.user else { throw TeamProjectAdoptionValue.invalid }; return try TeamProjectAdoptionDecision(project: person.project, user: user, choice: choice) }
            let value = try await store.backend.reviewProjectAdoption(i, decisions: d)
            guard reviewCurrent, epoch == id else { throw TeamProjectAdoptionValue.invalid }; review = value
        } catch { guard current, epoch == id else { return }; message = "The saved contents or access may have changed. Start a fresh review before transferring." }
    }
    private func confirm(_ r: TeamProjectAdoptionReview) async {
        guard reviewCurrent, let model else { message = "Finish any edits and refresh this review before transferring."; return }
        do { let command = try TeamProjectAdoptionCommand(review: r); await model.send(command, canAuthor: { reviewCurrent }); await received() }
        catch { message = "This review expired or changed. Review the transfer again." }
    }
    private func received() async {
        guard current, let result = model?.receipt else { return }
        accepted = result; inspection = nil; review = nil; choices = [:]; preparing = true
        needsRefresh = !(await store.refreshAfterProjectTransfer(result)); preparing = false
    }
}
