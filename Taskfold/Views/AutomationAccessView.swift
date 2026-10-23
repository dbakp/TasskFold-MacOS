import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The release entry stays hidden until the matching gateway is ready. The
/// isolated route exercises the same production view, never a separate mock UI.
enum AutomationAccessAvailability {
    static var enabled: Bool {
        if Bundle.main.object(forInfoDictionaryKey: "TaskfoldAutomationEnabled") as? Bool == true { return true }
        #if DEBUG
        return ["com.dbakp.taskfold.workflowtestsp1", "com.dbakp.taskfold.mac.workflowtestsp1"].contains(Bundle.main.bundleIdentifier ?? "") &&
            ProcessInfo.processInfo.arguments.contains("--automation-management-testing")
        #else
        return false
        #endif
    }
}

struct AutomationAccessView: View {
    var fixture = false
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    #if DEBUG
    @State private var signInFixture: ConnectionReauthenticationFixture?
    #endif
    @State private var authenticationBackend: Backend?
    @State private var reauthentication: AccountReauthentication?
    @State private var restoredIncarnation: UUID?
    @State private var model: AutomationAccessModel?
    @State private var composing = false
    @State private var revoking: AutomationKey?
    @State private var discardSetup = false
    @State private var revealedID: String?
    @State private var copiedID: String?
    #if DEBUG
    @State private var clipboardProof = "Clipboard check not started"
    #endif
    var body: some View {
        Group {
            if let model, model.current {
                management(model)
            } else { ContentUnavailableView("Sign in to manage access", systemImage: "key", description: Text("Automation keys belong to your synced account.")) }
        }
        .navigationTitle("Automation access")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480)
        #endif
        .task { await startModel() }
        .onChange(of:store.accountRemovalBlocked) { _,blocked in if blocked { leave() } }
        .onChange(of:model?.confirmed?.id) { _,id in if id == nil { revealedID = nil; copiedID = nil } }
        .onChange(of:signInBackend.reminderSessionIncarnation) { _,value in sessionChanged(value) }
        .onChange(of: store.workspaceGeneration) { _, _ in leave() }
        .onChange(of: store.signingOut) { _, value in if value { leave() } }
        .onChange(of: phase) { _, value in
            revealedID = nil; copiedID = nil
            if value == .active { Task { await model?.refreshRecovery() } }
        }
        .onDisappear { model?.close(); model = nil; revealedID = nil }
        .sheet(item:$reauthentication,onDismiss:{ if model?.current == false { restoredSignIn() } }) { context in
            ConnectionSignInSheet(backend:signInBackend,context:context,email:signInBackend.session?.user.email ?? store.email) { restoredSignIn() }
        }
        .sheet(isPresented: $composing) {
            if let model { AutomationKeyComposer(model: model) }
        }
        .confirmationDialog("Revoke this key?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            if let key = revoking { Button("Revoke key", role: .destructive) { revoking = nil; Task { await model?.revoke(key) } } }
        } message: { Text("Tools using this key will lose access immediately. Your tasks stay unchanged.") }
        .confirmationDialog("Discard this key setup?", isPresented: $discardSetup, titleVisibility: .visible) {
            Button("Discard setup", role: .destructive) { Task { await model?.discardPending() } }
        } message: { Text("Any key from this setup will stop working, even if it was still being created. Your tasks stay unchanged.") }
        .privacySensitive()
        .overlay {
            if phase != .active { Rectangle().fill(.background).overlay { Label("Automation access", systemImage: "lock.fill").foregroundStyle(.secondary) } }
        }
    }
    private var clipboardNotice: String {
        #if os(macOS)
        return "Copied keys stay on this Mac. While Taskfold stays open, the clipboard clears after one minute unless you copy something else. Keys are not included in task exports or backups."
        #else
        return "Copying keeps the key on this device’s clipboard for up to one minute. It is not included in task exports or backups."
        #endif
    }
    private var signInBackend: Backend { authenticationBackend ?? store.backend }
    private func beginSignIn(account: String) {
        guard let context = try? signInBackend.reauthenticationContext(account:account) else { leave(); return }
        reauthentication = context
    }
    private func sessionChanged(_ incarnation: UUID) {
        if restoredIncarnation == incarnation { return }
        if let context = reauthentication, signInBackend.session?.user.id == context.account { return }
        leave()
    }
    private func restoredSignIn() {
        guard let account = model?.account, signInBackend.session?.user.id == account else { leave(); return }
        restoredIncarnation = signInBackend.reminderSessionIncarnation
        let workspace = WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration)
        model?.close(); model = nil; reauthentication = nil
        Task {
            await startModel()
            if !fixture { await store.resumeSyncAfterSignIn(workspace:workspace) }
        }
    }
    private func startModel() async {
            guard model == nil else { return }
            #if DEBUG
            if fixture && ConnectionReauthenticationFixture.enabled {
                do {
                    let source = try signInFixture ?? ConnectionReauthenticationFixture(); signInFixture = source
                    authenticationBackend = source.backend; restoredIncarnation = source.backend.reminderSessionIncarnation
                    let value = source.automationModel(); model = value; await value.load()
                } catch { /* The exact isolated fixture remains unavailable on failure. */ }
                return
            }
            #endif
            #if DEBUG
            if fixture && AutomationManagementFixture.enabled {
                do { let value = try await AutomationManagementFixture.makeModel(); model = value; await value.load() }
                catch { /* Secure-storage failure leaves the fixture unavailable. */ }
                return
            }
            #endif
            guard model == nil, store.signedIn, !store.localMode, !store.signingOut, !store.accountRemovalBlocked,
                  AutomationAccessAvailability.enabled, let origin = try? store.backend.accountRemovalOrigin else { return }
            authenticationBackend = store.backend; restoredIncarnation = store.backend.reminderSessionIncarnation
            let binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)
            let backendSession = store.backend.reminderSessionIncarnation
            let value = AutomationAccessModel(account: binding.account, origin: origin, service: store.backend, vault: store.automationEnrollmentVault) {
                store.signedIn && !store.localMode && !store.signingOut && !store.accountRemovalBlocked &&
                binding.matches(account: store.userID, generation: store.workspaceGeneration) && store.backend.reminderSessionIncarnation == backendSession
            }
            model = value; await value.load()
    }
    private func leave() { reauthentication = nil; model?.close(); composing = false; revoking = nil; discardSetup = false; revealedID = nil; dismiss() }
    private func management(_ model: AutomationAccessModel) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "key.horizontal.fill").font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Your tools. Your permissions.").font(.title2.bold())
                    Text("Connect trusted tools to Taskfold with their own expiring keys. Choose exactly what each one can do, and revoke access whenever you like.").foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            if let message = model.message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityIdentifier("automationNotice")
                    if model.needsSignIn { Button("Sign in again") { beginSignIn(account:model.account) }.accessibilityIdentifier("connectionSignIn") }
                    Button("Try again") { Task { await model.load(includeInactive: model.includesInactive) } }
                }
            }
            if let draft = model.pending {
                Section {
                    LabeledContent("Name", value: draft.name)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permissions").font(.caption).foregroundStyle(.secondary)
                        Text(draft.scopes.map(\.title).joined(separator: " · ")).fixedSize(horizontal: false, vertical: true)
                    }
                    if let key = model.confirmed { LabeledContent("Expires", value: key.expires.formatted(date: .abbreviated, time: .shortened)) }
                    else { LabeledContent("Requested lifetime", value: "\(draft.days) days") }
                    if model.secret != nil {
                        Text("Save your key somewhere safe").font(.headline)
                        Text("This is your only chance to copy it. Taskfold cannot show it again after you finish setup.").foregroundStyle(.secondary)
                        if revealedID == draft.id, phase == .active, let secret = model.secret {
                            Text(verbatim: secret).font(.system(.caption, design: .monospaced))
                                .accessibilityLabel("Automation key, " + secret).accessibilityIdentifier("automationRevealedSecret")
                        } else {
                            Text("•••• •••• •••• ••••").font(.system(.body, design: .monospaced)).accessibilityLabel("Key hidden")
                        }
                        HStack {
                            Button(revealedID == draft.id ? "Hide key" : "Reveal key", systemImage: revealedID == draft.id ? "eye.slash" : "eye") { revealedID = revealedID == draft.id ? nil : draft.id }
                                .accessibilityIdentifier("automationReveal")
                            Spacer()
                            Button(copiedID == draft.id ? "Copied" : "Copy key", systemImage: copiedID == draft.id ? "checkmark" : "document.on.document") {
                                guard phase == .active, let secret = model.secret else { return }
                                copiedID = AutomationSecretClipboard.copy(secret) ? draft.id : nil
                                #if DEBUG
                                if copiedID != nil, fixture, AutomationManagementFixture.clipboardTesting {
                                    clipboardProof = "Checking clipboard expiry"
                                    Task { clipboardProof = await AutomationManagementFixture.checkClipboard(secret: secret) }
                                }
                                #endif
                            }.accessibilityIdentifier("automationCopy")
                        }.buttonStyle(.borderless)
                        #if DEBUG
                        if fixture, AutomationManagementFixture.clipboardTesting {
                            Text(clipboardProof).accessibilityIdentifier("automationClipboardProof")
                        }
                        #endif
                        Button("I’ve saved my key", systemImage: "checkmark.shield") {
                            revealedID = nil; copiedID = nil; Task { await model.acknowledgeSaved() }
                        }.accessibilityIdentifier("automationFinish")
                    } else {
                        Text(model.discarding ? "Discard setup needs attention" : "Key setup needs attention").font(.headline)
                        Text(model.discarding ? "Your discard request is saved on this device. Retry to finish; this setup won’t create another key." : "Continue with the same key to confirm whether it was created. Closing this screen keeps setup secure on this device.").foregroundStyle(.secondary)
                        Button(model.discarding ? "Retry discard" : "Continue setup", systemImage: "arrow.clockwise") { Task { await model.resume() } }.accessibilityIdentifier("automationResume")
                    }
                    if !model.discarding {
                        Button("Discard setup", role: .destructive) { discardSetup = true }.accessibilityIdentifier("automationDiscardSetup")
                    }
                } header: { Text("Finish setup") } footer: {
                    Text(model.secret != nil ? clipboardNotice : model.discarding ? "This request stays safely saved until discard is confirmed." : "Closing this screen keeps setup secure on this device.")
                }
            }
            Section {
                Toggle("Show expired and revoked keys", isOn: Binding(get: { model.includesInactive }, set: { value in model.selectHistory(value); Task { await model.load(includeInactive: value) } }))
                    .accessibilityIdentifier("automationHistory")
                if model.loaded && model.keys.isEmpty {
                    Label(model.includesInactive ? "No keys yet" : "No active keys", systemImage: "key.slash").foregroundStyle(.secondary)
                }
                ForEach(model.keys) { key in keyRow(key, model: model) }
                if model.nextCursor != nil {
                    Button("Load more keys") { Task { await model.load(includeInactive: model.includesInactive, more: true) } }.accessibilityIdentifier("automationMore")
                }
                Button("Create a key", systemImage: "plus") { composing = true }
                    .disabled(!model.loaded || model.pending != nil).accessibilityIdentifier("automationCreate")
            } header: { Text("Connected tools") } footer: { Text("Signing out does not revoke these keys. Only share a key with a tool you trust to use its permissions.") }
            if model.busy { Section { ProgressView("Updating access…").accessibilityIdentifier("automationProgress") } }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load(includeInactive: model.includesInactive) } }.disabled(model.busy)
            }
            #if os(macOS)
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            #endif
        }
    }
    private func keyRow(_ key: AutomationKey, model: AutomationAccessModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(key.name).font(.headline)
                Spacer()
                Text(key.revoked != nil ? "Revoked" : key.active(at: Date()) ? "Active" : "Expired")
                    .font(.caption.weight(.medium)).foregroundStyle(key.active(at: Date()) ? Color.accentColor : Color.secondary)
            }
            Text(key.scopes.map(\.title).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            Text("Expires " + key.expires.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            if let used = key.lastUsed { Text("Last used " + used.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            if key.revoked == nil {
                Button("Revoke key", role: .destructive) { revoking = key }.accessibilityIdentifier("automationRevoke-" + key.id)
            }
        }.padding(.vertical, 5)
    }
}

private struct AutomationKeyComposer: View {
    let model: AutomationAccessModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scopes: Set<AutomationScope> = [.read]
    @State private var days = 30
    @FocusState private var nameFocused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tool name", text: $name).focused($nameFocused).onSubmit { nameFocused = false }.accessibilityIdentifier("automationName")
                    Picker("Expires after", selection: $days) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                    }
                } header: { Text("Identify your tool") } footer: { Text("Give each tool its own key so you can revoke it separately.") }
                Section {
                    ForEach(AutomationScope.allCases, id: \.self) { scope in
                        Toggle(isOn: Binding(get: { scopes.contains(scope) }, set: { value in if value { scopes.insert(scope) } else { scopes.remove(scope) } })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(scope.title)
                                Text(scope.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("automationScope-" + scope.rawValue)
                    }
                } header: { Text("Permissions") } footer: { Text("These permissions apply to the account’s accessible tasks, including shared projects. Grant only what this tool needs.") }
                if scopes.contains(.delete) {
                    Section { Label("This tool can permanently delete tasks and reviewed linked occurrences.", systemImage: "trash").foregroundStyle(.red) }
                }
                if let message = model.message { Section { Text(message).foregroundStyle(.secondary) } }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle("Create a key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create key") { Task { await model.create(name: name, scopes: scopes, days: days); if model.pending != nil { dismiss() } } }
                        .disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scopes.isEmpty)
                        .accessibilityIdentifier("automationConfirmCreate")
                }
            }
            .interactiveDismissDisabled(model.busy)
            .task { nameFocused = true }
        }
        #if os(macOS)
        .frame(width: 560, height: 620)
        #endif
    }
}

