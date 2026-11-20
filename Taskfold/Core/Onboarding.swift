import Foundation
import CryptoKit

/// Starter-project onboarding (design review mac-r2, PR 3). Pure logic shared by both apps: deterministic record IDs,
/// the per-account "seeded" flag, the platform wording of the starter tasks, and the rules that tick each task off.
/// `OnboardingStore.swift` applies these to the live `Store`; nothing here touches storage, the network or the UI.
///
/// Where the flag lives (no hosted migration): the account's own `profiles` row already has a synced `preferences`
/// jsonb column, so the flag is `preferences.onboarding.starter = {version, seeded_at, dismissed, platforms}`. Other
/// keys in `preferences` are always kept. In local mode the same key is written to the local workspace's profile row.
/// The deterministic UUIDv5 IDs are the second guarantee: two devices that both seed write the same rows, so a create
/// that races is a no-op (`insertOnly`) rather than a duplicate.
enum Onboarding {
    static let version = 1
    static let projectName = "Get to know Taskfold"
    static let projectIntro = "Learn Taskfold by doing. Each task checks itself off when you do it."
    /// The editor palette's "Blue" (`ProjectPalette` draws it as the Blue identity hue). Never crimson.
    static let projectColor = "#3b82f6"
    /// Namespace for every starter ID. Fixed forever: changing it would duplicate projects on already-seeded accounts.
    static let namespace = UUID(uuidString: "6F1D2C5E-3B7A-4E0D-9C41-5A8E0B7D2F13")!

    enum Platform: String, Sendable { case mac = "macos", ios = "ios"
        var other: Platform { self == .mac ? .ios : .mac }
        var deviceName: String { self == .mac ? "Mac" : "iPhone" }
    }

    /// The six starter tasks, in display order.
    enum Key: String, CaseIterable, Sendable {
        case addTask = "add-task", reschedule, subtask, workingHours = "working-hours", calendar, otherDevice = "other-device"
    }

    // MARK: Deterministic IDs

