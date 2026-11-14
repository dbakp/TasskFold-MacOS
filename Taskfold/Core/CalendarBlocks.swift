import Foundation

/// Opt-in "Show time blocks in Calendar": planned tasks (a start time and a duration) are mirrored one way into one
/// calendar as events. Everything here is pure or sits behind `CalendarBlockStoring`, so the diff is testable.
/// This file is identical in the iOS and Mac repositories.
///
/// Rules:
/// - An event is ours only if it carries the marker `taskfold://task/<id>` (in its URL or its notes) and lives in the
///   chosen calendar. The title is never used to recognise an event.
/// - Every device computes the same events from the same tasks, so devices converge on the same calendar. When two
///   devices create the same block at once, each keeps the event created first (then the smallest identifier) and
///   deletes the rest, so they agree without coordinating. No device-local mapping decides which duplicate survives.
/// - Event titles are task titles. Notes hold only the marker; task notes are never copied.
enum CalendarBlocks {
    static let calendarTitle = "Taskfold"
    static let markerPrefix = "taskfold://task/"
    /// Today plus 13 more days.
    static let windowDays = 14
    static let untitled = "Untitled task"

    // MARK: Marker

    private static let idAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    static func marker(for taskID: String) -> String {
        markerPrefix + (taskID.addingPercentEncoding(withAllowedCharacters: idAllowed) ?? "")
    }
    static func markerURL(for taskID: String) -> URL? { URL(string: marker(for: taskID)) }

    /// The task id in a marker string, or nil when the string holds no marker.
    static func taskID(inMarker text: String?) -> String? {
        guard let text, let range = text.range(of: markerPrefix) else { return nil }
        let tail = text[range.upperBound...]
        let raw = tail.prefix { $0.unicodeScalars.allSatisfy { idAllowed.contains($0) || $0 == "%" } }
        guard !raw.isEmpty, let id = String(raw).removingPercentEncoding, !id.isEmpty else { return nil }
        return id
    }
    /// The URL is checked first; some calendar servers drop it, so the notes carry the same marker.
    static func taskID(url: URL?, notes: String?) -> String? {
        taskID(inMarker: url?.absoluteString) ?? taskID(inMarker: notes)
    }
    static func isBlock(url: URL?, notes: String?) -> Bool { taskID(url: url, notes: notes) != nil }

    /// Busy time must not count Taskfold's own blocks twice: the planner already knows these tasks.
    static func withoutBlocks<T>(_ items: [T], marker: (T) -> (url: URL?, notes: String?)) -> [T] {
        items.filter { item in let m = marker(item); return !isBlock(url: m.url, notes: m.notes) }
    }

    // MARK: Window

    /// Start of today up to the start of the day after the thirteenth day ahead, in `calendar`'s zone.
    static func window(now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: windowDays, to: start) ?? start.addingTimeInterval(Double(windowDays) * 86400)
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(1)))
    }

    // MARK: Desired blocks

    struct Block: Equatable, Sendable {
        var taskID: String
        var title: String
        var start: Date
        var end: Date
    }

    /// Open tasks with both a start time and a duration whose time block overlaps the window. One block per task id.
    static func blocks(from tasks: [Record], window: DateInterval, calendar: Calendar = .current) -> [Block] {
        var seen = Set<String>()
        var result: [Block] = []
        for task in tasks {
            guard Planning.eligible(task), !seen.contains(task.id),
                  let minutes = task.durationMinutes,
                  let start = TaskPlanning.start(task, calendar: calendar) else { continue }
            let end = start.addingTimeInterval(Double(minutes) * 60)
            guard start < window.end, end > window.start else { continue }
            seen.insert(task.id)
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Block(taskID: task.id, title: title.isEmpty ? untitled : title, start: start, end: end))
        }
        return result.sorted { $0.start == $1.start ? $0.taskID < $1.taskID : $0.start < $1.start }
    }

    // MARK: Diff

    /// A marked event found in the chosen calendar.
    struct Event: Equatable, Sendable {
        var identifier: String
        var taskID: String
        var title: String
        var start: Date
        var end: Date
        var created: Date?
    }

    struct Update: Equatable, Sendable { var identifier: String; var block: Block }

    struct Plan: Equatable, Sendable {
        var creates: [Block] = []
        var updates: [Update] = []
        /// Event identifiers to remove. The store re-checks the calendar and marker before removing each.
        var deletes: [String] = []
        /// Task id to the identifier of the event that stays (created ones are added after applying).
        var keep: [String: String] = [:]
        var isEmpty: Bool { creates.isEmpty && updates.isEmpty && deletes.isEmpty }
    }

    static func same(_ event: Event, _ block: Block) -> Bool {
        event.title == block.title && abs(event.start.timeIntervalSince(block.start)) < 1 && abs(event.end.timeIntervalSince(block.end)) < 1
    }

    /// Create, update and delete so the marked events mirror `desired`.
    /// - Parameters:
    ///   - existing: marked events read from the chosen calendar over the window.
    ///   - mapping: the device's remembered task id to event identifier. It only finds events that fell out of the
    ///     read window (a task moved away) so they can be removed; it never picks which duplicate survives.
    static func plan(desired: [Block], existing: [Event], mapping: [String: String] = [:]) -> Plan {
        var plan = Plan()
        let wanted = Dictionary(desired.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: existing, by: \.taskID)
        for taskID in grouped.keys.sorted() {
            let events = grouped[taskID]!.sorted { a, b in
                switch (a.created, b.created) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.identifier < b.identifier
                }
            }
            guard let block = wanted[taskID] else { plan.deletes += events.map(\.identifier); continue }
            let keeper = events[0]
            plan.keep[taskID] = keeper.identifier
            if !same(keeper, block) { plan.updates.append(Update(identifier: keeper.identifier, block: block)) }
            plan.deletes += events.dropFirst().map(\.identifier)
        }
        for block in desired where grouped[block.taskID] == nil && plan.creates.allSatisfy({ $0.taskID != block.taskID }) {
            plan.creates.append(block)
        }
        let seen = Set(existing.map(\.identifier))
        for (taskID, identifier) in mapping.sorted(by: { $0.key < $1.key }) where wanted[taskID] == nil && !seen.contains(identifier) && !plan.deletes.contains(identifier) {
            plan.deletes.append(identifier)
        }
        return plan
    }
}

