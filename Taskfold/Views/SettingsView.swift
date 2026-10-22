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
        TabView(selection: $workspace.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            MacSwipeSettings().tabItem { Label("Swipes", systemImage: "hand.draw") }.tag(SettingsTab.swipes)
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(SettingsTab.appearance)
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(SettingsTab.account)
            ImportSettings().tabItem { Label("Import", systemImage: "square.and.arrow.down") }.tag(SettingsTab.imports)
            AccountToolsSettings().tabItem { Label("Invitations", systemImage: "person.2") }.tag(SettingsTab.invitations)
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
    var body: some View {
        Form {
            Picker("Start view", selection: $defaultView) {
                ForEach([TaskScope.today, .inbox, .upcoming, .all, .completed], id: \.self) { Text($0.title).tag($0.preferenceKey) }
                Text("Calendar").tag("calendar")
                if !store.projects.isEmpty { Divider(); ForEach(store.projects) { Text($0.name).tag(TaskScope.project($0.id).preferenceKey) } }
                if !store.labels.isEmpty { Divider(); ForEach(store.labels) { Text($0.name).tag(TaskScope.label($0.id).preferenceKey) } }
            }
            Toggle("Task reminders", isOn: Binding(get: { store.remindersEnabled }, set: { enabled in if enabled { Task { await store.enableNotifications() } } else { store.disableNotifications() } }))
                .disabled(!store.signedIn || store.requestingNotifications || store.requestingFocusAlerts)
            if store.requestingNotifications {
                ProgressView("Requesting permission…")
                    .accessibilityIdentifier("taskReminderPermissionProgress")
            }
            Text("Choose fixed-time and before/after reminders in each task. Delivery is enabled separately for this workspace on each device. The nearest 60 notifications refresh while Taskfold is open.").font(.caption).foregroundStyle(.secondary)
            Text(store.reminderStatus).font(.caption).foregroundStyle(.secondary)
            ReminderSystemSettingsButton()
            #if DEBUG
            MacNotificationInspectionView()
            #endif
            if store.signedIn {
                Section("Date phrases") { DatePhrasePreferencesView() }
                Section("Automatic reminders") { ReminderAutomaticPreferencesView() }
                Section("Snooze") { ReminderSnoozePreferencesView() }
                Section("Place reminders") {
                    Label("Set up on iPhone or iPad", systemImage: "mappin.and.ellipse")
                    Text("Open Notifications → Place reminders in Taskfold on the device that will deliver the alert. Saved pins stay on that device. Your task’s reminder settings are preserved on this Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section("Remote reminders") { RemoteReminderRegistrationView() }
            } else {
                Text("Open a workspace to change date and reminder preferences.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Show Welcome Tour…") { workspace.onboarding = true; NSApp.windows.first { $0.identifier?.rawValue.contains("Taskfold") == true || $0.title == workspace.navigationTitle }?.makeKeyAndOrderFront(nil) }
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
    @State private var showLogin = false
    @State private var profileDraft = ProfileNameDraft()
    @State private var confirmSignOut = false
    @State private var importingAvatar = false
    @State private var uploading = false
    @State private var avatarWorkspace: WorkspaceBinding?
    @State private var avatarUploadID = UUID()
    @State private var changingEmail = false
    @State private var changingPassword = false
    @State private var deletingAccount = false
    @State private var resetMessage: String?
    @State private var sendingReset = false
    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Signed in as", value: !store.signedIn ? "Not signed in" : store.localMode ? "Local workspace on this Mac" : store.email)
                if store.localMode || !store.signedIn {
                    Text("Sign in to sync your tasks, manage your profile, and import from Todoist. Your local workspace stays saved separately on this Mac.").font(.callout).foregroundStyle(.secondary)
                    Button("Sign In or Create Account…") { showLogin = true }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("accountSignIn")
                }
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
                    Button("Delete Account…", role: .destructive) { deletingAccount = true }.accessibilityIdentifier("deleteAccount")
                } header: { Text("Security") } footer: {
                    if workspace.previewsAccount { Text("Preview: these actions need a signed-in account.").font(.caption).foregroundStyle(.secondary) }
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
                    Button(store.localMode ? "Leave Local Workspace…" : "Sign Out…", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .modifier(BackupPresentation())
        .formStyle(.grouped)
        .onAppear { refreshProfileDraft(); consumeSignInRequest() }
        .onChange(of: store.workspaceGeneration) { _, _ in refreshProfileDraft(); avatarWorkspace = nil; avatarUploadID = UUID(); uploading = false; importingAvatar = false }
        .onChange(of: store.accountName) { _, _ in refreshProfileDraft() }
        .onChange(of: workspace.signInRequested) { _, _ in consumeSignInRequest() }
        .onChange(of: store.localMode) { _, local in if !local && store.signedIn { showLogin = false } }
        .onChange(of: store.signedIn) { _, signedIn in if signedIn && !store.localMode { showLogin = false } }
        .sheet(isPresented: $changingEmail) { ChangeEmailSheet() }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .sheet(isPresented: $deletingAccount) { DeleteAccountSheet() }
        .sheet(isPresented: $showLogin) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Close") { showLogin = false }.keyboardShortcut(.cancelAction) }.padding(12)
                AuthView()
            }.frame(width: 820, height: 550)
        }
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
        .confirmationDialog(store.localMode ? "Leave this workspace?" : "Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(store.localMode ? "Leave" : "Sign Out", role: .destructive) { Task { await store.signOut() } }
        } message: { Text("Saved tasks and pending changes stay on this Mac for your next sign-in.") }
    }
    private func sendReset() {
        sendingReset = true; resetMessage = nil
        Task {
            defer { sendingReset = false }
            do { try await store.backend.sendPasswordReset(email: store.email); resetMessage = "A reset link was sent to \(store.email)." }
            catch { resetMessage = error.localizedDescription }
        }
    }
    private func consumeSignInRequest() {
        guard workspace.signInRequested else { return }
        workspace.signInRequested = false
        showLogin = true
    }
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
            Button("Sign In…") { workspace.settingsTab = .account; workspace.signInRequested = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Always-visible access to account and application tools, including in local mode.
struct AccountMenu: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Menu {
            if store.localMode || !store.signedIn {
                Button("Sign In…", systemImage: "person.crop.circle") { show(.account); workspace.signInRequested = true }
            }
            Button("Account…", systemImage: "person.crop.circle") { show(.account) }
            Button("Import from Todoist…", systemImage: "square.and.arrow.down") { show(.imports) }
            Button("Invitations…", systemImage: "person.2") { show(.invitations) }
            Divider()
            Button("Settings…", systemImage: "gearshape") { show(.general) }
        } label: {
            HStack(spacing: 8) {
                PersonAvatar(person: store.accountIdentity, size: 26).accessibilityHidden(true)
                Text(store.accountName).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton).padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityIdentifier("accountMenu").accessibilityLabel(store.accountName + ", Account")
    }
    private func show(_ tab: SettingsTab) { workspace.settingsTab = tab; openSettings() }
}
