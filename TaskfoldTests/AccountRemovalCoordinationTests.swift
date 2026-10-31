import XCTest
import Darwin
@testable import TaskfoldCore

private final class RemovalRaceIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var pause: (XCTestExpectation, DispatchSemaphore)?
    private var reads = 0, writes = 0
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (reads, writes) }
    func pauseNextRead(_ expectation: XCTestExpectation) -> DispatchSemaphore {
        lock.lock(); defer { lock.unlock() }
        let release = DispatchSemaphore(value: 0); pause = (expectation, release); return release
    }
    func read(key: String) throws -> Data? {
        lock.lock(); reads += 1; let result = data, paused = pause; pause = nil; lock.unlock()
        if let paused {
            paused.0.fulfill()
            guard paused.1.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
        }
        return result
    }
    func write(_ value: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; writes += 1; data = value }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; writes += 1; data = nil }
}

final class AccountRemovalCoordinationTests: XCTestCase {
    private let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let proof = "fixture." + String(repeating: "a", count: 43)
    private func command(_ account: String, token: String = "synthetic") throws -> AccountRemovalCommand {
        try .init(account: account, origin: "https://removal.test", authorization: token)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-removal-coordination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func assertTransactionHoldsLock(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let fd = Darwin.open(directory.appendingPathComponent(AccountRemovalVault.coordinationResource + ".lock").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { XCTFail("Vault did not create its process lock", file: file, line: line); return }
        defer { Darwin.close(fd) }
        let acquired = flock(fd, LOCK_EX | LOCK_NB)
        if acquired == 0 { flock(fd, LOCK_UN) }
        XCTAssertEqual(acquired, -1, "The lock must cover the read, not only the final write", file: file, line: line)
    }
    func testDifferentAccountsCannotOverwriteEachOthersBegunRemoval() async throws {
        let io = RemovalRaceIO(), dir = try directory()
        let first = AccountRemovalVault(io: io, coordinationDirectory: dir), second = AccountRemovalVault(io: io, coordinationDirectory: dir)
        let paused = expectation(description: "First transaction captured the old envelope"), release = io.pauseNextRead(paused)
        defer { release.signal() }
        let ca = try command(a), cb = try command(b)
        let beginA = Task { try await first.begin(ca) }
        await fulfillment(of: [paused], timeout: 2); try assertTransactionHoldsLock(dir)
        let started = expectation(description: "Second independent vault starts while A is paused")
        let beginB = Task { started.fulfill(); return try await second.begin(cb) }
        await fulfillment(of: [started], timeout: 2); release.signal()
        let savedA = try await beginA.value, savedB = try await beginB.value
        XCTAssertEqual(savedA, ca); XCTAssertEqual(savedB, cb)
        let pending = try await AccountRemovalVault(io: io, coordinationDirectory: dir).pending()
        XCTAssertEqual(Set(pending.map(\.id)), Set([ca.id, cb.id]))
    }
    func testFinishingAWhileBeginningBDoesNotEraseB() async throws {
        let io = RemovalRaceIO(), dir = try directory()
        let first = AccountRemovalVault(io: io, coordinationDirectory: dir), second = AccountRemovalVault(io: io, coordinationDirectory: dir)
        let original = try await first.begin(command(a)), prepared = try await first.prepare(original, proof: proof), confirmed = try await first.confirm(prepared)
        let paused = expectation(description: "Cleanup acknowledgement captured A"), release = io.pauseNextRead(paused)
        defer { release.signal() }
        let finishing = Task { try await first.finish(confirmed) }
        await fulfillment(of: [paused], timeout: 2); try assertTransactionHoldsLock(dir)
        let cb = try command(b), started = expectation(description: "B begins during A acknowledgement")
        let beginning = Task { started.fulfill(); return try await second.begin(cb) }
        await fulfillment(of: [started], timeout: 2); release.signal()
        try await finishing.value; let savedB = try await beginning.value; XCTAssertEqual(savedB, cb)
        let beforeRepeat = io.counts.1; try await second.finish(confirmed)
        XCTAssertEqual(io.counts.1, beforeRepeat, "Repeating an old acknowledgement must not rewrite the envelope")
        let pending = try await first.pending(); XCTAssertEqual(pending, [cb])
    }
    func testConfirmationCannotBeDowngradedByAnotherAccountsBegin() async throws {
        let io = RemovalRaceIO(), dir = try directory()
        let first = AccountRemovalVault(io: io, coordinationDirectory: dir), second = AccountRemovalVault(io: io, coordinationDirectory: dir)
        let original = try await first.begin(command(a)), prepared = try await first.prepare(original, proof: proof)
        let paused = expectation(description: "Confirmation captured prepared A"), release = io.pauseNextRead(paused)
        defer { release.signal() }
        let confirming = Task { try await first.confirm(prepared) }
        await fulfillment(of: [paused], timeout: 2); try assertTransactionHoldsLock(dir)
        let cb = try command(b), beginning = Task { try await second.begin(cb) }; release.signal()
        let confirmed = try await confirming.value; _ = try await beginning.value
        let writes = io.counts.1, duplicate = try await second.confirm(prepared)
        XCTAssertEqual(duplicate, confirmed); XCTAssertEqual(io.counts.1, writes)
        let pending = try await first.pending(); XCTAssertEqual(Set(pending.map(\.id)), Set([confirmed.id, cb.id])); XCTAssertTrue(pending.first { $0.account == a }!.confirmed)
    }
    func testStaleAcknowledgementCannotRemoveANewerCommandForTheSameAccount() async throws {
        let io = RemovalRaceIO(), dir = try directory(), vault = AccountRemovalVault(io: io, coordinationDirectory: dir)
        let original = try await vault.begin(command(a)), prepared = try await vault.prepare(original, proof: proof), confirmed = try await vault.confirm(prepared)
        try await vault.finish(confirmed)
        let newer = try await vault.begin(command(a, token: "new-authorization"))
        do { try await vault.finish(confirmed); XCTFail("Stale cleanup acknowledged newer work") } catch is CancellationError {}
        do { _ = try await vault.confirm(prepared); XCTFail("Stale success replaced newer authorization") } catch is CancellationError {}
        let pending = try await vault.pending(); XCTAssertEqual(pending, [newer])
    }
    func testAnExternalProcessLockPreventsIOUntilTheOtherProcessReleasesIt() async throws {
        let io = RemovalRaceIO(), dir = try directory(), vault = AccountRemovalVault(io: io, coordinationDirectory: dir, lockTimeout: 0.1)
        let original = try await vault.begin(command(a)), prepared = try await vault.prepare(original, proof: proof), confirmed = try await vault.confirm(prepared)
        let process = Process(), input = Pipe(), output = Pipe(), ready = expectation(description: "External process holds the shared envelope lock")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.buffer.read(1)", dir.appendingPathComponent(AccountRemovalVault.coordinationResource + ".lock").path]
        process.standardInput = input; process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.contains(10) { handle.readabilityHandler = nil; ready.fulfill() }
        }
        try process.run()
        defer { output.fileHandleForReading.readabilityHandler = nil; try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
        await fulfillment(of: [ready], timeout: 2)
        let before = io.counts
        do { _ = try await vault.begin(command(b)); XCTFail("Read-modify-write bypassed an external lock") } catch { XCTAssertTrue(error.localizedDescription.contains("Account removal recovery")) }
        do { _ = try await vault.pending(); XCTFail("Read bypassed an external lock") } catch {}
        do { try await vault.finish(confirmed); XCTFail("Acknowledgement bypassed an external lock") } catch {}
        XCTAssertEqual(io.counts.0, before.0); XCTAssertEqual(io.counts.1, before.1)
        try input.fileHandleForWriting.close(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let cb = try await vault.begin(command(b)); try await vault.finish(confirmed)
        let pending = try await vault.pending(); XCTAssertEqual(pending, [cb])
    }
    func testLockNamespaceIsStableForAServiceAndSeparateForOtherApps() throws {
        let root = try directory()
        let first = AccountRemovalVault.coordinationDirectory(service: "com.taskfold.mac.account-removal", root: root)
        XCTAssertEqual(first, AccountRemovalVault.coordinationDirectory(service: "com.taskfold.mac.account-removal", root: root))
        XCTAssertNotEqual(first, AccountRemovalVault.coordinationDirectory(service: "com.taskfold.ios.account-removal", root: root))
    }
}
