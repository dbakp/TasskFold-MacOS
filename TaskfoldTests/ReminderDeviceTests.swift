import XCTest
@testable import TaskfoldCore

private final class DeviceMemory: @unchecked Sendable {
    let lock = NSLock()
    var fail = false
    var saved: [ReminderDeviceInstallation] = []
    func save(_ value: ReminderDeviceInstallation) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { throw AppFailure(message: "Fixture storage failure") }
        saved.append(value)
    }
}

@MainActor private final class LifecycleFixture {
    var persisted = ReminderDeviceInstallation(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", secret: String(repeating: "a", count: 64))
    var saves: [ReminderDeviceInstallation] = []
    var sent: [(ReminderDeviceCommand, UUID?)] = []
    var saveFails = false
    var failOnce: Set<Int64> = []
    var hold: Set<Int64> = []
    var held: [Int64: CheckedContinuation<Void, Never>] = [:]
    var badReceipt = false
    var clock = Date(timeIntervalSince1970: 1_791_273_600)
    func save(_ next: ReminderDeviceInstallation) throws {
        if saveFails { throw AppFailure(message: "Fixture secure storage failure") }
        saves.append(next); persisted = next
    }
    func send(_ command: ReminderDeviceCommand, incarnation: UUID?) async throws -> ReminderDeviceReceipt {
        XCTAssertGreaterThanOrEqual(persisted.revision, command.revision, "Dispatch preceded secure persistence")
        sent.append((command, incarnation))
        if hold.contains(command.revision) { await withCheckedContinuation { held[command.revision] = $0 } }
        if failOnce.remove(command.revision) != nil { throw AppFailure(message: "PRIVATE fixture response must not appear in status") }
        return ReminderDeviceReceipt(version: 1, device: command.device, revision: command.revision,
            account: badReceipt ? "wrong-owner" : command.account, state: command.binding == nil ? "retired" : "registered", enabled: false,
            expires_at_ms: Int64(clock.addingTimeInterval(30 * 86400).timeIntervalSince1970 * 1000))
    }
    func release(_ revision: Int64) { held.removeValue(forKey: revision)?.resume() }
    func engine() throws -> ReminderDeviceLifecycle {
        try ReminderDeviceLifecycle(installation: persisted, save: { try self.save($0) }, send: { c, i in try await self.send(c, incarnation: i) }, now: { self.clock })
    }
    var context: ReminderDeviceContext {
        .init(account: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", workspace: UUID(), session: UUID(),
              identity: .init(platform: .ios, bundle: "com.dbakp.taskfold", environment: .development), timeZone: "Europe/Copenhagen", permission: .authorized)
    }
}

@MainActor final class ReminderDeviceLifecycleTests: XCTestCase {
    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 { if condition() { return }; await Task.yield() }
        XCTFail("Lifecycle did not reach the expected state", file: file, line: line)
    }
    func testFreshLaunchRequiresFreshTokenAndNeverEnablesRemoteDelivery() async throws {
        let fixture = LifecycleFixture(), engine = try fixture.engine(), context = fixture.context
        try engine.update(context, online: true)
        XCTAssertTrue(engine.needsToken); XCTAssertTrue(fixture.sent.isEmpty)
        engine.requestedToken(); XCTAssertFalse(engine.needsToken)
        try engine.receivedToken(Data([0, 15, 255]))
        await eventually { !engine.busy && fixture.sent.count == 1 }
        let command = fixture.sent[0].0
        XCTAssertEqual(command.binding?.token, "000fff"); XCTAssertEqual(command.binding?.enabled, false)
        XCTAssertEqual(fixture.sent[0].1, context.session)
        XCTAssertTrue(engine.status.contains("continue on this device"))
        let saved = try JSONEncoder().encode(fixture.persisted)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("000fff"))
        let restarted = try fixture.engine(); try restarted.update(context, online: true)
        XCTAssertTrue(restarted.needsToken, "A launch must not reuse a cached APNs address")
        // Restart conservatively unlinks an earlier registration before the fresh callback.
        await eventually { !restarted.busy }; XCTAssertNil(fixture.sent.last?.0.binding)
    }
    func testForegroundUnchangedBindingIsQuietAndLeaseRenewalReservesNewFence() async throws {
        let fixture = LifecycleFixture(), engine = try fixture.engine(), context = fixture.context
        try engine.update(context, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { !engine.busy && fixture.sent.count == 1 }
        for _ in 0..<5 { try engine.update(context, online: true); try engine.receivedToken(Data([0xaa])) }
        XCTAssertEqual(fixture.sent.count, 1); XCTAssertEqual(fixture.persisted.revision, 1)
        fixture.clock = fixture.clock.addingTimeInterval(24 * 86400)
        try engine.update(context, online: true)
        await eventually { !engine.busy && fixture.sent.count == 2 }
        XCTAssertEqual(fixture.sent.last?.0.revision, 2); XCTAssertFalse(fixture.persisted.pendingRetirement)
    }
    func testSignOutPersistsProofBeforeDispatchAndRestartRetriesExactAnonymousCommand() async throws {
        let fixture = LifecycleFixture(), engine = try fixture.engine(), context = fixture.context
        try engine.update(context, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { !engine.busy && fixture.sent.count == 1 }
        try engine.update(context, online: false); try engine.retire()
        XCTAssertTrue(fixture.persisted.pendingRetirement); XCTAssertEqual(fixture.persisted.revision, 2)
        XCTAssertEqual(fixture.sent.count, 1)
        let saved = try JSONEncoder().encode(fixture.persisted)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(context.account))
        fixture.persisted = try JSONDecoder().decode(ReminderDeviceInstallation.self, from: saved)
        let restarted = try fixture.engine(); try restarted.update(nil, online: true)
        await eventually { !restarted.busy && fixture.sent.count == 2 }
        XCTAssertEqual(fixture.sent.last?.0.revision, 2); XCTAssertNil(fixture.sent.last?.0.account); XCTAssertNil(fixture.sent.last?.1)
        XCTAssertFalse(fixture.persisted.pendingRetirement); XCTAssertFalse(restarted.retirementPending)
    }
    func testLostAcknowledgementRetriesSameRegistrationAndNeverLeaksProviderError() async throws {
        let fixture = LifecycleFixture(); fixture.failOnce = [1]
        let engine = try fixture.engine(); try engine.update(fixture.context, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { !engine.busy && fixture.sent.count == 1 }
        XCTAssertFalse(engine.status.contains("PRIVATE"))
        try engine.retry(); XCTAssertEqual(fixture.sent.count, 1, "Automatic retries should respect backoff")
        try engine.retry(force: true)
        await eventually { !engine.busy && fixture.sent.count == 2 }
        XCTAssertEqual(fixture.sent[0].0, fixture.sent[1].0); XCTAssertEqual(fixture.persisted.revision, 1)
    }
    func testAccountSwitchDiscardsHeldOldResponseThenRetiresBeforeNewBinding() async throws {
        let fixture = LifecycleFixture(); fixture.hold = [1]
        let engine = try fixture.engine(), original = fixture.context
        try engine.update(original, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { fixture.held[1] != nil }
        var next = original; next.account = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"; next.workspace = UUID(); next.session = UUID()
        try engine.update(next, online: true)
        await eventually { fixture.sent.count == 3 && !engine.busy }
        fixture.release(1); await Task.yield()
        XCTAssertEqual(fixture.sent.map { $0.0.revision }, [1,2,3])
        XCTAssertNil(fixture.sent[1].0.binding); XCTAssertNil(fixture.sent[1].1)
        XCTAssertEqual(fixture.sent[2].0.account, next.account); XCTAssertEqual(fixture.sent[2].1, next.session)
        XCTAssertEqual(fixture.persisted.revision, 3); XCTAssertFalse(fixture.persisted.pendingRetirement)
    }
    func testSameAccountReentryAndTimeZoneChangesFenceEarlierContext() async throws {
        let fixture = LifecycleFixture(), engine = try fixture.engine(); var context = fixture.context
        try engine.update(context, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { !engine.busy && fixture.sent.count == 1 }
        context.session = UUID(); try engine.update(context, online: true)
        await eventually { !engine.busy && fixture.sent.count == 3 }
        XCTAssertEqual(fixture.sent.last?.1, context.session)
        context.timeZone = "America/New_York"; try engine.update(context, online: true)
        await eventually { !engine.busy && fixture.sent.count == 5 }
        XCTAssertEqual(fixture.sent.last?.0.binding?.time_zone, "America/New_York")
    }
    func testPermissionOptOutWhileResponseHeldCannotBecomeReadyAndTokenAfterSignOutCannotEnroll() async throws {
        let fixture = LifecycleFixture(); fixture.hold = [1]
        let engine = try fixture.engine(); try engine.update(fixture.context, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { fixture.held[1] != nil }
        try engine.update(nil, online: true)
        await eventually { !engine.busy && fixture.sent.count == 2 }
        fixture.release(1); try engine.receivedToken(Data([0xbb])); await Task.yield()
        XCTAssertEqual(fixture.sent.count, 2); XCTAssertNil(fixture.sent.last?.0.binding)
        XCTAssertFalse(engine.status.contains("registration is confirmed"))
    }
    func testSecureSaveFailurePreventsOldDispatchAndRetirementCanBeRetried() async throws {
        let fixture = LifecycleFixture(), engine = try fixture.engine()
        try engine.update(fixture.context, online: true)
        fixture.saveFails = true; XCTAssertThrowsError(try engine.receivedToken(Data([0xaa])))
        XCTAssertEqual(fixture.persisted.revision, 0); XCTAssertTrue(fixture.sent.isEmpty)
        fixture.saveFails = false; try engine.retry(force: true)
        await eventually { !engine.busy && fixture.sent.count == 1 }
        fixture.saveFails = true; XCTAssertThrowsError(try engine.retire())
        XCTAssertTrue(engine.retirementPending); XCTAssertEqual(fixture.persisted.revision, 1)
        fixture.saveFails = false; try engine.retry(force: true)
        await eventually { !engine.busy && fixture.sent.count == 2 }
        XCTAssertNil(fixture.sent.last?.0.binding); XCTAssertEqual(fixture.sent.last?.0.revision, 2)
    }
    func testRetirementAckSaveFailureSurvivesRestartAndWrongReceiptCannotBecomeReady() async throws {
        let fixture = LifecycleFixture(), engine = try fixture.engine()
        try engine.update(fixture.context, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { !engine.busy && fixture.sent.count == 1 }
        fixture.hold = [2]; try engine.retire(); await eventually { fixture.held[2] != nil }
        fixture.saveFails = true; fixture.release(2)
        await eventually { !engine.busy }; XCTAssertTrue(fixture.persisted.pendingRetirement)
        fixture.saveFails = false
        let restarted = try fixture.engine(); try restarted.update(nil, online: true); fixture.hold = []
        await eventually { !restarted.busy }; XCTAssertFalse(fixture.persisted.pendingRetirement)
        try restarted.update(fixture.context, online: true); await eventually { !restarted.busy }
        fixture.badReceipt = true; try restarted.receivedToken(Data([0xbb]))
        await eventually { !restarted.busy }; XCTAssertTrue(restarted.status.contains("waiting for confirmation")); XCTAssertNotNil(fixture.sent.last?.0.binding)
    }
    func testTokenRotationAndFailureDiscardOldAddressAndInvalidContextNeverDispatches() async throws {
        let fixture = LifecycleFixture(), engine = try fixture.engine(), context = fixture.context
        var invalid = context; invalid.permission = .denied
        XCTAssertThrowsError(try engine.update(invalid, online: true)); XCTAssertTrue(fixture.sent.isEmpty)
        try engine.update(context, online: true); try engine.receivedToken(Data([0xaa]))
        await eventually { !engine.busy && fixture.sent.count == 1 }
        try engine.receivedToken(Data([0xbb])); await eventually { !engine.busy && fixture.sent.count == 2 }
        XCTAssertEqual(fixture.sent.last?.0.binding?.token, "bb"); engine.failedToken(); XCTAssertTrue(engine.needsToken); XCTAssertTrue(engine.status.contains("could not be checked"))
        try engine.update(context, online: true); XCTAssertEqual(fixture.sent.count, 2)
        engine.requestedToken(); fixture.clock = fixture.clock.addingTimeInterval(61); XCTAssertTrue(engine.needsToken, "Missing callbacks must be retryable")
        try engine.receivedToken(Data()); XCTAssertEqual(fixture.sent.count, 2)
    }
    func testOlderInstallationDecodesWithoutCleanupIntentAndNeverStoresADeviceAddress() throws {
        let old = Data("{\"id\":\"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\",\"secret\":\"\(String(repeating: "a",count:64))\",\"revision\":3}".utf8)
        let value = try JSONDecoder().decode(ReminderDeviceInstallation.self, from: old)
        XCTAssertTrue(value.valid); XCTAssertFalse(value.pendingRetirement); XCTAssertNil(value.retirement)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        XCTAssertEqual(Set(object.keys), Set(["id","secret","revision","pendingRetirement"]))
    }
    func testBackendRejectsEarlierSameAccountIncarnationBeforeUsingNewCredentials() async throws {
        let fixture = LifecycleFixture(), context = fixture.context
        let sessionData = try JSONSerialization.data(withJSONObject: ["access_token":"fixture-only", "refresh_token":"fixture-only",
            "expires_at":Date().addingTimeInterval(86400).timeIntervalSince1970, "user":["id":context.account]])
        let session = try JSONDecoder().decode(Session.self, from: sessionData)
        let backend = Backend(configuration: [:], session: session, persistSession: { _ in })
        let original = backend.reminderSessionIncarnation
        try backend.clearSession(); backend.session = session
        var installation = fixture.persisted
        let command = try installation.reserve(account: context.account, binding: .init(platform:.ios,bundle:context.identity.bundle,environment:.development,
            token:"aa",time_zone:"UTC",permission:.authorized,enabled:false))
        do { _ = try await backend.sendReminderDevice(command, expectedIncarnation: original); XCTFail("An earlier incarnation used replacement credentials") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class ReminderExecutableEntitlementTests: XCTestCase {
    private func put(_ value: UInt32, into bytes: inout Data, at offset: Int, little: Bool = false) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (little ? i * 8 : (3 - i) * 8)) & 255) }
    }
    private func thin(_ environment: String) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["aps-environment":environment, "application-identifier":"ABCDEFGHIJ.com.dbakp.taskfold"], format:.xml, options:0)
        let total = 20 + 8 + plist.count; var bytes = Data(repeating:0,count:48+total)
        put(0xcffaedfe,into:&bytes,at:0); put(0x0100000c,into:&bytes,at:4,little:true)
        put(1,into:&bytes,at:16,little:true); put(16,into:&bytes,at:20,little:true)
        put(0x1d,into:&bytes,at:32,little:true); put(16,into:&bytes,at:36,little:true)
        put(48,into:&bytes,at:40,little:true); put(UInt32(total),into:&bytes,at:44,little:true)
        put(0xfade0cc0,into:&bytes,at:48); put(UInt32(total),into:&bytes,at:52); put(1,into:&bytes,at:56)
        put(5,into:&bytes,at:60); put(20,into:&bytes,at:64); put(0xfade7171,into:&bytes,at:68); put(UInt32(8+plist.count),into:&bytes,at:72)
        bytes.replaceSubrange(76..<bytes.count,with:plist); return bytes
    }
    func testSignedMetadataSelectsEnvironmentRatherThanBuildConfiguration() throws {
        for (raw,expected) in [("development",ReminderDeviceBinding.Environment.development),("production",.production)] {
            let bytes=try thin(raw); XCTAssertEqual(ReminderExecutableEntitlements.environment(bytes,bundle:"com.dbakp.taskfold"),expected)
            XCTAssertNil(ReminderExecutableEntitlements.environment(bytes,bundle:"com.other"))
            for end in [0,3,31,47,bytes.count-1] { XCTAssertNil(ReminderExecutableEntitlements.environment(bytes.prefix(end),bundle:"com.dbakp.taskfold")) }
        }
        XCTAssertNil(ReminderExecutableEntitlements.environment(try thin("unsupported"),bundle:"com.dbakp.taskfold"))
    }
    func testMalformedCommandsSignatureAndEntitlementBoundsFailClosed() throws {
        let original=try thin("production")
        for (offset,value,little) in [(16,UInt32.max,true),(20,UInt32.max,true),(36,UInt32(4),true),(40,UInt32(0),true),(44,UInt32.max,true),(52,UInt32(8),false),(56,UInt32.max,false),(64,UInt32.max,false),(68,UInt32(0),false),(72,UInt32.max,false)] {
            var bytes=original; put(value,into:&bytes,at:offset,little:little)
            XCTAssertNil(ReminderExecutableEntitlements.environment(bytes,bundle:"com.dbakp.taskfold"),"Malformed field at \(offset)")
        }
    }
    func testUniversalSliceOffsetsAreRelativeAndMixedEnvironmentsAreRejected() throws {
        let a=try thin("production"),b=try thin("production"); var fat=Data(repeating:0,count:48)
        put(0xcafebabe,into:&fat,at:0);put(2,into:&fat,at:4)
        for (slot,offset,size) in [(8,48,a.count),(28,48+a.count,b.count)] {
            put(0x0100000c,into:&fat,at:slot);put(UInt32(offset),into:&fat,at:slot+8);put(UInt32(size),into:&fat,at:slot+12)
        }
        fat.append(a);fat.append(b);XCTAssertEqual(ReminderExecutableEntitlements.environment(fat,bundle:"com.dbakp.taskfold"),.production)
        let c=try thin("development");put(UInt32(c.count),into:&fat,at:40);fat.replaceSubrange(48+a.count..<fat.count,with:c)
        XCTAssertNil(ReminderExecutableEntitlements.environment(fat,bundle:"com.dbakp.taskfold"))
        put(32,into:&fat,at:4);XCTAssertNil(ReminderExecutableEntitlements.environment(fat,bundle:"com.dbakp.taskfold"))
    }
}
final class ReminderDeviceTests: XCTestCase {
    let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let device = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    var initial: ReminderDeviceInstallation { .init(id: device, secret: String(repeating: "a", count: 64)) }
    var binding: ReminderDeviceBinding { .init(platform: .ios, bundle: "com.dbakp.taskfold", environment: .development, token: "0aff", time_zone: "Europe/Copenhagen", permission: .authorized, enabled: false) }
    func testAddressBytesAreOpaqueVariableLengthAndBadDocumentsFailClosed() throws {
        XCTAssertEqual(ReminderDeviceBinding.address(Data([0,1,15,255])), "00010fff")
        XCTAssertNil(ReminderDeviceBinding.address(Data())); XCTAssertNil(ReminderDeviceBinding.address(Data(repeating: 1, count: 513)))
        XCTAssertTrue(binding.valid)
        for token in ["", "abc", "AB", "ag", String(repeating: "a", count: 1026)] { var b=binding; b.token=token; XCTAssertFalse(b.valid) }
        var b=binding; b.bundle="com.other"; XCTAssertFalse(b.valid)
        b=binding; b.time_zone="Mars/City"; XCTAssertFalse(b.valid)
        b=binding; b.enabled=true; b.permission = .denied; XCTAssertFalse(b.valid)
        b=binding; b.platform = .macos; XCTAssertFalse(b.valid); b.bundle="com.dbakp.taskfold.mac"; XCTAssertTrue(b.valid)
    }
    func testEnrollmentActivationRetirementAndAccountSwitchKeepMonotonicIdentity() throws {
        var value=initial, b=binding
        b.enabled=true; XCTAssertThrowsError(try value.reserve(account: owner,binding:b)); XCTAssertEqual(value.revision,0)
        let enrolled=try value.reserve(account:owner,binding:binding); b.enabled=true
        let activated=try value.reserve(account:owner,binding:b), retired=try value.reserve(account:nil,binding:nil)
        let rebound=try value.reserve(account:"cccccccc-cccc-4ccc-8ccc-cccccccccccc",binding:binding)
        XCTAssertEqual([enrolled.revision,activated.revision,retired.revision,rebound.revision],[1,2,3,4])
        XCTAssertEqual(rebound.device,enrolled.device); XCTAssertEqual(rebound.secret,enrolled.secret)
        XCTAssertEqual(try retired.body().keys.sorted(),["_device","_revision","_secret"])
        XCTAssertEqual(try enrolled.body().keys.sorted(),["_binding","_device","_revision","_secret"])
        let restored=try JSONDecoder().decode(ReminderDeviceInstallation.self,from:JSONEncoder().encode(value)); XCTAssertEqual(restored,value)
        let next=try restoredCommand(restored); XCTAssertEqual(next.revision,5)
    }
    func restoredCommand(_ value: ReminderDeviceInstallation) throws -> ReminderDeviceCommand { var v=value; return try v.reserve(account:nil,binding:nil) }
    func testInvalidCapabilityExhaustedRevisionAndPartialCommandsDoNotAdvance() throws {
        var invalid=initial; invalid.secret="broken"; XCTAssertThrowsError(try invalid.reserve(account:nil,binding:nil))
        var last=initial; last.revision=ReminderDeviceInstallation.maximumRevision; XCTAssertThrowsError(try last.reserve(account:nil,binding:nil)); XCTAssertEqual(last.revision,ReminderDeviceInstallation.maximumRevision)
        var valid=initial; XCTAssertThrowsError(try valid.reserve(account:nil,binding:binding)); XCTAssertEqual(valid.revision,0)
        let malformed=ReminderDeviceCommand(device:device,secret:initial.secret,revision:0,account:nil,binding:nil); XCTAssertThrowsError(try malformed.body())
        let generated=try ReminderDeviceInstallation.make(); XCTAssertTrue(generated.valid); XCTAssertNotEqual(generated.secret,initial.secret)
    }
    func testOnlyExactCurrentReceiptCanConfirmReadyRegistration() throws {
        var value=initial; let command=try value.reserve(account:owner,binding:binding), now=Date(timeIntervalSince1970:1_791_273_600)
        let good=ReminderDeviceReceipt(version:1,device:device,revision:1,account:owner,state:"registered",enabled:false,expires_at_ms:Int64(now.addingTimeInterval(86400).timeIntervalSince1970*1000))
        XCTAssertTrue(good.confirms(command,now:now))
        var bad=good; bad.version=2; XCTAssertFalse(bad.confirms(command,now:now))
        bad=good; bad.revision=2; XCTAssertFalse(bad.confirms(command,now:now))
        bad=good; bad.account="other"; XCTAssertFalse(bad.confirms(command,now:now))
        bad=good; bad.enabled=true; XCTAssertFalse(bad.confirms(command,now:now))
        bad=good; bad.expires_at_ms=Int64(now.timeIntervalSince1970*1000); XCTAssertFalse(bad.confirms(command,now:now))
        bad=good; bad.state="retired"; XCTAssertFalse(bad.confirms(command,now:now))
        let retired=try value.reserve(account:nil,binding:nil)
        let receipt=ReminderDeviceReceipt(version:1,device:device,revision:2,account:nil,state:"retired",enabled:false,expires_at_ms:Int64(now.timeIntervalSince1970*1000))
        XCTAssertTrue(receipt.confirms(retired,now:now)); XCTAssertFalse(good.confirms(retired,now:now))
    }
    func testReserveIsSavedBeforeDispatchAndStorageFailureDoesNotConsumeFence() async throws {
        let memory=DeviceMemory(), commands=try ReminderDeviceCommands(installation:initial,save:{ try memory.save($0) })
        memory.fail=true
        do { _=try await commands.reserve(account:owner,binding:binding); XCTFail("Failed storage returned a dispatchable command") } catch { }
        memory.fail=false
        let first=try await commands.reserve(account:owner,binding:binding)
        XCTAssertEqual(first.revision,1); XCTAssertEqual(memory.saved.map(\.revision),[1])
        let next=try await commands.reserve(account:nil,binding:nil); XCTAssertEqual(next.revision,2); XCTAssertEqual(memory.saved.map(\.revision),[1,2])
    }
}