// MARK: - EventKit boundary

enum CalendarBlockAccess: Equatable, Sendable { case notDetermined, denied, writeOnly, full }

enum CalendarBlockFailure: Error, Equatable, Sendable {
    case accessNeeded, calendarUnavailable, cannotCreateCalendar, failed(String)
    var message: String {
        switch self {
        case .accessNeeded: "Full calendar access is needed to add, update and remove time blocks."
        case .calendarUnavailable: "The calendar for time blocks is unavailable. Choose another calendar."
        case .cannotCreateCalendar: "Taskfold could not create a calendar here. Choose an existing calendar instead."
        case .failed(let text): "Calendar update failed: " + text
        }
    }
}

/// Everything the sync needs from the calendar database. The real implementation uses EventKit.
protocol CalendarBlockStoring: Sendable {
    func access() async -> CalendarBlockAccess
    func requestFullAccess() async throws -> Bool
    func writableCalendars() async -> [PlannerCalendar]
    /// The chosen calendar if given, else the calendar named "Taskfold", created in the default source when missing.
    func resolveCalendar(preferredID: String?) async throws -> PlannerCalendar
    /// Only events in `calendarID` that carry the marker.
    func markedEvents(calendarID: String, window: DateInterval) async throws -> [CalendarBlocks.Event]
    /// Returns task id to identifier for the events created. Skips any event outside `calendarID` or without a marker.
    func apply(_ plan: CalendarBlocks.Plan, calendarID: String) async throws -> [String: String]
    /// Removes every marked event in `calendarID`. Returns how many were removed.
    func removeAll(calendarID: String) async throws -> Int
}

struct CalendarBlockOutcome: Equatable, Sendable {
    var created = 0, updated = 0, deleted = 0
    var mapping: [String: String] = [:]
}

enum CalendarBlockSync {
    /// Read, diff, then apply. A second call with unchanged tasks finds an empty plan and writes nothing.
    static func run(tasks: [Record], store: any CalendarBlockStoring, calendarID: String, mapping: [String: String],
                    now: Date = Date(), calendar: Calendar = .current) async throws -> CalendarBlockOutcome {
        let window = CalendarBlocks.window(now: now, calendar: calendar)
        let desired = CalendarBlocks.blocks(from: tasks, window: window, calendar: calendar)
        let existing = try await store.markedEvents(calendarID: calendarID, window: window)
        let plan = CalendarBlocks.plan(desired: desired, existing: existing, mapping: mapping)
        var kept = plan.keep
        if !plan.isEmpty { for (id, identifier) in try await store.apply(plan, calendarID: calendarID) { kept[id] = identifier } }
        return CalendarBlockOutcome(created: plan.creates.count, updated: plan.updates.count, deleted: plan.deletes.count, mapping: kept)
    }
}
