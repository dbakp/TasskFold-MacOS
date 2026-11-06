import XCTest
import Darwin
@testable import TaskfoldCore

final class LocationResetRecoveryTests: XCTestCase {
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func record(device: String = UUID().uuidString.lowercased(), account: String = "reset-local") throws -> LocationNotificationAction {
        let place = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Private reset pin", latitude: 55, longitude: 12, radius: 250))
        var task = Record.task(user: account); task["task_generation"] = .string(UUID().uuidString.lowercased())
        let settings = try XCTUnwrap(LocationReminderSettings.make(device: device, taskID: task.id, taskGeneration: task.string("task_generation"), place: place, transition: .arrive, repeats: true))
        task["reminder_specs"] = .array([.object(settings.raw)])
        let ticket = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: task, settings: settings, place: place)).ticket
        return LocationNotificationAction(source: "la1:" + LocationReminderIdentity.digest([ticket.identifier]), ticket: ticket, action: .snooze, fireAt: 1_900_000_000, phase: .installed)
    }
    func reset(_ root: URL) throws -> LocationPrivateArchive { try LocationPrivateFile(applicationSupport: root).reset() }
    func testExplicitResetCreatesDurableFreshAuthorityAndConsentOff() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try reset(dir), second = try reset(dir)
        XCTAssertNotEqual(first.device, second.device); XCTAssertEqual(second.version, 3)
        XCTAssertTrue(second.places.isEmpty); XCTAssertTrue(second.journal.entries.isEmpty); XCTAssertEqual(second.allowedAccounts, [])
        XCTAssertEqual(second.supersedesEarlierInstallations, true); XCTAssertFalse(second.allows(account: "reset-local"))
        XCTAssertEqual(try LocationPrivateFile(applicationSupport: dir).read(), second)
        let golden = try XCTUnwrap(Bundle.module.url(forResource: "reset-location", withExtension: "json", subdirectory: "Fixtures"))
        let decoded = try LocationPrivateArchive.decode(Data(contentsOf: golden))
        XCTAssertEqual(decoded.supersedesEarlierInstallations, true); XCTAssertEqual(decoded.version, 3)
    }
    func testMissingAndLegacyArchivesCannotAuthorizeResetCleanup() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = LocationPrivateFile(applicationSupport: dir)
        XCTAssertThrowsError(try file.withResetAuthority(account: "reset-local", device: UUID().uuidString.lowercased()) { _ in XCTFail("Missing authority") })
        var archive = LocationPrivateArchive()
        XCTAssertThrowsError(try LocationInstallationReset(account: "reset-local", archive: archive))
        archive.version = 2; archive.allowedAccounts = []
        XCTAssertThrowsError(try LocationInstallationReset(account: "reset-local", archive: archive))
        archive.supersedesEarlierInstallations = true; XCTAssertFalse(archive.valid)
    }
    func testResetProofRemovesOnlyEarlierDevicesInTheCurrentAccount() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), current = try record(device: archive.device), old = try record(), other = try record(account: "other")
        let proof = try LocationInstallationReset(account: "reset-local", archive: archive)
        let rows = [current.source: current, old.source: old, other.source: other]
        XCTAssertEqual(try proof.retaining(rows), [current.source: current, other.source: other])
    }
    func testOldAuthorityCannotDeleteNewInstallationReceipts() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = try reset(dir), current = try reset(dir), receipt = try record(device: current.device)
        let file = LocationPrivateFile(applicationSupport: dir)
        XCTAssertThrowsError(try file.withResetAuthority(account: "reset-local", device: old.device) { proof in _ = try proof.retaining([receipt.source: receipt]); XCTFail("Stale reset reached writer") })
        XCTAssertEqual(try file.read(), current)
    }
    func testPrivateWriterLockCoversTheAtomicCacheEdit() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), a = LocationPrivateFile(applicationSupport: dir), b = LocationPrivateFile(applicationSupport: dir)
        try a.withResetAuthority(account: "reset-local", device: archive.device) { _ in
            XCTAssertThrowsError(try b.reset(), "Another reset must not replace authority during cache write")
            XCTAssertEqual(try b.read()?.device, archive.device)
        }
        XCTAssertNotEqual(try b.reset().device, archive.device)
    }
    func testWriteFailureAfterPrivateResetCanRecoverWithANewFileInstance() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), receipt = try record()
        var snapshot = Snapshot(); snapshot.locationActions = [receipt.source: receipt]
        let cache = dir.appendingPathComponent("synthetic-cache.json"); try JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
        let bytes = try Data(contentsOf: cache), file = LocationPrivateFile(applicationSupport: dir)
        XCTAssertThrowsError(try file.withResetAuthority(account: "reset-local", device: archive.device) { _ in throw CocoaError(.fileWriteOutOfSpace) } as Void)
        XCTAssertEqual(try Data(contentsOf: cache), bytes)
        let relaunched = LocationPrivateFile(applicationSupport: dir)
        try relaunched.withResetAuthority(account: "reset-local", device: archive.device) { proof in
            let previous = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cache))
            let next = try LocationRetirementOutbox.staging(previous: previous, proposed: snapshot, account: "reset-local", installationReset: proof)
            try JSONEncoder().encode(next).write(to: cache, options: .atomic)
        }
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cache)).locationActions)
        XCTAssertEqual(try relaunched.read(), archive)
    }
    func testBothDurableAndRestoredReceiptsAreFilteredWithoutTaskMutation() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), old = try record(), restored = try record()
        var previous = Snapshot(tables: ["tasks": [Record.task(user: "reset-local")]]); previous.locationActions = [old.source: old]
        var proposed = previous; proposed.locationActions = [restored.source: restored]
        let proof = try LocationInstallationReset(account: "reset-local", archive: archive)
        let clean = try LocationRetirementOutbox.staging(previous: previous, proposed: proposed, account: "reset-local", installationReset: proof)
        XCTAssertNil(clean.locationActions); XCTAssertEqual(clean.tables, previous.tables); XCTAssertEqual(clean.pending, previous.pending)
        XCTAssertEqual(try LocationRetirementOutbox.staging(previous: clean, proposed: previous, account: "reset-local").locationActions, previous.locationActions)
        XCTAssertNil(try LocationRetirementOutbox.staging(previous: clean, proposed: previous, account: "reset-local", installationReset: proof).locationActions)
    }
    func testResetProofCannotHideAMutatingResponseOrWrongAccount() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), old = try record(), proof = try LocationInstallationReset(account: "reset-local", archive: archive)
        var proposed = Snapshot(); proposed.locationActions = [old.source: old]
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: Snapshot(), proposed: proposed, account: "reset-local", newResponse: old, installationReset: proof))
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: proposed, proposed: proposed, account: "other", installationReset: proof))
    }
    func testMalformedResetFlagsAndFutureFilesAreRefusedWithoutReplacement() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), file = LocationPrivateFile(applicationSupport: dir)
        let original = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(archive)).object
        for invalid in [JSON.bool(false), .null, .number(1), .string("true")] {
            var raw = original; raw["supersedesEarlierInstallations"] = invalid
            let bytes = try JSONEncoder().encode(raw); try bytes.write(to: file.url)
            XCTAssertThrowsError(try file.read()); XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        }
        var raw = original; raw["version"] = .number(4); let bytes = try JSONEncoder().encode(raw); try bytes.write(to: file.url)
        XCTAssertThrowsError(try file.read()); XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }
    func testFullOldActionLedgerCanRecoverAfterReset() throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), old = try record(), proof = try LocationInstallationReset(account: "reset-local", archive: archive)
        var previous = Snapshot(); previous.locationActions = [:]
        for i in 0..<LocationNotificationAction.maximum {
            let source = "la1:" + LocationReminderIdentity.digest([String(i)])
            previous.locationActions?[source] = LocationNotificationAction(source: source, ticket: old.ticket, action: .tomorrow, fireAt: nil, phase: .closed, end: .consumed)
        }
        XCTAssertNil(try LocationRetirementOutbox.staging(previous: previous, proposed: previous, account: "reset-local", installationReset: proof).locationActions)
    }
    func testConsentChangesKeepResetAuthorityWithoutReusingOldIdentity() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try reset(dir), store = LocationPrivateStore(applicationSupport: dir)
        let allowed = try await store.setAllowance(account: "reset-local", enabled: true, expectedDevice: archive.device)
        XCTAssertEqual(allowed.version, 3); XCTAssertEqual(allowed.supersedesEarlierInstallations, true); XCTAssertEqual(allowed.device, archive.device)
        XCTAssertTrue(allowed.allows(account: "reset-local"))
        let off = try await store.setAllowance(account: "reset-local", enabled: false, expectedDevice: archive.device)
        XCTAssertEqual(off.version, 3); XCTAssertEqual(off.supersedesEarlierInstallations, true)
    }
}
