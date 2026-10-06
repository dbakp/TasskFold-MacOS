import Foundation

struct PlannerFailure: LocalizedError { var message: String; var errorDescription: String? { message } }

struct WorkingHours: Equatable, Sendable {
    var start = 9 * 60, end = 17 * 60, weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var document: JSON { .object(["version": .number(1), "start": .number(Double(start)), "end": .number(Double(end)), "days": .array(weekdays.sorted().map { .number(Double($0)) })]) }
    init(start: Int = 540, end: Int = 1020, weekdays: Set<Int> = [2, 3, 4, 5, 6]) { self.start = start; self.end = end; self.weekdays = weekdays }
    init(document: JSON) throws {
        let row = Record(document.object)
        guard row["version"] == .number(1), case .number(let start) = row["start"], case .number(let end) = row["end"], start.isFinite, end.isFinite, start.rounded() == start, end.rounded() == end,
              start >= 0, end <= 1440, start < end, case .array(let days) = row["days"], days.count <= 7,
              days.allSatisfy({ if case .number(let value) = $0 { return value.isFinite && value.rounded() == value && (1...7).contains(value) }; return false }) else { throw PlannerFailure(message: "Choose valid working hours and weekdays.") }
        self.init(start: Int(start), end: Int(end), weekdays: Set(days.map(\.integer)))
    }
    func interval(on day: Date, calendar: Calendar = .current) -> DateInterval? {
        guard start >= 0, end <= 1440, start < end, weekdays.contains(calendar.component(.weekday, from: day)), let bounds = calendar.dateInterval(of: .day, for: day),
              let start = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: bounds.start, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { return nil }
        let end = self.end == 1440 ? bounds.end : calendar.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: bounds.start, matchingPolicy: .nextTime, repeatedTimePolicy: .last, direction: .forward)
        guard let end, end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}

struct PlannerEvent: Identifiable, Equatable, Sendable {
    var id: String, calendarID: String, title = "Busy", source = "Calendar"
    var start: Date, end: Date
    var allDay = false
    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}

struct PlannerBlock: Identifiable {
    var task: Record, start: Date, end: Date?, clippedStart: Date, clippedEnd: Date
    var minute: Double, length: Double, lane = 0, laneCount = 1
    var id: String { task.id }
    /// A minimum hit target is purely visual. It never becomes an estimate or busy time.
    var renderLength: Double { max(30, length) }
    var renderEnd: Double { minute + renderLength }
}

struct PlannerCapacity: Equatable {
    var workingMinutes: Int, busyMinutes: Int, estimatedMinutes: Int, unknownTasks: Int
    var afterKnownWork: Int { workingMinutes - busyMinutes - estimatedMinutes }
}

