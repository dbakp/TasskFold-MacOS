import XCTest
import CryptoKit
@testable import TaskfoldCore

final class BackupTests: XCTestCase {
    func testSeparateQueryGroupedOrdersRestoreInboxAndProjectIdentity() throws {
        var snapshot = fixture()
        let rule = FilterRule.sections([.predicate("all", ""), .predicate("project", projectID)])
        snapshot.tables["saved_views"]![0]["query_ast"] = rule.document
        let viewID = snapshot.tables["saved_views"]![0].id
        let taskID = snapshot.tables["tasks"]![0].id
        let keys = rule.querySectionKeys
        snapshot.tables["view_orders"] = [
            Record(["id": .string("scope:view:" + viewID + ":group:" + keys[0] + ":project:none"), "user_id": .string(owner), "ids": .array([])]),
            Record(["id": .string("scope:view:" + viewID + ":group:" + keys[1] + ":project:" + projectID), "user_id": .string(owner), "ids": .array([.string(taskID)])])]
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data())
        let plan = try file.plan(current: Snapshot(), account: other)
        let view = Record(try XCTUnwrap(plan.changes.first { $0.table == "saved_views" }).fields)
        let restored = try FilterRule(document: view["query_ast"])
        let orders = plan.changes.filter { $0.table == "view_orders" }
        XCTAssertEqual(orders.map(\.recordID), [
            "scope:view:" + view.id + ":group:" + restored.querySectionKeys[0] + ":project:none",
            "scope:view:" + view.id + ":group:" + restored.querySectionKeys[1] + ":project:" + plan.mappedIDs["projects"]![projectID]!])
    }
    func testSeparateQueryRestoreRemapsReferencesAndRetainsEachManualOrder() throws {
        var snapshot = fixture()
        let rule = FilterRule.sections([.predicate("project", projectID), .predicate("assignee", owner), .predicate("assignee", "others"), .predicate("project", projectID)])
        snapshot.tables["saved_views"]![0]["query_ast"] = rule.document
        let viewID = snapshot.tables["saved_views"]![0].id
        let taskID = snapshot.tables["tasks"]![0].id
        snapshot.tables["view_orders"] = rule.querySectionKeys.map { Record(["id": .string("scope:view:" + viewID + ":group:" + $0 + ":all"), "user_id": .string(owner), "ids": .array([.string(taskID)])]) }
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data())
        let plan = try file.plan(current: Snapshot(), account: other)
        let view = Record(try XCTUnwrap(plan.changes.first { $0.table == "saved_views" }).fields)
        let project = try XCTUnwrap(plan.mappedIDs["projects"]?[projectID])
        let restored = try FilterRule(document: view["query_ast"])
        XCTAssertEqual(restored, .sections([.predicate("project", project), .predicate("assignee", "me"), .predicate("assignee", "others"), .predicate("project", project)]))
        let orders = plan.changes.filter { $0.table == "view_orders" }
        XCTAssertEqual(orders.map(\.recordID), restored.querySectionKeys.map { "scope:view:" + view.id + ":group:" + $0 + ":all" })
        XCTAssertTrue(orders.allSatisfy { $0.fields["ids"] == .array([.string(plan.mappedIDs["tasks"]![taskID]!)]) })
        XCTAssertEqual(Set(orders.map(\.recordID)).count, 4)
    }

    func testAssignmentStateFiltersKeepDestinationViewerSemanticsOnRestore() throws {
        var snapshot = fixture()
        let rule = FilterRule.and([.predicate("assigned", ""), .predicate("assignee", "others"), .predicate("assignee", owner)])
        snapshot.tables["saved_views"]![0]["query_ast"] = rule.document
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data())
        let plan = try file.plan(current: Snapshot(), account: other)
        let view = Record(try XCTUnwrap(plan.changes.first { $0.table == "saved_views" }).fields)
        XCTAssertEqual(try FilterRule(document: view["query_ast"]), .and([.predicate("assigned", ""), .predicate("assignee", "others"), .predicate("assignee", "me")]))
    }

    func testNamePatternsRestoreAsPatternsWhileExactTargetsRemap() throws {
        var snapshot = fixture()
        let rule = FilterRule.and([.predicate("project_name", "*search"), .predicate("section_name", "Read*"), .predicate("label_name", "*work"), .predicate("project", projectID)])
        snapshot.tables["saved_views"]![0]["query_ast"] = rule.document
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data())
        let plan = try file.plan(current: Snapshot(), account: other)
        let view = Record(try XCTUnwrap(plan.changes.first { $0.table == "saved_views" }).fields)
        let restored = try FilterRule(document: view["query_ast"])
        XCTAssertEqual(restored, .and([.predicate("project_name", "*search"), .predicate("section_name", "Read*"), .predicate("label_name", "*work"), .predicate("project", try XCTUnwrap(plan.mappedIDs["projects"]?[projectID]))]))
        let task = Record(try XCTUnwrap(plan.changes.first { $0.table == "tasks" }).fields)
        let project = Record(try XCTUnwrap(plan.changes.first { $0.table == "projects" }).fields)
        let section = Record(try XCTUnwrap(plan.changes.first { $0.table == "sections" }).fields)
        let label = Record(try XCTUnwrap(plan.changes.first { $0.table == "labels" }).fields)
        XCTAssertTrue(restored.matches(task, today: "2026-10-07", userID: other, labels: [.init(id: label.id, name: label.name)], timeZone: "UTC", projects: [.init(id: project.id, name: project.name)], sections: [.init(id: section.id, name: section.name, projectID: section.string("project_id"))]))
    }

    func testCreationFilterBackupRestorePreservesOriginalDatesAndRelativeQuery() throws {
        var snapshot = fixture(); snapshot.tables["tasks"]![0]["created_at"] = .string("2024-02-29T23:30:00Z")
        let rule = FilterRule.and([.predicate("created_after", "365 days ago"), .predicate("project", projectID)])
        snapshot.tables["saved_views"]![0]["query_ast"] = rule.document
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data())
        let plan = try file.plan(current: Snapshot(), account: other)
        let restored = Record(try XCTUnwrap(plan.changes.first { $0.table == "tasks" }).fields)
        XCTAssertEqual(restored.string("created_at"), "2024-02-29T23:30:00Z")
        let view = Record(try XCTUnwrap(plan.changes.first { $0.table == "saved_views" }).fields)
        let expected = FilterRule.and([.predicate("created_after", "365 days ago"), .predicate("project", try XCTUnwrap(plan.mappedIDs["projects"]?[projectID]))])
        XCTAssertEqual(try FilterRule(document: view["query_ast"]), expected)
        XCTAssertTrue(expected.captureDefaults(in: FilterContext(projects: [Record(["id": .string(plan.mappedIDs["projects"]![projectID]!), "name": .string("Research")])]), today: "2026-10-07")["created_at"] == nil)
    }

    let owner = "11111111-1111-4111-8111-111111111111"
    let other = "22222222-2222-4222-8222-222222222222"
    let projectID = "33333333-3333-4333-8333-333333333333"
    let taskID = "44444444-4444-4444-8444-444444444444"
    let labelID = "55555555-5555-4555-8555-555555555555"
    let sectionID = "66666666-6666-4666-8666-666666666666"
    let filterID = "77777777-7777-4777-8777-777777777777"
    func fixture() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.tables = [
            "projects": [Record(["id": .string(projectID), "user_id": .string(owner), "name": .string("Research"), "color": .string("#e31e4b")])],
            "labels": [Record(["id": .string(labelID), "user_id": .string(owner), "name": .string("Deep work"), "color": .string("#e31e4b")])],
            "sections": [Record(["id": .string(sectionID), "user_id": .string(owner), "name": .string("Reading"), "project_id": .string(projectID)])],
            "tasks": [Record(["id": .string(taskID), "user_id": .string(owner), "title": .string("Read a paper"), "project_id": .string(projectID), "section_id": .string(sectionID), "labels": .array([.string("Deep work")]), "deadline_date": .string("2026-10-25"), "duration_minutes": .number(25), "due_date": .string("2026-10-25"), "due_time": .string("02:30:00"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-25T01:30:00Z"), "assigned_to": .string(owner), "subtasks": .array([.object(["id": .string("child"), "title": .string("Annotate"), "completed": .bool(false), "assigned_to": .string(owner)])])])],
            "saved_views": [Record(["id": .string(filterID), "user_id": .string(owner), "name": .string("Focused"), "query_ast": FilterRule.and([.predicate("project", projectID), .not(.predicate("label", labelID))]).document])],
            "favorites": [Record(["id": .string("view:" + filterID), "user_id": .string(owner)])],
            "view_preferences": [Record(["id": .string("project:" + projectID), "user_id": .string(owner), "layout": .string("board")])],
            "view_orders": [Record(["id": .string("project:" + projectID + "|section:" + sectionID), "user_id": .string(owner), "ids": .array([.string(taskID)])])]
        ]; return snapshot
    }
    func backup() -> WorkspaceBackup { .make(fixture(), account: owner) }
    func testPortableVersionRoundTripExcludesExecutableQueue() throws {
        var snapshot = fixture(); snapshot.pending = [Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["title": .string("Unsent")], baseline: ["title": .string("Old")])]
        let data = try WorkspaceBackup.make(snapshot, account: owner).data()
        let root = try JSONDecoder().decode(JSON.self, from: data)
        XCTAssertEqual(root.object["version"], .number(1)); XCTAssertNil(root.object["pending"]); XCTAssertNil(root.object["session"])
        let read = try WorkspaceBackup.read(data); XCTAssertEqual(read.tables, snapshot.tables); XCTAssertEqual(read.unsyncedChanges, 1)
    }
    func testLegacyExportsRemainRestorable() throws {
        let data = try JSONEncoder().encode(fixture().tables)
        let read = try WorkspaceBackup.read(data); XCTAssertTrue(read.legacy)
        let plan = try read.plan(current: Snapshot(), account: owner)
        XCTAssertEqual(plan.mappedIDs["tasks"]?[taskID], taskID); XCTAssertEqual(plan.added, 8)
    }
    func testFutureVersionsUnknownColumnsAndMalformedRootsFailClosed() throws {
        var newer = backup(); newer.version = 2
        XCTAssertThrowsError(try WorkspaceBackup.read(newer.data()))
        for content in ["[]", "{\"pending\": []}", "{\"format\": \"elsewhere\", \"version\": 1}"] { XCTAssertThrowsError(try WorkspaceBackup.read(Data(content.utf8))) }
        newer = backup(); newer.tables["tasks"]![0]["future_field"] = .string("preserve me")
        XCTAssertThrowsError(try newer.plan(current: Snapshot(), account: owner))
        newer = backup(); newer.tables["unknown"] = []; XCTAssertThrowsError(try newer.validate())
    }
    func testInvalidPlanningValuesAndNullTitlesAreRejected() throws {
        for (field, value) in [("due_date",JSON.string("2026-02-30")),("due_time",.string("25:00")),("deadline_date",.number(5)),("duration_minutes",.number(0)),("duration_minutes",.number(25.5)),("time_zone",.string("Invented/Zone")),("title",.null),("priority",.number(99))] {
            var file = backup(); file.tables["tasks"]![0][field] = value
            XCTAssertThrowsError(try file.validate(), "\(field) = \(value)")
        }
    }
    func testFixedInstantRetainsSecondDSTFoldAndRejectsContradiction() throws {
        let plan = try backup().plan(current: Snapshot(), account: owner)
        let task = plan.changes.first { $0.table == "tasks" }!
        XCTAssertEqual(task.fields["scheduled_at"], .string("2026-10-25T01:30:00Z"))
        XCTAssertEqual(TaskPlanning.fields(task.fields, existing: nil)["scheduled_at"], task.fields["scheduled_at"])
        var file = backup(); file.tables["tasks"]![0]["scheduled_at"] = .string("2026-10-25T03:30:00Z")
        XCTAssertThrowsError(try file.validate())
    }
    func testCrossAccountRemapsGraphFiltersScopesAndAssignments() throws {
        let plan = try backup().plan(current: Snapshot(), account: other)
        let project = plan.mappedIDs["projects"]![projectID]!, label = plan.mappedIDs["labels"]![labelID]!, section = plan.mappedIDs["sections"]![sectionID]!, task = plan.mappedIDs["tasks"]![taskID]!
        XCTAssertNotEqual(project, projectID)
        let row = Record(plan.changes.first { $0.table == "tasks" }!.fields)
        XCTAssertEqual(row.string("project_id"), project); XCTAssertEqual(row.string("section_id"), section); XCTAssertEqual(row["labels"], .array([.string(label)])); XCTAssertEqual(row.string("assigned_to"), other)
        let child = Record(row["subtasks"].list[0].object); XCTAssertNotEqual(child.id, "child"); XCTAssertEqual(child.string("assigned_to"), other)
        let rule = try FilterRule(document: plan.changes.first { $0.table == "saved_views" }!.fields["query_ast"]!)
        XCTAssertEqual(rule, .and([.predicate("project",project), .not(.predicate("label",label))]))
        let order = plan.changes.first { $0.table == "view_orders" }!
        XCTAssertEqual(order.recordID, "project:" + project + "|section:" + section)
        XCTAssertEqual(order.fields["ids"], .array([.string(task)]))
        XCTAssertTrue(plan.changes.allSatisfy { $0.fields["user_id"] == .string(other) && $0.insertOnly == true })
    }
    func testStableMappingAcrossBackupsAndDifferentClients() throws {
        let a = try backup().plan(current: Snapshot(), account: other), b = try backup().plan(current: Snapshot(), account: other)
        XCTAssertEqual(a.mappedIDs, b.mappedIDs)
        var file = backup(); file.sourceAccount = "different-source"
        XCTAssertNotEqual(try file.plan(current: Snapshot(), account: other).mappedIDs, a.mappedIDs)
        var restored = Snapshot(); a.changes.forEach { restored.apply($0) }
        let repeated = try backup().plan(current: restored, account: other)
        XCTAssertEqual(repeated.added, 0); XCTAssertEqual(repeated.updated, 0); XCTAssertEqual(repeated.kept, 8)
    }
    func testMatchingPolicyPreservesEditsOrExplicitlyRestoresWithBaseline() throws {
        var current = fixture(); current.tables["tasks"]![0]["title"] = .string("Newer edit")
        let kept = try backup().plan(current: current, account: owner)
        XCTAssertEqual(kept.total, 0); XCTAssertEqual(kept.kept, 8)
        let overwrite = try backup().plan(current: current, account: owner, policy: .backupValues)
        let update = overwrite.changes.first { $0.table == "tasks" }!
        XCTAssertEqual(update.method, "PATCH"); XCTAssertEqual(update.fields["title"], .string("Read a paper")); XCTAssertEqual(update.baseline?["title"], .string("Newer edit"))
        XCTAssertNil(update.fields["id"]); XCTAssertNil(update.fields["user_id"]); XCTAssertNil(update.fields["created_at"])
        XCTAssertTrue(overwrite.changes.allSatisfy { $0.method != "DELETE" })
        XCTAssertNil(update.fields["subtasks"], "Matching own subtasks retain their IDs and do not create a spurious edit")
    }
    func testSharedProjectsBecomePersonalCopiesEvenForOwnTasks() throws {
        var file = backup(); file.tables["projects"]![0]["user_id"] = .string(other)
        let plan = try file.plan(current: fixture(), account: owner)
        XCTAssertNotEqual(plan.mappedIDs["projects"]?[projectID], projectID); XCTAssertNotEqual(plan.mappedIDs["tasks"]?[taskID], taskID)
    }
    func testProjectMoveRestoresValidatedAssignmentsAfterClearing() throws {
        var current = fixture(); current.tables["tasks"]![0]["project_id"] = .null; current.tables["tasks"]![0]["section_id"] = .null
        let plan = try backup().plan(current: current, account: owner, policy: .backupValues)
        let updates = plan.changes.filter { $0.table == "tasks" }
        XCTAssertEqual(updates.count, 2)
        let moves = TaskAssignment.mutations(updates[0], existing: current.tables["tasks"]![0])
        XCTAssertEqual(moves[0].fields["assigned_to"], .null)
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(updates[1].fields["assigned_to"], .string(owner))
        XCTAssertEqual(moves[0].baseline?["assigned_to"], .string(owner))
        XCTAssertEqual(moves[0].baseline?["subtasks"], current.tables["tasks"]![0]["subtasks"])
        XCTAssertEqual(updates[1].fields["subtasks"], fixture().tables["tasks"]![0]["subtasks"])
        XCTAssertEqual(updates[1].baseline?["subtasks"], TaskAssignment.clearChildren(fixture().tables["tasks"]![0]["subtasks"]))
    }

    func testProjectMoveDoesNotRepeatAnAlreadyRestoredRootAssignment() throws {
        var current = fixture(); current.tables["tasks"]![0]["project_id"] = .string("88888888-8888-4888-8888-888888888888"); current.tables["tasks"]![0]["assigned_to"] = .string(other)
        let updates = try backup().plan(current: current, account: owner, policy: .backupValues).changes.filter { $0.table == "tasks" }
        let moves = TaskAssignment.mutations(updates[0], existing: current.tables["tasks"]![0])
        XCTAssertEqual(moves.count, 2); XCTAssertEqual(moves[1].fields["assigned_to"], .string(owner))
        XCTAssertNil(updates[1].fields["assigned_to"]); XCTAssertNotNil(updates[1].fields["subtasks"])
    }
    func testProjectSectionOrdersAndInboxBucketKeepTheirMeaning() throws {
        var file = backup(); file.tables["view_orders"] = [Record(["id": .string("group:" + projectID + ":" + sectionID), "ids": .array([.string(taskID)])]), Record(["id": .string("scope:today:group:project:none"), "ids": .array([])])]
        let plan = try file.plan(current: Snapshot(), account: other)
        let keys = plan.changes.filter { $0.table == "view_orders" }.map(\.recordID)
        XCTAssertTrue(keys.contains("group:" + plan.mappedIDs["projects"]![projectID]! + ":" + plan.mappedIDs["sections"]![sectionID]!))
        XCTAssertTrue(keys.contains("scope:today:group:project:none"))
    }

    func testMissingOrContradictoryProjectReferencesFailBeforeMutation() throws {
        var file = backup(); file.tables["projects"] = []
        XCTAssertThrowsError(try file.plan(current: Snapshot(), account: other))
        file = backup(); file.tables["sections"]![0]["project_id"] = .string("different")
        XCTAssertThrowsError(try file.plan(current: Snapshot(), account: owner))
    }
    func testUnavailablePeopleClearedAtRootAndNestedDepth() throws {
        var file = backup(); file.tables["tasks"]![0]["assigned_to"] = .string(other)
        file.tables["tasks"]![0]["subtasks"] = .array([.object(["id": .string("one"), "title": .string("Parent"), "assigned_to": .string(other), "subtasks": .array([.object(["id": .string("two"), "title": .string("Child"), "assigned_to": .string(other)])])])])
        let plan = try file.plan(current: Snapshot(), account: owner)
        let row = Record(plan.changes.first { $0.table == "tasks" }!.fields)
        XCTAssertEqual(row["assigned_to"], .null)
        let child = Record(row["subtasks"].list[0].object); XCTAssertEqual(child["assigned_to"], .null); XCTAssertEqual(child["subtasks"].list[0].object["assigned_to"], .null)
        XCTAssertTrue(plan.warnings.contains { $0.contains("3 assignments") })
    }
    func testDuplicateSubtasksMalformedCollectionsAndRecurrenceRejected() throws {
        var file = backup(); let child = JSON.object(["id": .string("duplicate"), "title": .string("Subtask")]); file.tables["tasks"]![0]["subtasks"] = .array([child,child])
        XCTAssertThrowsError(try file.plan(current: Snapshot(), account: owner))
        file = backup(); file.tables["tasks"]![0]["subtasks"] = .array([.object(["title": .string("Bad"), "completed": .string("yes")])]); XCTAssertThrowsError(try file.plan(current: Snapshot(), account: owner))
        file = backup(); file.tables["tasks"]![0]["is_recurring"] = .bool(true); file.tables["tasks"]![0]["recurrence_pattern"] = .object(["type": .string("weekly"),"interval": .number(1),"daysOfWeek": .array([.number(7)])]); XCTAssertThrowsError(try file.validate())
    }
    func testRecurrenceParentsAreInsertedBeforeChildrenAndCyclesFail() throws {
        var file = backup(); var child = file.tables["tasks"]![0]; child["id"] = .string(UUID().uuidString.lowercased()); child["recurrence_parent_id"] = .string(taskID)
        file.tables["tasks"]!.insert(child, at: 0)
        let plan = try file.plan(current: Snapshot(), account: owner)
        XCTAssertEqual(plan.changes.filter { $0.table == "tasks" }.map(\.recordID), [taskID,child.id])
        file.tables["tasks"]![1]["recurrence_parent_id"] = .string(child.id)
        XCTAssertThrowsError(try file.plan(current: Snapshot(), account: owner))
    }
    func testLegacyDayOrdersAreRestoredWithMappedTaskIDs() throws {
        var file = backup(); file.tables.removeValue(forKey: "view_orders"); file.tables["_local_day_order"] = [Record(["id": .string("2026-10-25"),"ids": .array([.string(taskID)])])]
        let plan = try file.plan(current: Snapshot(), account: other)
        let order = plan.changes.first { $0.table == "view_orders" }!
        XCTAssertEqual(order.recordID,"2026-10-25"); XCTAssertEqual(order.fields["ids"], .array([.string(plan.mappedIDs["tasks"]![taskID]!)]))
    }
    func testUUIDCaseIsCanonicalAndDuplicateSpellingsFail() throws {
        let id = "abcdefab-cdef-4abc-8def-abcdefabcdef"
        var file = backup(); var task = file.tables["tasks"]![0]
        task["id"] = .string(id.uppercased()); file.tables["tasks"] = [task]
        var current = Snapshot(); var existing = task; existing["id"] = .string(id); current.tables["tasks"] = [existing]
        let plan = try file.plan(current: current, account: owner)
        XCTAssertEqual(plan.mappedIDs["tasks"]?[id.uppercased()], id)
        XCTAssertFalse(plan.changes.contains { $0.table == "tasks" })
        file.tables["tasks"]!.append(existing); XCTAssertThrowsError(try file.validate())
    }
    func testUnknownEmbeddedOrderTargetsAreNamespaced() throws {
        var file = backup(); file.tables["view_orders"] = [Record(["id": .string("scope:view:missing-view:group:project:missing-project"),"user_id": .string(owner),"ids": .array([.string(taskID)])])]
        let plan = try file.plan(current: Snapshot(), account: other)
        let order = plan.changes.first { $0.table == "view_orders" }!
        XCTAssertFalse(order.recordID.contains("missing-view")); XCTAssertFalse(order.recordID.contains("missing-project"))
        XCTAssertTrue(order.recordID.hasPrefix("scope:view:")); XCTAssertTrue(order.recordID.contains(":group:project:"))
    }

    func testDuplicateIDsAndOversizedNumbersFail() throws {
        var file = backup(); file.tables["tasks"]!.append(file.tables["tasks"]![0]); XCTAssertThrowsError(try file.validate())
        file = backup(); file.tables["tasks"]![0]["priority"] = .number(1e20); XCTAssertThrowsError(try file.validate())
    }
    func testQueueCodecReadsHistoricalCacheAndPreservesCreateOnly() throws {
        let old = Data(#"{"id":"99999999-9999-4999-8999-999999999999","table":"tasks","recordID":"one","method":"POST","fields":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Mutation.self, from: old).insertOnly)
        let change = Mutation(table: "tasks",recordID: taskID,method: "POST",fields: [:],insertOnly: true)
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(change)), change)
    }
    func testEncryptedVaultRetainsPendingQueueAndHasNoPlaintextTitles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = BackupVault(directory: directory,account: owner,key: { key })
        var snapshot = fixture(); snapshot.pending = [Mutation(table: "tasks",recordID: taskID,method:"PATCH",fields:["title":.string("Queued")],baseline:["title":.string("Read a paper")])]
        let entry = try vault.save(snapshot,kind:"Before restore")
        XCTAssertEqual(try vault.load(entry).snapshot,snapshot)
        XCTAssertFalse(String(decoding:try Data(contentsOf:vault.file(entry)),as:UTF8.self).contains("Read a paper"))
        XCTAssertFalse(String(decoding:try Data(contentsOf:directory.appendingPathComponent("index.json")),as:UTF8.self).contains("Read a paper"))
        XCTAssertEqual(try vault.entries().count,1)
    }
    func testVaultRejectsTamperingWrongKeyAndAnotherAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let key = SymmetricKey(size:.bits256), vault = BackupVault(directory:directory,account:owner,key:{ key })
        let entry = try vault.save(fixture(),kind:"Manual")
        let wrong = SymmetricKey(size:.bits256)
        XCTAssertThrowsError(try BackupVault(directory:directory,account:owner,key:{ wrong }).load(entry))
        XCTAssertThrowsError(try BackupVault(directory:directory,account:other,key:{ key }).load(entry))
        var bytes = try Data(contentsOf:vault.file(entry)); bytes[bytes.count-1] ^= 1; try bytes.write(to:vault.file(entry))
        XCTAssertThrowsError(try vault.load(entry))
    }
    func testVaultRetainsTwentyNewestAndRemovesOlderCiphertext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let key = SymmetricKey(size:.bits256), vault = BackupVault(directory:directory,account:owner,key:{ key })
        let first = try vault.save(fixture(),kind:"Daily",now:Date(timeIntervalSince1970:0))
        for n in 1...21 { _ = try vault.save(fixture(),kind:"Manual",now:Date(timeIntervalSince1970:Double(n))) }
        let entries = try vault.entries(); XCTAssertEqual(entries.count,20); XCTAssertEqual(entries.first?.createdAt,Date(timeIntervalSince1970:21)); XCTAssertFalse(FileManager.default.fileExists(atPath:vault.file(first).path))
    }
    @MainActor func testCreateOnlyTransportChecksOwnershipOnConflict() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"fixture\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(owner)\"}}".utf8))
        let backend = Backend(configuration:["URL":"https://native-auth.test","Key":"public"],http:URLSession(configuration:config),session:session,persistSession:{ _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        var requests = 0
        AuthTransportTests.Stub.handler = { request in
            requests += 1
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField:"Prefer"),"handling=strict,resolution=ignore-duplicates,missing=default,return=representation")
                return (200,Data("[]".utf8))
            }
            XCTAssertEqual(request.httpMethod,"GET")
            let params = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            XCTAssertEqual(params.first { $0.name == "user_id" }?.value,"eq." + self.owner)
            return (200,try JSONEncoder().encode([Record(["id":.string(self.taskID),"user_id":.string(self.owner),"title":.string("Newer server edit")])]))
        }
        try await backend.send(Mutation(table:"tasks",recordID:taskID,method:"POST",fields:["id":.string(taskID),"user_id":.string(owner),"title":.string("Backup edit")],insertOnly:true))
        XCTAssertEqual(requests,2)
        AuthTransportTests.Stub.handler = { _ in (200,Data("[]".utf8)) }
        do { try await backend.send(Mutation(table:"tasks",recordID:taskID,method:"POST",fields:["id":.string(taskID),"user_id":.string(owner)],insertOnly:true)); XCTFail("A missing inaccessible row cannot acknowledge a restore") } catch { XCTAssertTrue(error.localizedDescription.contains("could not confirm")) }
    }

    func testExtendedKeywordAndMetadataFiltersKeepMeaningAcrossBackupAccounts() throws {
        var file = backup()
        let rule = FilterRule.and([.predicate("project", projectID), .predicate("search", "read paper"), .predicate("no_time", ""), .not(.predicate("no_labels", "")), .predicate("recurring", "")])
        file.tables["saved_views"]![0]["query_ast"] = rule.document
        let read = try WorkspaceBackup.read(file.data()); XCTAssertEqual(read.tables["saved_views"]![0]["query_ast"], rule.document)
        let plan = try read.plan(current: Snapshot(), account: other)
        let restored = try XCTUnwrap(plan.changes.first { $0.table == "saved_views" })
        let expected = FilterRule.and([.predicate("project", plan.mappedIDs["projects"]![projectID]!), .predicate("search", "read paper"), .predicate("no_time", ""), .not(.predicate("no_labels", "")), .predicate("recurring", "")])
        XCTAssertEqual(try FilterRule(document: try XCTUnwrap(restored.fields["query_ast"])), expected)
        XCTAssertEqual(expected.captureDefaults(in: FilterContext(), today: "2026-10-05"), ["project_id": .string(plan.mappedIDs["projects"]![projectID]!)])
    }
    func testRelativeDateSourcesRemainRelativeAcrossBackupAccountRemapping() throws {
        var file = backup()
        let rule = FilterRule.and([.predicate("project", projectID), .predicate("effective_due_on", "tomorrow"), .predicate("deadline_after", "yesterday")])
        file.tables["saved_views"]![0]["query_ast"] = rule.document
        let read = try WorkspaceBackup.read(file.data())
        let plan = try read.plan(current: Snapshot(), account: other)
        let restored = try XCTUnwrap(plan.changes.first { $0.table == "saved_views" })
        let expected = FilterRule.and([.predicate("project", plan.mappedIDs["projects"]![projectID]!), .predicate("effective_due_on", "tomorrow"), .predicate("deadline_after", "yesterday")])
        XCTAssertEqual(try FilterRule(document: try XCTUnwrap(restored.fields["query_ast"])), expected)
        XCTAssertEqual(expected.captureDefaults(in: FilterContext(), today: "2026-10-05"), ["project_id": .string(plan.mappedIDs["projects"]![projectID]!)])
        let row = Record(try XCTUnwrap(plan.changes.first { $0.table == "tasks" }).fields)
        XCTAssertTrue(expected.matches(row, today: "2026-10-24", userID: other, labels: [], timeZone: "Europe/Copenhagen"))
        XCTAssertFalse(expected.matches(row, today: "2026-10-25", userID: other, labels: [], timeZone: "Europe/Copenhagen"))
    }

    func testTimedFiltersSurvivePortableBackupAccountAndProjectRemapping() throws {
        var file = backup()
        let rule = FilterRule.and([.predicate("project", projectID), .predicate("planned_before", "tomorrow at 03:00"), .predicate("planned_time_after", "01:00")])
        file.tables["saved_views"]![0]["query_ast"] = rule.document
        let plan = try WorkspaceBackup.read(file.data()).plan(current: Snapshot(), account: other)
        let restored = try XCTUnwrap(plan.changes.first { $0.table == "saved_views" })
        let expected = FilterRule.and([.predicate("project", plan.mappedIDs["projects"]![projectID]!), .predicate("planned_before", "tomorrow at 03:00"), .predicate("planned_time_after", "01:00")])
        XCTAssertEqual(try FilterRule(document: try XCTUnwrap(restored.fields["query_ast"])), expected)
        let row = Record(try XCTUnwrap(plan.changes.first { $0.table == "tasks" }).fields)
        XCTAssertTrue(expected.matches(row, today: "2026-10-24", userID: other, labels: [], timeZone: "Europe/Copenhagen"))
        XCTAssertFalse(expected.matches(row, today: "2026-10-23", userID: other, labels: [], timeZone: "Europe/Copenhagen"))
    }

}


