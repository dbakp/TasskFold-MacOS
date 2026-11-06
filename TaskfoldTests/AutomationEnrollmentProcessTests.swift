import XCTest
import Darwin
@testable import TaskfoldCore

/// Test-only substitute for a single atomic secure item. It stores only synthetic
/// enrollment data in an owned temporary directory, removed after each test.
private struct ProcessEnrollmentIO: CalendarSecureItemIO {
    let root: URL
    private var file: URL { root.appendingPathComponent("synthetic-item") }
    func read(key: String) throws -> Data? {
        let data = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        if data == nil { usleep(150_000) } // Deterministically widen the competing empty-read window.
        return data
    }
    func write(_ data: Data, key: String) throws { try data.write(to: file, options: .atomic) }
    func remove(key: String) throws { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
}
final class AutomationEnrollmentProcessTests: XCTestCase {
    private let account = "f097cafe-0000-4000-8000-000000000001"
    private let origin = "https://enrollment-process.test"
    private func wait(_ condition: () -> Bool, seconds: Double = 8) async throws {
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw AppFailure(message: "Synthetic process proof timed out") }
    }
    private func ownedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Taskfold-Enrollment-Process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func child(root: URL, method: String, label: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "TaskfoldCoreTests.AutomationEnrollmentProcessTests/" + method, Bundle(for: Self.self).bundleURL.path]
        process.environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"].contains($0.key) }
        process.environment?["TASKFOLD_ENROLLMENT_PROOF_ROOT"] = root.path
        process.environment?["TASKFOLD_ENROLLMENT_PROOF_WORKER"] = label
        // xctest can dump its environment on startup failure; do not collect it.
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); return process
    }
    private func stop(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
    private func workerRoot() throws -> (URL, String)? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TASKFOLD_ENROLLMENT_PROOF_ROOT"], let label = env["TASKFOLD_ENROLLMENT_PROOF_WORKER"] else { return nil }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let prefix = "Taskfold-Enrollment-Process-"
        guard root.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              root.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              ["a", "b", "hold"].contains(label) else { throw AutomationKey.invalid }
        return (root, label)
    }
    func testCompetingIndependentProcessesKeepOneExactEnrollment() async throws {
        if let (root, label) = try workerRoot() {
            try Data().write(to: root.appendingPathComponent("ready-" + label))
            try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("start").path) }
            let vault = AutomationEnrollmentVault(io: ProcessEnrollmentIO(root: root), coordinationDirectory: root.appendingPathComponent("Locks"))
            let draft = try AutomationKeyDraft(account: account, origin: origin, name: "Worker " + label, scopes: [.read], days: 30)
            let saved = try await vault.begin(draft, lease: CalendarReadLease())
            let result = ["id": saved.id, "hash": saved.body["token_hash"]!.text]
            try JSONEncoder().encode(result).write(to: root.appendingPathComponent("result-" + label), options: .atomic)
            return
        }
        let root = try ownedRoot()
        var children: [Process] = []
        defer { children.forEach(stop); try? FileManager.default.removeItem(at: root) }
        children = try ["a", "b"].map { try child(root: root, method: "testCompetingIndependentProcessesKeepOneExactEnrollment", label: $0) }
        try await wait { ["a", "b"].allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-" + $0).path) } }
        try Data().write(to: root.appendingPathComponent("start"))
        try await wait { children.allSatisfy { !$0.isRunning } }
        XCTAssertEqual(children.map(\.terminationStatus), [0, 0])
        let a = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("result-a")))
        let b = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("result-b")))
        XCTAssertEqual(a, b)
        let vault = AutomationEnrollmentVault(io: ProcessEnrollmentIO(root: root), coordinationDirectory: root.appendingPathComponent("Locks"))
        let pending = try await vault.pending(account: account, origin: origin)
        XCTAssertEqual(pending?.id, a["id"]); XCTAssertEqual(pending?.body["token_hash"]?.text, a["hash"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Locks/" + account + ".lock")).count, 0)
    }
    func testProcessDeathReleasesLockAndSymlinkCannotRedirectIt() async throws {
        if let (root, _) = try workerRoot() {
            try AutomationEnrollmentProcessLock(directory: root.appendingPathComponent("Locks")).withExclusive(account: account) {
                try Data().write(to: root.appendingPathComponent("holding"))
                while true { usleep(100_000) }
            }
            return
        }
        let root = try ownedRoot()
        let process = try child(root: root, method: "testProcessDeathReleasesLockAndSymlinkCannotRedirectIt", label: "hold")
        defer { stop(process); try? FileManager.default.removeItem(at: root) }
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("holding").path) }
        let processLock = AutomationEnrollmentProcessLock(directory: root.appendingPathComponent("Locks"), timeout: 0.1)
        XCTAssertThrowsError(try processLock.withExclusive(account: account) {})
        stop(process)
        XCTAssertEqual(try processLock.withExclusive(account: account) { 42 }, 42)
        let lock = root.appendingPathComponent("Locks/" + account + ".lock"), target = root.appendingPathComponent("untouched")
        try FileManager.default.removeItem(at: lock)
        try Data("fixture".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        XCTAssertThrowsError(try processLock.withExclusive(account: account) {})
        XCTAssertEqual(try Data(contentsOf: target), Data("fixture".utf8))
    }
}
