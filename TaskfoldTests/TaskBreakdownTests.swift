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
    func testReviewOrderKeepsEditsInclusionAndIdentityWithTheirStep() {
        var steps = ["Inspect", "Review", "Publish"].map { TaskBreakdownReview.Step(title: $0) }
        let ids = steps.map(\.id)
        steps[1].title = "Review the final layout"; steps[1].included = false
        XCTAssertEqual(TaskBreakdownReview.move(ids[2], by: -1, in: &steps), 1)
        XCTAssertEqual(TaskBreakdownReview.move(ids[2], by: -1, in: &steps), 0)
        XCTAssertEqual(steps.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(steps.map(\.title), ["Publish", "Inspect", "Review the final layout"])
        XCTAssertEqual(steps.filter(\.included).map(\.title), ["Publish", "Inspect"])
        XCTAssertEqual(TaskBreakdownReview.move(ids[2], by: 1, in: &steps), 1)
        XCTAssertEqual(steps.map(\.id), [ids[0], ids[2], ids[1]])
    }
    func testOldOrOutOfBoundsReviewControlsNeverMoveAnotherStep() {
        var steps = ["Inspect", "Publish"].map { TaskBreakdownReview.Step(title: $0) }
        let ids = steps.map(\.id)
        for (id, offset) in [(ids[0], -1), (ids[1], 1), (UUID(), 1), (ids[0], 0), (ids[0], Int.min), (ids[0], Int.max)] {
            XCTAssertNil(TaskBreakdownReview.move(id, by: offset, in: &steps))
            XCTAssertEqual(steps.map(\.id), ids)
        }
        let removed = steps.removeFirst(); let remaining = steps.map(\.id)
        XCTAssertNil(TaskBreakdownReview.move(removed.id, by: 1, in: &steps)); XCTAssertEqual(steps.map(\.id), remaining)
        steps = ["New result", "Other result"].map { TaskBreakdownReview.Step(title: $0) }
        let replacement = steps.map(\.id)
        XCTAssertNil(TaskBreakdownReview.move(ids[1], by: 1, in: &steps)); XCTAssertEqual(steps.map(\.id), replacement)
    }
    func testReviewedOrderAppendsLiteralStepsWithoutChangingExistingWork() throws {
        let original = source(), r = try request(original)
        var steps = ["Inspect", "Review", "Publish"].map { TaskBreakdownReview.Step(title: $0) }
        steps[1].included = false
        let publish = steps[2].id
        TaskBreakdownReview.move(publish, by: -1, in: &steps); TaskBreakdownReview.move(publish, by: -1, in: &steps)
        steps[0].title = "Publish #work tomorrow p1"
        let children = try r.applying(steps.filter(\.included).map(\.title), to: original, workspace: workspace, session: session)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(children.list[0], original["subtasks"].list[0]))
        XCTAssertEqual(children.list.dropFirst().map { $0.object["title"]!.text }, ["Publish #work tomorrow p1", "Inspect"])
        for child in children.list.dropFirst() { XCTAssertEqual(Set(child.object.keys), ["id", "title", "completed"]) }
        XCTAssertEqual(original.fields, r.source.fields)
        var changed = original; changed["priority"] = .number(1)
        XCTAssertThrowsError(try r.applying(steps.filter(\.included).map(\.title), to: changed, workspace: workspace, session: session))
    }
    func testActualOnDeviceEngineWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_TEST_ON_DEVICE_MODEL"] == "1" else { throw XCTSkip("Actual model probe is opt-in; ordinary checks never run inference.") }
        if let reason = TaskBreakdownEngine.unavailableReason {
            print("TASK_BREAKDOWN_MODEL_UNAVAILABLE " + reason)
            throw XCTSkip(reason)
        }
        var allAccepted = true
        for goal in ["Prepare a small picnic at a local park", "Review and submit a five-minute project presentation", "Preparar una presentación de cinco minutos"] {
            let start = ContinuousClock.now
            let result = try await TaskBreakdownEngine.generate(goal)
            let duration = start.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            let observation: [String: Any] = ["engine": "steps", "syntheticGoal": goal, "seconds": seconds, "titles": result]
            print("TASKFOLD_MODEL_OBSERVATION " + String(data: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), encoding: .utf8)!)
            let checked = try TaskBreakdownRequest.titles(result)
            if !(3...8).contains(result.count) || checked != result { allAccepted = false }
            XCTAssertTrue((3...8).contains(result.count))
            XCTAssertEqual(checked, result)
        }
        if allAccepted { print("TASK_BREAKDOWN_MODEL_ACCEPTED three synthetic goals; no task writes") }
    }
}
