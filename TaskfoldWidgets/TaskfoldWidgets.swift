import Foundation
#if WIDGET_MODEL_TESTING
import TaskfoldCore
#endif
#if !WIDGET_MODEL_TESTING
import WidgetKit
import SwiftUI
import AppIntents
#endif

/// A version-tolerant projection. Completion tokens hand off actions without credentials or task mutations.
struct WidgetTask: Codable, Identifiable {
    var id: String
    var title: String
    var due: String
    var time: String
    var priority: Int
    var project: String
    var color: String
    var projectID: String? = nil
    var deadline: String? = nil
    var duration: Int? = nil
    var scheduledAt: String? = nil
    var timeZone: String? = nil
    var completionToken: String? = nil
    var estimate: Int? { duration.flatMap { (1...10080).contains($0) ? $0 : nil } }
    var deadlineDay: String? { deadline.flatMap { WidgetSnapshot.validDay($0) ? $0 : nil } }
    func displayed(calendar: Calendar) -> WidgetTask {
        var task = self
        guard WidgetSnapshot.validDay(due) else { return task }
        guard !task.due.isEmpty, !time.isEmpty, let zone = timeZone, TimeZone(identifier: zone) != nil, let value = scheduledAt else { return task }
        guard let instant = Self.instant(value) else { return task }
        var local = Calendar(identifier: .gregorian); local.timeZone = calendar.timeZone
        let clock = local.dateComponents([.hour, .minute], from: instant)
        task.due = WidgetSnapshot.day(instant, calendar: local)
        task.time = String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0)
        return task
    }
    private static func instant(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    func start(calendar: Calendar) -> Date? {
        guard WidgetSnapshot.validDay(due), !time.isEmpty else { return nil }
        if let zone = timeZone, TimeZone(identifier: zone) != nil, let value = scheduledAt, let instant = Self.instant(value) { return instant }
        let clock = time.split(separator: ":").compactMap { Int($0) }
        guard clock.count >= 2, (0...23).contains(clock[0]), (0...59).contains(clock[1]) else { return nil }
        let parts = due.split(separator: "-").compactMap { Int($0) }
        var local = Calendar(identifier: .gregorian); local.timeZone = calendar.timeZone
        guard let day = local.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return local.date(bySettingHour: clock[0], minute: clock[1], second: 0, of: day, matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first, direction: .forward)
    }
    var url: URL { WidgetLinks.task(id) }
}

enum WidgetLinks {
    static func task(_ id: String) -> URL { scoped("task", id: id) }
    static func scoped(_ host: String, id: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        let component = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "taskfold://" + host + "/" + component) ?? URL(string: "taskfold://today")!
    }
}

enum InboxWidgetBatch: String, CaseIterable, Codable {
    case five = "5", ten = "10", all = "all"
    var limit: Int? { Int(rawValue) }
}
struct WidgetInboxReading {
    var tasks: [WidgetTask]?
    var count: Int? { tasks?.count }
    var undated: Int { tasks?.filter { $0.due.isEmpty }.count ?? 0 }
    var priorities: Int { tasks?.filter { $0.priority <= 2 }.count ?? 0 }
}
extension WidgetLinks {
    static func inboxReview(account: String, batch: InboxWidgetBatch) -> URL {
        guard !account.isEmpty else { return URL(string: "taskfold://inbox")! }
        var components = URLComponents()
        components.scheme = "taskfold"; components.host = "review"; components.path = "/inbox"
        components.queryItems = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "batch", value: batch.rawValue)]
        return components.url ?? URL(string: "taskfold://inbox")!
    }
}

enum WindowBudget: String, CaseIterable, Codable { case ten = "10", twentyFive = "25", fortyFive = "45"; var minutes: Int { Int(rawValue) ?? 25 } }
enum WindowScope: String, CaseIterable, Codable { case ready, inbox, all }
enum WidgetPalette: String, CaseIterable, Codable { case standard, rose, lavender, mint }
enum DeadlineWindow: String, CaseIterable, Codable { case week = "7", fortnight = "14", month = "30"; var days: Int { Int(rawValue) ?? 7 } }



enum CapacityDay: String, CaseIterable, Codable { case today, tomorrow; var offset: Int { self == .today ? 0 : 1 } }
struct WidgetCapacityDay: Codable, Equatable {
    var working: Int, busy: Int, estimated: Int, unknown: Int, overdue: Int
    var afterKnownWork: Int { working - busy - estimated }
    var valid: Bool { (0...1500).contains(working) && (0...working).contains(busy) && (0...100_000_000).contains(estimated) && (0...1_000_000).contains(unknown) && (0...1_000_000).contains(overdue) }
}
struct WidgetCapacity: Codable {
    var version: Int
    var timeZone: String
    var calendarState: String
    var calendarUpdated: TimeInterval?
    var hours: String
    var days: [String: WidgetCapacityDay]
}
struct WidgetCapacityReading {
    var day: WidgetCapacityDay?
    var state: String
    var dayKey: String
    var hours: String = ""
    var canCalculateRoom: Bool { state == "ready" || state == "off" }
    var calendarNote: String {
        switch state {
        case "ready": return "Calendar busy time included"
        case "off": return "Calendar not included"
        case "incomplete": return "Calendar data incomplete"
        case "choose": return "Choose calendars in Taskfold"
        case "unavailable": return "Calendar access unavailable"
        case "settings": return "Update Taskfold to read working hours"
        default: return "Open Taskfold to refresh"
        }
    }
    static func minutes(_ value: Int) -> String {
        let value = abs(value)
        if value < 60 { return "\(value)m" }
        return value % 60 == 0 ? "\(value / 60)h" : "\(value / 60)h \(value % 60)m"
    }
}

struct WidgetDay: Identifiable {
    var date: Date
    var count: Int
    var id: Date { date }
}

struct WidgetList: Codable, Identifiable, Sendable {
    var id: String
    var recordID: String
    var kind: String
    var name: String
    var days: [String: [String]]
    var timeZone: String
    var invalid: Bool
    var clockUpdated: Double? = nil
    var clockValidUntil: Double? = nil
    func belongs(to account: String) -> Bool {
        guard !account.isEmpty, let data = Data(base64Encoded: id), let key = try? JSONDecoder().decode([String].self, from: data) else { return false }
        return key == [account, kind, recordID] && ["project", "label", "filter"].contains(kind)
    }
    var url: URL { WidgetLinks.scoped(kind == "filter" ? "view" : kind, id: recordID) }
    var typeName: String { kind == "project" ? "Project" : kind == "label" ? "Label" : "Saved filter" }
}

enum WidgetListStatus: Equatable { case ready, choose, unavailable, refresh }

