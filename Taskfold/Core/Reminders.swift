import Foundation
import CryptoKit
import UserNotifications

/// Version 1 uses absolute instants or elapsed minutes relative to the planned time.
/// Unknown rows and additional fields survive edits, backup and sync unchanged.
struct ReminderSpec: Equatable, Identifiable, Sendable {
    static let plannedID = "00000000-0000-4000-8000-000000000001"
    static let maximum = 20
    var raw: [String: JSON]
    var id: String { raw["id"]?.text.lowercased() ?? "" }
    var enabled: Bool { raw["enabled"]?.flag ?? true }
    var offset: Int? {
        guard case .number(let value)? = raw["offset_minutes"], value.isFinite,
              value.rounded() == value, (-10080...10080).contains(value) else { return nil }
        return Int(value)
    }
    var absolute: Date? { TaskPlanning.instant(raw["at"]?.text ?? "") }
    var kind: String { raw["kind"]?.text ?? "" }
    init?(row: JSON) {
        let row = row.object
        guard row["version"] == .number(1), UUID(uuidString: row["id"]?.text ?? "") != nil,
              row["enabled"] == nil || row["enabled"] == .bool(true) || row["enabled"] == .bool(false),
              case .array(let channels)? = row["channels"], !channels.isEmpty,
              channels.allSatisfy({ ["local", "push", "email"].contains($0.text) }) else { return nil }
        raw = row
        switch kind {
        case "relative": guard row["anchor"] == .string("planned"), offset != nil else { return nil }
        case "absolute": guard absolute != nil, TimeZone(identifier: row["time_zone"]?.text ?? "") != nil else { return nil }
        default: return nil
        }
        if id == Self.plannedID && (kind != "relative" || offset != 0) { return nil }
    }
    static func relative(_ minutes: Int, id: String = UUID().uuidString.lowercased(), enabled: Bool = true) -> ReminderSpec {
        ReminderSpec(row: .object(["version": .number(1), "id": .string(id), "kind": .string("relative"), "anchor": .string("planned"), "offset_minutes": .number(Double(minutes)), "channels": .array([.string("local")]), "enabled": .bool(enabled)]))!
    }
    static func absolute(_ date: Date, id: String = UUID().uuidString.lowercased(), zone: String = TimeZone.current.identifier) -> ReminderSpec {
        ReminderSpec(row: .object(["version": .number(1), "id": .string(id), "kind": .string("absolute"), "at": .string(ISO8601DateFormatter().string(from: date)), "time_zone": .string(zone), "channels": .array([.string("local")]), "enabled": .bool(true)]))!
    }
    var local: Bool { raw["channels"]?.list.contains(.string("local")) == true }
    var locallyEditable: Bool { raw["channels"] == .array([.string("local")]) }
    var label: String {
        if kind == "absolute", let date = absolute { return date.formatted(date: .abbreviated, time: .shortened) }
        guard let offset else { return "Unsupported reminder" }
        if offset == 0 { return "At planned time" }
        return "\(abs(offset)) min \(offset < 0 ? "before" : "after")"
    }
    func date(task: Record, calendar: Calendar) -> Date? {
        if kind == "absolute" { return absolute }
        guard let anchor = Self.plannedDate(task, calendar: calendar), let offset else { return nil }
        return anchor.addingTimeInterval(Double(offset) * 60)
    }
    static func plannedDate(_ task: Record, calendar: Calendar) -> Date? {
        if !task.string("due_time").isEmpty { return TaskPlanning.start(task, calendar: calendar) }
        guard let day = Dates.parse(task.string("due_date"), calendar: calendar) else { return nil }
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)
    }
    static func rows(_ task: Record) -> [JSON] { task["reminder_specs"].list }
    static func plannedEnabled(_ task: Record) -> Bool {
        let rows = rows(task)
        return rows.isEmpty || rows.contains { guard let spec = ReminderSpec(row: $0) else { return false }; return spec.id == plannedID && spec.enabled && spec.local }
    }
    @discardableResult static func setPlanned(_ enabled: Bool, task: inout Record) -> Bool {
        var rows = rows(task)
        if enabled && duplicates(relative(0, id: plannedID), in: rows, excluding: plannedID) { return false }
        if let index = rows.firstIndex(where: { $0.object["id"]?.text.lowercased() == plannedID }), var spec = ReminderSpec(row: rows[index]), spec.locallyEditable {
            spec.raw["enabled"] = .bool(enabled); rows[index] = .object(spec.raw)
        } else if !rows.contains(where: { $0.object["id"]?.text.lowercased() == plannedID }), rows.count < maximum {
            rows.append(.object(relative(0, id: plannedID, enabled: enabled).raw))
        } else { return false }
        task["reminder_specs"] = .array(rows)
        return true
    }
    static func duplicates(_ spec: ReminderSpec, in rows: [JSON], excluding: String? = nil) -> Bool {
        guard spec.enabled && spec.local else { return false }
        return rows.compactMap(ReminderSpec.init(row:)).contains { other in
            guard other.id != excluding, other.enabled && other.local, other.kind == spec.kind else { return false }
            return spec.kind == "relative" ? other.offset == spec.offset : other.absolute == spec.absolute
        }
    }
    static func append(_ spec: ReminderSpec, task: inout Record) -> Bool {
        var values = rows(task)
        // Materialize the legacy default before introducing an explicit override.
        if values.isEmpty { values = [.object(relative(0, id: plannedID).raw)] }
        guard values.count < maximum, !values.contains(where: { $0.object["id"]?.text.lowercased() == spec.id }),
              !duplicates(spec, in: values) else { return false }
        values.append(.object(spec.raw)); task["reminder_specs"] = .array(values); return true
    }
    static func successorRows(_ rows: [JSON]) -> [JSON] {
        guard !rows.isEmpty else { return [] }
        let kept = rows.filter { ReminderSpec(row: $0)?.kind != "absolute" }
        return kept.isEmpty ? [.object(relative(0, id: plannedID, enabled: false).raw)] : kept
    }
}

