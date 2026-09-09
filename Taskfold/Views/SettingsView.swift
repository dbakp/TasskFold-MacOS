import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Preferences window (⌘,). Account, start view, appearance, reminders, data, and account-only tools.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
            AccountToolsSettings().tabItem { Label("Sharing", systemImage: "person.2") }
        }
        .frame(width: 520, height: 420)
    }
}

struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("defaultView") private var defaultView = "today"
    @AppStorage("remindersEnabled") private var reminders = false
    var body: some View {
        Form {
            Picker("Start view", selection: $defaultView) {
                ForEach([TaskScope.today, .inbox, .upcoming, .all, .completed], id: \.self) { Text($0.title).tag($0.preferenceKey) }
                Text("Calendar").tag("calendar")
                if !store.projects.isEmpty { Divider(); ForEach(store.projects) { Text($0.name).tag(TaskScope.project($0.id).preferenceKey) } }
                if !store.labels.isEmpty { Divider(); ForEach(store.labels) { Text($0.name).tag(TaskScope.label($0.id).preferenceKey) } }
            }
            Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
            Toggle("Task reminders", isOn: Binding(get: { reminders }, set: { enabled in if enabled { Task { await store.enableNotifications() } } else { store.disableNotifications() } }))
            Text("Due tasks notify at their chosen time, or 8:00 AM if no time is set. macOS schedules the nearest 60 reminders; Taskfold refreshes them while open.").font(.caption).foregroundStyle(.secondary)
            Button("Open Notification Settings…") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
        }
        .formStyle(.grouped)
    }
}

struct AccountSettings: View {
    @Environment(Store.self) private var store
    @State private var displayName = ""
    @State private var confirmSignOut = false
    @State private var importingAvatar = false
    @State private var uploading = false
    @State private var exporting = false
    @State private var exportDocument: JSONExport?
    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Signed in as", value: store.localMode ? "Local workspace on this Mac" : store.email)
                if !store.localMode {
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
            Section("Data") {
                LabeledContent("Storage", value: store.localMode ? "This Mac" : "Supabase + this Mac")
                if !store.localMode {
                    LabeledContent("Pending changes", value: "\(store.pendingCount)")
                    if let date = store.lastSync { LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Button(store.syncing ? "Syncing…" : "Sync Now") { Task { await store.sync() } }.disabled(store.syncing)
                    if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                Button("Export Workspace…") {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    exportDocument = JSONExport(data: (try? encoder.encode(store.snapshot.tables)) ?? Data()); exporting = true
                }
            }
            Section {
                Button(store.localMode ? "Leave Local Workspace…" : "Sign Out…", role: .destructive) { confirmSignOut = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { displayName = store.profile.string("display_name") }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Taskfold-export") { _ in }
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
        if store.localMode {
            ContentUnavailableView("Sign in to share projects", systemImage: "person.2", description: Text("Invitations and Todoist import need a Taskfold account."))
        } else {
            TabView {
                InvitationsView().tabItem { Text("Invitations") }
                TodoistImportView().tabItem { Text("Import from Todoist") }
            }.padding()
        }
    }
}

struct JSONExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
