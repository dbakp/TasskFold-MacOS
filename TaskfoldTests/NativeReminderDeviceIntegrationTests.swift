import XCTest
@testable import TaskfoldCore

final class NativeReminderDeviceIntegrationTests: XCTestCase {
    @MainActor func testRealAuthSessionsRetryRebindRetireAndRejectStaleCommands() async throws {
        guard let path=ProcessInfo.processInfo.environment["TASKFOLD_DEVICE_LIVE_FIXTURE"] else { throw XCTSkip("Disposable device-binding fixture not supplied") }
        let f=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let email=try XCTUnwrap(f["email"]), password=try XCTUnwrap(f["password"]), otherEmail=try XCTUnwrap(f["otherEmail"]), owner=try XCTUnwrap(f["userID"]), other=try XCTUnwrap(f["otherID"]), id=try XCTUnwrap(f["deviceID"])
        guard [email,otherEmail].allSatisfy({ $0.hasPrefix("taskfold-device-") && $0.hasSuffix("@example.invalid") }), UUID(uuidString:id) != nil else { throw AppFailure(message:"Use a disposable device fixture.") }
        let configuration=["URL":try XCTUnwrap(f["url"]),"Key":try XCTUnwrap(f["key"])]
        func api() -> Backend { Backend(configuration:configuration,http:URLSession(configuration:.ephemeral),session:nil,persistSession:{ _ in }) }
        let a=api(), b=api(), c=api()
        let signedA=try await a.signIn(email:email,password:password,signup:false)
        let signedB=try await b.signIn(email:email,password:password,signup:false)
        let signedC=try await c.signIn(email:otherEmail,password:password,signup:false)
        XCTAssertTrue(signedA && signedB && signedC); XCTAssertEqual(a.session?.user.id,owner); XCTAssertEqual(c.session?.user.id,other)
        XCTAssertNotEqual(a.session?.access_token,b.session?.access_token)
        let platform=ReminderDeviceBinding.Platform(rawValue:f["platform"] ?? "")!
        var binding=ReminderDeviceBinding(platform:platform,bundle:platform == .ios ? "com.dbakp.taskfold":"com.dbakp.taskfold.mac",environment:.development,token:id.replacingOccurrences(of:"-",with:""),time_zone:"Europe/Copenhagen",permission:.authorized,enabled:false)
        let secret=try XCTUnwrap(f["deviceSecret"])
        var command=ReminderDeviceCommand(device:id,secret:secret,revision:1,account:owner,binding:binding)
        func rejection(_ api: Backend,_ command: ReminderDeviceCommand,contains: String) async throws {
            do { _=try await api.sendReminderDevice(command); XCTFail("Server accepted a stale or unverified binding") }
            catch let error as AppFailure { XCTAssertTrue(error.message.contains(contains),error.message) }
        }
        do {
            let first=try await a.sendReminderDevice(command), retry=try await a.sendReminderDevice(command)
            var stableFirst = first, stableRetry = retry
            XCTAssertNotNil(first.server_time_ms); XCTAssertNotNil(retry.server_time_ms)
            stableFirst.server_time_ms = nil; stableRetry.server_time_ms = nil
            XCTAssertEqual(stableFirst, stableRetry); XCTAssertFalse(first.enabled)
            binding.enabled=true; command.binding=binding; command.revision=2
            let active=try await b.sendReminderDevice(command); XCTAssertTrue(active.enabled)
            var old=command; old.revision=1; old.binding?.enabled=false
            try await rejection(a,old,contains:"TASKFOLD_DEVICE_CONFLICT")
            var outsider=command; outsider.account=other; outsider.revision=3; outsider.secret=String(repeating:"f",count:64)
            try await rejection(c,outsider,contains:"could not be verified")
            outsider.secret=secret; outsider.binding?.enabled=false
            let rebound=try await c.sendReminderDevice(outsider); XCTAssertEqual(rebound.account,other); XCTAssertFalse(rebound.enabled)
            try await rejection(b,command,contains:"TASKFOLD_DEVICE_CONFLICT")
            try a.clearSession()
            let retired=ReminderDeviceCommand(device:id,secret:secret,revision:4,account:nil,binding:nil)
            let ended=try await a.sendReminderDevice(retired); XCTAssertEqual(ended.state,"retired"); XCTAssertNil(ended.account)
            try await rejection(c,outsider,contains:"TASKFOLD_DEVICE_CONFLICT")
        } catch {
            _=try? await c.sendReminderDevice(ReminderDeviceCommand(device:id,secret:secret,revision:20,account:nil,binding:nil))
            throw error
        }
    }
}