    /// RFC 4122 version-5 UUID (SHA-1 of the namespace bytes followed by the UTF-8 name).
    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var data = Data(withUnsafeBytes(of: namespace.uuid) { Array($0) })
        data.append(Data(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static func id(account: String, key: String) -> String {
        uuidV5(namespace: namespace, name: "\(account.lowercased())|starter-v\(version)|\(key)").uuidString.lowercased()
    }
    static func projectID(account: String) -> String { id(account: account, key: "project") }
    static func taskID(account: String, key: Key) -> String { id(account: account, key: key.rawValue) }
    static func starterTaskIDs(account: String) -> [String] { Key.allCases.map { taskID(account: account, key: $0) } }
    static func key(forTask id: String, account: String) -> Key? { Key.allCases.first { taskID(account: account, key: $0) == id.lowercased() } }
    static func isStarter(id: String, account: String) -> Bool {
        id.lowercased() == projectID(account: account) || key(forTask: id, account: account) != nil
    }

    // MARK: The flag

    struct Flag: Equatable, Sendable {
        var version = Onboarding.version
        var seededAt: String?
        var dismissed = false
        /// Platforms that have opened this account's starter project; the "other device" task ticks when both are here.
        var platforms: [String] = []
        /// An account that already had work was never given a starter project.
        var skipped = false

        var document: JSON {
            var fields: [String: JSON] = ["version": .number(Double(version)), "dismissed": .bool(dismissed), "platforms": .array(platforms.sorted().map(JSON.string))]
            if let seededAt { fields["seeded_at"] = .string(seededAt) }
            if skipped { fields["skipped"] = .bool(true) }
            return .object(fields)
        }
        init(version: Int = Onboarding.version, seededAt: String? = nil, dismissed: Bool = false, platforms: [String] = [], skipped: Bool = false) {
            self.version = version; self.seededAt = seededAt; self.dismissed = dismissed; self.platforms = platforms; self.skipped = skipped
        }
        init?(_ json: JSON) {
            guard case .object(let fields) = json, case .number(let number)? = fields["version"], number.isFinite, number.rounded() == number else { return nil }
            version = Int(number); seededAt = fields["seeded_at"]?.text.isEmpty == false ? fields["seeded_at"]?.text : nil
            dismissed = fields["dismissed"]?.flag ?? false; skipped = fields["skipped"]?.flag ?? false
            platforms = (fields["platforms"]?.list ?? []).map(\.text).filter { !$0.isEmpty }
        }
    }
    static func flag(in preferences: JSON) -> Flag? {
        guard case .object(let root) = preferences, case .object(let onboarding)? = root["onboarding"], let starter = onboarding["starter"] else { return nil }
        return Flag(starter)
    }
    /// `preferences` with the starter flag replaced and every other key (the web app's, other onboarding keys) untouched.
    static func writing(_ flag: Flag, into preferences: JSON) -> JSON {
        var root = preferences.object
        var onboarding = root["onboarding"]?.object ?? [:]
        onboarding["starter"] = flag.document
        root["onboarding"] = .object(onboarding)
        return .object(root)
    }
    static func adding(_ platform: Platform, to flag: Flag) -> Flag {
        var copy = flag
        if !copy.platforms.contains(platform.rawValue) { copy.platforms = (copy.platforms + [platform.rawValue]).sorted() }
        return copy
    }

    // MARK: Copy

    struct Copy: Equatable, Sendable { var title: String; var note: String }
    /// Platform wording. Titles stay the same on both platforms so a project seeded on one device reads correctly on
    /// the other; only the notes name the gesture, in the wording of the device that seeded it.
    static func copy(_ key: Key, platform: Platform, localMode: Bool) -> Copy {
        let mac = platform == .mac
        switch key {
        case .addTask:
            return Copy(title: "Add your first task", note: mac
                ? "Press ⌘N and type “Call mum tomorrow 5pm p1”. Taskfold picks out the date and priority."
                : "Tap + and type “Call mum tomorrow 5pm p1”. Taskfold picks out the date and priority.")
        case .reschedule:
            return Copy(title: "Drag this task to tomorrow", note: mac
                ? "Drop it on Upcoming in the sidebar, or drag it to tomorrow in Calendar."
                : "Press and hold, then drop it on tomorrow in Upcoming or Calendar.")
        case .subtask:
            return Copy(title: "Open this task and add a subtask", note: mac
                ? "Select it to open the inspector, then add a step under Subtasks."
                : "Tap it to open the details, then add a step under Subtasks.")
        case .workingHours:
            return Copy(title: "Set your working hours", note: mac
                ? "Taskfold plans your day inside them. Change them any time in Calendar, under Planner settings."
                : "Taskfold plans your day inside them. Change them any time in Settings ▸ Working hours.")
        case .calendar:
            return Copy(title: "Connect your calendar", note: mac
                ? "See your meetings next to your tasks. In Calendar, show the day panel, open Planner settings and choose a calendar."
                : "See your meetings next to your tasks. In Settings ▸ Calendars, connect and choose a calendar.")
        case .otherDevice:
            let device = platform.other.deviceName
            if localMode { return Copy(title: "Sign in to sync with \(device)", note: "Your tasks stay on this \(platform.deviceName) until you sign in.") }
            return Copy(title: "Get Taskfold on \(device)", note: "Sign in with the same account and everything is there.")
        }
    }
    /// What the toast says when a task ticks itself off.
    static func celebration(_ key: Key) -> String {
        switch key {
        case .addTask: "Nice, that's how you add tasks."
        case .reschedule: "Nice, that's how you reschedule."
        case .subtask: "Nice, big tasks start small."
        case .workingHours: "Your working hours are set."
        case .calendar: "Your calendar is connected."
        case .otherDevice: "Taskfold is on your other device."
        }
    }

    // MARK: Seeding

    /// The project and its six tasks as create-only mutations. The same account always gets the same IDs, so applying
    /// the plan twice (or on two devices) writes the same rows. `completed` marks tasks that are already true
    /// (working hours the account had before).
    static func seedMutations(account: String, platform: Platform, localMode: Bool, today: Date = Date(), completed: Set<Key> = [], calendar: Calendar = .current) -> [Mutation] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let project = Record(["id": .string(projectID(account: account)), "user_id": .string(account), "name": .string(projectName),
                              "color": .string(projectColor), "order_index": .number(0), "description": .string(projectIntro)])
        var changes = [Mutation(table: "projects", recordID: project.id, method: "POST", fields: project.fields, insertOnly: true)]
        for (index, key) in Key.allCases.enumerated() {
            let text = copy(key, platform: platform, localMode: localMode)
            // One second apart, newest first: lists show the newest task on top, so the lesson reads in order.
            var task = Record.task(user: account, project: project.id, date: key == .reschedule ? today : nil, createdAt: formatter.string(from: now.addingTimeInterval(-Double(index))))
            task["id"] = .string(taskID(account: account, key: key))
            task["title"] = .string(text.title); task["description"] = .string(text.note)
            if completed.contains(key) { task["completed"] = .bool(true) }
            changes.append(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields, insertOnly: true))
        }
        return changes
    }

