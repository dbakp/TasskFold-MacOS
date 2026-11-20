import SwiftUI
import UniformTypeIdentifiers
import AppKit
#if DEBUG
import UserNotifications
#endif

/// Preferences window (⌘,). Account, start view, appearance, reminders, data, and account-only tools.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            AccountRemovalRecoveryBanner()
            TabView(selection: $workspace.settingsTab) {
                GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
                MacSwipeSettings().tabItem { Label("Swipes", systemImage: "hand.draw") }.tag(SettingsTab.swipes)
                AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
                AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(SettingsTab.account)
                PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
                ImportSettings().tabItem { Label("Import", systemImage: "square.and.arrow.down") }.tag(SettingsTab.imports)
                AccountToolsSettings().tabItem { Label("Invitations", systemImage: "person.2") }.tag(SettingsTab.invitations)
            }
        }
        .frame(width: 620, height: 560)
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("defaultView") private var defaultView = "today"
    @AppStorage("accent") private var accent = "rose"
    @AppStorage(CompletionSound.defaultsKey) private var playCompletionSound = true
    var body: some View {
        Form {
            Picker("Start view", selection: $defaultView) {
                ForEach([TaskScope.today, .inbox, .upcoming, .all, .completed], id: \.self) { Text($0.title).tag($0.preferenceKey) }
                Text("Calendar").tag("calendar")
                if !store.projects.isEmpty { Divider(); ForEach(store.projects) { Text($0.name).tag(TaskScope.project($0.id).preferenceKey) } }
                if !store.labels.isEmpty { Divider(); ForEach(store.labels) { Text($0.name).tag(TaskScope.label($0.id).preferenceKey) } }
            }
            Toggle("Play sound on completion", isOn: $playCompletionSound).accessibilityIdentifier("playCompletionSound")
            GlobalQuickAddSettings()
            Toggle("Task reminders", isOn: Binding(get: { store.remindersEnabled }, set: { enabled in if enabled { Task { await store.enableNotifications() } } else { store.disableNotifications() } }))
                .disabled(!store.signedIn || store.requestingNotifications || store.requestingFocusAlerts)
            if store.requestingNotifications {
                ProgressView("Requesting permission…")
                    .accessibilityIdentifier("taskReminderPermissionProgress")
            }
            Text(store.reminderStatus).font(.caption).foregroundStyle(.secondary)
            ReminderSystemSettingsButton()
            #if DEBUG
            MacNotificationInspectionView()
            #endif
            if store.signedIn {
                Section("Date words") { DatePhrasePreferencesView() }
                Section("Automatic reminders") { ReminderAutomaticPreferencesView() }
                Section("Snooze") { ReminderSnoozePreferencesView() }
                Section("Place reminders") {
                    Label("Places live on your iPhone", systemImage: "mappin.and.ellipse")
                    Text("Type “at Home” in Quick Add; your iPhone reminds you at its place with that name.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("Remote reminders") { RemoteReminderRegistrationView() }
            } else {
                Text("Open a workspace to change date and reminder preferences.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Show welcome tour…") { workspace.onboarding = true; NSApp.windows.first { $0.identifier?.rawValue.contains("Taskfold") == true || $0.title == workspace.navigationTitle }?.makeKeyAndOrderFront(nil) }
                    .disabled(!store.signedIn)
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
/// Read-only system evidence, available only in the independently isolated notification app.
/// No launch flag is required: a real notification cold launch must retain normal app behavior.
private struct MacNotificationInspectionView: View {
    @Environment(Store.self) private var store
    @State private var report = "Not inspected"
    @State private var inspecting = false
    private var enabled: Bool {
        Bundle.main.bundleIdentifier == "com.dbakp.taskfold.mac.p0notificationtests"
    }
    var body: some View {
        if enabled {
            Section("Isolated notification inspection") {
                Button(inspecting ? "Inspecting…" : "Inspect system alerts") {
                    Task { await inspect() }
                }
                .disabled(inspecting)
                .accessibilityIdentifier("inspectSystemReminders")
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("systemReminderInspection")
                    .accessibilityValue(report)
                if MacNotificationResponseHoldFixture.enabled {
                    let fixture = MacNotificationResponseHoldFixture.shared
                    Button("Hold next response") { fixture.arm() }
                        .accessibilityIdentifier("holdNotificationCallback")
                    Button("Release held response") { fixture.release() }
                        .accessibilityIdentifier("releaseNotificationCallback")
                    Text(fixture.status).font(.caption.monospaced())
                        .accessibilityIdentifier("notificationCallbackPhase")
                        .accessibilityValue(fixture.status)
                }
            }
            .onChange(of: store.workspaceGeneration) { _, _ in report = "Workspace changed; inspect again" }
        }
    }
    @MainActor private func inspect() async {
        guard enabled, !inspecting else { return }
        inspecting = true
        defer { inspecting = false }
        let account = store.userID, generation = store.workspaceGeneration
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let categories = await center.notificationCategories()
        guard enabled, account == store.userID, generation == store.workspaceGeneration else { return }
        func request(_ value: UNNotificationRequest) -> [String: Any] {
            var row: [String: Any] = ["id": value.identifier, "category": value.content.categoryIdentifier]
            for key in ["accountID", "taskID", "specID", "signature", "originalAt", "fireAt", "snoozed"] {
                row[key] = value.content.userInfo[key]
            }
            let date = (value.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ??
                (value.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            if let date { row["triggerAt"] = date.timeIntervalSince1970 }
            return row
        }
        let payload: [String: Any] = [
            "observedAt": Date().timeIntervalSince1970,
            "accountID": account,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "pending": pending.sorted { $0.identifier < $1.identifier }.map(request),
            "delivered": delivered.sorted { $0.request.identifier < $1.request.identifier }.map { request($0.request) },
            "actions": categories.first { $0.identifier == ReminderCategory.identifier }?.actions.map {
                ["id": $0.identifier, "title": $0.title]
            } ?? []
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return }
        report = value
    }
}
#endif

struct AccountSettings: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var profileDraft = ProfileNameDraft()
    @State private var confirmSignOut = false
    @State private var importingAvatar = false
    @State private var uploading = false
    @State private var avatarWorkspace: WorkspaceBinding?
    @State private var avatarUploadID = UUID()
    @State private var emailCapture = false
    @State private var webhookAccess = false
    @State private var automationAccess = false
    @State private var teamsPresented = false
    @State private var changingEmail = false
    @State private var changingPassword = false
    @State private var deletingAccount = false
    @State private var deletionWorkspace: WorkspaceBinding?
    @State private var resetMessage: String?
    @State private var sendingReset = false
    var body: some View {
        Form {
            Section("Account") {
                if store.localMode || !store.signedIn {
                    LabeledContent("Account") { VStack(alignment: .trailing, spacing: 2) { Text("Not signed in"); Text("Tasks are saved only on this Mac").font(.caption).foregroundStyle(.secondary) } }
                    HStack {
                        Button("Sign In…") { requestSignIn() }.buttonStyle(.borderedProminent).tint(DS.Palette.accentFill).accessibilityIdentifier("accountSignIn")
                        Button("Create Account…") { requestSignIn() }.accessibilityIdentifier("accountCreate")
                    }
                } else { LabeledContent("Signed in as", value: store.email) }
                if store.signedIn && !store.localMode {
                    HStack(spacing: 14) {
                        PersonAvatar(person: store.accountIdentity, size: 48)
                        Button(uploading ? "Uploading…" : "Change Photo…") { avatarWorkspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); importingAvatar = true }.disabled(uploading)
                        if !store.profile.string("avatar_url").isEmpty { Button("Remove Photo") { var profile = store.profile; profile["avatar_url"] = .null; store.save("profiles", profile) } }
                    }
                    TextField("Display name", text: $profileDraft.text).onSubmit(saveProfile)
                    Button("Save Profile", action: saveProfile)
                }
            }
            if (store.signedIn && !store.localMode) || workspace.previewsAccount {
                Section {
                    Button("Change Email…") { changingEmail = true }.accessibilityIdentifier("changeEmail")
                    Button("Change Password…") { changingPassword = true }.accessibilityIdentifier("changePassword")
                    Button(sendingReset ? "Sending…" : "Send Password Reset Email") { sendReset() }.disabled(sendingReset).accessibilityIdentifier("sendPasswordReset")
                    if let resetMessage { Text(resetMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Delete Account…", role: .destructive) { deletionWorkspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); deletingAccount = true }.disabled(store.accountRemovalBusy || store.accountRemovalBlocked).accessibilityIdentifier("deleteAccount")
                } header: { Text("Security") } footer: {
                    if workspace.previewsAccount { Text("Preview: these actions need a signed-in account.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if EmailCaptureAvailability.enabled && store.signedIn && !store.localMode {
                Section("Email capture") { Button("Email to Taskfold…", systemImage: "envelope") { emailCapture = true }.accessibilityIdentifier("emailCapture") }
            }
            if WebhookAccessAvailability.enabled && store.signedIn && !store.localMode {
                Section("Task connections") { Button("Task connections…", systemImage: "arrow.triangle.branch") { webhookAccess = true }.accessibilityIdentifier("webhookAccess") }
            }
            SavedProjectTransferLink()
            SavedTeamTemplateRequestLink()
            SavedTeamWorkflowRequestLink()
            if TeamOrganizationAvailability.enabled && store.signedIn && !store.localMode {
                Section("Teams") { Button("Your teams…", systemImage: "person.3") { teamsPresented = true } }
            }
            if AutomationAccessAvailability.enabled && store.signedIn && !store.localMode {
                Section("Connected tools") {
                    Button("Automation access…", systemImage: "key.horizontal") { automationAccess = true }.accessibilityIdentifier("automationAccess")
                }
            }
            Section("Data") {
                LabeledContent("Storage", value: !store.signedIn ? "No workspace open" : store.localMode ? "This Mac" : "Synced account and this Mac")
                if store.signedIn && !store.localMode {
                    LabeledContent("Pending changes", value: "\(store.pendingCount)")
                    if let date = store.lastSync { LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Button(store.syncing ? "Syncing…" : "Sync Now") { Task { await store.sync() } }.disabled(store.syncing)
                    if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
            }
            BackupTools()
            if store.signedIn {
                Section {
                    Button(store.localMode ? "Close Local Workspace…" : "Sign Out…", role: store.localMode ? nil : .destructive) { confirmSignOut = true }
                }
            }
        }
        .modifier(BackupPresentation())
        .formStyle(.grouped)
        .onAppear { refreshProfileDraft() }
        .onChange(of: store.workspaceGeneration) { _, _ in refreshProfileDraft(); avatarWorkspace = nil; avatarUploadID = UUID(); uploading = false; importingAvatar = false }
        .onChange(of: store.accountName) { _, _ in refreshProfileDraft() }
        .sheet(isPresented: $emailCapture) { NavigationStack { EmailCaptureView() } }
        .sheet(isPresented: $webhookAccess) { NavigationStack { WebhookAccessView() } }
        .sheet(isPresented: $teamsPresented) { NavigationStack { TeamOrganizationView() } }
        .sheet(isPresented: $automationAccess) { NavigationStack { AutomationAccessView() } }
        .sheet(isPresented: $changingEmail) { ChangeEmailSheet() }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .sheet(isPresented: $deletingAccount) { if let request = deletionWorkspace { DeleteAccountSheet(workspace: request) } }
        .fileImporter(isPresented: $importingAvatar, allowedContentTypes: [.image]) { result in
            guard let owner = avatarWorkspace, store.signedIn, !store.localMode, owner.matches(account: store.userID, generation: store.workspaceGeneration) else { return }
            let operation = UUID(); avatarUploadID = operation
            uploading = true
            Task {
                defer { if avatarUploadID == operation { uploading = false } }
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard let image = NSImage(contentsOf: url) else { throw AppFailure(message: "Could not read this photo.") }
                    let side = min(image.size.width, image.size.height)
                    let rendered = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
                        let scale = 512 / side
                        image.draw(in: NSRect(x: (512 - image.size.width * scale) / 2, y: (512 - image.size.height * scale) / 2, width: image.size.width * scale, height: image.size.height * scale))
                        return true
                    }
                    guard let tiff = rendered.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw AppFailure(message: "Could not prepare this photo.") }
                    guard owner.matches(account: store.userID, generation: store.workspaceGeneration) else { return }
                    let avatarURL = try await store.backend.uploadAvatar(jpeg, expectedAccount: owner.account)
                    guard owner.matches(account: store.userID, generation: store.workspaceGeneration) else { return }
                    var profile = store.profile; profile["avatar_url"] = .string(avatarURL)
                    if profile.id.isEmpty { profile["id"] = .string(store.userID); profile["user_id"] = .string(store.userID) }
                    store.save("profiles", profile)
                } catch is CancellationError {
                    // Account changes discard this workspace-owned operation.
                } catch {
                    if owner.matches(account: store.userID, generation: store.workspaceGeneration) { store.error = error.localizedDescription }
                }
            }
        }
        .disabled(store.signingOut)
        .overlay {
            if store.signingOut {
                ProgressView("Signing out…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .confirmationDialog(store.localMode ? "Close this workspace?" : "Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(store.localMode ? "Close" : "Sign Out", role: store.localMode ? nil : .destructive) { Task { await store.signOut() } }
        } message: { Text(store.localMode ? "Your tasks stay on this Mac. You can open them again from the sign-in screen." : "Saved tasks and pending changes stay on this Mac for your next sign-in.") }
    }
    private func sendReset() {
        sendingReset = true; resetMessage = nil
        Task {
            defer { sendingReset = false }
            do { try await store.backend.sendPasswordReset(email: store.email); resetMessage = "A reset link was sent to \(store.email)." }
            catch { resetMessage = error.localizedDescription }
        }
    }
    private func requestSignIn() { workspace.presentSignIn() }
    private func refreshProfileDraft() {
        profileDraft.refresh(account: store.userID, generation: store.workspaceGeneration, name: store.accountName)
    }
    private func saveProfile() {
        guard store.signedIn, !store.localMode, profileDraft.matches(account: store.userID, generation: store.workspaceGeneration) else {
            refreshProfileDraft()
            return
        }
        var profile = store.profile
        if profile.id.isEmpty { profile["id"] = .string(store.userID); profile["user_id"] = .string(store.userID) }
        profile["display_name"] = .string(profileDraft.text); profile["updated_at"] = .string(Dates.timestamp())
        store.save("profiles", profile)
    }
}

struct AccountToolsSettings: View {
    @Environment(Store.self) private var store
    var body: some View {
        if store.localMode || !store.signedIn {
            AccountRequiredView(title: "Project invitations", detail: "Sign in to accept invitations and collaborate on projects.")
        } else { InvitationsView().padding() }
    }
}

struct ImportSettings: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import from Todoist").accessibilityIdentifier("todoistImportSettings").font(.title2.weight(.semibold)).padding(.horizontal, 20).padding(.top, 16)
            if (store.localMode || !store.signedIn) && !store.todoistImportFixture {
                AccountRequiredView(title: "Bring your tasks to Taskfold", detail: "Sign in to preview and import your Todoist projects, sections, labels, tasks, subtasks, and comments.")
            } else { TodoistImportView() }
        }
    }
}

struct AccountRequiredView: View {
    @Environment(Workspace.self) private var workspace
    let title: String
    let detail: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "person.crop.circle")
        } description: { Text(detail) } actions: {
            Button("Sign In…") { workspace.presentSignIn() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Always-visible access to account and application tools, including in local mode. A dot on the avatar flags a sync
/// problem (and only a problem); the menu explains it.
struct AccountMenu: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings
    @State private var reauthenticate = false
    /// The sidebar foot shows the initials chip alone.
    var compact = false
    var body: some View {
        let issue = store.syncIssue
        Menu {
            if let issue {
                Button(issue.detail, systemImage: issue == .offline ? "wifi.slash" : "exclamationmark.circle") {}.disabled(true)
                if issue == .signInAgain { Button("Sign in again…", systemImage: "person.crop.circle.badge.exclamationmark") { reauthenticate = true } }
                if issue == .cantSync { Button("Try Again", systemImage: "arrow.clockwise") { Task { await store.sync() } } }
                Divider()
            }
            if store.localMode || !store.signedIn {
                Button("Sign In…", systemImage: "person.crop.circle") { workspace.presentSignIn() }
            }
            Button("Account…", systemImage: "person.crop.circle") { show(.account) }
            Button("Import from Todoist…", systemImage: "square.and.arrow.down") { show(.imports) }
            Button("Invitations…", systemImage: "person.2") { show(.invitations) }
            Divider()
            Button("Settings…", systemImage: "gearshape") { show(.general) }
        } label: {
            if compact {
                PersonAvatar(person: store.accountIdentity, size: 22).accessibilityHidden(true)
                    .overlay(alignment: .topTrailing) { if issue != nil { SyncIssueDot().offset(x: 3, y: -3) } }
            } else {
                HStack(spacing: 8) {
                    PersonAvatar(person: store.accountIdentity, size: 26).accessibilityHidden(true)
                        .overlay(alignment: .topTrailing) { if issue != nil { SyncIssueDot().offset(x: 3, y: -3) } }
                    Text(store.accountName).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(compact ? .hidden : .automatic).fixedSize(horizontal: compact, vertical: false)
        .padding(.horizontal, compact ? 0 : 14).padding(.vertical, compact ? 0 : 10)
        .help(issue?.detail ?? store.accountName)
        .accessibilityIdentifier("accountMenu").accessibilityLabel(store.accountName + ", Account" + (issue.map { ". " + $0.detail } ?? ""))
        .background { SyncSignInButton(trigger: $reauthenticate).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true) }
    }
    private func show(_ tab: SettingsTab) { workspace.settingsTab = tab; openSettings() }
}

/// The small badge that marks an account button when sync needs a word.
struct SyncIssueDot: View {
    var body: some View {
        Circle().fill(Color.orange).frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(DS.Palette.surface, lineWidth: 1.5)).accessibilityIdentifier("syncIssueDot")
    }
}

private struct AccountRemovalRecoveryRequestDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(_ request: AccountRemovalRecoveryRequest) throws { data = try request.encoded() }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= AccountRemovalRecoveryFile.maximumBytes else { throw AccountRemovalRecoveryRequest.invalid }; self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct AccountRemovalRecoveryOptionsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var scope: AccountRemovalRecoveryScope?
    @State private var requests: [AccountRemovalRecoveryRequest] = []
    @State private var selected: UUID?
    @State private var document: AccountRemovalRecoveryRequestDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var importFor: AccountRemovalRecoveryRequest?
    @State private var reviewed: AccountRemovalRecoveryFile?
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    @State private var applying = false
    @State private var loading = true
    private var choice: AccountRemovalRecoveryRequest? { requests.first { $0.id == selected } }
    var body: some View {
        WorkflowShell(title: "Recover account removal") {
            Group {
                if applying {
                    ProgressView("Checking removal with the original server…").padding().accessibilityIdentifier("accountRecoveryChecking")
                } else if let scope, scope != store.accountRemovalRecoveryScope {
                    ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Reopen recovery options to continue. Your saved work has been kept."))
                } else {
                    Form {
                        Section {
                            Text("If signing in or retrying cannot finish an older removal, you can request a recovery file.")
                            Text("Your saved work stays on this device until the original server confirms removal.").foregroundStyle(.secondary)
                        }
                        if requests.count > 1 {
                            Picker("Saved removal", selection: $selected) {
                                ForEach(requests) { request in Text("Account ••••" + request.account.suffix(4)).tag(Optional(request.id)) }
                            }.disabled(work != nil || importing).onChange(of: selected) { _, _ in reviewed = nil; message = nil }
                        }
                        if let choice {
                            Section("Request help") {
                                LabeledContent("Original server", value: URL(string: choice.origin)?.host ?? choice.origin)
                                Button("Save recovery request…") {
                                    do { document = try AccountRemovalRecoveryRequestDocument(choice); exporting = true; message = nil }
                                    catch { message = error.localizedDescription }
                                }.accessibilityIdentifier("saveRemovalRecoveryRequest").disabled(work != nil)
                                Text("Send this request to your Taskfold administrator through your usual support channel. It contains no passwords or task content.").font(.footnote).foregroundStyle(.secondary)
                            }
                            Section("Use a recovery file") {
                                Button("Import recovery file…") { importFor = choice; importing = true; message = nil }.accessibilityIdentifier("importRemovalRecoveryFile").disabled(work != nil)
                                if let reviewed {
                                    Label("Recovery file matches this saved request", systemImage: "checkmark.shield").accessibilityIdentifier("removalRecoveryReviewed")
                                    Text("Taskfold will verify the file and check removal again with the original server before clearing this account’s remaining copies on this device.").font(.callout).foregroundStyle(.secondary)
                                    Button("Verify and finish", role: .destructive) { finish(reviewed) }.accessibilityIdentifier("verifyRemovalRecovery").disabled(work != nil)
                                }
                                if work != nil { ProgressView("Opening recovery file…") }
                            }
                        } else if loading { ProgressView("Loading saved requests…") }
                        else if scope != nil {
                            ContentUnavailableView("No saved removal to recover", systemImage: "checkmark.shield", description: Text("Retry may already have finished it. You can close this window."))
                        }
                        if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("removalRecoveryMessage") }
                    }.formStyle(.grouped)
                }
            }
        }
        .task {
            let captured = store.accountRemovalRecoveryScope; scope = captured
            defer { loading = false }
            do {
                let loaded = try await store.accountRemovalRecoveryRequests(scope: captured)
                guard !Task.isCancelled, captured == store.accountRemovalRecoveryScope else { return }
                requests = loaded; selected = loaded.first?.id
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Taskfold recovery request") { result in
            if case .failure(let error) = result, (error as NSError).code != CocoaError.userCancelled.rawValue { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first, let expected = importFor { read(url, expected: expected) }
            case .failure(let error): if (error as NSError).code != CocoaError.userCancelled.rawValue { message = error.localizedDescription }
            }
        }
        .onChange(of: store.accountRemovalRecoveryScope) { _, _ in
            if !applying { work?.cancel() }
            reviewed = nil; importFor = nil; document = nil; requests = []; importing = false; exporting = false
        }
        .onDisappear {
            // A full-screen system picker can cover this view without closing recovery.
            // Keep its exact request until the picker returns; scope changes still invalidate it.
            if !importing && !exporting { work?.cancel(); reviewed = nil; document = nil; importFor = nil }
        }
    }
    private func read(_ url: URL, expected: AccountRemovalRecoveryRequest) {
        guard let scope, scope == store.accountRemovalRecoveryScope, work == nil else { return }
        let operation = AccountRemovalRecoveryReadOperation()
        let worker = Task.detached(priority: .userInitiated) { try operation.read(url) }
        work = Task { @MainActor in
            defer { work = nil }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { operation.cancel(); worker.cancel() })
                try Task.checkCancellation()
                guard scope == store.accountRemovalRecoveryScope, expected.id == selected else { return }
                reviewed = try AccountRemovalRecoveryFile(data: data, expected: expected)
            } catch is CancellationError { }
            catch { if (error as NSError).code != CocoaError.userCancelled.rawValue { message = error.localizedDescription }; reviewed = nil }
        }
    }
    private func finish(_ file: AccountRemovalRecoveryFile) {
        guard let scope, scope == store.accountRemovalRecoveryScope, work == nil else { return }
        applying = true; message = nil
        work = Task { @MainActor in
            defer { applying = false; work = nil }
            do { try await store.applyAccountRemovalRecovery(file, scope: scope); dismiss() }
            catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
}
