import XCTest
@testable import TaskfoldCore

final class WorkflowDestinationIndexTests: XCTestCase {
    // Frozen pre-optimization constructor. Compare the decision and every
    // produced row, rather than checking the new implementation against itself.
    private func legacyKeys(_ changes: [Mutation], _ snapshot: Snapshot, _ account: String) -> Set<String>? {
        guard WorkflowUndo.creationRun(changes) != nil, !account.isEmpty else { return nil }
        let existing = snapshot.tables.mapValues { Set($0.map(\.id)) }
        var keys = Set<String>(), namespaces = Set<String>()
        for change in changes {
            if change.table == "tasks", !namespaces.insert(change.recordID.lowercased()).inserted { return nil }
            guard change.fields["id"]?.text == change.recordID, !change.recordID.isEmpty,
                  change.fields["user_id"]?.text == account,
                  !(existing[change.table] ?? []).contains(change.recordID),
                  keys.insert(change.table + ":" + change.recordID).inserted else { return nil }
        }
        return keys
    }
    private func command(_ table: String, _ id: String, run: UUID) -> Mutation {
        Mutation(table: table, recordID: id, method: "POST", fields: ["id": .string(id), "user_id": .string("local"), "title": .string("é")], insertOnly: true, workflowRun: run)
    }
    func testDestinationIndexesMatchLegacyDecisionsAndProjectedRows() throws {
        let names = ["projects", "sections", "labels", "tasks", "view_orders"]
        var cases = 0
        for destination in names {
            for populated in names + ["task_activity", "task_node_activity", "_private_recovery", "future_table"] {
                for collision in [false, true] {
                    let run = UUID(), changes = [command(destination, "shared-id", run: run)]
                    let row = Record(["id": .string(collision ? "shared-id" : "unrelated"), "opaque": .object(["future": .string("e\u{301}")])])
                    let original = Snapshot(tables: [populated: [row, row]])
                    let expected = legacyKeys(changes, original, "local")
                    var actual = FreshWorkflowCreation(changes, snapshot: original, account: "local")
                    XCTAssertEqual(actual != nil, expected != nil, "\(destination) vs \(populated), collision \(collision)")
                    if actual != nil {
                        var projected = original, sequential = original
                        for change in changes {
                            XCTAssertNotNil(actual?.append(change, to: &projected))
                            sequential.apply(change)
                        }
                        XCTAssertEqual(projected, sequential)
                        XCTAssertNil(actual?.append(changes[0], to: &projected), "A consumed insertion cannot be replayed")
                    }
                    XCTAssertEqual(original.tables[populated], [row,row])
                    cases += 1
                }
            }
        }
        XCTAssertEqual(cases, 90)
    }
    func testMalformedAndAliasedRunsStillChooseOrdinaryReplay() {
        let run = UUID(), first = command("tasks", "ABC", run: run)
        var badOwner = first; badOwner.fields["user_id"] = .string("other")
        var badID = first; badID.fields["id"] = .string("different")
        var patch = first; patch.method = "PATCH"
        var noRun = first; noRun.workflowRun = nil
        var shared = first; shared.fields["team_id"] = .string("team")
        let cases: [[Mutation]] = [[],[badOwner],[badID],[patch],[noRun],[first,first],
            [first,command("tasks","abc",run:run)],
            [first,command("tasks","other",run:UUID())],
            [command("unknown","row",run:run)],
            [command("tasks","",run:run)], [shared]]
        for changes in cases {
            for owner in ["local", "", "other"] {
                let original = Snapshot(tables:["future_table":[Record(["id":.string("ABC")])]])
                XCTAssertEqual(FreshWorkflowCreation(changes,snapshot:original,account:owner) != nil,
                               legacyKeys(changes,original,owner) != nil)
            }
        }
    }
    func testLargeUnrelatedHistoryPreservesSameAdmissionWithoutIndexingIt() throws {
        let run = UUID(), changes = [command("projects","new-project",run:run)]
        let history = (0..<30000).map { Record(["id":.string("history-\($0)"),"opaque":.string("preserved")]) }
        let original = Snapshot(tables:["task_activity":history,"task_node_activity":history,"future_table":history])
        let clock = ContinuousClock(), legacyStart = clock.now
        var admitted = 0
        for _ in 0..<5 { if legacyKeys(changes,original,"local") != nil { admitted += 1 } }
        let legacyElapsed = legacyStart.duration(to: clock.now)
        let currentStart = clock.now
        for _ in 0..<5 {
            var plan = try XCTUnwrap(FreshWorkflowCreation(changes,snapshot:original,account:"local"))
            var output = original
            XCTAssertNotNil(plan.append(changes[0],to:&output))
            XCTAssertEqual(output.tables["projects"]?.first?.id,"new-project")
            XCTAssertEqual(output.tables["task_activity"],history)
            XCTAssertEqual(output.tables["task_node_activity"],history)
            XCTAssertEqual(output.tables["future_table"],history)
        }
        let elapsed = currentStart.duration(to: clock.now)
        XCTAssertEqual(admitted,5)
        print("Destination index diagnostic: 90,000 unrelated rows, 5 admissions; legacy admission \(legacyElapsed); current admission+append+full preservation assertions \(elapsed). No timing threshold.")
    }
}