    // MARK: Progress

    struct Progress: Equatable, Sendable {
        var done: Set<Key> = []
        var total: Int { Key.allCases.count }
        var count: Int { done.count }
        var finished: Bool { count == total }
        var fraction: Double { Double(count) / Double(total) }
    }
    /// Reads progress from the stored tasks, so a manual completion counts exactly like an automatic one.
    static func progress(tasks: [Record], account: String) -> Progress {
        var progress = Progress()
        for task in tasks where task.completed {
            if let key = key(forTask: task.id, account: account) { progress.done.insert(key) }
        }
        return progress
    }

    // MARK: Auto-complete rules

    /// What happened in the app that a starter task may be waiting for.
    enum Event: Sendable {
        /// Quick Add created a task; `groups` are the `QuickEntry` token groups it recognised.
        case quickAdd(taskID: String, groups: [String])
        /// Mutations the store just committed.
        case mutations([Mutation])
        /// "Set up your day" was saved.
        case setupSaved
        /// A device calendar is connected and at least one calendar is selected.
        case calendarConnected
        /// The account's flag now lists both platforms.
        case platforms([String])
    }
    /// Quick Add counts when the text carried a date, a time or a priority (the lesson is "type it naturally").
    static let quickAddGroups: Set<String> = ["priority", "due_date", "due_time"]

    /// Which of the still-open starter tasks `event` completes. Pure: the caller decides what to write.
    static func completions(for event: Event, account: String, open: Set<Key>, today: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> [Key] {
        var result: [Key] = []
        func hit(_ key: Key) { if open.contains(key), !result.contains(key) { result.append(key) } }
        switch event {
        case .quickAdd(let id, let groups):
            if !isStarter(id: id, account: account), !quickAddGroups.isDisjoint(with: groups) { hit(.addTask) }
        case .setupSaved:
            hit(.workingHours)
        case .calendarConnected:
            hit(.calendar)
        case .platforms(let platforms):
            if Set(platforms).isSuperset(of: [Platform.mac.rawValue, Platform.ios.rawValue]) { hit(.otherDevice) }
        case .mutations(let changes):
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today).map(Dates.day)
            for change in changes {
                switch (change.table, change.method) {
                case ("tasks", "PATCH"):
                    if key(forTask: change.recordID, account: account) == .reschedule, let tomorrow, change.fields["due_date"]?.text == tomorrow { hit(.reschedule) }
                case ("tasks", "POST"):
                    // A first subtask: any new task row that points at a parent (the starter's own rows never do).
                    if !isStarter(id: change.recordID, account: account), !(change.fields["parent_id"]?.text ?? "").isEmpty { hit(.subtask) }
                case ("view_preferences", "POST"), ("view_preferences", "PATCH"):
                    if change.recordID == "planner", let hours = change.fields["working_hours"], hours != .null { hit(.workingHours) }
                default: break
                }
            }
        }
        return result
    }
}