/// The old device-wide switch migrates to the first active workspace only.
enum ReminderPreferences {
    static func key(_ account: String) -> String { "taskfold.reminders.enabled." + account.lowercased() }
    static func enabled(account: String, fixture: Bool = false, defaults: UserDefaults = .standard) -> Bool {
        guard !account.isEmpty else { return false }
        let ownerKey = "taskfold.reminders.legacyOwner" + (fixture ? ".fixture" : "")
        if defaults.string(forKey: ownerKey) == nil { defaults.set(account.lowercased(), forKey: ownerKey) }
        let key = key(account)
        if defaults.object(forKey: key) == nil {
            defaults.set(defaults.string(forKey: ownerKey) == account.lowercased() && defaults.bool(forKey: "remindersEnabled"), forKey: key)
        }
        return defaults.bool(forKey: key)
    }
}

enum ReminderEventKind: String, Sendable { case task, focusFinish }

struct DueReminder: Equatable, Sendable {
    var kind: ReminderEventKind = .task
    var id: String
    var title: String
    var body: String
    var date: Date
    var taskID: String
    var specID: String
    var signature: String
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func events(tasks: [Record], calendar: Calendar = .current) -> [DueReminder] {
        tasks.filter { !$0.completed }.flatMap { task -> [DueReminder] in
            let raw = ReminderSpec.rows(task)
            let specs = raw.isEmpty ? [ReminderSpec.relative(0, id: ReminderSpec.plannedID)] : raw.prefix(ReminderSpec.maximum).compactMap(ReminderSpec.init(row:))
            // Duplicate IDs cannot produce competing requests; retain only the first valid row.
            var seen = Set<String>()
            return specs.filter { seen.insert($0.id).inserted && $0.enabled && $0.local }.compactMap { spec in
                guard let date = spec.date(task: task, calendar: calendar) else { return nil }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let encoded = (try? encoder.encode(JSON.object(spec.raw))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let signature = digest(encoded + "|" + String(date.timeIntervalSince1970) + "|completion:" + String(task["completion_version"].integer))
                return DueReminder(id: raw.isEmpty ? task.id : task.id + "." + spec.id, title: task.title, body: task.string("description"), date: date, taskID: task.id, specID: spec.id, signature: signature)
            }
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    static func plan(tasks: [Record], now: Date = Date(), calendar: Calendar = .current, limit: Int = 60) -> [DueReminder] {
        Array(events(tasks: tasks, calendar: calendar).filter { $0.date > now }.prefix(max(0, limit)))
    }
}

struct ReminderRequest: Equatable, Sendable {
    static let prefix = "taskfold.r2."
    var identifier: String
    var account: String
    var event: DueReminder
    var fireAt: Date
    var snoozed = false
    static func make(account: String, event: DueReminder, fireAt: Date? = nil, snoozed: Bool = false) -> Self {
        let id = (event.kind == .focusFinish ? FocusFinish.prefix : prefix) + DueReminder.digest(account + "|" + event.taskID.lowercased() + "|" + event.specID)
        return Self(identifier: id + (snoozed ? ".snooze" : ""), account: account, event: event, fireAt: fireAt ?? event.date, snoozed: snoozed)
    }
    func valid(account: String, events: [DueReminder]) -> Bool {
        self.account == account && events.contains { $0.taskID == event.taskID && $0.specID == event.specID && $0.signature == event.signature && $0.kind == event.kind }
    }
}
struct ReminderState: Sendable {
    var revision: Int
    var account: String
    var events: [DueReminder]
    var now = Date()
}
struct ReminderReport: Equatable, Sendable {
    var revision: Int
    var scheduled = 0
    var deferred = 0
    var failures = 0
    var focusScheduled = false
    var focusFailure = false
    mutating func accepted(_ request: ReminderRequest) {
        if request.event.kind == .focusFinish { focusScheduled = true } else { scheduled += 1 }
    }
    mutating func failed(_ request: ReminderRequest) {
        if request.event.kind == .focusFinish { focusFailure = true } else { failures += 1 }
    }
}
protocol ReminderCenter: Sendable {
    func pending() async -> [ReminderRequest]
    func removeInvalid(account: String, events: [DueReminder]) async
    func remove(_ identifiers: [String]) async
    func add(_ request: ReminderRequest) async throws
}

/// A single drain serializes notification mutations even across suspension and account changes.
actor ReminderScheduler {
    private let center: any ReminderCenter
    private var desired = ReminderState(revision: -1, account: "", events: [])
    var currentRevision: Int { desired.revision }
    private var sequence = 0
    private var running = false
    private var snoozes: [ReminderRequest] = []
    private var waiters: [CheckedContinuation<ReminderReport, Never>] = []
    init(center: any ReminderCenter = SystemReminderCenter()) { self.center = center }
    func update(_ state: ReminderState) async -> ReminderReport {
        guard state.revision > desired.revision else { return ReminderReport(revision: desired.revision) }
        desired = state; sequence += 1
        return await sweep()
    }
    func snooze(account: String, taskID: String, specID: String, signature: String, now: Date = Date()) async -> ReminderReport? {
        guard account == desired.account, let event = desired.events.first(where: { $0.kind == .task && $0.taskID == taskID && $0.specID == specID && $0.signature == signature }) else { return nil }
        let request = ReminderRequest.make(account: account, event: event, fireAt: now.addingTimeInterval(3600), snoozed: true)
        snoozes.removeAll { $0.identifier == request.identifier }; snoozes.append(request); sequence += 1
        return await sweep()
    }
    private func sweep() async -> ReminderReport {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if !running { running = true; Task { await self.drain() } }
        }
    }
    private func drain() async {
        while true {
            let token = sequence, state = desired
            let existing = await center.pending()
            guard token == sequence else { continue }
            snoozes.removeAll { !$0.valid(account: state.account, events: state.events) || $0.fireAt <= state.now }
            let retained = existing.filter { $0.snoozed && $0.valid(account: state.account, events: state.events) && $0.fireAt > state.now }
            var requests = state.account.isEmpty ? [] : state.events.filter { $0.date > state.now }.map { ReminderRequest.make(account: state.account, event: $0) }
            requests += retained.filter { old in !snoozes.contains(where: { $0.identifier == old.identifier }) }
            requests += snoozes
            requests.sort {
                if $0.event.kind != $1.event.kind { return $0.event.kind == .focusFinish }
                return $0.fireAt == $1.fireAt ? $0.identifier < $1.identifier : $0.fireAt < $1.fireAt
            }
            var report = ReminderReport(revision: state.revision, deferred: max(0, requests.count - 60))
            requests = Array(requests.prefix(60))
            await center.removeInvalid(account: state.account, events: state.events)
            guard token == sequence else { continue }
            let expected = Set(requests.map(\.identifier))
            await center.remove(existing.map(\.identifier).filter { !expected.contains($0) })
            guard token == sequence else { continue }
            var acceptedSnoozes = Set<String>()
            for request in requests {
                if token != sequence { break }
                if existing.contains(request) { report.accepted(request); if request.snoozed { acceptedSnoozes.insert(request.identifier) }; continue }
                do { try await center.add(request); report.accepted(request); if request.snoozed { acceptedSnoozes.insert(request.identifier) } }
                catch { report.failed(request) }
            }
            guard token == sequence else { continue }
            snoozes.removeAll { acceptedSnoozes.contains($0.identifier) }
            let completions = waiters; waiters = []; running = false
            for completion in completions { completion.resume(returning: report) }
            return
        }
    }
}

struct SystemReminderCenter: ReminderCenter {
    private var center: UNUserNotificationCenter { .current() }
    static func decode(_ request: UNNotificationRequest) -> ReminderRequest? {
        let info = request.content.userInfo
        guard (request.identifier.hasPrefix(ReminderRequest.prefix) || request.identifier.hasPrefix(FocusFinish.prefix)),
              let account = info["accountID"] as? String, let task = info["taskID"] as? String,
              let spec = info["specID"] as? String, let signature = info["signature"] as? String,
              let original = info["originalAt"] as? Double, let fire = info["fireAt"] as? Double else { return nil }
        let kind: ReminderEventKind = request.identifier.hasPrefix(FocusFinish.prefix) ? .focusFinish : .task
        guard (kind == .focusFinish ? request.content.categoryIdentifier == FocusFinish.category && info["eventKind"] as? String == kind.rawValue : request.content.categoryIdentifier == "taskfold.reminder" && (info["eventKind"] == nil || info["eventKind"] as? String == kind.rawValue)) else { return nil }
        if kind == .focusFinish {
            guard FocusFinishReceipt(info: info) != nil, info["snoozed"] as? Bool == false, original.isFinite, fire.isFinite,
                  original == fire, (0...(Double(FocusSession.maximumTimestamp) / 1000 + 180 * 60)).contains(original) else { return nil }
        }
        let decoded = ReminderRequest(identifier: request.identifier, account: account,
            event: DueReminder(kind: kind, id: info["eventID"] as? String ?? task + "." + spec, title: request.content.title, body: request.content.body, date: Date(timeIntervalSince1970: original), taskID: task, specID: spec, signature: signature),
            fireAt: Date(timeIntervalSince1970: fire), snoozed: info["snoozed"] as? Bool ?? false)
        if kind == .focusFinish && decoded.identifier != ReminderRequest.make(account: account, event: decoded.event).identifier { return nil }
        return decoded
    }
    func pending() async -> [ReminderRequest] { await center.pendingNotificationRequests().compactMap(Self.decode) }
    func removeInvalid(account: String, events: [DueReminder]) async {
        func stale(_ request: UNNotificationRequest) -> Bool {
            // Touch only Taskfold's reminder category and versioned namespace.
            guard request.content.categoryIdentifier == "taskfold.reminder" || request.identifier.hasPrefix(ReminderRequest.prefix) || request.content.categoryIdentifier == FocusFinish.category || request.identifier.hasPrefix(FocusFinish.prefix) else { return false }
            return Self.decode(request)?.valid(account: account, events: events) != true
        }
        center.removePendingNotificationRequests(withIdentifiers: await center.pendingNotificationRequests().filter(stale).map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: await center.deliveredNotifications().map(\.request).filter(stale).map(\.identifier))
    }
    func remove(_ identifiers: [String]) async { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = calendar.timeZone; components.calendar = calendar
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
    static func content(for request: ReminderRequest) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.event.title; content.body = request.event.body; content.sound = .default
        content.categoryIdentifier = request.event.kind == .focusFinish ? FocusFinish.category : "taskfold.reminder"
        content.userInfo = ["eventKind": request.event.kind.rawValue, "eventID": request.event.id, "accountID": request.account, "taskID": request.event.taskID, "specID": request.event.specID, "signature": request.event.signature, "originalAt": request.event.date.timeIntervalSince1970, "fireAt": request.fireAt.timeIntervalSince1970, "snoozed": request.snoozed]
        return content
    }
    func add(_ request: ReminderRequest) async throws {
        // An explicit UTC instant preserves both sides of a daylight-saving fold.
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: Self.content(for: request), trigger: Self.trigger(at: request.fireAt)))
    }
}


