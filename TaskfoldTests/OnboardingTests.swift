import XCTest
@testable import TaskfoldCore

/// Starter-project onboarding (Core/Onboarding.swift): deterministic IDs, idempotent seeding, the synced flag and every
/// auto-complete rule.
final class OnboardingTests: XCTestCase {
    private let account = "11111111-2222-4333-8444-555555555555"
    private var gregorian: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }

    func testUUIDv5MatchesTheRFCVector() {
        // RFC 4122 appendix B style check: uuid5(DNS namespace, "www.example.com").
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(Onboarding.uuidV5(namespace: dns, name: "www.example.com").uuidString.lowercased(), "2ed6657d-e927-568b-95e1-2665a8aea6a2")
    }

    func testIDsAreDeterministicPerAccountAndDistinct() {
        let again = Onboarding.starterTaskIDs(account: account)
        XCTAssertEqual(again, Onboarding.starterTaskIDs(account: account.uppercased()))
        XCTAssertEqual(Set(again).count, 6)
        XCTAssertFalse(again.contains(Onboarding.projectID(account: account)))
        XCTAssertNotEqual(Onboarding.projectID(account: account), Onboarding.projectID(account: "local"))
        XCTAssertEqual((UUID(uuidString: Onboarding.projectID(account: account))!.uuid.6) >> 4, 5)
        XCTAssertEqual(Onboarding.key(forTask: Onboarding.taskID(account: account, key: .subtask).uppercased(), account: account), .subtask)
    }

    func testSeedingTwiceWritesTheSameRowsCreateOnly() {
        for platform in [Onboarding.Platform.mac, .ios] {
            let first = Onboarding.seedMutations(account: account, platform: platform, localMode: false)
            let second = Onboarding.seedMutations(account: account, platform: platform, localMode: false)
            XCTAssertEqual(first.map(\.recordID), second.map(\.recordID))
            XCTAssertEqual(first.count, 7)
            XCTAssertTrue(first.allSatisfy { $0.method == "POST" && $0.insertOnly == true })
            // Applying both plans to one table keeps one project and six tasks.
            var table: [String: Mutation] = [:]
            for change in first + second where table[change.recordID] == nil { table[change.recordID] = change }
            XCTAssertEqual(table.count, 7)
        }
        // A second device (other platform) hits the same IDs.
        XCTAssertEqual(Onboarding.seedMutations(account: account, platform: .mac, localMode: false).map(\.recordID),
                       Onboarding.seedMutations(account: account, platform: .ios, localMode: false).map(\.recordID))
    }

    func testSeedShapeAndBlueProject() throws {
        let plan = Onboarding.seedMutations(account: account, platform: .mac, localMode: false, completed: [.workingHours])
        let project = try XCTUnwrap(plan.first)
        XCTAssertEqual(project.table, "projects"); XCTAssertEqual(project.fields["name"]?.text, "Get to know Taskfold")
        XCTAssertEqual(project.fields["color"]?.text, "#3b82f6")
        XCTAssertEqual(ProjectPalette.hue(stored: "#3b82f6", projectID: project.recordID).name, "Blue")
        let tasks = plan.dropFirst()
        XCTAssertTrue(tasks.allSatisfy { $0.fields["project_id"]?.text == project.recordID && $0.fields["user_id"]?.text == account })
        XCTAssertEqual(tasks.map { $0.fields["title"]!.text }, ["Add your first task", "Drag this task to tomorrow", "Open this task and add a subtask", "Set your working hours", "Connect your calendar", "Get Taskfold on iPhone"])
        let dated = tasks.filter { $0.fields["due_date"] != .null }
        XCTAssertEqual(dated.count, 1); XCTAssertEqual(dated.first?.recordID, Onboarding.taskID(account: account, key: .reschedule))
        XCTAssertEqual(tasks.filter { $0.fields["completed"] == .bool(true) }.map(\.recordID), [Onboarding.taskID(account: account, key: .workingHours)])
        let stamps = tasks.map { $0.fields["created_at"]!.text }
        XCTAssertEqual(stamps, stamps.sorted(by: >), "newest first, so the list reads in lesson order")
    }

    func testPlatformWordingAndLocalVariant() {
        XCTAssertTrue(Onboarding.copy(.addTask, platform: .mac, localMode: false).note.contains("⌘N"))
        XCTAssertTrue(Onboarding.copy(.addTask, platform: .ios, localMode: false).note.contains("Tap +"))
        XCTAssertEqual(Onboarding.copy(.otherDevice, platform: .mac, localMode: false).title, "Get Taskfold on iPhone")
        XCTAssertEqual(Onboarding.copy(.otherDevice, platform: .mac, localMode: true).title, "Sign in to sync with iPhone")
        XCTAssertEqual(Onboarding.copy(.otherDevice, platform: .ios, localMode: false).title, "Get Taskfold on Mac")
        XCTAssertEqual(Onboarding.copy(.addTask, platform: .mac, localMode: false).title, Onboarding.copy(.addTask, platform: .ios, localMode: false).title)
    }

    func testFlagRoundTripKeepsOtherPreferences() throws {
        let prefs: JSON = .object(["theme": .string("dark"), "onboarding": .object(["tips": .bool(true)])])
        XCTAssertNil(Onboarding.flag(in: prefs)); XCTAssertNil(Onboarding.flag(in: .null)); XCTAssertNil(Onboarding.flag(in: .object([:])))
        var flag = Onboarding.Flag(seededAt: "2026-11-20T10:00:00Z", platforms: ["macos"])
        let written = Onboarding.writing(flag, into: prefs)
        XCTAssertEqual(written.object["theme"], .string("dark"))
        XCTAssertEqual(written.object["onboarding"]?.object["tips"], .bool(true))
        XCTAssertEqual(Onboarding.flag(in: written), flag)
        flag.dismissed = true; flag = Onboarding.adding(.ios, to: flag); flag = Onboarding.adding(.ios, to: flag)
        XCTAssertEqual(Onboarding.flag(in: Onboarding.writing(flag, into: written)), flag)
        XCTAssertEqual(flag.platforms, ["ios", "macos"])
        // Writing into a null column starts a fresh object.
        XCTAssertNotNil(Onboarding.flag(in: Onboarding.writing(flag, into: .null)))
        let skipped = Onboarding.Flag(dismissed: true, skipped: true)
        XCTAssertEqual(Onboarding.flag(in: Onboarding.writing(skipped, into: .null)), skipped)
    }

    func testProgressReadsManualAndAutomaticCompletionAlike() {
        var rows = Onboarding.seedMutations(account: account, platform: .mac, localMode: false).dropFirst().map { Record($0.fields) }
        XCTAssertEqual(Onboarding.progress(tasks: Array(rows), account: account).count, 0)
        rows[0]["completed"] = .bool(true); rows[3]["completed"] = .bool(true)
        let other = Record(["id": .string("someone-else"), "completed": .bool(true)])
        let progress = Onboarding.progress(tasks: Array(rows) + [other], account: account)
        XCTAssertEqual(progress.done, [.addTask, .workingHours]); XCTAssertFalse(progress.finished)
        for index in rows.indices { rows[index]["completed"] = .bool(true) }
        XCTAssertTrue(Onboarding.progress(tasks: Array(rows), account: account).finished)
    }

    // MARK: Triggers

    private let all = Set(Onboarding.Key.allCases)
    private func completions(_ event: Onboarding.Event, open: Set<Onboarding.Key>? = nil) -> [Onboarding.Key] {
        Onboarding.completions(for: event, account: account, open: open ?? all, today: Date(timeIntervalSince1970: 1_800_000_000), calendar: gregorian)
    }
    private var tomorrow: String { Dates.day(gregorian.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: 1_800_000_000))!) }

    func testQuickAddNeedsADatePriorityOrTime() {
        XCTAssertEqual(completions(.quickAdd(taskID: "x", groups: ["due_date"])), [.addTask])
        XCTAssertEqual(completions(.quickAdd(taskID: "x", groups: ["priority", "labels"])), [.addTask])
        XCTAssertEqual(completions(.quickAdd(taskID: "x", groups: ["due_time"])), [.addTask])
        XCTAssertEqual(completions(.quickAdd(taskID: "x", groups: [])), [])
        XCTAssertEqual(completions(.quickAdd(taskID: "x", groups: ["labels", "project_id"])), [])
        XCTAssertEqual(completions(.quickAdd(taskID: Onboarding.taskID(account: account, key: .calendar), groups: ["priority"])), [])
        XCTAssertEqual(completions(.quickAdd(taskID: "x", groups: ["priority"]), open: [.subtask]), [])
    }
    func testRescheduleNeedsTheStarterTaskMovedToTomorrow() {
        let id = Onboarding.taskID(account: account, key: .reschedule)
        func patch(_ id: String, _ day: String) -> Onboarding.Event { .mutations([Mutation(table: "tasks", recordID: id, method: "PATCH", fields: ["due_date": .string(day)])]) }
        XCTAssertEqual(completions(patch(id, tomorrow)), [.reschedule])
        XCTAssertEqual(completions(patch(id.uppercased(), tomorrow)), [.reschedule])
        XCTAssertEqual(completions(patch(id, "2000-01-01")), [])
        XCTAssertEqual(completions(patch("other", tomorrow)), [])
        XCTAssertEqual(completions(.mutations([Mutation(table: "tasks", recordID: id, method: "PATCH", fields: ["title": .string("x")])])), [])
    }
    func testSubtaskNeedsANewChildRow() {
        func post(_ id: String, parent: String?) -> Onboarding.Event {
            var fields: [String: JSON] = ["title": .string("Step")]; if let parent { fields["parent_id"] = .string(parent) }
            return .mutations([Mutation(table: "tasks", recordID: id, method: "POST", fields: fields)])
        }
        XCTAssertEqual(completions(post("new", parent: "p")), [.subtask])
        XCTAssertEqual(completions(post("new", parent: nil)), [])
        XCTAssertEqual(completions(post("new", parent: "")), [])
        XCTAssertEqual(completions(.mutations([Mutation(table: "tasks", recordID: "c", method: "PATCH", fields: ["parent_id": .string("p")])])), [])
    }
    func testWorkingHoursNeedsASavedPlannerDocumentOrTheSetupSheet() {
        let save = Mutation(table: "view_preferences", recordID: "planner", method: "POST", fields: ["working_hours": WorkingHours().document])
        XCTAssertEqual(completions(.mutations([save])), [.workingHours])
        var patch = save; patch.method = "PATCH"; XCTAssertEqual(completions(.mutations([patch])), [.workingHours])
        XCTAssertEqual(completions(.mutations([Mutation(table: "view_preferences", recordID: "today", method: "PATCH", fields: ["working_hours": WorkingHours().document])])), [])
        XCTAssertEqual(completions(.mutations([Mutation(table: "view_preferences", recordID: "planner", method: "PATCH", fields: ["date_preferences": .null])])), [])
        XCTAssertEqual(completions(.setupSaved), [.workingHours])
        XCTAssertEqual(completions(.setupSaved, open: [.calendar]), [])
    }
    func testCalendarAndOtherDevice() {
        XCTAssertEqual(completions(.calendarConnected), [.calendar])
        XCTAssertEqual(completions(.calendarConnected, open: []), [])
        XCTAssertEqual(completions(.platforms(["macos"])), [])
        XCTAssertEqual(completions(.platforms(["ios"])), [])
        XCTAssertEqual(completions(.platforms(["ios", "macos"])), [.otherDevice])
    }
    func testOnlyOpenTasksComplete() {
        let save = Mutation(table: "view_preferences", recordID: "planner", method: "PATCH", fields: ["working_hours": WorkingHours().document])
        XCTAssertEqual(completions(.mutations([save]), open: all.subtracting([.workingHours])), [])
    }
    func testLeakedFlagRepairTreatsTheStarterProjectAsSeed() {
        let seed = Onboarding.seedMutations(account: "local", platform: .mac, localMode: true)
        var snapshot = Snapshot()
        snapshot.tables["projects"] = [Record(seed[0].fields)]
        snapshot.tables["tasks"] = seed.dropFirst().map { Record($0.fields) }
        snapshot.tables["profiles"] = [Record(["id": .string("local"), "user_id": .string("local"), "preferences": Onboarding.writing(.init(), into: .null)])]
        XCTAssertTrue(LocalModeDefaults.holdsOnlySeedRows(snapshot))
        snapshot.tables["tasks"]! += [Record(["id": .string("mine"), "title": .string("Buy milk"), "project_id": .string(seed[0].recordID)])]
        XCTAssertFalse(LocalModeDefaults.holdsOnlySeedRows(snapshot))
    }
}
