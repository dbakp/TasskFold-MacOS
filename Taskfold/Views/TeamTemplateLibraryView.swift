import SwiftUI
import Observation

struct SavedTeamTemplateRequestLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var showing = false
    @State private var reload = UUID()
    private var lifecycle: String { "\(store.userID)|\(store.workspaceGeneration)|\(store.backend.reminderSessionIncarnation)|\(phase == .active)|\(reload)" }
    var body: some View {
        Group {
            if visible, store.teamTemplateRecoveryAvailable {
                Section { Button("Saved template request", systemImage: "tray.and.arrow.up") { showing = true }.accessibilityIdentifier("savedTeamTemplateRequest") }
            }
        }
        .task(id: lifecycle) {
            visible = false
            guard phase == .active, store.teamTemplateRecoveryAvailable, let origin = try? store.backend.accountRemovalOrigin else { return }
            let account = store.userID, captured = lifecycle
            do {
                let vault = try store.teamTemplateCommandVault(account: account, origin: origin)
                let saved = try await vault.pending(account: account, origin: origin)
                guard captured == lifecycle else { return }; visible = saved != nil
            } catch { guard captured == lifecycle else { return }; visible = true }
        }
        .sheet(isPresented: $showing, onDismiss: { reload = UUID() }) { WorkflowShell(title: "Saved template request") { TeamTemplateLibraryView() } }
    }
}