enum TaskPlanner {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        var iso = Calendar(identifier: .gregorian); iso.timeZone = calendar.timeZone
        let p = iso.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
    static func plannedDay(_ task: Record, calendar: Calendar = .current) -> String { FilterRule.plannedDay(task, timeZone: calendar.timeZone.identifier) }
    static func dayDate(_ task: Record, calendar: Calendar = .current) -> Date? { Dates.parse(plannedDay(task, calendar: calendar), calendar: calendar) }
    static func clockValue(_ task: Record, calendar: Calendar = .current) -> String {
        guard !task.string("time_zone").isEmpty, let start = TaskPlanning.start(task, calendar: calendar) else { return String(task.string("due_time").prefix(5)) }
        let parts = calendar.dateComponents([.hour, .minute], from: start)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    static func zoneLabel(_ task: Record, calendar: Calendar = .current) -> String {
        guard !task.string("time_zone").isEmpty, let start = TaskPlanning.start(task, calendar: calendar) else { return "" }
        return calendar.timeZone.abbreviation(for: start) ?? calendar.timeZone.identifier
    }
    static func slots(on day: Date, every minutes: Int = 15, calendar: Calendar = .current) -> [Date] {
        guard minutes > 0, let bounds = calendar.dateInterval(of: .day, for: day) else { return [] }
        return stride(from: bounds.start.timeIntervalSinceReferenceDate, to: bounds.end.timeIntervalSinceReferenceDate, by: Double(minutes * 60)).map { Date(timeIntervalSinceReferenceDate: $0) }
    }
    static func blocks(_ tasks: [Record], on day: Date, calendar: Calendar = .current) -> [PlannerBlock] {
        guard let bounds = calendar.dateInterval(of: .day, for: day) else { return [] }
        let raw = tasks.compactMap { task -> PlannerBlock? in
            guard !task.completed, let start = TaskPlanning.start(task, calendar: calendar) else { return nil }
            let end = task.durationMinutes.map { start.addingTimeInterval(Double($0) * 60) }
            if let end { guard start < bounds.end && end > bounds.start else { return nil } }
            else { guard start >= bounds.start && start < bounds.end else { return nil } }
            let clippedStart = max(start, bounds.start), clippedEnd = min(end ?? start, bounds.end)
            return PlannerBlock(task: task, start: start, end: end, clippedStart: clippedStart, clippedEnd: clippedEnd, minute: clippedStart.timeIntervalSince(bounds.start) / 60, length: max(0, clippedEnd.timeIntervalSince(clippedStart) / 60))
        }.sorted { $0.minute == $1.minute ? ($0.renderEnd == $1.renderEnd ? $0.id < $1.id : $0.renderEnd > $1.renderEnd) : $0.minute < $1.minute }
        var result: [PlannerBlock] = [], cluster: [PlannerBlock] = [], laneEnds: [Double] = [], clusterEnd = -Double.infinity
        func finish() { for var block in cluster { block.laneCount = laneEnds.count; result.append(block) }; cluster = []; laneEnds = []; clusterEnd = -Double.infinity }
        for var block in raw {
            if block.minute >= clusterEnd { finish() }
            let lane = laneEnds.firstIndex(where: { $0 <= block.minute }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(block.renderEnd) } else { laneEnds[lane] = block.renderEnd }
            block.lane = lane; cluster.append(block); clusterEnd = max(clusterEnd, block.renderEnd)
        }
        finish(); return result
    }
    static func allDay(_ tasks: [Record], on day: Date, calendar: Calendar = .current) -> [Record] {
        let key = dayKey(day, calendar: calendar)
        return tasks.filter { !$0.completed && $0.string("due_time").isEmpty && plannedDay($0, calendar: calendar) == key }
    }
    static func unionMinutes(_ intervals: [DateInterval], clippedTo window: DateInterval) -> Int {
        let sorted = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, window.start), end = min(interval.end, window.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var minutes: TimeInterval = 0, start: Date?, end: Date?
        for interval in sorted {
            if let oldEnd = end, interval.start <= oldEnd { end = max(oldEnd, interval.end) }
            else { if let oldStart = start, let oldEnd = end { minutes += oldEnd.timeIntervalSince(oldStart) }; start = interval.start; end = interval.end }
        }
        if let start, let end { minutes += end.timeIntervalSince(start) }
        return Int((minutes / 60).rounded())
    }
    static func capacity(_ tasks: [Record], events: [PlannerEvent], on day: Date, hours: WorkingHours, calendar: Calendar = .current) -> PlannerCapacity {
        let blocks = blocks(tasks, on: day, calendar: calendar), loose = allDay(tasks, on: day, calendar: calendar)
        let window = hours.interval(on: day, calendar: calendar)
        return PlannerCapacity(workingMinutes: Int((window?.duration ?? 0) / 60), busyMinutes: window.map { unionMinutes(events.map(\.interval), clippedTo: $0) } ?? 0,
            estimatedMinutes: Int(blocks.filter { $0.end != nil }.reduce(0) { $0 + $1.length }.rounded()) + loose.compactMap(\.durationMinutes).reduce(0, +),
            unknownTasks: blocks.filter { $0.end == nil }.count + loose.filter { $0.durationMinutes == nil }.count)
    }
    static func conflicts(task: Record, start: Date, minutes: Int?, tasks: [Record], events: [PlannerEvent], calendar: Calendar = .current) -> [String] {
        let end = minutes.map { start.addingTimeInterval(Double($0 * 60)) }
        func overlaps(_ otherStart: Date, _ otherEnd: Date?) -> Bool {
            switch (end, otherEnd) {
            case (.some(let end), .some(let otherEnd)): return start < otherEnd && end > otherStart
            case (.none, .some(let otherEnd)): return start >= otherStart && start < otherEnd
            case (.some(let end), .none): return otherStart >= start && otherStart < end
            case (.none, .none): return start == otherStart
            }
        }
        var names = tasks.filter { !$0.completed && $0.id != task.id }.compactMap { other -> String? in
            guard let otherStart = TaskPlanning.start(other, calendar: calendar), overlaps(otherStart, other.durationMinutes.map { otherStart.addingTimeInterval(Double($0 * 60)) }) else { return nil }
            return other.title
        }
        names += events.filter { overlaps($0.start, $0.end) }.map { $0.title }
        return names
    }
    static func fields(task: Record, start: Date, minutes: Int? = nil, timeZone: String? = nil, calendar: Calendar = .current) throws -> [String: JSON] {
        if let minutes, !(1...10080).contains(minutes) { throw PlannerFailure(message: "Choose an estimate between 1 minute and 7 days.") }
        var source = calendar
        let zone = timeZone ?? task.string("time_zone")
        if !zone.isEmpty { guard let value = TimeZone(identifier: zone) else { throw PlannerFailure(message: "Choose a valid time zone.") }; source.timeZone = value }
        let time = source.dateComponents([.hour, .minute], from: start)
        if zone.isEmpty, let midnight = source.dateInterval(of: .day, for: start)?.start,
           let first = source.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: midnight, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward), abs(first.timeIntervalSince(start)) >= 60 {
            throw PlannerFailure(message: "This clock time occurs twice. Choose Fixed time in Schedule to keep this exact occurrence.")
        }
        var fields: [String: JSON] = ["due_date": .string(dayKey(start, calendar: source)), "due_time": .string(String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)),
            "time_zone": zone.isEmpty ? .null : .string(zone), "scheduled_at": zone.isEmpty ? .null : .string(ISO8601DateFormatter().string(from: start))]
        if let minutes { fields["duration_minutes"] = .number(Double(minutes)) }
        return fields
    }
    /// A date drop preserves the visible local clock, while storing a fixed task in its source zone.
    static func dayFields(task: Record, day: String, calendar: Calendar = .current) -> [String: JSON] {
        guard let date = Dates.parse(day, calendar: calendar) else { return [:] }
        guard !task.string("time_zone").isEmpty, let old = TaskPlanning.start(task, calendar: calendar) else {
            var result: [String: JSON] = task.string("due_date") == day ? [:] : ["due_date": .string(day)]
            let clock = task.string("due_time").split(separator: ":").compactMap { Int($0) }
            if clock.count >= 2, (0...23).contains(clock[0]), (0...59).contains(clock[1]),
               let adjusted = calendar.nextDate(after: date.addingTimeInterval(-1), matching: DateComponents(hour: clock[0], minute: clock[1], second: 0), matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first, direction: .forward) {
                let time = calendar.dateComponents([.hour, .minute], from: adjusted)
                if time.hour != clock[0] || time.minute != clock[1] { result["due_time"] = .string(String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)) }
            }
            return result
        }
        let time = calendar.dateComponents([.hour, .minute], from: old)
        let first = calendar.nextDate(after: date.addingTimeInterval(-1), matching: DateComponents(hour: time.hour ?? 0, minute: time.minute ?? 0, second: 0), matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first, direction: .forward)
        let last = calendar.nextDate(after: date.addingTimeInterval(-1), matching: DateComponents(hour: time.hour ?? 0, minute: time.minute ?? 0, second: 0), matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .last, direction: .forward)
        guard let first else { return [:] }
        let selected = last.map { calendar.timeZone.secondsFromGMT(for: $0) == calendar.timeZone.secondsFromGMT(for: old) ? $0 : first } ?? first
        return ((try? fields(task: task, start: selected, calendar: calendar)) ?? [:]).filter { task[$0.key] != $0.value }
    }
    static func resizedMinutes(task: Record, delta: Int) -> Int? {
        guard let old = task.durationMinutes else { return nil }
        return min(10080, max(1, old + delta))
    }
}


