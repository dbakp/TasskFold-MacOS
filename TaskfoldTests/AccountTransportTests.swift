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

private final class SessionDiskFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "original"
    var value: String { lock.lock(); defer { lock.unlock() }; return stored }
    func save(_ value: String) { lock.lock(); stored = value; lock.unlock() }
}

final class AccountTransportTests: XCTestCase {
    let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    func signed(_ account: String, token: String = "old") throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"" + token + "\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + account + "\"}}").utf8))
    }
    private func replyToPreparation(_ request: URLRequest, _ transport: ScopedHTTP) -> Bool {
        guard request.value(forHTTPHeaderField: "X-Taskfold-Account-Removal-Proof") == nil else { return false }
        let body: [String: JSON] = ["prepared": .bool(true), "account": .string(owner), "proof": .string("fixture." + String(repeating: "a", count: 43))]
        transport.finish(200, try! JSONEncoder().encode(body)); return true
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
        try await api.clearSession()
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

extension AccountTransportTests {
    @MainActor func testAvatarResponseAfterAccountSwitchOrReentryIsDiscarded() async throws {
        for destination in [other, owner] {
            let api = backend(try signed(owner)), gate = HTTPGate()
            let started = expectation(description: "Avatar upload held")
            let next = try JSONEncoder().encode(signed(destination, token: "new-login"))
            ScopedHTTP.handler = { request, transport in
                if request.url?.path == "/auth/v1/token" { transport.finish(200, next) }
                else {
                    XCTAssertTrue(request.url!.path.hasPrefix("/storage/v1/object/avatars/" + self.owner + "/"))
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
                    gate.hold(transport); started.fulfill()
                }
            }
            defer { ScopedHTTP.handler = nil }
            let upload = Task { @MainActor in try await api.uploadAvatar(Data([1, 2, 3]), expectedAccount: self.owner) }
            await fulfillment(of: [started], timeout: 3)
            _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
            gate.release(200, Data())
            do { _ = try await upload.value; XCTFail("A stale upload returned a profile URL") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(gate.count, 1)
            XCTAssertEqual(api.session?.user.id, destination)
        }
    }
    @MainActor func testAvatarRejectsStalePickerOwnerBeforeHTTP() async throws {
        let api = backend(try signed(other)); var calls = 0
        ScopedHTTP.handler = { _, transport in calls += 1; transport.finish(200, Data()) }
        defer { ScopedHTTP.handler = nil }
        do { _ = try await api.uploadAvatar(Data([1]), expectedAccount: owner); XCTFail("Stale picker used new credentials") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testAvatarUploadReturnsOriginalOwnersURLOnSuccess() async throws {
        let api = backend(try signed(owner)); var calls = 0
        ScopedHTTP.handler = { request, transport in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
            XCTAssertTrue(request.url!.path.hasPrefix("/storage/v1/object/avatars/" + self.owner + "/"))
            transport.finish(200, Data())
        }
        defer { ScopedHTTP.handler = nil }
        let url = try await api.uploadAvatar(Data([1, 2, 3]), expectedAccount: owner)
        XCTAssertTrue(url.hasPrefix("https://native-scope.test/storage/v1/object/public/avatars/" + owner + "/"))
        XCTAssertTrue(url.hasSuffix(".jpg")); XCTAssertEqual(calls, 1)
    }
}

extension AccountTransportTests {
    @MainActor func testAvatarCannotStartStorageAfterAccountChangesDuringRefresh() async throws {
        var expired = try signed(owner); expired.expires_at = 0
        let api = backend(expired), gate = HTTPGate()
        let started = expectation(description: "Avatar token refresh held")
        let next = try JSONEncoder().encode(signed(other, token: "new-login"))
        let old = try JSONEncoder().encode(signed(owner, token: "refreshed-old"))
        var storageCalls = 0
        ScopedHTTP.handler = { request, transport in
            if request.url?.query?.contains("refresh_token") == true { gate.hold(transport); started.fulfill() }
            else if request.url?.path == "/auth/v1/token" { transport.finish(200, next) }
            else { storageCalls += 1; transport.finish(200, Data()) }
        }
        defer { ScopedHTTP.handler = nil }
        let upload = Task { @MainActor in try await api.uploadAvatar(Data([1]), expectedAccount: self.owner) }
        await fulfillment(of: [started], timeout: 3)
        _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
        gate.release(200, old)
        do { _ = try await upload.value; XCTFail("Old picker crossed a refresh/account boundary") }
        catch { /* Both cancellation forms leave the new account intact. */ }
        XCTAssertEqual(storageCalls, 0); XCTAssertEqual(api.session?.user.id, other)
    }
    @MainActor func testSuspendedSessionAcceptanceCannotResurrectAfterSignOut() async throws {
        let started = expectation(description: "Session write held")
        var release: CheckedContinuation<Void, Never>?
        let current = try signed(owner), next = try signed(other)
        let api = Backend(configuration: [:], session: current, persistSession: { value in
            if value != nil {
                await withCheckedContinuation { release = $0; started.fulfill() }
            }
        })
        let accepting = Task { try await api.accept(next) }
        await fulfillment(of: [started], timeout: 3)
        do { _ = try await api.request("/rest/v1/tasks"); XCTFail("A credential transition used the previous session") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await api.clearSession()
        release?.resume()
        do { try await accepting.value; XCTFail("A delayed sign-in revived the cleared session") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(api.session)
    }

    @MainActor func testFailedSessionClearRetainsCurrentSession() async throws {
        let current = try signed(owner)
        let api = Backend(configuration: [:], session: current, persistSession: { _ in
            throw AppFailure(message: "Test keychain unavailable")
        })
        do { try await api.clearSession(); XCTFail("Failed clearing must be reported") }
        catch { XCTAssertEqual(error.localizedDescription, "Test keychain unavailable") }
        XCTAssertEqual(api.session?.user.id, owner)
    }

    @MainActor func testSessionWritesRunOffMainAndClearFollowsHeldSave() async throws {
        let started = expectation(description: "Save started off main")
        let clear = expectation(description: "Clear finished off main")
        let gate = DispatchSemaphore(value: 0)
        let durable = SessionDiskFixture()
        let save = Task {
            try await SessionPersistence.perform {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                guard gate.wait(timeout: .now() + 5) == .success else { throw AppFailure(message: "Test gate timed out") }
                durable.save("saved")
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let remove = Task {
            try await SessionPersistence.perform {
                XCTAssertFalse(Thread.isMainThread)
                durable.save("cleared")
                clear.fulfill()
            }
        }
        // This code still executes on the main actor while the credential write is held.
        XCTAssertTrue(Thread.isMainThread)
        gate.signal()
        try await save.value; try await remove.value
        await fulfillment(of: [clear], timeout: 3)
        XCTAssertEqual(durable.value, "cleared")
    }

    @MainActor func testDelayedClearCannotEraseNewAcceptedSession() async throws {
        let started = expectation(description: "Credential clear held")
        var release: CheckedContinuation<Void, Never>?
        let current = try signed(owner), next = try signed(other)
        let api = Backend(configuration: [:], session: current, persistSession: { value in
            if value == nil {
                await withCheckedContinuation { release = $0; started.fulfill() }
            }
        })
        let clearing = Task { try await api.clearSession() }
        await fulfillment(of: [started], timeout: 3)
        try await api.accept(next)
        release?.resume()
        do { try await clearing.value; XCTFail("An old sign-out erased a newer sign-in") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(api.session?.user.id, other)
        XCTAssertEqual(api.session?.access_token, next.access_token)
    }

}

extension AccountTransportTests {
    @MainActor func testPasswordResponseCannotReturnAfterSignOut() async throws {
        let gate = HTTPGate(), started = expectation(description: "Password response held")
        var writes = 0
        let api = backend(try signed(owner), save: { _ in writes += 1 })
        let response = try JSONEncoder().encode(signed(other, token: "late"))
        ScopedHTTP.handler = { _, transport in gate.hold(transport); started.fulfill() }
        defer { ScopedHTTP.handler = nil }
        let signingIn = Task { try await api.signIn(email: "late@example.invalid", password: "fixture", signup: false) }
        await fulfillment(of: [started], timeout: 3)
        try await api.clearSession()
        gate.release(200, response)
        do { _ = try await signingIn.value; XCTFail("An abandoned password response signed in again") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(api.session)
        XCTAssertEqual(writes, 1, "Only the explicit clear may persist")
    }

    @MainActor func testEarlierPasswordResponseCannotReplaceNewerSignIn() async throws {
        let gate = HTTPGate(), started = expectation(description: "First password response held")
        var saved: Session?
        let api = backend(try signed(owner), save: { saved = $0 })
        let old = try JSONEncoder().encode(signed(owner, token: "late-old"))
        let next = try JSONEncoder().encode(signed(other, token: "latest"))
        var calls = 0
        ScopedHTTP.handler = { _, transport in
            calls += 1
            if calls == 1 { gate.hold(transport); started.fulfill() }
            else { transport.finish(200, next) }
        }
        defer { ScopedHTTP.handler = nil }
        let earlier = Task { try await api.signIn(email: "earlier@example.invalid", password: "fixture", signup: false) }
        await fulfillment(of: [started], timeout: 3)
        let accepted = try await api.signIn(email: "latest@example.invalid", password: "fixture", signup: false)
        XCTAssertTrue(accepted)
        gate.release(200, old)
        do { _ = try await earlier.value; XCTFail("Earlier authentication replaced the user's newer choice") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(api.session?.user.id, other)
        XCTAssertEqual(saved?.access_token, "latest")
    }
}

extension AccountTransportTests {
    @MainActor func testTemplateEditsUseGuardedRPCAndConfirmSavedFields() async throws {
        let api=backend(try signed(owner)),id="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let base:[String:JSON]=["id":.string(id),"user_id":.string(owner),"name":.string("Original"),"document":.object(["version":.number(1)])]
        var response=base;response["name"] = .string("Edited")
        let data=try JSONEncoder().encode(Record(response)),called=expectation(description:"Guarded template edit")
        ScopedHTTP.handler={request,transport in
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_edit_template");XCTAssertEqual(request.httpMethod,"POST")
            let body=try? JSONDecoder().decode([String:JSON].self,from:request.httpBody ?? { let stream=request.httpBodyStream!;stream.open();defer{stream.close()};var data=Data(),buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let count=stream.read(&buffer,maxLength:buffer.count);if count<=0{break};data.append(buffer,count:count) };return data }())
            XCTAssertEqual(body?["_base"],.object(base));XCTAssertEqual(body?["_changes"],.object(["name":.string("Edited")]));XCTAssertEqual(body?["_delete"],.bool(false))
            transport.finish(200,data);called.fulfill()
        }
        defer{ScopedHTTP.handler=nil}
        let saved=try await api.send(Mutation(table:WorkflowTemplate.table,recordID:id,method:"PATCH",fields:["name":.string("Edited")],baseline:base),expectedAccount:owner)
        XCTAssertEqual(saved?.name,"Edited");await fulfillment(of:[called],timeout:2)
    }
    @MainActor func testTemplateConflictAndMissingBaselineNeverSendBlindPatch() async throws {
        let api=backend(try signed(owner)),gate=HTTPGate(),id="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        ScopedHTTP.handler={_,transport in gate.hold(transport);transport.finish(409,Data(#"{"message":"TASKFOLD_CONFLICT: overlapping template"}"#.utf8))}
        defer{ScopedHTTP.handler=nil}
        let base:[String:JSON]=["name":.string("Original"),"document":.object(["version":.number(1)])]
        do{_ = try await api.send(Mutation(table:WorkflowTemplate.table,recordID:id,method:"PATCH",fields:["name":.string("Edited")]));XCTFail("Missing baseline sent")}catch{XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"))}
        XCTAssertEqual(gate.count,0)
        do{_ = try await api.send(Mutation(table:WorkflowTemplate.table,recordID:id,method:"PATCH",fields:["name":.string("Edited")],baseline:base));XCTFail("Overlap accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"))}
        XCTAssertEqual(gate.count,1)
    }
}

extension AccountTransportTests {
    @MainActor func testTemplateRestoreCannotUpsertOverAnotherDevicesEdit() async throws {
        let api=backend(try signed(owner)),id="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let desired:[String:JSON]=["id":.string(id),"user_id":.string(owner),"name":.string("Older restored copy"),"document":.object(["version":.number(1)])]
        var remote=desired;remote["name"] = .string("Other device edited this")
        let data=try JSONEncoder().encode([Record(remote)]),posted=expectation(description:"Insert ignores existing identity"),fetched=expectation(description:"Existing template compared")
        ScopedHTTP.handler={request,transport in
            if request.httpMethod=="POST" {
                XCTAssertTrue(request.value(forHTTPHeaderField:"Prefer")?.contains("resolution=ignore-duplicates")==true)
                transport.finish(200,Data("[]".utf8));posted.fulfill()
            } else { transport.finish(200,data);fetched.fulfill() }
        }
        defer{ScopedHTTP.handler=nil}
        do { _ = try await api.send(Mutation(table:WorkflowTemplate.table,recordID:id,method:"POST",fields:desired));XCTFail("A stale restoration overwrote the current template") }
        catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"),error.localizedDescription) }
        await fulfillment(of:[posted,fetched],timeout:2)
    }
}

extension AccountTransportTests {
    @MainActor func testProductivityGoalCreationAndEditsUseGuardedRPCWithExactBaselines() async throws {
        let api=backend(try signed(owner)),owner=self.owner
        var goals=try ProductivityGoals();goals.timeZone="UTC";goals.dailyTarget=5;goals.weeklyTarget=20
        let first=try ProductivityGoalEdit.command(goals.document,previous:nil,account:owner)
        var original=ProductivityGoalEdit.emptyRow(account:owner);original[ProductivityGoals.field]=goals.document
        goals.dailyTarget=6;let second=try ProductivityGoalEdit.command(goals.document,previous:original,account:owner)
        let expected=[first,second],called=expectation(description:"Guarded goal saves");called.expectedFulfillmentCount=2
        var index=0
        ScopedHTTP.handler={request,transport in
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_set_productivity_goals");XCTAssertEqual(request.httpMethod,"POST")
            let data=request.httpBody ?? {let stream=request.httpBodyStream!;stream.open();defer{stream.close()};var data=Data(),buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<=0{break};data.append(buffer,count:count)};return data}()
            let body=try? JSONDecoder().decode([String:JSON].self,from:data),change=expected[index];index+=1
            XCTAssertEqual(body,["_base":change.baseline![ProductivityGoals.field]!,"_goals":change.fields[ProductivityGoals.field]!])
            var saved=ProductivityGoalEdit.emptyRow(account:owner);saved[ProductivityGoals.field]=change.fields[ProductivityGoals.field]!;saved["sort_by"] = .string("title")
            transport.finish(200,try! JSONEncoder().encode(saved));called.fulfill()
        }
        defer{ScopedHTTP.handler=nil}
        let savedFirst=try await api.send(first,expectedAccount:owner);XCTAssertEqual(savedFirst?[ProductivityGoals.field],first.fields[ProductivityGoals.field])
        let savedSecond=try await api.send(second,expectedAccount:owner);XCTAssertEqual(savedSecond?[ProductivityGoals.field],second.fields[ProductivityGoals.field])
        await fulfillment(of:[called],timeout:2)
    }
    @MainActor func testGoalUnknownBaselineNeedsReviewAndConflictPropagatesWithoutBlindPatch() async throws {
        let api=backend(try signed(owner)),gate=HTTPGate()
        var goals=try ProductivityGoals();goals.timeZone="UTC";goals.dailyTarget=3
        var change=try ProductivityGoalEdit.command(goals.document,previous:nil,account:owner)
        change.baseline?[ProductivityGoals.field] = .object(["version":.number(2)])
        ScopedHTTP.handler={_,transport in gate.hold(transport);transport.finish(400,Data(#"{"message":"TASKFOLD_CONFLICT: Goals changed"}"#.utf8))};defer{ScopedHTTP.handler=nil}
        do{_ = try await api.send(change);XCTFail("Unsupported baseline sent")}catch{XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"))};XCTAssertEqual(gate.count,0)
        change.baseline?[ProductivityGoals.field] = .null
        do{_ = try await api.send(change);XCTFail("Stale save accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"))};XCTAssertEqual(gate.count,1)
    }
    @MainActor func testGoalServerAcknowledgementMustConfirmOwnerAndCompleteChoice() async throws {
        let api=backend(try signed(owner));var goals=try ProductivityGoals();goals.timeZone="UTC";goals.dailyTarget=3
        let change=try ProductivityGoalEdit.command(goals.document,previous:nil,account:owner)
        var wrong=ProductivityGoalEdit.emptyRow(account:owner);wrong[ProductivityGoals.field] = .null
        let data=try JSONEncoder().encode(wrong)
        ScopedHTTP.handler={_,transport in transport.finish(200,data)};defer{ScopedHTTP.handler=nil}
        do{_ = try await api.send(change);XCTFail("Unconfirmed goal choice was acknowledged")}catch{XCTAssertTrue(error.localizedDescription.contains("did not confirm"))}
    }
}


extension AccountTransportTests {
    @MainActor func testAccountRemovalRequiresExplicitBooleanConfirmation() async throws {
        let api = backend(try signed(owner))
        defer { ScopedHTTP.handler = nil }
        for body in ["", "{}", "null", "[]", "{\"deleted\":false}", "{\"deleted\":\"true\"}", "not JSON", String(repeating: " ", count: 5000) + "{\"deleted\":true}"] {
            ScopedHTTP.handler = { request, transport in
                XCTAssertEqual(request.url?.path, "/functions/v1/delete-account")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Taskfold-Account-Removal"), "2")
                XCTAssertEqual(request.httpMethod, "POST")
                if self.replyToPreparation(request, transport) { return }
                transport.finish(200, Data(body.utf8))
            }
            do { try await api.deleteAccount(); XCTFail("Unconfirmed removal accepted: " + body) }
            catch { XCTAssertTrue(error.localizedDescription.contains("did not confirm")) }
            XCTAssertEqual(api.session?.user.id, owner)
        }
        ScopedHTTP.handler = { request, transport in
            if request.value(forHTTPHeaderField: "X-Taskfold-Account-Removal-Proof") == nil {
                let body: [String: JSON] = ["prepared": .bool(true), "account": .string(self.owner), "proof": .string("fixture." + String(repeating: "a", count: 43))]
                transport.finish(200, try! JSONEncoder().encode(body))
            } else { transport.finish(200, Data(#"{"deleted":true}"#.utf8)) }
        }
        try await api.deleteAccount()
        // Store owns local cleanup after confirmation; the transport never clears a session.
        XCTAssertEqual(api.session?.user.id, owner)
    }
    @MainActor func testDelayedRemovalCannotConfirmForAnotherAccountOrNewSignIn() async throws {
        for destination in [other, owner] {
            let gate = HTTPGate(), started = expectation(description: "Deletion response held")
            let api = backend(try signed(owner))
            ScopedHTTP.handler = { request, transport in
                if self.replyToPreparation(request, transport) { return }
                gate.hold(transport); started.fulfill()
            }
            defer { ScopedHTTP.handler = nil }
            let deleting = Task { @MainActor in try await api.deleteAccount() }
            await fulfillment(of: [started], timeout: 3)
            try await api.accept(signed(destination, token: "new"))
            gate.release(200, Data(#"{"deleted":true}"#.utf8))
            do { try await deleting.value; XCTFail("Old response confirmed a newer workspace") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(api.session?.user.id, destination)
            XCTAssertEqual(api.session?.access_token, "new")
        }
    }
    @MainActor func testRemovalRefusalPreservesSessionAndDoesNotReportSuccess() async throws {
        let api = backend(try signed(owner))
        ScopedHTTP.handler = { _, transport in transport.finish(503, Data(#"{"error":"Retry removal"}"#.utf8)) }
        defer { ScopedHTTP.handler = nil }
        do { try await api.deleteAccount(); XCTFail("Refused removal reported success") }
        catch { XCTAssertEqual(error.localizedDescription, "Retry removal") }
        XCTAssertEqual(api.session?.user.id, owner)
        XCTAssertEqual(api.session?.access_token, "old")
    }
}

extension AccountTransportTests {
    @MainActor func testPersistedRemovalUsesOriginalTokenAfterExpiryAndAnotherAccountSignIn() async throws {
        let api = backend(try signed(owner)), command = try await api.accountRemovalCommand().prepared(with: "fixture." + String(repeating: "a", count: 43))
        var next = try signed(other, token: "B-current"); next.expires_at = 0
        try await api.accept(next)
        var calls = 0
        ScopedHTTP.handler = { request, transport in
            calls += 1
            XCTAssertEqual(request.url?.path, "/functions/v1/delete-account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
            XCTAssertFalse(request.httpShouldHandleCookies)
            transport.finish(200, Data(#"{"deleted":true}"#.utf8))
        }
        defer { ScopedHTTP.handler = nil }
        try await api.performAccountRemoval(command)
        XCTAssertEqual(calls, 1); XCTAssertEqual(api.session?.user.id, other); XCTAssertEqual(api.session?.access_token, "B-current")
    }
    @MainActor func testLostRemovalReplyRetriesExactAuthorizationWithoutRefreshingDeadSession() async throws {
        let api = backend(try signed(owner)), command = try await api.accountRemovalCommand().prepared(with: "fixture." + String(repeating: "a", count: 43))
        var calls = 0
        ScopedHTTP.handler = { request, transport in
            calls += 1
            XCTAssertEqual(request.url?.path, "/functions/v1/delete-account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
            if calls == 1 { transport.finish(503, Data(#"{"error":"Reply lost; retry"}"#.utf8)) }
            else { transport.finish(200, Data(#"{"deleted":true}"#.utf8)) }
        }
        defer { ScopedHTTP.handler = nil }
        do { try await api.performAccountRemoval(command); XCTFail("Lost result was accepted") } catch {}
        api.session?.expires_at = 0
        try await api.performAccountRemoval(command)
        XCTAssertEqual(calls, 2); XCTAssertEqual(api.session?.access_token, "old")
    }
    @MainActor func testRemovalCommandCannotSendItsBearerToChangedServerAndConfirmedRecoveryNeedsNoNetwork() async throws {
        let api = backend(try signed(owner))
        var calls = 0
        ScopedHTTP.handler = { _, transport in calls += 1; transport.finish(200, Data(#"{"deleted":true}"#.utf8)) }
        defer { ScopedHTTP.handler = nil }
        let foreign = try AccountRemovalCommand(account: owner, origin: "https://another.test", authorization: "private-fixture")
        do { try await api.performAccountRemoval(foreign); XCTFail("Bearer reached another host") } catch {}
        var confirmed = try await api.accountRemovalCommand().prepared(with: "fixture." + String(repeating: "a", count: 43)); confirmed.confirmed = true
        try await api.performAccountRemoval(confirmed)
        XCTAssertEqual(calls, 0)
    }
}


extension AccountTransportTests {
    @MainActor func testExplicitRemovalRefusalCanRenewOnlyCurrentAccountBeforeRetry() async throws {
        let api = backend(try signed(owner)), original = try await api.accountRemovalCommand().prepared(with: "fixture." + String(repeating: "a", count: 43))
        let refreshed = try JSONEncoder().encode(signed(owner, token: "renewed"))
        var calls: [String] = []
        ScopedHTTP.handler = { request, transport in
            let path = request.url!.path; calls.append(path)
            if path == "/auth/v1/token" { transport.finish(200, refreshed) }
            else if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" { transport.finish(401, Data(#"{"error":"Sign in again"}"#.utf8)) }
            else { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed"); transport.finish(200, Data(#"{"deleted":true}"#.utf8)) }
        }
        defer { ScopedHTTP.handler = nil }
        do { try await api.performAccountRemoval(original); XCTFail("401 accepted") }
        catch { XCTAssertTrue(error is AccountRemovalAuthorizationRequired) }
        XCTAssertEqual(calls, ["/functions/v1/delete-account"], "No automatic refresh may discard the original receipt authorization")
        let replacement = try await api.accountRemovalCommand(forceRefresh: true).prepared(with: "fixture." + String(repeating: "a", count: 43))
        XCTAssertEqual(replacement.account, owner); XCTAssertEqual(replacement.authorization, "renewed")
        try await api.performAccountRemoval(replacement)
        XCTAssertEqual(calls, ["/functions/v1/delete-account", "/auth/v1/token", "/functions/v1/delete-account"])
    }
}

extension AccountTransportTests {
    @MainActor func testExecutionWithoutPersistableProofNeverSendsRequest() async throws {
        let api = backend(try signed(owner)), command = try await api.accountRemovalCommand()
        var calls = 0
        ScopedHTTP.handler = { _, _ in calls += 1 }; defer { ScopedHTTP.handler = nil }
        do { try await api.performAccountRemoval(command); XCTFail("Unprepared deletion sent") } catch {}
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testPreparationRequiresMatchingAccountAndBoundedOpaqueProof() async throws {
        let api = backend(try signed(owner)), command = try await api.accountRemovalCommand()
        defer { ScopedHTTP.handler = nil }
        for body in [#"{"prepared":true,"account":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","proof":"a.b"}"#,
                     #"{"prepared":true,"account":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","proof":"a.b"}"#,
                     #"{"prepared":"true"}"#, #"{"deleted":true}"#] {
            ScopedHTTP.handler = { request, transport in
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Taskfold-Account-Removal-Proof"))
                let sentBody = request.httpBody ?? { let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 64); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }; return data }()
                XCTAssertEqual(sentBody, Data(#"{"action":"prepare"}"#.utf8))
                transport.finish(200, Data(body.utf8))
            }
            do { _ = try await api.prepareAccountRemoval(command); XCTFail("Invalid preparation accepted") } catch {}
        }
    }
}

extension AccountTransportTests {
    @MainActor func testConnectionRefreshReplaysTheOriginalIntentOnlyOnce() async throws {
        for path in ["/functions/v1/automation-webhooks", "/functions/v1/automation-keys"] {
            var refreshed = 0, requests = 0, intents: [[String:JSON]] = []
            let api = backend(try signed(owner)), next = try JSONEncoder().encode(signed(owner,token:"renewed"))
            ScopedHTTP.handler = { request, transport in
                if request.url?.path == "/auth/v1/token" { refreshed += 1; transport.finish(200,next); return }
                XCTAssertEqual(request.url?.path,path)
                requests += 1
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating:0,count:4096)
                    while stream.hasBytesAvailable { let n = stream.read(&bytes,maxLength:bytes.count); if n <= 0 { break }; data.append(bytes,count:n) }
                }
                if let body = try? JSONDecoder().decode([String:JSON].self,from:data) { intents.append(body) }
                if requests == 1 { transport.finish(401,Data(#"{"message":"Expired"}"#.utf8)) }
                else {
                    XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer renewed")
                    transport.finish(200,try! JSONEncoder().encode(["account":JSON.string(self.owner)]))
                }
            }
            defer { ScopedHTTP.handler = nil }
            let fields:[String:JSON] = ["id":.string(UUID().uuidString.lowercased()),"name":.string("Synthetic connection")]
            if path.hasSuffix("webhooks") { _ = try await api.webhookReceipt(action:"create",body:fields,account:owner,origin:"https://native-scope.test") }
            else { _ = try await api.request(path,method:"POST",body:["action":.string("create"),"body":.object(fields)],extra:["X-Taskfold-Automation":"1"],expectedAccount:owner) }
            XCTAssertEqual(refreshed,1); XCTAssertEqual(requests,2); XCTAssertEqual(intents.count,2)
            XCTAssertTrue(intents.first == intents.last,"Automatic renewal must replay the original intent")
            XCTAssertEqual(api.session?.user.id,owner)
        }
    }
    @MainActor func testConnectionRepeated401RequiresSignInWithoutExposingServerDetails() async throws {
        for path in ["/functions/v1/automation-webhooks", "/functions/v1/automation-keys"] {
            var renewals = 0, requests = 0
            let api = backend(try signed(owner)), next = try JSONEncoder().encode(signed(owner,token:"renewed"))
            ScopedHTTP.handler = { request, transport in
                if request.url?.path == "/auth/v1/token" { renewals += 1; transport.finish(200,next) }
                else { requests += 1; transport.finish(401,Data(#"{"message":"PRIVATE SERVER DETAIL"}"#.utf8)) }
            }
            defer { ScopedHTTP.handler = nil }
            do { _ = try await api.request(path,method:"POST",body:["action":.string("list")],expectedAccount:owner); XCTFail("Rejected session accepted") }
            catch { XCTAssertTrue(error is AccountSessionAuthorizationRequired); XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
            XCTAssertEqual(renewals,1); XCTAssertEqual(requests,2)
            XCTAssertEqual(api.session?.user.id,owner,"Authorization failure must not discard the saved account")
        }
    }
    @MainActor func testRevokedRefreshCodesRequireSignInButTransientFailuresDoNot() async throws {
        for (status,code,requiresSignIn) in [
            (400,"refresh_token_not_found",true),(400,"refresh_token_already_used",true),
            (400,"session_expired",true),(422,"session_not_found",true),
            (400,"unexpected_failure",false),(429,"over_request_rate_limit",false),
            (500,"session_expired",false)
        ] {
            let api = backend(try signed(owner)); var refreshes = 0, requests = 0
            ScopedHTTP.handler = { request, transport in
                if request.url?.path == "/auth/v1/token" {
                    refreshes += 1
                    transport.finish(status,try! JSONEncoder().encode(["code":code,"message":"PRIVATE AUTH DETAIL"]))
                } else { requests += 1; transport.finish(401,Data(#"{"message":"Expired"}"#.utf8)) }
            }
            defer { ScopedHTTP.handler = nil }
            do { _ = try await api.webhookReceipt(action:"list",body:[:],account:owner,origin:"https://native-scope.test"); XCTFail("Renewal failure accepted") }
            catch { XCTAssertEqual(error is AccountSessionAuthorizationRequired,requiresSignIn); if requiresSignIn { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) } }
            XCTAssertEqual(refreshes,1); XCTAssertEqual(requests,1)
            XCTAssertEqual(api.session?.access_token,"old")
        }
    }
    @MainActor func testLateRejectedConnectionRefreshCannotAffectAnotherAccount() async throws {
        let gate = HTTPGate(), started = expectation(description:"Old account's refresh started")
        let api = backend(try signed(owner)), otherSession = try JSONEncoder().encode(signed(other,token:"other"))
        var requests = 0
        ScopedHTTP.handler = { request, transport in
            if request.url?.query?.contains("refresh_token") == true { gate.hold(transport); started.fulfill() }
            else if request.url?.path == "/auth/v1/token" { transport.finish(200,otherSession) }
            else { requests += 1; XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer old"); transport.finish(401,Data("{}".utf8)) }
        }
        defer { ScopedHTTP.handler = nil }
        let old = Task { @MainActor in try await api.webhookReceipt(action:"list",body:[:],account:self.owner,origin:"https://native-scope.test") }
        await fulfillment(of:[started],timeout:3)
        _ = try await api.signIn(email:"synthetic@example.invalid",password:"synthetic",signup:false)
        gate.release(400,Data(#"{"code":"refresh_token_not_found"}"#.utf8))
        do { _ = try await old.value; XCTFail("Old request must not recover under a different account") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(api.session?.user.id,other); XCTAssertEqual(requests,1)
    }
}