struct TeamTemplateLibraryView: View {
    var teamID: String? = nil
    var templateID: String? = nil
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var browser: TeamTemplateBrowser?
    @State private var commands: TeamTemplateCommandModel?
    @State private var loaded: String?
    @State private var editing: TeamTemplateReviewRequest?
    @State private var transferring: TeamTemplateTransferSheet?
    @State private var stopping: TeamTemplateCommand?
    @State private var retrying: TeamTemplateCommand?
    private var context: String? {
        guard store.teamTemplateRecoveryAvailable, let origin = try? store.backend.accountRemovalOrigin else { return nil }
        return "\(store.userID)|\(origin)|\(store.workspaceGeneration)|\(store.backend.reminderSessionIncarnation)"
    }
    private var visible: Bool { phase == .active && context != nil && context == loaded }
    var body: some View {
        Group {
            if visible {
                List {
                    recovery
                    if teamID != nil {
                        if !store.teamOrganizationReadable { ContentUnavailableView("Refresh your workspace", systemImage: "lock.shield", description: Text("Team access must be verified before showing its templates.")) }
                        else if browser?.loading == true { ProgressView("Refreshing templates…") }
                        else if let message = browser?.message { Section { Text(message); Button("Try again") { Task { await refresh() } } } }
                        else if let organization = browser?.organization {
                            Section {
                                Label(organization.team.name, systemImage: "person.3.fill").font(.title2.bold())
                                Text("Reusable workflows for this team. Publishing a definition creates no tasks; later edits leave existing work unchanged.").font(.callout).foregroundStyle(.secondary)
                                if organization.team.archived { Label("Archived team · library is read-only", systemImage: "archivebox").font(.callout) }
                            }.listRowBackground(Color.accentColor.opacity(0.07))
                            if let detail = browser?.detail {
                                Section(detail.metadata.name) {
                                    if detail.supported != nil { TemplateDefinitionPreview(document: detail.document, scope: "team-library") }
                                    else { Text("This definition needs a newer Taskfold version. Its contents are preserved.").foregroundStyle(.secondary) }
                                }
                                if detail.supported != nil {
                                    Section {
                                        Button("Save private copy…", systemImage: "square.on.square") { transfer(detail, exporting: false) }.accessibilityIdentifier("copyTeamTemplate")
                                        Button("Export template…", systemImage: "square.and.arrow.up") { transfer(detail, exporting: true) }.accessibilityIdentifier("exportTeamTemplate")
                                    }
                                }
                                if canManage {
                                    Section {
                                        if detail.supported != nil { Button("Edit or replace definition", systemImage: "pencil") { review(.replace, detail: detail) }.accessibilityIdentifier("editTeamTemplate") }
                                        Button("Remove from library", role: .destructive) { review(.delete, detail: detail) }.accessibilityIdentifier("deleteTeamTemplate")
                                    }
                                }
                            } else {
                                Section("Team templates") {
                                    if browser?.items.isEmpty == true { ContentUnavailableView("Room for a new routine", systemImage: "square.stack.3d.up", description: Text("Publish a reviewed private template to give this team a shared starting point.")) }
                                    ForEach(browser?.items ?? []) { item in
                                        NavigationLink { TeamTemplateLibraryView(teamID: teamID, templateID: item.id) } label: {
                                            VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.headline); Text("Updated \(item.updated.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                                        }.accessibilityIdentifier("teamTemplate-" + item.id)
                                    }
                                }
                            }
                        } else { Section { Text("Refresh to view this team’s templates."); Button("Refresh") { Task { await refresh() } } } }
                    } else if commands?.pending == nil, commands?.recoveryLoaded == true { ContentUnavailableView("No saved template request", systemImage: "checkmark.circle", description: Text("Confirmed changes can be found in their team’s library.")) }
                }
            } else { ContentUnavailableView("Team templates", systemImage: "lock.shield", description: Text("Open your synced account to continue.")) }
        }
        .navigationTitle("Team templates")
        .privacySensitive()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth: 560, idealWidth: 680, minHeight: 500)
        #endif
        .toolbar {
            if visible, teamID != nil {
                if canManage, templateID == nil { ToolbarItem { Button("Publish template", systemImage: "plus") { review(.publish) }.accessibilityIdentifier("publishTeamTemplate") } }
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(browser?.loading == true || commands?.busy == true) }
            }
        }
        .task(id: context) { await start() }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await refresh() } } }
        .onChange(of: store.workspaceReadRevision) { _, _ in browser?.invalidate(); Task { await refresh() } }
        .onDisappear { browser?.invalidate(); commands?.close() }
        .sheet(item: $editing) { request in
            if let commands { TeamTemplatePublicationReview(request: request, model: commands, current: { visible && store.teamOrganizationReadable && context == request.context && browser?.organization == request.organization && browser?.scope?.canManage == true && (request.baseline == nil || browser?.detail == request.baseline) }) }
        }
        .sheet(item: $transferring) { request in
            TeamTemplateTransferView(request: request, current: { visible && store.permitsTeamTemplateTransfer(request.review) && browser?.detail == request.review.detail }, refresh: { await refreshTransfer(request) })
        }
        .confirmationDialog("Stop retrying this change?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            if let command = stopping { Button("Stop retrying", role: .destructive) { Task { await commands?.stopRetrying(command) } } }
        } message: { Text("This removes only the saved request on this device. A change already accepted by the service stays in the team library. Check the latest library first.") }
        .confirmationDialog("Retry the original change?", isPresented: Binding(get: { retrying != nil }, set: { if !$0 { retrying = nil } })) {
            if let command = retrying { Button("Retry original change") { Task { await commands?.retry(command) } } }
        } message: { Text("Resend the exact reviewed request to its original team. This will not replace it with the latest definition or overwrite a newer version automatically.") }
        .onChange(of: commands?.receipt) { _, receipt in
            guard let receipt, visible else { return }; editing = nil
            if templateID != nil, receipt.raw["deleted"] == .bool(true) { dismiss(); return }
            Task { await refresh() }
        }
    }
    private var canManage: Bool { visible && browser?.scope?.canManage == true && browser?.organization != nil && browser?.loading == false && commands?.recoveryLoaded == true && commands?.pending == nil && commands?.busy == false }
    @ViewBuilder private var recovery: some View {
        if let commands {
            if let pending = commands.pending {
                Section("Saved template request") {
                    Text("An original \(pending.action.rawValue) request is waiting for confirmation.").font(.headline)
                    Text("Its contents stay private here until this team’s current access is verified. Check the latest library before deciding whether to retry.").font(.callout).foregroundStyle(.secondary)
                    NavigationLink("Check latest library") { TeamTemplateLibraryView(teamID: pending.team) }
                    Button("Retry original change") { retrying = pending }.disabled(commands.busy).accessibilityIdentifier("retryTeamTemplate")
                    Button("Stop retrying…", role: .destructive) { stopping = pending }.disabled(commands.busy)
                }
            }
            if let message = commands.message { Section { Text(message).foregroundStyle(.secondary) }.accessibilityIdentifier("teamTemplateRequestMessage") }
            if let success = commands.success { Section { Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }.accessibilityIdentifier("teamTemplateSuccess") }
            if !commands.recoveryLoaded, !commands.busy { Section { Text("Saved requests must be checked before publishing a new change."); Button("Check saved requests") { Task { await commands.load() } } } }
        }
    }
    private func transfer(_ detail: TeamTemplateDetail, exporting: Bool) {
        guard visible, store.teamOrganizationReadable, browser?.detail == detail else { return }
        if let review = try? TeamTemplateTransferReview(detail: detail, workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), session: store.backend.reminderSessionIncarnation) {
            transferring = TeamTemplateTransferSheet(review: review, exporting: exporting)
        }
    }
    @MainActor private func refreshTransfer(_ request: TeamTemplateTransferSheet) async -> Bool {
        let original = request.review
        guard visible, store.permitsTeamTemplateTransfer(original), transferring === request else { return false }
        await browser?.refresh(template: original.detail.metadata.id)
        guard visible, store.permitsTeamTemplateTransfer(original), transferring === request, let latest = browser?.detail,
              latest.metadata.id == original.detail.metadata.id, latest.scope.team == original.detail.scope.team,
              let review = try? TeamTemplateTransferReview(detail: latest, workspace: original.workspace, session: original.session, id: original.id) else { return false }
        request.review = review; return true
    }
    private func review(_ action: TeamTemplateCommand.Action, detail: TeamTemplateDetail? = nil) {
        guard canManage, let context, let organization = browser?.organization else { return }
        editing = .init(context: context, organization: organization, action: action, baseline: detail)
    }
    @MainActor private func start() async {
        browser?.invalidate(); commands?.close(); loaded = nil
        guard let captured = context, let origin = try? store.backend.accountRemovalOrigin else { return }
        let account = store.userID, backend = store.backend
        do {
            commands = TeamTemplateCommandModel(account: account, origin: origin, vault: try store.teamTemplateCommandVault(account: account, origin: origin), service: backend, current: { context == captured })
            if let teamID {
                browser = TeamTemplateBrowser(account: account, origin: origin, team: teamID, current: { context == captured && store.teamOrganizationReadable }, fence: { try await backend.workspaceBoundary(account: account).raw["token"]!.text }, page: { try await backend.teamTemplatePage(team: teamID, account: account, origin: origin, after: $0, revision: $1) }, detail: { try await backend.teamTemplateDetail(team: teamID, template: $0, account: account, origin: origin) }, readTeam: { try await backend.teamOrganizationDetail(team: teamID, account: account, origin: origin) })
            } else { browser = nil }
            loaded = captured; await commands?.load(); await refresh()
        } catch { loaded = nil }
    }
    @MainActor private func refresh() async {
        guard visible, commands?.busy != true else { return }
        await browser?.refresh(template: templateID)
    }
}

