import XCTest
@testable import TaskfoldCore

final class WorkflowHistoryGuardTests: XCTestCase {
    private let run = UUID(uuidString:"11111111-1111-4111-8111-111111111111")!
    private func change(_ id: String, table: String = "tasks", method: String = "POST", run: UUID? = nil) -> Mutation {
        Mutation(table:table,recordID:id,method:method,fields:["id":.string(id)],workflowRun:run ?? self.run)
    }
    private func legacy(_ changes: [Mutation], _ source: Snapshot, _ undo: [Mutation]?) -> Bool {
        let creation = changes.first?.workflowRun != nil && changes.allSatisfy { $0.method == "POST" && $0.workflowRun == changes.first?.workflowRun }
        guard creation else { return false }
        let ids = source.tables.mapValues { Set($0.map(\.id)) }
        return changes.contains { !(ids[$0.table] ?? []).contains($0.recordID) } && undo?.isEmpty != false
    }
    func testNonemptyUndoDoesNotReadAnyBaselineTables() {
        let changes = [change("fresh")]; var reads = 0
        func baseline() -> Snapshot { reads += 1; return Snapshot() }
        XCTAssertFalse(WorkflowUndo.missingCreationHistory(changes,snapshot:baseline(),undo:[change("inverse")]))
        XCTAssertEqual(reads,0,"An already retained inverse must not scan existing tasks/history")
    }
    func testRefusalMatchesLegacyAcrossIdentitiesAndWorkflowShapes() {
        let identities = ["same","SAME","café","cafe\u{301}","", "new"]
        let tables = ["tasks","projects","future-table","café","cafe\u{301}"]
        let undoChoices: [[Mutation]?] = [nil,[],[change("inverse")]]
        var cases = 0
        for table in tables { for existingID in identities { for id in identities {
            var source = Snapshot(); source.tables[table] = [Record(["id":.string(existingID)])]
            let row = change(id,table:table)
            var untagged = row; untagged.workflowRun = nil
            let shapes = [[row],[row,change("second",table:table)],[row,change("second",method:"PATCH")],[untagged],[],[row,change("other",run:UUID())]]
            for rows in shapes { for undo in undoChoices {
                XCTAssertEqual(WorkflowUndo.missingCreationHistory(rows,snapshot:source,undo:undo),legacy(rows,source,undo))
                cases += 1
            } }
        } } }
        XCTAssertEqual(cases,3240)
    }
    func testMissingInverseStillRejectsNewRowsAndAcceptsOnlyExistingRows() {
        var source = Snapshot(); source.tables["tasks"] = [Record(["id":.string("old")])]
        XCTAssertFalse(WorkflowUndo.missingCreationHistory([change("old")],snapshot:source,undo:nil))
        XCTAssertTrue(WorkflowUndo.missingCreationHistory([change("old"),change("new")],snapshot:source,undo:[]))
        XCTAssertTrue(WorkflowUndo.missingCreationHistory([change("old",table:"projects")],snapshot:source,undo:nil))
        XCTAssertTrue(WorkflowUndo.missingCreationHistory([change("OLD")],snapshot:source,undo:nil))
    }
    func testRetainedInverseDoesNotHideNormalUndoConstructionFailure() throws {
        let item = change("fresh"), source = Snapshot()
        let invalid = EditHistory(changes:[item],snapshot:source)
        XCTAssertTrue(invalid.undo.isEmpty)
        XCTAssertTrue(WorkflowUndo.missingCreationHistory([item],snapshot:source,undo:invalid.undo))
        let definition = try WorkflowTemplate(document:.object(["version":.number(1),"kind":.string("project"),"projects":.array([.object(["id":.string("root"),"name":.string("Project")])]),"sections":.array([]),"tasks":.array([])]))
        let changes = try definition.instantiate(account:"local",name:"Project")
        let history = EditHistory(changes:changes,snapshot:source)
        XCTAssertFalse(history.undo.isEmpty)
        XCTAssertFalse(WorkflowUndo.missingCreationHistory(changes,snapshot:source,undo:history.undo))
    }
    func testGuardIgnoresUnrelatedLargeHistoryWithoutChangingItsDecision() throws {
        var source = Snapshot()
        for table in [TaskActivity.table,TaskNodeActivity.table,"future-history"] {
            source.tables[table] = (0..<30000).map { Record(["id":.string("\(table)-\($0)"),"text":.string("Preserve cafe\u{301}")]) }
        }
        let before = source, changes = [change("fresh",table:"projects")], undo = [change("inverse")]
        let clock = ContinuousClock(); let oldStart = clock.now
        for _ in 0..<5 { XCTAssertFalse(legacy(changes,source,undo)) }
        let oldTime = oldStart.duration(to:clock.now), start = clock.now
        for _ in 0..<5 { XCTAssertFalse(WorkflowUndo.missingCreationHistory(changes,snapshot:source,undo:undo)) }
        let current = start.duration(to:clock.now)
        XCTAssertEqual(source,before); XCTAssertTrue(WorkflowUndo.missingCreationHistory(changes,snapshot:source,undo:[]))
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds)+Double(d.components.attoseconds)/1e18 }
        let data = try JSONSerialization.data(withJSONObject:["rows":90000,"repetitions":5,"legacySeconds":seconds(oldTime),"currentSeconds":seconds(current)],options:.sortedKeys)
        print("WORKFLOW_HISTORY_GUARD_METRICS " + String(decoding:data,as:UTF8.self))
    }
}