/// One optional device-local finish alert shares the existing serialized 60-request budget.
/// State and task completion revisions invalidate old alerts; task titles are not signature inputs.
enum FocusFinish {
    static let prefix = "taskfold.f1."
    static let category = "taskfold.focus.finished"
    static func preferenceKey(_ account: String) -> String { "taskfold.focus.alerts.enabled." + account.lowercased() }
    static func event(row: Record?, tasks: [Record], account: String, available: Bool = true, conflict: Bool = false) -> DueReminder? {
        guard available, !conflict, !account.isEmpty, let row,
              let session = FocusSessionChange.session(in: row, account: account), session.status == .running,
              let end = session.endDate, let task = tasks.first(where: { $0.id.lowercased() == session.taskID && !$0.completed }) else { return nil }
        let document: JSON = .object(["state": session.document, "baseline": .object(FocusSessionChange.baseline(row)), "completion": task["completion_version"]])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document), let encoded = String(data: data, encoding: .utf8) else { return nil }
        // Calendar notification triggers resolve to whole seconds. Never alert before the timer ends.
        return DueReminder(kind: .focusFinish, id: "focus." + session.id, title: "Time well spent",
            body: PinnedNotes.excerpt(task.title, characters: 160, bytes: 1000).0 + "\nYour Focus timer is finished.",
            date: Date(timeIntervalSince1970: ceil(end.timeIntervalSince1970)), taskID: session.taskID,
            specID: session.id, signature: DueReminder.digest(encoded))
    }
}
struct FocusFinishReceipt: Equatable, Sendable {
    var account: String
    var task: String
    var session: String
    var signature: String
    init?(info: [AnyHashable: Any]) {
        guard let account = info["accountID"] as? String, !account.isEmpty, account.utf8.count <= 256,
              let task = info["taskID"] as? String, UUID(uuidString: task) != nil,
              let session = info["specID"] as? String, UUID(uuidString: session) != nil,
              let signature = info["signature"] as? String, signature.count == 64,
              signature.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        self.account = account; self.task = task; self.session = session; self.signature = signature
    }
    func valid(account: String, event: DueReminder?, now: Date = Date()) -> Bool {
        self.account == account && event?.kind == .focusFinish && event?.taskID == task && event?.specID == session && event?.signature == signature && (event?.date ?? .distantFuture) <= now
    }
}

/// A notification's validated Open action keeps its workspace incarnation through scene activation.
struct ReminderTaskRoute: Equatable, Sendable {
    var workspace: WorkspaceBinding
    var taskID: String
    var specID: String
    var signature: String
    func matches(account: String, generation: UUID, events: [DueReminder]) -> Bool {
        workspace.matches(account: account, generation: generation) && events.contains {
            $0.kind == .task && $0.taskID == taskID && $0.specID == specID && $0.signature == signature
        }
    }
}
