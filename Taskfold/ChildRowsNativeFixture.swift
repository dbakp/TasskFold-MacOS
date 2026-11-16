#if DEBUG
import Foundation
import ObjectiveC

/// `--child-rows-fixture`: turns the child-rows flag on for this launch and seeds a local workspace (never hosted) with a
/// parent, children and a grandchild. One child is dated today and one tomorrow. `--child-rows-keep` turns the flag on
/// without reseeding, so a relaunch shows what the first launch saved.
enum ChildRowsFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--child-rows-fixture") }
    static var keep: Bool { ProcessInfo.processInfo.arguments.contains("--child-rows-keep") }
    static let project = "cr-project"
    static let parent = "cr-parent", venue = "cr-venue", agenda = "cr-agenda", invite = "cr-invite"
    static let topics = "cr-topics", timebox = "cr-timebox", catering = "cr-catering"

    /// `TaskTree.rowsEnabled` reads Info.plist `TaskfoldChildRowsEnabled`. A fixture launch answers true for that key only.
    private final class FlagBundle: Bundle, @unchecked Sendable {
        override func object(forInfoDictionaryKey key: String) -> Any? {
            key == "TaskfoldChildRowsEnabled" ? true : super.object(forInfoDictionaryKey: key)
        }
    }
    static func enableFlagIfRequested() {
        guard enabled, object_getClass(Bundle.main) != FlagBundle.self else { return }
        object_setClass(Bundle.main, FlagBundle.self)
    }
}

extension Store {
    func seedChildRowsFixture() {
        guard ChildRowsFixture.enabled, userID == "ui-testing" || userID == "preview" else { return }
        dailyBackupsEnabled = false; disableNotifications()
        guard !ChildRowsFixture.keep else { return }
        typealias F = ChildRowsFixture
        let now = Date(), tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)
        snapshot = Snapshot()
        snapshot.tables["projects"] = [Record(["id": .string(F.project), "user_id": .string(userID), "name": .string("Q4 offsite"), "color": .string("#e31e4b")])]
        snapshot.tables["labels"] = [Record(["id": .string("cr-label-agenda"), "user_id": .string(userID), "name": .string("agenda"), "color": .string("#3b82f6")])]
        func row(_ id: String, _ title: String, priority: Int = 4, date: Date? = nil, parent: String? = nil, order: Double? = nil, labels: [String] = []) -> Record {
            var task = Record.task(user: userID, project: F.project, date: date)
            task["id"] = .string(id); task["title"] = .string(title); task["priority"] = .number(Double(priority))
            if let parent { task["parent_id"] = .string(parent) }
            if let order { task["child_order"] = .number(order) }
            task["labels"] = .array(labels.map(JSON.string))
            return task
        }
        snapshot.tables["tasks"] = [
            row(F.parent, "Prepare the Q4 offsite", priority: 2),
            row(F.venue, "Book the venue", priority: 1, date: now, parent: F.parent, order: 1),
            row(F.agenda, "Draft the agenda", priority: 3, date: tomorrow, parent: F.parent, order: 2, labels: ["cr-label-agenda"]),
            row(F.topics, "Collect topics from the team", parent: F.agenda, order: 1),
            row(F.timebox, "Time-box each session", parent: F.agenda, order: 2),
            row(F.invite, "Send invitations", parent: F.parent, order: 3),
            row(F.catering, "Order catering"),
        ]
        undoStack = []; redoStack = []
        try? persist()
    }
}
#endif
