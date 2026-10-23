import SwiftUI
import Foundation
import CryptoKit

/// Renews only the current account. Store.authenticated() is deliberately not
/// called: that path resets workspace and Undo state for a full account entry.
struct ConnectionSignInSheet: View {
    let backend: Backend
    let email: String
    let restored: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var context: AccountReauthentication
    @State private var password = ""
    @State private var busy = false
    @State private var saving = false
    @State private var active = true
    @State private var message: String?
    @State private var operation: Task<Void,Never>?
    @FocusState private var passwordFocused: Bool
    init(backend: Backend, context: AccountReauthentication, email: String, restored: @escaping () -> Void) {
        self.backend = backend; self.email = email; self.restored = restored
        _context = State(initialValue:context)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                if let message {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:"exclamationmark.circle").dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityHidden(true)
                        Text(message).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("connectionSignInNotice")
                    }.font(.callout).foregroundStyle(.secondary).padding(.horizontal,20).padding(.vertical,12).background(.background)
                    Divider()
                }
            Form {
                Section {
                    Text("Use the same Taskfold account. Your saved work stays in place.")
                        .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    LabeledContent("Account") { Text(email.isEmpty ? "Current Taskfold account" : email).textSelection(.enabled) }
                }
                Section {
                    SecureField("Password",text:$password).textContentType(.password)
                        .focused($passwordFocused).disabled(busy).onSubmit { run(google:false) }
                        .accessibilityIdentifier("connectionSignInPassword")
                    Button("Sign in") { run(google:false) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(busy || password.isEmpty).accessibilityIdentifier("connectionSignInSubmit")
                    Button("Continue with Google") { run(google:true) }
                        .disabled(busy).accessibilityIdentifier("connectionSignInGoogle")
                }
                if busy { Section { ProgressView(saving ? "Saving sign-in…" : "Signing in…") } }
            }
            .formStyle(.grouped)
            }
            .navigationTitle("Sign in again")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("Cancel") { cancel() }.disabled(saving).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("connectionSignInCancel")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth:420,idealWidth:500,minHeight:380)
        #endif
        .interactiveDismissDisabled(busy)
        .privacySensitive()
        .overlay { if phase != .active { Rectangle().fill(.background).overlay { Label("Sign in again",systemImage:"lock.fill").foregroundStyle(.secondary) } } }
        .onAppear { passwordFocused = true }
        .onChange(of:passwordFocused) { _,focused in if focused { message = nil } }
        .onDisappear {
            active = false; password = ""
            if !saving { operation?.cancel(); backend.cancelReauthentication(context) }
        }
    }
    private func cancel() {
        guard !saving else { return }
        active = false; password = ""; operation?.cancel(); backend.cancelReauthentication(context); dismiss()
    }
    private func run(google: Bool) {
        guard !busy, google || !password.isEmpty else { return }
        busy = true; message = nil; passwordFocused = false
        let suppliedPassword = password; password = ""
        operation = Task { @MainActor in
            defer { busy = false; saving = false }
            do {
                if google {
                    #if os(macOS)
                    try await backend.googleOnMac(reauthenticating:context,willCommit:{saving = true})
                    #else
                    try await backend.google(reauthenticating:context,willCommit:{saving = true})
                    #endif
                } else {
                    _ = try await backend.signIn(email:email,password:suppliedPassword,signup:false,reauthenticating:context,willCommit:{saving = true})
                }
                guard active else { return }
                restored(); dismiss()
            } catch {
                guard active else { return }
                if let fresh = try? backend.reauthenticationContext(account:context.account) { context = fresh }
                if saving { message = "Sign-in could not be saved. Try again." }
                else if error is AccountReauthenticationMismatch { message = "Use the same Taskfold account." }
                else if error is CancellationError { message = "Sign-in was interrupted. Try again." }
                else { message = "Sign-in was not confirmed. Try again." }
            }
        }
    }
}


