import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum EmailCaptureAvailability {
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "TaskfoldEmailCaptureEnabled") as? Bool == true }
}
struct EmailCaptureView: View {
    var fixture = false
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var model: EmailCaptureModel?
    @State private var composing = false
    @State private var destructive: EmailRoute?
    @State private var replacing: EmailRoute?
    @State private var discarding = false
    @State private var revealed: String?
    @State private var copied: String?
    @State private var copyFailed = false
    @State private var reauthentication: AccountReauthentication?
    var body: some View {
        Group {
            if let model, model.current { management(model) }
            else { ContentUnavailableView("Sign in to capture email", systemImage: "envelope", description: Text("Email addresses belong to your synced account.")) }
        }
        .navigationTitle("Email to Taskfold")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth: 540, idealWidth: 620, minHeight: 480)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        #endif
        .task { await start() }
        .onChange(of: store.workspaceGeneration) { _, _ in leave() }
        .onChange(of: store.signingOut) { _, value in if value { leave() } }
        .onChange(of: store.accountRemovalBlocked) { _, value in if value { leave() } }
        .onChange(of: store.backend.reminderSessionIncarnation) { _, _ in
            if let context = reauthentication, store.backend.session?.user.id == context.account { return }; leave()
        }
        .onChange(of: phase) { _, value in revealed = nil; copied = nil; if value == .active { Task { await model?.load() } } }
        .onDisappear { model?.close(); model = nil; revealed = nil; copied = nil }
        .sheet(isPresented: $composing) { if let model { EmailCaptureComposer(model: model, projects: store.projects, sender: composerSender) } }
        .sheet(item: $reauthentication) { context in
            ConnectionSignInSheet(backend: store.backend, context: context, email: store.backend.session?.user.email ?? store.email) {
                guard store.backend.session?.user.id == context.account else { leave(); return }
                model?.close(); model = nil; reauthentication = nil; Task { await start() }
            }
        }
        .confirmationDialog("Revoke this address?", isPresented: Binding(get: { destructive != nil }, set: { if !$0 { destructive = nil } }), titleVisibility: .visible) {
            if let route = destructive { Button("Revoke address", role: .destructive) { destructive = nil; revealed = nil; Task { await model?.control("revoke", route: route) } } }
        } message: { Text("Future email to this address will be refused. Tasks already captured stay saved.") }
        .confirmationDialog("Replace this address?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), titleVisibility: .visible) {
            if let route = replacing { Button("Replace address", role: .destructive) { replacing = nil; revealed = nil; Task { await model?.control("rotate", route: route) } } }
        } message: { Text("A new private address will replace this one. The old address will stop accepting email. Update any forwarding rules after reviewing the new address.") }
        .confirmationDialog("Discard this setup?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard setup", role: .destructive) { Task { await model?.discardSetup() } }
        } message: { Text("The new address will be revoked even if setup reached the server while its reply was lost. A replacement may already have retired the old address.") }
        .privacySensitive()
        .overlay { if phase != .active { Rectangle().fill(.background).overlay { Label("Email to Taskfold", systemImage: "lock.fill").foregroundStyle(.secondary) } } }
    }
    private var composerSender: String {
        #if DEBUG
        if fixture && EmailCaptureFixture.enabled { return "workshop@example.invalid" }
        #endif
        return store.backend.session?.user.email ?? store.email
    }
    private func start() async {
        #if DEBUG
        if fixture && EmailCaptureFixture.enabled {
            guard model == nil else { return }; let value = EmailCaptureFixture.model(); model = value; await value.load(); return
        }
        #endif
        guard model == nil, EmailCaptureAvailability.enabled, store.signedIn, !store.localMode, !store.signingOut, !store.accountRemovalBlocked, let origin = try? store.backend.accountRemovalOrigin else { return }
        let binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), incarnation = store.backend.reminderSessionIncarnation
        let value = EmailCaptureModel(account: binding.account, origin: origin, service: store.backend, vault: store.emailAddressVault) {
            store.signedIn && !store.localMode && !store.signingOut && !store.accountRemovalBlocked && binding.matches(account: store.userID, generation: store.workspaceGeneration) && store.backend.reminderSessionIncarnation == incarnation
        }
        model = value; await value.load()
    }
    private func leave() { model?.close(); model = nil; revealed = nil; copied = nil; composing = false; reauthentication = nil }
    private func management(_ model: EmailCaptureModel) -> some View {
        Form {
            Section {
                Label("A quieter way to capture", systemImage: "envelope.badge").font(.headline)
                Text("Forward an email from your verified account address. Its subject becomes the task title, and its full plain text becomes the note.").foregroundStyle(.secondary)
                Text("Attachments are not imported. Email never sets dates, priority or assignment.").font(.callout).foregroundStyle(.secondary)
            }
            if !model.available {
                Section { Label("Email capture is not available yet", systemImage: "clock"); Text("Your tasks stay saved. Existing addresses can still be paused or revoked after refreshing their status.").font(.callout).foregroundStyle(.secondary) }
            }
            if let message = model.message {
                Section { Label(message, systemImage: "exclamationmark.circle").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("emailCaptureNotice")
                    if model.needsSignIn { Button("Sign in again") { reauthentication = try? store.backend.reauthenticationContext(account: model.account) } }
                }
            }
            if let pending = model.pending {
                Section("Unfinished change") {
                    Text(pending.action == "create" || pending.action == "rotate" ? "Your private setup is saved on this device. Retry to check whether the address was created." : "Retry the saved action to confirm its status.")
                    Button("Retry saved action") { Task { await model.retry() } }.accessibilityIdentifier("retryEmailSetup")
                    if pending.draft != nil { Button("Discard setup", role: .destructive) { discarding = true } }
                }
            }
            Section("Your addresses") {
                let routes = model.routes.filter { $0.state != "revoked" }
                if routes.isEmpty { Text("Keep your inbox moving").font(.headline); Text("Create a private address for Inbox or a project.").foregroundStyle(.secondary) }
                ForEach(routes) { route in addressRow(route, model) }
                Button { composing = true } label: { Label("New email address", systemImage: "plus") }
                    .disabled(!model.available || model.pending != nil || model.busy).accessibilityIdentifier("newEmailAddress")
            }
            Section { Button { revealed = nil; copied = nil; Task { await model.load() } } label: { Label("Refresh status", systemImage: "arrow.clockwise") }.disabled(model.busy) }
            Section { Text("Private addresses stay on this device and are excluded from Taskfold backups. On another device, replace an address if its private copy is unavailable. Changing your verified account email stops capture from the old sender.").font(.footnote).foregroundStyle(.secondary) }
        }
        .disabled(model.busy)
        .overlay { if model.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        .onChange(of: model.pending?.id) { _, _ in revealed = nil; copied = nil }
    }
    private func addressRow(_ route: EmailRoute, _ model: EmailCaptureModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(route.name).font(.headline); Spacer(); Text(route.state == "paused" ? "Paused" : "Active").font(.caption).foregroundStyle(.secondary) }
            Text(route.project.flatMap { id in store.projects.first { $0.id == id }?.name } ?? (route.project == nil ? "Inbox" : "Project unavailable")).font(.subheadline).foregroundStyle(.secondary)
            Text("From \(route.sender)").font(.caption).foregroundStyle(.secondary)
            if let address = model.address(for: route) {
                if revealed == route.id {
                    Text(address).font(.system(.footnote, design: .monospaced)).textSelection(.disabled).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Private email address revealed").accessibilityValue("Address concealed from speech")
                    Button(copied == route.id ? "Copied" : "Copy address") { copyFailed = !copy(address); copied = copyFailed ? nil : route.id }.accessibilityHint("Copies the private email address for one minute. It is not synced to other devices.")
                    if copyFailed { Text("Couldn’t copy the address. Try again.").font(.caption).foregroundStyle(.secondary) }
                    Button("Hide address") { revealed = nil; copied = nil }
                } else { Button("Show private address") { revealed = route.id; copied = nil } }
            } else if model.pending == nil { Text("Private address unavailable here. Replace it to create one on this device.").font(.caption).foregroundStyle(.secondary) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { routeControls(route, model) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 12) { routeControls(route, model) }
            }.disabled(model.pending != nil)
        }.padding(.vertical, 6).buttonStyle(.borderless)
    }
    @ViewBuilder private func routeControls(_ route: EmailRoute, _ model: EmailCaptureModel) -> some View {
                if route.state == "active" { Button("Pause") { revealed = nil; Task { await model.control("pause", route: route) } } }
                else { Button("Resume") { Task { await model.control("resume", route: route) } }.disabled(model.address(for: route) == nil) }
                Menu("Manage") { Button("Replace address…") { replacing = route }.disabled(!model.available); Button("Revoke address…", role: .destructive) { destructive = route } }
    }
    private func copy(_ address: String) -> Bool {
        #if os(iOS)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: address]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]); return true
        #else
        let board = NSPasteboard.general; board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem(); item.setString(address, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")); item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard board.writeObjects([item]) else { return false }; let change = board.changeCount
        Task { try? await Task.sleep(for: .seconds(60)); if board.changeCount == change { board.clearContents() } }; return true
        #endif
    }
}
private struct EmailCaptureComposer: View {
    let model: EmailCaptureModel
    let projects: [Record]
    let sender: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Email inbox"
    @State private var project = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Address") { TextField("Name", text: $name).accessibilityIdentifier("emailAddressName")
                    Picker("Destination", selection: $project) { Text("Inbox").tag(""); ForEach(projects) { Text($0.name).tag($0.id) } }
                }
                Section("Review") {
                    LabeledContent("Allowed sender", value: sender).accessibilityElement(children: .ignore).accessibilityLabel("Allowed sender").accessibilityValue(sender).accessibilityIdentifier("emailAllowedSender")
                    Text("Only your current verified Taskfold email can send tasks to this address.").font(.callout).foregroundStyle(.secondary)
                    Text("A private address will be created after confirmation. Its full text stays in this device’s secure storage.").font(.callout).foregroundStyle(.secondary)
                }
                if let message = model.message { Section { Text(message).foregroundStyle(.secondary) } }
            }
            .navigationTitle("New email address")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Create address") { Task { await model.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), project: project.isEmpty ? nil : project); if model.pending != nil || model.message == nil { dismiss() } } }.disabled(!WebhookValue.name(name.trimmingCharacters(in: .whitespacesAndNewlines)) || model.busy || !model.current || !model.available) }
            }
            .disabled(model.busy)
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 380)
            #endif
        }
        .interactiveDismissDisabled(model.busy)
        .privacySensitive()
    }
}

