import XCTest
@testable import TaskfoldCore

final class MoveAssignmentIntentTests: XCTestCase {
    private let owner = "a6110000-0000-4000-8000-000000000001"
    private let taskID = "a6110000-0000-4000-8000-000000000002"
    private let source = "a6110000-0000-4000-8000-000000000003"
    private let target = "a6110000-0000-4000-8000-000000000004"
    private let member = "a6110000-0000-4000-8000-000000000005"
    private let generation = "a6110000-0000-4000-8000-000000000006"
    private func original(inbox: Bool = false) throws -> Record {
        var task = Record.task(user: owner, project: inbox ? "" : source)
        task["id"] = .string(taskID); task["task_generation"] = .string(generation)
        task["title"] = .string("Keep all project work"); task["assigned_to"] = .string(owner)
        task["section_id"] = inbox ? .null : .string("a6110000-0000-4000-8000-000000000007")
        return task
    }
    private func mark(_ value: Mutation, _ current: Record?) -> Mutation { value }
    private func snapshot(_ row: Record) -> Snapshot { Snapshot(tables: ["tasks": [row]]) }
    private func row(_ snapshot: Snapshot) throws -> Record { try XCTUnwrap(snapshot.tables["tasks"]?.first) }
    private func execute(_ input: [Mutation], _ state: inout Snapshot, personal: Bool = true) throws -> [Mutation] {
        let normalized = try TaskAssignment.normalizedChanges(input, existing: { id in state.tables["tasks"]?.first { $0.id == id } }, markMove: personal ? mark : { value, _ in value })
        var committed: [Mutation] = []
        for change in normalized {
            let captured = TaskCompletionRevision.capturing(change, existing: state.tables["tasks"]?.first { $0.id == change.recordID })
            state.apply(captured); committed.append(captured)
        }
        return committed
    }
    private func replay(_ changes: [Mutation], from state: Snapshot, personal: Bool = true) throws -> [Mutation] {
        try TaskAssignment.replayingHistory(changes, existing: { table, id in state.tables[table]?.first { $0.id == id } }, markMove: personal ? mark : { value, _ in value })
    }
    private func move(_ original: Record, person: String? = nil) throws -> Mutation {
        var draft = try TaskAssignment.movingDraft(original, to: .string(target))
        if let person { draft["assigned_to"] = .string(person) }
        return try XCTUnwrap(PinnedNotes.edit(draft, existing: original, baseline: original))
    }
    func testSameAssigneeRemainsAuthoredWhenTheProjectChanges() throws {
        let task = try original(), change = try move(task, person: owner)
        XCTAssertEqual(change.fields["assigned_to"], .string(owner)); XCTAssertEqual(change.baseline?["assigned_to"], .string(owner))
        var state = snapshot(task); let commands = try execute([change], &state)
        XCTAssertEqual(commands.count, 2); XCTAssertEqual(try row(state)["assigned_to"], .string(owner))
        XCTAssertEqual(commands[0].fields["assigned_to"], .null); XCTAssertNil(commands[0].fields["subtasks"])
        XCTAssertEqual(commands[1].fields, ["assigned_to": .string(owner), "project_id": .string(target)])
        XCTAssertEqual(TaskAssignment.scopedProject(commands[1]), .string(target))
    }
    func testOrdinaryNoteEditDoesNotReauthorAnUntouchedAssignee() throws {
        let task = try original(); var edited = task; edited["description"] = .string("Only my note changed")
        let change = try XCTUnwrap(PinnedNotes.edit(edited, existing: task, baseline: task))
        XCTAssertNil(change.fields["assigned_to"]); XCTAssertNil(change.fields["project_id"])
        XCTAssertEqual(Set(change.fields.keys), ["description"])
    }
    func testNormalizedMoveAndAssignmentPairsAreIdempotent() throws {
        let task = try original(); let change = try move(task, person: member)
        let first = try TaskAssignment.normalizedChanges([change], existing: { _ in task }, markMove: mark)
        let again = try TaskAssignment.normalizedChanges(first, existing: { _ in task }, markMove: mark)
        XCTAssertEqual(first, again); XCTAssertEqual(again.count, 2)
    }
    func testUndoRedoKeepsRootAssigneeSectionAndFreshMoveIdentities() throws {
        for personal in [true, false] {
            for person in [owner, member] {
                let task = try original(); var state = snapshot(task)
                let originalCommands = try execute([move(task, person: person)], &state, personal: personal)
                var entry = EditHistory(changes: originalCommands, snapshot: snapshot(task))
                for _ in 0..<3 {
                    let beforeUndo = state, undo = try replay(entry.undo, from: state, personal: personal)
                    _ = try execute(undo, &state, personal: personal)
                    let undone = try row(state)
                    XCTAssertEqual(undone["project_id"], task["project_id"]); XCTAssertEqual(undone["assigned_to"], task["assigned_to"]); XCTAssertEqual(undone["section_id"], task["section_id"])
                    let redoEntry = EditHistory(changes: undo, snapshot: beforeUndo, id: entry.id).reversed
                    let beforeRedo = state, redo = try replay(redoEntry.redo, from: state, personal: personal)
                    _ = try execute(redo, &state, personal: personal)
                    XCTAssertEqual(try row(state)["project_id"], .string(target)); XCTAssertEqual(try row(state)["assigned_to"], .string(person)); XCTAssertEqual(try row(state)["section_id"], .null)
                    entry = EditHistory(changes: redo, snapshot: beforeRedo, id: entry.id)
                }
            }
        }
    }
    func testUndoCanRestoreTheOwnersAssignmentInInbox() throws {
        let task = try original(inbox: true); var state = snapshot(task)
        let changes = try execute([move(task)], &state)
        let history = EditHistory(changes: changes, snapshot: snapshot(task))
        _ = try execute(replay(history.undo, from: state), &state)
        XCTAssertEqual(try row(state)["project_id"], .null); XCTAssertEqual(try row(state)["assigned_to"], .string(owner))
    }
    func testInboxRefusesAnotherPersonsAssignmentBeforeReturningCommands() throws {
        let task = try original(); let change = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["project_id": .null, "assigned_to": .string(member)])
        XCTAssertThrowsError(try TaskAssignment.normalizedChanges([change], existing: { _ in task }))
        XCTAssertEqual(task["project_id"], .string(source)); XCTAssertEqual(task["assigned_to"], .string(owner))
    }
    func testScopedFollowUpCannotMoveOrAssignAMovedOrReplacedTask() throws {
        let task = try original(); var state = snapshot(task)
        let changes = try execute([move(task, person: owner)], &state), follow = try XCTUnwrap(changes.last)
        for field in ["project_id", "task_generation"] {
            var current = try row(state); current[field] = .string("a6110000-0000-4000-8000-000000000099")
            XCTAssertThrowsError(try TaskAssignment.normalizedChanges([follow], existing: { _ in current }, markMove: mark))
            var projected = snapshot(current); projected.apply(follow); XCTAssertEqual(projected.tables["tasks"], [current])
            let history = EditHistory(changes: [follow], snapshot: snapshot(current)); XCTAssertTrue(history.undo.isEmpty)
            projected.pending = [follow]
            XCTAssertNil(SyncConflict(mutation: follow, remote: current).resolving(projected, keepLocal: true))
            let discarded = try XCTUnwrap(SyncConflict(mutation: follow, remote: current).resolving(projected, keepLocal: false))
            XCTAssertTrue(discarded.pending.isEmpty); XCTAssertEqual(try row(discarded), current)
        }
    }
    func testStaleUndoRefusesTheEntireGroupBeforeAnyUnassignment() throws {
        let task = try original(); var state = snapshot(task)
        let commands = try execute([move(task, person: member)], &state)
        let history = EditHistory(changes: commands, snapshot: snapshot(task))
        for field in ["project_id", "task_generation"] {
            var current = try row(state); current[field] = .string("a6110000-0000-4000-8000-000000000099")
            let changed = snapshot(current)
            XCTAssertThrowsError(try replay(history.undo, from: changed))
            XCTAssertEqual(try row(changed)["assigned_to"], .string(member))
        }
    }
    func testDiscardedMoveAlsoDiscardsOnlyItsDependentAssignment() throws {
        let task = try original(); var state = snapshot(task)
        let commands = try execute([move(task, person: member)], &state)
        let later = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["description": .string("Keep later authored notes")], baseline: ["description": task["description"], "task_generation": task["task_generation"]])
        state.pending = commands + [later]; state.apply(later)
        let resolved = try XCTUnwrap(SyncConflict(mutation: commands[0], remote: task).resolving(state, keepLocal: false))
        XCTAssertEqual(resolved.pending.map(\.id), [later.id]); XCTAssertEqual(try row(resolved)["project_id"], task["project_id"])
        XCTAssertEqual(try row(resolved)["assigned_to"], task["assigned_to"]); XCTAssertEqual(try row(resolved)["description"], .string("Keep later authored notes"))
    }
    func testSelectionRetainsExplicitSameAssigneeButDoesNotInheritItForAPlainMove() throws {
        let task = try original(), workspace = WorkspaceBinding(account: owner, generation: UUID())
        let projects = [source, target].map { Record(["id": .string($0), "name": .string($0), "user_id": .string(owner)]) }
        for explicit in [true, false] {
            var fields: [String: JSON] = ["project_id": .string(target)]
            if explicit { fields["assigned_to"] = .string(owner) }
            let result = try TaskSelectionPlan.changes([.init(task: task, action: .patch(fields), workspace: workspace)], accessibleRoots: [task], projects: projects, workspace: workspace)
            XCTAssertEqual(result.first?.fields["assigned_to"], explicit ? .string(owner) : nil)
        }
    }
    func testScopeUUIDSpellingDoesNotChangeTheProjectedProject() throws {
        let task = try original(); var state = snapshot(task)
        let changes = try execute([move(task, person: member)], &state)
        var follow = try XCTUnwrap(changes.last)
        follow.fields["project_id"] = .string(target.uppercased())
        follow.baseline?["project_id"] = .string(target.uppercased())
        follow.baseline?["task_generation"] = .string(generation.uppercased())
        state.apply(follow)
        XCTAssertEqual(try row(state)["project_id"], .string(target))
        XCTAssertEqual(try row(state)["assigned_to"], .string(member))
    }
    func testCreateThenMoveUsesTheActualNewGenerationForTheAssignmentGuard() throws {
        var task = try original(); task.fields.removeValue(forKey: "task_generation")
        let creation = Mutation(table: "tasks", recordID: taskID, method: "POST", fields: task.fields)
        let change = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["project_id": .string(target), "assigned_to": .string(owner)])
        var state = Snapshot()
        let commands = try execute([creation, change], &state)
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands.last?.baseline?["task_generation"], .string(creation.id.uuidString.lowercased()))
        XCTAssertEqual(try row(state)["project_id"], .string(target)); XCTAssertEqual(try row(state)["assigned_to"], .string(owner))
    }

    func testPartialAssignmentsAndCompoundEditsKeepTheirOpeningProject() throws {
        let task = try original()
        var edited = task; edited["assigned_to"] = .string(member); edited["description"] = .string("Keep the note too")
        let change = try XCTUnwrap(PinnedNotes.edit(edited, existing: task, baseline: task))
        XCTAssertEqual(change.fields["project_id"], task["project_id"])
        XCTAssertEqual(change.baseline?["project_id"], task["project_id"])
        XCTAssertEqual(TaskAssignment.scopedProject(change), task["project_id"])
        var state = snapshot(task); _ = try execute([change], &state)
        XCTAssertEqual(try row(state)["assigned_to"], .string(member)); XCTAssertEqual(try row(state)["description"], .string("Keep the note too"))
        let partial = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["assigned_to": .string(member)])
        var another = snapshot(task); let committed = try execute([partial], &another)
        XCTAssertEqual(TaskAssignment.scopedProject(committed[0]), task["project_id"])
    }
    func testUndoDoesNotReplaceALaterAssignmentInTheSameProject() throws {
        let task = try original(); var state = snapshot(task)
        let commands = try execute([move(task, person: member)], &state)
        let history = EditHistory(changes: commands, snapshot: snapshot(task))
        var latest = try row(state); latest["assigned_to"] = .string("a6110000-0000-4000-8000-000000000099")
        XCTAssertThrowsError(try replay(history.undo, from: snapshot(latest)))
        XCTAssertEqual(latest["project_id"], .string(target))
    }
    func testExplicitReviewRetainsTheChosenAssigneeEvenWhenItMatchedTheBaseline() throws {
        let task = try original(); var remote = task; remote["assigned_to"] = .string(member)
        let change = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["project_id": task["project_id"], "assigned_to": .string(owner)], baseline: ["project_id": task["project_id"], "assigned_to": .string(owner), "task_generation": task["task_generation"]])
        var state = snapshot(remote); state.pending = [change]
        let review = SyncConflict(mutation: change, remote: remote)
        XCTAssertFalse(review.assignmentContextChanged)
        let kept = try XCTUnwrap(review.resolving(state, keepLocal: true))
        XCTAssertEqual(kept.pending[0].fields["assigned_to"], .string(owner))
        XCTAssertEqual(kept.pending[0].baseline?["assigned_to"], .string(member))
        XCTAssertEqual(try row(kept)["assigned_to"], .string(owner))
    }
    func testQueuedScopeAndExactMetadataSurvivePersistence() throws {
        let task = try original(); var state = snapshot(task)
        state.pending = try execute([move(task, person: member)], &state)
        let bytes = try TaskfoldJSONEncoder().encode(state)
        let cold = try TaskfoldJSONDecoder().decode(Snapshot.self, from: bytes)
        XCTAssertEqual(cold.pending, state.pending)
        XCTAssertEqual(TaskAssignment.scopedProject(cold.pending[1]), .string(target))
    }

}