struct WidgetNote: Codable, Identifiable, Sendable {
    var id: String
    var taskID: String
    var title: String
    var text: String
    var truncated: Bool
    var completed: Bool
    func belongs(to account: String) -> Bool {
        guard !account.isEmpty, !taskID.isEmpty, taskID.utf8.count <= 200, !taskID.contains(":"), !taskID.contains("|"),
              title.count <= 160, title.utf8.count <= 1000, text.count <= 1200, text.utf8.count <= 6000,
              let data = Data(base64Encoded: id), let key = try? JSONDecoder().decode([String].self, from: data) else { return false }
        return key == [account, "note", taskID]
    }
    func url(account: String) -> URL {
        var parts = URLComponents(); parts.scheme = "taskfold"; parts.host = "note"
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/%?#")
        parts.percentEncodedPath = "/" + (taskID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        parts.queryItems = [URLQueryItem(name: "account", value: account)]
        return parts.url ?? URL(string: "taskfold://notes")!
    }
}
enum WidgetNoteStatus: Equatable { case ready, choose, unavailable, refresh }

struct WidgetSnapshot: Codable {
    var updated: TimeInterval
    var tasks: [WidgetTask]
    var version: Int
    var account: String
    var lists: [WidgetList] = []
    var notes: [WidgetNote]? = nil // nil means this publisher predates pinned notes.
    var projectPulse: ProjectPulseSnapshot? = nil
    var focusSession: FocusWidgetSnapshot? = nil
    var capacity: WidgetCapacity? = nil
    var pendingSync: Int = 0
    var pendingTaskIDs: [String] = [] // Derived under the same disk lock as the snapshot read.
    init(updated: TimeInterval, tasks: [WidgetTask], version: Int = 2, account: String = "", lists: [WidgetList] = []) {
        self.updated = updated; self.tasks = tasks; self.version = version; self.account = account; self.lists = lists
    }
    private enum CodingKeys: String, CodingKey { case updated, tasks, version, account, lists, pendingSync, capacity, notes, focusSession, projectPulse }
    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        version = try row.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...2).contains(version) else { throw DecodingError.dataCorruptedError(forKey: .version, in: row, debugDescription: "Unsupported widget snapshot version") }
        updated = try row.decode(TimeInterval.self, forKey: .updated)
        tasks = try row.decode([WidgetTask].self, forKey: .tasks)
        account = try row.decodeIfPresent(String.self, forKey: .account) ?? ""
        lists = try row.decodeIfPresent([WidgetList].self, forKey: .lists) ?? []
        pendingSync = max(0, try row.decodeIfPresent(Int.self, forKey: .pendingSync) ?? 0)
        notes = try? row.decode([WidgetNote].self, forKey: .notes)
        capacity = try? row.decode(WidgetCapacity.self, forKey: .capacity)
        focusSession = try? row.decode(FocusWidgetSnapshot.self, forKey: .focusSession)
        projectPulse = try? row.decode(ProjectPulseSnapshot.self, forKey: .projectPulse)
    }
    var availableNotes: [WidgetNote] {
        var seen = Set<String>()
        return (notes ?? []).filter { seen.insert($0.taskID).inserted && $0.belongs(to: account) }.sorted {
            $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    func note(_ id: String?) -> WidgetNote? { guard let id else { return nil }; return availableNotes.first { $0.id == id } }
    func noteSubtitle(_ note: WidgetNote) -> String {
        let duplicate = availableNotes.filter { $0.title.caseInsensitiveCompare(note.title) == .orderedSame }.count > 1
        return (note.completed ? "Completed task notes" : "Task notes") + (duplicate ? " · " + note.taskID : "")
    }
    func notesFresh(at date: Date) -> Bool { !account.isEmpty && notes != nil && updated.isFinite && updated > 0 && date.timeIntervalSinceReferenceDate >= updated - 300 && date.timeIntervalSinceReferenceDate < updated + 86_400 }
    func noteTimelineDates(from date: Date, calendar: Calendar = .current) -> [Date] {
        let days = Self.timelineDates(from: date, calendar: calendar)
        guard notesFresh(at: date) else { return days }
        let expiry = Date(timeIntervalSinceReferenceDate: updated + 86_400)
        return Array(Set(days + [expiry])).sorted()
    }
    func noteStatus(_ id: String?, at date: Date) -> WidgetNoteStatus {
        guard notesFresh(at: date) else { return .refresh }
        guard id != nil else { return .choose }
        return note(id) == nil ? .unavailable : .ready
    }
    var notesURL: URL {
        guard !account.isEmpty else { return URL(string: "taskfold://all")! }
        var parts = URLComponents(); parts.scheme = "taskfold"; parts.host = "notes"; parts.queryItems = [URLQueryItem(name: "account", value: account)]
        return parts.url ?? URL(string: "taskfold://all")!
    }
    func focusSessionStatus(at date: Date) -> FocusWidgetStatus { focusSession?.status(at: date, owner: account, updated: updated) ?? .refresh }
    func focusSessionTimelineDates(from date: Date) -> [Date] {
        guard focusSession?.valid(for: account) == true else { return [date] }
        return focusSession!.timelineDates(from: date, updated: updated)
    }
    var focusSessionURL: URL { account.isEmpty ? URL(string: "taskfold://today")! : FocusSessionLink(account: account).url }
    var availablePulseProjects: [PulseProject] {
        guard projectPulse?.fresh(at: Date(), owner: account, updated: updated) == true else { return [] }
        return projectPulse!.projects.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func pulseSubtitle(_ project: PulseProject) -> String {
        let duplicate = projectPulse?.projects.filter { $0.name.caseInsensitiveCompare(project.name) == .orderedSame }.count ?? 0
        return duplicate > 1 ? "Project · " + project.recordID : "Project"
    }
    func pulseStatus(_ id: String?, at date: Date, calendar: Calendar = .current) -> PulseWidgetStatus { projectPulse?.status(id, at: date, owner: account, updated: updated, calendar: calendar) ?? .refresh }
    func pulseURL(_ id: String?) -> URL {
        guard !account.isEmpty else { return URL(string: "taskfold://all")! }
        return id.flatMap(PulseProject.link)?.url ?? ProjectPulseLink(account: account).url
    }
    var hasPlanningFields: Bool { version == 2 }
    static let empty = WidgetSnapshot(updated: 0, tasks: [])
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func validDay(_ value: String) -> Bool {
        guard value.count == 10, value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        return day(date, calendar: calendar) == value
    }
    private func ordered(_ rows: [WidgetTask], calendar: Calendar) -> [WidgetTask] {
        rows.sorted {
            if $0.due != $1.due { return ($0.due.isEmpty ? "9999" : $0.due) < ($1.due.isEmpty ? "9999" : $1.due) }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if let first = $0.start(calendar: calendar), let second = $1.start(calendar: calendar), first != second { return first < second }
            if $0.time != $1.time { return ($0.time.isEmpty ? "24:00" : $0.time) < ($1.time.isEmpty ? "24:00" : $1.time) }
            return $0.id < $1.id
        }
    }
    func today(at date: Date, calendar: Calendar = .current) -> [WidgetTask] {
        let key = Self.day(date, calendar: calendar)
        return ordered(tasks.map { $0.displayed(calendar: calendar) }.filter { Self.validDay($0.due) && $0.due <= key }, calendar: calendar)
    }
    /// Outstanding scheduled work first, then unscheduled P1/P2 work. Future tasks never jump the queue.
    func focus(at date: Date, calendar: Calendar = .current) -> WidgetTask? {
        today(at: date, calendar: calendar).first ?? ordered(tasks.map { $0.displayed(calendar: calendar) }.filter { $0.due.isEmpty && $0.priority <= 2 }, calendar: calendar).first
    }
    func week(at date: Date, calendar: Calendar = .current) -> [WidgetDay] {
        let localTasks = tasks.map { $0.displayed(calendar: calendar) }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)) else { return nil }
            let key = Self.day(day, calendar: calendar)
            return WidgetDay(date: day, count: localTasks.filter { $0.due == key }.count)
        }
    }
    /// Independent deadlines in the inclusive local-day window, plus every missed deadline.
    func deadlines(at date: Date, days: Int = 7, calendar: Calendar = .current) -> [WidgetTask] {
        guard hasPlanningFields, (1...30).contains(days), let last = calendar.date(byAdding: .day, value: days - 1, to: date) else { return [] }
        let end = Self.day(last, calendar: calendar)
        return tasks.filter { $0.deadlineDay.map { $0 <= end } ?? false }.sorted {
            if $0.deadlineDay != $1.deadlineDay { return ($0.deadlineDay ?? "9999") < ($1.deadlineDay ?? "9999") }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id < $1.id
        }.map { $0.displayed(calendar: calendar) }
    }
    func windowTasks(scope: WindowScope, at date: Date, calendar: Calendar = .current) -> [WidgetTask] {
        guard hasPlanningFields else { return [] }
        let today = Self.day(date, calendar: calendar)
        return tasks.map { $0.displayed(calendar: calendar) }.filter {
            switch scope {
            case .ready: return $0.due.isEmpty || (Self.validDay($0.due) && $0.due <= today)
            case .inbox: return $0.projectID == ""
            case .all: return true
            }
        }
    }
    /// Unknown/invalid estimates are never represented as zero-minute work.
    func smallWindow(minutes: Int, scope: WindowScope = .ready, at date: Date, calendar: Calendar = .current) -> [WidgetTask] {
        guard [10, 25, 45].contains(minutes) else { return [] }
        return windowTasks(scope: scope, at: date, calendar: calendar).filter { $0.estimate.map { $0 <= minutes } ?? false }.sorted {
            if $0.deadlineDay != $1.deadlineDay { return ($0.deadlineDay ?? "9999") < ($1.deadlineDay ?? "9999") }
            if $0.due != $1.due { return ($0.due.isEmpty ? "9999" : $0.due) < ($1.due.isEmpty ? "9999" : $1.due) }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.estimate != $1.estimate { return ($0.estimate ?? Int.max) < ($1.estimate ?? Int.max) }
            return $0.id < $1.id
        }
    }
    func listSubtitle(_ target: WidgetList) -> String {
        let duplicates = availableLists.filter { $0.kind == target.kind && $0.name.caseInsensitiveCompare(target.name) == .orderedSame }.count
        return target.typeName + (duplicates > 1 ? " · " + target.recordID : "")
    }
    var availableLists: [WidgetList] { lists.filter { $0.belongs(to: account) }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    func list(_ id: String?) -> WidgetList? { guard let id else { return nil }; return availableLists.first { $0.id == id } }
    func listStatus(_ id: String?, at date: Date, calendar: Calendar = .current) -> WidgetListStatus {
        guard id != nil else { return .choose }
        guard let target = list(id), !target.invalid else { return .unavailable }
        if target.clockUpdated != nil || target.clockValidUntil != nil {
            guard target.kind == "filter", let start = target.clockUpdated, let end = target.clockValidUntil,
                  start.isFinite, end.isFinite, end - start == 60,
                  date.timeIntervalSinceReferenceDate >= start, date.timeIntervalSinceReferenceDate < end else { return .refresh }
        }
        if target.kind == "filter", (target.timeZone != calendar.timeZone.identifier || target.days[Self.day(date, calendar: calendar)] == nil) { return .refresh }
        return .ready
    }
    func listTasks(_ id: String?, at date: Date, calendar: Calendar = .current) -> [WidgetTask] {
        guard listStatus(id, at: date, calendar: calendar) == .ready, let target = list(id) else { return [] }
        let ids = target.kind == "filter" ? target.days[Self.day(date, calendar: calendar)] ?? [] : target.days["*"] ?? []
        let byID = Dictionary(tasks.map { ($0.id, $0.displayed(calendar: calendar)) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ids.compactMap { seen.insert($0).inserted ? byID[$0] : nil }
    }
    func scoped(to id: String?, at date: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        guard let id else { return self }
        var copy = self; copy.tasks = listTasks(id, at: date, calendar: calendar); return copy
    }

    func inboxReading() -> WidgetInboxReading {
        guard version == 2, !account.isEmpty, updated.isFinite, updated > 0,
              tasks.allSatisfy({ !$0.id.isEmpty && $0.projectID != nil }) else { return WidgetInboxReading(tasks: nil) }
        var seen = Set<String>()
        let inbox = tasks.filter { seen.insert($0.id).inserted }.filter { $0.projectID == "" }
        let sorted = inbox.enumerated().sorted { $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority }.map(\.element)
        return WidgetInboxReading(tasks: sorted)
    }

    func inboxReviewURL(batch: InboxWidgetBatch) -> URL {
        guard let count = inboxReading().count, count > 0 else { return URL(string: "taskfold://inbox")! }
        return WidgetLinks.inboxReview(account: account, batch: batch)
    }

    func capacityReading(at date: Date, day: CapacityDay = .today, calendar input: Calendar = .current) -> WidgetCapacityReading {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        let selected = calendar.date(byAdding: .day, value: day.offset, to: date) ?? date
        let key = Self.day(selected, calendar: calendar)
        guard !account.isEmpty, let capacity, capacity.version == 1, capacity.timeZone == calendar.timeZone.identifier else { return WidgetCapacityReading(day: nil, state: "refresh", dayKey: key) }
        if capacity.calendarState == "settings" { return WidgetCapacityReading(day: nil, state: "settings", dayKey: key) }
        guard let value = capacity.days[key], value.valid else { return WidgetCapacityReading(day: nil, state: "refresh", dayKey: key) }
        var state = capacity.calendarState
        if !["ready", "off", "incomplete", "choose", "unavailable", "refresh"].contains(state) { state = "refresh" }
        if state == "ready" || state == "incomplete" {
            if let updated = capacity.calendarUpdated, updated.isFinite, date.timeIntervalSinceReferenceDate >= updated - 300, date.timeIntervalSinceReferenceDate < updated + 3600 {} else { state = "refresh" }
        }
        return WidgetCapacityReading(day: value, state: state, dayKey: key, hours: capacity.hours)
    }
    func capacityTimelineDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = Self.timelineDates(from: now, calendar: calendar)
        if let capacity, ["ready", "incomplete"].contains(capacity.calendarState), let stamp = capacity.calendarUpdated, stamp.isFinite {
            let expiry = Date(timeIntervalSinceReferenceDate: stamp + 3600)
            if expiry > now, expiry < dates.last ?? now { dates.append(expiry) }
        }
        return Array(Set(dates)).sorted()
    }

    /// Clock-window projections expire at their exact minute; retain the ordinary day entries.
    func listTimelineDates(_ id: String?, from now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = Self.timelineDates(from: now, calendar: calendar)
        if let expiry = list(id)?.clockValidUntil, expiry.isFinite {
            let date = Date(timeIntervalSinceReferenceDate: expiry)
            if date > now, date < dates.last ?? now { dates.append(date) }
        }
        return Array(Set(dates)).sorted()
    }

    /// Day entries make relative selections change at midnight even while the app is closed.
    static func timelineDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        [now] + (1..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now)) }
    }
    #if !WIDGET_MODEL_TESTING
    static func load() -> WidgetSnapshot {
        guard let read = try? WidgetActionDisk.system().read(), let data = read.data,
              var snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        snapshot.pendingTaskIDs = read.pendingTaskIDs
        // Signed-out v2 payloads cannot accidentally expose retained task rows.
        return snapshot.version == 2 && snapshot.account.isEmpty ? .empty : snapshot
    }
    #endif
}