#if DEBUG
/// Exact isolated Simulator host only. No network, real account or task writes.
@MainActor enum EmailCaptureFixture {
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowtestswebhooks", "com.dbakp.taskfold.mac.workflowtestsp1"].contains(Bundle.main.bundleIdentifier ?? "") && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--email-capture-testing")
    }
    static func model() -> EmailCaptureModel {
        precondition(enabled)
        return EmailCaptureModel(account: "f0e1cafe-0000-4000-8000-000000000001", origin: "https://backend.example", service: EmailCaptureFixturePeer(), vault: EmailAddressVault(io: EmailCaptureFixtureMemory()), isCurrent: { true })
    }
}
private final class EmailCaptureFixtureMemory: CalendarSecureItemIO, @unchecked Sendable {
    private var rows: [String: Data] = [:]
    func read(key: String) throws -> Data? { rows[key] }
    func write(_ value: Data, key: String) throws { rows[key] = value }
    func remove(key: String) throws { rows.removeValue(forKey: key) }
}
@MainActor private final class EmailCaptureFixturePeer: EmailCaptureService {
    private var rows: [String: [String: JSON]] = [:]
    func emailRouteReceipt(action: String, body: [String: JSON], domain: String?, account: String, origin: String) async throws -> [String: JSON] {
        precondition(EmailCaptureFixture.enabled)
        if action == "list" { return ["account": .string(account), "available": .bool(true), "domain": .string("mail.example.invalid"), "routes": .array(rows.values.map(JSON.object))] }
        let id = body["id"]!.text
        func row(_ draft: [String: JSON]) -> [String: JSON] {
            ["id": draft["id"]!, "name": draft["name"]!, "project_id": draft["project_id"]!, "sender_email": .string("workshop@example.invalid"), "state": .string("active"), "revision": .number(1), "created_at": .string("2026-10-23T16:00:00Z"), "updated_at": .string("2026-10-23T16:00:00Z"), "accept_after": .string("2026-10-23T16:00:00Z"), "rotated_to": .null]
        }
        if action == "create", rows[id] == nil { rows[id] = row(body) }
        if action == "revoke", rows[id] == nil { return ["account": .string(account), "id": .string(id), "cancelled": .bool(true)] }
        if action == "rotate" {
            let draft = body["replacement"]!.object, replacementID = draft["id"]!.text
            rows[id]?["state"] = .string("revoked"); rows[id]?["rotated_to"] = .string(replacementID); rows[replacementID] = row(draft)
            return ["account": .string(account), "route": .object(rows[replacementID]!), "replaced": .object(rows[id]!)]
        }
        if ["pause", "resume", "revoke"].contains(action) { rows[id]?["state"] = .string(action == "pause" ? "paused" : action == "resume" ? "active" : "revoked"); rows[id]?["revision"] = .number(Double(body["revision"]!.integer + 1)) }
        guard let result = rows[id] else { throw EmailCaptureValue.invalid }
        return ["account": .string(account), "route": .object(result)]
    }
}
#endif
