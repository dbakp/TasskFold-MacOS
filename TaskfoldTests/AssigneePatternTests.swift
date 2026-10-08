import XCTest
@testable import TaskfoldCore

final class AssigneePatternTests: XCTestCase {
    let owner = "11111111-1111-4111-8111-111111111111"
    let mary = "22222222-2222-4222-8222-222222222222"
    let marc = "33333333-3333-4333-8333-333333333333"
    let jane = "44444444-4444-4444-8444-444444444444"
    var context: FilterContext {
        FilterContext(projects: [Record(["id": .string("work"), "name": .string("Work")])], userID: owner, people: [person(mary,"Mary Smith"), person(marc,"Márç Smith"), person(jane,"Jane Smith")])
    }
    func person(_ id: String, _ name: String, project: String = "work") -> Record {
        Record(["id": .string(id), "display_name": .string(name), "email": .string("mailsmith@example.test"), "project_id": .string(project)])
    }
    func task(_ id: String, _ assigned: String?, project: String = "work") -> Record {
        Record(["id": .string(id), "title": .string(id), "project_id": .string(project), "assigned_to": assigned.map(JSON.string) ?? .null, "completed": .bool(false)])
    }
    func parse(_ input: String, in context: FilterContext? = nil) throws -> FilterRule {
        var p = try FilterParser(input, context: context ?? self.context); return try p.parse()
    }
    func ids(_ rule: FilterRule, _ rows: [Record], _ context: FilterContext) -> [String] {
        rows.filter { rule.resultMatches($0, context: context, today: "2026-10-08", timeZone: "UTC") }.map(\.id)
    }
    func testWildcardAliasesLiteralNamesAndCanonicalRoundTrip() throws {
        for input in ["assigned to: m* smith", "assignee:m* smith", #"assignee matching:"m* smith""#] {
            let rule = try parse(input)
            XCTAssertEqual(rule, .predicate("assignee_name", "m* smith"))
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertEqual(try FilterRule(document: rule.document), rule)
            XCTAssertEqual(ids(rule,[task("mary",mary),task("marc",marc),task("jane",jane),task("none",nil)],context),["mary","marc"])
            XCTAssertTrue(rule.captureDefaults(in: context, today: "2026-10-08").isEmpty)
        }
        var literal = context; literal.people.append(person(jane,"M* Smith"))
        XCTAssertEqual(try parse(#"assigned to:"M* Smith""#, in: literal), .predicate("assignee", jane))
        XCTAssertEqual(try parse(#"assignee matching:"M\\* Smith""#), .predicate("assignee_name", #"M\* Smith"#))
        XCTAssertThrowsError(try parse(#"assignee matching:"""#))
        XCTAssertThrowsError(try FilterRule(document: FilterRule.predicate("assignee_name",String(repeating:"a",count:121)).document))
        XCTAssertTrue(ids(try parse("assigned to:mailsmith*"), [task("email",mary)], context).isEmpty)
    }
    func testUnavailableMembersProjectsAndIdentityFailClosedThroughBooleanQueries() throws {
        let rows=[task("known",jane),task("stale",owner),task("none",nil),task("other-project",mary,project:"gone"),task("inbox-assigned",mary,project:"")]
        for expression in ["!assigned to:m*", "all OR assigned to:m*"] {
            let rule=try parse(expression)
            XCTAssertEqual(ids(rule,rows,context),["known","none"])
            var revoked=context;revoked.projects=[];XCTAssertTrue(ids(rule,rows,revoked).isEmpty)
            var signedOut=context;signedOut.userID="";XCTAssertTrue(ids(rule,rows,signedOut).isEmpty)
            var missing=context;missing.people=[];XCTAssertEqual(ids(rule,rows,missing),["none"])
        }
        var moved=context;moved.people[0]["project_id"] = .string("elsewhere")
        XCTAssertTrue(ids(try parse("all OR assigned to:m*"),[task("wrong-membership",mary)],moved).isEmpty)
        let independent=try parse("assigned to:m*, all")
        XCTAssertEqual(ids(independent,[task("stale",owner)],context),["stale"],"Independent all section retains its own scope")
    }
    func testCatalogRenamesAndMembershipInvalidateCacheWithoutChangingExactIDs() throws {
        let row=task("mary",mary), cache=TaskCache();cache.update([row])
        let rule=try parse("assigned to:m* smith")
        var query=TaskQuery(scope:.all,filter:rule,filterProjects:context.projects.map { FilterReference(id:$0.id,name:$0.name) },filterPeople:context.personReferences,userID:owner,timeZone:"UTC")
        XCTAssertEqual(cache.matching(query).map(\.id),[row.id]);let first=cache.computationCount
        query.filterPeople[0].name="Mary Jones";XCTAssertTrue(cache.matching(query).isEmpty);XCTAssertGreaterThan(cache.computationCount,first)
        query.filter = .predicate("assignee",mary);XCTAssertEqual(cache.matching(query).map(\.id),[row.id])
        query.filter = .not(rule);query.filterPeople=[];XCTAssertTrue(cache.matching(query).isEmpty)
        query.filterPeople=context.personReferences;query.filterPeople.append(FilterReference(id:owner,name:"Matthew Smith",projectID:"work"))
        cache.update([row,task("new",owner)]);query.filter=rule;XCTAssertEqual(Set(cache.matching(query).map(\.id)),["mary","new"])
    }
    func testOrderedGroupsAndPrivateWidgetProjectionUseTheSameDirectory() throws {
        let rows=[task("mary",mary),task("jane",jane),task("none",nil)]
        let rule=try parse("assigned to:m* smith, !assigned to:m* smith")
        let groups=TaskGrouping.queryGroups(rows,rule:rule,by:"none",context:context,today:"2026-10-08",timeZone:"UTC")
        XCTAssertEqual(groups.map { $0.tasks.map(\.id) },[["mary"],["jane","none"]])
        XCTAssertTrue(groups[0].name.contains("Assigned name matches"))
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let view=Record(["id":.string("v"),"name":.string("Matching people"),"query_ast":try parse("assigned to:m* smith").document])
        let payload=WidgetProjection.listPayload(tasks:rows,projects:context.projects,labels:[],sections:[],savedViews:[view],account:owner,now:Dates.parse("2026-10-08")!,calendar:calendar,people:context.people)
        let filter=Record(try XCTUnwrap(payload.last).object)
        XCTAssertEqual(filter["days"].object.count,8);XCTAssertTrue(filter["days"].object.values.allSatisfy { $0.list.map(\.text)==["mary"] })
        let encoded=String(data:try JSONEncoder().encode(payload),encoding:.utf8)!
        for privateValue in ["Mary Smith","Márç Smith","mailsmith@example.test","assignee_name","query_ast"] { XCTAssertFalse(encoded.contains(privateValue),privateValue) }
        let revoked=WidgetProjection.listPayload(tasks:rows,projects:context.projects,labels:[],sections:[],savedViews:[view],account:owner,now:Dates.parse("2026-10-08")!,calendar:calendar)
        XCTAssertTrue(Record(revoked.last!.object)["days"].object.values.allSatisfy { $0.list.isEmpty })
    }
    func testAcceptedDirectoryRejectsInvitationsAndPlaceholderDisplayNames() throws {
        let project=Record(["id":.string("work"),"user_id":.string(owner)])
        let accepted=Record(["user_id":.string(mary),"status":.string("accepted"),"display_name":.string("Mary Smith")])
        let unnamed=Record(["user_id":.string(marc),"status":.string("accepted"),"invited_email":.string("marc@example.test")])
        let invited=Record(["user_id":.string(jane),"status":.string("pending"),"display_name":.string("Jane Smith")])
        let members=TaskAssignment.members(project:project,collaborators:[accepted,unnamed,invited],currentUser:owner,profile:Record(["display_name":.string("Me Smith")]))
        let c=FilterContext(projects:[project],userID:owner,people:members)
        XCTAssertEqual(Set(c.personReferences.map(\.id)),[owner,mary])
        XCTAssertEqual(ids(try parse("assignee matching: *smith"),[task("owner",owner),task("mary",mary),task("unknown",marc),task("invite",jane)],c),["owner","mary"])
        XCTAssertTrue(ids(try parse("!assigned to:*smith"),[task("unknown",marc)],c).isEmpty)
    }
    func testTheMatchedNameMustBelongToTheTasksProjectDirectory() throws {
        var c = context
        c.projects.append(Record(["id": .string("second"), "name": .string("Second")]))
        c.people.append(person(mary, "Mary Jones", project: "second"))
        let rows = [task("smith", mary), task("jones", mary, project: "second")]
        let rule = try parse("assigned to:M* Smith")
        XCTAssertEqual(ids(rule, rows, c), ["smith"])
        XCTAssertEqual(ids(.not(rule), rows, c), ["jones"])
        let groups = TaskGrouping.queryGroups(rows, rule: .sections([rule, .not(rule)]), by: "none", context: c, today: "2026-10-08", timeZone: "UTC")
        XCTAssertEqual(groups.map { $0.tasks.map(\.id) }, [["smith"], ["jones"]])
        c.people.removeAll { $0.id == mary && $0.string("project_id") == "work" }
        XCTAssertTrue(ids(rule, rows, c).isEmpty)
        XCTAssertEqual(ids(.not(rule), rows, c), ["jones"], "A directory in another project cannot stand in for the missing membership")
    }

    func testMalformedOrOversizedNamesRemainUnavailableUnderNegation() throws {
        let rule = try parse("!assigned to:*")
        for name in ["", "  ", "Mary\nSmith", String(repeating: "x", count: 401)] {
            var c = context; c.people = [person(mary, name)]
            XCTAssertTrue(c.personReferences.isEmpty, name)
            XCTAssertTrue(ids(rule, [task("unavailable", mary)], c).isEmpty)
        }
        var c = context; c.people = [person(mary, String(repeating: "x", count: 400))]
        XCTAssertEqual(c.personReferences.count, 1)
        XCTAssertEqual(ids(try parse("assigned to:*"), [task("bounded", mary)], c), ["bounded"])
    }

    func testOfflinePendingQueryRoundTripPreservesPatternAndUnknownDocument() throws {
        let rule=try parse(#"assignee matching:"M* Smith""#)
        let view=Record(["id":.string("v"),"user_id":.string(owner),"name":.string("People"),"query_ast":rule.document])
        var snapshot=Snapshot();snapshot.tables["saved_views"]=[view];snapshot.pending=[Mutation(table:"saved_views",recordID:view.id,method:"POST",fields:view.fields)]
        let decoded=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.tables["saved_views"],[view]);XCTAssertEqual(decoded.pending[0].fields["query_ast"],rule.document)
        let future=FilterRule.predicate("future_person_scope","*").document
        snapshot.tables["saved_views"]![0]["query_ast"]=future
        let retained=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(retained.tables["saved_views"]![0]["query_ast"],future);XCTAssertThrowsError(try FilterRule(document:future))
    }
}
