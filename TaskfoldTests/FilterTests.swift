import XCTest
@testable import TaskfoldCore

final class FilterTests: XCTestCase {
    let context = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Work")])], sections: [Record(["id": .string("section-id"), "name": .string("Next steps")])], labels: [Record(["id": .string("waiting-id"), "name": .string("waiting")])], userID: "owner")
    func parse(_ input: String, context: FilterContext? = nil) throws -> FilterRule { var parser = try FilterParser(input, context: context ?? self.context); return try parser.parse() }
    func task(_ id: String, _ fields: [String: JSON] = [:]) -> Record { var row = Record(["id": .string(id), "title": .string(id), "completed": .bool(false), "priority": .number(4)]); for (key, value) in fields { row[key] = value }; return row }
    func matches(_ rule: FilterRule, _ row: Record, labels: [FilterReference] = [FilterReference(id: "waiting-id", name: "waiting")], zone: String = "Europe/Copenhagen") -> Bool { rule.matches(row, today: "2026-10-05", userID: "owner", labels: labels, timeZone: zone) }
    func testCommonFilterCorpusAndOperatorPrecedence() throws {
        let rows = [task("overdue", ["due_date": .string("2026-10-04")]), task("today", ["due_date": .string("2026-10-05"), "priority": .number(1)]), task("later", ["due_date": .string("2026-10-06"), "project_id": .string("work-id"), "priority": .number(1)]), task("plain"), task("waiting", ["labels": .array([.string("waiting")])])]
        for (expression, expected) in [("today OR overdue", ["overdue", "today"]), ("project:Work AND p1", ["later"]), (#"no date AND NOT label:"waiting""#, ["plain"]), ("overdue OR today AND p1", ["overdue", "today"]), ("(overdue OR today) AND p1", ["today"]), ("next 2 days", ["today", "later"])] {
            let rule = try parse(expression); XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), expected, expression)
        }
    }
    func testStableTargetsSurviveRenameAndRejectDeletionIncludingNegation() throws {
        let rule = try parse("project:Work AND NOT label:waiting")
        let renamed = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Renamed")])], labels: context.labels)
        XCTAssertNoThrow(try rule.validate(in: renamed)); XCTAssertEqual(try parse(rule.expression(in: renamed), context: renamed), rule)
        XCTAssertThrowsError(try rule.validate(in: FilterContext(projects: renamed.projects)))
        XCTAssertThrowsError(try FilterRule.not(.predicate("project", "missing")).validate(in: context))
    }
    func testQuotedTargetsAndDuplicateNamesRoundTripWithoutRetargeting() throws {
        let weird = Record(["id": .string("weird-id"), "name": .string(#"Work "A" & (B)"#)])
        let c = FilterContext(projects: [weird, Record(["id": .string("first"), "name": .string("Same")]), Record(["id": .string("second"), "name": .string("Same")])])
        for id in [weird.id, "first", "second"] { let rule = FilterRule.predicate("project", id); XCTAssertEqual(try parse(rule.expression(in: c), context: c), rule) }
        XCTAssertThrowsError(try parse("project:Same", context: c))
    }
    func testMalformedExpressionsAndUntrustedDocumentsStayInvalid() throws {
        for expression in ["", "today tomorrow", "today OR", "NOT", "(today", "today)", "p0", "next 0 days", "duration<=0", "deadline:2026-02-30", "assignee:nobody", #"project:"unclosed"#] { XCTAssertThrowsError(try parse(expression), expression) }
        for document: JSON in [.object([:]), .object(["version": .number(2), "root": FilterRule.predicate("all", "").json]), .object(["version": .number(1), "root": .object(["op": .string("all")])])] { XCTAssertThrowsError(try FilterRule(document: document)) }
        XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("and"), "children": .array([])])))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("assignee", "not-an-id").json))
        XCTAssertThrowsError(try parse(String(repeating: "NOT ", count: 25) + "today"))
    }
    func testDeadlinesAreIndependentAndUnknownEstimatesDoNotFitSmallWindow() throws {
        let row = task("report", ["due_date": .string("2026-10-08"), "deadline_date": .string("2026-10-05"), "duration_minutes": .number(25)])
        XCTAssertTrue(matches(try parse("deadline:today AND duration<=25"), row))
        XCTAssertFalse(matches(try parse("today"), row)); XCTAssertFalse(matches(try parse("duration<=10"), row))
        XCTAssertFalse(matches(try parse("duration<=25"), task("unknown")))
        XCTAssertTrue(matches(try parse("no estimate AND no deadline"), task("unknown")))
        XCTAssertTrue(matches(try parse("deadline:next7"), row))
    }
    func testAssignmentUsesCurrentAccountAndCompletionHasExplicitOptIn() throws {
        XCTAssertTrue(matches(try parse("assignee:me"), task("mine", ["assigned_to": .string("owner")])))
        XCTAssertFalse(matches(try parse("assignee:me"), task("other", ["assigned_to": .string("other")])))
        XCTAssertTrue(matches(try parse("assignee:unassigned"), task("none")))
        XCTAssertTrue(try parse("completed OR today").includesCompletion)
        XCTAssertFalse(try parse("today").includesCompletion)
        let cache = TaskCache(); cache.update([task("done", ["completed": .bool(true)]), task("open")])
        var query = TaskQuery(scope: .saved("example")); query.filter = try parse("completed"); query.includeCompleted = true
        XCTAssertEqual(cache.matching(query).map(\.id), ["done"])
    }
    func testFixedPlanFiltersFollowLocalDayWhileFloatingDatesStayPut() throws {
        let fixed = task("fixed", ["due_date": .string("2026-10-05"), "due_time": .string("00:30"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-04T22:30:00Z")])
        let rule = try parse("today")
        XCTAssertTrue(matches(rule, fixed)); XCTAssertFalse(matches(rule, fixed, zone: "America/New_York"))
        XCTAssertTrue(matches(rule, task("floating", ["due_date": .string("2026-10-05"), "due_time": .string("00:30")]), zone: "America/New_York"))
        let cache = TaskCache(); cache.update([fixed]); var query = TaskQuery(scope: .saved("local-day"), today: "2026-10-05"); query.filter = rule; query.timeZone = "America/New_York"
        XCTAssertTrue(cache.matching(query).isEmpty); query.timeZone = "Europe/Copenhagen"; XCTAssertEqual(cache.matching(query).map(\.id), ["fixed"])
    }
    func testCacheIncludesRuleAndReferenceChanges() throws {
        let cache = TaskCache(); cache.update([task("one", ["labels": .array([.string("waiting")])]), task("two")])
        var query = TaskQuery(scope: .saved("example")); query.filter = try parse("label:waiting"); query.filterLabels = [FilterReference(id: "waiting-id", name: "waiting")]
        XCTAssertEqual(cache.matching(query).map(\.id), ["one"])
        query.filterLabels = [FilterReference(id: "waiting-id", name: "renamed")]; XCTAssertTrue(cache.matching(query).isEmpty)
        query.filter = try parse("no date"); XCTAssertEqual(cache.matching(query).count, 2)
    }
    func testOrganizationRecordsAndOfflineQueueSurviveAccountCacheRoundTrip() throws {
        let rule = try parse("today OR overdue")
        let view = Record(["id": .string("filter-id"), "user_id": .string("owner"), "name": .string("Focus"), "query_ast": rule.document, "layout": .string("board"), "grouping": .string("priority")])
        let records = ["saved_views": [view], "favorites": [Record(["id": .string("view:filter-id"), "user_id": .string("owner"), "order_index": .number(0)])], DayPlacement.table: [Record(["id": .string("scope:view:filter-id:group:all"), "user_id": .string("owner"), "ids": .array([.string("b"), .string("a")])])]]
        let queue = records.flatMap { table, rows in rows.map { Mutation(table: table, recordID: $0.id, method: "POST", fields: $0.fields) } }
        let snapshot = Snapshot(tables: records, pending: queue)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)); XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(try FilterRule(document: decoded.tables["saved_views"]![0]["query_ast"]), rule)
        XCTAssertEqual(TaskScope(preferenceKey: "view:filter-id"), .saved("filter-id")); XCTAssertNil(TaskScope(preferenceKey: "view:"))
        XCTAssertEqual(DayPlacement.table, "view_orders")
    }
    func testCaptureDefaultsStayConservativeAcrossBooleanConditions() throws {
        let work = try parse("project:Work AND p1 AND today AND label:waiting")
        let defaults = work.captureDefaults(in: context, today: "2026-10-05")
        XCTAssertEqual(defaults["project_id"], .string("work-id")); XCTAssertEqual(defaults["priority"], .number(1)); XCTAssertEqual(defaults["due_date"], .string("2026-10-05")); XCTAssertEqual(defaults["labels"], .array([.string("waiting")]))
        XCTAssertTrue(try parse("today OR overdue").captureDefaults(in: context, today: "2026-10-05").isEmpty)
        XCTAssertNil(try parse("duration<=25 AND next 7 days").captureDefaults(in: context, today: "2026-10-05")["duration_minutes"])
        XCTAssertNil(try parse("p1 AND p2").captureDefaults(in: context, today: "2026-10-05")["priority"])
        XCTAssertEqual(try parse("(project:Work AND today) OR (project:Work AND overdue)").captureDefaults(in: context, today: "2026-10-05"), ["project_id": .string("work-id")])
    }
    func testGroupingHasStableIDsAcrossProjectRenameAndUnknownDates() {
        let rows = [task("one", ["project_id": .string("work-id")]), task("two")]
        let before = TaskGrouping.groups(rows, by: "project", projects: context.projects)
        let after = TaskGrouping.groups(rows, by: "project", projects: [Record(["id": .string("work-id"), "name": .string("Renamed")])])
        XCTAssertEqual(before.map(\.id), after.map(\.id)); XCTAssertEqual(after.first(where: { $0.id == "project:work-id" })?.name, "Renamed")
        XCTAssertEqual(TaskGrouping.groups(rows, by: "deadline", projects: []).first?.name, "No deadline")
    }
    func testKeywordSearchUsesEveryWordAcrossTitleAndDescriptionWithInvariantFolding() throws {
        let rule = try parse("search: EMAIL cafe")
        var row = task("Cafe meeting", ["description": .string("Send the email agenda")])
        XCTAssertTrue(matches(rule, row))
        row["title"] = .string("CAFÉ MEETING"); XCTAssertTrue(matches(rule, row))
        row["description"] = .string("Email goes here"); XCTAssertTrue(matches(try parse("search: café email"), row))
        XCTAssertFalse(matches(try parse("search: email missing"), row))
        row["description"] = .string(""); row["comments"] = .array([.object(["text": .string("email")])])
        XCTAssertFalse(matches(rule, row), "Comments are outside the keyword condition")
        XCTAssertTrue(matches(try parse("search: http"), task("Read https://example.com")))
        XCTAssertFalse(matches(.predicate("search", "\u{301}"), task("Any title")), "A word folded to empty must not match everything")
        XCTAssertFalse(matches(.predicate("search", "email \u{301}"), task("Send email")), "Every requested word must stay meaningful after folding")
    }
    func testSearchQuotedOperatorWordsAndPunctuationKeepTheirLiteralMeaning() throws {
        for value in ["AND OR NOT", "& | ! ( )", #"quote \" and \\ path"#, "meeting,today", "send\nemail"] {
            let rule = FilterRule.predicate("search", value)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertTrue(matches(rule, task(value)), value)
        }
        for value in ["\u{301}", "email \u{301}"] {
            let rule = FilterRule.predicate("search", value)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule, "Quotes must survive adjacent combining scalars")
            XCTAssertFalse(matches(rule, task("Send email")), "Literal combining terms must not disappear from a query")
        }
        XCTAssertEqual(try parse("search: email \u{301}"), .predicate("search", "email \u{301}"), "Whitespace must not consume adjacent accents")
        XCTAssertEqual(try parse(#"search: "AND" & no labels"#), .and([.predicate("search", "AND"), .predicate("no_labels", "")]))
        XCTAssertEqual(try parse(#"search:"OR" OR recurring"#), .or([.predicate("search", "OR"), .predicate("recurring", "")]))
        XCTAssertEqual(try parse("search: send email & p1 | recurring"), .or([.and([.predicate("search", "send email"), .predicate("priority", "1")]), .predicate("recurring", "")]))
    }
    func testSearchRejectsEmptyOverlongAndMalformedQueriesWithoutMergingSections() throws {
        for expression in ["search:", #"search:"""#, "search: & today", "search: AND", "search:" + String(repeating: "x", count: 401), "search: Meeting, today", #"search:"unterminated"#] {
            XCTAssertThrowsError(try parse(expression), expression)
        }
        XCTAssertNoThrow(try parse("search:" + String(repeating: "x", count: 400)))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("search", " \n\t").json))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("search", String(repeating: "e\u{301}", count: 201)).json))
        XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string("search"), "value": .number(1)])))
        XCTAssertThrowsError(try parse("today, overdue")) { XCTAssertTrue($0.localizedDescription.contains("separate filters")) }
    }
    func testTimeLabelsAndRecurrenceAreIndependentMetadataConditions() throws {
        let plain = task("plain"), allDay = task("day", ["due_date": .string("2026-10-05")]), timed = task("timed", ["due_date": .string("2026-10-05"), "due_time": .string("00:00:00")]), labelled = task("labelled", ["labels": .array([.string("waiting-id")])]), repeating = task("repeat", ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")])])
        XCTAssertTrue(matches(try parse("no time"), plain)); XCTAssertTrue(matches(try parse("no time"), allDay)); XCTAssertFalse(matches(try parse("no time"), timed))
        XCTAssertTrue(matches(try parse("no labels"), plain)); XCTAssertFalse(matches(try parse("no labels"), labelled))
        XCTAssertFalse(matches(try parse("recurring"), plain)); XCTAssertTrue(matches(try parse("recurring"), repeating))
        XCTAssertTrue(matches(try parse("!recurring & !no time"), timed))
        XCTAssertFalse(matches(try parse("!recurring"), repeating))
        for field in ["recurring", "no_time", "no_labels"] {
            for value in [JSON.string("unexpected"), .number(1), .bool(false), .null, .object([:]), .array([])] {
                XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string(field), "value": value])))
            }
        }
        XCTAssertEqual(try parse("no priority"), .predicate("priority", "4"))
    }
    func testProjectAndLabelShorthandsKeepStableTargetsIncludingQuotedNames() throws {
        XCTAssertEqual(try parse("#Work & %waiting"), try parse("project:Work AND label:waiting"))
        XCTAssertEqual(try parse("#Work & @waiting"), try parse("project:Work AND label:waiting"))
        XCTAssertEqual(try parse("#Inbox"), .predicate("inbox", ""))
        let weird = Record(["id": .string("weird"), "name": .string("A & B, OR")])
        let c = FilterContext(projects: [weird], labels: [weird])
        XCTAssertEqual(try parse(#"#"A & B, OR" | %"A & B, OR""#, context: c), .or([.predicate("project", "weird"), .predicate("label", "weird")]))
        let leading = Record(["id": .string("leading-mark"), "name": .string("\u{301}Name")])
        let leadingContext = FilterContext(projects: [leading], labels: [leading])
        for (prefix, field) in [("#", "project"), ("%", "label"), ("@", "label")] {
            let query = prefix + "\"" + leading.name + "\""
            let rule = try parse(query, context: leadingContext)
            XCTAssertEqual(rule, .predicate(field, leading.id))
            XCTAssertEqual(try parse(rule.expression(in: leadingContext), context: leadingContext), rule)
        }
        let rule = try parse("#Work & !%waiting")
        let renamed = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Renamed")])], labels: context.labels)
        XCTAssertNoThrow(try rule.validate(in: renamed)); XCTAssertEqual(try parse(rule.expression(in: renamed), context: renamed), rule)
        XCTAssertThrowsError(try rule.validate(in: FilterContext(projects: renamed.projects)))
        for expression in ["#missing", "%missing", "#", "%", "@", "#Work*", "%wait*"] { XCTAssertThrowsError(try parse(expression), expression) }
    }
    func testNewConditionsRoundTripWithoutInventingCaptureSettings() throws {
        let rule = try parse(#"search:"send email" & no time & no labels & recurring & #Work"#)
        XCTAssertEqual(try FilterRule(document: rule.document), rule)
        XCTAssertEqual(try parse(rule.expression(in: context)), rule)
        XCTAssertEqual(rule.captureDefaults(in: context, today: "2026-10-05"), ["project_id": .string("work-id")])
        XCTAssertTrue(try parse("no time OR recurring").captureDefaults(in: context, today: "2026-10-05").isEmpty)
        XCTAssertThrowsError(try FilterRule(document: .object(["version": .number(1), "root": FilterRule.predicate("future_field", "").json])))
    }
    func testNewFilterPredicatesInvalidateTaskCacheWhenInputsChange() throws {
        let cache = TaskCache(); var row = task("Send email", ["description": .string("Café agenda")])
        cache.update([row]); var query = TaskQuery(scope: .saved("example")); query.filter = try parse("search: cafe email & no time & no labels & !recurring")
        XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        for (field, value) in [("description", JSON.string("Agenda")), ("due_time", .string("09:00")), ("labels", .array([.string("waiting")])), ("is_recurring", .bool(true))] {
            var changed = row; changed[field] = value; cache.update([changed]); XCTAssertTrue(cache.matching(query).isEmpty, field)
            cache.update([row]); XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        }
        row["description"] = .string("Café email"); row["title"] = .string("Other"); cache.update([row]); XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
    }
    func testNewQueryFieldsSurviveOfflineWireAndAccountCacheEncoding() throws {
        let rule = try parse("search: email & no time & no labels & recurring")
        let row = Record(["id": .string("filter-id"), "user_id": .string("owner"), "name": .string("Email review"), "query_ast": rule.document])
        let mutation = Mutation(table: "saved_views", recordID: row.id, method: "POST", fields: row.fields)
        let original = Snapshot(tables: ["saved_views": [row]], pending: [mutation])
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original); XCTAssertEqual(restored.pending[0].fields["query_ast"], rule.document)
        XCTAssertEqual(try FilterRule(document: restored.tables["saved_views"]![0]["query_ast"]), rule)
    }
}

final class OrganizationTransportTests: XCTestCase {
    @MainActor func testNewQueryPredicatesSurviveAuthenticatedRESTBodyAndRepresentation() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"fixture","refresh_token":"refresh","expires_in":3600,"user":{"id":"owner"}}"#.utf8))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var parser = try FilterParser(#"search:"café email" & recurring & no time & no labels"#, context: FilterContext())
        let rule = try parser.parse()
        let row = Record(["id": .string("filter-id"), "user_id": .string("owner"), "name": .string("Email review"), "query_ast": rule.document])
        var requests = 0
        AuthTransportTests.Stub.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/rest/v1/saved_views")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            if request.httpMethod == "POST" {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "id")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=representation")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                }
                let sent = try JSONDecoder().decode(Record.self, from: data)
                XCTAssertEqual(sent, row); XCTAssertEqual(try FilterRule(document: sent["query_ast"]), rule)
            } else { XCTAssertEqual(request.httpMethod, "GET") }
            return (200, try JSONEncoder().encode([row]))
        }
        defer { AuthTransportTests.Stub.handler = nil }
        let response = try await backend.send(Mutation(table: "saved_views", recordID: row.id, method: "POST", fields: row.fields), expectedAccount: "owner")
        let saved = try XCTUnwrap(response)
        XCTAssertEqual(saved, row)
        let rows = try await backend.rows("saved_views")
        XCTAssertEqual(rows, [row]); XCTAssertEqual(try FilterRule(document: rows[0]["query_ast"]), rule); XCTAssertEqual(requests, 2)
    }

    @MainActor func testCompositeUpsertsAndEscapedStableKeysUseAuthenticatedRequests() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"fixture","refresh_token":"refresh","expires_in":3600,"user":{"id":"owner"}}"#.utf8))
        let backend = Backend(configuration: ["URL":"https://native-auth.test", "Key":"public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        for table in ["favorites", "view_preferences", "view_orders"] {
            let key = "scope:view:filter/group:all & done"
            AuthTransportTests.Stub.handler = { request in
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/rest/v1/" + table)
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "user_id,id")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=representation")
                return (200, try JSONEncoder().encode([Record(["id": .string(key), "user_id": .string("owner")])]))
            }
            try await backend.send(Mutation(table: table, recordID: key, method: "POST", fields: ["id": .string(key), "user_id": .string("owner")]))
            AuthTransportTests.Stub.handler = { request in
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "eq." + key)
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)
                return (200, Data("[]".utf8))
            }
            try await backend.send(Mutation(table: table, recordID: key, method: "DELETE", fields: [:]))
        }
        AuthTransportTests.Stub.handler = { _ in (200, Data("[]".utf8)) }
        do { try await backend.send(Mutation(table: "favorites", recordID: "missing", method: "PATCH", fields: ["order_index": .number(1)])); XCTFail("Empty representation must retain the offline mutation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
    }

}
