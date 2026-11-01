import XCTest
import CryptoKit
@testable import TaskfoldCore

private let fileAccount = "ec990000-0000-4000-8000-000000000001", fileOrigin = "https://files.example"
private let fileTarget = Record(["team_id": .string("ec990000-0000-4000-8000-000000000002"), "project_id": .string("ec990000-0000-4000-8000-000000000003"), "task_id": .string("ec990000-0000-4000-8000-000000000004"), "task_generation": .string("ec990000-0000-4000-8000-000000000005")])
private let fileKey = SymmetricKey(size: .bits256)
private func publication(_ journal: TaskFileUploadJournal, state: String = "published") throws -> Data {
    let attachment: JSON = state == "published" ? .object(["id": .string(journal.id), "storage_object_id": .string("ec990000-0000-4000-8000-000000000006"), "name": journal.intent["name"], "size": journal.intent["byte_count"], "type": journal.intent["type"], "sha256": journal.intent["sha256"], "uploadedAt": .string("2026-11-01T22:00:00Z")]) : .null
    return try TaskfoldJSONEncoder().encode(Record(["receipt": .object(["protocol": .number(1), "account": .string(journal.account), "operation_id": .string(journal.id), "target": .object(journal.target.fields), "state": .string(state), "attachment": attachment])]))
}
@MainActor private final class FilePeer: TaskFileUploadTransport {
    var calls: [(String, TaskFileUploadJournal)] = []
    var applied: [String: Data] = [:]
    var lose = false, malformed = false, hold = false, unreserved = false
    var beforeSend: ((TaskFileUploadJournal) async throws -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    func taskFileReply(_ journal: TaskFileUploadJournal, action: String, incarnation: UUID) async throws -> Data {
        try await beforeSend?(journal); calls.append((action, journal))
        if unreserved, action == "publish" { throw URLError(.notConnectedToInternet) }
        if unreserved, action == "cancel" { return try TaskfoldJSONEncoder().encode(Record(["receipt": .object(["protocol": .number(1), "sender_stop_protocol": .number(1), "account": .string(journal.account), "operation_id": .string(journal.id), "state": .string("cancelled")])])) }
        let response: Data
        if let saved = applied[journal.id] { response = saved }
        else if action == "publish" { response = try publication(journal); applied[journal.id] = response }
        else { response = try publication(journal, state: action == "cancel" ? "cancelled" : "reserved") }
        if hold { await withCheckedContinuation { continuation = $0 } }
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        return malformed ? Data("{}".utf8) : response
    }
}
private final class FileFaultIO: CalendarSecureItemIO, @unchecked Sendable {
    let base: ReviewedTeamCommandFileIO<TaskFileUploadJournal>
    private let lock = NSLock(); private var failing = false
    init(_ base: ReviewedTeamCommandFileIO<TaskFileUploadJournal>) { self.base = base }
    func failWrite(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func read(key: String) throws -> Data? { try base.read(key: key) }
    func write(_ data: Data, key: String) throws { lock.lock(); let fail = failing; lock.unlock(); if fail { throw URLError(.cannotWriteToFile) }; try base.write(data, key: key) }
    func remove(key: String) throws { try base.remove(key: key) }
}
private final class FileHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, FileHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func reply(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class TaskFileUploadTests: XCTestCase {
    private func journal(bytes: Data = Data("Private workshop notes".utf8), name: String = "Workshop.txt", type: String = "text/plain") throws -> TaskFileUploadJournal { try .init(account: fileAccount, origin: fileOrigin, target: fileTarget, bytes: bytes, name: name, type: type) }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-file-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func io(_ root: URL, account: String = fileAccount, origin: String = fileOrigin) -> ReviewedTeamCommandFileIO<TaskFileUploadJournal> { .init(directory: root.appendingPathComponent("uploads"), account: account, origin: origin, encryptionKey: { fileKey }) }
    private func vault(_ root: URL, io: (any CalendarSecureItemIO)? = nil) -> TaskFileUploadVault { .init(io: io ?? self.io(root), coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root) }
    func testActualOwnSQLReceiptRoundTripsAndKeepsOriginalFile() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-file-upload-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try TaskfoldJSONDecoder().decode(Record.self, from: Data(contentsOf: url)), intent = Record(fixture["intent"].object), published = Record(fixture["published"].object)
        let receipt = Record(published["receipt"].object)
        let saved = try TaskFileUploadJournal(account: receipt.string("account"), origin: fileOrigin, target: Record(intent["target"].object), bytes: Data("hello".utf8), name: intent.string("name"), type: intent.string("type"), operation: UUID(uuidString: intent.string("operation_id"))!)
        let confirmed = try saved.markingAttempted().receiving(TaskfoldJSONEncoder().encode(Record(["receipt": published["receipt"]])))
        XCTAssertEqual(confirmed.phase, .published); XCTAssertEqual(confirmed.bytes, saved.bytes); XCTAssertEqual(try TaskfoldJSONDecoder().decode(TaskFileUploadJournal.self, from: TaskfoldJSONEncoder().encode(confirmed)), confirmed)
    }
    func testQueuedAndAttemptedJournalsRoundTripWithoutExposingDescriptions() throws {
        let queued = try journal()
        for value in [queued, try queued.markingAttempted()] {
            XCTAssertEqual(try TaskfoldJSONDecoder().decode(TaskFileUploadJournal.self, from: TaskfoldJSONEncoder().encode(value)), value)
            XCTAssertFalse(String(reflecting: value).contains(value.name)); XCTAssertFalse(String(describing: value).contains(fileAccount))
        }
    }
    func testActualOwnSQLUnknownSenderStopClosesAndColdRestoresOriginal() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-file-sender-stop-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try TaskfoldJSONDecoder().decode(Record.self, from: Data(contentsOf: url)), wire = Record(fixture["wire"].object), intent = Record(wire["intent"].object), reply = Record(wire["reply"].object)
        let proof = Record(reply["receipt"].object)
        let value = try TaskFileUploadJournal(account: proof.string("account"), origin: fileOrigin, target: Record(intent["target"].object), bytes: Data("hello".utf8), name: intent.string("name"), type: intent.string("type"), operation: UUID(uuidString: intent.string("operation_id"))!).markingAttempted()
        let stopped = try value.receiving(TaskfoldJSONEncoder().encode(reply)); XCTAssertEqual(stopped.phase, .cancelled); XCTAssertEqual(stopped.bytes, value.bytes); XCTAssertTrue(stopped.resolved)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(TaskFileUploadJournal.self, from: TaskfoldJSONEncoder().encode(stopped)), stopped)
        XCTAssertThrowsError(try stopped.receiving(publication(value)))
    }
    func testMinimalSenderStopRejectsForeignUnknownAndPublishingClaims() throws {
        let value = try journal().markingAttempted()
        let original: [String:JSON] = ["protocol": .number(1), "sender_stop_protocol": .number(1), "account": .string(value.account), "operation_id": .string(value.id), "state": .string("cancelled")]
        for (key, replacement) in [("sender_stop_protocol",JSON.number(2)),("account",.string(UUID().uuidString.lowercased())),("operation_id",.string(UUID().uuidString.lowercased())),("state",.string("published")),("attachment",.null)] {
            var fields = original; fields[key] = replacement
            XCTAssertThrowsError(try value.receiving(TaskfoldJSONEncoder().encode(Record(["receipt":.object(fields)]))))
        }
    }
    @MainActor func testUnreservedAttemptCanStopAndReleaseOnlyAfterRealProof() async throws {
        let root = try root(), peer = FilePeer(); peer.unreserved = true
        let model = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: vault(root), service: peer, incarnation: UUID(), current: { true })
        await model.load(); await model.choose(Data("hello".utf8), name: "hello.txt", type: "text/plain"); await model.act("publish"); XCTAssertEqual(model.pending?.phase, .attempted)
        await model.finish(); XCTAssertNotNil(model.pending)
        await model.act("cancel"); XCTAssertEqual(model.pending?.phase, .cancelled); XCTAssertEqual(model.pending?.bytes, Data("hello".utf8)); XCTAssertTrue(peer.applied.isEmpty)
        await model.finish(); XCTAssertNil(model.pending); XCTAssertEqual(peer.calls.map(\.0),["publish","cancel"])
    }
    func testDescriptorBoundsAndUnsafeFileNamesReject() throws {
        for name in ["", ".", "..", "../secret", "folder\\secret", "bad\nname", String(repeating: "a", count: 241)] { XCTAssertThrowsError(try journal(name: name)) }
        for bytes in [Data(), Data(repeating: 0, count: TaskFileUploadJournal.maximumBytes + 1)] { XCTAssertThrowsError(try journal(bytes: bytes)) }
        for type in ["text/html", "image/svg+xml", "TEXT/PLAIN"] { XCTAssertThrowsError(try journal(type: type)) }
        XCTAssertNoThrow(try journal(bytes: Data(repeating: 0, count: TaskFileUploadJournal.maximumBytes), type: "application/octet-stream"))
    }
    func testTamperedBytesOrUnknownJournalFieldsCannotRecover() throws {
        let value = try journal(); var raw = try TaskfoldJSONDecoder().decode(Record.self, from: TaskfoldJSONEncoder().encode(value))
        raw["bytes"] = .string(Data("different".utf8).base64EncodedString())
        XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(TaskFileUploadJournal.self, from: TaskfoldJSONEncoder().encode(raw)))
        raw = try TaskfoldJSONDecoder().decode(Record.self, from: TaskfoldJSONEncoder().encode(value)); raw["future"] = .bool(true)
        XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(TaskFileUploadJournal.self, from: TaskfoldJSONEncoder().encode(raw)))
    }
    func testReceiptRequiresExactOperationAccountTargetAndFileDescriptor() throws {
        let value = try journal().markingAttempted(), original = try TaskfoldJSONDecoder().decode(Record.self, from: publication(value))
        for key in ["account", "operation_id", "target", "protocol", "state"] {
            var fields = original["receipt"].object; fields[key] = .string("changed")
            XCTAssertThrowsError(try value.receiving(TaskfoldJSONEncoder().encode(Record(["receipt": .object(fields)]))), key)
        }
        for key in ["id", "storage_object_id", "name", "size", "type", "sha256", "uploadedAt"] {
            var fields = original["receipt"].object, attachment = fields["attachment"]!.object; attachment[key] = .string("changed"); fields["attachment"] = .object(attachment)
            XCTAssertThrowsError(try value.receiving(TaskfoldJSONEncoder().encode(Record(["receipt": .object(fields)]))), key)
        }
        XCTAssertThrowsError(try journal().receiving(publication(value)))
        XCTAssertThrowsError(try value.receiving(publication(value, state: "attempted")))
    }
    func testOnlyAuthenticatedTerminalStatesResolveAndKeepBytes() throws {
        let value = try journal().markingAttempted()
        for state in ["published", "cancelled", "expired"] { let result = try value.receiving(publication(value, state: state)); XCTAssertTrue(result.resolved); XCTAssertEqual(result.bytes, value.bytes); XCTAssertNotNil(result.receipt) }
        let reserved = try value.receiving(publication(value, state: "reserved")); XCTAssertFalse(reserved.resolved); XCTAssertNil(reserved.receipt)
    }
    func testCiphertextColdReadHasNoPlaintextAndIsBoundToOrigin() async throws {
        let root = try root(), source = try journal(), io = io(root), vault = vault(root, io: io)
        try await vault.begin(source, lease: .init())
        let cipher = try Data(contentsOf: io.file); XCTAssertNil(cipher.range(of: source.bytes)); XCTAssertNil(cipher.range(of: Data(source.name.utf8)))
        let cold = self.vault(root); let restored = try await cold.pending(account: fileAccount, origin: fileOrigin); XCTAssertEqual(restored, source)
        let other = self.io(root, origin: "https://other.example")
        XCTAssertThrowsError(try other.read(key: TaskFileUploadJournal.storagePrefix + fileAccount + "." + CalendarOAuthConfiguration.digest("https://other.example")))
    }
    func testCASRefusesStaleWindowAndCannotResurrectClearedJournal() async throws {
        let root = try root(), source = try journal(), vault = vault(root), attempted = try source.markingAttempted()
        try await vault.begin(source, lease: .init()); try await vault.replace(source, with: attempted, lease: .init())
        do { try await vault.replace(source, with: source, lease: .init()); XCTFail("stale replacement") } catch { }
        do { try await vault.clear(source, lease: .init()); XCTFail("stale clear") } catch { }
        try await vault.clear(attempted, lease: .init())
        do { try await vault.replace(attempted, with: source, lease: .init()); XCTFail("resurrection") } catch { }
    }
    @MainActor func testMaximumBinaryFileFitsEncryptedRecoveryAndRealHTTPEnvelope() async throws {
        let root = try root(), value = try journal(bytes: Data(repeating: 255, count: TaskFileUploadJournal.maximumBytes), type: "application/octet-stream"), vault = vault(root)
        try await vault.begin(value, lease: .init()); let cold = try await vault.pending(account: fileAccount, origin: fileOrigin); XCTAssertEqual(cold, value)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FileHTTP.self]
        let session = try TaskfoldJSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(fileAccount)\"}}".utf8))
        let backend = Backend(configuration: ["URL": fileOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        FileHTTP.handler = { request, peer in
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var chunk = [UInt8](repeating: 0, count: 65536); while stream.hasBytesAvailable { let count = stream.read(&chunk, maxLength: chunk.count); if count <= 0 { break }; bytes.append(contentsOf: chunk.prefix(count)) } }
            XCTAssertLessThanOrEqual(bytes.count, TaskFileUploadJournal.maximumStoredBytes)
            let body = try! TaskfoldJSONDecoder().decode(Record.self, from: bytes); XCTAssertEqual(Data(base64Encoded: body.string("bytes_base64")), value.bytes)
            peer.reply(try! publication(value))
        }
        defer { FileHTTP.handler = nil }
        _ = try await backend.taskFileReply(value.markingAttempted(), action: "publish", incarnation: backend.reminderSessionIncarnation)
    }
    @MainActor func testDurableAttemptPrecedesSendAndLostReplyRecoversSameIdentity() async throws {
        let root = try root(), vault = vault(root), peer = FilePeer(); peer.lose = true
        peer.beforeSend = { journal in let durable = try await vault.pending(account: fileAccount, origin: fileOrigin); XCTAssertEqual(durable, journal); XCTAssertEqual(durable?.phase, .attempted) }
        let model = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: vault, service: peer, incarnation: UUID(), current: { true })
        await model.load(); await model.choose(Data("Private workshop notes".utf8), name: "Workshop.txt", type: "text/plain"); await model.act("publish")
        XCTAssertEqual(model.pending?.phase, .attempted); XCTAssertEqual(peer.applied.count, 1)
        let cold = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: self.vault(root), service: peer, incarnation: UUID(), current: { true })
        await cold.load(); await cold.act("resolve"); XCTAssertEqual(cold.pending?.phase, .published); XCTAssertEqual(peer.applied.count, 1); XCTAssertEqual(peer.calls.map { $0.1.id }, [model.pending!.id, model.pending!.id])
    }
    @MainActor func testQueuedCancellationDoesNotSendAndStatusDoesNotMarkUnsentAttempted() async throws {
        let root = try root(), peer = FilePeer(), model = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: vault(root), service: peer, incarnation: UUID(), current: { true })
        await model.load(); await model.choose(Data("hello".utf8), name: "hello.txt", type: "text/plain"); await model.act("resolve"); XCTAssertEqual(model.pending?.phase, .queued)
        await model.act("cancel"); XCTAssertNil(model.pending); XCTAssertTrue(peer.calls.isEmpty)
        let durable = try await vault(root).pending(account: fileAccount, origin: fileOrigin); XCTAssertNil(durable)
    }
    @MainActor func testWriteFailureAndAnotherPendingFilePreventNetworkAndReplacement() async throws {
        let root = try root(), fault = FileFaultIO(io(root)), vault = vault(root, io: fault), peer = FilePeer()
        let model = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: vault, service: peer, incarnation: UUID(), current: { true })
        await model.load(); await model.choose(Data("hello".utf8), name: "hello.txt", type: "text/plain"); let original = model.pending
        await model.choose(Data("other".utf8), name: "other.txt", type: "text/plain"); XCTAssertEqual(model.pending, original)
        fault.failWrite(true); await model.act("publish"); XCTAssertTrue(peer.calls.isEmpty); XCTAssertEqual(model.pending, original)
    }
    @MainActor func testAccountSwitchWhileAwaitingReplyKeepsAttemptedOriginalWithoutLateUIReceipt() async throws {
        let root = try root(), peer = FilePeer(); peer.hold = true; var current = true
        let vault = vault(root), model = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: vault, service: peer, incarnation: UUID(), current: { current })
        await model.load(); await model.choose(Data("hello".utf8), name: "hello.txt", type: "text/plain")
        let task = Task { await model.act("publish") }; for _ in 0..<1000 { if peer.continuation != nil { break }; await Task.yield() }; XCTAssertNotNil(peer.continuation)
        current = false; model.close(); peer.continuation?.resume(); await task.value
        XCTAssertNil(model.pending); let durable = try await vault.pending(account: fileAccount, origin: fileOrigin); XCTAssertEqual(durable?.phase, .attempted); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testDisabledPublicationStillLoadsAndResolvesSavedOriginal() async throws {
        let root = try root(), vault = vault(root), source = try journal().markingAttempted(), peer = FilePeer(); try await vault.begin(source, lease: .init())
        let model = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: vault, service: peer, incarnation: UUID(), current: { true }, publishAllowed: { false })
        await model.load(); await model.act("publish"); XCTAssertTrue(peer.calls.isEmpty); await model.act("resolve"); XCTAssertEqual(peer.calls.first?.0, "resolve"); XCTAssertEqual(model.pending?.phase, .attempted)
    }
    @MainActor func testMalformedReceiptCannotClearOrConfirmAndTerminalCopyClearsOnlyExplicitly() async throws {
        let root = try root(), peer = FilePeer(), model = TaskFileUploadModel(account: fileAccount, origin: fileOrigin, target: fileTarget, vault: vault(root), service: peer, incarnation: UUID(), current: { true }); peer.malformed = true
        await model.load(); await model.choose(Data("hello".utf8), name: "hello.txt", type: "text/plain"); await model.act("publish"); await model.finish(); XCTAssertEqual(model.pending?.phase, .attempted)
        peer.malformed = false; await model.act("resolve"); XCTAssertEqual(model.pending?.phase, .published); XCTAssertNotNil(model.pending?.bytes); await model.finish(); XCTAssertNil(model.pending); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testActualBackendSendsFrozenBytesAndOnlyOperationForRecovery() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FileHTTP.self]
        let session = try TaskfoldJSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(fileAccount)\"}}".utf8))
        let backend = Backend(configuration: ["URL": fileOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        let value = try journal().markingAttempted(); defer { FileHTTP.handler = nil }
        for action in ["publish", "resolve", "cancel"] {
            FileHTTP.handler = { request, peer in
                XCTAssertEqual(request.url?.absoluteString, fileOrigin + "/functions/v1/task-files?action=" + action)
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-auth")
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var chunk = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&chunk, maxLength: chunk.count); if count <= 0 { break }; bytes.append(contentsOf: chunk.prefix(count)) } }
                let body = try! TaskfoldJSONDecoder().decode(Record.self, from: bytes)
                XCTAssertEqual(body, action == "publish" ? Record(["intent": .object(value.intent.fields), "bytes_base64": .string(value.bytes.base64EncodedString())]) : Record(["operation_id": .string(value.id)]))
                peer.reply(try! publication(value))
            }
            let reply = try await backend.taskFileReply(value, action: action, incarnation: backend.reminderSessionIncarnation)
            XCTAssertEqual(try value.receiving(reply).phase, .published)
        }
    }
    @MainActor func testBackendRejectsWrongSessionBeforeAnyNetworkRequest() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FileHTTP.self]
        let session = try TaskfoldJSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(fileAccount)\"}}".utf8))
        let backend = Backend(configuration: ["URL": fileOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        FileHTTP.handler = { _, _ in XCTFail("must not send") }; defer { FileHTTP.handler = nil }
        do { _ = try await backend.taskFileReply(journal().markingAttempted(), action: "publish", incarnation: UUID()); XCTFail("must refuse changed session") } catch { }
    }
    @MainActor func testBackendDownloadVerifiesActualBytesBeforeReturningCopy() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FileHTTP.self]
        let session = try TaskfoldJSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(fileAccount)\"}}".utf8))
        let backend = Backend(configuration: ["URL": fileOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        let value = try journal().markingAttempted(), r = try TaskfoldJSONDecoder().decode(Record.self, from: publication(value)), attachment = Record(r["receipt"].object["attachment"]!.object)
        defer { FileHTTP.handler = nil }
        for correct in [true, false] {
            FileHTTP.handler = { request, peer in
                XCTAssertEqual(request.url?.absoluteString, fileOrigin + "/functions/v1/task-files?action=download"); XCTAssertFalse(request.httpShouldHandleCookies)
                peer.reply(correct ? value.bytes : Data(repeating: 0, count: value.bytes.count))
            }
            do {
                let bytes = try await backend.downloadTaskFile(attachment, target: fileTarget, account: fileAccount, origin: fileOrigin, incarnation: backend.reminderSessionIncarnation)
                XCTAssertTrue(correct); XCTAssertEqual(bytes, value.bytes)
            } catch { XCTAssertFalse(correct) }
        }
    }
}
