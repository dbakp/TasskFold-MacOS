import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Preferences window (⌘,). Account, start view, appearance, reminders, data, and account-only tools.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    var body: some View {
        @Bindable var workspace = workspace
        TabView(selection: $workspace.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
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
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("defaultView") private var defaultView = "today"
    @AppStorage("remindersEnabled") private var reminders = false
    @AppStorage("accent") private var accent = "rose"
    var body: some View {
        Form {
            Picker("Start view", selection: $defaultView) {
                ForEach([TaskScope.today, .inbox, .upcoming, .all, .completed], id: \.self) { Text($0.title).tag($0.preferenceKey) }
                Text("Calendar").tag("calendar")
                if !store.projects.isEmpty { Divider(); ForEach(store.projects) { Text($0.name).tag(TaskScope.project($0.id).preferenceKey) } }
                if !store.labels.isEmpty { Divider(); ForEach(store.labels) { Text($0.name).tag(TaskScope.label($0.id).preferenceKey) } }
            }
            Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
            LabeledContent("Accent") {
                HStack(spacing: 10) {
                    ForEach(Color.accents, id: \.key) { option in
                        Button { withAnimation(Transitions.Ease.smoothOut(Transitions.Duration.quick)) { accent = option.key } } label: {
                            Circle().fill(option.color).frame(width: 22, height: 22)
                                .overlay { if accent == option.key { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) } }
                                .overlay(Circle().strokeBorder(Color.primary.opacity(accent == option.key ? 0.25 : 0), lineWidth: 1))
                        }
                        .buttonStyle(.plain).pointerStyle(.link)
                        .help(option.name)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(accent == option.key ? .isSelected : [])
                        .accessibilityIdentifier("accent-\(option.key)")
                    }
                }
            }
            Toggle("Task reminders", isOn: Binding(get: { reminders }, set: { enabled in if enabled { Task { await store.enableNotifications() } } else { store.disableNotifications() } }))
            Text("Due tasks notify at their chosen time, or 8:00 AM if no time is set. macOS schedules the nearest 60 reminders; Taskfold refreshes them while open.").font(.caption).foregroundStyle(.secondary)
            Button("Open Notification Settings…") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
        }
        .formStyle(.grouped)
    }
}

struct AccountSettings: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var showLogin = false
    @State private var displayName = ""
    @State private var confirmSignOut = false
    @State private var importingAvatar = false
    @State private var uploading = false
    @State private var exporting = false
    @State private var exportDocument: JSONExport?
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
                        AsyncImage(url: URL(string: store.profile.string("avatar_url"))) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                            .frame(width: 48, height: 48).clipShape(.circle)
                        Button(uploading ? "Uploading…" : "Change Photo…") { importingAvatar = true }.disabled(uploading)
                        if !store.profile.string("avatar_url").isEmpty { Button("Remove Photo") { var profile = store.profile; profile["avatar_url"] = .null; store.save("profiles", profile) } }
                    }
                    TextField("Display name", text: $displayName).onSubmit(saveProfile)
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
                LabeledContent("Storage", value: store.localMode ? "This Mac" : "Synced account and this Mac")
                if store.signedIn && !store.localMode {
                    LabeledContent("Pending changes", value: "\(store.pendingCount)")
                    if let date = store.lastSync { LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Button(store.syncing ? "Syncing…" : "Sync Now") { Task { await store.sync() } }.disabled(store.syncing)
                    if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                Button("Export Workspace…") {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    do {
                        exportDocument = JSONExport(data: try encoder.encode(store.snapshot.tables)); exporting = true
                    } catch { store.error = error.localizedDescription }
                }
            }
            if store.signedIn {
                Section {
                    Button(store.localMode ? "Leave Local Workspace…" : "Sign Out…", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { displayName = store.profile.string("display_name"); consumeSignInRequest() }
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
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Taskfold-export") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
        .fileImporter(isPresented: $importingAvatar, allowedContentTypes: [.image]) { result in
            uploading = true
            Task {
                defer { uploading = false }
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
                    let avatarURL = try await store.backend.uploadAvatar(jpeg)
                    var profile = store.profile; profile["avatar_url"] = .string(avatarURL)
                    if profile.id.isEmpty { profile["id"] = .string(store.userID); profile["user_id"] = .string(store.userID) }
                    store.save("profiles", profile)
                } catch { store.error = error.localizedDescription }
            }
        }
        .confirmationDialog(store.localMode ? "Leave this workspace?" : "Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(store.localMode ? "Leave" : "Sign Out", role: .destructive) { store.signOut() }
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
    private func saveProfile() {
        var profile = store.profile
        if profile.id.isEmpty { profile["id"] = .string(store.userID); profile["user_id"] = .string(store.userID) }
        profile["display_name"] = .string(displayName); profile["updated_at"] = .string(Dates.timestamp())
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
            if store.localMode || !store.signedIn {
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
            Label(store.localMode ? "Local Workspace" : store.profile.string("display_name").isEmpty ? "My Account" : store.profile.string("display_name"), systemImage: "person.crop.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton).padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityIdentifier("accountMenu")
    }
    private func show(_ tab: SettingsTab) { workspace.settingsTab = tab; openSettings() }
}

struct JSONExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