/// Reuses same-account renewal without the full account-entry workspace reset.
struct SyncSignInButton: View {
    @Environment(Store.self) private var store
    @State private var request: Request?
    private struct Request: Identifiable {
        let context: AccountReauthentication
        let workspace: WorkspaceBinding
        var id: UUID { context.id }
    }
    var body: some View {
        Button("Sign in again") {
            guard let context = try? store.syncSignInContext() else { return }
            request = Request(context:context,workspace:WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration))
        }
        .disabled(store.syncing || !store.canSignInForSync)
        .accessibilityIdentifier("syncSignIn")
        .sheet(item:$request) { value in
            ConnectionSignInSheet(backend:store.backend,context:value.context,email:store.backend.session?.user.email ?? store.email) {
                Task { await store.resumeSyncAfterSignIn(workspace:value.workspace) }
            }
        }
        .onChange(of:store.workspaceGeneration) { _,_ in request = nil }
        .onChange(of:store.signingOut) { _,value in if value { request = nil } }
        .onChange(of:store.accountRemovalBlocked) { _,value in if value { request = nil } }
    }
}

#if DEBUG
/// Exact isolated native host only. Real Backend/URLSession, synthetic HTTP and
/// memory-only credentials/vaults; no provider browser or hosted Auth claim.
@MainActor final class ConnectionReauthenticationFixture {
    nonisolated static let account = "f0c4cafe-0000-4000-8000-000000000001"
    nonisolated static let other = "f0c4cafe-0000-4000-8000-000000000002"
    nonisolated static let origin = "https://connection-reauthentication.test"
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return ["com.dbakp.taskfold.workflowtestswebhooks","com.dbakp.taskfold.workflowtestsp1","com.dbakp.taskfold.mac.workflowtestsp1"].contains(Bundle.main.bundleIdentifier ?? "") && args.contains("--uitesting") && args.contains("--connection-reauthentication-testing") && !args.contains("--live-auth-ui-test") && UserDefaults.standard.bool(forKey:"localMode")
    }
    let backend: Backend
    private let webhookVault: WebhookEnrollmentVault
    private let automationVault: AutomationEnrollmentVault
    init() throws {
        precondition(Self.enabled)
        ConnectionReauthenticationHTTP.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConnectionReauthenticationHTTP.self]
        let session = try JSONDecoder().decode(Session.self,from:JSONSerialization.data(withJSONObject:["access_token":"fixture-old","refresh_token":"fixture-refresh","expires_at":Date().addingTimeInterval(3600).timeIntervalSince1970,"user":["id":Self.account,"email":"connection-fixture@example.invalid"]]))
        backend = Backend(configuration:["URL":Self.origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
        let memory = ConnectionReauthenticationMemory()
        webhookVault = WebhookEnrollmentVault(io:memory); automationVault = AutomationEnrollmentVault(io:memory)
    }
    func webhookModel() -> WebhookAccessModel {
        let generation = backend.reminderSessionIncarnation
        return WebhookAccessModel(account:Self.account,origin:Self.origin,service:backend,vault:webhookVault,isCurrent:{[backend] in backend.session?.user.id == Self.account && backend.reminderSessionIncarnation == generation})
    }
    func automationModel() -> AutomationAccessModel {
        let generation = backend.reminderSessionIncarnation
        return AutomationAccessModel(account:Self.account,origin:Self.origin,service:backend,vault:automationVault,isCurrent:{[backend] in backend.session?.user.id == Self.account && backend.reminderSessionIncarnation == generation})
    }
}
private final class ConnectionReauthenticationMemory: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String:Data] = [:]
    func read(key:String) throws -> Data? {lock.withLock{data[key]}}
    func write(_ value:Data,key:String) throws {lock.withLock{data[key]=value}}
    func remove(key:String) throws {_ = lock.withLock{data.removeValue(forKey:key)}}
}
private final class ConnectionReauthenticationHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var expired = false, restored = false
    private static var record: [String:JSON]?
    private static var intent: Data?
    static func reset() {lock.withLock {expired=false;restored=false;record=nil;intent=nil}}
    override class func canInit(with request:URLRequest) -> Bool {request.url?.host == "connection-reauthentication.test"}
    override class func canonicalRequest(for request:URLRequest) -> URLRequest {request}
    override func stopLoading() {}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open();defer{stream.close()};var bytes=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {let n=stream.read(&bytes,maxLength:bytes.count);if n<=0{break};data.append(bytes,count:n);guard data.count<=64000 else {throw WebhookValue.invalid}}
            }
            let body = try JSONDecoder().decode([String:JSON].self,from:data)
            let args = ProcessInfo.processInfo.arguments
            if request.url?.query == "grant_type=password", args.contains("--connection-reauthentication-hold") {return}
            let response:(Int,[String:JSON]) = try Self.lock.withLock {
                if request.url?.path == "/auth/v1/token" {
                    guard request.url?.query == "grant_type=password" else {return (400,["code":.string("refresh_token_not_found"),"message":.string("Synthetic expired refresh")])}
                    guard body["password"] == .string("fixture-password") else {return (400,["code":.string("invalid_credentials")])}
                    let wrong = args.contains("--connection-reauthentication-wrong-account")
                    if !wrong {Self.restored=true;Self.expired=false}
                    return (200,["access_token":.string("fixture-renewed"),"refresh_token":.string("fixture-renewed-refresh"),"expires_at":.number(Date().addingTimeInterval(3600).timeIntervalSince1970),"user":.object(["id":.string(wrong ? ConnectionReauthenticationFixture.other : ConnectionReauthenticationFixture.account),"email":.string("connection-fixture@example.invalid")])])
                }
                let action=body["action"]?.text ?? "", fields=body["body"]?.object ?? [:]
                let webhook=request.url?.path == "/functions/v1/automation-webhooks"
                if !Self.restored && ["verify","revoke"].contains(action) {Self.expired=true}
                if Self.expired {return (401,["error":.string("Synthetic session expired")])}
                let expected=Self.restored ? "Bearer fixture-renewed":"Bearer fixture-old"
                guard request.value(forHTTPHeaderField:"Authorization") == expected else {return (401,[:])}
                var reply:[String:JSON] = ["account":.string(ConnectionReauthenticationFixture.account)]
                if action == "list" {
                    reply[webhook ? "subscriptions":"keys"] = .array(Self.record.map{[.object($0)]} ?? [])
                    reply["next_cursor"] = .null;return (200,reply)
                }
                if action == "create" {
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                    let digest=Data(SHA256.hash(data:try encoder.encode(fields)))
                    if let old=Self.intent {guard old==digest else{return (409,["error":.string("Synthetic enrollment changed")])}}
                    if Self.record == nil {
                        Self.intent=digest
                        let stamp=Date(),f=ISO8601DateFormatter(),days=fields["ttl_days"]?.integer ?? 30
                        var row:[String:JSON] = ["id":fields["id"]!,"name":fields["name"]!,"created_at":.string(f.string(from:stamp)),"expires_at":.string(f.string(from:stamp.addingTimeInterval(Double(days)*86400))),"revoked_at":.null,"last_used_at":.null]
                        if webhook {
                            row.merge(["revision":.string(UUID().uuidString.lowercased()),"origin":.string(WebhookValue.receiverOrigin(fields["endpoint"]!.text)!),"scope":fields["scope"]!,"project_id":fields["project_id"]!,"events":fields["events"]!,"state":.string("pending"),"verified_at":.null,"delivery":.object(["version":.number(1),"pending":.number(0),"retained_bytes":.number(0),"missed":.number(0),"delivered":.number(0),"failed":.number(0),"capture_issue":.null,"missed_since":.null,"missed_until":.null,"blocked_reason":.null,"last_error":.null,"last_success":.null,"last_failure":.null])],uniquingKeysWith:{$1})
                        } else {row["scopes"]=fields["scopes"];row["prefix"] = .string("tfk_v1_" + fields["id"]!.text.replacingOccurrences(of:"-",with:"").prefix(8))}
                        Self.record=row
                    }
                    reply[webhook ? "subscription":"key"] = .object(Self.record!);return (200,reply)
                }
                throw WebhookValue.invalid
            }
            let encoded=try JSONEncoder().encode(response.1)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:response.0,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:encoded);client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
}
#endif
