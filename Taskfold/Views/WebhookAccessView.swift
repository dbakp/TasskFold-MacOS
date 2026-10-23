import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum WebhookAccessAvailability {
    static var enabled: Bool {
        if Bundle.main.object(forInfoDictionaryKey:"TaskfoldWebhooksEnabled") as? Bool == true { return true }
        #if DEBUG
        return ["com.dbakp.taskfold.workflowtestsp1","com.dbakp.taskfold.workflowtestswebhooks","com.dbakp.taskfold.mac.workflowtestsp1"].contains(Bundle.main.bundleIdentifier ?? "") && ProcessInfo.processInfo.arguments.contains("--webhook-management-testing")
        #else
        return false
        #endif
    }
}
struct WebhookAccessView: View {
    var fixture = false
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var model: WebhookAccessModel?
    @State private var composing = false
    @State private var selected: WebhookConnection?
    @State private var revoking: WebhookConnection?
    @State private var discard = false
    @State private var revealed = false
    @State private var copied = false
    var body: some View {
        Group {
            if let model, model.current { management(model) }
            else { ContentUnavailableView("Sign in to connect a receiver",systemImage:"arrow.triangle.branch",description:Text("Connections belong to your synced account.")) }
        }
        .navigationTitle("Task connections")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth:560,idealWidth:660,minHeight:500)
        #endif
        .task {
            #if DEBUG
            if fixture && WebhookManagementFixture.enabled { let value = WebhookManagementFixture.makeModel(); model = value; await value.load(); return }
            #endif
            guard model == nil, WebhookAccessAvailability.enabled, store.signedIn, !store.localMode, !store.signingOut, !store.accountRemovalBlocked,
                  let origin = try? store.backend.accountRemovalOrigin else { return }
            let binding = WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration), session = store.backend.reminderSessionIncarnation
            let value = WebhookAccessModel(account:binding.account,origin:origin,service:store.backend,vault:store.webhookEnrollmentVault) {
                store.signedIn && !store.localMode && !store.signingOut && !store.accountRemovalBlocked && binding.matches(account:store.userID,generation:store.workspaceGeneration) && store.backend.reminderSessionIncarnation == session
            }
            model = value; await value.load()
        }
        .onChange(of:store.workspaceGeneration) { _,_ in leave() }
        .onChange(of:store.backend.reminderSessionIncarnation) { _,_ in leave() }
        .onChange(of:store.signingOut) { _,v in if v { leave() } }
        .onChange(of:phase) { _,v in revealed = false; copied = false; model?.conceal(); if v == .active { Task { await model?.load() } } }
        .onDisappear { model?.close(); model = nil; revealed = false; copied = false }
        .sheet(isPresented:$composing) { if let model { WebhookComposer(model:model,projects:store.projects) } }
        .sheet(item:$selected) { c in if let model { WebhookHistoryView(model:model,connection:c) } }
        .confirmationDialog("Revoke this connection?",isPresented:Binding(get:{revoking != nil},set:{if !$0 { revoking = nil }}),titleVisibility:.visible) {
            if let c = revoking { Button("Revoke connection",role:.destructive) { revoking = nil; Task { await model?.control("revoke",connection:c) } } }
        } message: { Text("Future delivery will stop and queued task content will be erased. A request already sent cannot be recalled. Your tasks stay saved.") }
        .confirmationDialog("Discard this setup?",isPresented:$discard,titleVisibility:.visible) {
            Button("Discard setup",role:.destructive) { revealed = false; Task { await model?.discard() } }
        } message: { Text("The receiver will be disabled even if setup reached the server while its reply was lost.") }
        .privacySensitive()
        .overlay { if phase != .active { Rectangle().fill(.background).overlay { Label("Task connections",systemImage:"lock.fill").foregroundStyle(.secondary) } } }
    }
    private func leave() { model?.close(); composing = false; selected = nil; revoking = nil; dismiss() }
    private func management(_ model: WebhookAccessModel) -> some View {
        ScrollViewReader { proxy in
        Form {
            Section {
                VStack(alignment:.leading,spacing:10) {
                    Image(systemName:"arrow.triangle.branch").font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Keep your tools in step.").font(.title2.bold())
                    Text("Send task changes to a trusted receiver. Choose its reach, verify the connection, and see how delivery is doing.").foregroundStyle(.secondary)
                }.padding(.vertical,8)
            }
            if let notice = model.message { Section { Label(notice,systemImage:"exclamationmark.circle").fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("webhookNotice") } }
            if let action = model.uncertainAction {
                Section("Action awaiting confirmation") {
                    Text("\(actionTitle(action)) was not confirmed. Retry the same request, or reload the server’s current status before choosing another action.")
                    Button("Retry same action") { Task { await model.retryControl() } }
                    Button("Reload current status") { Task { await model.load(includeInactive:true) } }
                }
            }
            if let p = model.pending {
                Section(p.cancelling ? "Discard in progress" : "Finish your connection") {
                    LabeledContent("Name",value:p.draft.name)
                    Text(p.draft.endpoint).textSelection(.enabled).font(.callout).fixedSize(horizontal:false,vertical:true)
                    Text(scopeTitle(p.draft.scope)).foregroundStyle(.secondary)
                    if let secret = model.secret, !p.cancelling {
                        Text("Save the receiver secret").font(.headline)
                        Text("Configure this secret at your receiver. It proves ownership and checks signed deliveries. You cannot retrieve it after finishing this review.").foregroundStyle(.secondary)
                        if revealed { Text(secret).font(.system(.callout,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("webhookSecret") }
                        else { Text("•••• •••• •••• ••••").accessibilityLabel("Receiver secret hidden") }
                        HStack {
                            Button(revealed ? "Hide secret" : "Reveal secret") { revealed.toggle() }.accessibilityIdentifier("webhookReveal")
                            Spacer()
                            Button(copied ? "Copied" : "Copy secret") { if phase == .active, let current = model.secret { copied = WebhookClipboard.copy(current) } }.accessibilityIdentifier("webhookCopy")
                        }
                        Text("Copy stays on this device. The clipboard expires after one minute while Taskfold is open unless you copy something else.").font(.caption).foregroundStyle(.secondary)
                        Button("I’ve saved the secret") { revealed = false; copied = false; Task { await model.acknowledgeSaved() } }.accessibilityIdentifier("webhookAcknowledge")
                    } else {
                        Text(p.cancelling ? "Retry discard to finish disabling the receiver." : "Your private setup is saved on this device. Continue with the same settings after an interrupted request.").foregroundStyle(.secondary)
                        Button(p.cancelling ? "Retry discard" : "Continue setup") { Task { await model.resumeSetup() } }.accessibilityIdentifier("webhookContinue")
                    }
                    Button("Discard setup",role:.destructive) { discard = true }
                }.id("webhookPending")
            }
            Section {
                if model.connections.isEmpty && !model.busy { ContentUnavailableView("Your tools, connected",systemImage:"link",description:Text("Add a receiver when you’re ready to automate a workflow.")) }
                ForEach(model.connections) { c in connectionRow(c,model:model).id(c.id) }
                if model.nextCursor != nil { Button("Load more connections") { Task { await model.load(more:true) } } }
                Button("Add connection",systemImage:"plus") { composing = true }.disabled(model.pending != nil || model.uncertainAction != nil).accessibilityIdentifier("webhookAdd")
            } header: { Text("Connections") } footer: { Text("Delivered and failed totals are cumulative. Delivery is bounded and may repeat a request after an interrupted acknowledgement. Trusted receivers must verify signatures and handle duplicate and multipart events.") }
            Section {
                Toggle("Show expired and revoked",isOn:Binding(get:{model.includesInactive},set:{v in Task { await model.load(includeInactive:v) }}))
                Button("Reload connections",systemImage:"arrow.clockwise") { Task { await model.load() } }
                if model.busy { ProgressView("Confirming…") }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
        .onChange(of:model.pending?.draft.id) { old,new in
            Task { @MainActor in
                await Task.yield()
                guard model.current, model.pending?.draft.id == new else { return }
                if new != nil { proxy.scrollTo("webhookPending",anchor:.top) }
                else if let old, model.connections.contains(where:{$0.id == old}) { proxy.scrollTo(old,anchor:.top) }
            }
        }
        }
    }
    private func connectionRow(_ c: WebhookConnection,model:WebhookAccessModel) -> some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline) { Text(c.name).font(.headline); Spacer(); Text(c.state.capitalized).font(.caption).foregroundStyle(c.state == "active" ? Color.accentColor : .secondary) }
            Text(c.origin).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(scopeTitle(c.scope) + " · " + c.events.map(\.title).joined(separator:" · ")).font(.caption).fixedSize(horizontal:false,vertical:true)
            Text("Expires \(c.expires.formatted(date:.abbreviated,time:.omitted))").font(.caption).foregroundStyle(.secondary)
            Text("\(c.delivery.pending) waiting · \(c.delivery.delivered) delivered · \(c.delivery.failed) failed").font(.callout).monospacedDigit()
            if let recovery = c.delivery.recovery { Label(recovery,systemImage:"exclamationmark.circle").font(.callout).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("webhookRecovery") }
            HStack {
                Button("Delivery history") { selected = c }
                if c.usable {
                    if c.state == "pending" { Button("Verify receiver") { Task { await model.control("verify",connection:c) } }.accessibilityIdentifier("webhookVerify") }
                    else { Button(c.state == "paused" || c.delivery.blocked != nil ? "Resume" : "Pause") { Task { await model.control(c.state == "paused" || c.delivery.blocked != nil ? "resume" : "pause",connection:c) } } }
                    Button("Revoke",role:.destructive) { revoking = c }
                }
            }.buttonStyle(.borderless).disabled(model.uncertainAction != nil)
        }.padding(.vertical,6)
    }
    private func scopeTitle(_ scope:String) -> String { switch scope { case "all":"All accessible tasks"; case "project":"Selected project"; default:"Inbox only" } }
    private func actionTitle(_ action:String) -> String { switch action { case "retry_delivery":"Delivery retry"; case "verify":"Receiver verification"; default:action.capitalized } }
}
private struct WebhookComposer: View {
    let model: WebhookAccessModel
    let projects: [Record]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var name = ""
    @State private var endpoint = ""
    @State private var scope = "inbox"
    @State private var project = ""
    @State private var events = Set(WebhookEvent.allCases)
    @State private var days = 30
    @State private var understood = false
    private enum Field: Hashable { case name, address }
    @FocusState private var editing: Field?
    var body: some View {
        NavigationStack {
            Form {
                Section("Receiver") {
                    TextField("Name",text:$name).focused($editing,equals:.name).onSubmit { editing = .address }.accessibilityIdentifier("webhookName")
                    TextField("HTTPS address",text:$endpoint).textContentType(.URL).autocorrectionDisabled()
                        .focused($editing,equals:.address).onSubmit { editing = nil }
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL).submitLabel(.done)
                        #endif
                        .accessibilityIdentifier("webhookEndpoint")
                    Text("Use a receiver you control. Taskfold checks its public address and requires proof that it holds your receiver secret.").font(.callout).foregroundStyle(.secondary)
                }
                Section("Reach") {
                    Picker("Tasks",selection:$scope) { Text("Inbox only").tag("inbox"); Text("One project").tag("project"); Text("All accessible tasks").tag("all") }
                    if scope == "project" { Picker("Project",selection:$project) { Text("Choose project").tag(""); ForEach(projects) { p in Text(p.name).tag(p.id) } } }
                    ForEach(WebhookEvent.allCases,id:\.self) { event in Toggle(event.title,isOn:Binding(get:{events.contains(event)},set:{if $0 { events.insert(event) } else { events.remove(event) }})) }
                    Picker("Expires after",selection:$days) { Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365) }
                }
                Section {
                    Toggle("I trust this receiver with task content",isOn:$understood).accessibilityIdentifier("webhookTrust")
                    Text("Selected changes include task titles, full notes and checklists. All accessible tasks also includes shared projects you can read, including projects you join later. Each project scope covers only that project. Deleted or moved-out tasks send only identity information. Pausing stops delivery while retaining a bounded queue for up to 24 hours.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if let message = model.message { Section { Text(message).foregroundStyle(.secondary) } }
            }.formStyle(.grouped)
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement:.confirmationAction) { Button("Create") { Task { await model.create(name:name,endpoint:endpoint,scope:scope,project:scope == "project" ? project : nil,events:events,days:days); if model.pending != nil { dismiss() } } }.disabled(model.busy || !understood || !WebhookValue.name(name.trimmingCharacters(in:.whitespacesAndNewlines)) || !WebhookValue.endpoint(endpoint.trimmingCharacters(in:.whitespacesAndNewlines)) || events.isEmpty || scope == "project" && project.isEmpty).accessibilityIdentifier("webhookCreate") }
            }
        }
        #if os(macOS)
        .frame(minWidth:540,idealWidth:620,minHeight:560)
        #endif
        .interactiveDismissDisabled(model.busy)
        .privacySensitive()
        .overlay { if phase != .active || !model.current { Rectangle().fill(.background).overlay { Label("Task connections",systemImage:"lock.fill").foregroundStyle(.secondary) } } }
    }
}
private struct WebhookHistoryView: View {
    let model: WebhookAccessModel
    let connection: WebhookConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var retry: WebhookHistoryEvent?
    private var current: WebhookConnection { model.connections.first{$0.id == connection.id} ?? connection }
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Delivery records expire after seven days. Payloads expire after 24 hours. A failed part can be retried up to three times without changing its identity.").foregroundStyle(.secondary) }
                if let message = model.message { Section { Text(message) } }
                if let recovery = current.delivery.recovery { Section { Label(recovery,systemImage:"exclamationmark.circle") } }
                if model.historyID == connection.id {
                    if model.history.isEmpty { ContentUnavailableView("No delivery records",systemImage:"tray",description:Text("New changes appear here after this receiver is verified.")) }
                    ForEach(model.history) { event in
                        VStack(alignment:.leading,spacing:8) {
                            HStack { Text(WebhookEvent(rawValue:event.type)?.title ?? "Removed from scope").font(.headline); Spacer(); Text(event.status.capitalized).foregroundStyle(.secondary) }
                            Text(event.created.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                            Text("\(event.partsDelivered) of \(event.parts) parts · \(event.attempts) attempts").font(.caption).monospacedDigit()
                            if let error = event.error { Text("Last issue: " + errorTitle(error)).font(.callout).foregroundStyle(.secondary) }
                            DisclosureGroup("Reference") {
                                Text("Event: " + event.id).textSelection(.enabled).font(.system(.caption,design:.monospaced)).fixedSize(horizontal:false,vertical:true)
                                Text("Task: " + event.taskID).textSelection(.enabled).font(.system(.caption,design:.monospaced)).fixedSize(horizontal:false,vertical:true)
                            }
                            if event.retryable { Button("Retry delivery") { retry = event }.disabled(model.busy || model.uncertainAction != nil || current.state != "active" || current.delivery.blocked != nil) }
                        }.padding(.vertical,4)
                    }
                    if model.historyCursor != nil { Button("Load older records") { Task { await model.loadHistory(current,more:true) } } }
                }
                if model.uncertainAction != nil { Button("Retry same action") { Task { await model.retryControl() } } }
                Button("Reload history") { Task { await model.loadHistory(current) } }.disabled(model.busy)
                if model.busy { ProgressView("Loading…") }
            }
            .navigationTitle("Delivery history")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.loadHistory(connection) }
            .confirmationDialog("Retry this delivery?",isPresented:Binding(get:{retry != nil},set:{if !$0 { retry = nil }}),titleVisibility:.visible) {
                if let event = retry { Button("Retry delivery") { retry = nil; Task { await model.control("retry_delivery",connection:current,event:event) } } }
            } message: { Text("This resends the same saved event or unfinished parts. Check your receiver before retrying; it may have accepted an earlier request whose reply was lost.") }
        }
        #if os(macOS)
        .frame(minWidth:540,idealWidth:640,minHeight:500)
        #endif
        .privacySensitive()
        .overlay { if phase != .active || !model.current { Rectangle().fill(.background).overlay { Label("Delivery history",systemImage:"lock.fill").foregroundStyle(.secondary) } } }
    }
    private func errorTitle(_ value:String) -> String { switch value { case "attempts_exhausted":"Automatic retries were exhausted."; case "temporary":"The receiver could not confirm delivery."; case "gone":"The receiver is no longer available."; case "refused":"The receiver refused delivery."; case "expired":"The saved event expired."; case "configuration":"Secure delivery configuration is unavailable."; case "quota":"Waiting for sending allowance."; default:"The original account, task or connection is no longer available." } }
}
@MainActor private enum WebhookClipboard {
    static func copy(_ secret:String) -> Bool {
        #if os(iOS)
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic:secret]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(60)]); return true
        #else
        let board = NSPasteboard.general; board.prepareForNewContents(with:.currentHostOnly)
        let item = NSPasteboardItem(); item.setString(secret,forType:.string); item.setString("",forType:NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")); item.setString("",forType:NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard board.writeObjects([item]) else { return false }; let revision = board.changeCount
        Task { @MainActor in try? await Task.sleep(for:.seconds(60)); if board.changeCount == revision { board.clearContents() } }; return true
        #endif
    }
}