@MainActor private enum AutomationSecretClipboard {
    static func copy(_ secret: String) -> Bool {
        #if os(iOS)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        return true
        #else
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard board.writeObjects([item]) else { return false }
        let revision = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if board.changeCount == revision { board.clearContents() }
        }
        return true
        #endif
    }
}

#if DEBUG
/// Synthetic native acceptance only: exact disposable hosts, local protocol
/// interception, app-only Keychain and an owned metadata file. No live requests.
@MainActor enum AutomationManagementFixture {
    static let account = "f096cafe-1111-4111-8111-000000000001"
    static var enabled: Bool {
        if ConnectionReauthenticationFixture.enabled && ProcessInfo.processInfo.arguments.contains("--automation-management-fixture") { return true }

        return AutomationAccessAvailability.enabled && ProcessInfo.processInfo.arguments.contains("--uitesting") &&
            UserDefaults.standard.bool(forKey: "localMode") && !ProcessInfo.processInfo.arguments.contains("--live-auth-ui-test") &&
            ProcessInfo.processInfo.arguments.contains("--automation-management-fixture") &&
            ["com.dbakp.taskfold.workflowtestsp1", "com.dbakp.taskfold.mac.workflowtestsp1"].contains(Bundle.main.bundleIdentifier ?? "")
    }
    static var clipboardTesting: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--automation-clipboard-testing") }
    /// Real system pasteboard observation, restricted to the synthetic local host.
    /// Only a fixed result reaches accessibility; no secret or clipboard text is exported.
    static func checkClipboard(secret: String) async -> String {
        guard clipboardTesting else { return "Clipboard check unavailable" }
        #if os(iOS)
        let initial = UIPasteboard.general.string
        #else
        let initial = NSPasteboard.general.string(forType: .string)
        #endif
        guard initial == secret else { return "Clipboard copy failed" }
        let replace = ProcessInfo.processInfo.arguments.contains("--automation-clipboard-replace")
        let sample = "Synthetic Taskfold clipboard replacement " + UUID().uuidString
        if replace {
            #if os(iOS)
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: sample]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
            #else
            NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
            guard NSPasteboard.general.setString(sample, forType: .string) else { return "Clipboard replacement failed" }
            #endif
        }
        do { try await Task.sleep(for: .seconds(62)) }
        catch { return "Clipboard check cancelled" }
        #if os(iOS)
        let value = UIPasteboard.general.string
        #else
        let value = NSPasteboard.general.string(forType: .string)
        #endif
        if replace {
            guard value == sample else { return "New clipboard content was lost" }
            // Clear only this probe's own synthetic sample after observing it.
            #if os(iOS)
            UIPasteboard.general.items = []
            #else
            NSPasteboard.general.clearContents()
            #endif
            return "New clipboard content preserved"
        }
        return value == nil ? "Copied key expired" : "Copied key did not expire"
    }
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("AutomationManagementFixture", isDirectory: true) }
    static func makeModel() async throws -> AutomationAccessModel {
        precondition(enabled)
        let vault = AutomationEnrollmentVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "") + ".automation-fixture"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("AutomationEnrollmentFixtureLocks", isDirectory: true))
        if ProcessInfo.processInfo.arguments.contains("--automation-management-reset") {
            try await vault.removeAccount(account, origin: "https://automation-management.test")
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AutomationManagementHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: ["access_token": "synthetic-enrollment", "refresh_token": "synthetic-refresh", "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970, "user": ["id": account, "email": "automation-fixture@example.invalid"]]))
        let backend = Backend(configuration: ["URL": "https://automation-management.test", "Key": "synthetic-public"], http: URLSession(configuration: config), session: session)
        return AutomationAccessModel(account: account, origin: "https://automation-management.test", service: backend, vault: vault, isCurrent: { true })
    }
}
private final class AutomationManagementHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            guard ["com.dbakp.taskfold.workflowtestsp1", "com.dbakp.taskfold.mac.workflowtestsp1"].contains(Bundle.main.bundleIdentifier ?? ""),
                  ProcessInfo.processInfo.arguments.contains("--automation-management-fixture"),
                  request.url?.absoluteString == "https://automation-management.test/functions/v1/automation-keys", request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-enrollment" else { throw URLError(.unsupportedURL) }
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let size = stream.read(&buffer, maxLength: buffer.count)
                    guard size >= 0, result.count + size <= 8192 else { throw AutomationKey.invalid }
                    if size == 0 { break }; result.append(buffer, count: size)
                }
                data = result
            }
            guard let data, let input = try? JSONDecoder().decode([String: JSON].self, from: data), case .object(let body) = input["body"] else { throw AutomationKey.invalid }
            let root = URL.applicationSupportDirectory.appendingPathComponent("AutomationManagementFixture", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("metadata.json")
            var state = (try? JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: file))) ?? [:]
            var rows: [[String: JSON]] = state["keys"]?.list.compactMap { value -> [String: JSON]? in if case .object(let row) = value { return row }; return nil } ?? []
            let action = input["action"]?.text ?? ""
            let account = "f096cafe-1111-4111-8111-000000000001"
            var result: [String: JSON] = ["account": .string(account)]
            let format = ISO8601DateFormatter(), now = Date()
            if action == "list" {
                state["last_list_inactive"] = body["include_inactive"]
                let visible = rows.filter { body["include_inactive"] == .bool(true) || $0["revoked_at"] == .null }
                result["keys"] = .array(visible.map { .object($0.filter { $0.key != "token_hash" }) }); result["next_cursor"] = .null
            } else if action == "cancel" {
                state["cancel_attempts"] = .number(Double((state["cancel_attempts"]?.integer ?? 0) + 1))
                guard let id = body["id"]?.text, AutomationKey.canonicalID(id) else { throw AutomationKey.invalid }
                var cancelled = state["cancelled_ids"]?.list ?? []
                if !cancelled.contains(.string(id)) { cancelled.append(.string(id)) }
                state["cancelled_ids"] = .array(cancelled)
                if let index = rows.firstIndex(where: { $0["id"] == .string(id) }) { rows[index]["revoked_at"] = .string(format.string(from: now)) }
                result["id"] = .string(id); result["cancelled"] = .bool(true)
            } else if action == "create" {
                state["create_attempts"] = .number(Double((state["create_attempts"]?.integer ?? 0) + 1))
                if ProcessInfo.processInfo.arguments.contains("--automation-management-fail-before-create") {
                    try JSONEncoder().encode(state).write(to: file, options: .atomic)
                    throw URLError(.notConnectedToInternet)
                }
                let id = body["id"]?.text ?? ""
                guard AutomationKey.canonicalID(id), body["token_hash"]?.text.count == 64 else { throw AutomationKey.invalid }
                guard !(state["cancelled_ids"]?.list.contains(.string(id)) ?? false) else { throw AutomationKey.invalid }
                if let old = rows.first(where: { $0["id"] == .string(id) }) {
                    guard old["token_hash"] == body["token_hash"] else { throw AutomationKey.invalid }
                    result["key"] = .object(old.filter { $0.key != "token_hash" })
                } else {
                    let days: Double
                    if case .number(let value) = body["ttl_days"] { days = value } else { days = 30 }
                    let row: [String: JSON] = ["id": .string(id), "name": body["name"] ?? .string("Tool"), "prefix": .string("tfk_v1_" + id.replacingOccurrences(of: "-", with: "").prefix(8)), "scopes": body["scopes"] ?? .array([]), "created_at": .string(format.string(from: now)), "expires_at": .string(format.string(from: now.addingTimeInterval(Double(days) * 86400))), "revoked_at": .null, "last_used_at": .null, "token_hash": body["token_hash"]!]
                    rows.append(row); result["key"] = .object(row.filter { $0.key != "token_hash" })
                }
            } else if action == "revoke", let index = rows.firstIndex(where: { $0["id"] == body["id"] }) {
                rows[index]["revoked_at"] = .string(format.string(from: now)); result["key"] = .object(rows[index].filter { $0.key != "token_hash" })
            } else { throw AutomationKey.invalid }
            state["keys"] = .array(rows.map { .object($0) })
            let lost = action == "create" && ProcessInfo.processInfo.arguments.contains("--automation-management-lose-reply") && state["lost_reply"] != .bool(true)
            if lost { state["lost_reply"] = .bool(true) }
            let lostCancel = action == "cancel" && ProcessInfo.processInfo.arguments.contains("--automation-management-discard-lost-reply") && state["lost_cancel_reply"] != .bool(true)
            if lostCancel { state["lost_cancel_reply"] = .bool(true) }
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            if lost || lostCancel { throw URLError(.networkConnectionLost) }
            let reply = try JSONEncoder().encode(result)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
#endif
