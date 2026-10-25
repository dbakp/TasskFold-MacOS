import SwiftUI

struct TeamWorkflowRunRequest: Identifiable {
    let id = UUID()
    let source: TeamWorkflowRunPlan.Source
}

struct SavedTeamWorkflowRequestLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var showing = false
    @State private var reload = UUID()
    private var lifecycle: String { "\(store.userID)|\(store.workspaceGeneration)|\(store.backend.reminderSessionIncarnation)|\(phase == .active)|\(reload)" }
    var body: some View {
        // Keep recovery mounted before its first asynchronous disk check.
        Group { if store.teamTemplateRecoveryAvailable {
            Section { Button(visible ? "Saved workflow request" : "Shared workflow requests", systemImage: "tray.and.arrow.up") { showing = true }.accessibilityIdentifier("savedTeamWorkflowRequest") }
        } }
        .task(id: lifecycle) {
            visible = false
            guard phase == .active, store.teamTemplateRecoveryAvailable, let origin = try? store.backend.accountRemovalOrigin else { return }
            let account = store.userID, captured = lifecycle
            do {
                let saved = try await store.teamWorkflowRunVault(account: account, origin: origin).pending(account: account, origin: origin)
                guard captured == lifecycle else { return }; visible = saved != nil
            } catch { guard captured == lifecycle else { return }; visible = true }
        }
        .sheet(isPresented: $showing, onDismiss: { reload = UUID() }) { WorkflowShell(title: "Saved workflow request") { TeamWorkflowRunView() } }
    }
}

private struct TeamWorkflowPrepared: Identifiable {
    var id: UUID { plan.run }
    let plan: TeamWorkflowRunPlan
    let command: TeamWorkflowRunCommand
}

