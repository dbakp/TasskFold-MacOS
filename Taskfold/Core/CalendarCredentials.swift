import Foundation
import Security
import CryptoKit

/// Public application identifiers only. No client secret belongs in a native app.
struct CalendarOAuthConfiguration:Equatable,Sendable {
    let service:CalendarService
    let clientID:String
    let redirect:URL
    var authorizationEndpoint:URL {URL(string:service == .google ? "https://accounts.google.com/o/oauth2/v2/auth":"https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!}
    var tokenEndpoint:URL {URL(string:service == .google ? "https://oauth2.googleapis.com/token":"https://login.microsoftonline.com/common/oauth2/v2.0/token")!}
    var fingerprint:String {Self.digest(service.rawValue+"|"+clientID+"|"+redirect.absoluteString+"|"+service.scopes.joined(separator:" "))}
    static func digest(_ text:String)->String {SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
    static func read(_ service:CalendarService,info:[String:Any])->Self? {
        let field=service == .google ? "TaskfoldGoogleCalendarClientID":"TaskfoldMicrosoftCalendarClientID"
        guard let raw=info[field] as? String else {return nil}
        let client=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !client.isEmpty,client.utf8.count<=500,client.unicodeScalars.allSatisfy({CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._").contains($0)}) else {return nil}
        let scheme:String
        if service == .google {
            guard client.hasSuffix(".apps.googleusercontent.com"),client.count>".apps.googleusercontent.com".count else {return nil}
            scheme=client.split(separator:".").reversed().joined(separator:".")
        } else {
            guard UUID(uuidString:client) != nil,let bundle=info["CFBundleIdentifier"] as? String,!bundle.isEmpty else {return nil}
            scheme=bundle+".calendar"
        }
        let registered=(info["CFBundleURLTypes"] as? [[String:Any]] ?? []).flatMap{$0["CFBundleURLSchemes"] as? [String] ?? []}
        guard registered.contains(scheme),let redirect=URL(string:scheme+":/oauthredirect") else {return nil}
        return Self(service:service,clientID:client,redirect:redirect)
    }
}
struct CalendarCredentialRecord:Codable,Equatable,Sendable {
    var version=1
    let id:UUID
    let identity:CalendarAccountIdentity
    let configuration:String
    var sequence:UInt64?=nil
    let state:Data
}
protocol CalendarSecureItemIO:Sendable {
    func read(key:String) throws ->Data?
    func write(_ data:Data,key:String) throws
    func remove(key:String) throws
}
/// The default app-only Keychain service is never shared with widgets or cloud backups.
struct CalendarKeychainIO:CalendarSecureItemIO {
    let service:String
    private func query(_ key:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:key,kSecAttrSynchronizable as String:false,kSecUseDataProtectionKeychain as String:true]
    }
    func read(key:String) throws ->Data? {
        var query=query(key);query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
        var item:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&item)
        if status==errSecItemNotFound {return nil}
        guard status==errSecSuccess,let data=item as? Data else {throw CalendarReadFailure.unavailable};return data
    }
    func write(_ data:Data,key:String) throws {
        let query=query(key),attributes:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated=SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if updated==errSecSuccess {return}
        guard updated==errSecItemNotFound else {throw CalendarReadFailure.unavailable}
        var addition=query;attributes.forEach{addition[$0.key]=$0.value}
        guard SecItemAdd(addition as CFDictionary,nil)==errSecSuccess else {throw CalendarReadFailure.unavailable}
    }
    func remove(key:String) throws {
        let status=SecItemDelete(query(key) as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else {throw CalendarReadFailure.unavailable}
    }
}
/// Serializes secure operations off the UI actor, with cancellation and conditional cleanup.
actor CalendarCredentialVault {
    private let io:any CalendarSecureItemIO
    init(io:any CalendarSecureItemIO) {self.io=io}
    static func key(owner:String,service:CalendarService)->String {CalendarOAuthConfiguration.digest(owner)+"."+service.rawValue}
    func read(owner:String,service:CalendarService) throws ->CalendarCredentialRecord? {
        guard !owner.isEmpty else {throw CalendarReadFailure.unavailable}
        guard let data=try io.read(key:Self.key(owner:owner,service:service)) else {return nil}
        guard data.count<=1024*1024,let record=try? JSONDecoder().decode(CalendarCredentialRecord.self,from:data),record.version==1,!record.identity.id.isEmpty,!record.state.isEmpty else {throw CalendarReadFailure.unavailable};return record
    }
    func write(_ record:CalendarCredentialRecord,owner:String,service:CalendarService,lease:CalendarReadLease,expectedID:UUID?=nil) throws {
        try lease.check();guard !owner.isEmpty,record.version==1,!record.state.isEmpty else {throw CalendarReadFailure.unavailable}
        if let expectedID {
            guard let previous=try read(owner:owner,service:service),previous.id==expectedID else {throw CancellationError()}
            if previous==record {return}
            guard (record.sequence ?? 0)>(previous.sequence ?? 0) else {throw CancellationError()}
        }
        let data=try JSONEncoder().encode(record);guard data.count<=1024*1024 else {throw CalendarReadFailure.unavailable}
        try lease.check();try io.write(data,key:Self.key(owner:owner,service:service))
    }
    func remove(owner:String,service:CalendarService,ifID:UUID?=nil) throws {
        guard !owner.isEmpty else {return}
        if let ifID {guard try read(owner:owner,service:service)?.id==ifID else {return}}
        try io.remove(key:Self.key(owner:owner,service:service))
    }
}
