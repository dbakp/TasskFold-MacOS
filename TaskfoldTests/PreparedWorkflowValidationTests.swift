import Foundation
import XCTest
@testable import TaskfoldCore

final class PreparedWorkflowValidationTests: XCTestCase {
    private let account = "local"
    private func changes(task: Record? = nil) -> [Mutation] {
        let run = UUID()
        var row = task ?? Record.task(user: account)
        row["user_id"] = .string(account)
        return [Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields, insertOnly: true, workflowRun: run)]
    }
    private func prepare(_ changes: [Mutation], snapshot: Snapshot = Snapshot(), source: UUID) throws -> LocalActivityCreation.Preparation? {
        try LocalActivityCreation.Preparation(changes: changes, snapshot: snapshot, source: source, account: account, labels: [], cache: nil)
    }
    private func validation(_ changes: [Mutation], snapshot: Snapshot = Snapshot(), source: UUID) throws -> LocalActivityCreation.Preparation.ValidatedCreation? {
        guard let preparation = try prepare(changes, snapshot: snapshot, source: source),
              let admitted = preparation.admit(changes, source: source, account: account, cache: nil) else { return nil }
        return admitted.validatedCreation(matching: admitted.changes, source: source, account: account)
    }
    func testWorkerDecisionMatchesSequentialTaskChecksAcrossRootAndChecklistKinds() throws {
        let flags: [JSON?] = [nil, .null, .bool(false), .bool(true), .string("heading"), .number(1)]
        let completions: [JSON] = [.bool(false), .bool(true), .null]
        let stamps: [JSON] = [.null, .string("2026-10-28T08:00:00Z")]
        let children: [JSON] = [
            .array([]), .null, .object(["future": .bool(true)]), .string("legacy checklist"),
            .array([.string("legacy step")]),
            .array([.object(["id": .string("child"), "is_heading": .bool(true), "completed": .bool(false), "completed_at": .null])]),
            .array([.object(["id": .string("child"), "is_heading": .bool(true), "completed": .bool(true)])]),
            .array([.object(["is_heading": .bool(true), "completed": .bool(false)])]),
            .array([.object(["id": .string("child"), "is_heading": .string("future")])])
        ]
        var compared = 0
        for flag in flags { for completed in completions { for stamp in stamps { for child in children {
            var row = Record.task(user: account)
            row.fields["is_heading"] = flag; row["completed"] = completed; row["completed_at"] = stamp; row["subtasks"] = child
            let input = changes(task: row), source = UUID()
            let normalized = TaskCompletionRevision.capturing(input[0], existing: nil)
            let proof = try validation(input, source: source)
            for enabled in [false, true] {
                let ordinary = TaskGeneration.permitsLocalAction(normalized, existing: nil)
                    && (enabled || !TaskKind.requiresAuthoring(normalized, existing: nil))
                    && TaskKind.permits(normalized, existing: nil)
                XCTAssertEqual(proof?.permitsAuthoring(enabled: enabled) ?? false, ordinary,
                    "flag=\(String(describing: flag)), completed=\(completed), stamp=\(stamp), child=\(child), enabled=\(enabled)")
                compared += 1
            }
        } } } }
        XCTAssertEqual(compared, 648)
    }
    func testProofRequiresExactNormalizedBufferRevisionOwnerAndAdmittedContext() throws {
        let source = UUID(), input = changes(), plan = try XCTUnwrap(prepare(input, source: source))
        let admitted = try XCTUnwrap(plan.admit(input, source: source, account: account, cache: nil))
        XCTAssertNotNil(admitted.validatedCreation(matching: admitted.changes, source: source, account: account))
        XCTAssertNil(admitted.validatedCreation(matching: admitted.changes, source: UUID(), account: account))
        XCTAssertNil(admitted.validatedCreation(matching: admitted.changes, source: source, account: "other"))
        let copy = admitted.changes.map { $0 }
        XCTAssertEqual(copy, admitted.changes)
        XCTAssertNil(admitted.validatedCreation(matching: copy, source: source, account: account))
        var edited = admitted.changes; edited[0].fields["description"] = .string("changed")
        XCTAssertNil(admitted.validatedCreation(matching: edited, source: source, account: account))
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(secondsFromGMT: calendar.timeZone.secondsFromGMT() == 0 ? 3600 : 0)!
        XCTAssertNil(plan.admit(input, source: source, account: account, cache: nil, calendar: calendar))
        XCTAssertNil(plan.admit(input, source: UUID(), account: account, cache: nil))
        XCTAssertNil(plan.admit(input, source: source, account: "other", cache: nil))
    }
    func testRawUnicodeAndSignedZeroEditsCannotReuseValidatedInput() throws {
        var row = Record.task(user: account); row["description"] = .string("é"); row["future"] = .number(0)
        let input = changes(task: row), source = UUID(), plan = try XCTUnwrap(prepare(input, source: source))
        for field in ["description", "future"] {
            var edited = input; edited[0].fields[field] = field == "description" ? .string("e\u{301}") : .number(-0.0)
            XCTAssertEqual(edited, input)
            XCTAssertNil(plan.admit(edited, source: source, account: account, cache: nil))
        }
    }
    func testCapabilityIsCheckedAtUseAndNeverBakedIntoSuccessfulValidation() throws {
        var row = Record.task(user: account); row["is_heading"] = .bool(true)
        let source = UUID(), proof = try XCTUnwrap(validation(changes(task: row), source: source))
        XCTAssertTrue(proof.permitsAuthoring(enabled: true))
        XCTAssertFalse(proof.permitsAuthoring(enabled: false))
        XCTAssertTrue(proof.permitsAuthoring(enabled: true))
        let ordinary = try XCTUnwrap(validation(changes(), source: source))
        XCTAssertTrue(ordinary.permitsAuthoring(enabled: false))
    }
    func testReusedFreshPlanStillContainsEveryIdentityForLateProjectionFallback() throws {
        let run = UUID(), source = UUID()
        let project = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(account), "name": .string("Synthetic")])
        var input = changes(); input[0].workflowRun = run; input[0].fields["project_id"] = .string(project.id)
        input.insert(Mutation(table: "projects", recordID: project.id, method: "POST", fields: project.fields, insertOnly: true, workflowRun: run), at: 0)
        let plan = try XCTUnwrap(prepare(input, source: source))
        let admitted = try XCTUnwrap(plan.admit(input, source: source, account: account, cache: nil))
        let proof = try XCTUnwrap(admitted.validatedCreation(matching: admitted.changes, source: source, account: account))
        var fresh = proof.creation, actual = Snapshot(), ordinary = Snapshot()
        var legacy = try XCTUnwrap(FreshWorkflowCreation(admitted.changes, snapshot: ordinary, account: account))
        for change in admitted.changes {
            XCTAssertNotNil(fresh.append(change, to: &actual))
            XCTAssertNotNil(legacy.append(change, to: &ordinary))
        }
        XCTAssertEqual(actual, ordinary)
        XCTAssertNil(fresh.append(admitted.changes[0], to: &actual))
        let projectOnly = [input[0]]
        XCTAssertNotNil(try validation(projectOnly, source: source))
    }
    func testCollisionsUnsupportedCommandsAndEncodingOrUndoFailureCannotProduceProof() throws {
        let source = UUID(), input = changes()
        XCTAssertNil(try validation(input, snapshot: Snapshot(tables: ["tasks": [Record(input[0].fields)]]), source: source))
        var edited = input; edited[0].method = "PATCH"
        XCTAssertNil(try validation(edited, source: source))
        edited = input; edited[0].insertOnly = nil
        XCTAssertNil(try validation(edited, source: source))
        edited = input; edited[0].table = "future_table"
        XCTAssertNil(try validation(edited, source: source))
        edited = input; edited[0].baseline = ["title": .string("prior")]
        XCTAssertNil(try validation(edited, source: source))
        edited = input; edited[0].fields["future"] = .number(.nan)
        XCTAssertNil(try validation(edited, source: source))
        var cancelled = false
        XCTAssertThrowsError(try LocalActivityCreation.Preparation(changes: input, snapshot: Snapshot(), source: source, account: account, labels: [], cache: nil, checkCancellation: {
            cancelled = true; throw CancellationError()
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(cancelled)
    }
}
