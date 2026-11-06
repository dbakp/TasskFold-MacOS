import XCTest
@testable import TaskfoldCore

private actor HeadingReminderCenter: ReminderCenter {
    var requests: [ReminderRequest] = []
    func pending() -> [ReminderRequest] { requests }
    func removeInvalid(_ state: ReminderState) { requests.removeAll { !$0.valid(state: state) } }
    func remove(_ ids: [String]) { requests.removeAll { ids.contains($0.identifier) } }
    func add(_ request: ReminderRequest) { requests.append(request) }
}
final class HeadingDeliveryTests: XCTestCase {
    let account = "f2910000-0000-4000-8000-000000000001"
    let device = "f2910000-0000-4000-8000-000000000002"
    let now = Date(timeIntervalSince1970: 1_792_901_600)
    func task() -> Record {
        var task = Record.task(user: account); task["title"] = .string("Reference instructions")
        task["description"] = .string("Keep these instructions")
        task["reminder_specs"] = .array([.object(ReminderSpec.absolute(now.addingTimeInterval(600)).raw)])
        return task
    }
    func unsupported(_ task: Record) -> Record { var result = task; result["is_heading"] = .string("future"); return result }
    func heading(_ task: Record) -> Record { var result = task; result["is_heading"] = .bool(true); return result }
    func testDisplayedCountsSeparateTypesWithoutExpandingOrDoubleCountingChildren() {
        var ordinary = task(); let header = heading(task()), unknown = unsupported(task())
        ordinary["subtasks"] = .array([.object(header.fields), .object(task().fields)])
        XCTAssertEqual(TaskKind.listCountLabel([]), "0")
        XCTAssertEqual(TaskKind.listCountLabel([ordinary]), "1")
        XCTAssertEqual(TaskKind.listCountLabel([header]), "0 tasks · 1 heading")
        XCTAssertEqual(TaskKind.listCountLabel([ordinary, header, unknown]), "1 task · 1 heading · 1 unsupported item")
        XCTAssertEqual(TaskKind.listCountLabel([header, header]), "0 tasks · 2 headings")
    }
    func testTimeEventsAndReconstructedStaleReceiptsRefuseHeadingAndUnknownWithoutChangingSettings() throws {
        let original = task(), event = try XCTUnwrap(DueReminder.events(tasks: [original], now: now).first)
        for changed in [heading(original), unsupported(original)] {
            let persisted = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(changed))
            XCTAssertTrue(DueReminder.events(tasks: [persisted], now: now).isEmpty)
            XCTAssertNil(DueReminder.validated(tasks: [persisted], taskID: original.id, specID: event.specID, signature: event.signature, originalAt: event.date))
            XCTAssertEqual(persisted["reminder_specs"], original["reminder_specs"])
            XCTAssertEqual(persisted["description"], original["description"])
        }
        XCTAssertNotNil(DueReminder.validated(tasks: [original], taskID: original.id, specID: event.specID, signature: event.signature, originalAt: event.date))
    }
    func testPlannedLegacyReminderIsSuppressedForHeadingAndUnknown() {
        var original = task(); original.fields.removeValue(forKey: "reminder_specs")
        original["due_date"] = .string("2026-11-01"); original["due_time"] = .string("09:00")
        XCTAssertEqual(DueReminder.events(tasks: [original], now: now).count, 1)
        XCTAssertTrue(DueReminder.events(tasks: [heading(original), unsupported(original)], now: now).isEmpty)
    }
    func testSchedulerRemovesPendingSnoozeAndRejectsOldActionAfterColdHeadingRead() async throws {
        let original = task(), center = HeadingReminderCenter(), scheduler = ReminderScheduler(center: center)
        let event = try XCTUnwrap(DueReminder.events(tasks: [original], now: now).first)
        var state = ReminderState(revision: 1, account: account, events: [event], now: now, validationTasks: [original])
        _ = await scheduler.update(state)
        _ = await scheduler.snooze(account: account, taskID: original.id, specID: event.specID, signature: event.signature, minutes: 5, now: now)
        let initial = await center.pending(); XCTAssertFalse(initial.isEmpty)
        let restored = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(heading(original)))
        state.revision = 2; state.events = DueReminder.events(tasks: [restored], now: now); state.validationTasks = [restored]
        _ = await scheduler.update(state)
        let remaining = await center.pending(); XCTAssertTrue(remaining.isEmpty)
        let stale = await scheduler.snooze(account: account, taskID: original.id, specID: event.specID, signature: event.signature, minutes: 5, now: now)
        XCTAssertNil(stale)
    }
    func testFocusFinishRefusesConvertedOrUnsupportedTaskButRetainsSession() throws {
        let original = task(), session = try FocusSession(taskID: original.id, minutes: 25, now: now)
        let row = Record(try FocusSessionChange.make(session, current: nil, account: account).fields)
        XCTAssertNotNil(FocusFinish.event(row: row, tasks: [original], account: account))
        for changed in [heading(original), unsupported(original)] {
            XCTAssertNil(FocusFinish.event(row: row, tasks: [changed], account: account))
            XCTAssertEqual(FocusSessionChange.session(in: row, account: account), session)
        }
    }
    func testCapturedFocusChoiceCannotStartAfterTypeChange() throws {
        let original = task(), catalog = FocusTaskCatalog(tasks: [original], projects: [], sections: [])
        let choice = try XCTUnwrap(catalog.choices.first)
        XCTAssertTrue(FocusTaskCatalog.selectable(choice, tasks: [original]))
        for changed in [heading(original), unsupported(original)] {
            XCTAssertFalse(FocusTaskCatalog.selectable(choice, tasks: [changed]))
            XCTAssertTrue(FocusTaskCatalog(tasks: [changed], projects: [], sections: []).choices.isEmpty)
        }
    }
    func location() throws -> (Record, LocationPrivateArchive, LocationPrivatePlace, WorkspaceBinding) {
        let pin = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Synthetic private workshop", latitude: 55.67, longitude: 12.56, radius: 250))
        var archive = LocationPrivateArchive(device: device); archive.places = [pin.raw]
        return (task(), archive, pin, WorkspaceBinding(account: account, generation: UUID()))
    }
    func testLocationCandidateAndRetirementSuppressHeadingWhileKeepingPrivateSettings() throws {
        let (original, archive, pin, workspace) = try location()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: original, archive: archive, place: pin, transition: .arrive))
        let saved = try XCTUnwrap(review.applying(to: original, archive: archive, workspace: workspace))
        let ordinary = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: saved, settings: review.settings, place: pin))
        for changed in [heading(saved), unsupported(saved)] {
            XCTAssertNil(LocationReminderCandidate(account: account, device: device, task: changed, settings: review.settings, place: pin))
            XCTAssertEqual(LocationReminderTicket.retired(account: account, before: saved, after: changed), [ordinary.ticket])
            XCTAssertEqual(changed["reminder_specs"], saved["reminder_specs"])
        }
    }
    func testLocationReviewAndHandoffProposalRefuseTypeChangeEvenWithSameCompletionRevision() throws {
        let (original, archive, pin, workspace) = try location()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: original, archive: archive, place: pin, transition: .leave))
        let proposal = try XCTUnwrap(LocationHandoffProposal.make(account: account, task: original, place: pin, transition: .leave, repeats: false, now: now))
        XCTAssertTrue(proposal.matches(task: original, account: account))
        for changed in [heading(original), unsupported(original)] {
            XCTAssertNil(LocationReminderReview(workspace: workspace, task: changed, archive: archive, place: pin, transition: .leave))
            XCTAssertFalse(review.valid(task: changed, archive: archive, workspace: workspace))
            XCTAssertNil(review.applying(to: changed, archive: archive, workspace: workspace))
            XCTAssertNil(LocationHandoffProposal.make(account: account, task: changed, place: pin, transition: .leave, repeats: false, now: now))
            XCTAssertFalse(proposal.matches(task: changed, account: account))
        }
    }
}