#if !WIDGET_MODEL_TESTING
struct TodayEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    static var preview: TodayEntry {
        let now = Date()
        return TodayEntry(date: now, snapshot: WidgetSnapshot(updated: now.timeIntervalSinceReferenceDate, tasks: [
            WidgetTask(id: "preview-1", title: "Sketch the next big idea", due: WidgetSnapshot.day(now), time: "09:00", priority: 1, project: "Studio", color: "#e31e4b", projectID: "preview-studio", deadline: WidgetSnapshot.day(Calendar.current.date(byAdding: .day, value: 1, to: now)!), duration: 25),
            WidgetTask(id: "preview-2", title: "Send the proposal", due: WidgetSnapshot.day(now), time: "14:30", priority: 2, project: "Work", color: "#7863c8", projectID: "preview-work", deadline: WidgetSnapshot.day(Calendar.current.date(byAdding: .day, value: 3, to: now)!), duration: 10),
            WidgetTask(id: "preview-3", title: "Take a proper lunch break", due: WidgetSnapshot.day(now), time: "", priority: 3, project: "Personal", color: "#32856d", projectID: "preview-personal"),
            WidgetTask(id: "preview-4", title: "Review the first draft", due: WidgetSnapshot.day(Calendar.current.date(byAdding: .day, value: 2, to: now)!), time: "", priority: 2, project: "Studio", color: "#e31e4b", projectID: "preview-studio", duration: 45),
            WidgetTask(id: "preview-5", title: "File the expense report", due: WidgetSnapshot.day(now), time: "", priority: 2, project: "Work", color: "#7863c8", projectID: "preview-work", deadline: WidgetSnapshot.day(Calendar.current.date(byAdding: .day, value: -1, to: now)!), duration: 15)
        ].map { var task = $0; task.completionToken = UUID().uuidString.lowercased(); return task }, account: "preview", lists: [WidgetList(id: (try! JSONEncoder().encode(["preview", "project", "preview-studio"])).base64EncodedString(), recordID: "preview-studio", kind: "project", name: "Studio", days: ["*": ["preview-1", "preview-4"]], timeZone: TimeZone.current.identifier, invalid: false)]))
    }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .preview }
    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? .preview : TodayEntry(date: Date(), snapshot: .load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let entries = WidgetSnapshot.timelineDates(from: now).map { TodayEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private func adaptiveWidgetTint(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    #if os(iOS)
    return Color(uiColor: UIColor { traits in
        let rgb = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    })
    #else
    return Color(nsColor: NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    })
    #endif
}
private let brand = adaptiveWidgetTint((0.88, 0.12, 0.30), (1, 0.43, 0.60))
private let plum = adaptiveWidgetTint((0.39, 0.28, 0.65), (0.73, 0.63, 0.98))
private let mint = adaptiveWidgetTint((0.16, 0.48, 0.39), (0.43, 0.80, 0.66))
private func widgetColor(_ hex: String) -> Color {
    let value = hex.replacingOccurrences(of: "#", with: "")
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return brand }
    return Color(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
}

struct WidgetSurface: View {
    var tint: Color
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.24 : 0.10), tint.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct WidgetFooter: View {
    let entry: TodayEntry
    var body: some View {
        if entry.snapshot.updated == 0 {
            Text("Open Taskfold to begin").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else if !entry.snapshot.pendingTaskIDs.isEmpty {
            Link("Open Taskfold to finish", destination: URL(string: "taskfold://all")!).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else if entry.snapshot.pendingSync > 0 {
            Text("Saved · sync pending").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else if entry.date.timeIntervalSinceReferenceDate - entry.snapshot.updated > 86_400 {
            Label("Open app to refresh", systemImage: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("TASKFOLD").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.5).foregroundStyle(.secondary)
        }
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry
    var tasks: [WidgetTask] { entry.snapshot.today(at: entry.date) }
    var limit: Int { family == .systemLarge ? 7 : 2 }
    var body: some View {
        #if os(iOS)
        switch family {
        case .accessoryCircular:
            ZStack { AccessoryWidgetBackground(); VStack(spacing: 0) { Text("\(tasks.count)").font(.title2.bold()).monospacedDigit(); Text("due").font(.caption2) } }
                .widgetURL(URL(string: "taskfold://today"))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) { Text(tasks.first?.title ?? "All clear").font(.headline).lineLimit(1); Text("\(tasks.count) due · including overdue").font(.caption2).lineLimit(1) }
                .widgetURL(tasks.first?.url ?? URL(string: "taskfold://today"))
        case .accessoryInline:
            Text("Taskfold · \(tasks.count) due").widgetURL(URL(string: "taskfold://today"))
        default: content
        }
        #else
        content
        #endif
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) { Text("Today").font(.headline); Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text("\(tasks.count)").font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(brand)
            }
            if tasks.isEmpty {
                Spacer(minLength: 0)
                Label("All clear for today", systemImage: "sun.max").font(.subheadline.weight(.medium))
                Text("No scheduled tasks outstanding.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(tasks.prefix(limit)) { task in
                    Link(destination: task.url) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(widgetColor(task.color)).frame(width: 3, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(task.due < WidgetSnapshot.day(entry.date) ? "Overdue · P\(task.priority)" : task.time.isEmpty ? "P\(task.priority)" : task.time).font(.system(size: 9)).foregroundStyle(task.due < WidgetSnapshot.day(entry.date) ? brand : .secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            HStack { WidgetFooter(entry: entry); Spacer(); if tasks.count > limit { Text("+\(tasks.count - limit)").font(.caption2).foregroundStyle(.secondary) }; Link(destination: URL(string: "taskfold://add")!) { Image(systemName: "plus.circle.fill").foregroundStyle(brand) }.accessibilityLabel("Add task") }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: brand) }
        .widgetURL(URL(string: "taskfold://today"))
    }
}

struct FocusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry
    var task: WidgetTask? { entry.snapshot.focus(at: entry.date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Focus", systemImage: "scope").font(.caption.weight(.semibold)).foregroundStyle(plum)
            if let task {
                Text(task.title).font(family == .systemSmall ? .headline : .title2.bold()).lineLimit(3).minimumScaleFactor(0.85)
                Text(task.due.isEmpty ? "Unscheduled priority · P\(task.priority)" : task.due < WidgetSnapshot.day(entry.date) ? "Overdue · P\(task.priority)" : "Today · P\(task.priority)\(task.time.isEmpty ? "" : " · \(task.time)")").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                HStack { if entry.date.timeIntervalSinceReferenceDate - entry.snapshot.updated > 86_400 { WidgetFooter(entry: entry) } else { Text(task.project.isEmpty ? "Inbox" : task.project).font(.caption2).lineLimit(1) }; Spacer(); Image(systemName: "arrow.up.right.circle.fill").font(.title2).foregroundStyle(plum) }
            } else {
                Text("Space to focus").font(.headline)
                Text("Nothing due or high priority. Capture your next step.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if family != .systemSmall || task == nil { WidgetFooter(entry: entry) }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: plum) }
        .widgetURL(task?.url ?? URL(string: "taskfold://add"))
    }
}

struct WeekWidgetView: View {
    let entry: TodayEntry
    var days: [WidgetDay] { entry.snapshot.week(at: entry.date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Next 7 days", systemImage: "calendar").font(.headline); Spacer(); Text("\(days.reduce(0) { $0 + $1.count }) scheduled").font(.caption).foregroundStyle(mint) }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        Text("\(day.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        RoundedRectangle(cornerRadius: 5).fill(mint.opacity(day.count == 0 ? 0.12 : 0.75)).frame(height: day.count == 0 ? 4 : max(9, 40 * Double(day.count) / Double(max(1, days.map(\.count).max() ?? 1))))
                        Text(day.date.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))), \(day.count) scheduled tasks")
                }
            }
            HStack { WidgetFooter(entry: entry); Spacer(); let overdue = entry.snapshot.today(at: entry.date).filter { $0.due < WidgetSnapshot.day(entry.date) }.count; if overdue > 0 { Text("\(overdue) overdue").font(.caption2).foregroundStyle(brand) } }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: mint) }
        .widgetURL(URL(string: "taskfold://upcoming"))
    }
}

struct CaptureWidgetView: View {
    let entry: TodayEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "plus.circle.fill").font(.system(size: 32, weight: .light)).foregroundStyle(brand)
            Text("Catch a thought").font(.headline)
            Text("Add a task in one tap.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("QUICK CAPTURE").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.2).foregroundStyle(brand)
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: brand) }
        .widgetURL(URL(string: "taskfold://add"))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskfoldToday", provider: TodayProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Today").description("Your scheduled tasks, including overdue work, with quick capture.")
            #if os(iOS)
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
            #else
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            #endif
    }
}
struct FocusWidget: Widget {
    var body: some WidgetConfiguration { StaticConfiguration(kind: "TaskfoldFocus", provider: TodayProvider()) { FocusWidgetView(entry: $0) }.configurationDisplayName("Focus").description("One next action: outstanding scheduled work, then unscheduled priorities.").supportedFamilies([.systemSmall, .systemMedium]) }
}
struct WeekWidget: Widget {
    var body: some WidgetConfiguration { StaticConfiguration(kind: "TaskfoldWeek", provider: TodayProvider()) { WeekWidgetView(entry: $0) }.configurationDisplayName("Week ahead").description("See scheduled task counts for the next seven days. Tap to review your week.").supportedFamilies([.systemMedium]) }
}
struct CaptureWidget: Widget {
    var body: some WidgetConfiguration { StaticConfiguration(kind: "TaskfoldCapture", provider: TodayProvider()) { CaptureWidgetView(entry: $0) }.configurationDisplayName("Quick capture").description("Capture a thought before it gets away.").supportedFamilies([.systemSmall]) }
}

