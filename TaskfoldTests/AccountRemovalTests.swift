import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class RemovalMemoryIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var fail = false
    func setFailure(_ value: Bool) { lock.lock(); fail = value; lock.unlock() }
    func seed(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }; data = value
    }
    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }; data = nil
    }
}
final class AccountRemovalTests: XCTestCase {
    let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    func command(_ account: String? = nil, token: String = "original-token") throws -> AccountRemovalCommand {
        try .init(account: account ?? owner, origin: "https://removal.test", authorization: token)
    }
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testDurableOriginalAuthorizationSurvivesNewVaultAndRefusesUnconfirmedFinish() async throws {
        let io = RemovalMemoryIO(), vault = AccountRemovalVault(io: io), first = try command()
        let saved = try await vault.begin(first); XCTAssertEqual(saved, first)
        let restarted = AccountRemovalVault(io: io)
        let pending = try await restarted.pending(); XCTAssertEqual(pending, [first])
        let duplicate = try await restarted.begin(command(token: "refreshed-token")); XCTAssertEqual(duplicate.authorization, "original-token")
        do { try await restarted.finish(first); XCTFail("Unconfirmed cleanup discarded its retry capability") } catch {}
        let confirmed = try await restarted.confirm(first)
        XCTAssertTrue(confirmed.confirmed)
        let afterRestart = try await AccountRemovalVault(io: io).pending(); XCTAssertEqual(afterRestart, [confirmed])
        try await restarted.finish(confirmed)
        let empty = try await restarted.pending(); XCTAssertTrue(empty.isEmpty)
    }
    func testFailedSecureConfirmationAndFinishRemainRecoverableAndNeverTouchAnotherAccount() async throws {
        let io = RemovalMemoryIO(), vault = AccountRemovalVault(io: io)
        let a = try await vault.begin(command()), b = try await vault.begin(command(other))
        io.setFailure(true)
        do { _ = try await vault.confirm(a); XCTFail("Failed secure write pretended durability") } catch {}
        let unchanged = try await vault.pending(); XCTAssertEqual(unchanged, [a,b])
        io.setFailure(false); let confirmed = try await vault.confirm(a)
        io.setFailure(true)
        do { try await vault.finish(confirmed); XCTFail("Failed cleanup acknowledgement pretended durability") } catch {}
        let retained = try await vault.pending(); XCTAssertEqual(retained, [confirmed,b])
        io.setFailure(false); try await vault.finish(confirmed)
        let remaining = try await vault.pending(); XCTAssertEqual(remaining, [b])
    }
    func testMalformedRecoveryAndOriginChangesPreserveStoredData() async throws {
        let io = RemovalMemoryIO(), vault = AccountRemovalVault(io: io), bad = Data("unsupported protected state".utf8)
        io.seed(bad)
        do { _ = try await vault.begin(command()); XCTFail("Corrupt recovery overwritten") } catch {}
        XCTAssertEqual(try io.read(key: "unused"), bad)
        io.seed(try JSONEncoder().encode([command()]))
        do { _ = try await vault.command(account: owner, origin: "https://elsewhere.test"); XCTFail("Original bearer could be sent to another server") } catch {}
        XCTAssertThrowsError(try AccountRemovalCommand(account: "../outside", origin: "https://removal.test", authorization: "token"))
        XCTAssertThrowsError(try AccountRemovalCommand(account: owner, origin: "https://removal.test?redirect=elsewhere", authorization: "token"))
    }
    func testCacheRemovalIsIdempotentAndStopsDelayedWritersWithoutErasingOtherWorkspace() throws {
        let directory = try root(), a = AccountRemovalDisk(directory: directory, account: owner), b = AccountRemovalDisk(directory: directory, account: other)
        let old = Data("A private cache".utf8), outside = Data("B private queue".utf8)
        try a.writable { try old.write(to: a.cache) }; try b.writable { try outside.write(to: b.cache) }
        try a.removeCache(); try a.removeCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.cache.path)); XCTAssertEqual(try Data(contentsOf: b.cache), outside)
        XCTAssertThrowsError(try AccountRemovalDisk(directory: directory, account: owner).writable { try old.write(to: a.cache) })
        try b.writable { try outside.write(to: b.cache) }
        XCTAssertThrowsError(try AccountRemovalDisk(directory: directory, account: "../outside").removeCache())
    }
    func testBackupWipeCannotBeRecreatedByDelayedSaveAndKeepsOtherVault() throws {
        let directory = try root(), aGate = AccountRemovalDisk(directory: directory, account: owner)
        let key = SymmetricKey(size: .bits256)
        let a = BackupVault(directory: directory.appendingPathComponent("a-vault"), account: owner, key: { key }, removalGate: aGate)
        let b = BackupVault(directory: directory.appendingPathComponent("b-vault"), account: other, key: { key })
        _ = try a.save(Snapshot(), kind: "Synthetic"); let outside = try b.save(Snapshot(), kind: "Synthetic")
        try aGate.removeCache(); try a.removeAll(); try a.removeAll()
        XCTAssertTrue(try a.entries().isEmpty); XCTAssertEqual(try b.entries().map(\.id), [outside.id]); XCTAssertEqual(try b.load(outside).workspace.sourceAccount, other)
        XCTAssertThrowsError(try a.save(Snapshot(), kind: "Delayed old backup"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
    }
    func testPrivatePlacesConsentAndReceiptsPurgeOnlyDeletedAccountAndRejectStaleJournal() async throws {
        let directory = try root(), store = LocationPrivateStore(applicationSupport: directory)
        let a = try XCTUnwrap(LocationPrivatePlace.make(account: owner, name: "A private place", latitude: 55, longitude: 12, radius: 200))
        let b = try XCTUnwrap(LocationPrivatePlace.make(account: other, name: "B private place", latitude: 56, longitude: 13, radius: 250))
        let first = try await store.save(a); _ = try await store.save(b)
        _ = try await store.setAllowance(account: owner, enabled: true, expectedDevice: first.device)
        _ = try await store.setAllowance(account: other, enabled: true, expectedDevice: first.device)
        let ticket = LocationReminderTicket(account: owner, device: first.device, taskID: UUID().uuidString.lowercased(), generation: UUID().uuidString.lowercased(), completionVersion: 0, specID: UUID().uuidString.lowercased(), placeID: a.id, placeRevision: a.revision, arm: UUID().uuidString.lowercased(), transition: "arrive")
        var stale = first.journal; XCTAssertTrue(stale.prepare(ticket)); try await store.saveJournal(stale)
        try AccountRemovalDisk(directory: directory, account: owner).removeCache()
        try await store.removeAccountData(owner); try await store.removeAccountData(owner)
        let state = try await store.snapshot()
        XCTAssertEqual(state?.places(for: other), [b]); XCTAssertEqual(state?.places(for: owner), [])
        XCTAssertEqual(state?.allowedAccounts, [other]); XCTAssertEqual(state?.device, first.device); XCTAssertTrue(state?.journal.entries.isEmpty == true)
        do { _ = try await store.save(a); XCTFail("Deleted place recreated") } catch {}
        do { try await store.saveJournal(stale); XCTFail("Deleted receipt recreated") } catch {}
        do { _ = try await store.setAllowance(account: owner, enabled: true, expectedDevice: first.device); XCTFail("Deleted consent restored") } catch {}
    }
    func testShareAndWidgetPurgeKeepCurrentOtherAccountPublicationAndDrafts() throws {
        let directory = try root(), share = SharedCaptureDisk(directory: directory)
        let a = SharedCaptureWorkspace(account: owner, generation: UUID(), label: "A"), b = SharedCaptureWorkspace(account: other, generation: UUID(), label: "B")
        try share.publish(a); try share.save(SharedCaptureDraft(workspace: a, content: .init(title: "A draft")))
        try share.publish(b); let bDraft = try SharedCaptureDraft(workspace: b, content: .init(title: "B draft")); try share.save(bDraft)
        try share.removeAccount(owner)
        XCTAssertEqual(try share.workspace(), b); XCTAssertEqual(try share.drafts(account: other), [bDraft])
        let widgets = WidgetActionDisk(directory: directory)
        var task = Record.task(user: other); task["title"] = .string("B task")
        let payload = try JSONEncoder().encode(WidgetProjection.payload(tasks: [task], projects: [], account: other))
        try widgets.publish(payload); try widgets.removeAccount(owner)
        XCTAssertEqual(try widgets.read().data, payload)
        try widgets.removeAccount(other); XCTAssertNil(try widgets.read().data)
        try share.removeAccount(other); XCTAssertNil(try share.workspace())
    }
}


extension AccountRemovalTests {
    func testRenewalIsDurableAndConditionalOnExactUnconfirmedOwnerAndServer() async throws {
        let io = RemovalMemoryIO(), vault = AccountRemovalVault(io: io)
        let original = try await vault.begin(command())
        do { _ = try await vault.renew(original, with: command(other, token: "new")); XCTFail("Other account replaced authorization") } catch {}
        io.setFailure(true)
        do { _ = try await vault.renew(original, with: command(token: "new")); XCTFail("Renewal pretended durability") } catch {}
        let preserved = try await vault.pending(); XCTAssertEqual(preserved, [original])
        io.setFailure(false)
        let renewed = try await vault.renew(original, with: command(token: "new"))
        let restarted = try await AccountRemovalVault(io: io).pending(); XCTAssertEqual(restarted, [renewed])
        do { _ = try await vault.renew(original, with: command(token: "late")); XCTFail("Stale renewal overwrote current command") } catch {}
        let confirmed = try await vault.confirm(renewed)
        do { _ = try await vault.renew(confirmed, with: command(token: "newer")); XCTFail("Confirmed local cleanup was reauthorized") } catch {}
    }
}
