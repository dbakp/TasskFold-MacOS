import XCTest
@testable import TaskfoldCore

final class RecurrenceTests: XCTestCase {
    private func calendar(_ zone: String = "Europe/Copenhagen") -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    private func date(_ day: String, _ zone: String = "Europe/Copenhagen") -> Date { Dates.parse(day, calendar: calendar(zone))! }
    private func task(_ day: String, _ rule: [String: JSON]) -> Record {
        Record(["id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "user_id": .string("owner"), "title": .string("Review"), "due_date": .string(day), "is_recurring": .bool(true), "recurrence_pattern": .object(rule), "completed": .bool(false), "completed_at": .null])
    }
    private func quick(_ value: String, day: String = "2026-10-06", disabled: Set<String> = []) -> QuickEntry { QuickEntry(value, now: date(day).addingTimeInterval(12*3600), calendar: calendar(), disabled: disabled) }
    func testWeekdaySetsAndMultiWeekIntervalsHaveOneRuleAndCleanTitle() {
        let p = quick("Review every 2 weeks on mon, wed and fri until 2026-12-31 for 7 occurrences at 9am !30mb p2 ~25m")
        XCTAssertEqual(p.title, "Review"); XCTAssertTrue(p.warnings.isEmpty)
        let r = Record(p.updates["recurrence_pattern"]!.object)
        XCTAssertEqual(r.string("type"), "weekly"); XCTAssertEqual(r["interval"], .number(2)); XCTAssertEqual(r["daysOfWeek"], .array([.number(1),.number(3),.number(5)]))
        XCTAssertEqual(r["count"], .number(7)); XCTAssertEqual(r.string("endDate"), "2026-12-31")
        XCTAssertEqual(p.updates["due_date"], .string("2026-10-07")); XCTAssertEqual(p.updates["due_time"], .string("09:00"))
        XCTAssertEqual(p.updates["duration_minutes"], .number(25)); XCTAssertEqual(p.updates["priority"], .number(2)); XCTAssertEqual(p.updates["reminder_specs"]?.list.filter { $0.object["offset_minutes"] == .number(-30) }.count, 1)
        XCTAssertEqual(p.tokens.filter { $0.group == "recurrence" }.count, 1)
    }
    func testWorkdayWeekendAndSingleWeekdayStartsAreExplicit() {
        XCTAssertEqual(quick("Review every weekday").updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(quick("Review every weekend").updates["due_date"], .string("2026-10-10"))
        XCTAssertEqual(quick("Review every tuesday").updates["due_date"], .string("2026-10-13"))
        XCTAssertEqual(quick("Review every tuesday starting 2026-10-06").updates["due_date"], .string("2026-10-06"))
    }
    func testMonthlyNthLastAndExplicitDayPhrasesResolveFirstOccurrence() {
        for (phrase, day, ordinal) in [("every first monday","2026-11-02",1),("every month on the last friday","2026-10-30",-1),("every fifth monday","2026-11-30",5)] {
            let p = quick("Review " + phrase)
            XCTAssertEqual(p.title, "Review"); XCTAssertEqual(p.updates["due_date"], .string(day))
            XCTAssertEqual(p.updates["recurrence_pattern"]?.object["weekdayOrdinal"], .number(Double(ordinal)))
        }
        let p = quick("Review every 2 months on the 31st starting 2026-02-01")
        XCTAssertEqual(p.updates["due_date"], .string("2026-02-28")); XCTAssertEqual(p.updates["recurrence_pattern"]?.object["dayOfMonth"], .number(31))
        XCTAssertEqual(p.updates["recurrence_pattern"]?.object["interval"], .number(2))
    }
    func testYearlyLeapAndOtherIntervalsKeepAnchors() {
        let p = quick("Birthday every year on february 29 starting 2027-01-01")
        XCTAssertEqual(p.title, "Birthday"); XCTAssertEqual(p.updates["due_date"], .string("2027-02-28"))
        XCTAssertEqual(p.updates["recurrence_pattern"]?.object["dayOfMonth"], .number(29)); XCTAssertEqual(p.updates["recurrence_pattern"]?.object["monthOfYear"], .number(2))
        XCTAssertEqual(quick("Review every other year").updates["recurrence_pattern"]?.object["interval"], .number(2))
        XCTAssertEqual(quick("Review monthly", day: "2026-01-31").updates["recurrence_pattern"]?.object["dayOfMonth"], .number(31))
    }
    func testDeclinedInvalidAndEscapedPhrasesCannotBecomeDatesOrWeeklyRules() {
        for phrase in ["every monday until 2026-12-31", "every 0 days until 2026-12-31", "every sixth friday", "every 999999999999999999999 months starting 2026-12-31", "every year on april 31", "every day until 2026-02-30", "every day starting 2026-12-31 until 2026-10-01", "every day for 0 occurrences"] {
            let declined: Set<String> = phrase == "every monday until 2026-12-31" ? ["recurrence"] : []
            let p = quick("Review " + phrase, disabled: declined)
            XCTAssertEqual(p.title, "Review " + phrase, phrase); XCTAssertNil(p.updates["recurrence_pattern"], phrase); XCTAssertNil(p.updates["due_date"], phrase)
        }
        let escaped = quick(#"Review \every monday until 2026-12-31"#)
        XCTAssertEqual(escaped.title, "Review every monday until 2026-12-31"); XCTAssertTrue(escaped.updates.isEmpty)
        XCTAssertTrue(quick(#"Review "every monday until 2026-12-31""#).updates.isEmpty)
        let conflict = quick("Review every monday every friday")
        XCTAssertEqual(conflict.title, "Review every monday every friday"); XCTAssertTrue(conflict.updates.isEmpty); XCTAssertFalse(conflict.warnings.isEmpty)
    }
    func testRepeatBoundsAreNotOrdinaryPlanDatesAndNewRuleClearsOldEnd() {
        let p = quick("Review every 3 days starting 2026-11-01 until 2026-12-31 for 4 occurrences")
        XCTAssertEqual(p.title, "Review"); XCTAssertEqual(p.updates["due_date"], .string("2026-11-01"))
        var old = task("2026-10-06", ["type":.string("daily"), "interval":.number(1), "endDate":.string("2026-10-10")]); old["recurrence_end_date"] = .string("2026-10-10")
        let result = p.applying(to: old)
        XCTAssertEqual(result["recurrence_end_date"], .null); XCTAssertEqual(result["recurrence_pattern"].object["endDate"], .string("2026-12-31"))
        XCTAssertTrue(quick("Review every day", disabled: ["due_date"]).updates.isEmpty)
    }
    func testMissingFifthWeekdaySkipsWholeMonthsAndLastWeekdayDoesNotDrift() {
        let p: [String:JSON] = ["type":.string("monthly"),"interval":.number(1),"weekdayOrdinal":.number(5),"weekday":.number(1)]
        let t = task("2026-11-30", p)
        XCTAssertEqual(Dates.next(t, calendar: calendar()).map { TaskPlanner.dayKey($0, calendar: calendar()) }, "2027-03-29")
        var r=p; r["weekdayOrdinal"] = .number(-1);r["weekday"] = .number(5)
        XCTAssertEqual(Dates.next(task("2026-10-30",r),calendar:calendar()).map { TaskPlanner.dayKey($0,calendar:calendar()) }, "2026-11-27")
    }
    func testMonthlyAndYearlyClampsRetainIntentAfterShortMonths() throws {
        var t = quick("Review monthly", day:"2026-01-31").applying(to: Record.task(user:"owner"))
        var day="2026-01-31"
        for expected in ["2026-02-28","2026-03-31","2026-04-30"] {
            t["due_date"] = .string(day)
            let next=try XCTUnwrap(Dates.next(t,calendar:calendar()));day=TaskPlanner.dayKey(next,calendar:calendar());XCTAssertEqual(day,expected)
        }
        var leap=task("2027-02-28",["type":.string("yearly"),"interval":.number(1),"monthOfYear":.number(2),"dayOfMonth":.number(29)])
        XCTAssertEqual(Dates.next(leap,calendar:calendar()).map { TaskPlanner.dayKey($0,calendar:calendar()) },"2028-02-29")
        leap["due_date"] = .string("2028-02-29")
        XCTAssertEqual(Dates.next(leap,calendar:calendar()).map { TaskPlanner.dayKey($0,calendar:calendar()) },"2029-02-28")
    }
    func testLateCompletionSkipsMissedDatesWithoutUsingCompletionAsScheduledAnchor() throws {
        let scheduled=task("2026-01-10",["type":.string("monthly"),"interval":.number(3),"dayOfMonth":.number(10)])
        let completion=date("2026-09-19")
        let change=TaskCompletion.complete(scheduled,tasks:[],at:completion,calendar:calendar())
        XCTAssertEqual(change.count,2);XCTAssertEqual(change.last?.fields["due_date"],.string("2026-10-10"))
        var dynamic=scheduled;dynamic["recurrence_pattern"] = .object(["type":.string("monthly"),"interval":.number(3),"fromCompletion":.bool(true)])
        XCTAssertEqual(TaskCompletion.complete(dynamic,tasks:[],at:completion,calendar:calendar()).last?.fields["due_date"],.string("2026-12-19"))
        let daily=task("1900-01-01",["type":.string("daily"),"interval":.number(1)])
        XCTAssertEqual(TaskCompletion.complete(daily,tasks:[],at:completion,calendar:calendar()).last?.fields["due_date"],.string("2026-09-20"))
    }
    func testMultiWeekCatchupPreservesSelectedCycleAndRemainingCount() {
        let t=task("2026-10-05",["type":.string("weekly"),"interval":.number(2),"daysOfWeek":.array([.number(1),.number(3)]),"count":.number(3)])
        let next=TaskCompletion.complete(t,tasks:[],at:date("2026-10-08"),calendar:calendar())
        XCTAssertEqual(next.last?.fields["due_date"],.string("2026-10-19"));XCTAssertEqual(next.last?.fields["recurrence_pattern"]?.object["count"],.number(2))
        XCTAssertEqual(TaskCompletion.complete(t,tasks:[],at:date("2026-10-19"),calendar:calendar()).last?.fields["due_date"],.string("2026-10-21"))
    }
    func testCompletionBasedFixedZoneCrossesDSTAndTravelWithOneSuccessor() {
        var t=quick("Review every! 2 days starting 2026-10-23").applying(to: Record.task(user:"owner"))
        t["due_time"] = .string("09:00"); t["time_zone"] = .string("Europe/Copenhagen")
        let completion=ISO8601DateFormatter().date(from:"2026-10-25T00:30:00Z")!
        let a=TaskCompletion.complete(t,tasks:[],at:completion,calendar:calendar())
        let b=TaskCompletion.complete(t,tasks:[],at:completion,calendar:calendar("America/New_York"))
        XCTAssertEqual(a.last?.fields["due_date"],.string("2026-10-27"));XCTAssertEqual(a.last?.fields["scheduled_at"],.string("2026-10-27T08:00:00Z"))
        XCTAssertEqual(a.last?.recordID,b.last?.recordID);XCTAssertEqual(a.last?.fields["scheduled_at"],b.last?.fields["scheduled_at"])
    }
    func testNewRulesRespectCountEndAndRejectMalformedUnsafeNumbers() {
        var t=task("2026-10-30",["type":.string("monthly"),"interval":.number(1),"weekdayOrdinal":.number(-1),"weekday":.number(5),"endDate":.string("2026-11-27")])
        XCTAssertEqual(TaskCompletion.complete(t,tasks:[],at:date("2026-11-26"),calendar:calendar()).count,2)
        XCTAssertEqual(TaskCompletion.complete(t,tasks:[],at:date("2026-11-27"),calendar:calendar()).count,1)
        for rule in [["type":JSON.string("yearly"),"interval":.number(Double.infinity)], ["type":.string("monthly"),"weekdayOrdinal":.number(0),"weekday":.number(5)], ["type":.string("daily"),"interval":.number(1.5)], ["type":.string("weekly"),"daysOfWeek":.array([.number(99)])]] {
            t["recurrence_pattern"] = .object(rule);XCTAssertNil(Dates.next(t,calendar:calendar()))
        }
    }
    func testSnapshotQueueBackupAndReopenPreserveRichRules() throws {
        let t=quick("Review every 2 months on last friday starting 2026-10-01 for 3 occurrences until 2027-12-31").applying(to: Record.task(user:"owner"))
        XCTAssertEqual(t.title,"Review");var s=Snapshot();s.tables["tasks"]=[t]
        s.pending=TaskCompletion.complete(t,tasks:[t],at:date("2026-10-30"),calendar:calendar());for change in s.pending { s.apply(change) }
        let restored=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(s))
        XCTAssertEqual(restored,s)
        let backup=WorkspaceBackup.make(restored,account:"owner")
        let decoded=try WorkspaceBackup.read(backup.data())
        XCTAssertEqual(decoded.tables["tasks"]?.last?["recurrence_pattern"],restored.tables["tasks"]?.last?["recurrence_pattern"])
        let done=restored.tables["tasks"]!.first!
        XCTAssertEqual(TaskCompletion.toggle(done,tasks:restored.tables["tasks"]!,at:date("2026-11-01")).count,1)
    }
    func testSummaryDisclosesScopeAnchorBoundsAndOccurrenceLimit() {
        let p=quick("Review every! 2 months on last friday until 2027-12-31 for 5 occurrences")
        let summary=Recurrence.summary(Record(p.updates["recurrence_pattern"]!.object))
        for text in ["Every 2 months","Last Friday","From completion","2027-12-31","5 left"] { XCTAssertTrue(summary.contains(text),summary) }
    }
    func testCompletionCalendarConstraintsNeverShortenTheWaitingInterval() {
        let rows: [(String,[String:JSON],String)] = [
            ("2026-10-05",["type":.string("weekly"),"interval":.number(2),"daysOfWeek":.array([.number(1),.number(5)]),"fromCompletion":.bool(true)],"2026-10-23"),
            ("2026-10-05",["type":.string("monthly"),"interval":.number(2),"weekdayOrdinal":.number(-1),"weekday":.number(5),"fromCompletion":.bool(true)],"2027-01-29"),
            ("2026-10-05",["type":.string("yearly"),"interval":.number(1),"monthOfYear":.number(2),"dayOfMonth":.number(29),"fromCompletion":.bool(true)],"2028-02-29")
        ]
        for (day,rule,expected) in rows {
            let completed = rule["type"] == .string("weekly") ? "2026-10-07" : "2026-10-30"
            XCTAssertEqual(TaskCompletion.complete(task(day,rule),tasks:[],at:date(completed),calendar:calendar()).last?.fields["due_date"],.string(expected))
        }
    }
    func testLegacyUnspecifiedMonthEndIsStabilizedInTheSuccessor() throws {
        let original=task("2026-01-31",["type":.string("monthly"),"interval":.number(1)])
        let first=Record(try XCTUnwrap(TaskCompletion.complete(original,tasks:[],at:date("2026-01-31"),calendar:calendar()).last?.fields))
        XCTAssertEqual(first.string("due_date"),"2026-02-28")
        XCTAssertEqual(first["recurrence_pattern"].object["dayOfMonth"],.number(31))
        XCTAssertEqual(TaskCompletion.complete(first,tasks:[],at:date("2026-02-28"),calendar:calendar()).last?.fields["due_date"],.string("2026-03-31"))
    }
    func testUnsupportedSuffixesAndWeekdayListsRemainWholeLiterals() {
        for phrase in ["every day until next friday", "every monday and bananas starting 2027-01-01", "every day for 3 weeks", "every week on monday, banana until 2027-12-31", "every monday and every friday", "every monday and 2027-01-01"] {
            let p=quick("Review " + phrase)
            XCTAssertEqual(p.title,"Review " + phrase);XCTAssertTrue(p.updates.isEmpty,phrase);XCTAssertFalse(p.warnings.isEmpty,phrase)
        }
    }
    func testRepeatQuickEntryUsesGregorianSourceZoneAndShowsLegacyEndLimit() {
        var t=Record.task(user:"owner");t["time_zone"] = .string("Europe/Copenhagen"); t["due_time"] = .string("09:00")
        let now=ISO8601DateFormatter().date(from:"2026-10-05T23:30:00Z")!
        var buddhist=Calendar(identifier:.buddhist);buddhist.timeZone=TimeZone(identifier:"America/New_York")!
        let p=QuickEntry("Review daily",now:now,calendar:buddhist,task:t)
        XCTAssertEqual(p.updates["due_date"],.string("2026-10-06"))
        t["recurrence_pattern"] = .object(["type":.string("weekly"),"interval":.number(1)]);t["recurrence_end_date"] = .string("2026-12-31")
        XCTAssertTrue(Recurrence.summary(Recurrence.effective(t)).contains("2026-12-31"))
    }

    func testLegacyEmptyEndDateRemainsAnUnlimitedRule() {
        let t=task("2026-10-06",["type":.string("daily"),"interval":.number(1),"endDate":.string("")])
        XCTAssertEqual(Dates.next(t,calendar:calendar()).map { TaskPlanner.dayKey($0,calendar:calendar()) },"2026-10-07")
        var r=Record(t["recurrence_pattern"].object);r["endDate"] = .number(123)
        XCTAssertFalse(Recurrence.valid(r))
    }

}