extension WindowBudget: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Time budget")
    static var caseDisplayRepresentations: [WindowBudget: DisplayRepresentation] = [.ten: "10 minutes", .twentyFive: "25 minutes", .fortyFive: "45 minutes"]
}
extension WindowScope: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task scope")
    static var caseDisplayRepresentations: [WindowScope: DisplayRepresentation] = [.ready: "Ready work", .inbox: "Inbox", .all: "All open tasks"]
    var label: String { switch self { case .ready: return "Today, overdue & undated"; case .inbox: return "Open Inbox tasks"; case .all: return "All open tasks · future dates included" } }
    var url: URL { URL(string: self == .inbox ? "taskfold://inbox" : "taskfold://all")! }
}
extension DeadlineWindow: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Deadline window")
    static var caseDisplayRepresentations: [DeadlineWindow: DisplayRepresentation] = [.week: "7 days", .fortnight: "14 days", .month: "30 days"]
}
private let paletteMint = mint
extension WidgetPalette: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Widget color")
    static var caseDisplayRepresentations: [WidgetPalette: DisplayRepresentation] = [.standard: "Default", .rose: "Rose", .lavender: "Lavender", .mint: "Mint"]
    func color(fallback: Color) -> Color { switch self { case .standard: return fallback; case .rose: return brand; case .lavender: return plum; case .mint: return paletteMint } }
}

struct WidgetListEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task list")
    static var defaultQuery = WidgetListQuery()
    var id: String
    var name: String
    var subtitle: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)") }
    init(_ list: WidgetList, subtitle: String) { id = list.id; name = list.name; self.subtitle = subtitle }
}
struct WidgetListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetListEntity] {
        let snapshot = WidgetSnapshot.load()
        return identifiers.compactMap { snapshot.list($0).map { WidgetListEntity($0, subtitle: snapshot.listSubtitle($0)) } }
    }
    func entities(matching string: String) async throws -> [WidgetListEntity] {
        let snapshot = WidgetSnapshot.load()
        return snapshot.availableLists.filter { $0.name.localizedCaseInsensitiveContains(string) }.map { WidgetListEntity($0, subtitle: snapshot.listSubtitle($0)) }
    }
    func suggestedEntities() async throws -> [WidgetListEntity] { let snapshot = WidgetSnapshot.load(); return snapshot.availableLists.map { WidgetListEntity($0, subtitle: snapshot.listSubtitle($0)) } }
}

struct ListConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "My list"
    static var description = IntentDescription("Keep one project's, label's or saved filter's open tasks close by.")
    @Parameter(title: "List") var list: WidgetListEntity?
    @Parameter(title: "Color", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide task and list names", default: false) var hideTitles: Bool
}

struct WindowConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "A small window"
    static var description = IntentDescription("Pick work with a known estimate that fits your available time. Ready work includes today, overdue and undated tasks.")
    @Parameter(title: "Time available", default: .twentyFive) var budget: WindowBudget
    @Parameter(title: "Limit to a list") var list: WidgetListEntity?
    @Parameter(title: "Tasks", default: .ready) var scope: WindowScope
    @Parameter(title: "Color", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide task and list names", default: false) var hideTitles: Bool
}
struct DeadlineConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Deadline radar"
    static var description = IntentDescription("Missed and approaching hard deadlines. Moving the planned work date leaves the deadline unchanged.")
    @Parameter(title: "Look ahead", default: .week) var window: DeadlineWindow
    @Parameter(title: "Limit to a list") var list: WidgetListEntity?
    @Parameter(title: "Color", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide task and list names", default: false) var hideTitles: Bool
}

struct WindowEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var budget: WindowBudget = .twentyFive
    var scope: WindowScope = .ready
    var palette: WidgetPalette = .standard
    var hideTitles = false
    var listID: String? = nil
    var footer: TodayEntry { TodayEntry(date: date, snapshot: snapshot) }
}
struct DeadlineEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var window: DeadlineWindow = .week
    var palette: WidgetPalette = .standard
    var hideTitles = false
    var listID: String? = nil
    var footer: TodayEntry { TodayEntry(date: date, snapshot: snapshot) }
}
struct WindowProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WindowEntry { WindowEntry(date: Date(), snapshot: TodayEntry.preview.snapshot) }
    func snapshot(for configuration: WindowConfiguration, in context: Context) async -> WindowEntry {
        entry(Date(), snapshot: context.isPreview ? TodayEntry.preview.snapshot : .load(), configuration: configuration)
    }
    func timeline(for configuration: WindowConfiguration, in context: Context) async -> Timeline<WindowEntry> {
        let snapshot = WidgetSnapshot.load()
        return Timeline(entries: snapshot.listTimelineDates(configuration.list?.id, from: Date()).map { entry($0, snapshot: snapshot, configuration: configuration) }, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: WindowConfiguration) -> WindowEntry {
        WindowEntry(date: date, snapshot: snapshot, budget: configuration.budget, scope: configuration.scope, palette: configuration.palette, hideTitles: configuration.hideTitles, listID: configuration.list?.id)
    }
}
struct DeadlineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DeadlineEntry { DeadlineEntry(date: Date(), snapshot: TodayEntry.preview.snapshot) }
    func snapshot(for configuration: DeadlineConfiguration, in context: Context) async -> DeadlineEntry {
        entry(Date(), snapshot: context.isPreview ? TodayEntry.preview.snapshot : .load(), configuration: configuration)
    }
    func timeline(for configuration: DeadlineConfiguration, in context: Context) async -> Timeline<DeadlineEntry> {
        let snapshot = WidgetSnapshot.load()
        return Timeline(entries: snapshot.listTimelineDates(configuration.list?.id, from: Date()).map { entry($0, snapshot: snapshot, configuration: configuration) }, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: DeadlineConfiguration) -> DeadlineEntry {
        DeadlineEntry(date: date, snapshot: snapshot, window: configuration.window, palette: configuration.palette, hideTitles: configuration.hideTitles, listID: configuration.list?.id)
    }
}

private func widgetDate(_ day: String) -> String {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return day }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
struct PlanningWidgetEmpty: View {
    var snapshot: WidgetSnapshot
    var title: String
    var message: String
    var symbol: String
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !compact { Image(systemName: symbol).font(.title2).foregroundStyle(.secondary) }
            Text(snapshot.updated == 0 ? "Make it yours" : !snapshot.hasPlanningFields ? "Refresh your widgets" : title).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(2)
            Text(snapshot.updated == 0 ? "Open Taskfold to load your tasks." : !snapshot.hasPlanningFields ? "Open Taskfold for deadline and estimate data." : message).font(.caption2).foregroundStyle(.secondary).lineLimit(compact ? 2 : 3)
        }
    }
}

struct DeadlineWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeadlineEntry
    private var tint: Color { entry.palette.color(fallback: brand) }
    private var tasks: [WidgetTask] { entry.snapshot.scoped(to: entry.listID, at: entry.date).deadlines(at: entry.date, days: entry.window.days) }
    private var today: String { WidgetSnapshot.day(entry.date) }
    private var missed: Int { tasks.filter { ($0.deadlineDay ?? "9999") < today }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 5) {
            HStack { Label("Deadline radar", systemImage: "flag.checkered").font(family == .systemSmall ? .caption.weight(.semibold) : .headline); Spacer(minLength: 0); if family != .systemSmall && entry.snapshot.updated > 0 && entry.snapshot.hasPlanningFields && (entry.listID == nil || entry.snapshot.listStatus(entry.listID, at: entry.date) == .ready) { Text("\(tasks.count)").font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint) } }
            if let listID = entry.listID, entry.snapshot.listStatus(listID, at: entry.date) != .ready {
                WidgetListEmpty(status: entry.snapshot.listStatus(listID, at: entry.date))
            } else if tasks.isEmpty {
                Spacer(minLength: 0)
                PlanningWidgetEmpty(snapshot: entry.snapshot, title: "Room to breathe", message: "No missed deadlines or cutoffs in the next \(entry.window.days) days.", symbol: "checkmark.seal", compact: family == .systemSmall)
            } else {
                Text(family == .systemSmall ? (missed > 0 ? "\(missed) missed · \(entry.window.days) days" : "Next \(entry.window.days) days") : (missed > 0 ? "\(missed) missed · next \(entry.window.days) days" : "Hard cutoffs · next \(entry.window.days) days")).font(.caption2).foregroundStyle(missed > 0 ? tint : .secondary).lineLimit(1)
                ForEach(tasks.prefix(family == .systemSmall ? 1 : 3)) { task in
                    Link(destination: task.url) {
                        if family == .systemSmall {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.hideTitles ? "Task names hidden" : task.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true).privacySensitive()
                                deadlineBadge(task)
                            }
                        } else {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.7)).frame(width: 3, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.hideTitles ? "Private task" : task.title).font(.caption.weight(.medium)).lineLimit(1).privacySensitive()
                                    if !entry.hideTitles { Text(task.project.isEmpty ? "Inbox" : task.project).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).privacySensitive() }
                                }
                                Spacer(minLength: 0)
                                deadlineBadge(task)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            HStack { WidgetFooter(entry: entry.footer); Spacer(minLength: 0); if family != .systemSmall && tasks.count > 3 { Text("+\(tasks.count - 3)").font(.caption2).foregroundStyle(.secondary) } }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: tint) }
        .widgetURL(tasks.first?.url ?? entry.snapshot.list(entry.listID)?.url ?? URL(string: "taskfold://all"))
    }
    private func deadlineBadge(_ task: WidgetTask) -> some View {
        let day = task.deadlineDay ?? ""
        let text = day == today ? "Today" : day < today ? "Missed · " + widgetDate(day) : widgetDate(day)
        return Text(text).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 4).foregroundStyle(tint).background(tint.opacity(0.12), in: .capsule)
            .accessibilityLabel("Deadline \(day)\(day < today ? ", missed" : "")")
    }
}

