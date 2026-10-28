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
    func finish(_ data: Data, status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"]) { client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
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

extension AudioCommentPublishingTests {
    @MainActor func testPresentationMaskClosesBeforeSignOutPersistenceCompletes() async throws {
        let original = try backend(); var release: CheckedContinuation<Void, Never>?
        let peer = Backend(configuration: ["URL": origin, "Key": "synthetic-public"], session: original.session, persistSession: { _ in await withCheckedContinuation { release = $0 } })
        XCTAssertTrue(peer.audioPublicationSessionMatches(account.uuidString.lowercased()))
        let operation = Task { try await peer.clearSession() }
        for _ in 0..<500 { if release != nil { break }; await Task.yield() }
        XCTAssertNotNil(release); XCTAssertNotNil(peer.session); XCTAssertFalse(peer.audioPublicationSessionMatches(account.uuidString.lowercased()))
        release?.resume(); try await operation.value
        XCTAssertFalse(peer.audioPublicationSessionMatches(account.uuidString.lowercased()))
    }
    @MainActor func testPrivateRecoveryCopyReusesOriginalOperationAndBlocksEditedDuplicate() async throws {
        let file = try disk(), original = try source(), pending = try file.prepare(original)
        let copy = try AudioCommentSavedDraft(owner: original.owner, target: original.target, caption: original.caption, clip: original.clip, id: pending.publication.asset, revision: pending.publication.operation)
        XCTAssertEqual(try file.prepare(copy).publication.operation, pending.publication.operation)
        let edited = try copy.replacing(caption: "Edited recovery copy", clip: copy.clip)
        XCTAssertThrowsError(try file.prepare(edited))
        let transport = Transport(), flow = AudioCommentPublicationFlow(storage: .init(disk: file), transport: transport, incarnation: UUID(), target: original.target, isCurrent: { true })
        try await flow.restore(copy); XCTAssertEqual(flow.journal?.publication.operation, pending.publication.operation); XCTAssertTrue(transport.requests.isEmpty)
        _ = try file.confirm(pending, receipt: .init(record: record(pending.publication), publication: pending.publication), retainingAudio: true)
        XCTAssertNotEqual(try file.prepare(edited).publication.operation, pending.publication.operation)
    }
    func testConfirmedCopyCanShrinkEvenWithTwentyOtherPendingEntries() throws {
        let file = try disk(), original = try file.prepare(source())
        let kept = try file.confirm(original, receipt: .init(record: record(original.publication), publication: original.publication), retainingAudio: true)
        for _ in 0..<20 { _ = try file.prepare(source()) }
        XCTAssertThrowsError(try file.prepare(source()))
        XCTAssertNil(try file.releaseConfirmedAudio(kept).clip)
        XCTAssertEqual(try file.journals().filter { $0.receipt == nil }.count, 20)
    }
    func testRetainedConfirmationSurvivesReopenWithExactAudioAndReceipt() throws {
        let file = try disk(), source = try source(), pending = try file.prepare(source)
        let receipt = try AudioCommentPublishedReceipt(record: record(pending.publication), publication: pending.publication)
        let kept = try file.confirm(pending, receipt: receipt, retainingAudio: true), reopened = try XCTUnwrap(disk().journals().first)
        XCTAssertNotNil(kept.receipt); XCTAssertEqual(reopened.clip?.data, source.clip.data); XCTAssertEqual(reopened.receipt?.record, receipt.record)
        XCTAssertTrue(try disk().prepare(source).publication.sameIntent(as: pending.publication))
    }
    func testOnlyExactConfirmedCopyCanBeExplicitlyReleased() throws {
        let file = try disk(), pending = try file.prepare(source())
        XCTAssertThrowsError(try file.releaseConfirmedAudio(pending))
        let kept = try file.confirm(pending, receipt: .init(record: record(pending.publication), publication: pending.publication), retainingAudio: true)
        let released = try file.releaseConfirmedAudio(kept); XCTAssertNil(released.clip); XCTAssertNotNil(released.receipt)
        XCTAssertNil(try disk().releaseConfirmedAudio(kept).clip)
        XCTAssertEqual(try disk().journals().count, 1)
    }
    func testInterruptedRetentionReleaseKeepsFullConfirmedRecording() throws {
        let file = try disk(), pending = try file.prepare(source()), kept = try file.confirm(pending, receipt: .init(record: record(pending.publication), publication: pending.publication), retainingAudio: true)
        var failing = file; failing.fault = { if case .beforeRename = $0 { throw AudioCommentStorageFailure.unreadable } }
        XCTAssertThrowsError(try failing.releaseConfirmedAudio(kept)); XCTAssertNotNil(try disk().journals().first?.clip); XCTAssertNotNil(try disk().journals().first?.receipt)
    }
}

extension AudioCommentPublishingTests {
    func remote(_ input: AudioCommentPublication? = nil) throws -> AudioCommentRemote {
        let publication = try input ?? disk().prepare(source()).publication
        return try .init(record: record(publication), account: account, target: publication.target)
    }
    func listData(_ rows: [AudioCommentRemote]) throws -> Data { try JSONEncoder().encode(Record(["protocol": .number(1), "account": .string(account.uuidString.lowercased()), "items": .array(rows.map { .object($0.record.fields) })])) }
    func testRemoteMetadataPreservesLiteralCaptionAndAllowsDifferentOrRemovedAuthor() throws {
        let original = try remote()
        for author in [JSON.string(UUID().uuidString.lowercased()), .null] {
            var fields = original.record.fields; fields["author_id"] = author
            let read = try AudioCommentRemote(record: Record(fields), account: account, target: original.publication.target)
            XCTAssertTrue(read.publication.caption.utf8.elementsEqual(original.publication.caption.utf8)); XCTAssertEqual(read.author == nil, author == .null)
        }
    }
    func testRemoteListRejectsForeignTaskAccountDuplicateIdentityAndExtraFields() throws {
        let value = try remote(), bytes = try listData([value]); XCTAssertEqual(try AudioCommentRemote.list(bytes, account: account, target: value.publication.target), [value])
        XCTAssertThrowsError(try AudioCommentRemote.list(bytes, account: UUID(), target: value.publication.target))
        XCTAssertThrowsError(try AudioCommentRemote.list(bytes, account: account, target: .init(task: UUID(), generation: UUID(), project: nil)))
        XCTAssertThrowsError(try AudioCommentRemote.list(listData([value,value]), account: account, target: value.publication.target))
        for (key, field) in [("state", JSON.string("pending")),("object_name", .string("private/path")),("published_at", .string("2031-01-01T00:00:00Z")),("author_id", .string("invalid"))] {
            var fields = value.record.fields; fields[key] = field
            XCTAssertThrowsError(try AudioCommentRemote(record: Record(fields), account: account, target: value.publication.target))
        }
        XCTAssertThrowsError(try AudioCommentRemote.list(Data(repeating: 32, count: 640_001), account: account, target: value.publication.target))
    }
    @MainActor func testRemoteListUsesOnlyFixedAuthenticatedNoCookieRoute() async throws {
        let backend = try backend(), value = try remote(), response = try listData([value]); var calls = 0
        PublicationHTTP.handler = { request, http in
            calls += 1; XCTAssertEqual(request.url?.absoluteString, self.origin + "/functions/v1/audio-comments?action=list"); XCTAssertEqual(request.httpMethod,"POST"); XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-auth"); XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store"); XCTAssertFalse(request.httpShouldHandleCookies); http.finish(response)
        }; defer { PublicationHTTP.handler = nil }
        let rows = try await backend.listAudio(account: account, target: value.publication.target, origin: origin, incarnation: backend.reminderSessionIncarnation)
        XCTAssertEqual(rows,[value]); XCTAssertEqual(calls,1)
    }
    @MainActor func testRemoteDownloadRequiresExactDigestBytesAndNativeAACDecode() async throws {
        let backend = try backend(), draft = try source(), publication = try AudioCommentPublication(account: account, target: draft.target, caption: draft.caption, descriptor: draft.clip.descriptor), value = try remote(publication)
        PublicationHTTP.handler = { _, http in http.finish(draft.clip.data, headers:["Content-Type":"audio/mp4", "X-Audio-SHA256":draft.clip.descriptor.sha256]) }; defer { PublicationHTTP.handler = nil }
        let clip = try await backend.downloadAudio(value, origin: origin, incarnation: backend.reminderSessionIncarnation)
        XCTAssertEqual(clip.data,draft.clip.data); XCTAssertEqual(clip.descriptor,draft.clip.descriptor)
        for headers in [["Content-Type":"audio/mp4"],["Content-Type":"application/json","X-Audio-SHA256":draft.clip.descriptor.sha256],["Content-Type":"audio/mp4","X-Audio-SHA256":String(repeating:"a",count:64)]] {
            PublicationHTTP.handler = { _, http in http.finish(draft.clip.data, headers:headers) }
            do { _ = try await backend.downloadAudio(value, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTFail() } catch {}
        }
        PublicationHTTP.handler = { _, http in http.finish(Data("damaged".utf8), headers:["Content-Type":"audio/mp4","X-Audio-SHA256":draft.clip.descriptor.sha256]) }
        do { _ = try await backend.downloadAudio(value, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTFail() } catch {}
    }
    @MainActor func testRemoteRemovalRequiresExactOperationCommentAndTerminalState() async throws {
        let backend = try backend(), value = try remote()
        let fields: [String:JSON] = ["protocol":.number(1),"account":.string(account.uuidString.lowercased()),"operation_id":.string(value.publication.operation.uuidString.lowercased()),"comment_id":.string(value.id.uuidString.lowercased()),"state":.string("retired")]
        PublicationHTTP.handler = { _, http in http.finish(try! JSONEncoder().encode(Record(fields))) }; defer { PublicationHTTP.handler = nil }
        let removed = try await backend.removeAudio(value, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTAssertEqual(removed.comment,value.id)
        for (key,field) in [("comment_id",JSON.string(UUID().uuidString.lowercased())),("operation_id",.string(UUID().uuidString.lowercased())),("state",.string("published")),("account",.string(UUID().uuidString.lowercased()))] {
            var altered = fields; altered[key] = field
            PublicationHTTP.handler = { _, http in http.finish(try! JSONEncoder().encode(Record(altered))) }
            do { _ = try await backend.removeAudio(value, origin: origin, incarnation: backend.reminderSessionIncarnation); XCTFail() } catch {}
        }
    }
    @MainActor func testRemoteRefusesWrongSessionOrOriginBeforeAnyRequest() async throws {
        let backend = try backend(), value = try remote(); var calls = 0
        PublicationHTTP.handler = { _, http in calls += 1; http.finish(Data()) }; defer { PublicationHTTP.handler = nil }
        do { _ = try await backend.listAudio(account:account,target:value.publication.target,origin:origin,incarnation:UUID()); XCTFail() } catch {}
        do { _ = try await backend.downloadAudio(value,origin:"https://other.example.invalid",incarnation:backend.reminderSessionIncarnation); XCTFail() } catch {}
        do { _ = try await backend.removeAudio(value,origin:origin,incarnation:UUID()); XCTFail() } catch {}
        XCTAssertEqual(calls,0)
    }
    @MainActor func testRemoteLateResponseCannotReturnAfterAccountDeparture() async throws {
        let backend = try backend(), value = try remote(), gate = PublicationHTTPGate(), incarnation = backend.reminderSessionIncarnation
        PublicationHTTP.handler = { _, http in gate.hold(http) }; defer { PublicationHTTP.handler = nil }
        let operation = Task { try await backend.listAudio(account:account,target:value.publication.target,origin:origin,incarnation:incarnation) }
        for _ in 0..<500 { if gate.ready { break }; try await Task.sleep(for:.milliseconds(10)) }; XCTAssertTrue(gate.ready)
        try await backend.clearSession(); gate.release(try listData([value]))
        do { _ = try await operation.value; XCTFail() } catch {}
    }
    @MainActor func testRemoteErrorsNeverExposeProviderTextOrAcceptRedirect() async throws {
        let backend = try backend(), value = try remote()
        for status in [302,401,403,404,429,503] {
            PublicationHTTP.handler = { _,http in http.finish(Data("synthetic-private-provider-secret".utf8),status:status) }
            do { _ = try await backend.listAudio(account:account,target:value.publication.target,origin:origin,incarnation:backend.reminderSessionIncarnation); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-private")) }
        }; PublicationHTTP.handler = nil
    }
}

extension AudioCommentPublishingTests {
    func pageData(_ items:[AudioCommentRemote], next: Record? = nil) throws -> Data {
        try JSONEncoder().encode(Record(["protocol":.number(1),"account":.string(account.uuidString.lowercased()),"items":.array(items.map { .object($0.record.fields) }),"next":next.map { .object($0.fields) } ?? .null]))
    }
    func testPageCursorPreservesExactMicrosecondsAndBindsAccountAndTarget() throws {
        let first=try remote(),target=first.publication.target
        let items=try (0..<20).map { _ in try remote(.init(account:account,target:target,caption:"Recording",descriptor:first.publication.descriptor)) }
        let last=try XCTUnwrap(items.last),position=Record(["published_at":last.record["published_at"],"comment_id":last.record["comment_id"]])
        let page=try AudioCommentPage(data:pageData(items,next:position),account:account,target:target,after:nil)
        XCTAssertEqual(page.items.count,20);XCTAssertEqual(page.next?.position.string("published_at"),"2026-10-28T15:00:01.123456+00:00")
        XCTAssertEqual(page.next?.account,account);XCTAssertEqual(page.next?.target,target)
        XCTAssertThrowsError(try AudioCommentPage(data:pageData([]),account:UUID(),target:target,after:page.next))
        XCTAssertThrowsError(try AudioCommentPage(data:pageData(items,next:position),account:account,target:target,after:page.next))
        var wrong=position.fields;wrong["comment_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try AudioCommentPage(data:pageData(items,next:Record(wrong)),account:account,target:target,after:nil))
        XCTAssertThrowsError(try AudioCommentPage(data:pageData([first],next:position),account:account,target:target,after:nil))
    }
    @MainActor func testBackendPageUsesBoundCursorAndFixedAuthenticatedRoute() async throws {
        let backend=try backend(),value=try remote(),position=try AudioCommentPageCursor(position:Record(["published_at":value.record["published_at"],"comment_id":value.record["comment_id"]]),account:account,target:value.publication.target)
        var calls=0
        PublicationHTTP.handler={request,http in
            calls += 1;XCTAssertEqual(request.url?.absoluteString,self.origin+"/functions/v1/audio-comments?action=page")
            var bytes=request.httpBody ?? Data()
            if let stream=request.httpBodyStream { stream.open();defer { stream.close() };var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count);if n<=0 { break };bytes.append(buffer,count:n) } }
            let body=try! JSONDecoder().decode(Record.self,from:bytes);XCTAssertEqual(body["after"],.object(position.position.fields));XCTAssertEqual(body["target"],.object(value.publication.target.record.fields))
            http.finish(try! self.pageData([]))
        };defer{PublicationHTTP.handler=nil}
        let page=try await backend.pageAudio(account:account,target:value.publication.target,after:position,origin:origin,incarnation:backend.reminderSessionIncarnation)
        XCTAssertTrue(page.items.isEmpty);XCTAssertNil(page.next)
        do {_ = try await backend.pageAudio(account:account,target:.init(task:UUID(),generation:UUID(),project:nil),after:position,origin:origin,incarnation:backend.reminderSessionIncarnation);XCTFail()}catch{}
        XCTAssertEqual(calls,1)
    }
}

extension AudioCommentPublishingTests {
    func closedProof(_ publication:AudioCommentPublication) throws -> AudioCommentPublicationClosed {
        try .init(record:Record(["protocol":.number(1),"intent":.object(publication.record.fields),"state":.string("closed")]),publication:publication)
    }
    func testClosedProofRejectsChangedIntentAndUnboundStatuses() throws {
        let pending=try disk().prepare(source()),proof=try closedProof(pending.publication)
        for (key,value) in [("state",JSON.string("expired")),("account",.string(account.uuidString.lowercased())),("protocol",.number(2))] {
            var fields=proof.record.fields;fields[key]=value
            XCTAssertThrowsError(try AudioCommentPublicationClosed(record:Record(fields),publication:pending.publication))
        }
        var changed=pending.publication.record.fields;changed["caption"] = .string("  café\nمراجعة 🪴  ")
        var fields=proof.record.fields;fields["intent"] = .object(changed)
        XCTAssertThrowsError(try AudioCommentPublicationClosed(record:Record(fields),publication:pending.publication))
        XCTAssertThrowsError(try AudioCommentPublicationClosed(record:Record(["status":.string("retired"),"operation_id":.string(pending.publication.operation.uuidString.lowercased())]),publication:pending.publication))
    }
    func testClosedProofRoundTripsWithMediaThenExplicitCompaction() throws {
        let input=try source(),file=try disk(),pending=try file.prepare(input)
        let closed=try file.settleClosed(pending,proof:closedProof(pending.publication))
        XCTAssertFalse(closed.isPending);XCTAssertNil(closed.receipt);XCTAssertEqual(closed.clip?.data,input.clip.data)
        let reopened=try AudioCommentPublicationJournal(encoded:closed.encoded(),account:account,origin:origin)
        XCTAssertEqual(reopened.closedReceipt?.record,closed.closedReceipt?.record);XCTAssertEqual(reopened.clip?.data,input.clip.data)
        let compact=try file.releaseResolvedAudio(reopened)
        XCTAssertNil(compact.clip);XCTAssertNotNil(compact.closedReceipt)
        XCTAssertLessThan(try compact.encoded().count,10000)
        XCTAssertNotNil(try file.prepare(input).closedReceipt)
        XCTAssertThrowsError(try file.releaseConfirmedAudio(closed))
    }
    func testClosedFileNeedsExactNonemptyProofAndUnchangedMedia() throws {
        let file=try disk(),pending=try file.prepare(source()),closed=try file.settleClosed(pending,proof:closedProof(pending.publication))
        let fields=try XCTUnwrap(PropertyListSerialization.propertyList(from:closed.encoded(),format:nil) as? [String:Any])
        for change in ["empty","missing","both","audio"] {
            var value=fields
            switch change {
            case "empty":value["closed"]=Data()
            case "missing":value.removeValue(forKey:"closed")
            case "both":value["receipt"]=try JSONEncoder().encode(record(pending.publication))
            default:value["audio"]=Data([1,2,3])
            }
            let bytes=try PropertyListSerialization.data(fromPropertyList:value,format:.binary,options:0)
            XCTAssertThrowsError(try AudioCommentPublicationJournal(encoded:bytes,account:account,origin:origin),change)
        }
    }
    func testClosedOriginalRequiresExplicitNewSavedRevision() throws {
        let input=try source(),file=try disk(),pending=try file.prepare(input)
        _=try file.settleClosed(pending,proof:closedProof(pending.publication))
        let same=try file.prepare(input);XCTAssertEqual(same.publication.operation,pending.publication.operation);XCTAssertNotNil(same.closedReceipt)
        let edited=try input.replacing(caption:"Reviewed new version",clip:input.clip)
        let fresh=try file.prepare(edited);XCTAssertTrue(fresh.isPending);XCTAssertNotEqual(fresh.publication.operation,pending.publication.operation)
        XCTAssertEqual(try file.journals().count,2)
    }
    func testClosedEntryDoesNotConsumePendingQuotaButRetainsMediaBytes() throws {
        let file=try disk(),pending=try file.prepare(source()),closed=try file.settleClosed(pending,proof:closedProof(pending.publication))
        for _ in 0..<20 {_=try file.prepare(source())}
        XCTAssertEqual(try file.journals().filter(\.isPending).count,20)
        XCTAssertThrowsError(try file.prepare(source()))
        let compact=try file.releaseResolvedAudio(closed);XCTAssertNil(compact.clip);XCTAssertNotNil(compact.closedReceipt)
    }
    func testClosedWriteBeforeRenameFailurePreservesPendingAndAfterRenameReconciles() throws {
        let file=try disk(),pending=try file.prepare(source()),proof=try closedProof(pending.publication)
        var failing=file;failing.fault={if case .beforeRename=$0 {throw AudioCommentStorageFailure.unreadable}}
        XCTAssertThrowsError(try failing.settleClosed(pending,proof:proof));XCTAssertTrue(try XCTUnwrap(file.journals().first).isPending)
        failing.fault={if case .afterRename=$0 {throw AudioCommentStorageFailure.unreadable}}
        XCTAssertThrowsError(try failing.settleClosed(pending,proof:proof))
        let restored=try file.settleClosed(pending,proof:proof);XCTAssertNotNil(restored.closedReceipt);XCTAssertNotNil(restored.clip)
        XCTAssertEqual(try file.journals().count,1)
    }
    func testPublishedAndClosedProofsCannotOverwriteEachOther() throws {
        let file=try disk(),pending=try file.prepare(source()),proof=try closedProof(pending.publication)
        _=try file.confirm(pending,receipt:.init(record:record(pending.publication),publication:pending.publication))
        XCTAssertThrowsError(try file.settleClosed(pending,proof:proof))
        let other=try file.prepare(source());_=try file.settleClosed(other,proof:closedProof(other.publication))
        XCTAssertThrowsError(try file.confirm(other,receipt:.init(record:record(other.publication),publication:other.publication)))
        let terminal=try XCTUnwrap(file.journals().first{$0.publication.operation==other.publication.operation})
        XCTAssertThrowsError(try terminal.confirmed(.init(record:record(other.publication),publication:other.publication)))
    }
    func testPendingAndForeignClosedCopyCannotBeReleasedOrSettled() throws {
        let file=try disk(),pending=try file.prepare(source()),other=try file.prepare(source())
        XCTAssertThrowsError(try file.releaseResolvedAudio(pending))
        XCTAssertThrowsError(try file.settleClosed(pending,proof:closedProof(other.publication)))
        let closed=try file.settleClosed(pending,proof:closedProof(pending.publication))
        XCTAssertThrowsError(try AudioCommentPublicationJournal(encoded:closed.encoded(),account:UUID(),origin:origin))
        XCTAssertThrowsError(try AudioCommentPublicationJournal(encoded:closed.encoded(),account:account,origin:"https://another.example.invalid"))
    }
    @MainActor func testFlowPersistsClosedAndColdRetryNeverResends() async throws {
        let file=try disk(),input=try source(),transport=Transport()
        transport.response={pending in throw try self.closedProof(pending.publication)}
        let flow=AudioCommentPublicationFlow(storage:.init(disk:file),transport:transport,incarnation:UUID(),target:input.target,isCurrent:{true})
        try await flow.publish(input);XCTAssertEqual(flow.state,.closed);XCTAssertEqual(transport.requests.count,1)
        let journal=try XCTUnwrap(flow.journal);XCTAssertEqual(journal.clip?.data,input.clip.data)
        let restored=AudioCommentPublicationFlow(storage:.init(disk:file),transport:transport,incarnation:UUID(),target:input.target,isCurrent:{true})
        try await restored.restore(input);XCTAssertEqual(restored.state,.closed)
        try await restored.retry(journal);try await restored.publish(input)
        XCTAssertEqual(restored.state,.closed);XCTAssertEqual(transport.requests.count,1)
    }
    @MainActor func testTimeoutAndGenericRetiredMessageRemainUnconfirmed() async throws {
        let file=try disk(),input=try source(),transport=Transport()
        transport.response={_ in throw AudioCommentFailure(message:"retired")}
        let flow=AudioCommentPublicationFlow(storage:.init(disk:file),transport:transport,incarnation:UUID(),target:input.target,isCurrent:{true})
        do {try await flow.publish(input);XCTFail("Expected uncertainty")}catch{}
        XCTAssertEqual(flow.state,.unconfirmed);XCTAssertTrue(try XCTUnwrap(file.journals().first).isPending)
    }
    @MainActor func testDepartureDuringClosedReplyDoesNotSettleOrUpdateNewContext() async throws {
        let file=try disk(),input=try source(),transport=Transport();var current=true
        transport.response={pending in current=false;throw try self.closedProof(pending.publication)}
        let flow=AudioCommentPublicationFlow(storage:.init(disk:file),transport:transport,incarnation:UUID(),target:input.target,isCurrent:{current})
        do {try await flow.publish(input);XCTFail("Expected departure")}catch{}
        XCTAssertTrue(try XCTUnwrap(file.journals().first).isPending);XCTAssertNil(flow.journal?.closedReceipt)
    }
}
