import XCTest
@testable import TaskfoldCore

final class TaskNodeActivityTests: XCTestCase {
    let owner="11111111-1111-4111-8111-111111111111",rootID="22222222-2222-4222-8222-222222222222",generation="33333333-3333-4333-8333-333333333333",project="44444444-4444-4444-8444-444444444444"
    let now=TaskPlanning.instant("2026-10-26T10:00:00Z")!
    func node(_ key:String,heading:Bool=false,done:Bool=false,children:[Record]=[]) -> Record {
        Record(["id":.string(key),"title":.string(key),"is_heading":.bool(heading),"completed":.bool(done),"subtasks":.array(children.map{.object($0.fields)})])
    }
    func root(_ children:[Record],heading:Bool=true) -> Record {
        var value=node(rootID,heading:heading,children:children);value["user_id"] = .string(owner);value["task_generation"] = .string(generation);value["project_id"] = .string(project);return value
    }
    func change(_ before:Record?,_ after:Record?,id:UUID=UUID()) -> Mutation { Mutation(id:id,table:"tasks",recordID:rootID,method:before==nil ? "POST":after==nil ? "DELETE":"PATCH",fields:after?.fields ?? [:]) }
    func rows(_ before:Record?,_ after:Record?,id:UUID=UUID(),sequence:Int64=0) -> [Record] {TaskNodeActivity.localRows(change(before,after,id:id),before:before,after:after,account:owner,recordedAt:now,afterSequence:sequence)}
    func events(_ before:Record?,_ after:Record?) -> [TaskNodeActivity] { rows(before,after).compactMap(TaskNodeActivity.init) }
    func testActualSQLFieldActivityRowsUseTheStrictReaderAndNoCompletionCredit() throws {
        struct Fixture: Decodable { let epoch: [Record]; let events: [Record] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"child-field-activity-v2",withExtension:"json",subdirectory:"Fixtures"))
        let fixture=try TaskfoldJSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
        XCTAssertEqual(fixture.events.count,10)
        let parsed=fixture.events.compactMap(TaskNodeActivity.init)
        XCTAssertEqual(parsed.count,10);XCTAssertEqual(parsed.filter{$0.kinds.contains(.edited)}.count,6)
        let history=ChildWorkHistory(rows:fixture.events,epoch:fixture.epoch)
        XCTAssertNotNil(history.recordedFrom);XCTAssertNotNil(history.fieldRecordedFrom)
        let reading=ChildWorkReading(history,now:Date.distantFuture)
        XCTAssertFalse(reading.incomplete);XCTAssertEqual(reading.malformed,0);XCTAssertTrue(reading.credits().isEmpty)
        XCTAssertTrue(parsed.filter{$0.kinds.contains(.edited)}.allSatisfy{WorkActivity.child($0).changedFieldsText != nil})
        let encoded=String(decoding:try TaskfoldJSONEncoder().encode(fixture.events),as:UTF8.self)
        XCTAssertFalse(encoded.contains("Private title and notes must stay out of the ledger"))
    }
    func testFieldCoverageAcceptsOnlyKnownValidEpochShapes() {
        let old=Record(["id":.string("current"),"recorded_from":.string("2026-10-01T00:00:00Z")])
        XCTAssertTrue(TaskNodeActivity.validEpoch([old]))
        var modern=old;modern["field_recorded_from"] = .string("2026-10-31T10:00:00Z")
        XCTAssertTrue(TaskNodeActivity.validEpoch([modern]))
        modern["field_recorded_from"] = .string("not a timestamp");XCTAssertFalse(TaskNodeActivity.validEpoch([modern]))
        modern=old;modern["unexpected"] = .string("not authority");XCTAssertFalse(TaskNodeActivity.validEpoch([modern]))
    }
    func testActualPostgresRowsDecodeWithSameWorkAndIdentityContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-node-activity", withExtension: "json", subdirectory: "Fixtures"))
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(records.count, 30)
        let events = try records.map { try XCTUnwrap(TaskNodeActivity(row: $0), $0.id) }
        XCTAssertTrue(events.contains { $0.isGap })
        XCTAssertTrue(events.contains { $0.kinds == [.completed] && $0.workAfter })
        XCTAssertTrue(events.contains { $0.kinds == [.completed] && !$0.workAfter })
        XCTAssertEqual(Set(events.map(\.sequence)).count, events.count)
    }
    @MainActor func historyBackend() throws -> (Backend, Session) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"test\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + owner + "\"}}").utf8))
        return (Backend(configuration: ["URL": "https://native-auth.test", "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: session, persistSession: { _ in }), session)
    }
    @MainActor func testOptionalNetworkHistoryRequiresCompleteStableEpochAndPreservesEmpty() async throws {
        let (backend, _) = try historyBackend()
        let epoch = try JSONEncoder().encode([Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])])
        defer { AuthTransportTests.Stub.handler = nil }
        var calls = 0
        AuthTransportTests.Stub.handler = { request in
            calls += 1
            return (200, request.url!.path.hasSuffix("epoch") ? epoch : Data("[]".utf8))
        }
        let empty = await backend.nodeActivityHistory()
        XCTAssertEqual(empty?.rows, []); XCTAssertEqual(calls, 3)
        for status in [403, 404, 500] {
            for failedPath in [TaskNodeActivity.epochTable, TaskNodeActivity.table] {
                AuthTransportTests.Stub.handler = { request in
                    if request.url!.lastPathComponent == failedPath { return (status, Data("{\"message\":\"Unavailable\"}".utf8)) }
                    return (200, epoch)
                }
                let unavailable = await backend.nodeActivityHistory(); XCTAssertNil(unavailable)
            }
        }
        AuthTransportTests.Stub.handler = { _ in (200, Data("[]".utf8)) }
        let missingEpoch = await backend.nodeActivityHistory(); XCTAssertNil(missingEpoch)
        var epochs = 0
        AuthTransportTests.Stub.handler = { request in
            if request.url!.path.hasSuffix("epoch") {
                epochs += 1
                return (200, epochs == 1 ? epoch : Data("[{\"id\":\"current\",\"recorded_from\":\"2026-10-27T10:00:00Z\"}]".utf8))
            }
            return (200, Data("[]".utf8))
        }
        let reset = await backend.nodeActivityHistory(); XCTAssertNil(reset)
    }
    @MainActor func testNetworkHistoryDiscardsSameAccountSessionCycle() async throws {
        let (backend, session) = try historyBackend()
        let epoch = try JSONEncoder().encode([Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])])
        let started = expectation(description: "Child history read started"), gate = DispatchSemaphore(value: 0)
        defer { AuthTransportTests.Stub.handler = nil; gate.signal() }
        AuthTransportTests.Stub.handler = { request in
            if request.url!.path.hasSuffix("epoch") { return (200, epoch) }
            started.fulfill(); _ = gate.wait(timeout: .now() + 10)
            return (200, Data("[]".utf8))
        }
        let read = Task { await backend.nodeActivityHistory(expectedAccount: owner) }
        await fulfillment(of: [started], timeout: 5)
        var other = session; other.user.id = "55555555-5555-4555-8555-555555555555"
        try await backend.accept(other); try await backend.accept(session); gate.signal()
        let stale = await read.value; XCTAssertNil(stale)
    }
    @MainActor func testChildHistoryAndEpochRejectAllClientWritesBeforeNetwork() async throws {
        let (backend, _) = try historyBackend()
        AuthTransportTests.Stub.handler = { _ in XCTFail("Read-only history sent a request"); return (200, Data("[]".utf8)) }
        defer { AuthTransportTests.Stub.handler = nil }
        for table in [TaskNodeActivity.table, TaskNodeActivity.epochTable] {
            for method in ["POST", "PATCH", "DELETE"] {
                do { _ = try await backend.send(Mutation(table: table, recordID: UUID().uuidString, method: method, fields: [:])); XCTFail("History write accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("read-only")) }
            }
        }
    }

    func testRetainedTeamSQLHistoryDecodesAndArchivesWithoutActorOrOwnerRewriting() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-node-custody", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        let events = try rows.map { try XCTUnwrap(TaskNodeActivity(row: $0), $0.id) }
        XCTAssertTrue(events.contains { $0.actor == nil }); XCTAssertTrue(events.contains { $0.actor != nil && $0.actor != $0.owner })
        let account = try XCTUnwrap(events.compactMap(\.actor).first)
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: [TaskNodeActivity.table: rows]), account: account).data())
        XCTAssertEqual(file.tables[TaskNodeActivity.table], rows)
        XCTAssertTrue(try file.plan(current: Snapshot(), account: UUID().uuidString.lowercased()).changes.isEmpty)
    }
    func testReviewedHistoricalCustodyRowsRemainValidWithoutLiveTasksOrAuthors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reviewed-history-custody", withExtension: "json", subdirectory: "Fixtures"))
        let wire = try JSONDecoder().decode([String: [Record]].self, from: Data(contentsOf: url))
        let roots = try XCTUnwrap(wire["root"]), children = try XCTUnwrap(wire["child"])
        XCTAssertFalse(roots.isEmpty); XCTAssertFalse(children.isEmpty)
        let rootEvents = try roots.map { try XCTUnwrap(TaskActivity(row: $0), $0.id) }
        let childEvents = try children.map { try XCTUnwrap(TaskNodeActivity(row: $0), $0.id) }
        XCTAssertTrue(rootEvents.allSatisfy { $0.actor == nil })
        XCTAssertTrue(childEvents.allSatisfy { $0.actor == nil })
        XCTAssertTrue(childEvents.contains { $0.kinds == [.completed] && $0.workAfter })
        XCTAssertTrue(childEvents.contains { $0.kinds == [.deleted] })
        // Reading the archive never supplies current task authority.
        let member = UUID().uuidString.lowercased()
        for event in childEvents { XCTAssertNil(event.currentTask(tasks: [], projects: [], account: member)) }
        for event in rootEvents {
            let project = event.after["project_id"]?.text ?? event.before["project_id"]?.text ?? ""
            XCTAssertNil(ProjectActivityContext(event: event, project: project, tasks: [], projects: [], members: [], account: member).task)
        }
        let snapshot = Snapshot(tables: [TaskActivity.table: roots, TaskNodeActivity.table: children])
        let archive = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: member).data())
        XCTAssertEqual(archive.tables[TaskActivity.table], roots)
        XCTAssertEqual(archive.tables[TaskNodeActivity.table], children)
        XCTAssertTrue(try archive.plan(current: Snapshot(), account: UUID().uuidString.lowercased()).changes.isEmpty)
    }

}
