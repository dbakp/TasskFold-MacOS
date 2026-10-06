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
