import Foundation
import AuthenticationServices
import AppAuthCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// AppAuth owns PKCE, state validation, code exchange and refresh-token rotation.
/// The browser adapter only presents the system authentication session.
@MainActor private final class CalendarBrowser:NSObject,OIDExternalUserAgent,ASWebAuthenticationPresentationContextProviding {
    private var browser:ASWebAuthenticationSession?
    private weak var flow:OIDExternalUserAgentSession?
    private let anchor:ASPresentationAnchor
    init(anchor:ASPresentationAnchor) {self.anchor=anchor}
    func presentationAnchor(for session:ASWebAuthenticationSession)->ASPresentationAnchor {anchor}
    nonisolated func present(_ request:OIDExternalUserAgentRequest,session:OIDExternalUserAgentSession)->Bool {
        MainActor.assumeIsolated {presentOnMain(request,session:session)}
    }
    private func presentOnMain(_ request:OIDExternalUserAgentRequest,session:OIDExternalUserAgentSession)->Bool {
        guard browser==nil else {return false};flow=session
        let browser=ASWebAuthenticationSession(url:request.externalUserAgentRequestURL(),callbackURLScheme:request.redirectScheme()) { [weak self,weak session] url,error in
            Task { @MainActor in
                guard let self,let session else {return}
                self.browser=nil
                if let url {do {try session.resumeExternalUserAgentFlow(url)} catch {session.failExternalUserAgentFlowWithError(CalendarReadFailure.signIn)}}
                else {session.failExternalUserAgentFlowWithError(error ?? CancellationError())}
            }
        }
        browser.presentationContextProvider=self
        // An explicit connection/reconnection always shows an account choice, without reusing an app web view.
        browser.prefersEphemeralWebBrowserSession=true
        self.browser=browser
        if !browser.start() {self.browser=nil;return false};return true
    }
    nonisolated func dismiss(animated:Bool,completion:@escaping @Sendable ()->Void) {
        MainActor.assumeIsolated {browser?.cancel();browser=nil;flow=nil;completion()}
    }
}
@MainActor final class NativeCalendarAuthorization:CalendarAuthorizing {
    private struct Active {
        var record:CalendarCredentialRecord
        let state:OIDAuthState
        let lease:CalendarReadLease
    }
    private struct Pending {
        let service:CalendarService
        let owner:String
        let generation:UUID
        let state:OIDAuthState
        let lease:CalendarReadLease
    }
    private let configurations:[CalendarService:CalendarOAuthConfiguration]
    private let vault:CalendarCredentialVault
    private var owner=""
    private var generation=UUID()
    private var active:[CalendarService:Active]=[:]
    private var writeSequences:[UUID:UInt64]=[:]
    private var pending:[UUID:Pending]=[:]
    private var flow:OIDExternalUserAgentSession?
    private var browser:CalendarBrowser?
    private var flowService:CalendarService?
    private var flowID:UUID?
    private var flowContinuation:CheckedContinuation<UUID,Error>?
    var configured:Set<CalendarService> {Set(configurations.keys)}
    init(info:[String:Any]=Bundle.main.infoDictionary ?? [:],vault:CalendarCredentialVault?=nil) {
        configurations=Dictionary(uniqueKeysWithValues:CalendarService.allCases.compactMap {service in CalendarOAuthConfiguration.read(service,info:info).map{(service,$0)}})
        self.vault=vault ?? CalendarCredentialVault(io:CalendarKeychainIO(service:(Bundle.main.bundleIdentifier ?? "com.taskfold")+".calendar.oauth"))
    }
    static func install() {
        #if DEBUG
        let arguments=ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting"),arguments.contains("--calendar-native-auth-proof") {Task {await Self.runOfflineProof();await Self.runSyntheticKeychainProof()};return}
        if arguments.contains("--uitesting") || arguments.contains("--preview") {return}
        #endif
        CalendarLinksStore.shared.install(NativeCalendarAuthorization())
    }
    func bind(owner:String) {
        guard self.owner != owner else {return}
        cancel(service:nil);active.values.forEach{$0.lease.cancel()};active=[:];writeSequences=[:];self.owner=owner;generation=UUID()
    }
    private func current(_ owner:String,_ generation:UUID)->Bool {self.owner==owner && self.generation==generation && !Task.isCancelled}
    func restore(owner:String,service:CalendarService) async throws ->CalendarAccountIdentity? {
        guard owner==self.owner,!owner.isEmpty else {throw CancellationError()}
        let binding=generation
        guard let record=try await vault.read(owner:owner,service:service) else {return nil}
        guard current(owner,binding) else {throw CancellationError()}
        guard let config=configurations[service],record.configuration==config.fingerprint,
              let state=try? NSKeyedUnarchiver.unarchivedObject(ofClass:OIDAuthState.self,from:record.state),state.isAuthorized else {throw CalendarReadFailure.signIn}
        active[service]=Active(record:record,state:state,lease:CalendarReadLease());return record.identity
    }
    private func presentationAnchor()->ASPresentationAnchor? {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.filter{$0.activationState == .foregroundActive}.flatMap(\.windows).first(where:{$0.isKeyWindow})
        #else
        return NSApp.keyWindow ?? NSApp.mainWindow
        #endif
    }
    func begin(owner:String,service:CalendarService) async throws ->UUID {
        guard owner==self.owner,!owner.isEmpty,flowID==nil,let config=configurations[service],let anchor=presentationAnchor() else {throw CalendarReadFailure.unavailable}
        let binding=generation,id=UUID(),agent=CalendarBrowser(anchor:anchor)
        let configuration=OIDServiceConfiguration(authorizationEndpoint:config.authorizationEndpoint,tokenEndpoint:config.tokenEndpoint)
        let parameters=service == .google ? ["access_type":"offline","prompt":"consent select_account"]:["prompt":"select_account"]
        let request=OIDAuthorizationRequest(configuration:configuration,clientId:config.clientID,scopes:service.scopes,redirectURL:config.redirect,responseType:OIDResponseTypeCode,additionalParameters:parameters)
        flowID=id;flowService=service;browser=agent
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                flowContinuation=continuation
                flow=OIDAuthState.authState(byPresenting:request,externalUserAgent:agent) { [weak self] state,error in
                    Task { @MainActor in
                        guard let self,self.flowID==id else {return}
                        let continuation=self.flowContinuation;self.flowContinuation=nil;self.flowID=nil;self.flow=nil;self.browser=nil;self.flowService=nil
                        guard self.current(owner,binding) else {continuation?.resume(throwing:CancellationError());return}
                        guard let state,state.isAuthorized else {
                            let cancelled=(error as NSError?)?.domain==ASWebAuthenticationSessionError.errorDomain && (error as NSError?)?.code==ASWebAuthenticationSessionError.canceledLogin.rawValue
                            continuation?.resume(throwing:cancelled ? CancellationError():CalendarReadFailure.signIn);return
                        }
                        self.pending[id]=Pending(service:service,owner:owner,generation:binding,state:state,lease:CalendarReadLease());continuation?.resume(returning:id)
                    }
                }
            }
        },onCancel:{Task { @MainActor [weak self] in if self?.flowID==id {self?.cancel(service:service)}}})
    }
    func token(owner:String,service:CalendarService,pending id:UUID?,forceRefresh:Bool) async throws ->String {
        let binding=generation,state:OIDAuthState,lease:CalendarReadLease,record:CalendarCredentialRecord?
        guard current(owner,binding),!owner.isEmpty else {throw CancellationError()}
        if let id {
            guard let staged=pending[id],staged.owner==owner,staged.generation==binding,staged.service==service else {throw CancellationError()}
            state=staged.state;lease=staged.lease;record=nil
        } else {
            guard let saved=active[service] else {throw CalendarReadFailure.signIn}
            state=saved.state;lease=saved.lease;record=saved.record
        }
        try lease.check();if forceRefresh {guard state.refreshToken != nil else {throw CalendarReadFailure.signIn};state.setNeedsTokenRefresh()}
        let token:String=try await withCheckedThrowingContinuation { continuation in
            state.performAction { accessToken,_,error in
                if let error {let ns=error as NSError;continuation.resume(throwing:ns.domain==OIDOAuthTokenErrorDomain ? CalendarReadFailure.signIn:CalendarReadFailure.unavailable)}
                else if let accessToken,!accessToken.isEmpty {continuation.resume(returning:accessToken)}
                else {continuation.resume(throwing:CalendarReadFailure.signIn)}
            }
        }
        try lease.check();guard current(owner,binding) else {throw CancellationError()}
        if let record {
            let previous=max(writeSequences[record.id] ?? 0,record.sequence ?? 0)
            guard previous<UInt64.max else {throw CalendarReadFailure.unavailable}
            let sequence=previous+1;writeSequences[record.id]=sequence
            let refreshed=CalendarCredentialRecord(id:record.id,identity:record.identity,configuration:record.configuration,sequence:sequence,state:try NSKeyedArchiver.archivedData(withRootObject:state,requiringSecureCoding:true))
            try await vault.write(refreshed,owner:owner,service:service,lease:lease,expectedID:record.id)
            try lease.check();guard current(owner,binding),active[service]?.record.id==record.id else {throw CancellationError()}
            if writeSequences[record.id]==sequence {active[service]?.record=refreshed}
        }
        return token
    }
    func accept(owner:String,service:CalendarService,pending id:UUID,identity:CalendarAccountIdentity) async throws {
        guard let staged=pending[id],staged.service==service,staged.owner==owner,current(owner,staged.generation),let config=configurations[service] else {throw CancellationError()}
        try staged.lease.check()
        let record=CalendarCredentialRecord(id:UUID(),identity:identity,configuration:config.fingerprint,state:try NSKeyedArchiver.archivedData(withRootObject:staged.state,requiringSecureCoding:true))
        try await vault.write(record,owner:owner,service:service,lease:staged.lease)
        guard current(owner,staged.generation),pending[id] != nil,(try? staged.lease.check()) != nil else {
            try await vault.remove(owner:owner,service:service,ifID:record.id);throw CancellationError()
        }
        active[service]?.lease.cancel();active[service]=Active(record:record,state:staged.state,lease:staged.lease);pending.removeValue(forKey:id)
    }
    func discard(_ id:UUID) {pending.removeValue(forKey:id)?.lease.cancel()}
    func cancel(service:CalendarService?) {
        let ids=pending.filter{service==nil || $0.value.service==service}.map(\.key);ids.forEach{discard($0)}
        if flowID != nil,service==nil || flowService==service {
            let continuation=flowContinuation,session=flow;flowContinuation=nil;flowID=nil;flowService=nil;flow=nil;browser=nil
            session?.cancel();continuation?.resume(throwing:CancellationError())
        }
    }
    func eraseAccount(_ account:String) async throws {
        if owner==account { bind(owner:"") }
        for service in CalendarService.allCases { try await vault.remove(owner:account,service:service) }
    }
    func disconnect(owner:String,service:CalendarService) async throws {
        guard self.owner==owner,!owner.isEmpty else {throw CancellationError()}
        cancel(service:service);active.removeValue(forKey:service)?.lease.cancel()
        try await vault.remove(owner:owner,service:service)
    }
}
#if DEBUG
/// Exercises the actual AppAuth archive and native bridge against memory-only storage.
/// Even accidental SDK refreshes are intercepted; this proof cannot make a provider request.
private final class CalendarProofHTTP:URLProtocol,@unchecked Sendable {
    static let lock=NSLock()
    nonisolated(unsafe) static var attempts=0
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {Self.lock.lock();Self.attempts+=1;Self.lock.unlock();client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet))}
    override func stopLoading() {}
    static func count()->Int {lock.lock();defer{lock.unlock()};return attempts}
}
private final class CalendarProofSecrets:CalendarSecureItemIO,@unchecked Sendable {
    private var values:[String:Data]=[:]
    var failWrite=false,failRemove=false
    var beforeWrite:(@Sendable ()->Void)?
    func read(key:String) throws ->Data? {values[key]}
    func write(_ data:Data,key:String) throws {if failWrite {throw CalendarReadFailure.unavailable};let action=beforeWrite;beforeWrite=nil;action?();values[key]=data}
    func remove(key:String) throws {if failRemove {throw CalendarReadFailure.unavailable};values.removeValue(forKey:key)}
}
extension NativeCalendarAuthorization {
    static func runOfflineProof() async {
        let original=OIDURLSessionProvider.session(),configuration=URLSessionConfiguration.ephemeral
        configuration.protocolClasses=[CalendarProofHTTP.self];let session=URLSession(configuration:configuration)
        OIDURLSessionProvider.setSession(session);defer{OIDURLSessionProvider.setSession(original);session.invalidateAndCancel()}
        var checks:[String]=[],success=false
        func require(_ value:Bool,_ name:String) throws {guard value else {throw CalendarReadFailure.invalidResponse};checks.append(name)}
        do {
            let info:[String:Any]=["CFBundleIdentifier":"com.example.calendarproof","TaskfoldGoogleCalendarClientID":"123-synthetic.apps.googleusercontent.com","TaskfoldMicrosoftCalendarClientID":"11111111-2222-3333-4444-555555555555","CFBundleURLTypes":[["CFBundleURLSchemes":["com.googleusercontent.apps.123-synthetic","com.example.calendarproof.calendar"]]]]
            for service in CalendarService.allCases {
                let io=CalendarProofSecrets(),vault=CalendarCredentialVault(io:io),native=NativeCalendarAuthorization(info:info,vault:vault)
                native.bind(owner:"synthetic-workspace-a")
                guard let config=native.configurations[service] else {throw CalendarReadFailure.invalidResponse}
                let request=OIDAuthorizationRequest(configuration:OIDServiceConfiguration(authorizationEndpoint:config.authorizationEndpoint,tokenEndpoint:config.tokenEndpoint),clientId:config.clientID,scopes:service.scopes,redirectURL:config.redirect,responseType:OIDResponseTypeCode,additionalParameters:nil)
                try require(request.codeVerifier != nil && request.codeChallengeMethod=="S256" && request.state != nil,service.rawValue+": SDK PKCE and state")
                let response=OIDAuthorizationResponse(request:request,parameters:["code":"synthetic-code" as NSString,"state":request.state! as NSString])
                guard let tokenRequest=response.tokenExchangeRequest() else {throw CalendarReadFailure.invalidResponse}
                let token=OIDTokenResponse(request:tokenRequest,parameters:["access_token":"synthetic-proof-access" as NSString,"refresh_token":"synthetic-proof-refresh" as NSString,"token_type":"Bearer" as NSString,"expires_in":NSNumber(value:3600),"scope":service.scopes.joined(separator:" ") as NSString])
                let state=OIDAuthState(authorizationResponse:response,tokenResponse:token),id=UUID(),identity=CalendarAccountIdentity(id:"synthetic-default",label:"Synthetic calendar")
                native.pending[id]=Pending(service:service,owner:native.owner,generation:native.generation,state:state,lease:CalendarReadLease())
                try await native.accept(owner:native.owner,service:service,pending:id,identity:identity)
                let saved=try await vault.read(owner:native.owner,service:service)
                try require(saved?.identity==identity,service.rawValue+": accepted record")
                let restored=NativeCalendarAuthorization(info:info,vault:vault);restored.bind(owner:native.owner)
                let account=try await restored.restore(owner:native.owner,service:service)
                try require(account==identity,service.rawValue+": SDK secure archive restored")
                let access=try await restored.token(owner:native.owner,service:service,pending:nil,forceRefresh:false)
                try require(access=="synthetic-proof-access",service.rawValue+": fresh token and persisted state")
                io.failWrite=true
                do {_ = try await restored.token(owner:native.owner,service:service,pending:nil,forceRefresh:false);throw CalendarReadFailure.invalidResponse} catch CalendarReadFailure.unavailable {checks.append(service.rawValue+": write failure visible")}
                io.failWrite=false
                restored.bind(owner:"synthetic-workspace-b")
                let other=try await restored.restore(owner:"synthetic-workspace-b",service:service)
                try require(other==nil,service.rawValue+": other workspace isolated")
                io.failRemove=true
                do {try await native.disconnect(owner:native.owner,service:service);throw CalendarReadFailure.invalidResponse} catch CalendarReadFailure.unavailable {checks.append(service.rawValue+": removal failure visible")}
                io.failRemove=false;try await native.disconnect(owner:native.owner,service:service)
                let removed=try await vault.read(owner:native.owner,service:service);try require(removed==nil,service.rawValue+": disconnect retry removes record")
                // Hold a secure write while the main actor changes workspace, then allow it to finish.
                let late=UUID();native.pending[late]=Pending(service:service,owner:native.owner,generation:native.generation,state:state,lease:CalendarReadLease())
                let gate=DispatchSemaphore(value:0)
                io.beforeWrite={Task { @MainActor in native.bind(owner:"synthetic-workspace-b");gate.signal() };gate.wait()}
                do {try await native.accept(owner:"synthetic-workspace-a",service:service,pending:late,identity:identity);throw CalendarReadFailure.invalidResponse} catch is CancellationError {checks.append(service.rawValue+": late acceptance rejected")}
                let stale=try await vault.read(owner:"synthetic-workspace-a",service:service);try require(stale==nil,service.rawValue+": late record cleaned conditionally")
            }
            try require(CalendarProofHTTP.count()==0,"No SDK HTTP requests")
            success=true
        } catch {success=false}
        let result:[String:Any]=["passed":success,"checks":checks,"sdkHTTPAttempts":CalendarProofHTTP.count(),"realKeychainAccess":false,"providerNetworkAccess":false]
        if let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {
            try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try? data.write(to:folder.appendingPathComponent("calendar-native-authorization-proof.json"),options:.atomic)
        }
    }
}
#endif
#if DEBUG
extension NativeCalendarAuthorization {
    /// A unique disposable service exercises actual OS storage without reading a user's credentials.
    static func runSyntheticKeychainProof() async {
        let service=(Bundle.main.bundleIdentifier ?? "taskfold")+".calendar.synthetic."+UUID().uuidString
        let vault=CalendarCredentialVault(io:CalendarKeychainIO(service:service)),owner="synthetic-keychain-workspace"
        let first=CalendarCredentialRecord(id:UUID(),identity:CalendarAccountIdentity(id:"synthetic-default",label:"Synthetic calendar"),configuration:"synthetic-only",state:Data("synthetic-opaque-state".utf8))
        var checks:[String]=[],clean=false
        do {
            try await vault.write(first,owner:owner,service:.google,lease:CalendarReadLease())
            guard try await vault.read(owner:owner,service:.google)==first else {throw CalendarReadFailure.invalidResponse};checks.append("OS Keychain write/read")
            let changed=CalendarCredentialRecord(id:first.id,identity:first.identity,configuration:first.configuration,sequence:1,state:Data("synthetic-rotated-state".utf8))
            try await vault.write(changed,owner:owner,service:.google,lease:CalendarReadLease(),expectedID:first.id)
            guard try await vault.read(owner:owner,service:.google)==changed else {throw CalendarReadFailure.invalidResponse};checks.append("OS Keychain update/read")
            try await vault.remove(owner:owner,service:.google,ifID:first.id)
            guard try await vault.read(owner:owner,service:.google)==nil else {throw CalendarReadFailure.invalidResponse};checks.append("OS Keychain conditional removal")
        } catch {}
        do {try await vault.remove(owner:owner,service:.google);clean=try await vault.read(owner:owner,service:.google)==nil} catch {}
        let result:[String:Any]=["passed":checks.count==3 && clean,"checks":checks,"syntheticOnly":true,"uniqueDisposableService":true,"credentialsRemoved":clean,"providerNetworkAccess":false]
        if let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) {
            try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try? data.write(to:folder.appendingPathComponent("calendar-synthetic-keychain-proof.json"),options:.atomic)
        }
    }
}
#endif
