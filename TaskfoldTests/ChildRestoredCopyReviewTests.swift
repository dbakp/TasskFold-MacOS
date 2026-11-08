import XCTest
@testable import TaskfoldCore


private final class HeldReviewHTTP: URLProtocol {
    static var handler: ((URLRequest, HeldReviewHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String:String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

final class ChildRestoredCopyReviewTests: XCTestCase {
    struct Fixture {
        let review: ChildTaskAdoptionReview, data: Data
        let actor: String, restoration: String
    }
    func fixture(session: UUID? = nil) throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-restored-copy-contract-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fields = try ChildTaskRecordRead.separatingJSONFields(["root", "review", "held"], data: Data(contentsOf: url), maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: []).values
        let root = try TaskfoldJSONDecoder().decode(Record.self, from: XCTUnwrap(fields["root"]))
        let source = try ChildTaskRecordRead.separatingJSONField("source_tree", data: XCTUnwrap(fields["review"]), maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: [])
        let metadata = try TaskfoldJSONDecoder().decode([String: JSON].self, from: source.metadata)
        let context = try ChildTaskRecordContext(account: metadata["account"]!.text, origin: "https://repair.test", workspace: UUID(), session: session ?? UUID(), access: UUID(), snapshot: UUID(), root: root)
        let review = try ChildTaskAdoptionReview(data: XCTUnwrap(fields["review"]), context: context, workspaceID: nil)
        let data = try XCTUnwrap(fields["held"])
        let held = try ChildTaskRecordRead.separatingJSONField("copies", data: data, maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: [])
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: held.metadata)
        return .init(review: review, data: data, actor: raw["restoration"]!.object["actor_id"]!.text, restoration: raw["restoration"]!.object["restore_id"]!.text)
    }
    func testRealAuthenticatedRestorationComparisonPreservesOpaqueCopies() throws {
        let f = try fixture(), result = try ChildTaskRestoredCopyReview(data: f.data, review: f.review, actorID: f.actor, restorationID: f.restoration)
        XCTAssertEqual(result.restoration.revision, 1)
        XCTAssertTrue(result.copies.omitted.isEmpty)
        XCTAssertTrue(result.copies.copies[2].visible)
        let exported = String(decoding: result.copies.exportBundle, as: UTF8.self)
        XCTAssertTrue(exported.contains("9007199254740993"))
        XCTAssertFalse(String(reflecting: result).contains("Original instruction"))
        XCTAssertFalse(String(describing: result).contains(f.actor))
    }
    func testComparisonRequiresExactRestorationAndCurrentReviewContext() throws {
        let f = try fixture()
        XCTAssertThrowsError(try ChildTaskRestoredCopyReview(data: f.data, review: f.review, actorID: UUID().uuidString.lowercased(), restorationID: f.restoration))
        XCTAssertThrowsError(try ChildTaskRestoredCopyReview(data: f.data, review: f.review, actorID: f.actor, restorationID: UUID().uuidString.lowercased()))
        let raw = String(decoding: f.data, as: UTF8.self)
        for (name,data) in [
            ("extra", Data(raw.replacingOccurrences(of: "{\"", with: "{\"extra\":true,\"", range: raw.range(of: "{\"")).utf8)),
            ("foreign task", Data(raw.replacingOccurrences(of: f.review.context.root.id, with: UUID().uuidString.lowercased()).utf8)),
            ("missing revision", Data(raw.replacingOccurrences(of: "\"revision\": 1", with: "\"revision\": 0").utf8))
        ] {
            XCTAssertNotEqual(data, f.data, name)
            XCTAssertThrowsError(try ChildTaskRestoredCopyReview(data: data, review: f.review, actorID: f.actor, restorationID: f.restoration), name)
        }
    }
    func testUnsafeFractionalNegativeAndDuplicateBindingCountersAreRefused() throws {
        let f = try fixture(), text = String(decoding: f.data, as: UTF8.self)
        for spelling in ["1.5", "-1", "9007199254740992", "1e500", "\"1\"", "null", "1, \"revision\": 1"] {
            let changed = Data(text.replacingOccurrences(of: "\"revision\": 1", with: "\"revision\": " + spelling).utf8)
            XCTAssertNotEqual(changed, f.data)
            XCTAssertThrowsError(try ChildTaskRestoredCopyReview(data: changed, review: f.review, actorID: f.actor, restorationID: f.restoration), spelling)
        }
    }
    @MainActor private func backend(account: String) throws -> Backend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldReviewHTTP.self]
        let session = try TaskfoldJSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic\",\"refresh_token\":\"synthetic\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration: ["URL": "https://repair.test", "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: session, persistSession: { _ in })
    }
    @MainActor func testTransportIsPrivateBoundedAndCannotReuseEndedSession() async throws {
        let first = try fixture(), api = try backend(account: first.review.context.account)
        let f = try fixture(session: api.reminderSessionIncarnation); var calls = 0
        defer { HeldReviewHTTP.handler = nil }
        HeldReviewHTTP.handler = { request, peer in
            calls += 1
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_review_restored_child_copies")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            peer.finish(200, f.data)
        }
        let value = try await api.restoredChildTaskCopyReview(f.review, actorID: f.actor, restorationID: f.restoration)
        XCTAssertEqual(value.restoration.restorationID, f.restoration); XCTAssertEqual(calls, 1)
        HeldReviewHTTP.handler = { _, peer in calls += 1; peer.finish(200, Data(), headers: ["Content-Length": String(ChildTaskRestoredCopyReview.maximumBytes + 1)]) }
        do { _ = try await api.restoredChildTaskCopyReview(f.review, actorID: f.actor, restorationID: f.restoration); XCTFail("Oversized private response accepted") }
        catch { XCTAssertTrue(error is ChildTaskRepairFailure) }
        XCTAssertEqual(calls, 2)
        try await api.clearSession()
        do { _ = try await api.restoredChildTaskCopyReview(f.review, actorID: f.actor, restorationID: f.restoration); XCTFail("Ended session reused") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testLatePrivateTransportReplyCannotCrossSessionBoundary() async throws {
        let first = try fixture(), api = try backend(account: first.review.context.account)
        let f = try fixture(session: api.reminderSessionIncarnation)
        defer { HeldReviewHTTP.handler = nil }
        HeldReviewHTTP.handler = { _, peer in Task { @MainActor in try await api.clearSession(); peer.finish(200, f.data) } }
        do { _ = try await api.restoredChildTaskCopyReview(f.review, actorID: f.actor, restorationID: f.restoration); XCTFail("Late content crossed the session boundary") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