extension BackupTests {
    func testSnoozePreferenceBackupCrossAccountIdentityAndCreateOnlyRetry() throws {
        let settings: JSON = .object(["version": .number(1), "snooze_minutes": .number(15), "extension": .string("keep")])
        var source = fixture(); source.tables[ReminderSnooze.table] = [Record(["id": .string("current"), "user_id": .string(owner), "settings": settings])]
        let read = try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data())
        let plan = try read.plan(current: Snapshot(), account: other)
        let change = try XCTUnwrap(plan.changes.first { $0.table == ReminderSnooze.table })
        XCTAssertEqual(change.recordID, "current"); XCTAssertEqual(change.fields["user_id"], .string(other)); XCTAssertEqual(change.fields["settings"], settings); XCTAssertTrue(change.insertOnly == true)
        var applied = Snapshot(); plan.changes.forEach { applied.apply($0) }
        let retry = try read.plan(current: applied, account: other)
        XCTAssertFalse(retry.changes.contains { $0.table == ReminderSnooze.table })
        let future: JSON = .object(["version": .number(2), "future": .array([.string("opaque")]), "extension": .string(String(repeating: "/", count: 5000))])
        source.tables[ReminderSnooze.table]![0]["settings"] = future
        let futureRead = try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data())
        XCTAssertEqual(futureRead.tables[ReminderSnooze.table]?[0]["settings"], future)
        let futurePlan = try futureRead.plan(current: Snapshot(), account: other)
        XCTAssertEqual(futurePlan.changes.first { $0.table == ReminderSnooze.table }?.fields["settings"], future)
    }
    func testMalformedSnoozePreferenceBackupFailsBeforeAnyRestorePlan() throws {
        var source = fixture(); source.tables[ReminderSnooze.table] = [Record(["id": .string("current"), "user_id": .string(owner), "settings": .object(["version": .number(1), "snooze_minutes": .number(0)])])]
        XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data()))
        source.tables[ReminderSnooze.table]![0]["settings"] = .object(["version": .number(1), "snooze_minutes": .number(30)])
        source.tables[ReminderSnooze.table]![0]["id"] = .string("different")
        XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data()))
    }
}