struct DeadlineSelection: Identifiable, Sendable {
    var id = UUID()
    var account: String
    var ids: Set<String>
}

/// A deadline is a Gregorian calendar date, separate from every planned-time field.
enum TaskDeadlines {
    static func fields(day: String?) throws -> [String: JSON] {
        guard let day else { return ["deadline_date": .null] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let year = Int(day.prefix(4)), year > 0,
              let date = Dates.parse(day, calendar: calendar), TaskPlanner.dayKey(date, calendar: calendar) == day else {
            throw PlannerFailure(message: "Choose a valid deadline date.")
        }
        return ["deadline_date": .string(day)]
    }
    static func changes(tasks: [Record], day: String?) throws -> [Mutation] {
        let fields = try fields(day: day)
        var seen = Set<String>()
        return tasks.sorted { $0.id < $1.id }.compactMap { task in
            guard !task.id.isEmpty, seen.insert(task.id).inserted, task["deadline_date"] != fields["deadline_date"] else { return nil }
            return Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: fields, baseline: ["deadline_date": task["deadline_date"]])
        }
    }
}

#if DEBUG
extension Snapshot {
    static func deadlineFixture(user: String) -> Snapshot {
        var first = Record.task(user: user)
        first["id"] = .string("dddddddd-dddd-4ddd-8ddd-dddddddddd01"); first["title"] = .string("Prepare launch")
        first["due_date"] = .string("2026-10-10"); first["due_time"] = .string("09:00"); first["time_zone"] = .string("Europe/Copenhagen")
        first["scheduled_at"] = .string("2026-10-10T07:00:00Z"); first["deadline_date"] = .string("2026-10-12")
        first["duration_minutes"] = .number(25); first["reminder_specs"] = .array([.object(ReminderSpec.relative(-30).raw)])
        var second = Record.task(user: user)
        second["id"] = .string("dddddddd-dddd-4ddd-8ddd-dddddddddd02"); second["title"] = .string("Review copy")
        second["due_date"] = .string("2026-10-11"); second["due_time"] = .string("15:00"); second["deadline_date"] = .null
        var result = Snapshot(); result.tables["tasks"] = [first, second]; return result
    }
}
#endif