private struct TeamTemplateReviewRequest: Identifiable {
    let id = UUID()
    let context: String
    let organization: TeamOrganizationDetail
    let action: TeamTemplateCommand.Action
    let baseline: TeamTemplateDetail?
}
private struct TeamTemplatePublicationReview: View {
    let request: TeamTemplateReviewRequest
    let model: TeamTemplateCommandModel
    let current: () -> Bool
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var source: Record?
    @State private var name = ""
    @State private var message: String?
    @State private var audienceConfirmed = false
    @State private var submitted = false
    private var definition: JSON? { source?["document"] ?? request.baseline?.document }
    private var sourceCurrent: Bool { source == nil || (store.record(WorkflowTemplate.table, id: source!.id) == source && source?.string("user_id") == store.userID) }
    private var authoringCurrent: Bool { phase == .active && current() && sourceCurrent }
    private var allowed: Bool { authoringCurrent && !model.busy && model.pending == nil && model.recoveryLoaded }
    private var valid: Bool {
        guard allowed, !submitted else { return false }
        if request.action == .delete { return request.baseline != nil }
        guard (try? TeamTemplateLibraryValue.name(.string(name.trimmingCharacters(in: .whitespacesAndNewlines)))) != nil, let definition else { return false }
        return (try? WorkflowTemplate(document: definition)) != nil && audienceConfirmed
    }
    var body: some View {
        NavigationStack {
            Form {
                if phase == .active, current() {
                    Section("Audience") {
                        Label(request.organization.team.name, systemImage: "person.3.fill").font(.headline)
                        Text("Owners, admins and full members can read team templates. Guests cannot browse this library. Removing the definition later does not remove copies or work already created.").font(.callout).foregroundStyle(.secondary)
                    }
                    if request.action == .delete {
                        Section("Remove definition") {
                            Text(request.baseline?.metadata.name ?? "Template").font(.headline)
                            Text("Existing tasks and private copies are kept. Removing a template cannot be undone from this screen.").foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Definition") {
                            TextField("Template name", text: $name).accessibilityIdentifier("teamTemplateName")
                            Menu {
                                if request.baseline != nil { Button("Keep current definition") { source = nil; audienceConfirmed = false } }
                                ForEach(store.workflowTemplates.filter { $0.string("user_id") == store.userID && (try? WorkflowTemplate(document: $0["document"])) != nil }) { row in
                                    Button(row.name) { let previous = source?.name; source = row; if request.action == .publish && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == previous) { name = row.name }; audienceConfirmed = false }
                                }
                            } label: { Label(source?.name ?? (request.baseline == nil ? "Choose a private template" : "Current team definition"), systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect) }.accessibilityIdentifier("teamTemplateSource")
                            Text("Project names, task notes, labels and schedule rules will be visible to this audience. No tasks are created. Assignments, discussion and files are not included.").font(.callout).foregroundStyle(.secondary)
                            if request.action == .replace { Text("This replaces the saved definition for future use. Existing work stays unchanged.").font(.callout) }
                        }
                        if let definition { Section("Full contents") { TemplateDefinitionPreview(document: definition, scope: "publish") } }
                        Section { Toggle("I reviewed the audience and contents", isOn: $audienceConfirmed).accessibilityIdentifier("confirmTeamTemplateAudience") }
                    }
                    #if DEBUG
                    if TeamTemplateNativeFixture.enabled {
                        Section("Isolated test controls") {
                            Button { store.changeTeamTemplatePrivateSourceFixture() } label: { Text("Change private test source").frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect) }.accessibilityIdentifier("changeTemplatePublicationSource")
                            Button { store.withdrawTeamTemplateAccessFixture() } label: { Text("Withdraw test library access").frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect) }.accessibilityIdentifier("withdrawTemplatePublicationAccess")
                        }
                    }
                    #endif
                    if !sourceCurrent { Section { Text("The private source changed. Your draft name is kept; choose the latest source and review it again.").foregroundStyle(.secondary) } }
                    if let message = message ?? model.message { Section { Text(message).foregroundStyle(.secondary) } }
                } else { ContentUnavailableView("Review paused", systemImage: "lock.shield", description: Text("Return to the original account and refresh its library. Your draft is kept here.")) }
            }.formStyle(.grouped).accessibilityIdentifier("teamTemplatePublicationForm")
            .navigationTitle(request.action == .publish ? "Publish template" : request.action == .replace ? "Update team template" : "Remove template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy).accessibilityIdentifier("cancelTeamTemplateChange") }
                ToolbarItem(placement: .confirmationAction) { Button(request.action == .delete ? "Remove" : request.action == .publish ? "Publish" : "Save changes", role: request.action == .delete ? .destructive : nil) { send() }.disabled(!valid).accessibilityIdentifier("confirmTeamTemplateChange") }
            }
        }.privacySensitive()
        .onAppear { if name.isEmpty { name = request.baseline?.metadata.name ?? "" } }
        .onChange(of: name) { _, _ in audienceConfirmed = false }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 680, minHeight: 540, idealHeight: 680)
        #endif
    }
    private func send() {
        guard valid else { return }
        do {
            let command = try TeamTemplateCommand(account: request.organization.account, origin: request.organization.origin, action: request.action, team: request.organization.team.id, template: request.baseline?.metadata.id ?? UUID().uuidString.lowercased(), revision: request.baseline?.metadata.revision, name: request.action == .delete ? nil : name, document: request.action == .delete ? nil : definition)
            submitted = true
            Task {
                await model.send(command, canAuthor: {
                    authoringCurrent && (request.action == .delete || (audienceConfirmed && command.body["name"] == .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) && command.body["document"] == definition))
                })
                if model.pending == nil, model.receipt == nil { submitted = false }
            }
        } catch { message = "Review the name and definition before sending this change." }
    }
}

