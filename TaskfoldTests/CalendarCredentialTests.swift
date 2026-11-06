import Foundation
import XCTest
@testable import TaskfoldCore

private final class CalendarMemorySecrets:CalendarSecureItemIO,@unchecked Sendable {
    private let lock=NSLock()
    private var data:[String:Data]=[:]
    var fails=false
    func read(key:String) throws ->Data? {lock.lock();defer{lock.unlock()};if fails {throw CalendarReadFailure.unavailable};return data[key]}
    func write(_ value:Data,key:String) throws {lock.lock();defer{lock.unlock()};if fails {throw CalendarReadFailure.unavailable};data[key]=value}
    func remove(key:String) throws {lock.lock();defer{lock.unlock()};if fails {throw CalendarReadFailure.unavailable};data.removeValue(forKey:key)}
}
final class CalendarCredentialTests:XCTestCase {
    private var identity:CalendarAccountIdentity {CalendarAccountIdentity(id:"primary",label:"Synthetic account")}
    private func record(_ id:UUID=UUID())->CalendarCredentialRecord {CalendarCredentialRecord(id:id,identity:identity,configuration:"synthetic-config",state:Data("synthetic-opaque-state".utf8))}
    func testPublicConfigurationRequiresMatchingRegisteredCallback() throws {
        let client="123-synthetic.apps.googleusercontent.com",scheme="com.googleusercontent.apps.123-synthetic"
        var info:[String:Any]=["CFBundleIdentifier":"com.example.taskfold","TaskfoldGoogleCalendarClientID":client,"CFBundleURLTypes":[["CFBundleURLSchemes":[scheme]]]]
        let google=try XCTUnwrap(CalendarOAuthConfiguration.read(.google,info:info));XCTAssertEqual(google.redirect.absoluteString,scheme+":/oauthredirect")
        XCTAssertEqual(google.tokenEndpoint.host,"oauth2.googleapis.com")
        info["CFBundleURLTypes"]=[["CFBundleURLSchemes":["wrong"]]];XCTAssertNil(CalendarOAuthConfiguration.read(.google,info:info))
        for invalid in ["", "$(TASKFOLD_GOOGLE_CALENDAR_CLIENT_ID)","web-client","secret\nvalue"] {info["TaskfoldGoogleCalendarClientID"]=invalid;XCTAssertNil(CalendarOAuthConfiguration.read(.google,info:info))}
        info["TaskfoldMicrosoftCalendarClientID"]="11111111-2222-3333-4444-555555555555";info["CFBundleURLTypes"]=[["CFBundleURLSchemes":["com.example.taskfold.calendar"]]]
        let microsoft=try XCTUnwrap(CalendarOAuthConfiguration.read(.outlook,info:info));XCTAssertEqual(microsoft.redirect.absoluteString,"com.example.taskfold.calendar:/oauthredirect")
        XCTAssertEqual(microsoft.authorizationEndpoint.host,"login.microsoftonline.com");XCTAssertNotEqual(google.fingerprint,microsoft.fingerprint)
        info["TaskfoldMicrosoftCalendarClientID"]="not-a-uuid";XCTAssertNil(CalendarOAuthConfiguration.read(.outlook,info:info))
    }
    func testCredentialsAreWorkspaceAndProviderIsolated() async throws {
        let io=CalendarMemorySecrets(),vault=CalendarCredentialVault(io:io),first=record(),second=record()
        try await vault.write(first,owner:"local-workspace",service:.google,lease:CalendarReadLease())
        try await vault.write(second,owner:"cloud-workspace",service:.google,lease:CalendarReadLease())
        let a=try await vault.read(owner:"local-workspace",service:.google),b=try await vault.read(owner:"cloud-workspace",service:.google),other=try await vault.read(owner:"local-workspace",service:.outlook)
        XCTAssertEqual(a,first);XCTAssertEqual(b,second);XCTAssertNil(other)
        let key=CalendarCredentialVault.key(owner:"local-workspace",service:.google);XCTAssertFalse(key.contains("local-workspace"))
        try await vault.remove(owner:"local-workspace",service:.google)
        let retained=try await vault.read(owner:"cloud-workspace",service:.google);XCTAssertEqual(retained,second)
    }
    func testCancelledCredentialWriteCannotReviveDisconnectedAccount() async throws {
        let vault=CalendarCredentialVault(io:CalendarMemorySecrets()),lease=CalendarReadLease();lease.cancel()
        do {try await vault.write(record(),owner:"workspace",service:.google,lease:lease);XCTFail("Cancelled write stored credentials")}catch{XCTAssertTrue(error is CancellationError)}
        let result=try await vault.read(owner:"workspace",service:.google);XCTAssertNil(result)
    }
    func testLateRefreshAndCleanupCannotOverwriteNewConnection() async throws {
        let vault=CalendarCredentialVault(io:CalendarMemorySecrets()),old=record(),new=record()
        try await vault.write(old,owner:"workspace",service:.google,lease:CalendarReadLease())
        try await vault.write(new,owner:"workspace",service:.google,lease:CalendarReadLease())
        do {try await vault.write(old,owner:"workspace",service:.google,lease:CalendarReadLease(),expectedID:old.id);XCTFail("Stale refresh replaced connection")}catch{XCTAssertTrue(error is CancellationError)}
        try await vault.remove(owner:"workspace",service:.google,ifID:old.id)
        let result=try await vault.read(owner:"workspace",service:.google);XCTAssertEqual(result,new)
        var refreshed=new;refreshed=CalendarCredentialRecord(id:new.id,identity:new.identity,configuration:new.configuration,sequence:1,state:Data("rotated-synthetic-state".utf8))
        try await vault.write(refreshed,owner:"workspace",service:.google,lease:CalendarReadLease(),expectedID:new.id)
        let rotated=try await vault.read(owner:"workspace",service:.google);XCTAssertEqual(rotated,refreshed)
    }
    func testUnknownVersionCorruptionAndStorageFailureStayVisible() async throws {
        let io=CalendarMemorySecrets(),vault=CalendarCredentialVault(io:io),key=CalendarCredentialVault.key(owner:"workspace",service:.google)
        var future=record();future.version=2
        for data in [Data("corrupt".utf8),try JSONEncoder().encode(future),Data(repeating:0,count:1024*1024+1)] {
            try io.write(data,key:key)
            do {_ = try await vault.read(owner:"workspace",service:.google);XCTFail("Unreadable credential became disconnected success")}catch{XCTAssertEqual(error as? CalendarReadFailure,.unavailable)}
        }
        io.fails=true
        do {try await vault.remove(owner:"workspace",service:.google);XCTFail("Delete failure hidden")}catch{XCTAssertEqual(error as? CalendarReadFailure,.unavailable)}
    }
    func testLateRefreshCannotOverwriteNewerStateWithinSameConnection() async throws {
        let vault=CalendarCredentialVault(io:CalendarMemorySecrets()),initial=record()
        try await vault.write(initial,owner:"workspace",service:.google,lease:CalendarReadLease())
        let older=CalendarCredentialRecord(id:initial.id,identity:identity,configuration:initial.configuration,sequence:1,state:Data("older-synthetic-rotation".utf8))
        let newer=CalendarCredentialRecord(id:initial.id,identity:identity,configuration:initial.configuration,sequence:2,state:Data("newer-synthetic-rotation".utf8))
        try await vault.write(newer,owner:"workspace",service:.google,lease:CalendarReadLease(),expectedID:initial.id)
        do {try await vault.write(older,owner:"workspace",service:.google,lease:CalendarReadLease(),expectedID:initial.id);XCTFail("Old refresh replaced newer credentials")}catch{XCTAssertTrue(error is CancellationError)}
        try await vault.write(newer,owner:"workspace",service:.google,lease:CalendarReadLease(),expectedID:initial.id)
        let saved=try await vault.read(owner:"workspace",service:.google);XCTAssertEqual(saved,newer)
    }

}