struct WindowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WindowEntry
    private var tint: Color { entry.palette.color(fallback: plum) }
    private var tasks: [WidgetTask] { entry.snapshot.scoped(to: entry.listID, at: entry.date).smallWindow(minutes: entry.budget.minutes, scope: entry.scope, at: entry.date) }
    private var unknown: Int { entry.snapshot.scoped(to: entry.listID, at: entry.date).windowTasks(scope: entry.scope, at: entry.date).filter { $0.estimate == nil }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 5) {
            HStack {
                Label(family == .systemSmall ? "Small window" : "A small window", systemImage: "hourglass").font(family == .systemSmall ? .caption.weight(.semibold) : .headline).foregroundStyle(tint)
                Spacer(minLength: 0)
                if family != .systemSmall { budgetBadge }
            }
            if family == .systemSmall { HStack(alignment: .firstTextBaseline, spacing: 5) { Text("\(entry.budget.minutes)").font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint); Text("min to spare").font(.caption2).foregroundStyle(.secondary) } }
            else { Text(entry.listID == nil ? entry.scope.label : entry.hideTitles ? "Selected list · " + entry.scope.label : (entry.snapshot.list(entry.listID)?.name ?? "Selected list") + " · " + entry.scope.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).privacySensitive() }
            if let listID = entry.listID, entry.snapshot.listStatus(listID, at: entry.date) != .ready {
                WidgetListEmpty(status: entry.snapshot.listStatus(listID, at: entry.date))
            } else if tasks.isEmpty {
                PlanningWidgetEmpty(snapshot: entry.snapshot, title: "Nothing fits yet", message: unknown > 0 ? "\(unknown) tasks need estimates. Add one in Taskfold." : "No known estimate fits this budget and scope.", symbol: "sparkle", compact: family == .systemSmall)
            } else {
                ForEach(tasks.prefix(family == .systemSmall ? 1 : 3)) { task in
                    Link(destination: task.url) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.hideTitles ? "Task names hidden" : task.title).font(family == .systemSmall ? .subheadline.weight(.semibold) : .caption.weight(.medium)).lineLimit(family == .systemSmall ? 2 : 1).fixedSize(horizontal: false, vertical: family == .systemSmall).privacySensitive()
                                if family != .systemSmall && !entry.hideTitles { Text(task.project.isEmpty ? "Inbox" : task.project).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).privacySensitive() }
                            }
                            Spacer(minLength: 0)
                            if family != .systemSmall { Text("\(task.estimate ?? 0)m").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(tint) }
                        }
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            if family == .systemSmall && entry.snapshot.hasPlanningFields && entry.snapshot.updated > 0 && entry.date.timeIntervalSinceReferenceDate - entry.snapshot.updated <= 86400 && (entry.listID == nil || entry.snapshot.listStatus(entry.listID, at: entry.date) == .ready) {
                Text("\(tasks.count) fit\(unknown > 0 ? " · \(unknown) unestimated" : " · estimates only")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                HStack { WidgetFooter(entry: entry.footer); Spacer(minLength: 0); if tasks.count > 3 { Text("+\(tasks.count - 3) fit").font(.caption2).foregroundStyle(.secondary) }; if unknown > 0 { Text("\(unknown) unestimated").font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }
            }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: tint) }
        .widgetURL(tasks.first?.url ?? (entry.snapshot.updated == 0 || !entry.snapshot.hasPlanningFields ? URL(string: "taskfold://all") : entry.snapshot.list(entry.listID)?.url ?? entry.scope.url))
    }
    private var budgetBadge: some View { Text("\(entry.budget.minutes) min").font(.subheadline.weight(.semibold)).monospacedDigit().padding(.horizontal, 9).padding(.vertical, 4).foregroundStyle(tint).background(tint.opacity(0.12), in: .capsule) }
}

struct ListEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var listID: String? = nil
    var palette: WidgetPalette = .standard
    var hideTitles = false
}
struct ListProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ListEntry { let preview = TodayEntry.preview; return ListEntry(date: preview.date, snapshot: preview.snapshot, listID: preview.snapshot.availableLists.first?.id) }
    func snapshot(for configuration: ListConfiguration, in context: Context) async -> ListEntry { context.isPreview ? placeholder(in: context) : entry(Date(), snapshot: .load(), configuration: configuration) }
    func timeline(for configuration: ListConfiguration, in context: Context) async -> Timeline<ListEntry> {
        let snapshot = WidgetSnapshot.load()
        return Timeline(entries: snapshot.listTimelineDates(configuration.list?.id, from: Date()).map { entry($0, snapshot: snapshot, configuration: configuration) }, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: ListConfiguration) -> ListEntry {
        ListEntry(date: date, snapshot: snapshot, listID: configuration.list?.id, palette: configuration.palette, hideTitles: configuration.hideTitles)
    }
}
struct WidgetListEmpty: View {
    var status: WidgetListStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status == .choose ? "Choose your list" : status == .refresh ? "Refresh this list" : "List unavailable").font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(status == .choose ? "Edit this widget to pick a project, label or filter." : status == .refresh ? "Open Taskfold to update this filter for the current date, time and time zone." : "Open Taskfold to refresh, or edit this widget to choose another list.").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}
struct ListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ListEntry
    private var target: WidgetList? { entry.snapshot.list(entry.listID) }
    private var tasks: [WidgetTask] { entry.snapshot.listTasks(entry.listID, at: entry.date) }
    private var status: WidgetListStatus { entry.snapshot.listStatus(entry.listID, at: entry.date) }
    private var tint: Color { entry.palette.color(fallback: mint) }
    private var listHeader: some View {
        HStack {
            Label(entry.hideTitles ? "My list" : target?.name ?? "My list", systemImage: "list.bullet.rectangle")
                .font(family == .systemSmall ? .caption.weight(.semibold) : .headline)
                .lineLimit(family == .systemSmall ? 2 : 1).fixedSize(horizontal: false, vertical: true).privacySensitive()
            Spacer(minLength: 0)
            if status == .ready { Text("\(tasks.count)").font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint) }
        }
        .contentShape(Rectangle())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if family != .systemSmall, status == .ready, let url = target?.url {
                Link(destination: url) { listHeader }.buttonStyle(.plain)
            } else {
                listHeader
            }
            if status != .ready { Spacer(minLength: 0); WidgetListEmpty(status: status) }
            else if tasks.isEmpty {
                Spacer(minLength: 0); Text("All clear").font(.headline)
                Text("No open tasks in this list.").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(tasks.prefix(family == .systemSmall ? 1 : family == .systemLarge ? 5 : 2)) { task in
                    HStack(spacing: 2) {
                        if let token = task.completionToken, !entry.snapshot.account.isEmpty {
                            let pending = entry.snapshot.pendingTaskIDs.contains(task.id)
                            Button(intent: CompleteWidgetTaskIntent(account: entry.snapshot.account, taskID: task.id, token: token)) {
                                Image(systemName: pending ? "hourglass" : "circle")
                                    .font(.system(size: 21, weight: .regular)).foregroundStyle(task.priority <= 2 ? tint : .secondary)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(pending)
                                .accessibilityLabel(pending ? "Waiting to complete" : entry.hideTitles ? "Complete private task" : "Complete \(task.title)")
                        }
                        Link(destination: task.url) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.hideTitles ? "Private task" : task.title).font(.caption.weight(.semibold)).lineLimit(family == .systemSmall ? 3 : 2).privacySensitive()
                                if WidgetSnapshot.validDay(task.due) {
                                    Text("Planned \(widgetDate(task.due))").font(.caption2).foregroundStyle(.secondary)
                                        .accessibilityLabel("Planned \(task.due)")
                                }
                                if family != .systemSmall, let day = task.deadlineDay { Text(widgetDate(day)).font(.caption2).foregroundStyle(tint).accessibilityLabel("Deadline \(day)") }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
            WidgetFooter(entry: TodayEntry(date: entry.date, snapshot: entry.snapshot))
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: tint) }
        .widgetURL(status == .ready ? (family == .systemSmall ? tasks.first?.url ?? target?.url : target?.url) : URL(string: "taskfold://all"))
    }
}
struct ListWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldMyList", intent: ListConfiguration.self, provider: ListProvider()) { ListWidgetView(entry: $0) }
            .configurationDisplayName("My list").description("Your chosen project's, label's or saved filter's open tasks.").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct DeadlineWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldDeadlines", intent: DeadlineConfiguration.self, provider: DeadlineProvider()) { DeadlineWidgetView(entry: $0) }
            .configurationDisplayName("Deadline radar").description("Missed and approaching hard cutoffs, independent of the work plan.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct WindowWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldSmallWindow", intent: WindowConfiguration.self, provider: WindowProvider()) { WindowWidgetView(entry: $0) }
            .configurationDisplayName("A small window").description("Pick a task with a known estimate that fits 10, 25 or 45 minutes.").supportedFamilies([.systemSmall, .systemMedium])
    }
}


