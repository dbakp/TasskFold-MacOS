import XCTest
@testable import TaskfoldCore

/// Operator-provisioned, disposable accounts only. The fixture file is private,
/// outside the repository; passwords/tokens are never printed or persisted by Backend.
final class AssignmentProvenanceHTTPIntegrationTests: XCTestCase {
    struct Fixture: Decodable { let users:[String]; let password:String }
    @MainActor func testLiveAssignmentReadsReassignmentRetryRevocationAndFilters() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_ASSIGNMENT_LIVE_FIXTURE"] else { throw XCTSkip("Disposable assignment HTTP accounts required") }
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        guard fixture.users.count == 3, fixture.users.allSatisfy({ UUID(uuidString:$0) != nil }) else { throw AppFailure(message:"Invalid disposable assignment fixture") }
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try PropertyListDecoder().decode([String:String].self,from:Data(contentsOf:source.appendingPathComponent("Taskfold/Backend.plist")))
        guard URL(string:configuration["URL"] ?? "")?.host == "zqxflydiyfjeedqvyova.supabase.co" else { throw AppFailure(message:"This fixture requires the dedicated Taskfold backend") }
        let clients = (0..<3).map { _ in Backend(configuration:configuration,session:nil,persistSession:{ _ in }) }
        let owner = clients[0], member = clients[1], outsider = clients[2]
        let ownerID = fixture.users[0], memberID = fixture.users[1]
        let projectID = UUID().uuidString.lowercased(), taskID = UUID().uuidString.lowercased(), invitationID = UUID().uuidString.lowercased(), childID = UUID().uuidString.lowercased()
        func cleanup() async {
            _ = try? await owner.request("/rest/v1/tasks?id=eq."+taskID,method:"DELETE")
            _ = try? await owner.request("/rest/v1/projects?id=eq."+projectID,method:"DELETE")
            for client in clients where client.session != nil {
                _ = try? await client.request("/auth/v1/logout",method:"POST")
                try? await client.clearSession()
            }
        }
        func catalog(_ client: Backend) async throws -> TaskAssignmentProvenance.Catalog {
            let rows = await client.assignmentProvenanceRows()
            return TaskAssignmentProvenance.Catalog(try XCTUnwrap(rows,"Actual HTTP history read unavailable"))
        }
        func patch(_ client: Backend, task: Record, recipient: String) async throws -> Record {
            var child = task["subtasks"].list[0].object; child["assigned_to"] = .string(recipient)
            let fields: [String:JSON] = ["assigned_to":.string(recipient),"subtasks":.array([.object(child)])]
            let base: [String:JSON] = ["assigned_to":task["assigned_to"],"subtasks":task["subtasks"],"task_generation":task["task_generation"]]
            let result = try await client.send(Mutation(table:"tasks",recordID:task.id,method:"PATCH",fields:fields,baseline:base))
            return try XCTUnwrap(result)
        }
        do {
            for (index,client) in clients.enumerated() {
                let signedIn = try await client.signIn(email:"taskfold-assignment-"+fixture.users[index]+"@example.invalid",password:fixture.password,signup:false)
                XCTAssertTrue(signedIn); XCTAssertEqual(client.session?.user.id,fixture.users[index])
            }
            _ = try await owner.send(Mutation(table:"projects",recordID:projectID,method:"POST",fields:["id":.string(projectID),"user_id":.string(ownerID),"name":.string("Disposable assignment HTTP studio")]))
            _ = try await owner.send(Mutation(table:"project_collaborators",recordID:invitationID,method:"POST",fields:["id":.string(invitationID),"project_id":.string(projectID),"invited_email":.string("taskfold-assignment-"+memberID+"@example.invalid"),"invited_by":.string(ownerID)]))
            _ = try await member.send(Mutation(table:"project_collaborators",recordID:invitationID,method:"PATCH",fields:["status":.string("accepted")]))
            var draft = Record.task(user:ownerID,project:projectID,date:Date())
            draft["id"] = .string(taskID); draft["task_generation"] = .string(UUID().uuidString.lowercased()); draft["title"] = .string("Disposable assignment HTTP handoff"); draft["assigned_to"] = .string(memberID)
            draft["subtasks"] = .array([.object(["id":.string(childID),"title":.string("Disposable nested handoff"),"completed":.bool(false),"assigned_to":.string(memberID)])])
            let created = try await owner.send(Mutation(table:"tasks",recordID:taskID,method:"POST",fields:draft.fields,insertOnly:true))
            var current = try XCTUnwrap(created)
            let initial = try await catalog(member)
            guard case .known(let firstActor,_,_) = initial.resolution(root:current) else { throw AppFailure(message:"HTTP creation actor missing") }
            XCTAssertEqual(firstActor,ownerID)
            let changed = try await patch(member,task:current,recipient:ownerID)
            let history = try await catalog(owner)
            guard case .known(let actor,let event,_) = history.resolution(root:changed) else { throw AppFailure(message:"HTTP member actor missing") }
            XCTAssertEqual(actor,memberID)
            let index = try TaskHierarchyIndex(roots:[changed],projects:[Record(["id":.string(projectID),"name":.string("Fixture")])],workspace:WorkspaceBinding(account:ownerID,generation:UUID()))
            let child = try XCTUnwrap(index.items.first { $0.isSubtask })
            guard case .known(let childActor,_,_) = history.resolution(item:child) else { throw AppFailure(message:"HTTP child actor missing") }
            XCTAssertEqual(childActor,memberID)
            // A lost-response retry by the other client is not a new assignment.
            current = try await patch(owner,task:current,recipient:ownerID)
            let retried = try await catalog(owner)
            guard case .known(let retryActor,let retryEvent,_) = retried.resolution(root:current) else { throw AppFailure(message:"Retry provenance missing") }
            XCTAssertEqual(retryActor,memberID); XCTAssertEqual(retryEvent,event)
            current = try await patch(owner,task:current,recipient:memberID)
            current = try await patch(member,task:current,recipient:ownerID)
            let latest = try await catalog(owner)
            guard case .known(let latestActor,let latestEvent,_) = latest.resolution(root:current) else { throw AppFailure(message:"Assignment cycle provenance missing") }
            XCTAssertEqual(latestActor,memberID); XCTAssertNotEqual(latestEvent,event)
            let rule = FilterRule.predicate("assigned_by",memberID)
            let context = FilterContext(projects:[Record(["id":.string(projectID),"name":.string("Fixture")])],userID:ownerID,assignments:latest)
            try rule.validate(in:context)
            XCTAssertTrue(rule.resultMatches(current,context:context,today:"2026-10-21",timeZone:"UTC"))
            do {
                _ = try await owner.request("/rest/v1/task_assignment_provenance",method:"POST",body:["id":.string(UUID().uuidString.lowercased()),"task_id":.string(taskID),"actor_id":.string(ownerID)])
                XCTFail("Actual HTTP forged actor accepted")
            } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("permission denied"),"Expected database write denial") }
            let outsiderRows = try await outsider.rows("tasks")
            XCTAssertFalse(outsiderRows.contains { $0.id == taskID })
            let outsiderHistory = await outsider.assignmentProvenanceRows()
            XCTAssertFalse(try XCTUnwrap(outsiderHistory).contains { $0.string("task_id") == taskID })
            _ = try await owner.send(Mutation(table:"project_collaborators",recordID:invitationID,method:"PATCH",fields:["status":.string("declined")]))
            let revoked = await member.assignmentProvenanceRows()
            XCTAssertFalse(try XCTUnwrap(revoked).contains { $0.string("task_id") == taskID })
            let stillReadable = try await catalog(owner)
            XCTAssertTrue(rule.resultMatches(current,context:FilterContext(projects:context.projects,userID:ownerID,assignments:stillReadable),today:"2026-10-21",timeZone:"UTC"))
        } catch { await cleanup(); throw error }
        await cleanup()
    }
}