struct TeamWorkflowRunView: View {
    var source: TeamWorkflowRunPlan.Source? = nil
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var opening: WorkspaceBinding?
    @State private var session: UUID?
    @State private var origin: String?
    @State private var loaded: String?
    @State private var catalog: TeamWorkflowDestinations?
    @State private var commands: TeamWorkflowRunModel?
    @State private var currentSource: TeamWorkflowRunPlan.Source?
    @State private var changedSource: TeamWorkflowRunPlan.Source?
    @State private var sourceReadable = false
    @State private var team = ""
    @State private var project = ""
    @State private var folder = ""
    @State private var parent = ""
    @State private var name = ""
    @State private var visibility = TeamProjectVisibility.team
    @State private var dated = false
    @State private var date = Date()
    @State private var prepared: TeamWorkflowPrepared?
    @State private var accepted = false
    @State private var working = false
    @State private var message: String?
    @State private var retrying: TeamWorkflowRunCommand?
    @State private var stopping: TeamWorkflowRunCommand?
    @AccessibilityFocusState private var statusFocused: Bool
    private var lifecycle: String { "\(store.userID)|\(store.workspaceGeneration)|\(store.backend.reminderSessionIncarnation)|\(phase == .active)" }
    private var context: String? {
        guard store.teamTemplateRecoveryAvailable, let opening, let session, let origin, opening.matches(account: store.userID, generation: store.workspaceGeneration),
              session == store.backend.reminderSessionIncarnation, origin == (try? store.backend.accountRemovalOrigin) else { return nil }
        return "\(opening.account)|\(opening.generation)|\(session)|\(origin)"
    }
    private var visible: Bool { phase == .active && context != nil && context == loaded }
    private var disabled: Bool { working || commands?.busy == true || commands?.pending != nil || commands?.recoveryLoaded != true }
    private var definition: WorkflowTemplate? { currentSource.flatMap { try? WorkflowTemplate(document: $0.document) } }
    private var eligible: [TeamProjectAccess] { (catalog?.projects ?? []).filter(TeamWorkflowDestinations.editable) }
    private var nameIssue: String? {
        guard definition?.kind == .project else { return nil }
        return (try? TeamOrganizationValue.name(.string(name.trimmingCharacters(in: .whitespacesAndNewlines)))) == nil ? "Use a project name of 1–100 characters without line breaks." : nil
    }
    var body: some View {
        Group {
            if visible {
                Form {
                    status
                    recovery
                    if commands?.pending == nil, commands?.recoveryLoaded == true, commands?.receipt == nil, source != nil {
                        if !store.teamWorkflowCreationAvailable { ContentUnavailableView("Refresh your workspace", systemImage: "lock.shield", description: Text("Finish sync and verify shared editing access before creating this workflow.")) }
                        else if working || catalog?.loading == true { ProgressView("Verifying workflow…") }
                        else if let prepared { review(prepared) }
                        else { setup }
                    } else if source == nil, commands?.pending == nil, commands?.recoveryLoaded == true, commands?.receipt == nil {
                        ContentUnavailableView("No saved workflow request", systemImage: "checkmark.circle", description: Text("Confirmed workflows can be found in their destination workspace."))
                    }
                }.formStyle(.grouped).accessibilityIdentifier("sharedWorkflowForm")
            } else { ContentUnavailableView("Shared workflow", systemImage: "lock.shield", description: Text("Return to the account and workspace where you opened this review.")) }
        }
        .navigationTitle(source == nil ? "Saved workflow request" : "Use in shared workspace")
        .privacySensitive()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth: 580, idealWidth: 720, minHeight: 520)
        #endif
        .task(id: lifecycle) { await start() }
        .onDisappear { commands?.close(); catalog?.invalidate() }
        .onChange(of: team) { _, _ in
            project = ""; folder = ""; parent = ""; prepared = nil; accepted = false
            guard visible else { return }; Task { await refresh() }
        }
        .onChange(of: store.workspaceReadRevision) { _, _ in
            guard visible, !working, commands?.busy != true else { return }
            prepared = nil; sourceReadable = false; Task { await refresh() }
        }
        .onChange(of: commands?.receipt) { _, receipt in
            guard receipt != nil, visible else { return }; prepared = nil; accepted = false
            Task { await store.sync() }
        }
        .confirmationDialog("Retry the original workflow?", isPresented: Binding(get: { retrying != nil }, set: { if !$0 { retrying = nil } })) {
            if let request = retrying { Button("Confirm original request") { Task { await commands?.retry(request) } }.accessibilityIdentifier("confirmSharedWorkflowRetry") }
        } message: { Text("Confirm the exact saved request with its original destination, dates and task identities. No new workflow will be substituted.") }
        .confirmationDialog("Stop retrying this workflow?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            if let request = stopping { Button("Stop retrying", role: .destructive) { Task { await commands?.stopRetrying(request) } } }
        } message: { Text("This removes the saved request only on this device. A workflow already created in the shared workspace stays there. Check that workspace before starting another run.") }
    }
    @ViewBuilder private var status: some View {
        if let message { Section { Text(message).accessibilityFocused($statusFocused).accessibilityIdentifier("sharedWorkflowMessage") } }
        if let model = commands {
            if let message = model.message { Section { Text(message).accessibilityIdentifier("sharedWorkflowRecoveryMessage") } }
            if let success = model.success { Section { Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("sharedWorkflowSuccess") } }
            if !model.recoveryLoaded, !model.busy { Section { Button("Check saved requests") { Task { await model.load() } } } }
        }
    }
    @ViewBuilder private var recovery: some View {
        if let model = commands, let request = model.pending {
            Section("Saved workflow") {
                Text("The original request is saved securely on this device. Its result has not been confirmed here.")
                Text("Retry checks the original request; stopping retry does not undo work already created.").font(.caption).foregroundStyle(.secondary)
                Button("Retry original request") { retrying = request }.accessibilityIdentifier("retrySharedWorkflow")
                Button("Stop retrying…", role: .destructive) { stopping = request }.accessibilityIdentifier("stopSharedWorkflow")
            }.disabled(model.busy)
        }
    }
    @ViewBuilder private var setup: some View {
        if let changedSource {
            Section { Text("The source definition or access changed. Review the latest definition before creating a workflow.")
                Button("Review latest definition") { currentSource = changedSource; self.changedSource = nil; sourceReadable = true; message = nil }.accessibilityIdentifier("reviewLatestSharedWorkflowSource") }
        } else if !sourceReadable {
            Section { Text("Refresh to verify the template and destinations."); Button("Refresh") { Task { await refresh() } }.accessibilityIdentifier("refreshSharedWorkflow") }
        } else if let definition {
            Section {
                Label(sourceName(currentSource!), systemImage: "square.stack.3d.up").font(.title2.bold())
                Text("Start a fresh workflow in a shared workspace. The reusable template and existing work stay unchanged.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Destination") {
                Picker("Team", selection: $team) {
                    Text("Choose a team").tag("")
                    ForEach(catalog?.overview?.teams.filter { !$0.archived && (definition.kind != .project || $0.role != .guest) } ?? []) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("sharedWorkflowTeam")
                if let organization = catalog?.organization, organization.team.id == team {
                    if definition.kind == .project {
                        TextField("New project name", text: $name).accessibilityIdentifier("sharedWorkflowName").accessibilityHint(nameIssue ?? "Name for the new shared project.")
                        if let nameIssue { Text(nameIssue).font(.caption).foregroundStyle(.secondary) }
                        Picker("Who can access it", selection: $visibility) { Text("Team members").tag(TeamProjectVisibility.team); Text("Private project").tag(TeamProjectVisibility.private) }
                        Text(visibility == .team ? "Team members receive their team permissions. Guests require explicit project access." : "Access starts with you and team managers. Inviting or granting access is a separate action.").font(.caption).foregroundStyle(.secondary)
                        Picker("Folder", selection: $folder) { Text("No folder").tag(""); ForEach(organization.folders) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("sharedWorkflowFolder")
                        Picker("Inside project", selection: $parent) { Text("Top level").tag(""); ForEach(eligible.filter { $0.role == .manager }, id: \.id) { Text($0.name ?? "Available project").tag($0.id) } }.accessibilityIdentifier("sharedWorkflowParent")
                    } else {
                        Picker("Project", selection: $project) { Text("Choose a project").tag(""); ForEach(eligible, id: \.id) { Text($0.name ?? "Available project").tag($0.id) } }.accessibilityIdentifier("sharedWorkflowProject")
                        if eligible.isEmpty { Text("No active projects are currently available for editing.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Toggle("Schedule from a start date", isOn: $dated)
                    if dated { DatePicker("Start date", selection: $date, displayedComponents: .date).accessibilityIdentifier("sharedWorkflowStart") }
                    Text(dated ? "Planned days and deadlines keep their spacing from this date. Undated tasks stay undated." : "New tasks start without planned days or deadlines.").font(.caption).foregroundStyle(.secondary)
                    Button("Review workflow") { Task { await prepare() } }.buttonStyle(.borderedProminent).disabled(disabled || nameIssue != nil || (definition.kind != .project && project.isEmpty)).accessibilityIdentifier("reviewSharedWorkflow")
                }
            }.disabled(disabled)
            Section("Template contents") { TemplateDefinitionPreview(document: definition.document, scope: "shared-run-source") }
        } else {
            ContentUnavailableView("Update Taskfold to use this template", systemImage: "square.stack.3d.up", description: Text("The latest definition uses a format this app cannot safely create. Its contents are preserved."))
        }
        if let message = catalog?.message { Section { Text(message); Button("Refresh destinations") { Task { await refresh() } } } }
    }
    @ViewBuilder private func review(_ value: TeamWorkflowPrepared) -> some View {
        Section("Create in this workspace") {
            Text(value.plan.team.name).font(.headline)
            switch value.plan.destination {
            case .project(let access): Text(access.name ?? "Selected project"); Text(access.visibility == .team ? "Audience: people with access to this team project" : "Audience: people granted access and team managers")
            case .newProject(let visibility, let folder, let parent):
                Text(visibility == .team ? "Audience: team members; guests need explicit access" : "Audience: you and team managers initially")
                if let parent { Text("Inside " + (parent.name ?? "selected parent")) }
                if let folder, let title = catalog?.organization?.folders.first(where: { $0.id == folder })?.name { Text("Folder: " + title) }
            }
            Text(contentsSummary(value.plan)).font(.subheadline).foregroundStyle(.secondary)
            Text("New tasks are unassigned and incomplete. Discussions, files and completion history are excluded. Existing tasks and list order are preserved.").font(.caption).foregroundStyle(.secondary)
        }
        TeamWorkflowContents(plan: value.plan)
        Section {
            Toggle("I reviewed these contents and who can access them", isOn: $accepted).accessibilityIdentifier("acknowledgeSharedWorkflow")
            Button("Create workflow") { Task { await create(value) } }.buttonStyle(.borderedProminent).disabled(!accepted || disabled).accessibilityIdentifier("createSharedWorkflow")
            Button("Back to destination") { prepared = nil; accepted = false }.disabled(disabled).accessibilityIdentifier("backSharedWorkflow")
            Text("Create sends this complete workflow together. A lost reply keeps the original request for safe retry.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func contentsSummary(_ plan: TeamWorkflowRunPlan) -> String {
        var checklist = 0
        for row in plan.tasks { checklist += (try? TeamChecklist.indexed(row["subtasks"]).count) ?? 0 }
        let groups: [(Int, String)] = [(plan.projects.count, "project"), (plan.sections.count, "section"), (plan.tasks.count, "task"), (checklist, "checklist item")]
        var parts: [String] = []
        for (count, noun) in groups where count > 0 { parts.append(String(count) + " " + noun + (count == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
    }
    private func sourceName(_ value: TeamWorkflowRunPlan.Source) -> String { switch value { case .personal(let row): row.name; case .shared(let detail): detail.metadata.name } }
    private func normalized(_ value: TeamWorkflowRunPlan.Source) -> TeamWorkflowRunPlan.Source {
        switch value { case .personal(let row): .personal(Record(row.fields.filter { ["id", "user_id", "name", "document"].contains($0.key) })); case .shared: value }
    }
    @MainActor private func readSource(_ value: TeamWorkflowRunPlan.Source) async throws -> TeamWorkflowRunPlan.Source {
        guard visible, let opening, let origin else { throw CancellationError() }
        let result: TeamWorkflowRunPlan.Source
        switch value {
        case .personal(let row): result = try await store.backend.workflowPersonalSource(id: row.id, account: opening.account, origin: origin)
        case .shared(let detail): result = .shared(try await store.backend.teamTemplateDetail(team: detail.scope.team, template: detail.metadata.id, account: opening.account, origin: origin))
        }
        guard visible, !Task.isCancelled else { throw CancellationError() }; return result
    }
    @MainActor private func start() async {
        commands?.close(); catalog?.invalidate(); prepared = nil; loaded = nil; sourceReadable = false
        if opening == nil { opening = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); session = store.backend.reminderSessionIncarnation; origin = try? store.backend.accountRemovalOrigin }
        guard phase == .active, let captured = context, let opening, let origin else { return }
        let backend = store.backend
        do {
            let model = TeamWorkflowRunModel(account: opening.account, origin: origin, vault: try store.teamWorkflowRunVault(account: opening.account, origin: origin), service: backend, current: { context == captured && phase == .active })
            commands = model
            catalog = TeamWorkflowDestinations(account: opening.account, origin: origin, current: { context == captured && phase == .active && store.teamWorkflowCreationAvailable }, fence: { try await backend.workspaceBoundary(account: opening.account).raw["token"]!.text }, overview: { try await backend.teamOrganizationOverview(account: opening.account, origin: origin) }, team: { try await backend.teamOrganizationDetail(team: $0, account: opening.account, origin: origin) }, page: { try await backend.teamProjectPage(team: $0, account: opening.account, origin: origin, after: $1) })
            loaded = captured; await model.load()
            guard context == captured, !Task.isCancelled else { return }
            if name.isEmpty, let source { name = sourceName(source) }
            await refresh()
        } catch { message = "Saved workflow requests couldn’t be opened. Try again before creating a new run." }
    }
    @MainActor private func refresh() async {
        guard visible, store.teamWorkflowCreationAvailable, !working, commands?.busy != true, let seed = currentSource ?? source.map(normalized) else { return }
        working = true; sourceReadable = false; message = nil; defer { working = false }
        do {
            let latest = try await readSource(seed)
            await catalog?.load(team: team.isEmpty ? nil : team)
            guard visible, !Task.isCancelled, catalog?.overview != nil else { return }
            if latest != seed { changedSource = latest; currentSource = seed }
            else { currentSource = latest; sourceReadable = true }
        } catch { if visible { message = "The template couldn’t be verified. Refresh its access before continuing."; statusFocused = true } }
    }
    private func destination() throws -> TeamWorkflowRunPlan.Destination {
        guard let organization = catalog?.organization, organization.team.id == team else { throw TeamWorkflowRunCommand.invalid }
        if definition?.kind == .project {
            let parentAccess = parent.isEmpty ? nil : eligible.first { $0.id == parent && $0.role == .manager }
            guard parent.isEmpty || parentAccess != nil, folder.isEmpty || organization.folders.contains(where: { $0.id == folder }) else { throw TeamWorkflowRunCommand.invalid }
            return .newProject(visibility, folder: folder.isEmpty ? nil : folder, parent: parentAccess)
        }
        guard let access = eligible.first(where: { $0.id == project }) else { throw TeamWorkflowRunCommand.invalid }; return .project(access)
    }
    @MainActor private func prepare() async {
        guard visible, !disabled, let seed = currentSource, let opening, let session, let origin else { return }
        working = true; sourceReadable = false; message = nil; defer { working = false }
        do {
            let latest = try await readSource(seed); await catalog?.load(team: team)
            guard visible, latest == seed, let organization = catalog?.organization else { changedSource = latest; throw TeamWorkflowRunCommand.invalid }
            let plan = try TeamWorkflowRunPlan(source: latest, account: opening.account, origin: origin, team: organization.team, destination: destination(), name: name, start: dated ? date : nil, workspace: opening, session: session)
            let orders = try await store.backend.workflowBaseOrders(plan)
            guard visible, store.teamWorkflowCreationAvailable else { throw CancellationError() }
            let command = try TeamWorkflowRunCommand(plan: plan, baseOrders: orders)
            prepared = TeamWorkflowPrepared(plan: plan, command: command); accepted = false; sourceReadable = true
        } catch { if visible { message = "This workflow couldn’t be prepared. Review the source and destination, then try again."; statusFocused = true } }
    }
    @MainActor private func create(_ value: TeamWorkflowPrepared) async {
        guard visible, accepted, !disabled, prepared?.id == value.id, let model = commands else { return }
        working = true; sourceReadable = false; message = nil; defer { working = false }
        do {
            let latest = try await readSource(value.plan.source); await catalog?.load(team: value.plan.team.id)
            guard visible, let organization = catalog?.organization, let opening, let session else { throw CancellationError() }
            try value.plan.verify(source: latest, team: organization.team, destination: destination(), workspace: opening, session: session)
            let orders = try await store.backend.workflowBaseOrders(value.plan)
            guard try value.plan.requestBody(baseOrders: orders) == value.command.body, visible else { throw TeamWorkflowRunCommand.invalid }
            let revision = store.workspaceReadRevision
            await model.send(value.command, canAuthor: { visible && store.teamWorkflowCreationAvailable && prepared?.id == value.id && store.workspaceReadRevision == revision })
        } catch {
            guard visible else { return }; prepared = nil; accepted = false
            message = "The source, destination or list order changed. Nothing new was sent. Review the latest workflow before creating it."; statusFocused = true
        }
    }
}

private struct WorkflowContentRow: Identifiable { let id: String; let row: Record; let depth: Int; let project: String; let section: String? }
private struct TeamWorkflowContents: View {
    let plan: TeamWorkflowRunPlan
    private var rows: [WorkflowContentRow] {
        var result: [WorkflowContentRow] = []
        let sections = Dictionary(uniqueKeysWithValues: plan.sections.map { ($0.id, $0.name) })
        let projects = Dictionary(uniqueKeysWithValues: plan.projects.map { ($0.id, $0) })
        func add(_ row: Record, root: String, depth: Int, project: String, section: String?) {
            result.append(.init(id: root + ":" + row.id, row: row, depth: depth, project: project, section: section))
            for child in row["subtasks"].list { add(Record(child.object), root: root, depth: depth + 1, project: project, section: section) }
        }
        for row in plan.tasks { add(row, root: row.id, depth: 0, project: projectPath(row.string("project_id"), projects: projects), section: sections[row.string("section_id")]) }; return result
    }
    var body: some View {
        let projects = Dictionary(uniqueKeysWithValues: plan.projects.map { ($0.id, $0) })
        if !plan.projects.isEmpty { Section("New projects") {
            ForEach(plan.projects) { row in VStack(alignment: .leading, spacing: 4) {
                Label(row.name, systemImage: "folder").font(.headline)
                if !row.string("parent_id").isEmpty { Text("Inside " + projectPath(row.string("parent_id"), projects: projects)).font(.caption).foregroundStyle(.secondary) }
                if !row.string("description").isEmpty { Text(row.string("description")).textSelection(.enabled) }
            } }
        } }
        if !plan.sections.isEmpty { Section("New sections") { ForEach(plan.sections) { row in
            VStack(alignment: .leading, spacing: 4) {
                Label(row.name, systemImage: "rectangle.split.3x1")
                Text(projectPath(row.string("project_id"), projects: projects)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Project: " + projectPath(row.string("project_id"), projects: projects))
            }
        } } }
        Section("New tasks and checklist") {
            ForEach(rows) { item in VStack(alignment: .leading, spacing: 6) {
                Text(item.row.title).font(item.depth == 0 ? .headline : .body).accessibilityIdentifier("sharedWorkflowTask-" + item.row.id)
                if item.depth == 0 { Text(item.project + (item.section.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary) }
                if !item.row.string("description").isEmpty { Text(item.row.string("description")).textSelection(.enabled) }
                Text(details(item.row)).font(.caption).foregroundStyle(.secondary)
                if !item.row["labels"].list.isEmpty { Label(item.row["labels"].list.map(\.text).joined(separator: ", "), systemImage: "tag").font(.caption) }
                if item.row["is_recurring"].flag { Text(Recurrence.summary(Record(item.row["recurrence_pattern"].object))).font(.caption).foregroundStyle(.secondary) }
            }.padding(.leading, CGFloat(min(item.depth, 8)) * 10) }
        }
    }
    private func projectPath(_ id: String, projects: [String: Record]) -> String {
        var next = id, names: [String] = [], visited = Set<String>()
        while let row = projects[next], visited.insert(next).inserted {
            names.append(row.name); next = row.string("parent_id")
        }
        if case .newProject(_, _, let parent) = plan.destination, let parent, parent.id == next {
            names.append(parent.name ?? "Selected parent")
        }
        if !names.isEmpty { return names.reversed().joined(separator: " / ") }
        if case .project(let access) = plan.destination, access.id == id { return access.name ?? "Selected project" }
        return "Selected project"
    }
    private func details(_ row: Record) -> String {
        var parts = ["Priority \(row.priority)"]
        if let day = Dates.parse(row.string("due_date")) { parts.append("Planned " + day.formatted(date: .abbreviated, time: .omitted)); if !row.string("due_time").isEmpty { parts.append(row.string("due_time") + (row.string("time_zone").isEmpty ? "" : " " + row.string("time_zone"))) } }
        if let day = Dates.parse(row.string("deadline_date")) { parts.append("Deadline " + day.formatted(date: .abbreviated, time: .omitted)) }
        if row["duration_minutes"].integer > 0 { parts.append("\(row["duration_minutes"].integer) min") }
        return parts.joined(separator: " · ")
    }
}
