import XCTest
@testable import TaskfoldCore

private final class StructureReadHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var callback: ((URLRequest, StructureReadHTTP) -> Void)?
    static var handler: ((URLRequest, StructureReadHTTP) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class StructureReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: StructureReadHTTP?
    func hold(_ value: StructureReadHTTP) { lock.lock(); held = value; lock.unlock() }
    func release(_ status: Int, _ data: Data) { lock.lock(); let value = held; held = nil; lock.unlock(); value?.finish(status, data) }
}
final class ChildTaskStructureReadTests: XCTestCase {
    private func fixture() throws -> (String, Record, [String: JSON]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-structure-read", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        return (try XCTUnwrap(raw["account"]?.text), Record(try XCTUnwrap(raw["root"]?.object)), try XCTUnwrap(raw["response"]?.object))
    }
    private func context(_ root: Record, _ account: String, session: UUID = UUID()) throws -> ChildTaskRecordContext {
        try .init(account: account, origin: "https://child-record.test", workspace: UUID(), session: session, access: UUID(), snapshot: UUID(), root: root)
    }
    private func encode(_ raw: [String: JSON]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(raw)
    }
    private func decode(_ raw: [String: JSON], _ root: Record, _ account: String) throws -> ChildTaskStructureRead {
        try .init(data: encode(raw), context: context(root, account))
    }
    private func field(_ name: String, value: JSON, raw: inout [String: JSON], root: inout Record) throws {
        var rows = raw["records"]!.list
        let index = try XCTUnwrap(rows.firstIndex { $0.object["node_key"] == .string("a") })
        var row = rows[index].object, fields = row["fields"]!.object
        fields[name] = value; row["fields"] = .object(fields); rows[index] = .object(row); raw["records"] = .array(rows)
        var roots = root["subtasks"].list
        let parentIndex = try XCTUnwrap(roots.firstIndex { $0.object["id"] == .string("a") })
        var parent = roots[parentIndex].object; parent[name] = value; roots[parentIndex] = .object(parent); root["subtasks"] = .array(roots)
    }
    func testActualPostgresV2ReadReconstructsExactTreeAndAuthoredOrder() throws {
        let (account, root, raw) = try fixture(), read = try decode(raw, root, account)
        XCTAssertEqual(read.structureRevision, 2)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(read.records.tree, root["subtasks"]))
        XCTAssertEqual(read.records.orderedNodes.map(\.key), ["fresh", "a", "nested", "b"])
        XCTAssertEqual(read.records.nodes["nested"]?.childrenKind, "null")
        XCTAssertEqual(read.records.nodes["a"]?.fields["attachments"]?.list.count, 1)
    }
    func testActualNativeTeamFieldReceiptKeepsExistingClientContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "native-team-child-field-write", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let body = try XCTUnwrap(fixture["body"]?.object), receipt = try XCTUnwrap(fixture["receipt"]?.object)
        let command = try ChildTaskFieldCommand(account: try XCTUnwrap(body["account"]?.text), origin: "https://child-record.test", body: body)
        XCTAssertNoThrow(try command.confirmed(receipt))
        XCTAssertEqual(receipt["node_key"], body["node_key"])
        XCTAssertEqual(receipt["protocol"], .number(1))
    }
    func testVersionsRemainSeparateWithoutSilentFallback() throws {
        let (account, root, raw) = try fixture(), scope = try context(root, account)
        XCTAssertThrowsError(try ChildTaskRecordRead(data: encode(raw), context: scope))
        var old = raw; old.removeValue(forKey: "structure_revision"); old["protocol"] = .number(1)
        XCTAssertNoThrow(try ChildTaskRecordRead(data: encode(old), context: scope))
        XCTAssertThrowsError(try ChildTaskStructureRead(data: encode(old), context: scope))
    }
    func testUnknownMissingOrCrossScopeHeadersRefuse() throws {
        let (account, root, original) = try fixture()
        for (key, value) in [("unexpected", JSON.bool(true)), ("protocol", .number(3)), ("account", .string(UUID().uuidString.lowercased())), ("task_id", .string(UUID().uuidString.lowercased())), ("project_id", .null), ("task_generation", .string(UUID().uuidString.lowercased()))] {
            var raw = original; raw[key] = value; XCTAssertThrowsError(try decode(raw, root, account), key)
        }
        for key in ["structure_revision", "records", "root_kind"] {
            var raw = original; raw.removeValue(forKey: key); XCTAssertThrowsError(try decode(raw, root, account), key)
        }
    }
    func testCounterLexemesCannotRoundIntoAValidProof() throws {
        let (account, root, raw) = try fixture(), scope = try context(root, account)
        let text = String(decoding: try encode(raw), as: UTF8.self)
        for invalid in ["0", "-1", "1.0", "1e0", "9007199254740990.5", "1.00000000000000000000000000000000000000000001", "9007199254740992", "null", "true", "\"2\""] {
            let changed = text.replacingOccurrences(of: "\"structure_revision\":2", with: "\"structure_revision\":" + invalid)
            XCTAssertNotEqual(changed, text)
            XCTAssertThrowsError(try ChildTaskStructureRead(data: Data(changed.utf8), context: scope), invalid)
        }
        var highest = raw; highest["structure_revision"] = .number(9_007_199_254_740_991)
        XCTAssertEqual(try decode(highest, root, account).structureRevision, 9_007_199_254_740_991)
    }
    func testRecordAndProjectionCountersAlsoUseCanonicalIntegers() throws {
        let (account, root, raw) = try fixture(), scope = try context(root, account)
        let text = String(decoding: try encode(raw), as: UTF8.self)
        for (key, old) in [("projection_revision", String(raw["projection_revision"]!.integer)), ("revision", "1"), ("sibling_order", "0")] {
            let changed = text.replacingOccurrences(of: "\"" + key + "\":" + old, with: "\"" + key + "\":9007199254740990.5")
            XCTAssertNotEqual(changed, text)
            XCTAssertThrowsError(try ChildTaskStructureRead(data: Data(changed.utf8), context: scope), key)
        }
    }
    func testOpaqueFractionalMetadataIsNotMistakenForRecordCounters() throws {
        let (account, originalRoot, original) = try fixture(); var root = originalRoot, raw = original
        try field("future", value: .object(["revision": .number(1.5), "records": .array([.object(["revision": .number(2.25)])])]), raw: &raw, root: &root)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(try decode(raw, root, account).records.tree, root["subtasks"]))
    }
    func testDuplicateHeaderAndOpaqueKeysRefuseBeforeDictionaryCollapse() throws {
        let (account, originalRoot, original) = try fixture(); var root = originalRoot, raw = original
        try field("future", value: .object(["duplicate": .number(2)]), raw: &raw, root: &root)
        let text = String(decoding: try encode(raw), as: UTF8.self), scope = try context(root, account)
        for changed in [text.replacingOccurrences(of: "\"duplicate\":2", with: "\"duplicate\":1,\"duplicate\":2"), String(text.dropLast()) + ",\"structure_revision\":2}"] {
            XCTAssertThrowsError(try ChildTaskStructureRead(data: Data(changed.utf8), context: scope))
        }
    }
    func testNearWireLimitDoesNotRequireAnExpandedReencoding() throws {
        let (account, originalRoot, original) = try fixture(); var root = originalRoot, raw = original
        let size = ChildTaskStructureRead.maximumBytes - (try encode(raw).count) - 200
        try field("description", value: .string(String(repeating: "/", count: size)), raw: &raw, root: &root)
        let bytes = try encode(raw); XCTAssertLessThanOrEqual(bytes.count, ChildTaskStructureRead.maximumBytes)
        XCTAssertGreaterThan(bytes.count, 1_900_000)
        let read = try ChildTaskStructureRead(data: bytes, context: context(root, account))
        XCTAssertEqual(read.records.nodes["a"]?.fields["description"]?.text.utf8.count, size)
    }
    func testOversizedWireRefusesBeforeParsing() throws {
        let (account, root, _) = try fixture()
        XCTAssertThrowsError(try ChildTaskStructureRead(data: Data(repeating: 32, count: 2_000_001), context: context(root, account))) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large"))
        }
    }
    @MainActor private func backend(_ account: String) throws -> Backend {
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic\",\"refresh_token\":\"synthetic\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StructureReadHTTP.self]
        return Backend(configuration: ["URL": "https://child-record.test", "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: session, persistSession: { _ in })
    }
    @MainActor func testBackendUsesSeparateUncachedBoundedRoute() async throws {
        let (account, root, raw) = try fixture(), api = try backend(account), bytes = try encode(raw)
        StructureReadHTTP.handler = { request, transport in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_read_child_structure")
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.timeoutInterval, 25)
            transport.finish(200, bytes)
        }; defer { StructureReadHTTP.handler = nil }
        let result = try await api.childTaskStructure(context(root, account, session: api.reminderSessionIncarnation))
        XCTAssertEqual(result.structureRevision, 2)
    }
    @MainActor func testBackendSanitizesGateAccessAndSizeFailures() async throws {
        let (account, root, _) = try fixture(), api = try backend(account), scope = try context(root, account, session: api.reminderSessionIncarnation)
        defer { StructureReadHTTP.handler = nil }
        for code in ["PT503", "PGRST202", "42501", "PT409", "54000"] {
            StructureReadHTTP.handler = { _, transport in transport.finish(403, Data("{\"code\":\"\(code)\",\"message\":\"private diagnostic\"}".utf8)) }
            do { _ = try await api.childTaskStructure(scope); XCTFail("Expected refusal") } catch { XCTAssertTrue(error is ChildTaskRecordFailure); XCTAssertFalse(error.localizedDescription.contains("private diagnostic")) }
        }
        StructureReadHTTP.handler = { _, transport in transport.finish(200, Data("{}".utf8), headers: ["Content-Length": "2000001"]) }
        do { _ = try await api.childTaskStructure(scope); XCTFail("Expected bounded refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }
    @MainActor func testHeldSuccessAndFailureCannotEscapeAccountSwitch() async throws {
        let (account, root, raw) = try fixture(); defer { StructureReadHTTP.handler = nil }
        for status in [200, 403] {
            let api = try backend(account), scope = try context(root, account, session: api.reminderSessionIncarnation)
            let gate = StructureReadGate(), started = expectation(description: "Structural read held")
            StructureReadHTTP.handler = { _, transport in gate.hold(transport); started.fulfill() }
            let task = Task { @MainActor in try await api.childTaskStructure(scope) }
            await fulfillment(of: [started], timeout: 3)
            api.session = try backend(UUID().uuidString.lowercased()).session
            gate.release(status, status == 200 ? try encode(raw) : Data("{\"code\":\"PT409\"}".utf8))
            do { _ = try await task.value; XCTFail("Stale response escaped") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }
}
