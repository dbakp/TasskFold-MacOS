import XCTest
import Darwin
@testable import TaskfoldCore

final class LocationPlaceStoreTests: XCTestCase {
    let account = "local"
    func root() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-place-store-" + UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
    func place(account: String = "local", name: String = "Synthetic private place") throws -> LocationPrivatePlace { try XCTUnwrap(.make(account: account, name: name, latitude: 55.676098, longitude: 12.568337, radius: 250)) }
    func testReadMissingDoesNotCreateIdentityOrFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root)
        let value = try await store.snapshot(); XCTAssertNil(value)
        let places = try await store.places(account: account); XCTAssertTrue(places.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("LocationPrivate").path))
    }
    func testRealFileRoundtripPermissionsBackupExclusionAndStableIdentity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), p = try place()
        let first = try await store.save(p), restarted = LocationPrivateStore(applicationSupport: root)
        let loaded = try await restarted.snapshot(); XCTAssertEqual(loaded, first); XCTAssertEqual(loaded?.places(for: account), [p])
        let file = LocationPrivateFile(applicationSupport: root)
        let dir = try FileManager.default.attributesOfItem(atPath: file.directory.path), attrs = try FileManager.default.attributesOfItem(atPath: file.url.path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700); XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try file.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let second = try await restarted.save(try place(name: "Another place")); XCTAssertEqual(first.device, second.device)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.directory.path).filter { $0.hasPrefix(".write-") }, [])
    }
    func testAccountFilteringAndClearKeepOtherAccountsAndJournalIdentity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), first = try place(), other = try place(account: "another")
        let original = try await store.save(first); _ = try await store.save(other)
        let own = try await store.places(account: account); XCTAssertEqual(own, [first])
        try await store.clearPlaces(account: account)
        let state = try await store.snapshot(); XCTAssertEqual(state?.places(for: "another"), [other]); XCTAssertEqual(state?.device, original.device); XCTAssertTrue(state?.places(for: account).isEmpty == true)
    }
    func testRenameGeometryRevisionIdempotentSaveAndStaleEdits() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), p = try place()
        _ = try await store.save(p); let retry = try await store.save(p); XCTAssertEqual(retry.places.count, 1)
        let named = try XCTUnwrap(p.editing(name: "Renamed private place", latitude: 55.676098, longitude: 12.568337, radius: 250))
        _ = try await store.save(named, replacing: p); XCTAssertEqual(named.revision, p.revision)
        let moved = try XCTUnwrap(named.editing(name: named.name, latitude: 55.7, longitude: 12.568337, radius: 500))
        _ = try await store.save(moved, replacing: named); XCTAssertNotEqual(moved.revision, p.revision)
        do { _ = try await store.save(named, replacing: p); XCTFail("Stale edit accepted") } catch { XCTAssertEqual(error as? LocationStorageFailure, .changed) }
        do { try await store.delete(p); XCTFail("Stale delete accepted") } catch { XCTAssertEqual(error as? LocationStorageFailure, .changed) }
        let final = try await store.places(account: account); XCTAssertEqual(final, [moved])
    }
    func testCorruptionAndFutureFieldsAreNotReplacedAndResetRequiresConfirmation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), file = LocationPrivateFile(applicationSupport: root)
        let original = try await store.save(try place())
        for bytes in [Data("broken".utf8), try JSONEncoder().encode(JSON.object(["version": .number(2)]))] {
            try bytes.write(to: file.url)
            do { _ = try await store.snapshot(); XCTFail("Unreadable file accepted") } catch {}
            do { _ = try await store.save(try place()); XCTFail("Unreadable file overwritten") } catch {}
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        }
        do { _ = try await store.resetAllPrivateData(confirmed: false); XCTFail("Unconfirmed reset") } catch {}
        let reset = try await store.resetAllPrivateData(confirmed: true); XCTAssertNotEqual(reset.device, original.device); XCTAssertTrue(reset.places.isEmpty)
        var json = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: file.url)).object; json["future_private_data"] = .object(["keep": .bool(true)])
        let future = try JSONEncoder().encode(JSON.object(json)); try future.write(to: file.url)
        do { _ = try await store.save(try place()); XCTFail("Unknown future archive overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: file.url), future)
    }
    func testBoundedReadRejectsOversizeBeforeDecoding() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), file = LocationPrivateFile(applicationSupport: root)
        _ = try await store.save(try place()); try Data(repeating: 32, count: LocationPrivateFile.maximumBytes + 1).write(to: file.url)
        do { _ = try await store.snapshot(); XCTFail("Oversize read accepted") } catch {}
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.intValue, LocationPrivateFile.maximumBytes + 1)
    }
    func testSymbolicAndHardLinksAreRefusedWithoutTouchingTheirTargets() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = LocationPrivateFile(applicationSupport: root), target = root.appendingPathComponent("unrelated.json")
        let bytes = Data("do not touch".utf8); try bytes.write(to: target)
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: target)
        do { _ = try file.read(); XCTFail("Link followed") } catch {}
        do { _ = try file.reset(); XCTFail("Linked target replaced") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: file.url); try FileManager.default.linkItem(at: target, to: file.url)
        do { _ = try file.read(); XCTFail("Hard link read") } catch {}
        do { _ = try file.reset(); XCTFail("Hard link reset") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    func testAliasedDirectoryAndBusyWriterCannotReplaceData() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = LocationPrivateFile(applicationSupport: root), elsewhere = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: file.directory, withDestinationURL: elsewhere)
        do { _ = try file.reset(); XCTFail("Directory link followed") } catch {}
        try FileManager.default.removeItem(at: file.directory)
        let store = LocationPrivateStore(applicationSupport: root); _ = try await store.save(try place()); let before = try Data(contentsOf: file.url)
        let descriptor = Darwin.open(file.directory.appendingPathComponent("writer.lock").path, O_RDWR); XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        do { _ = try await store.save(try place()); XCTFail("Conflicting writer accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file.url), before)
    }
    func testIndependentStoreInstancesPreserveFreshDiskStateAndPrivateExtensions() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LocationPrivateStore(applicationSupport: root), b = LocationPrivateStore(applicationSupport: root)
        var fields = try place().raw; fields["future_label_data"] = .string("Keep private extension")
        let p = try XCTUnwrap(LocationPrivatePlace(raw: fields)), other = try place(account: "other")
        _ = try await a.save(p); _ = try await b.save(other)
        let renamed = try XCTUnwrap(p.editing(name: "Updated name", latitude: 55.676098, longitude: 12.568337, radius: 250))
        _ = try await a.save(renamed, replacing: p)
        let read = try await b.snapshot(); XCTAssertEqual(read?.places.count, 2); XCTAssertEqual(read?.places(for: account).first?.raw["future_label_data"], .string("Keep private extension"))
    }
    func testJournalCannotRewindLosePreparedIntentsOrChangeInstallation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), p = try place(), archive = try await store.save(p)
        let task = "83000000-0000-4000-8000-000000000001", generation = "83000000-0000-4000-8000-000000000002"
        let settings = try XCTUnwrap(LocationReminderSettings.make(device: archive.device, taskID: task, taskGeneration: generation, place: p, transition: .arrive))
        let record = Record(["id": .string(task), "task_generation": .string(generation), "title": .string("Storage proof")])
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: archive.device, task: record, settings: settings, place: p))
        var journal = archive.journal; XCTAssertTrue(journal.prepare(candidate.ticket)); try await store.saveJournal(journal)
        let prepared = journal; journal.entries[candidate.ticket.identifier]?.phase = .reserved; try await store.saveJournal(journal)
        do { try await store.saveJournal(prepared); XCTFail("Journal rewound") } catch {}
        do { try await store.saveJournal(archive.journal); XCTFail("Preparation lost") } catch {}
        do { try await store.saveJournal(LocationReminderJournal(device: UUID().uuidString.lowercased())); XCTFail("Device replaced") } catch {}
        let saved = try await store.snapshot(); XCTAssertEqual(saved?.journal.entries[candidate.ticket.identifier]?.phase, .reserved)
        try await store.clearPlaces(account: account); let cleared = try await store.snapshot(); XCTAssertEqual(cleared?.journal, saved?.journal)
    }
    func testLegacyArchiveConsentStartsOffAndExplicitGrantSurvivesRestartPrivately() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), p = try place()
        let legacy = try await store.save(p)
        XCTAssertEqual(legacy.version, 1); XCTAssertNil(legacy.allowedAccounts); XCTAssertFalse(legacy.allows(account: account))
        let oldBytes = try JSONEncoder().encode(legacy)
        let read = try LocationPrivateArchive.decode(oldBytes); XCTAssertEqual(read, legacy)
        let granted = try await store.setAllowance(account: account, enabled: true, expectedDevice: legacy.device)
        XCTAssertEqual(granted.version, 2); XCTAssertTrue(granted.allows(account: account)); XCTAssertFalse(granted.allows(account: "other"))
        XCTAssertEqual(granted.device, legacy.device); XCTAssertEqual(granted.places, legacy.places); XCTAssertEqual(granted.journal, legacy.journal)
        let restarted = LocationPrivateStore(applicationSupport: root), persisted = try await restarted.snapshot()
        XCTAssertEqual(persisted, granted)
        let file = LocationPrivateFile(applicationSupport: root)
        XCTAssertEqual(try file.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testExplicitConsentCanCreateInstallationWithoutInventingAPin() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root)
        let created = try await store.setAllowance(account: account, enabled: true, expectedDevice: nil)
        XCTAssertTrue(created.places.isEmpty); XCTAssertTrue(created.journal.entries.isEmpty); XCTAssertTrue(created.allows(account: account))
        do { _ = try await store.setAllowance(account: "other", enabled: true, expectedDevice: nil); XCTFail("Stale missing-file review granted consent") } catch {}
        let current = try await store.snapshot(); XCTAssertEqual(current, created)
    }
    func testConsentRevocationKeepsOtherAccountsPlacesAndJournal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LocationPrivateStore(applicationSupport: root), b = LocationPrivateStore(applicationSupport: root)
        let first = try await a.save(try place())
        _ = try await a.setAllowance(account: account, enabled: true, expectedDevice: first.device)
        _ = try await b.setAllowance(account: "other", enabled: true, expectedDevice: first.device)
        let final = try await a.setAllowance(account: account, enabled: false, expectedDevice: first.device)
        XCTAssertFalse(final.allows(account: account)); XCTAssertTrue(final.allows(account: "other"))
        XCTAssertEqual(final.places, first.places); XCTAssertEqual(final.journal, first.journal); XCTAssertEqual(final.device, first.device)
        try await a.clearPlaces(account: account)
        let empty = try await b.snapshot(); XCTAssertEqual(empty?.allowedAccounts, final.allowedAccounts)
    }
    func testResetRemovesAllConsentAndStaleDeviceCannotGrantAgain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root)
        let old = try await store.setAllowance(account: account, enabled: true, expectedDevice: nil)
        let reset = try await store.resetAllPrivateData(confirmed: true)
        XCTAssertNotEqual(old.device, reset.device); XCTAssertFalse(reset.allows(account: account))
        let before = try Data(contentsOf: LocationPrivateFile(applicationSupport: root).url)
        do { _ = try await store.setAllowance(account: account, enabled: true, expectedDevice: old.device); XCTFail("Old device granted consent") } catch {}
        XCTAssertEqual(try Data(contentsOf: LocationPrivateFile(applicationSupport: root).url), before)
    }
    func testMalformedFutureAndDuplicateConsentNeverReplacePrivateData() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), initial = try await store.save(try place())
        let file = LocationPrivateFile(applicationSupport: root)
        var raw = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(initial)).object
        raw["version"] = .number(2)
        for value in [JSON.null, .array([.string(account), .string(account)]), .array([.string(" ")]), .array([.bool(true)]), .array((0..<51).map { .string("account-" + String($0)) })] {
            raw["allowedAccounts"] = value
            let bytes = try JSONEncoder().encode(JSON.object(raw)); try bytes.write(to: file.url)
            do { _ = try await store.setAllowance(account: account, enabled: true, expectedDevice: initial.device); XCTFail("Invalid consent rewritten") } catch {}
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        }
        raw["allowedAccounts"] = .array([.string(account)]); raw["version"] = .number(3)
        let future = try JSONEncoder().encode(JSON.object(raw)); try future.write(to: file.url)
        do { _ = try await store.setAllowance(account: account, enabled: false, expectedDevice: initial.device); XCTFail("Future private file rewritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: file.url), future)
    }
    func testJournalAndPlaceWritesPreserveConcurrentConsentChanges() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = LocationPrivateStore(applicationSupport: root), b = LocationPrivateStore(applicationSupport: root), p = try place()
        let initial = try await a.save(p)
        let settings = try XCTUnwrap(LocationReminderSettings.make(device: initial.device, taskID: UUID().uuidString.lowercased(), taskGeneration: UUID().uuidString.lowercased(), place: p, transition: .leave))
        let task = Record(["id": .string(settings.taskID), "task_generation": .string(settings.taskGeneration)])
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: initial.device, task: task, settings: settings, place: p))
        var journal = initial.journal; XCTAssertTrue(journal.prepare(candidate.ticket))
        _ = try await a.setAllowance(account: account, enabled: true, expectedDevice: initial.device)
        try await b.saveJournal(journal)
        let renamed = try XCTUnwrap(p.editing(name: "Renamed", latitude: 55.676098, longitude: 12.568337, radius: 250))
        _ = try await b.save(renamed, replacing: p)
        let revoked = try await a.setAllowance(account: account, enabled: false, expectedDevice: initial.device)
        journal.entries[candidate.ticket.identifier]?.phase = .reserved; try await b.saveJournal(journal)
        let final = try await a.snapshot()
        XCTAssertEqual(final?.allowedAccounts, revoked.allowedAccounts); XCTAssertFalse(final?.allows(account: account) ?? true)
        XCTAssertEqual(final?.journal, journal); XCTAssertEqual(final?.places(for: account), [renamed])
    }

}