extension BackupTests {
    func testAutomaticPreferenceRoundTripAndCreateOnlyRestorePreserveBothChoices() throws {
        let settings: JSON = .object(["version": .number(1), "snooze_minutes": .number(5), ReminderAutomatic.field: .number(15), "extension": .string("keep")])
        var source = fixture()
        source.tables[ReminderSnooze.table] = [Record(["id": .string("current"), "user_id": .string(owner), "settings": settings])]
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data())
        XCTAssertEqual(file.tables[ReminderSnooze.table]?.first?["settings"], settings)
        let plan = try file.plan(current: Snapshot(), account: other)
        let change = try XCTUnwrap(plan.changes.first { $0.table == ReminderSnooze.table })
        XCTAssertEqual(change.insertOnly, true); XCTAssertNil(change.reminderPreferenceField)
        XCTAssertEqual(change.fields["user_id"], .string(other)); XCTAssertEqual(change.fields["settings"], settings)
        var restored = Snapshot(); restored.apply(change)
        var newer = restored.tables[ReminderSnooze.table]!.first!
        newer["settings"] = ReminderAutomatic.changing(newer["settings"], minutes: -1)!
        restored.tables[ReminderSnooze.table] = [newer]; restored.apply(change)
        XCTAssertEqual(restored.tables[ReminderSnooze.table], [newer])
        source.tables[ReminderSnooze.table]![0]["settings"] = .object(["version": .number(1), "snooze_minutes": .number(5), ReminderAutomatic.field: .number(15.5)])
        XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data()))
    }
}