#if DEBUG
/// Exact isolated host only. This exercises the production view/model with
/// synthetic service responses, not hosted integration or Keychain acceptance.
@MainActor enum WebhookManagementFixture {
    static var enabled: Bool { WebhookAccessAvailability.enabled && ProcessInfo.processInfo.arguments.contains("--uitesting") && UserDefaults.standard.bool(forKey:"localMode") && !ProcessInfo.processInfo.arguments.contains("--live-auth-ui-test") }
    static func makeModel() -> WebhookAccessModel { WebhookAccessModel(account:WebhookFixtureService.account,origin:"https://backend.example",service:WebhookFixtureService(),vault:WebhookEnrollmentVault(io:WebhookFixtureMemory()),isCurrent:{true}) }
}
private final class WebhookFixtureMemory: CalendarSecureItemIO, @unchecked Sendable {
    private var bytes: [String:Data] = [:]
    func read(key:String) throws -> Data? { bytes[key] }
    func write(_ data:Data,key:String) throws { bytes[key] = data }
    func remove(key:String) throws { bytes.removeValue(forKey:key) }
}
@MainActor private final class WebhookFixtureService: WebhookService {
    static let account = "f0b2cafe-0000-4000-8000-000000000001"
    private let existing = "f0b2cafe-0000-4000-8000-000000000021"
    private let eventID = "f0b2cafe-0000-4000-8000-000000000031"
    private var rows: [String:[String:JSON]] = [:]
    private var retried = false
    init() { var row = subscription(id:existing,name:"Design handoff",origin:"https://receiver.example",scope:"inbox",project:.null,events:[.string("task.created")],days:30);row["state"] = .string("active");rows[existing] = row }
    private func delivery(_ warning:Bool) -> JSON { .object(["version":.number(1),"pending":.number(retried ? 1 : 0),"retained_bytes":.number(200),"missed":.number(warning ? 3 : 0),"capture_issue":warning ? .string("event_quota") : .null,"missed_since":.null,"missed_until":.null,"blocked_reason":.null,"last_error":.null,"last_success":.null,"last_failure":.null,"delivered":.number(4),"failed":.number(1)]) }
    private func subscription(id:String,name:String,origin:String,scope:String,project:JSON,events:[JSON],days:Int) -> [String:JSON] {
        let date = ISO8601DateFormatter();return ["id":.string(id),"revision":.string(UUID().uuidString.lowercased()),"name":.string(name),"origin":.string(origin),"scope":.string(scope),"project_id":project,"events":.array(events),"state":.string("pending"),"created_at":.string(date.string(from:Date())),"expires_at":.string(date.string(from:Date().addingTimeInterval(Double(days)*86400))),"verified_at":.null,"revoked_at":.null,"delivery":delivery(id == existing)]
    }
    private func event() -> JSON { let f = ISO8601DateFormatter();return .object(["id":.string(eventID),"task_id":.string("f0b2cafe-0000-4000-8000-000000000032"),"task_generation":.string("f0b2cafe-0000-4000-8000-000000000033"),"type":.string("task.created"),"status":.string(retried ? "pending":"failed"),"created_at":.string(f.string(from:Date())),"expires_at":.string(f.string(from:Date().addingTimeInterval(86400))),"finished_at":.null,"next_attempt_at":.string(f.string(from:Date())),"parts":.number(3),"parts_delivered":.number(1),"attempts":.number(12),"manual_retries":.number(retried ? 1:0),"error":.string("attempts_exhausted"),"http_status":.number(503)]) }
    func webhookReceipt(action:String,body:[String:JSON],account:String,origin:String) async throws -> [String:JSON] {
        guard account == Self.account, origin == "https://backend.example" else { throw WebhookValue.invalid }
        if action == "list" { return ["account":.string(account),"subscriptions":.array(rows.values.sorted{$0["name"]!.text < $1["name"]!.text}.map(JSON.object)),"next_cursor":.null] }
        let id = body["id"]?.text ?? ""
        if action == "create", rows[id] == nil { rows[id] = subscription(id:id,name:body["name"]!.text,origin:WebhookValue.receiverOrigin(body["endpoint"]!.text)!,scope:body["scope"]!.text,project:body["project_id"]!,events:body["events"]!.list,days:[30,90,365].first { body["ttl_days"] == .number(Double($0)) } ?? 30) }
        if action == "cancel" { rows.removeValue(forKey:id);return ["account":.string(account),"id":.string(id),"cancelled":.bool(true)] }
        guard var row = rows[id] else { throw WebhookValue.invalid }
        if action == "pause" { row["state"] = .string("paused") }
        if action == "resume" || action == "verify" { row["state"] = .string("active") }
        if action == "revoke" { row["state"] = .string("revoked");row["revoked_at"] = .string(ISO8601DateFormatter().string(from:Date())) }
        if ["pause","resume","revoke"].contains(action) { row["revision"] = .string(UUID().uuidString.lowercased()) }
        if action == "retry_delivery" { retried = true;row["delivery"] = delivery(id == existing) }
        rows[id] = row;var reply: [String:JSON] = ["account":.string(account),"subscription":.object(row)]
        if ["pause","resume"].contains(action) { reply["command"] = .object(["request_id":body["request_id"]!,"applied":.bool(true)]) }
        if action == "verify" { reply["verification"] = .object(["attempt_id":body["attempt_id"]!,"outcome":.string("verified")]) }
        if action == "history" { reply["events"] = .array(id == existing ? [event()]:[]);reply["next_cursor"] = .null }
        if action == "retry_delivery" { reply["event"] = event();reply["retry"] = .object(["event_id":body["event_id"]!,"request_id":body["request_id"]!,"applied":.bool(true)]) }
        return reply
    }
}
#endif