// MARK: Day capacity
extension CapacityDay: AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Capacity day")
    static var caseDisplayRepresentations: [CapacityDay: DisplayRepresentation] = [.today: "Today", .tomorrow: "Tomorrow"]
}
struct CapacityConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Day capacity"
    static var description = IntentDescription("Compare your whole day's task estimates, working hours and selected calendar busy time. Missing estimates stay visible.")
    @Parameter(title: "Day", default: .today) var day: CapacityDay
    @Parameter(title: "Color", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide capacity details", default: false) var hideDetails: Bool
}
struct CapacityEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var day: CapacityDay = .today
    var palette: WidgetPalette = .standard
    var hideDetails = false
    static var preview: CapacityEntry {
        let date = Date(); var snapshot = TodayEntry.preview.snapshot
        let days = Dictionary(uniqueKeysWithValues: (0..<8).compactMap { offset -> (String, WidgetCapacityDay)? in
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: date) else { return nil }
            return (WidgetSnapshot.day(day), WidgetCapacityDay(working: 480, busy: 90, estimated: 50, unknown: 1, overdue: 0))
        })
        snapshot.capacity = WidgetCapacity(version: 1, timeZone: TimeZone.current.identifier, calendarState: "ready", calendarUpdated: date.timeIntervalSinceReferenceDate, hours: "09:00–17:00", days: days)
        return CapacityEntry(date: date, snapshot: snapshot)
    }
}
struct CapacityProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CapacityEntry { .preview }
    func snapshot(for configuration: CapacityConfiguration, in context: Context) async -> CapacityEntry {
        entry(Date(), snapshot: context.isPreview ? CapacityEntry.preview.snapshot : .load(), configuration: configuration)
    }
    func timeline(for configuration: CapacityConfiguration, in context: Context) async -> Timeline<CapacityEntry> {
        let now = Date(), snapshot = WidgetSnapshot.load()
        let entries = snapshot.capacityTimelineDates(from: now).map { entry($0, snapshot: snapshot, configuration: configuration) }
        return Timeline(entries: entries, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: CapacityConfiguration) -> CapacityEntry {
        CapacityEntry(date: date, snapshot: snapshot, day: configuration.day, palette: configuration.palette, hideDetails: configuration.hideDetails)
    }
}
struct CapacityWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CapacityEntry
    private var reading: WidgetCapacityReading { entry.snapshot.capacityReading(at: entry.date, day: entry.day) }
    private var tint: Color { entry.palette.color(fallback: mint) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(tint)
                Text(family == .systemSmall ? "Capacity" : "Day capacity").font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(entry.day == .today ? "Today" : "Tomorrow").font(family == .systemSmall ? .system(size: 9) : .caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if entry.hideDetails {
                Spacer(minLength: 0)
                Text("Your day's plan").font(.headline).lineLimit(2)
                Text("Open Taskfold for capacity details.").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            } else if let day = reading.day {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline(day)).font(.system(size: family == .systemSmall ? 34 : 36, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                            .foregroundStyle(reading.canCalculateRoom && day.afterKnownWork < 0 && day.working > 0 ? brand : .primary)
                        Text(qualifier(day)).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: family == .systemSmall)
                    }.frame(maxWidth: .infinity, alignment: .leading).privacySensitive()
                    if family != .systemSmall {
                        VStack(alignment: .leading, spacing: 4) {
                            metric("Working", value: WidgetCapacityReading.minutes(day.working), color: tint)
                            metric("Calendar", value: reading.state == "ready" ? WidgetCapacityReading.minutes(day.busy) : reading.state == "incomplete" ? "≥ " + WidgetCapacityReading.minutes(day.busy) : "—", color: plum)
                            metric("Tasks", value: WidgetCapacityReading.minutes(day.estimated), color: brand)
                        }.privacySensitive()
                    }
                }
                capacityBar(day).padding(.vertical, 2)
                Text(caution(day)).font(.caption2).foregroundStyle(.secondary).lineLimit(family == .systemSmall ? 2 : 1).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: family == .systemSmall).privacySensitive()
                Spacer(minLength: 0)
                Text(reading.calendarNote).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Spacer(minLength: 0)
                Text(reading.state == "settings" ? "Capacity unavailable" : entry.snapshot.updated == 0 ? "Make room for your day" : "Refresh your day").font(.headline).lineLimit(2)
                Text(reading.state == "settings" ? "Update Taskfold to read your working hours." : "Open Taskfold to load working hours and your plan.").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 0)
            }
            WidgetFooter(entry: TodayEntry(date: entry.date, snapshot: entry.snapshot))
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: tint) }
        .widgetURL(WidgetLinks.scoped("day", id: reading.dayKey))
    }
    private func headline(_ day: WidgetCapacityDay) -> String {
        if !reading.canCalculateRoom { return "Review" }
        if day.working == 0 { return "No workday" }
        return WidgetCapacityReading.minutes(day.afterKnownWork) + (day.afterKnownWork < 0 ? " over" : "")
    }
    private func qualifier(_ day: WidgetCapacityDay) -> String {
        if !reading.canCalculateRoom { return "Calendar needs attention" }
        if day.working == 0 { return WidgetCapacityReading.minutes(day.estimated) + " task estimates" }
        if day.afterKnownWork < 0 { return "over the day’s budget" }
        return reading.state == "off" ? "whole day after estimates" : "whole day after known work"
    }
    private func caution(_ day: WidgetCapacityDay) -> String {
        let estimate = day.unknown == 0 ? "All planned tasks estimated" : "\(day.unknown) unestimated"
        return estimate + (day.overdue == 0 ? "" : " · \(day.overdue) overdue outside plan")
    }
    private func metric(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }.font(.system(size: 10)).accessibilityElement(children: .combine)
    }
    private func capacityBar(_ day: WidgetCapacityDay) -> some View {
        GeometryReader { geometry in
            let denominator = Double(max(1, max(day.working, day.busy + day.estimated)))
            HStack(spacing: 0) {
                if reading.state == "ready" || reading.state == "incomplete" { Rectangle().fill(plum.opacity(0.75)).frame(width: geometry.size.width * Double(day.busy) / denominator) }
                Rectangle().fill(brand.opacity(0.75)).frame(width: geometry.size.width * Double(day.estimated) / denominator)
                Spacer(minLength: 0)
            }.background(tint.opacity(0.17)).clipShape(Capsule())
        }.frame(height: 6).accessibilityHidden(true)
    }
}
struct CapacityWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldDayCapacity", intent: CapacityConfiguration.self, provider: CapacityProvider()) { CapacityWidgetView(entry: $0) }
            .configurationDisplayName("Day capacity").description("Your whole-day budget after task estimates and known calendar busy time, with missing estimates made clear.").supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension InboxWidgetBatch: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Inbox review"
    static var caseDisplayRepresentations: [InboxWidgetBatch: DisplayRepresentation] = [.five: "Five tasks", .ten: "Ten tasks", .all: "All Inbox tasks"]
}
struct InboxConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Inbox reset"
    static var description = IntentDescription("Choose how much to review and what to show on this widget.")
    @Parameter(title: "Review", default: .five) var batch: InboxWidgetBatch
    @Parameter(title: "Color", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide Inbox details", default: false) var hideDetails: Bool
}
struct InboxEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var batch: InboxWidgetBatch = .five
    var palette: WidgetPalette = .standard
    var hideDetails = false
    static var preview: InboxEntry {
        let tasks = ["Untangle the launch checklist", "Book the studio", "Sketch the next little idea", "Check the delivery", "Save a good reference", "Read the draft"].enumerated().map { index, title in
            WidgetTask(id: "inbox-\(index)", title: title, due: index == 1 ? WidgetSnapshot.day(Date()) : "", time: "", priority: index < 2 ? 2 : 4, project: "", color: "", projectID: "")
        }
        return InboxEntry(date: Date(), snapshot: WidgetSnapshot(updated: Date().timeIntervalSinceReferenceDate, tasks: tasks, account: "preview"))
    }
}
struct InboxProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> InboxEntry { .preview }
    func snapshot(for configuration: InboxConfiguration, in context: Context) async -> InboxEntry {
        context.isPreview ? .preview : entry(Date(), snapshot: .load(), configuration: configuration)
    }
    func timeline(for configuration: InboxConfiguration, in context: Context) async -> Timeline<InboxEntry> {
        let now = Date(), snapshot = WidgetSnapshot.load()
        return Timeline(entries: WidgetSnapshot.timelineDates(from: now).map { entry($0, snapshot: snapshot, configuration: configuration) }, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: InboxConfiguration) -> InboxEntry {
        InboxEntry(date: date, snapshot: snapshot, batch: configuration.batch, palette: configuration.palette, hideDetails: configuration.hideDetails)
    }
}
struct InboxWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: InboxEntry
    private var reading: WidgetInboxReading { entry.snapshot.inboxReading() }
    private var tint: Color { entry.palette.color(fallback: plum) }
    private var count: Int? { reading.count }
    private var reviewLabel: String {
        guard let count, count > 0 else { return "Open Inbox" }
        let batchCount = min(count, entry.batch.limit ?? count)
        return batchCount < count ? "Review \(batchCount) of \(count)" : "Review all \(count)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "tray").foregroundStyle(tint)
                Text("Inbox reset").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            if entry.hideDetails {
                Spacer(minLength: 0)
                Text("A little clarity").font(.headline).lineLimit(2)
                Text("Open Inbox to choose what comes next.").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            } else if let count {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(count == 0 ? "Clear" : "\(count)").font(.system(size: count == 0 ? 30 : 50, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        Text(count == 0 ? "Room for a fresh thought" : "open in Inbox").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).privacySensitive()
                    if family != .systemSmall, count > 0 {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array((reading.tasks ?? []).prefix(2))) { task in
                                HStack(alignment: .top, spacing: 5) {
                                    Circle().fill(task.priority <= 2 ? brand : tint).frame(width: 5, height: 5).padding(.top, 4)
                                    Text(task.title).font(.caption2).lineLimit(2)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).privacySensitive()
                    }
                }
                if count > 0 {
                    Text("\(reading.priorities) priorities · \(reading.undated) without dates").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75).privacySensitive()
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text(entry.snapshot.updated == 0 ? "A fresh start" : "Refresh Inbox").font(.headline).lineLimit(2)
                Text("Open Taskfold to load your Inbox.").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                Text(entry.hideDetails ? "Review Inbox" : reviewLabel).font(.caption2.weight(.semibold)).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
            }.foregroundStyle(tint)
            WidgetFooter(entry: TodayEntry(date: entry.date, snapshot: entry.snapshot))
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: tint) }
        .widgetURL(entry.snapshot.inboxReviewURL(batch: entry.batch))
    }
}
struct InboxWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldInboxReset", intent: InboxConfiguration.self, provider: InboxProvider()) { InboxWidgetView(entry: $0) }
            .configurationDisplayName("Inbox reset").description("See what is still in Inbox and review a few tasks at a time. Move, edit, finish or keep each one.").supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WidgetNoteEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pinned note")
    static var defaultQuery = WidgetNoteQuery()
    var id: String
    var name: String
    var subtitle: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)") }
    init(_ note: WidgetNote, subtitle: String) { id = note.id; name = note.title; self.subtitle = subtitle }
}
struct WidgetNoteQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetNoteEntity] {
        let snapshot = WidgetSnapshot.load()
        guard snapshot.notesFresh(at: Date()) else { return [] }
        return identifiers.compactMap { snapshot.note($0).map { WidgetNoteEntity($0, subtitle: snapshot.noteSubtitle($0)) } }
    }
    func entities(matching string: String) async throws -> [WidgetNoteEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [WidgetNoteEntity] {
        let snapshot = WidgetSnapshot.load()
        return snapshot.notesFresh(at: Date()) ? snapshot.availableNotes.map { WidgetNoteEntity($0, subtitle: snapshot.noteSubtitle($0)) } : []
    }
}
struct NoteConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pinned note"
    static var description = IntentDescription("Keep instructions or an idea close. Pin a task's notes in Taskfold, then choose it here.")
    @Parameter(title: "Note") var note: WidgetNoteEntity?
    @Parameter(title: "Color", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide title and text", default: false) var hideDetails: Bool
}
struct NoteEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var noteID: String?
    var palette: WidgetPalette = .standard
    var hideDetails: Bool = false
    static var preview: NoteEntry {
        let now = Date(), account = "preview", taskID = "preview-note"
        let id = try! JSONEncoder().encode([account, "note", taskID]).base64EncodedString()
        var snapshot = WidgetSnapshot(updated: now.timeIntervalSinceReferenceDate, tasks: [], account: account)
        snapshot.notes = [WidgetNote(id: id, taskID: taskID, title: "Make room for good ideas", text: "Start with one clear thought.\nSketch it before polishing.\nLeave a little space for surprise.", truncated: false, completed: false)]
        return NoteEntry(date: now, snapshot: snapshot, noteID: id)
    }
}
struct NoteProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NoteEntry { .preview }
    func snapshot(for configuration: NoteConfiguration, in context: Context) async -> NoteEntry { context.isPreview ? .preview : entry(Date(), snapshot: .load(), configuration: configuration) }
    func timeline(for configuration: NoteConfiguration, in context: Context) async -> Timeline<NoteEntry> {
        let now = Date(), snapshot = WidgetSnapshot.load()
        return Timeline(entries: snapshot.noteTimelineDates(from: now).map { entry($0, snapshot: snapshot, configuration: configuration) }, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: NoteConfiguration) -> NoteEntry {
        NoteEntry(date: date, snapshot: snapshot, noteID: configuration.note?.id, palette: configuration.palette, hideDetails: configuration.hideDetails)
    }
}
struct NoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NoteEntry
    private var tint: Color { entry.palette.color(fallback: mint) }
    private var status: WidgetNoteStatus { entry.snapshot.noteStatus(entry.noteID, at: entry.date) }
    private var note: WidgetNote? { status == .ready ? entry.snapshot.note(entry.noteID) : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : family == .systemLarge ? 12 : 8) {
            HStack {
                Label("PINNED NOTE", systemImage: "pin.fill").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1).foregroundStyle(tint)
                Spacer(minLength: 0)
                if note?.completed == true { Image(systemName: "checkmark.circle").foregroundStyle(tint).accessibilityLabel("Task completed") }
            }
            if entry.hideDetails {
                Spacer(minLength: 0)
                Label("A note, just for you", systemImage: "lock").font(.headline).lineLimit(2)
                Text("Open Taskfold to read it.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            } else if let note {
                Text(note.title.isEmpty ? "Your pinned note" : note.title).font(.system(.headline, design: .rounded)).lineLimit(family == .systemSmall ? 2 : 1).fixedSize(horizontal: false, vertical: true).privacySensitive()
                if note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note.truncated ? "Open Taskfold to read the full note." : "Add note text in task details.").font(.callout).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    Text(note.text).font(.system(family == .systemSmall ? .caption : family == .systemLarge ? .callout : .subheadline, design: .rounded)).lineSpacing(family == .systemLarge ? 3 : 2).lineLimit(family == .systemSmall ? 3 : family == .systemLarge ? 12 : 4).frame(maxWidth: .infinity, alignment: .leading).privacySensitive()
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text(status == .choose ? "Keep a thought close" : status == .unavailable ? "Note unavailable" : "Refresh your notes").font(.headline).lineLimit(2)
                Text(status == .choose ? "Pin notes in Taskfold, then choose one in Edit Widget." : status == .unavailable ? "It was unpinned, removed, or belongs to another workspace." : "Open Taskfold to update this widget.").font(.caption).foregroundStyle(.secondary).lineLimit(family == .systemSmall ? 3 : 4)
                Spacer(minLength: 0)
            }
            HStack {
                Text(note == nil ? "OPEN TASKFOLD" : "READ FULL NOTE").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1).foregroundStyle(tint)
                Spacer(minLength: 2)
                if entry.snapshot.pendingSync > 0 { Image(systemName: "icloud").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Saved, sync pending") }
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(tint)
            }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: tint) }
        .widgetURL(note?.url(account: entry.snapshot.account) ?? entry.snapshot.notesURL)
    }
}
struct NoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldPinnedNote", intent: NoteConfiguration.self, provider: NoteProvider()) { NoteWidgetView(entry: $0) }
            .configurationDisplayName("Pinned note").description("Keep instructions, a checklist, or an idea within reach. Tap to read the full note.").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FocusSessionConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Focus session"
    static var description = IntentDescription("Follow your current workspace's timer. Tap to start, pause, resume or review it in Taskfold.")
    @Parameter(title: "Appearance", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide task title", default: false) var hideTitle: Bool
}
struct FocusSessionEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var palette: WidgetPalette = .standard
    var hideTitle = false
    static var preview: FocusSessionEntry {
        let now = Date(), start = Int64(now.addingTimeInterval(-300).timeIntervalSince1970 * 1000)
        var snapshot = WidgetSnapshot(updated: now.timeIntervalSinceReferenceDate, tasks: [], account: "preview")
        snapshot.focusSession = FocusWidgetSnapshot(account: "preview", clock: FocusWidgetClock(
            sessionID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa32", taskID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31",
            durationSeconds: 1500, elapsedMilliseconds: 0, startedAt: start, changedAt: start, runningSince: start,
            status: "running", taskState: "open", title: "Make room for the next good idea"))
        return FocusSessionEntry(date: now, snapshot: snapshot)
    }
}
struct FocusSessionProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FocusSessionEntry { .preview }
    func snapshot(for configuration: FocusSessionConfiguration, in context: Context) async -> FocusSessionEntry {
        context.isPreview ? .preview : entry(Date(), snapshot: .load(), configuration: configuration)
    }
    func timeline(for configuration: FocusSessionConfiguration, in context: Context) async -> Timeline<FocusSessionEntry> {
        let now = Date(), snapshot = WidgetSnapshot.load()
        return Timeline(entries: snapshot.focusSessionTimelineDates(from: now).map { entry($0, snapshot: snapshot, configuration: configuration) }, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: FocusSessionConfiguration) -> FocusSessionEntry {
        FocusSessionEntry(date: date, snapshot: snapshot, palette: configuration.palette, hideTitle: configuration.hideTitle)
    }
}
struct FocusSessionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FocusSessionEntry
    private var tint: Color { entry.palette.color(fallback: plum) }
    private var status: FocusWidgetStatus { entry.snapshot.focusSessionStatus(at: entry.date) }
    private var clock: FocusWidgetClock? { status == .refresh ? nil : entry.snapshot.focusSession?.clock }
    private var heading: String {
        switch status {
        case .running: return "Time to focus"
        case .paused: return "Paused"
        case .ended: return "Session ended"
        case .finished: return "Time well spent"
        case .conflict: return "Review changes"
        case .unavailable: return clock?.taskState == "completed" ? "Task completed" : "Task unavailable"
        case .idle: return "One useful step"
        case .refresh: return "Refresh Focus"
        }
    }
    private var action: String {
        switch status {
        case .running: return "Open session"
        case .paused: return "Resume in app"
        case .conflict, .unavailable: return "Review in app"
        case .ended, .finished, .idle: return "Start in app"
        case .refresh: return "Open Taskfold"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
            HStack {
                Label(family == .systemSmall ? "FOCUS" : "FOCUS SESSION", systemImage: status == .paused ? "pause.circle" : "timer")
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1).foregroundStyle(tint)
                Spacer(minLength: 0)
                if entry.hideTitle { Image(systemName: "lock").font(.caption2).foregroundStyle(tint).accessibilityLabel("Task title hidden") }
                if entry.snapshot.pendingSync > 0 { Image(systemName: "icloud").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Saved, sync pending") }
            }
            if family == .systemSmall {
                clockContent
                Text(heading).font(.caption.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
                taskContent
            } else {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) { clockContent; Text(heading).font(.caption.weight(.semibold)).foregroundStyle(tint).lineLimit(2) }
                        .frame(width: 124, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        taskContent
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text(action).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(tint).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(tint)
            }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: tint) }
        .widgetURL(entry.snapshot.focusSessionURL)
    }
    @ViewBuilder private var clockContent: some View {
        if let clock {
            Group {
                if status == .running, let interval = clock.timerInterval {
                    Text(timerInterval: interval, countsDown: true, showsHours: false)
                } else { Text(clock.clock(at: entry.date, spent: clock.status == "stopped")) }
            }
            .font(.system(size: clock.durationSeconds >= 6000 ? 32 : (family == .systemSmall ? 36 : 40), weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint(clock.status == "stopped" ? "Time focused" : "Time remaining")
            .accessibilityIdentifier("focusWidgetClock")
        } else {
            Image(systemName: status == .idle ? "sparkles" : "arrow.clockwise").font(.system(size: 28)).foregroundStyle(tint).frame(height: 42)
        }
    }
    @ViewBuilder private var taskContent: some View {
        if status == .refresh || status == .idle {
            Text(status == .idle ? "Give one task a little time." : "Open Taskfold to update your session.").font(.subheadline.weight(.medium)).lineLimit(3)
        } else if entry.hideTitle {
            Text("A little time, just for you").font(.subheadline.weight(.medium)).lineLimit(2)
        } else {
            Text(clock?.title ?? "Choose another task").font((family == .systemSmall ? Font.caption : Font.subheadline).weight(.medium)).lineLimit(family == .systemSmall ? 2 : 3).fixedSize(horizontal: false, vertical: true).privacySensitive()
        }
    }
    private var detail: String {
        switch status {
        case .running:
            let minutes = (clock?.durationSeconds ?? 0) / 60
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") for one task."
        case .paused: return "Your progress is saved."
        case .ended: return "Your task stays unchanged."
        case .finished: return "Complete the task when its work is done."
        case .conflict: return "Choose which session to keep."
        case .unavailable: return "End this session or choose another task."
        case .idle: return "Choose a task and a duration."
        case .refresh: return "See your latest session."
        }
    }
}
struct FocusSessionWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldFocusSession", intent: FocusSessionConfiguration.self, provider: FocusSessionProvider()) { FocusSessionWidgetView(entry: $0) }
            .configurationDisplayName("Focus session").description("Keep one task's timer close. See time remaining and reopen the session to pause, resume or start again.").supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PulseProjectEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static var defaultQuery = PulseProjectQuery()
    var id: String
    var name: String
    var subtitle: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)") }
    init(_ project: PulseProject, subtitle: String) { id = project.id; name = project.name; self.subtitle = subtitle }
    init(unavailable id: String) { self.id = id; name = "Unavailable project"; subtitle = "Open Taskfold to review" }
}
struct PulseProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PulseProjectEntity] {
        let snapshot = WidgetSnapshot.load()
        return identifiers.filter { PulseProject.link(for: $0) != nil }.map { id in
            snapshot.availablePulseProjects.first { $0.id == id }.map { PulseProjectEntity($0, subtitle: snapshot.pulseSubtitle($0)) } ?? PulseProjectEntity(unavailable: id)
        }
    }
    func entities(matching string: String) async throws -> [PulseProjectEntity] { try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) } }
    func suggestedEntities() async throws -> [PulseProjectEntity] {
        let snapshot = WidgetSnapshot.load()
        return snapshot.availablePulseProjects.map { PulseProjectEntity($0, subtitle: snapshot.pulseSubtitle($0)) }
    }
}
struct PulseConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Project pulse"
    static var description = IntentDescription("Choose a project to see current completion, recorded events and work needing attention.")
    @Parameter(title: "Project") var project: PulseProjectEntity?
    @Parameter(title: "Appearance", default: .standard) var palette: WidgetPalette
    @Parameter(title: "Hide project and task names", default: false) var hideNames: Bool
}
struct PulseEntry: TimelineEntry {
    var date: Date, snapshot: WidgetSnapshot
    var projectID: String? = nil
    var palette: WidgetPalette = .standard
    var hideNames = false
    static var preview: PulseEntry {
        let now = Date(), account = "preview", id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71"
        let day = PulseDay(completions: 6, reopens: 1, additions: 3, movedIn: 0, movedOut: 1, attentionCount: 2, attention: [PulseAttention(id: "draft", title: "Shape the launch story"), PulseAttention(id: "review", title: "Review the final details")])
        var days: [String: PulseDay] = [:]
        for offset in 0..<8 { days[ProjectPulseSnapshot.day(Calendar.current.date(byAdding: .day, value: offset, to: now)!)] = day }
        let project = PulseProject(account: account, recordID: id, name: "A good idea, taking shape", total: 12, completed: 8, days: days)
        var snapshot = WidgetSnapshot(updated: now.timeIntervalSinceReferenceDate, tasks: [], account: account)
        snapshot.projectPulse = ProjectPulseSnapshot(account: account, timeZone: TimeZone.current.identifier, history: "ready", recordedFrom: now.addingTimeInterval(-30 * 86400).timeIntervalSince1970, projects: [project])
        return PulseEntry(date: now, snapshot: snapshot, projectID: project.id)
    }
}
struct PulseProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PulseEntry { .preview }
    func snapshot(for configuration: PulseConfiguration, in context: Context) async -> PulseEntry { context.isPreview ? .preview : entry(Date(), snapshot: .load(), configuration: configuration) }
    func timeline(for configuration: PulseConfiguration, in context: Context) async -> Timeline<PulseEntry> {
        let now = Date(), snapshot = WidgetSnapshot.load()
        let dates = snapshot.projectPulse?.timelineDates(from: now, updated: snapshot.updated) ?? [now]
        return Timeline(entries: dates.map { entry($0, snapshot: snapshot, configuration: configuration) }, policy: .atEnd)
    }
    private func entry(_ date: Date, snapshot: WidgetSnapshot, configuration: PulseConfiguration) -> PulseEntry { PulseEntry(date: date, snapshot: snapshot, projectID: configuration.project?.id, palette: configuration.palette, hideNames: configuration.hideNames) }
}
struct PulseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PulseEntry
    private var tint: Color { entry.palette.color(fallback: mint) }
    private var status: PulseWidgetStatus { entry.snapshot.pulseStatus(entry.projectID, at: entry.date) }
    private var project: PulseProject? { status == .ready ? entry.snapshot.projectPulse?.project(entry.projectID) : nil }
    private var day: PulseDay? { project?.days[ProjectPulseSnapshot.day(entry.date)] }
    private var large: Bool { family == .systemLarge }
    private var small: Bool { family == .systemSmall }
    var body: some View {
        VStack(alignment: .leading, spacing: small ? 5 : 8) {
            HStack {
                Label("PROJECT PULSE", systemImage: "chart.bar.fill").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.8).foregroundStyle(tint)
                Spacer(minLength: 0)
                if entry.hideNames { Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(tint).accessibilityLabel("Project and task names hidden") }
                if entry.snapshot.pendingSync > 0 { Image(systemName: "icloud").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Saved, sync pending; events update after sync") }
            }
            if let project, let day {
                Text(entry.hideNames ? "Your chosen project" : project.name).font((small ? Font.caption : Font.subheadline).weight(.semibold)).lineLimit(small ? 2 : 1).privacySensitive()
                if small { progress(project); Text("\(day.attentionCount) \(day.attentionCount == 1 ? "needs" : "need") attention").font(.system(size: 10, weight: .medium)).foregroundStyle(day.attentionCount > 0 ? tint : .secondary).lineLimit(1) }
                else {
                    HStack(alignment: .top, spacing: 20) {
                        progress(project).frame(width: large ? 124 : 115, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) { recent(day); if !large { attention(day, limit: 1) } }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if large {
                        if entry.snapshot.projectPulse?.history == "ready" { Text("\(day.additions) added · \(day.movedIn) moved in · \(day.movedOut) moved out").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                        Divider()
                        attention(day, limit: 3)
                        Text(coverage).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text("Review project").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(tint)
                }
            } else {
                Spacer(minLength: 0)
                Text(status == .choose ? "Make it yours" : status == .unavailable ? "Project unavailable" : "Refresh your project").font(.headline).lineLimit(2)
                Text(status == .choose ? "Edit this widget to choose a project." : status == .unavailable ? "Its access or availability changed. Choose another project." : "Open Taskfold for the latest progress.").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 0)
                Text("Open Taskfold ↗").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            }
        }.containerBackground(for: .widget) { WidgetSurface(tint: tint) }
            .widgetURL(entry.snapshot.pulseURL(entry.projectID))
    }
    private func progress(_ project: PulseProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(project.completed) / \(project.total)").font(.system(size: small ? 32 : 30, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5).accessibilityLabel("\(project.completed) of \(project.total) current project tasks completed").accessibilityIdentifier("pulseWidgetProgress")
            Text("completed · current tasks").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.15))
                    Capsule().fill(tint).frame(width: project.total == 0 ? 0 : proxy.size.width * Double(project.completed) / Double(project.total))
                }
            }.frame(height: 5).accessibilityHidden(true)
        }
    }
    private func recent(_ day: PulseDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recorded · last 7 days").font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
            if entry.snapshot.projectPulse?.history == "ready" {
                Text("\(day.completions) completion \(day.completions == 1 ? "event" : "events")").font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8).accessibilityIdentifier("pulseWidgetEvents")
                Text("\(day.reopens) reopen \(day.reopens == 1 ? "event" : "events")").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Text(window + " · " + coverageStart).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(entry.snapshot.projectPulse?.history == "incomplete" ? "History needs refresh" : "History not loaded").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
    private func attention(_ day: PulseDay, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: large ? 8 : 3) {
            Text("\(day.attentionCount) \(day.attentionCount == 1 ? "needs" : "need") attention").font(.system(size: large ? 11 : 9, weight: .semibold)).foregroundStyle(day.attentionCount > 0 ? tint : .secondary).lineLimit(1)
            if !entry.hideNames {
                ForEach(day.attention.prefix(limit)) { task in
                    HStack(alignment: .top, spacing: 6) { Circle().fill(tint).frame(width: 4, height: 4).padding(.top, 4); Text(task.title).font(.system(size: large ? 12 : 10, weight: .medium)).lineLimit(large ? 2 : 1).privacySensitive() }
                }
            } else if day.attentionCount > 0 { Text("Task names hidden").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
    private var window: String {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: entry.date)!
        return start.formatted(.dateTime.day().month(.abbreviated)) + "–" + entry.date.formatted(.dateTime.day().month(.abbreviated))
    }
    private var coverageStart: String {
        guard let from = entry.snapshot.projectPulse?.recordedFrom else { return "" }
        return "since " + Date(timeIntervalSince1970: from).formatted(.dateTime.day().month(.abbreviated))
    }
    private var coverage: String {
        guard let pulse = entry.snapshot.projectPulse, let from = pulse.recordedFrom else { return "Open Taskfold to load recording coverage." }
        return "History since " + Date(timeIntervalSince1970: from).formatted(date: .abbreviated, time: .omitted) + ". Earlier work has no timeline. Events are separate from current completion."
    }
}
struct PulseWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskfoldProjectPulse", intent: PulseConfiguration.self, provider: PulseProvider()) { PulseWidgetView(entry: $0) }
            .configurationDisplayName("Project pulse").description("Current project progress, recorded completion/reopen events and the work needing attention. Choose a project, appearance and name privacy.").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct TaskfoldWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        FocusWidget()
        WeekWidget()
        CaptureWidget()
        DeadlineWidget()
        WindowWidget()
        ListWidget()
        CapacityWidget()
        InboxWidget()
        NoteWidget()
        FocusSessionWidget()
        PulseWidget()
        #if os(iOS)
        AddTaskControl()
        #endif
    }
}
#if os(iOS)
struct OpenQuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Task"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "taskfold://add")!))
    }
}
struct AddTaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TaskfoldAddTask") {
            ControlWidgetButton(action: OpenQuickAddIntent()) { Label("Add Task", systemImage: "plus.circle.fill") }
        }.displayName("Add Task").description("Opens Taskfold ready to type a new task.")
    }
}
#endif
#endif
