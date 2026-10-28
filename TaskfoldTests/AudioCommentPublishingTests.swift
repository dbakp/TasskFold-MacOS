import XCTest
import Darwin
@testable import TaskfoldCore

final class AudioCommentPublishingTests: XCTestCase {
    var root: URL!
    let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let origin = "https://publication.example.invalid"
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-publication-tests-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    func source() throws -> AudioCommentSavedDraft { try .init(owner: .init(account.uuidString.lowercased()), target: .init(task: UUID(), generation: UUID(), project: nil), caption: "  cafe\u{301}\nمراجعة 🪴  ", clip: .init(data: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "audio-comment-synthetic-tone", withExtension: "m4a", subdirectory: "Fixtures"))))) }
    func disk() throws -> AudioCommentPublicationDisk { try .init(root: root, account: account, origin: origin) }
    func record(_ publication: AudioCommentPublication) -> Record {
        var row = publication.record.fields; row.removeValue(forKey: "version")
        row["protocol"] = .number(1); row["author_id"] = .string(account.uuidString.lowercased()); row["state"] = .string("published")
        row["reserved_at"] = .string("2026-10-28T15:00:00+00:00"); row["expires_at"] = .string("2026-10-29T15:00:00+00:00"); row["published_at"] = .string("2026-10-28T15:00:01.123456+00:00"); return Record(row)
    }
    func testRelaunchKeepsFrozenIdentityExactBytesAndLiteralCaption() throws {
        let source = try source(), original = try disk().prepare(source), resumed = try disk().prepare(source)
        XCTAssertTrue(original.publication.sameIntent(as: resumed.publication)); XCTAssertEqual(resumed.clip?.data, source.clip.data)
        XCTAssertTrue(resumed.publication.caption.utf8.elementsEqual(source.caption.utf8)); XCTAssertEqual(try disk().journals().count, 1)
    }
    func testReceiptCompactsJournalAndPreventsRepublishAfterRelaunch() throws {
        let source = try source(), pending = try disk().prepare(source), receipt = try AudioCommentPublishedReceipt(record: record(pending.publication), publication: pending.publication)
        let confirmed = try disk().confirm(pending, receipt: receipt), resumed = try disk().prepare(source)
        XCTAssertNil(confirmed.clip); XCTAssertNotNil(resumed.receipt); XCTAssertTrue(resumed.publication.sameIntent(as: pending.publication)); XCTAssertLessThan(try resumed.encoded().count, 10000)
    }
    func testUnconfirmedEarlierRevisionBlocksAnotherIdentity() throws {
        let source = try source(); _ = try disk().prepare(source)
        XCTAssertThrowsError(try disk().prepare(source.replacing(caption: "Edited later", clip: source.clip)))
        XCTAssertEqual(try disk().journals().count, 1)
    }
    func testConfirmedEarlierRevisionAllowsExplicitEditedRecording() throws {
        let source = try source(), pending = try disk().prepare(source); _ = try disk().confirm(pending, receipt: .init(record: record(pending.publication), publication: pending.publication))
        let edited = try disk().prepare(source.replacing(caption: "Edited later", clip: source.clip)); XCTAssertNotEqual(edited.publication.operation, pending.publication.operation); XCTAssertNil(edited.receipt)
    }
    func testServerAndAccountNamespacesCannotAdoptEachOthersJournal() throws {
        let original = try disk().prepare(source()), data = try original.encoded()
        XCTAssertThrowsError(try AudioCommentPublicationJournal(encoded: data, account: UUID(), origin: origin))
        XCTAssertThrowsError(try AudioCommentPublicationJournal(encoded: data, account: account, origin: "https://other.example.invalid"))
        XCTAssertTrue(try AudioCommentPublicationDisk(root: root, account: account, origin: "https://other.example.invalid").journals().isEmpty)
        for invalid in ["http://publication.example.invalid", "https://user:password@publication.example.invalid", origin + "/task", origin + "?token=x", origin + "#task"] { XCTAssertThrowsError(try AudioCommentPublicationDisk(root: root, account: account, origin: invalid)) }
    }
    func testEchoPendingWrongAuthorWrongCaptionAndExtraFieldsCannotConfirm() throws {
        let publication = try disk().prepare(source()).publication
        XCTAssertThrowsError(try AudioCommentPublishedReceipt(record: publication.record, publication: publication))
        for (key, value) in [("state", JSON.string("pending")), ("author_id", .string(UUID().uuidString.lowercased())), ("caption", .string("  café\nمراجعة 🪴  ")), ("object_name", .string("untrusted/path")), ("published_at", .string("2030-01-01T00:00:00Z"))] {
            var fields = record(publication).fields; fields[key] = value
            XCTAssertThrowsError(try AudioCommentPublishedReceipt(record: Record(fields), publication: publication), key)
        }
    }
    func testUnknownRenameOutcomeReusesOriginalOperation() throws {
        var failing = try disk(); failing.fault = { if case .afterRename = $0 { throw AudioCommentStorageFailure.unreadable } }
        let source = try source(); XCTAssertThrowsError(try failing.prepare(source))
        let stored = try XCTUnwrap(disk().journals().first), recovered = try disk().prepare(source)
        XCTAssertTrue(stored.publication.sameIntent(as: recovered.publication)); XCTAssertEqual(try disk().journals().count, 1)
    }
    func testFailedReceiptRenameLeavesRetryablePendingJournal() throws {
        let pending = try disk().prepare(source()); var failing = try disk(); failing.fault = { if case .beforeRename = $0 { throw AudioCommentStorageFailure.unreadable } }
        XCTAssertThrowsError(try failing.confirm(pending, receipt: .init(record: record(pending.publication), publication: pending.publication)))
        let resumed = try XCTUnwrap(disk().journals().first); XCTAssertNil(resumed.receipt); XCTAssertNotNil(resumed.clip); XCTAssertTrue(resumed.publication.sameIntent(as: pending.publication))
    }
    @MainActor final class Transport: AudioCommentPublishingTransport {
        var requests: [AudioCommentPending] = []
        var response: ((AudioCommentPending) async throws -> AudioCommentPublishedReceipt)!
        func publishAudio(_ pending: AudioCommentPending, origin: String, incarnation: UUID) async throws -> AudioCommentPublishedReceipt { requests.append(pending); return try await response(pending) }
    }
    @MainActor func testNetworkStartsOnlyAfterFrozenJournalIsDurable() async throws {
        let file = try disk(), storage = AudioCommentPublicationStorage(disk: file), transport = Transport(), input = try source()
        transport.response = { pending in let written = try XCTUnwrap(file.journals().first); XCTAssertTrue(written.publication.sameIntent(as: pending.publication)); return try .init(record: self.record(pending.publication), publication: pending.publication) }
        let flow = AudioCommentPublicationFlow(storage: storage, transport: transport, incarnation: UUID(), target: input.target, isCurrent: { true }); try await flow.publish(input); XCTAssertEqual(transport.requests.count, 1); XCTAssertNotNil(flow.journal?.receipt)
        let reopened = AudioCommentPublicationFlow(storage: storage, transport: transport, incarnation: UUID(), target: input.target, isCurrent: { true }); try await reopened.publish(sourceForJournal(try XCTUnwrap(flow.journal))); XCTAssertEqual(transport.requests.count, 1)
    }
    func sourceForJournal(_ journal: AudioCommentPublicationJournal) throws -> AudioCommentSavedDraft { let clip = try source().clip; return try .init(owner: .init(account.uuidString.lowercased()), target: journal.publication.target, caption: journal.publication.caption, clip: clip, id: journal.source, revision: journal.revision) }
    @MainActor func testRestoringNewReviewDoesNotPrepareOrSend() async throws {
        let input = try source(), storage = AudioCommentPublicationStorage(disk: try disk()), transport = Transport()
        let flow = AudioCommentPublicationFlow(storage: storage, transport: transport, incarnation: UUID(), target: input.target, isCurrent: { true })
        try await flow.restore(input); XCTAssertEqual(flow.state, .ready); XCTAssertNil(flow.journal); XCTAssertTrue(try disk().journals().isEmpty); XCTAssertTrue(transport.requests.isEmpty)
    }
    @MainActor func testRestoringPendingAndConfirmedReviewNeverSends() async throws {
        let input = try source(), file = try disk(), pending = try file.prepare(input), storage = AudioCommentPublicationStorage(disk: file), transport = Transport()
        let flow = AudioCommentPublicationFlow(storage: storage, transport: transport, incarnation: UUID(), target: input.target, isCurrent: { true })
        try await flow.restore(input); XCTAssertEqual(flow.state, .unconfirmed); XCTAssertEqual(flow.journal?.publication.operation, pending.publication.operation)
        _ = try file.confirm(pending, receipt: .init(record: record(pending.publication), publication: pending.publication))
        try await flow.restore(input); XCTAssertEqual(flow.state, .published); XCTAssertTrue(transport.requests.isEmpty)
    }
    @MainActor func testRestoringDifferentUnconfirmedRevisionRequiresEarlierReview() async throws {
        let input = try source(), file = try disk(); _ = try file.prepare(input)
        let changed = try input.replacing(caption: "Edited review", clip: input.clip), transport = Transport()
        let flow = AudioCommentPublicationFlow(storage: .init(disk: file), transport: transport, incarnation: UUID(), target: input.target, isCurrent: { true })
        do { try await flow.restore(changed); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("earlier version")) }
        XCTAssertNil(flow.journal); XCTAssertTrue(transport.requests.isEmpty); XCTAssertEqual(try file.journals().count, 1)
    }
    @MainActor func testLostResponseRetriesOriginalIdentityAfterNewController() async throws {
        let storage = AudioCommentPublicationStorage(disk: try disk()), transport = Transport(), source = try source()
        transport.response = { _ in throw URLError(.networkConnectionLost) }
        let first = AudioCommentPublicationFlow(storage: storage, transport: transport, incarnation: UUID(), target: source.target, isCurrent: { true })
        do { try await first.publish(source); XCTFail() } catch {}
        let pending = try XCTUnwrap(disk().journals().first)
        transport.response = { try .init(record: self.record($0.publication), publication: $0.publication) }
        let reopened = AudioCommentPublicationFlow(storage: storage, transport: transport, incarnation: UUID(), target: source.target, isCurrent: { true }); try await reopened.retry(pending)
        XCTAssertEqual(transport.requests.count, 2); XCTAssertTrue(transport.requests[0].publication.sameIntent(as: transport.requests[1].publication)); XCTAssertNotNil(reopened.journal?.receipt)
    }
    @MainActor func testDepartureDiscardsLatePresentationAndKeepsPendingOperation() async throws {
        let storage = AudioCommentPublicationStorage(disk: try disk()), transport = Transport(); var completion: CheckedContinuation<AudioCommentPublishedReceipt, Error>?
        transport.response = { _ in try await withCheckedThrowingContinuation { completion = $0 } }
        let source = try source(), flow = AudioCommentPublicationFlow(storage: storage, transport: transport, incarnation: UUID(), target: source.target, isCurrent: { true })
        let task = Task { try await flow.publish(source) }
        while completion == nil { await Task.yield() }
        flow.invalidate(); let publication = try XCTUnwrap(transport.requests.first).publication
        completion?.resume(returning: try .init(record: record(publication), publication: publication))
        do { try await task.value; XCTFail() } catch {}
        XCTAssertNil(flow.journal); XCTAssertNil(try disk().journals().first?.receipt); XCTAssertEqual(try disk().journals().first?.publication.operation, publication.operation)
    }
    @MainActor func testFailedDurablePrepareNeverCallsTransport() async throws {
        var failing = try disk(); failing.fault = { if case .beforeRename = $0 { throw AudioCommentStorageFailure.full } }
        let input = try source(), transport = Transport(), flow = AudioCommentPublicationFlow(storage: .init(disk: failing), transport: transport, incarnation: UUID(), target: input.target, isCurrent: { true })
        do { try await flow.publish(input); XCTFail() } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

private final class PublicationHTTP: URLProtocol {
    static var handler: ((URLRequest, PublicationHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Self.handler?(request, self) }
    func finish(_ data: Data, status: Int = 200) { client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
}
private final class PublicationHTTPGate: @unchecked Sendable {
    private let lock = NSLock(); private var value: PublicationHTTP?
    func hold(_ value: PublicationHTTP) { lock.lock(); self.value = value; lock.unlock() }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
    func release(_ data: Data) { lock.lock(); let held = value; value = nil; lock.unlock(); held?.finish(data) }
}
extension AudioCommentPublishingTests {
    @MainActor func testFlowCannotPublishAnotherTargetEvenIfCallbackIsTrue() async throws {
        let transport = Transport(), source = try source(), other = try AudioCommentTarget(task: UUID(), generation: UUID(), project: nil)
        let flow = AudioCommentPublicationFlow(storage: .init(disk: try disk()), transport: transport, incarnation: UUID(), target: other, isCurrent: { true })
        do { try await flow.publish(source); XCTFail() } catch {}
        XCTAssertTrue(transport.requests.isEmpty); XCTAssertTrue(try disk().journals().isEmpty)
    }
    @MainActor func backend() throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PublicationHTTP.self]
        let raw: [String: JSON] = ["access_token": .string("synthetic-auth"), "refresh_token": .string("synthetic-refresh"), "expires_in": .number(3600), "user": .object(["id": .string(account.uuidString.lowercased())])]
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(raw))
        return Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testBackendPublishesExactFrozenBytesThroughPrivateFixedRoute() async throws {
        let backend = try backend(), journal = try disk().prepare(source()), pending = try AudioCommentPending(publication: journal.publication, clip: XCTUnwrap(journal.clip)); var bodies: [Data] = []
        let response = try JSONEncoder().encode(Record(["receipt": .object(record(pending.publication).fields)]))
        PublicationHTTP.handler = { request, http in
            XCTAssertEqual(request.url?.absoluteString, self.origin + "/functions/v1/audio-comments?action=publish"); XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-auth"); XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "synthetic-public"); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.timeoutInterval, 25)
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) } }
            bodies.append(body); http.finish(response)
        }; defer { PublicationHTTP.handler = nil }
        _ = try await backend.publishAudio(pending, origin: origin, incarnation: backend.reminderSessionIncarnation)
        _ = try await backend.publishAudio(pending, origin: origin, incarnation: backend.reminderSessionIncarnation)
        XCTAssertEqual(bodies.count, 2); XCTAssertEqual(bodies[0], bodies[1]); let body = try JSONDecoder().decode(Record.self, from: bodies[0]); XCTAssertEqual(body["intent"], .object(pending.publication.record.fields)); XCTAssertEqual(Data(base64Encoded: body.string("audio_base64")), pending.clip.data)
    }
    @MainActor func testMaximumRecordingWithSlashHeavyBase64StaysInsideGatewayEnvelope() async throws {
        let backend = try backend(), original = try source(); var bytes = original.clip.data
        let extra = AudioCommentDescriptor.maximumBytes - bytes.count; var length = UInt32(extra).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }; bytes.append(Data("free".utf8)); bytes.append(Data(repeating: 255, count: extra - 8))
        let clip = try AudioCommentClip(data: bytes), publication = try AudioCommentPublication(account: account, target: original.target, caption: original.caption, descriptor: clip.descriptor), pending = try AudioCommentPending(publication: publication, clip: clip)
        let response = try JSONEncoder().encode(Record(["receipt": .object(record(publication).fields)])); var sent = false
        PublicationHTTP.handler = { request, http in
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 65536); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) } }
            XCTAssertLessThanOrEqual(body.count, ((AudioCommentDescriptor.maximumBytes + 2) / 3) * 4 + 64000); sent = true; http.finish(response)
        }; defer { PublicationHTTP.handler = nil }
        _ = try await backend.publishAudio(pending, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTAssertTrue(sent)
    }
    @MainActor func testBackendRejectsWrongServerOrSessionBeforeHTTP() async throws {
        let backend = try backend(), journal = try disk().prepare(source()), pending = try AudioCommentPending(publication: journal.publication, clip: XCTUnwrap(journal.clip)); var calls = 0
        PublicationHTTP.handler = { _, http in calls += 1; http.finish(Data()) }; defer { PublicationHTTP.handler = nil }
        do { _ = try await backend.publishAudio(pending, origin: "https://other.example.invalid", incarnation: backend.reminderSessionIncarnation); XCTFail() } catch {}
        do { _ = try await backend.publishAudio(pending, origin: origin, incarnation: UUID()); XCTFail() } catch {}
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testBackendEchoAndPendingReceiptsRemainUnconfirmed() async throws {
        let backend = try backend(), journal = try disk().prepare(source()), pending = try AudioCommentPending(publication: journal.publication, clip: XCTUnwrap(journal.clip))
        for raw in [pending.publication.record, Record(["receipt": .object(pending.publication.record.fields)])] {
            PublicationHTTP.handler = { _, http in http.finish(try! JSONEncoder().encode(raw)) }
            do { _ = try await backend.publishAudio(pending, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("couldn’t be confirmed")) }
        }; PublicationHTTP.handler = nil; XCTAssertNil(try disk().journals().first?.receipt)
    }
    @MainActor func testBackendOversizedResponseIsBoundedAndDoesNotSettle() async throws {
        let backend = try backend(), journal = try disk().prepare(source()), pending = try AudioCommentPending(publication: journal.publication, clip: XCTUnwrap(journal.clip))
        PublicationHTTP.handler = { _, http in http.finish(Data(repeating: 32, count: 64001)) }; defer { PublicationHTTP.handler = nil }
        do { _ = try await backend.publishAudio(pending, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTFail() } catch {}
        XCTAssertNil(try disk().journals().first?.receipt)
    }
    @MainActor func testBackendLateAccountResponseCannotConfirm() async throws {
        let backend = try backend(), journal = try disk().prepare(source()), pending = try AudioCommentPending(publication: journal.publication, clip: XCTUnwrap(journal.clip)), gate = PublicationHTTPGate(), incarnation = backend.reminderSessionIncarnation
        PublicationHTTP.handler = { _, http in gate.hold(http) }; defer { PublicationHTTP.handler = nil }
        let task = Task { try await backend.publishAudio(pending, origin: origin, incarnation: incarnation) }
        for _ in 0..<500 { if gate.ready { break }; try await Task.sleep(for: .milliseconds(10)) }; XCTAssertTrue(gate.ready)
        try await backend.clearSession(); gate.release(try JSONEncoder().encode(Record(["receipt": .object(record(pending.publication).fields)])))
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertNil(try disk().journals().first?.receipt)
    }
    @MainActor func testBackendSanitizesFailedProviderReply() async throws {
        let backend = try backend(), journal = try disk().prepare(source()), pending = try AudioCommentPending(publication: journal.publication, clip: XCTUnwrap(journal.clip))
        PublicationHTTP.handler = { _, http in http.finish(Data("PRIVATE PROVIDER DETAIL synthetic-secret".utf8), status: 503) }; defer { PublicationHTTP.handler = nil }
        do { _ = try await backend.publishAudio(pending, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")); XCTAssertFalse(error.localizedDescription.contains("synthetic-secret")); XCTAssertTrue(error.localizedDescription.contains("couldn’t be confirmed")) }
    }
}
