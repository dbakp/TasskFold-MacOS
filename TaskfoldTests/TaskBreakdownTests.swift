import XCTest
@testable import TaskfoldCore

final class TaskBreakdownTests: XCTestCase {
    private let workspace = WorkspaceBinding(account: "owner", generation: UUID())
    private let session = UUID()
    private func source() -> Record {
        Record(["id": .string("task"), "title": .string("Prepare a picnic"), "project_id": .string("chosen-project"), "due_date": .string("2026-11-06"), "description": .string("Private original e\u{301}"), "future": .object(["opaque": .array([.number(-0.0), .string("keep")])]), "subtasks": .array([.object(["id": .string("existing"), "title": .string("Existing work"), "completed": .bool(true), "extension": .object(["keep": .bool(true)])])])])
    }
    private func request(_ row: Record? = nil, depth: Int = 0) throws -> TaskBreakdownRequest {
        try .init(workspace: workspace, session: session, source: row ?? source(), depth: depth)
    }
    func testLiteralTitlesAppendFreshChildrenWithoutChangingOriginalMetadata() throws {
        let original = source(), r = try request(original)
        let titles = [" Call @Alice #Finance tomorrow p1 ", "Pack food"]
        let children = try r.applying(titles, to: original, workspace: workspace, session: session)
        XCTAssertEqual(children.list.count, 3)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(children.list[0], original["subtasks"].list[0]))
        XCTAssertEqual(children.list[1].object["title"], .string(titles[0].trimmingCharacters(in: .whitespaces)))
        for child in children.list.dropFirst() {
            XCTAssertEqual(Set(child.object.keys), ["id", "title", "completed"])
            XCTAssertNotNil(UUID(uuidString: child.object["id"]!.text))
            XCTAssertEqual(child.object["completed"], .bool(false))
        }
        XCTAssertEqual(Set(children.list.map { $0.object["id"]!.text }).count, 3)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(original.fields), .object(source().fields)))
    }
    func testRejectsAnyChangedDraftBeforeApplying() throws {
        let original = source(), r = try request(original)
        for field in ["id", "title", "project_id", "due_date", "description", "subtasks", "future", "completed"] {
            var changed = original; changed[field] = .string("changed")
            XCTAssertThrowsError(try r.applying(["One step"], to: changed, workspace: workspace, session: session), field)
        }
        var added = original; added["new_field"] = .bool(true)
        XCTAssertThrowsError(try r.applying(["One step"], to: added, workspace: workspace, session: session))
    }
    func testExactUnicodeSourceBindingAndWorkspaceIncarnation() throws {
        var original = source(); original["title"] = .string("Cafe\u{301}")
        let r = try request(original)
        var changed = original; changed["title"] = .string("Caf\u{e9}")
        XCTAssertThrowsError(try r.applying(["One step"], to: changed, workspace: workspace, session: session))
        for w in [WorkspaceBinding(account: "other", generation: workspace.generation), WorkspaceBinding(account: "owner", generation: UUID())] {
            XCTAssertThrowsError(try r.applying(["One step"], to: original, workspace: w, session: session))
        }
        XCTAssertThrowsError(try r.applying(["One step"], to: original, workspace: workspace, session: UUID()))
    }
    func testTitleValidationRejectsBlankMultilineControlsDuplicatesAndOversize() throws {
        for titles in [[], [""], ["  "], ["a\nb"], ["a\tb"], ["a\u{2028}b"], ["a\u{2029}b"], ["a\0b"], ["A", "a"], ["Cafe\u{301}", "Caf\u{e9}"], [String(repeating: "x", count: 301)], [String(repeating: "👩‍👧‍👦", count: 100)], Array(repeating: "x", count: 13)] {
            XCTAssertThrowsError(try TaskBreakdownRequest.titles(titles), String(describing: titles.prefix(2)))
        }
        XCTAssertEqual(try TaskBreakdownRequest.titles((1...12).map { "Step \($0)" }).count, 12)
        XCTAssertEqual(try TaskBreakdownRequest.titles(["  Pack food  "]), ["Pack food"])
    }
    func testGoalBoundsAndOriginalPreservationAfterValidationFailure() throws {
        XCTAssertEqual(try TaskBreakdownRequest.goal("  Picnic\n "), "Picnic")
        for goal in [" ", "x\0y", String(repeating: "é", count: 1001)] { XCTAssertThrowsError(try TaskBreakdownRequest.goal(goal)) }
        let original = source(), r = try request(original)
        XCTAssertThrowsError(try r.applying(["Good step", ""], to: original, workspace: workspace, session: session))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(original.fields), .object(r.source.fields)))
        XCTAssertEqual(original["subtasks"].list.count, 1)
    }
    func testUnavailableSourceAndDepthRefuseOpening() throws {
        for field in ["completed", "is_heading"] {
            var row = source(); row[field] = .bool(true)
            XCTAssertThrowsError(try request(row))
        }
        var invalid = source(); invalid["subtasks"] = .string("future container")
        XCTAssertThrowsError(try request(invalid))
        XCTAssertThrowsError(try request(depth: -1))
        XCTAssertThrowsError(try request(depth: SubtaskTree.maximumDepth))
        let r = try request(depth: SubtaskTree.maximumDepth - 1)
        XCTAssertEqual(try r.applying(["Last level"], to: source(), workspace: workspace, session: session).list.count, 2)
    }
    func testApplyingTwiceCannotDuplicateIntoChangedDraft() throws {
        let r = try request(); var draft = source()
        draft["subtasks"] = try r.applying(["One step"], to: draft, workspace: workspace, session: session)
        XCTAssertThrowsError(try r.applying(["One step"], to: draft, workspace: workspace, session: session))
        XCTAssertEqual(draft["subtasks"].list.count, 2)
    }
    func testCancelSupersedeAndLateAccountResultsAreIgnored() throws {
        var run = TaskBreakdownSession(request: try request())
        let old = try XCTUnwrap(run.begin(workspace: workspace, session: session))
        run.stop()
        XCTAssertNil(try run.receive(["Old"], token: old, workspace: workspace, session: session))
        let current = try XCTUnwrap(run.begin(workspace: workspace, session: session))
        XCTAssertNil(try run.receive(["Old"], token: old, workspace: workspace, session: session))
        XCTAssertNil(try run.receive(["Wrong account"], token: current, workspace: .init(account: "other", generation: workspace.generation), session: session))
        XCTAssertNil(try run.receive(["Wrong session"], token: current, workspace: workspace, session: UUID()))
        XCTAssertThrowsError(try run.receive([""], token: current, workspace: workspace, session: session))
        XCTAssertEqual(try run.receive(["Reviewed"], token: current, workspace: workspace, session: session), ["Reviewed"])
        XCTAssertNil(try run.receive(["Twice"], token: current, workspace: workspace, session: session))
        run.close()
        XCTAssertNil(run.begin(workspace: workspace, session: session))
    }
    func testCancelledGenerationStopsBeforeInputOrAvailabilityChecks() async throws {
        for input in ["", "Prepare a workshop"] {
            let worker = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await TaskBreakdownEngine.generate(input)
            }
            do { _ = try await worker.value; XCTFail("A cancelled request returned suggestions") }
            catch { XCTAssertTrue(error is CancellationError, "Cancellation must win over input or availability: \(error)") }
        }
    }
    func testActualOnDeviceEngineWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_TEST_ON_DEVICE_MODEL"] == "1" else { throw XCTSkip("Actual model probe is opt-in; ordinary checks never run inference.") }
        if let reason = TaskBreakdownEngine.unavailableReason {
            print("TASK_BREAKDOWN_MODEL_UNAVAILABLE " + reason)
            throw XCTSkip(reason)
        }
        for goal in ["Prepare a small picnic at a local park", "Review and submit a five-minute project presentation", "Preparar una presentación de cinco minutos"] {
            let start = ContinuousClock.now
            let result = try await TaskBreakdownEngine.generate(goal)
            let duration = start.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            let observation: [String: Any] = ["engine": "steps", "syntheticGoal": goal, "seconds": seconds, "titles": result]
            print("TASKFOLD_MODEL_OBSERVATION " + String(data: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), encoding: .utf8)!)
            XCTAssertTrue((3...8).contains(result.count))
            XCTAssertEqual(try TaskBreakdownRequest.titles(result), result)
        }
        print("TASK_BREAKDOWN_MODEL_ACCEPTED three synthetic goals; no task writes")
    }
}
