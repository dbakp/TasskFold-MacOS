import XCTest
@testable import TaskfoldCore

final class QuickEntryReferencesTests: XCTestCase {
    private func row(_ id: String, _ name: String, project: String = "") -> Record {
        Record(["id": .string(id), "name": .string(name), "project_id": .string(project)])
    }
    private func person(_ id: String, _ name: String, status: String = "accepted") -> Record {
        Record(["id": .string(id), "display_name": .string(name), "status": .string(status)])
    }
    private var context: QuickEntryContext {
        QuickEntryContext(projects: [row("work", "Client Work"), row("home", "Home")],
            sections: [row("next", "Next steps", project: "work"), row("home-next", "Next steps", project: "home")],
            labels: [row("client-label", "Client notes")], members: ["work": [person("alex", "Alex Morgan"), person("self", "Morgan Lee")]],
            currentUser: "self")
    }
    func testQuotedReferencesAndPlanningResolveTogether() {
        let parsed = QuickEntry(#"Draft proposal #"Client Work" /"Next steps" +Alex @"Client notes" tomorrow p2 ~25m {2026-10-09}"#,
            now: Dates.parse("2026-10-05")!, context: context)
        XCTAssertEqual(parsed.title, "Draft proposal")
        XCTAssertEqual(parsed.updates["project_id"], .string("work"))
        XCTAssertEqual(parsed.updates["section_id"], .string("next"))
        XCTAssertEqual(parsed.updates["assigned_to"], .string("alex"))
        XCTAssertEqual(parsed.updates["labels"], .array([.string("Client notes")]))
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(parsed.updates["duration_minutes"], .number(25))
        XCTAssertEqual(parsed.updates["deadline_date"], .string("2026-10-09"))
        XCTAssertTrue(parsed.warnings.isEmpty)
        XCTAssertEqual(parsed.applying(to: Record.task(user: "self"))["labels"], .array([.string("client-label")]))
    }
    func testUnknownExplicitTargetsCannotTurnIntoPlanningFields() {
        let parsed = QuickEntry("Write #project:tomorrow /p1 +tomorrow", context: context)
        XCTAssertEqual(parsed.title, "Write #project:tomorrow /p1 +tomorrow")
        XCTAssertTrue(parsed.updates.isEmpty)
        XCTAssertFalse(parsed.warnings.isEmpty)
    }
    func testProjectLabelCollisionRequiresExplicitChoiceAndLegacyLabelsRemain() {
        var ctx = context; ctx.labels.append(row("home-label", "Home"))
        let collision = QuickEntry("Tidy #Home", context: ctx)
        XCTAssertEqual(collision.title, "Tidy #Home"); XCTAssertTrue(collision.updates.isEmpty)
        XCTAssertEqual(collision.warnings.count, 1)
        let explicit = QuickEntry("Tidy #project:Home @Home #errands %mail", context: ctx)
        XCTAssertEqual(explicit.title, "Tidy")
        XCTAssertEqual(explicit.updates["project_id"], .string("home"))
        XCTAssertEqual(explicit.updates["labels"], .array([.string("Home"), .string("errands"), .string("mail")]))
    }
    func testAmbiguousOrMultipleProjectsNeverChooseFirst() {
        var ctx = context; ctx.projects.append(row("work-2", "Client Work"))
        let duplicate = QuickEntry(#"Write #"Client Work" /"Next steps" +Alex"#, context: ctx)
        XCTAssertTrue(duplicate.updates.isEmpty)
        XCTAssertFalse(duplicate.warnings.isEmpty)
        let multiple = QuickEntry(#"Write #"Client Work" #Home"#, context: context)
        XCTAssertTrue(multiple.updates.isEmpty)
    }
    func testSectionsAreScopedToTheSelectedProject() {
        var ctx = context; ctx.currentProject = "home"
        XCTAssertEqual(QuickEntry(#"Tidy /"Next steps""#, context: ctx).updates["section_id"], .string("home-next"))
        let noProject = QuickEntry(#"Tidy /"Next steps""#, context: context)
        XCTAssertNil(noProject.updates["section_id"]); XCTAssertFalse(noProject.warnings.isEmpty)
    }
    func testAssigneesAreScopedAndAmbiguousNamesOrPendingInvitesStayLiteral() {
        var ctx = context; ctx.currentProject = "work"
        XCTAssertEqual(QuickEntry("Draft +me", context: ctx).updates["assigned_to"], .string("self"))
        ctx.members["work"]?.append(person("alex-2", "Alex Chen"))
        ctx.members["work"]?.append(person("pending", "Pat", status: "pending"))
        XCTAssertNil(QuickEntry("Draft +Alex", context: ctx).updates["assigned_to"])
        XCTAssertEqual(QuickEntry(#"Draft +"Alex Morgan""#, context: ctx).updates["assigned_to"], .string("alex"))
        XCTAssertNil(QuickEntry("Draft +Pat", context: ctx).updates["assigned_to"])
        ctx.currentProject = "home"
        XCTAssertNil(QuickEntry("Draft +Alex", context: ctx).updates["assigned_to"])
    }
    func testDeclinedProjectAlsoKeepsDependentTargetsAndNeverBecomesALabel() {
        let input = #"Draft #"Client Work" /"Next steps" +Alex tomorrow"#
        let parsed = QuickEntry(input, now: Dates.parse("2026-10-05")!, disabled: ["project_id"], context: context)
        XCTAssertEqual(parsed.title, #"Draft #"Client Work" /"Next steps" +Alex"#)
        XCTAssertNil(parsed.updates["project_id"]); XCTAssertNil(parsed.updates["section_id"])
        XCTAssertNil(parsed.updates["assigned_to"]); XCTAssertNil(parsed.updates["labels"])
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-06"))
        let all = QuickEntry(input, disabled: Set(QuickEntry.groups), context: context)
        XCTAssertEqual(all.title, input); XCTAssertTrue(all.updates.isEmpty)
    }
    func testEscapedAndQuotedLiteralsAndNonReferenceBoundaries() {
        let escaped = QuickEntry(##"Write \#"Client Work" \/"Next steps" \+Alex \@"Client notes""##, context: context)
        XCTAssertEqual(escaped.title, #"Write #"Client Work" /"Next steps" +Alex @"Client notes""#)
        XCTAssertTrue(escaped.updates.isEmpty)
        XCTAssertTrue(QuickEntry(##"Write "#Home +Alex tomorrow p1""##, context: context).updates.isEmpty)
        let literal = "Use https://example.com/#Home /tmp/file #Client/Next C++ mail+Alex@example.com"
        XCTAssertEqual(QuickEntry(literal, context: context).title, literal)
        XCTAssertTrue(QuickEntry(literal, context: context).updates.isEmpty)
        XCTAssertEqual(QuickEntry("Look at").title, "Look at")
    }
    func testMovingProjectsClearsOldAssignmentsAndMergesLabelsWithoutDuplicateIDs() {
        var task = Record.task(user: "self", project: "home")
        task["section_id"] = .string("home-next"); task["assigned_to"] = .string("old")
        task["deadline_date"] = .string("2026-10-09"); task["duration_minutes"] = .number(25)
        task["labels"] = .array([.string("client-label"), .string("keep")])
        task["subtasks"] = .array([.object(["title": .string("Child"), "assigned_to": .string("old")])])
        let result = QuickEntry(#"Draft #"Client Work" /"Next steps" +Alex @"client notes""#, context: context).applying(to: task)
        XCTAssertEqual(result.string("project_id"), "work"); XCTAssertEqual(result.string("section_id"), "next")
        XCTAssertEqual(result.string("assigned_to"), "alex"); XCTAssertEqual(result["subtasks"].list[0].object["assigned_to"], .null)
        XCTAssertEqual(result["labels"], task["labels"])
        XCTAssertEqual(result["deadline_date"], task["deadline_date"]); XCTAssertEqual(result["duration_minutes"], task["duration_minutes"])
        let withoutDestination = QuickEntry(#"Draft #"Client Work""#, context: context).applying(to: task)
        XCTAssertEqual(withoutDestination["section_id"], .null); XCTAssertEqual(withoutDestination["assigned_to"], .null)
    }
    func testDuplicateTokensHaveStableUniqueIdentifiers() {
        let parsed = QuickEntry("Draft @mail @mail %mail #errands", context: context)
        XCTAssertEqual(parsed.title, "Draft")
        XCTAssertEqual(parsed.updates["labels"], .array([.string("mail"), .string("errands")]))
        XCTAssertEqual(Set(parsed.tokens.map(\.id)).count, parsed.tokens.count)
    }
    func testLabelNormalizationIsStableAcrossRenameAndKeepsUnknownLegacyValues() {
        let labels = [row("id-one", "Client notes"), row("id-two", "Other")]
        let normalized = TaskLabels.normalized([.string("Client notes"), .string("id-one"), .string("legacy"), .object(["old": .bool(true)])], labels: labels)
        XCTAssertEqual(normalized, [.string("id-one"), .string("legacy"), .object(["old": .bool(true)])])
        var renamed = labels; renamed[0]["name"] = .string("Renamed")
        XCTAssertEqual(TaskLabels.normalized(normalized, labels: renamed), normalized)
        XCTAssertEqual(TaskLabels.normalized(normalized, labels: []), normalized)
        XCTAssertEqual(TaskLabels.normalized([.string("duplicate")], labels: [row("a", "duplicate"), row("b", "duplicate")]), [.string("duplicate")])
    }
    func testLabelNamesAndIDsRemainDistinctDuringReferenceResolution() {
        var ctx = context
        XCTAssertTrue(QuickEntry("Draft @client-label", context: ctx).updates.isEmpty)
        ctx.labels.append(row("another", "client-label"))
        var task = Record.task(user: "self"); task["labels"] = .array([.string("client-label")])
        let result = QuickEntry("Draft @client-label", context: ctx).applying(to: task)
        XCTAssertEqual(result["labels"], .array([.string("client-label"), .string("another")]))
    }
}


final class QuickEntryRemindersTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return result
    }
    private var now: Date { TaskPlanning.instant("2026-10-06T10:00:00Z")! }
    private func parse(_ text: String, disabled: Set<String> = [], task: Record = Record()) -> QuickEntry {
        QuickEntry(text, now: now, calendar: calendar, disabled: disabled, task: task)
    }
    private func specs(_ parsed: QuickEntry, task: Record = Record()) -> [ReminderSpec] {
        ReminderSpec.rows(parsed.applying(to: task)).compactMap(ReminderSpec.init(row:))
    }
    func testFromNowAndBeforeRemainIndependentOfTaskDateTime() {
        let parsed = parse("Call tomorrow at 4pm !30m !30mb p1")
        XCTAssertEqual(parsed.title, "Call"); XCTAssertEqual(parsed.updates["due_time"], .string("16:00"))
        XCTAssertEqual(parsed.updates["priority"], .number(1)); XCTAssertEqual(parsed.tokens.filter { $0.group.hasPrefix("reminder_specs") }.count, 2)
        let values = specs(parsed)
        XCTAssertEqual(values.count, 3); XCTAssertEqual(values.first?.id, ReminderSpec.plannedID)
        XCTAssertEqual(values.first { $0.kind == "absolute" }?.absolute, now.addingTimeInterval(1800))
        XCTAssertEqual(values.first { $0.offset == -30 }?.offset, -30)
        var task = parsed.applying(to: Record()); let before = DueReminder.events(tasks: [task], calendar: calendar)
        task["due_date"] = .string("2026-10-09")
        let after = DueReminder.events(tasks: [task], calendar: calendar)
        XCTAssertEqual(before.first { $0.specID == values[1].id }?.date, after.first { $0.specID == values[1].id }?.date)
        XCTAssertNotEqual(before.first { $0.specID == values[2].id }?.date, after.first { $0.specID == values[2].id }?.date)
    }
    func testCompoundMinutesUnitsAfterAndZeroBefore() {
        let parsed = parse("Call tomorrow !2h30m !1h before !45min after !0mb")
        XCTAssertEqual(parsed.title, "Call"); XCTAssertTrue(parsed.warnings.isEmpty)
        let values = specs(parsed)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values.filter { $0.id == ReminderSpec.plannedID }.count, 1)
        XCTAssertEqual(values.first { $0.kind == "absolute" }?.absolute, now.addingTimeInterval(9000))
        XCTAssertTrue(values.contains { $0.offset == -60 }); XCTAssertTrue(values.contains { $0.offset == 45 })
        XCTAssertEqual(specs(parse("Call !1d")).last?.absolute, now.addingTimeInterval(86400))
    }
    func testAbsoluteReminderDateNeverBecomesPlannedDateOrRecurrence() {
        for syntax in ["!tomorrow 3pm", "!tmr at 15:00", "!2026-10-07 15:00", "!wed 3pm"] {
            let parsed = parse("Call " + syntax)
            XCTAssertEqual(parsed.title, "Call", syntax); XCTAssertNil(parsed.updates["due_date"], syntax)
            XCTAssertNil(parsed.updates["due_time"], syntax); XCTAssertNil(parsed.updates["is_recurring"], syntax)
            XCTAssertEqual(specs(parsed).last?.absolute, TaskPlanning.instant("2026-10-07T13:00:00Z"), syntax)
        }
        XCTAssertEqual(specs(parse("Call !tomorrow")).last?.absolute, TaskPlanning.instant("2026-10-07T07:00:00Z"))
    }
    func testBareClockUsesNextOccurrenceAndLaterUsesElapsedTime() {
        XCTAssertEqual(specs(parse("Call !11am")).last?.absolute, TaskPlanning.instant("2026-10-07T09:00:00Z"))
        XCTAssertEqual(specs(parse("Call !6pm")).last?.absolute, TaskPlanning.instant("2026-10-06T16:00:00Z"))
        XCTAssertEqual(specs(parse("Call !later")).last?.absolute, now.addingTimeInterval(14400))
        XCTAssertEqual(specs(parse("Call !12am")).last?.absolute, TaskPlanning.instant("2026-10-06T22:00:00Z"))
    }
    func testDeclineOneReminderProtectsItsTimeAndOtherRemindersRemain() {
        let text = "Call tomorrow at 4pm !30mb !tomorrow 9am"
        let declined = parse(text).tokens.filter { $0.group.hasPrefix("reminder_specs") }[1].group
        let parsed = parse(text, disabled: [declined])
        XCTAssertEqual(parsed.title, "Call !tomorrow 9am")
        XCTAssertEqual(parsed.updates["due_time"], .string("16:00")); XCTAssertEqual(specs(parsed).count, 2)
        XCTAssertTrue(parsed.warnings.isEmpty)
        XCTAssertEqual(parse("Call !tomorrow 9am", disabled: [declined]).title, "Call !tomorrow 9am")
        let all = parse(text, disabled: ["reminder_specs"])
        XCTAssertEqual(all.title, "Call !30mb !tomorrow 9am"); XCTAssertNil(all.updates["reminder_specs"])
    }
    func testEscapingQuotesAndNonTokenBoundariesRemainLiteral() {
        let input = #"Write \!tomorrow "!today 3pm" URL https://host/!tomorrow email!30m"#
        let parsed = parse(input)
        XCTAssertEqual(parsed.title, #"Write !tomorrow "!today 3pm" URL https://host/!tomorrow email!30m"#)
        XCTAssertTrue(parsed.updates.isEmpty); XCTAssertTrue(parsed.warnings.isEmpty)
    }
    func testEscapedMultiwordReminderCannotBecomeTaskTime() {
        for expression in [#"\!tomorrow 3pm"#, #"\!MON 9AM"#, #"\!1h before"#, #"\!every sat 9am"#] {
            let parsed = parse("Literal " + expression)
            XCTAssertEqual(parsed.title, "Literal " + String(expression.dropFirst()), expression)
            XCTAssertTrue(parsed.updates.isEmpty, expression); XCTAssertTrue(parsed.warnings.isEmpty, expression)
        }
    }
    func testUnsupportedReminderRestoresNestedProtectedProse() {
        let input = #"Call !every day "tomorrow p1" https://host/tomorrow !25:60"#
        let parsed = parse(input)
        XCTAssertEqual(parsed.title, input); XCTAssertTrue(parsed.updates.isEmpty)
        XCTAssertFalse(parsed.title.contains("\u{E000}")); XCTAssertFalse(parsed.title.contains("\u{E004}"))
    }
    func testInvalidReminderIsProtectedAndNeverSchedulesTheTask() {
        for expression in ["!0m", "!25:60", "!13pm", "!0am", "!2026-02-30 3pm", "!today 9am", "!10081mb", "!99999999999999999999h", "!every sat 9am", "!every 2 hours", "!nonsense"] {
            let parsed = parse("Call " + expression)
            XCTAssertEqual(parsed.title, "Call " + expression, expression); XCTAssertTrue(parsed.updates.isEmpty, expression)
            XCTAssertFalse(parsed.warnings.isEmpty, expression)
        }
        let parsed = parse("Call tomorrow at 4pm !25:60 p2")
        XCTAssertEqual(parsed.title, "Call !25:60"); XCTAssertEqual(parsed.updates["due_time"], .string("16:00"))
        XCTAssertEqual(parsed.updates["priority"], .number(2))
    }
    func testDuplicatesStayLiteralWithUsefulWarningAndStableIDs() {
        let first = parse("Call tomorrow !30mb !30min before !0mb !0min before")
        XCTAssertEqual(first.title, "Call !30min before !0min before")
        XCTAssertEqual(first.warnings.count, 2); XCTAssertEqual(specs(first).count, 2)
        XCTAssertEqual(first.updates, parse("Call tomorrow !30mb !30min before !0mb !0min before").updates)
        XCTAssertEqual(Set(first.tokens.map(\.id)).count, first.tokens.count)
    }
    func testExistingRowsUnknownFieldsAndOptOutSurviveEditingAndApplying() {
        var task = Record.task(user: "owner")
        let unknown: JSON = .object(["version": .number(2), "id": .string(UUID().uuidString.lowercased()), "future": .bool(true)])
        var off = ReminderSpec.relative(0, id: ReminderSpec.plannedID, enabled: false).raw; off["extra"] = .string("keep")
        task["reminder_specs"] = .array([.object(off), unknown])
        let parsed = parse("Call !30m", task: task)
        let result = parsed.applying(to: task)
        XCTAssertEqual(Array(result["reminder_specs"].list.prefix(2)), [.object(off), unknown])
        XCTAssertFalse(ReminderSpec.plannedEnabled(result)); XCTAssertEqual(result["reminder_specs"].list.count, 3)
        let enable = parse("Call tomorrow !0mb", task: task).applying(to: task)
        XCTAssertTrue(ReminderSpec.plannedEnabled(enable)); XCTAssertEqual(enable["reminder_specs"].list[0].object["extra"], .string("keep"))
    }
    func testMaximumAndReapplyingDoNotDropAcceptedTextOrExistingRows() {
        var task = Record.task(user: "owner", date: now)
        task["reminder_specs"] = .array((0..<20).map { .object(ReminderSpec.relative($0).raw) })
        let parsed = parse("Call !30mb", task: task)
        XCTAssertEqual(parsed.title, "Call !30mb"); XCTAssertEqual(parsed.warnings.count, 1)
        XCTAssertEqual(parsed.applying(to: task)["reminder_specs"], task["reminder_specs"])
        let empty = parse("Call !30mb")
        let applied = empty.applying(to: task)
        XCTAssertEqual(applied.title, "Call !30mb"); XCTAssertEqual(applied["reminder_specs"], task["reminder_specs"])
    }
    func testRelativeUndatedWaitsAndDateOnlyUsesEightAM() {
        let parsed = parse("Call !30mb")
        XCTAssertEqual(parsed.warnings, ["Relative reminders wait for a planned date. Date-only tasks use 8 AM."])
        XCTAssertTrue(DueReminder.events(tasks: [parsed.applying(to: Record())], calendar: calendar).isEmpty)
        let dated = parse("Call tomorrow !30mb").applying(to: Record())
        XCTAssertEqual(DueReminder.events(tasks: [dated], calendar: calendar).first?.date, TaskPlanning.instant("2026-10-07T05:30:00Z"))
    }
    func testRecurringTaskRetainsRelativeAndDropsOneOffShortcutReminder() {
        let parsed = parse("Call every day at 4pm !30mb !2h")
        XCTAssertEqual(parsed.title, "Call"); XCTAssertEqual(parsed.updates["is_recurring"], .bool(true))
        let values = ReminderSpec.successorRows(ReminderSpec.rows(parsed.applying(to: Record())))
        XCTAssertEqual(values.compactMap(ReminderSpec.init(row:)).map(\.kind), ["relative", "relative"])
    }
    func testCalendarZoneAndDSTResolveAbsoluteOnce() {
        let spring = TaskPlanning.instant("2027-03-27T12:00:00Z")!
        let parsed = QuickEntry("Call !tomorrow 2:30am", now: spring, calendar: calendar)
        let spec = specs(parsed).last!
        XCTAssertEqual(spec.absolute, TaskPlanning.instant("2027-03-28T01:00:00Z"))
        XCTAssertEqual(spec.raw["time_zone"], .string("Europe/Copenhagen"))
        var travel = calendar; travel.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(DueReminder.events(tasks: [parsed.applying(to: Record())], calendar: travel).last?.date, spec.absolute)
    }
}
