import XCTest
@testable import TaskfoldCore

final class TaskAssignmentProvenanceTests: XCTestCase {
    typealias Provenance = TaskAssignmentProvenance
    let owner = "f01dcafe-8200-4000-8000-000000000001"
    let member = "f01dcafe-8200-4000-8000-000000000002"
    let taskID = "f01dcafe-8200-4000-8000-000000000010"
    let generation = "f01dcafe-8200-4000-8000-000000000020"
    let event = "f01dcafe-8200-4000-8000-000000000030"
    let stamp = "2026-10-21T12:00:00Z"
    func task() -> Record {
        Record(["id":.string(taskID),"user_id":.string(owner),"title":.string("Handoff"),"assigned_to":.string(member),"task_generation":.string(generation)])
    }
    func row(node: String = "", path: [String] = []) -> Record {
        Record(["id":.string("f01dcafe-8200-4000-8000-000000000040"),"task_id":.string(taskID),"task_generation":.string(generation),"node_key":.string(node),"node_path":.array(path.map(JSON.string)),"assignee_id":.string(member),"actor_id":.string(owner),"event_id":.string(event),"assigned_at":.string(stamp),"origin":.string("recorded"),"active":.bool(true)])
    }
    var known: Provenance.Resolution { .known(actor:owner,event:event,recordedAt:TaskPlanning.instant(stamp)!) }
    func testConfirmedActorIsIndependentOfTaskAuthorAndAssignee() {
        var task = task(); task["user_id"] = .string(member)
        var row = row(); row["task_id"] = .string(taskID.uppercased()); row["actor_id"] = .string(owner.uppercased())
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),known)
        task["title"] = .string("Renamed"); task["completed"] = .bool(true)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),known)
        row["actor_id"] = .string(member)
        XCTAssertNotEqual(Provenance.Catalog([row]),Provenance.Catalog([self.row()]),"Metadata participates in future query cache identity")
    }
    func testUnknownHistoryNeverUsesAuthorAssigneeOrUntrustedActor() {
        let task = task()
        XCTAssertEqual(Provenance.Catalog(nil).resolution(root:task),.unknown(.unavailable))
        XCTAssertEqual(Provenance.Catalog([]).resolution(root:task),.unknown(.legacy))
        for reason in [Provenance.Unknown.legacy,.system,.recurrence,.unsupported] {
            var row = row(); row["origin"] = .string(reason.rawValue)
            XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(reason))
        }
        var row = row(); row["actor_id"] = .null
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.deletedActor))
        row["actor_id"] = .string("Task owner")
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.unsupported))
    }
    func testUnassignedIsDistinctFromMissingOrUnknownHistory() {
        for recipient in [JSON.null,.string("")] {
            var task = task(); task["assigned_to"] = recipient
            XCTAssertEqual(Provenance.Catalog(nil).resolution(root:task),.unassigned)
            XCTAssertEqual(Provenance.Catalog([row()]).resolution(root:task),.unassigned)
        }
        var task = task(); task["assigned_to"] = .number(3)
        XCTAssertEqual(Provenance.Catalog([row()]).resolution(root:task),.unknown(.unsupported))
    }
    func testIncarnationLegacyAndDuplicateRowsFailClosed() {
        var task = task(); task["task_generation"] = .string(UUID().uuidString)
        XCTAssertEqual(Provenance.Catalog([row()]).resolution(root:task),.unknown(.legacy))
        task["task_generation"] = .null
        var row = row(); row["task_generation"] = .string(Provenance.legacyGeneration)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),known,"A genuine new assignment on a pre-migration task can be recorded")
        task["task_generation"] = .string(Provenance.legacyGeneration)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.unsupported))
        XCTAssertEqual(Provenance.Catalog([self.row(),self.row()]).resolution(root:self.task()),.unknown(.ambiguous))
    }
    func testOfflineRecipientChangeAndMalformedCurrentRowsCannotReuseActor() throws {
        let row = row(); var task = task(); task["assigned_to"] = .string(owner)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.stale))
        for (field,value) in [("active",JSON.bool(false)),("node_path",.array([.string("moved")])),("event_id",.string("bad")),("assigned_at",.string("bad")),("origin",.string("future")),("node_path",.array([.number(2)]))] {
            var bad = row; bad[field] = value
            let result = Provenance.Catalog([bad]).resolution(root:self.task())
            if case .unknown = result {} else { XCTFail("Malformed \(field) became confirmed") }
        }
        let snapshot = Snapshot(tables:["tasks":[task],Provenance.table:[row]])
        let saved = try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(Provenance.Catalog(saved.tables[Provenance.table]).resolution(root:saved.tables["tasks"]![0]),.unknown(.stale))
    }
    func testNestedPathsAreCaseSensitiveAndOwnAssignmentDoesNotInherit() throws {
        var task = task()
        task["subtasks"] = .array([.object(["id":.string("A"),"title":.string("Upper"),"assigned_to":.string(member)]),.object(["id":.string("a"),"title":.string("Lower")])])
        let index = try TaskHierarchyIndex(roots:[task],projects:[],workspace:WorkspaceBinding(account:owner,generation:UUID()))
        let upper = try XCTUnwrap(index.items.first(where:{$0.path == ["A"]}))
        let lower = try XCTUnwrap(index.items.first(where:{$0.path == ["a"]}))
        let catalog = Provenance.Catalog([row(node:"A",path:["A"])])
        XCTAssertEqual(catalog.resolution(item:upper),known)
        XCTAssertEqual(catalog.resolution(item:lower),.unassigned)
        var moved = row(node:"A",path:["branch","A"])
        XCTAssertEqual(Provenance.Catalog([moved]).resolution(item:upper),.unknown(.stale))
        moved["node_key"] = .string("a")
        XCTAssertEqual(Provenance.Catalog([moved]).resolution(item:upper),.unknown(.legacy))
    }
    @MainActor func testGenericWritesCannotForgeReadOnlyHistoryAndPortableFilesExcludeIt() async throws {
        let row = row(); let original = Snapshot(tables:["tasks":[task()],Provenance.table:[row]])
        let backend = Backend(configuration:["URL":"https://assignment.test","Key":"public"],session:nil,persistSession:{ _ in })
        for method in ["POST","PATCH","DELETE"] {
            let change = Mutation(table:Provenance.table,recordID:row.id,method:method,fields:["actor_id":.string(member)])
            var snapshot = original; snapshot.apply(change)
            XCTAssertEqual(snapshot,original)
            do { _ = try await backend.send(change); XCTFail("Read-only mutation was sent") }
            catch { XCTAssertEqual(error.localizedDescription,"Activity history is read-only.") }
        }
        let backup = WorkspaceBackup.make(original,account:owner)
        XCTAssertNil(backup.tables[Provenance.table])
        let decoded = try WorkspaceBackup.read(backup.data())
        XCTAssertNil(decoded.tables[Provenance.table]); XCTAssertEqual(decoded.tables["tasks"],original.tables["tasks"])
        var forged = backup; forged.tables[Provenance.table] = [row]
        XCTAssertThrowsError(try WorkspaceBackup.read(forged.data()),"A portable file cannot certify an actor")
    }
}
