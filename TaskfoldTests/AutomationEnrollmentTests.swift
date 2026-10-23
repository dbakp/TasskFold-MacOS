import XCTest
@testable import TaskfoldCore

private final class EnrollmentMemoryIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var failWrite = false
    var failRemove = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return storage[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw AutomationKey.invalid }; storage[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw AutomationKey.invalid }; storage[key] = nil }
}
@MainActor private final class EnrollmentService: AutomationKeyService {
    var submitted: [AutomationKeyDraft] = []
    var row: AutomationKey?
    var loseReply = false
    var failRevoke = false
    var onRegister: (() -> Void)?
    var held: CheckedContinuation<Void, Never>?
    var hold = false
    var pages: [AutomationKeyPage] = []
    var cursors: [String?] = []
    var filters: [Bool] = []
    func automationKeyPage(account: String, origin: String, cursor: String?, includeInactive: Bool) async throws -> AutomationKeyPage {
        cursors.append(cursor); filters.append(includeInactive)
        if !pages.isEmpty { return pages.removeFirst() }
        return try AutomationKeyPage(["account": .string(account), "keys": .array([]), "next_cursor": .null], account: account)
    }
    func registerAutomationKey(_ draft: AutomationKeyDraft) async throws -> AutomationKey {
        submitted.append(draft)
        row = try Self.key(draft)
        if hold { await withCheckedContinuation { held = $0; onRegister?() } }
        if loseReply { throw URLError(.networkConnectionLost) }
        return row!
    }
    func revokeAutomationKey(id: String, account: String, origin: String) async throws -> AutomationKey {
        if failRevoke { throw URLError(.notConnectedToInternet) }
        guard let row, row.id == id else { throw AutomationKey.invalid }
        var fields = Self.fields(id: row.id, name: row.name, scopes: row.scopes)
        fields["revoked_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        let result = try AutomationKey(fields); self.row = result; return result
    }
    static func fields(id: String, name: String = "Build script", scopes: [AutomationScope] = [.read]) -> [String: JSON] {
        let formatter = ISO8601DateFormatter(), now = Date()
        return ["id": .string(id), "name": .string(name), "prefix": .string("tfk_v1_" + id.replacingOccurrences(of: "-", with: "").prefix(8)),
                "scopes": .array(scopes.map { .string($0.rawValue) }), "created_at": .string(formatter.string(from: now)),
                "expires_at": .string(formatter.string(from: now.addingTimeInterval(30 * 86400))), "revoked_at": .null, "last_used_at": .null]
    }
    static func key(_ draft: AutomationKeyDraft) throws -> AutomationKey { try AutomationKey(fields(id: draft.id, name: draft.name, scopes: draft.scopes)) }
}
@MainActor final class AutomationEnrollmentTests: XCTestCase {
    let account = "f096cafe-0000-4000-8000-000000000001"
    let other = "f096cafe-0000-4000-8000-000000000002"
    let origin = "https://automation-enrollment.test"
    private func draft() throws -> AutomationKeyDraft { try AutomationKeyDraft(account: account, origin: origin, name: "Build script", scopes: [.read], days: 30) }
    private func model(_ service: EnrollmentService, _ vault: AutomationEnrollmentVault, current: @escaping () -> Bool = { true }) -> AutomationAccessModel {
        AutomationAccessModel(account: account, origin: origin, service: service, vault: vault, isCurrent: current)
    }
    func testLostReplyAndRelaunchReuseExactSecureEnrollment() async throws {
        let io = EnrollmentMemoryIO(), service = EnrollmentService(), vault = AutomationEnrollmentVault(io: io)
        let first = model(service, vault); service.loseReply = true
        await first.create(name: "Build script", scopes: [.read], days: 30)
        let original = try XCTUnwrap(first.pending)
        XCTAssertNil(first.secret); XCTAssertNotNil(first.message); first.close()
        let next = model(service, vault)
        await next.load(); XCTAssertEqual(next.pending?.id, original.id); XCTAssertNil(next.secret)
        service.loseReply = false; await next.resume()
        XCTAssertEqual(service.submitted.count, 2)
        XCTAssertEqual(service.submitted[0].body, service.submitted[1].body)
        XCTAssertEqual(next.secret, original.secretForOneTimeReview)
        XCTAssertFalse(String(describing: original).contains(original.secretForOneTimeReview))
        await next.acknowledgeSaved()
        XCTAssertNil(next.secret); XCTAssertNil(next.pending)
        let stored = try await vault.pending(account: account, origin: origin); XCTAssertNil(stored)
        let reopened = model(service, vault); await reopened.load(); XCTAssertNil(reopened.pending)
    }
    func testSecureWriteFailurePreventsAnyEnrollmentRequest() async {
        let io = EnrollmentMemoryIO(); io.failWrite = true
        let service = EnrollmentService(), value = model(service, AutomationEnrollmentVault(io: io))
        await value.create(name: "Build script", scopes: [.read], days: 30)
        XCTAssertTrue(service.submitted.isEmpty); XCTAssertNil(value.pending); XCTAssertNil(value.secret); XCTAssertNotNil(value.message)
    }
    func testLateReplyAfterCloseCannotRevealAndKeepsRecovery() async throws {
        let service = EnrollmentService(), vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO()), value = model(service, vault)
        service.hold = true
        let started = expectation(description: "Registration held")
        service.onRegister = { started.fulfill() }
        let request = Task { await value.create(name: "Build script", scopes: [.read], days: 30) }
        await fulfillment(of: [started], timeout: 3)
        value.close(); service.held?.resume(); await request.value
        XCTAssertNil(value.secret); XCTAssertNil(value.pending); XCTAssertTrue(value.keys.isEmpty)
        let stored = try await vault.pending(account: account, origin: origin); XCTAssertNotNil(stored)
    }
    func testAccountFenceRefusesSecretAfterSwitchWithoutDeletingRecovery() async throws {
        let service = EnrollmentService(), vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO())
        var current = true
        let value = model(service, vault, current: { current })
        await value.create(name: "Build script", scopes: [.read], days: 30)
        XCTAssertNotNil(value.secret); current = false; XCTAssertNil(value.secret)
        await value.acknowledgeSaved()
        let stored = try await vault.pending(account: account, origin: origin); XCTAssertNotNil(stored)
    }
    func testRevocationIsConfirmedBeforeRecoveryCanBeDiscarded() async throws {
        let io = EnrollmentMemoryIO(), service = EnrollmentService(), vault = AutomationEnrollmentVault(io: io), value = model(service, vault)
        await value.create(name: "Build script", scopes: [.read], days: 30)
        service.failRevoke = true; await value.revokePending()
        XCTAssertNotNil(value.pending); XCTAssertNotNil(value.secret)
        service.failRevoke = false; io.failRemove = true; await value.revokePending()
        XCTAssertNil(value.secret); XCTAssertNotNil(value.pending); XCTAssertNotNil(value.message)
        XCTAssertNotNil(value.keys.first?.revoked)
        io.failRemove = false; await value.revokePending()
        XCTAssertNil(value.pending)
        let stored = try await vault.pending(account: account, origin: origin); XCTAssertNil(stored)
    }
    func testAcknowledgementFailureRetainsRecoverableKey() async throws {
        let io = EnrollmentMemoryIO(), service = EnrollmentService(), vault = AutomationEnrollmentVault(io: io), value = model(service, vault)
        await value.create(name: "Build script", scopes: [.read], days: 30)
        io.failRemove = true; await value.acknowledgeSaved()
        XCTAssertNotNil(value.pending); XCTAssertNotNil(value.message)
        io.failRemove = false; await value.acknowledgeSaved(); XCTAssertNil(value.secret)
    }
    func testVaultSerializesCompetingWindowsAndRejectsStaleFinish() async throws {
        let vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO()), first = try draft(), competing = try draft(), lease = CalendarReadLease()
        let one = try await vault.begin(first, lease: lease), two = try await vault.begin(competing, lease: lease)
        XCTAssertEqual(one.id, two.id); XCTAssertEqual(one.body, two.body)
        try await vault.finish(one, lease: lease)
        let newer = try await vault.begin(competing, lease: lease)
        do { try await vault.finish(one, lease: lease); XCTFail("Stale finish erased newer recovery") } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await vault.pending(account: account, origin: origin); XCTAssertEqual(saved?.id, newer.id)
    }
    func testOriginAndAccountIsolationAndCancelledLease() async throws {
        let vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO()), draft = try draft(), lease = CalendarReadLease()
        _ = try await vault.begin(draft, lease: lease)
        let foreign = try await vault.pending(account: other, origin: origin); XCTAssertNil(foreign)
        do { _ = try await vault.pending(account: account, origin: "https://other.test"); XCTFail("Foreign origin read") } catch { }
        lease.cancel()
        do { try await vault.finish(draft, lease: lease); XCTFail("Cancelled finish") } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await vault.pending(account: account, origin: origin); XCTAssertEqual(saved?.id, draft.id)
        try await vault.removeAccount(account, origin: origin)
        let removed = try await vault.pending(account: account, origin: origin); XCTAssertNil(removed)
    }
    func testCorruptRecoveryCannotBeOverwrittenByNewKey() async throws {
        let io = EnrollmentMemoryIO(), vault = AutomationEnrollmentVault(io: io), draft = try draft()
        let key = "enrollment-v1." + account
        for data in [Data("{}".utf8), Data(repeating: 0, count: 4097)] {
            try io.write(data, key: key)
            do { _ = try await vault.begin(draft, lease: CalendarReadLease()); XCTFail("Overwrote unreadable recovery") } catch { }
            XCTAssertEqual(try io.read(key: key), data)
        }
    }
    func testPagingAndRefreshDoNotRetainAnUnverifiedSecret() async throws {
        let service = EnrollmentService(), vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO()), value = model(service, vault)
        await value.create(name: "Build script", scopes: [.read], days: 30)
        let id = service.submitted[0].id
        let row = EnrollmentService.fields(id: id)
        let second = EnrollmentService.fields(id: UUID().uuidString.lowercased())
        service.pages = [try AutomationKeyPage(["account": .string(account), "keys": .array([.object(row)]), "next_cursor": .string(id)], account: account),
                         try AutomationKeyPage(["account": .string(account), "keys": .array([.object(second)]), "next_cursor": .null], account: account)]
        value.selectHistory(true); XCTAssertTrue(value.includesInactive)
        await value.load(includeInactive: true)
        XCTAssertNil(value.secret); XCTAssertNotNil(value.pending); XCTAssertEqual(value.nextCursor, id)
        await value.load(includeInactive: true, more: true)
        XCTAssertEqual(value.keys.count, 2); XCTAssertNil(value.nextCursor)
        XCTAssertEqual(service.cursors.count, 2); XCTAssertEqual(service.cursors[1], id); XCTAssertEqual(service.filters, [true, true])
    }
    func testSavingInOneWindowRemovesRevealFromAnotherWindow() async throws {
        let service = EnrollmentService(), vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO())
        let first = model(service, vault), second = model(service, vault)
        await first.create(name: "Build script", scopes: [.read], days: 30)
        await second.load(); await second.resume()
        XCTAssertNotNil(first.secret); XCTAssertNotNil(second.secret)
        await first.acknowledgeSaved()
        XCTAssertNil(first.secret); XCTAssertNil(second.secret)
        await second.resume(); XCTAssertNil(second.pending)
    }

    func testCompetingDraftRequiresReviewBeforeItCanBeRegistered() async throws {
        let service = EnrollmentService(), vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO())
        let old = try draft()
        _ = try await vault.begin(old, lease: CalendarReadLease())
        let value = model(service, vault)
        await value.create(name: "Different tool", scopes: [.delete], days: 7)
        XCTAssertTrue(service.submitted.isEmpty)
        XCTAssertEqual(value.pending?.id, old.id); XCTAssertNil(value.secret); XCTAssertNotNil(value.message)
        await value.resume()
        XCTAssertEqual(service.submitted.first?.body, old.body)
    }

    func testReplacedRecoveryRequiresFreshReviewBeforeResume() async throws {
        let service = EnrollmentService(), vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO()), old = try draft()
        let lease = CalendarReadLease()
        _ = try await vault.begin(old, lease: lease)
        let value = model(service, vault); await value.load()
        try await vault.finish(old, lease: lease)
        let replacement = try AutomationKeyDraft(account: account, origin: origin, name: "Replacement", scopes: [.delete], days: 7)
        _ = try await vault.begin(replacement, lease: lease)
        await value.resume()
        XCTAssertTrue(service.submitted.isEmpty); XCTAssertEqual(value.pending?.id, replacement.id); XCTAssertNil(value.secret)
        await value.resume(); XCTAssertEqual(service.submitted.first?.body, replacement.body)
    }

    func testAccountRemovalPreservesAnotherServersEnrollment() async throws {
        let vault = AutomationEnrollmentVault(io: EnrollmentMemoryIO()), draft = try draft()
        _ = try await vault.begin(draft, lease: CalendarReadLease())
        try await vault.removeAccount(account, origin: "https://other.test")
        let saved = try await vault.pending(account: account, origin: origin)
        XCTAssertEqual(saved?.id, draft.id)
        try await vault.removeAccount(other, origin: origin)
        let stillSaved = try await vault.pending(account: account, origin: origin)
        XCTAssertEqual(stillSaved?.body, draft.body)
        try await vault.removeAccount(account, origin: origin)
        let removed = try await vault.pending(account: account, origin: origin); XCTAssertNil(removed)
    }

}
