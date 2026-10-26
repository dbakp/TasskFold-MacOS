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
    /// Edit known v1 fields without discarding extensions written by another client.
    /// A missing preference is editable; an unreadable existing document is not.
    static func editable(_ document: JSON) -> Bool {
        document == .null || (try? WorkingHours(document: document)) != nil
    }
    func replacing(_ document: JSON) throws -> JSON {
        guard Self.editable(document) else { throw PlannerFailure(message: "These working hours are unsupported. Update Taskfold before changing them.") }
        _ = try WorkingHours(document: self.document)
        var fields = document.object
        for (key, value) in self.document.object { fields[key] = value }
        return .object(fields)
    }
    func interval(on day: Date, calendar: Calendar = .current) -> DateInterval? {
        guard start >= 0, end <= 1440, start < end, weekdays.contains(calendar.component(.weekday, from: day)), let bounds = calendar.dateInterval(of: .day, for: day),
              let start = TaskPlanning.wallTime(day: bounds.start, hour: start / 60, minute: start % 60, calendar: calendar) else { return nil }
        let end = self.end == 1440 ? bounds.end : TaskPlanning.wallTime(day: bounds.start, hour: end / 60, minute: end % 60, calendar: calendar, fold: .last)
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
    static func capacity(_ tasks: [Record], events: [PlannerEvent], on day: Date, hours: WorkingHours?, calendar: Calendar = .current) -> PlannerCapacity {
        let actionable = tasks.filter(TaskKind.mayComplete)
        let blocks = blocks(actionable, on: day, calendar: calendar), loose = allDay(actionable, on: day, calendar: calendar)
        let window = hours?.interval(on: day, calendar: calendar)
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
    /// Notification “Move to tomorrow” means the receiving device's next calendar day,
    /// including undated work and reminders that arrive before a future task plan.
    static func tomorrowFields(task: Record, now: Date = Date(), calendar: Calendar = .current) -> [String: JSON] {
        guard now.timeIntervalSince1970.isFinite,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return [:] }
        return dayFields(task: task, day: dayKey(tomorrow, calendar: calendar), calendar: calendar)
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
    var workspace: WorkspaceBinding? = nil
    var records: [Record] = []
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
    static func widgetListFixture(user: String) -> Snapshot {
        let project = Record(["id": .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01"), "name": .string("Widget Studio"), "user_id": .string(user), "color": .string("#32856d")])
        let label = Record(["id": .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02"), "name": .string("Widget Waiting"), "user_id": .string(user)])
        let view = Record(["id": .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03"), "name": .string("Widget Today"), "user_id": .string(user), "query_ast": FilterRule.predicate("today", "").document])
        var selected = Record.task(user: user, project: project.id, date: Date())
        selected["id"] = .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04"); selected["title"] = .string("Sketch widget concept")
        selected["labels"] = .array([.string(label.id)]); selected["duration_minutes"] = .number(10)
        var outside = Record.task(user: user); outside["id"] = .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05"); outside["title"] = .string("Unrelated Inbox task")
        var result = Snapshot(); result.tables["projects"] = [project]; result.tables["labels"] = [label]; result.tables["saved_views"] = [view]; result.tables["tasks"] = [selected, outside]; return result
    }
    static func widgetOrderingFixture(user:String) -> Snapshot {
        var result=widgetListFixture(user:user)
        let project=result.tables["projects"]![0].id
        let review="eeeeeeee-eeee-4eee-8eee-eeeeeeeeee11", ship="eeeeeeee-eeee-4eee-8eee-eeeeeeeeee12"
        result.tables["sections"]=[Record(["id":.string(review),"user_id":.string(user),"project_id":.string(project),"name":.string("Design review"),"order_index":.number(0)]),Record(["id":.string(ship),"user_id":.string(user),"project_id":.string(project),"name":.string("Ready to ship"),"order_index":.number(1)])]
        let names=["Refine the concept","Review the layout","Approve contrast","Publish the design"]
        let tasks=names.enumerated().map { index,name -> Record in
            var row=Record.task(user:user,project:project)
            row["id"] = .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee2\(index)");row["title"] = .string(name)
            row["priority"] = .number(index==2 ? 1 : index==3 ? 4 : 2)
            row["section_id"] = .string(index==3 ? ship : review)
            row["labels"] = .array([.string(result.tables["labels"]![0].id)])
            return row
        }
        result.tables["tasks"]=tasks
        result.tables["view_orders"]=[Record(["id":.string("group:"+project+":"+review),"user_id":.string(user),"ids":.array([tasks[1].id,tasks[0].id,tasks[2].id].map(JSON.string))])]
        result.tables["view_preferences"]=[Record(["id":.string("project:"+project),"user_id":.string(user),"sort_by":.string("manual")])]
        return result
    }
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


/// Memory-only calendar input. Widget files receive totals, never event identities or titles.
struct CalendarCapacityWindow: Sendable {
    var account: String
    var timeZone: String
    var updated: Date
    var state: String
    var events: [PlannerEvent] = []
}

enum PlannerWidgetRoute {
    static func day(_ url: URL) -> Date? {
        guard url.scheme == "taskfold", url.host == "day", url.pathComponents.count == 2,
              url.query == nil, url.fragment == nil, url.lastPathComponent.count == 10 else { return nil }
        return Dates.parse(url.lastPathComponent)
    }
}

/// A shared visual collision map for tasks and read-only calendar events.
/// Minimum display heights never change estimates, event intervals or capacity totals.
struct PlannerTimelineItem:Identifiable {
    enum Content {case task(PlannerBlock),event(PlannerEvent)}
    var content:Content
    var minute:Double
    var length:Double
    var lane=0,laneCount=1
    var id:String {switch content {case .task(let value):return "task:"+value.id;case .event(let value):return "calendar:"+value.id}}
    var renderLength:Double {max(30,length)}
    var renderEnd:Double {minute+renderLength}
    private var order:Int {if case .task=content {return 0};return 1}
    static func layout(blocks:[PlannerBlock],events:[PlannerEvent],on day:Date,calendar:Calendar = .current)->[Self] {
        guard let bounds=calendar.dateInterval(of:.day,for:day) else {return []}
        var seen=Set<String>()
        var raw=blocks.map {Self(content:.task($0),minute:$0.minute,length:$0.length)}
        raw += events.compactMap {event in
            guard !event.allDay,event.start.timeIntervalSince1970.isFinite,event.end.timeIntervalSince1970.isFinite,event.end>event.start,event.start<bounds.end,event.end>bounds.start else {return nil}
            let start=max(event.start,bounds.start),end=min(event.end,bounds.end)
            return Self(content:.event(event),minute:start.timeIntervalSince(bounds.start)/60,length:end.timeIntervalSince(start)/60)
        }
        raw=raw.filter {seen.insert($0.id).inserted}.sorted {
            if $0.minute != $1.minute {return $0.minute<$1.minute}
            if $0.renderEnd != $1.renderEnd {return $0.renderEnd>$1.renderEnd}
            if $0.order != $1.order {return $0.order<$1.order}
            return $0.id<$1.id
        }
        var result:[Self]=[],cluster:[Self]=[],ends:[Double]=[],clusterEnd = -Double.infinity
        func finish() {for var item in cluster {item.laneCount=ends.count;result.append(item)};cluster=[];ends=[];clusterEnd = -Double.infinity}
        for var item in raw {
            if item.minute>=clusterEnd {finish()}
            let lane=ends.firstIndex(where:{$0<=item.minute}) ?? ends.count
            if lane==ends.count {ends.append(item.renderEnd)} else {ends[lane]=item.renderEnd}
            item.lane=lane;cluster.append(item);clusterEnd=max(clusterEnd,item.renderEnd)
        }
        finish();return result
    }
    /// Dense clusters can scroll; unrelated plans retain the viewport's full width.
    func width(in viewport:Double,minimum:Double=140)->Double {max(max(1,viewport)/Double(laneCount),minimum)-4}
}

/// Values authored by the bulk deadline/estimate picker, before an explicit review.
enum BulkPlanningField: String, Sendable {
    case deadline, estimate
    var title: String { self == .deadline ? "Edit deadlines" : "Edit estimates" }
    var key: String { self == .deadline ? "deadline_date" : "duration_minutes" }
    func fields(day: String?, minutes: String, clearing: Bool) throws -> [String: JSON] {
        if self == .deadline {
            guard clearing || day != nil else { throw PlannerFailure(message: "Choose a deadline date.") }
            return try TaskDeadlines.fields(day: clearing ? nil : day)
        }
        if clearing { return [key: .null] }
        let text = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text), (1...10080).contains(value) else {
            throw PlannerFailure(message: "Choose an estimate between 1 minute and 7 days (10,080 minutes).")
        }
        return [key: .number(Double(value))]
    }
}