@MainActor @Observable private final class TeamTemplateTransferSheet: Identifiable {
    let id: UUID
    var review: TeamTemplateTransferReview
    let exporting: Bool
    init(review: TeamTemplateTransferReview, exporting: Bool) { id = review.id; self.review = review; self.exporting = exporting }
}
private struct TeamTemplateTransferView: View {
    let request: TeamTemplateTransferSheet
    let current: () -> Bool
    let refresh: () async -> Bool
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @AccessibilityFocusState private var statusFocused: Bool
    @State private var busy = false
    @State private var finished = false
    @State private var message: String?
    @State private var exportData = Data()
    @State private var exporting = false
    private var allowed: Bool { phase == .active && current() && !busy && !finished }
    var body: some View {
        NavigationStack {
            Form {
                if phase == .active, current() {
                    if let message { Section {
                        Text(message).foregroundStyle(.secondary).accessibilityIdentifier("teamTemplateTransferMessage").accessibilityFocused($statusFocused)
                        Button("Review latest definition") { refreshReview() }.disabled(busy).accessibilityIdentifier("refreshTeamTemplateTransfer")
                    } }
                    Section {
                        TextField("Template name", text: $name).focused($nameFocused).disabled(busy).accessibilityIdentifier("teamTemplateTransferName")
                        Text(request.exporting ? "This file includes workflow notes, label names and schedule rules. Review the full contents before saving or sharing it outside the team." : "Save a private template in your account. The team’s definition stays unchanged; later team edits will not update your copy.").font(.callout).foregroundStyle(.secondary)
                        Text("Assignments, discussions, attachments and completion history are excluded. No tasks are created.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Full contents") { TemplateDefinitionPreview(document: request.review.detail.document, scope: "team-transfer") }
                    #if DEBUG
                    if TeamTemplateNativeFixture.enabled {
                        Section("Isolated test controls") {
                            Button { store.changeTeamTemplateSharedSourceFixture() } label: { Text("Change shared test definition").frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect) }.accessibilityIdentifier("changeTemplateTransferSource")
                            Button { store.withdrawTeamTemplateAccessFixture() } label: { Text("Withdraw test library access").frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect) }.accessibilityIdentifier("withdrawTemplateTransferAccess")
                        }
                    }
                    #endif
                } else { Section {
                    ContentUnavailableView("Review paused", systemImage: "lock.shield", description: Text("Return to the original account and refresh this definition. Your draft name is kept here."))
                    Button("Review latest definition") { refreshReview() }.disabled(busy || phase != .active || !store.permitsTeamTemplateTransfer(request.review)).accessibilityIdentifier("refreshTeamTemplateTransfer")
                } }
            }.formStyle(.grouped).accessibilityIdentifier("teamTemplateTransferForm")
            .navigationTitle(request.exporting ? "Export team template" : "Save private copy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy).accessibilityIdentifier("cancelTeamTemplateTransfer") }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Checking…" : request.exporting ? "Save file…" : "Save copy") { perform() }.disabled(!allowed).accessibilityIdentifier(request.exporting ? "prepareTeamTemplateExport" : "saveTeamTemplateCopy") }
            }
        }.privacySensitive().frame(minWidth: 580, idealWidth: 680, minHeight: 540, idealHeight: 680)
        .onAppear { if name.isEmpty { name = request.review.detail.metadata.name } }
        .fileExporter(isPresented: $exporting, document: WorkspaceDocument(data: exportData), contentType: .json, defaultFilename: "Taskfold-template") { result in
            guard current() else { return }
            if case .success = result { finished = true; dismiss() }
            else if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { message = "The file couldn’t be saved. Your draft is kept." }
        }
        .onChange(of: request.review.detail) { _, _ in exporting = false; exportData = Data() }
        .onChange(of: message) { _, value in statusFocused = value != nil }
        .onChange(of: store.userID) { _, _ in exporting = false; exportData = Data() }
        .onChange(of: store.workspaceGeneration) { _, _ in exporting = false; exportData = Data() }
        .onChange(of: store.backend.reminderSessionIncarnation) { _, _ in exporting = false; exportData = Data() }
        .onChange(of: store.teamOrganizationReadable) { _, readable in if !readable { exporting = false; exportData = Data() } }
    }
    private func refreshReview() {
        guard !busy, phase == .active, store.permitsTeamTemplateTransfer(request.review) else { return }
        busy = true
        Task {
            let refreshed = await refresh()
            message = refreshed ? "Review the updated contents before continuing. Your draft name is kept." : "The definition couldn’t be refreshed. Return to the original account and try again when connected."
            busy = false
        }
    }
    private func perform() {
        guard allowed else { return }
        nameFocused = false
        let reviewedName = name, reviewed = request.review; busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await store.revalidateTeamTemplateTransfer(reviewed)
                guard phase == .active, current(), name == reviewedName, request.review.detail == reviewed.detail else { throw TeamTemplateLibraryValue.invalid }
                if request.exporting { exportData = try reviewed.export(name: reviewedName).encoded(); exporting = true }
                else {
                    let row = try reviewed.privateCopy(name: reviewedName)
                    guard store.record(WorkflowTemplate.table, id: row.id) == nil else { throw TeamTemplateLibraryValue.invalid }
                    var saved = false; workspace.run("Save Private Team Template") { saved = store.save(WorkflowTemplate.table, row) }
                    guard saved else { throw TeamTemplateLibraryValue.invalid }; finished = true; dismiss()
                }
            } catch { message = "The current definition and access couldn’t be verified, or this version cannot copy its contents. Your draft is kept. Refresh the library before trying again." }
        }
    }
}
