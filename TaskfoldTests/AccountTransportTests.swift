import XCTest
@testable import TaskfoldCore

/// A held HTTP response makes account-switch races deterministic without a real service.
private final class ScopedHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, ScopedHTTP) -> Void)?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    func finish(_ status: Int, _ data: Data) {
        lock.lock(); let active = !stopped; lock.unlock()
        guard active else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class HTTPGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ScopedHTTP?
    private var calls = 0
    func hold(_ request: ScopedHTTP) { lock.lock(); held = request; calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func release(_ status: Int, _ data: Data) { lock.lock(); let request = held; held = nil; lock.unlock(); request?.finish(status, data) }
}

final class AccountTransportTests: XCTestCase {
    let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    func signed(_ account: String, token: String = "old") throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"" + token + "\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + account + "\"}}").utf8))
    }
    @MainActor func backend(_ session: Session, save: @escaping (Session?) throws -> Void = { _ in }) -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScopedHTTP.self]
        return Backend(configuration: ["URL":"https://native-scope.test","Key":"public"], http: URLSession(configuration: config), session: session, persistSession: save)
    }
    @MainActor func testOldFocus401CannotRetryWithAnotherAccountsCredentials() async throws {
        let gate = HTTPGate(), started = expectation(description: "Original account's Focus request started")
        let next = try signed(other, token: "new"), data = try JSONEncoder().encode(next)
        var saved: Session?
        let api = backend(try signed(owner), save: { saved = $0 })
        ScopedHTTP.handler = { request, transport in
            if request.url?.path == "/auth/v1/token" { transport.finish(200, data) }
            else {
                XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_set_focus_session")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
                gate.hold(transport); started.fulfill()
            }
        }
        defer { ScopedHTTP.handler = nil }
        let session = try FocusSession(taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", minutes: 25)
        let change = try FocusSessionChange.make(session, current: nil, account: owner)
        let request = Task { @MainActor in try await api.send(change, expectedAccount: self.owner) }
        await fulfillment(of: [started], timeout: 3)
        _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
        gate.release(401, Data(#"{"message":"Expired token"}"#.utf8))
        do { _ = try await request.value; XCTFail("An old request must not retry under the new account") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.count, 1); XCTAssertEqual(api.session?.user.id, other); XCTAssertEqual(saved?.user.id, other)
    }
    @MainActor func testStaleQueueScopeIsRejectedBeforeAnyTransportIncludingSharedTaskEdits() async throws {
        let api = backend(try signed(other)); let calls = HTTPGate()
        ScopedHTTP.handler = { _, transport in calls.hold(transport); transport.finish(200, Data("[]".utf8)) }
        defer { ScopedHTTP.handler = nil }
        let mutation = Mutation(table: "tasks", recordID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", method: "PATCH", fields: ["title": .string("Old workspace edit")], baseline: ["title": .string("Original")])
        do { _ = try await api.send(mutation, expectedAccount: owner); XCTFail("A stale queue used the current account") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await api.request("/rest/v1/focus_sessions", expectedAccount: owner); XCTFail("A stale timer request used the current account") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.count, 0)
    }
    @MainActor func testJoinedRefreshCannotRestorePreviousAccountAfterNewSignIn() async throws {
        var expired = try signed(owner); expired.expires_at = 0
        let gate = HTTPGate(), started = expectation(description: "Shared refresh started")
        let next = try signed(other, token: "new"), data = try JSONEncoder().encode(next), oldData = try JSONEncoder().encode(signed(owner, token: "refreshed-old"))
        var saved: Session?
        let api = backend(expired, save: { saved = $0 })
        ScopedHTTP.handler = { request, transport in
            if request.url?.query?.contains("refresh_token") == true { gate.hold(transport); started.fulfill() }
            else { transport.finish(200, data) }
        }
        defer { ScopedHTTP.handler = nil }
        let first = Task { @MainActor in try await api.refreshIfNeeded() }
        await fulfillment(of: [started], timeout: 3)
        let joinedStarted = expectation(description: "Second caller joined the held refresh")
        let joined = Task { @MainActor in joinedStarted.fulfill(); try await api.refreshIfNeeded() }
        await fulfillment(of: [joinedStarted], timeout: 3)
        _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
        gate.release(200, oldData)
        for request in [first, joined] {
            do { try await request.value; XCTFail("A stale refresh replaced the accepted account") } catch { /* Cancellation/network cancellation both leave the new account intact. */ }
        }
        XCTAssertEqual(gate.count, 1); XCTAssertEqual(api.session?.user.id, other); XCTAssertEqual(saved?.user.id, other)
    }
}


extension AccountTransportTests {
    @MainActor func testActivityHistoryReadsBeyondOnePageUsingTheServerSequence() async throws {
        let api = backend(try signed(owner)); var calls = 0
        ScopedHTTP.handler = { request, transport in
            XCTAssertEqual(request.url?.path, "/rest/v1/task_activity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let after = query.first { $0.name == "sequence" }?.value
            XCTAssertEqual(query.first { $0.name == "order" }?.value, "sequence.asc")
            calls += 1
            let rows = after == "gt.0" ? (1...500).map { Record(["sequence": .number(Double($0))]) } : [Record(["sequence": .number(800)])]
            if calls == 2 { XCTAssertEqual(after, "gt.500") }
            transport.finish(200, try! JSONEncoder().encode(rows))
        }
        defer { ScopedHTTP.handler = nil }
        let rows = try await api.rows(TaskActivity.table)
        XCTAssertEqual(rows.count, 501); XCTAssertEqual(rows.last?["sequence"], .number(800)); XCTAssertEqual(calls, 2)
    }
    @MainActor func testActivityPageArrivingAfterAccountSwitchCannotContinueInAnotherWorkspace() async throws {
        for destination in [other, owner] {
            let gate = HTTPGate(), started = expectation(description: "Old activity page started")
            let api = backend(try signed(owner)), next = try JSONEncoder().encode(signed(destination, token: "new"))
            ScopedHTTP.handler = { request, transport in
                if request.url?.path == "/auth/v1/token" { transport.finish(200, next) }
                else { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old"); gate.hold(transport); started.fulfill() }
            }
            defer { ScopedHTTP.handler = nil }
            let read = Task { @MainActor in try await api.rows(TaskActivity.table) }
            await fulfillment(of: [started], timeout: 3)
            _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
            gate.release(200, try JSONEncoder().encode((1...500).map { Record(["sequence": .number(Double($0))]) }))
            do { _ = try await read.value; XCTFail("History combined workspaces") } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(gate.count, 1)
        }
    }
    @MainActor func testActivityHistoryCannotBeSubmittedAsANativeMutation() async throws {
        let api = backend(try signed(owner)); var calls = 0
        ScopedHTTP.handler = { _, transport in calls += 1; transport.finish(200, Data("[]".utf8)) }
        defer { ScopedHTTP.handler = nil }
        for table in [TaskActivity.table, TaskActivity.epochTable] {
            do { _ = try await api.send(Mutation(table: table, recordID: "fixture", method: "POST", fields: [:])); XCTFail("History was sent") }
            catch { XCTAssertEqual(error.localizedDescription, "Activity history is read-only.") }
        }
        XCTAssertEqual(calls, 0)
    }
}

extension AccountTransportTests {
    func reminderDeviceCommand(account: String? = nil, retire: Bool = false) -> ReminderDeviceCommand {
        .init(device:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",secret:String(repeating:"a",count:64),revision:1,account:retire ? nil : account ?? owner,
              binding:retire ? nil : .init(platform:.ios,bundle:"com.dbakp.taskfold",environment:.development,token:"aabb",time_zone:"UTC",permission:.authorized,enabled:false))
    }
    func reminderDeviceReceipt(_ command: ReminderDeviceCommand) throws -> Data {
        try JSONEncoder().encode(ReminderDeviceReceipt(version:1,device:command.device,revision:command.revision,account:command.account,
                                                       state:command.binding == nil ? "retired":"registered",enabled:command.binding?.enabled ?? false,
                                                       expires_at_ms:Int64(Date().addingTimeInterval(86400).timeIntervalSince1970*1000)))
    }
    @MainActor func testDeviceRegistrationUsesBoundJWTAndRetirementUsesRevocationCapabilityOnly() async throws {
        let api=backend(try signed(owner)), active=reminderDeviceCommand(), retired=reminderDeviceCommand(retire:true)
        ScopedHTTP.handler = { request,transport in
            let fields=try! JSONDecoder().decode([String:JSON].self,from:request.httpBody ?? { let stream=request.httpBodyStream!; stream.open(); defer { stream.close() }; var data=Data(),buffer=[UInt8](repeating:0,count:4096); while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count); if n<=0 { break }; data.append(buffer,count:n) }; return data }())
            let isRetired=request.url?.path == retired.path
            XCTAssertEqual(request.httpMethod,"POST"); XCTAssertEqual(fields["_secret"],.string(active.secret))
            XCTAssertNil(fields["account"]); XCTAssertNil(fields["user_id"])
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),isRetired ? nil:"Bearer old")
            transport.finish(200,try! self.reminderDeviceReceipt(isRetired ? retired:active))
        }
        defer { ScopedHTTP.handler=nil }
        let confirmed=try await api.sendReminderDevice(active); XCTAssertEqual(confirmed.state,"registered")
        try api.clearSession()
        let cleared=try await api.sendReminderDevice(retired); XCTAssertEqual(cleared.state,"retired")
    }
    @MainActor func testDeviceBindingResponseAfterSameAccountReentryCannotBeAccepted() async throws {
        let api=backend(try signed(owner)), command=reminderDeviceCommand(), gate=HTTPGate(), started=expectation(description:"Old binding registration in flight")
        let session=try JSONEncoder().encode(signed(owner,token:"new-login"))
        ScopedHTTP.handler = { request,transport in
            if request.url?.path == command.path { gate.hold(transport); started.fulfill() }
            else { transport.finish(200,session) }
        }
        defer { ScopedHTTP.handler=nil }
        let old=Task { @MainActor in try await api.sendReminderDevice(command) }
        await fulfillment(of:[started],timeout:3)
        _=try await api.signIn(email:"fixture@example.invalid",password:"fixture",signup:false)
        gate.release(200,try reminderDeviceReceipt(command))
        do { _=try await old.value; XCTFail("A late registration from before reentry was accepted") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.count,1); XCTAssertEqual(api.session?.access_token,"new-login")
    }
    @MainActor func testForeignDeviceCommandIsRejectedBeforeHTTPAndWrongReceiptNeverEnables() async throws {
        let api=backend(try signed(other)), command=reminderDeviceCommand(); var calls=0
        ScopedHTTP.handler = { _,transport in calls+=1; transport.finish(200,try! self.reminderDeviceReceipt(command)) }
        defer { ScopedHTTP.handler=nil }
        do { _=try await api.sendReminderDevice(command); XCTFail("Foreign command used current JWT") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls,0)
        let own=reminderDeviceCommand(account:other)
        do { _=try await api.sendReminderDevice(own); XCTFail("Wrong-account receipt was confirmed") } catch { XCTAssertTrue(error is AppFailure) }
        XCTAssertEqual(calls,1)
    }
}


extension AccountTransportTests {
    func snoozeMutation(minutes: Int = 15) -> Mutation {
        Mutation(table: ReminderSnooze.table, recordID: ReminderSnooze.recordID, method: "POST", fields: [
            "id": .string(ReminderSnooze.recordID), "user_id": .string(owner),
            "settings": .object(["version": .number(1), "snooze_minutes": .number(Double(minutes)), "extension": .string("old")])])
    }
    @MainActor func testSnoozeSyncSendsOnlyDelayAndAcceptsLatestServerMetadata() async throws {
        let api = backend(try signed(owner)); var calls = 0
        let latest = Record(["id": .string("current"), "user_id": .string(owner), "settings": .object([
            "version": .number(1), "snooze_minutes": .number(15), "extension": .string("newer device metadata")])])
        ScopedHTTP.handler = { request, transport in
            calls += 1; XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_set_reminder_snooze")
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
            let body = request.httpBody ?? {
                let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            }()
            XCTAssertEqual(try! JSONDecoder().decode([String: JSON].self, from: body), ["_minutes": .number(15)])
            transport.finish(200, try! JSONEncoder().encode(latest))
        }
        defer { ScopedHTTP.handler = nil }
        let saved = try await api.send(snoozeMutation(), expectedAccount: owner)
        XCTAssertEqual(saved, latest); XCTAssertEqual(calls, 1)
    }
    @MainActor func testSnoozeSyncRejectsWrongOwnerDelayAndUnsupportedQueueBeforeAcknowledgement() async throws {
        let api = backend(try signed(owner)); var calls = 0
        ScopedHTTP.handler = { _, transport in
            calls += 1
            transport.finish(200, try! JSONEncoder().encode(Record(["id": .string("current"), "user_id": .string(calls == 1 ? self.other : self.owner), "settings": .object(["version": .number(1), "snooze_minutes": .number(calls == 1 ? 15 : 30)])])))
        }
        defer { ScopedHTTP.handler = nil }
        for _ in 0..<2 {
            do { _ = try await api.send(snoozeMutation(), expectedAccount: owner); XCTFail("Unconfirmed preference was acknowledged") }
            catch { XCTAssertTrue(error.localizedDescription.contains("server did not confirm")) }
        }
        var future = snoozeMutation(); future.fields["settings"] = .object(["version": .number(2), "future": .string("preserved")])
        do { _ = try await api.send(future, expectedAccount: owner); XCTFail("Unsupported future queue submitted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("supported delay")) }
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testSnoozeResponseAfterWorkspaceReentryCannotBeAccepted() async throws {
        let api = backend(try signed(owner)), gate = HTTPGate(), started = expectation(description: "Old snooze request in flight")
        let next = try JSONEncoder().encode(signed(owner, token: "new-login"))
        ScopedHTTP.handler = { request, transport in
            if request.url?.path == "/auth/v1/token" { transport.finish(200, next) }
            else { gate.hold(transport); started.fulfill() }
        }
        defer { ScopedHTTP.handler = nil }
        let request = Task { @MainActor in try await api.send(self.snoozeMutation(), expectedAccount: self.owner) }
        await fulfillment(of: [started], timeout: 3)
        _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
        gate.release(200, try JSONEncoder().encode(Record(snoozeMutation().fields)))
        do { _ = try await request.value; XCTFail("Stale workspace accepted snooze receipt") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.count, 1)
    }
}

extension AccountTransportTests {
    func automaticMutation(minutes: Int = 15) -> Mutation {
        var result = snoozeMutation()
        result.reminderPreferenceField = ReminderAutomatic.field
        result.fields["settings"] = ReminderAutomatic.changing(result.fields["settings"]!, minutes: minutes)
        return result
    }
    @MainActor func testAutomaticSyncSendsOnlyOffsetAndConfirmsLatestOwnerMetadata() async throws {
        let api = backend(try signed(owner)); var calls = 0
        let latest = Record(["id": .string("current"), "user_id": .string(owner), "settings": .object(["version": .number(1), "snooze_minutes": .number(120), ReminderAutomatic.field: .number(15), "extension": .string("new")])])
        ScopedHTTP.handler = { request, transport in
            calls += 1; XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_set_automatic_reminder")
            let body = request.httpBody ?? {
                let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            }()
            XCTAssertEqual(try! JSONDecoder().decode([String: JSON].self, from: body), ["_minutes": .number(15)])
            transport.finish(200, try! JSONEncoder().encode(latest))
        }
        defer { ScopedHTTP.handler = nil }
        let saved = try await api.send(automaticMutation(), expectedAccount: owner)
        XCTAssertEqual(saved, latest); XCTAssertEqual(calls, 1)
        let encoded = try JSONEncoder().encode(automaticMutation())
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: encoded).reminderPreferenceField, ReminderAutomatic.field)
    }
    @MainActor func testAutomaticSyncRejectsUnconfirmedResponsesAndUnknownCommands() async throws {
        let api = backend(try signed(owner)); var calls = 0
        ScopedHTTP.handler = { _, transport in
            calls += 1
            var saved = Record(self.automaticMutation().fields)
            if calls == 1 { saved["user_id"] = .string(self.other) }
            if calls == 2 { saved["settings"] = ReminderAutomatic.changing(saved["settings"], minutes: 30)! }
            if calls == 3 { saved["settings"] = .object(["version": .number(2), "future": .string("keep")]) }
            transport.finish(200, try! JSONEncoder().encode(saved))
        }
        defer { ScopedHTTP.handler = nil }
        for _ in 0..<3 {
            do { _ = try await api.send(automaticMutation(), expectedAccount: owner); XCTFail("Unconfirmed choice acknowledged") }
            catch { XCTAssertTrue(error.localizedDescription.contains("server did not confirm")) }
        }
        for selector in ["unknown", ReminderAutomatic.field] {
            var invalid = automaticMutation(); invalid.reminderPreferenceField = selector
            if selector == ReminderAutomatic.field { invalid.fields["user_id"] = .string(other) }
            do { _ = try await api.send(invalid, expectedAccount: owner); XCTFail("Invalid command sent") }
            catch { XCTAssertTrue(error.localizedDescription.contains("supported delay")) }
        }
        XCTAssertEqual(calls, 3)
    }
}
