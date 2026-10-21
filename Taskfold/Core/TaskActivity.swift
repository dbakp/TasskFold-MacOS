import Foundation

/// Server-confirmed current assignment history. The task author and invitation
/// sender never substitute for a missing actor. Catalogs belong to one workspace.
enum TaskAssignmentProvenance {
    static let table = "task_assignment_provenance"
    static let legacyGeneration = "00000000-0000-0000-0000-000000000000"
    enum Unknown: String, Equatable, Sendable {
        case unavailable, legacy, system, recurrence, unsupported, stale, ambiguous, deletedActor
    }
    enum Resolution: Equatable, Sendable {
        case unassigned
        case known(actor: String, event: String, recordedAt: Date)
        case unknown(Unknown)
    }
    private struct Key: Hashable, Sendable {
        let task: String
        let generation: String
        let node: String
    }
    struct Catalog: Equatable, Sendable {
        private let rows: [Key: [Record]]?
        init(_ source: [Record]?) {
            rows = source.map { source in
                Dictionary(grouping: source, by: { row in
                    Key(task: row.string("task_id").lowercased(), generation: row.string("task_generation").lowercased(), node: row.string("node_key"))
                })
            }
        }
        func resolution(root: Record) -> Resolution { resolve(source: root, root: root, path: []) }
        /// Hierarchy items have already passed the bounded identity/tree validator.
        func resolution(item: TaskHierarchyIndex.Item) -> Resolution { resolve(source: item.source, root: item.root, path: item.path) }
        private func resolve(source: Record, root: Record, path: [String]) -> Resolution {
            let recipient = source["assigned_to"]
            if recipient == .null || recipient == .string("") { return .unassigned }
            guard case .string(let recipientID) = recipient, UUID(uuidString: recipientID) != nil,
                  UUID(uuidString: root.id) != nil else { return .unknown(.unsupported) }
            let generation: String
            if root["task_generation"] == .null { generation = legacyGeneration }
            else if case .string(let value) = root["task_generation"], UUID(uuidString: value) != nil, value.lowercased() != legacyGeneration { generation = value.lowercased() }
            else { return .unknown(.unsupported) }
            guard let rows else { return .unknown(.unavailable) }
            let key = Key(task: root.id.lowercased(), generation: generation, node: path.last ?? "")
            guard let candidates = rows[key], !candidates.isEmpty else { return .unknown(.legacy) }
            guard candidates.count == 1 else { return .unknown(.ambiguous) }
            let row = candidates[0]
            guard UUID(uuidString: row.id) != nil, UUID(uuidString: row.string("event_id")) != nil,
                  case .string? = row.fields["node_key"], case .array(let encodedPath) = row["node_path"],
                  encodedPath.allSatisfy({ if case .string = $0 { return true }; return false }) else { return .unknown(.unsupported) }
            guard row["active"] == .bool(true), encodedPath.map(\.text) == path,
                  row.string("assignee_id").lowercased() == recipientID.lowercased() else { return .unknown(.stale) }
            switch row.string("origin") {
            case "recorded":
                guard let recordedAt = TaskPlanning.instant(row.string("assigned_at")) else { return .unknown(.unsupported) }
                guard row["actor_id"] != .null else { return .unknown(.deletedActor) }
                guard UUID(uuidString: row.string("actor_id")) != nil else { return .unknown(.unsupported) }
                return .known(actor: row.string("actor_id").lowercased(), event: row.string("event_id").lowercased(), recordedAt: recordedAt)
            case "legacy": return .unknown(.legacy)
            case "system": return .unknown(.system)
            case "recurrence": return .unknown(.recurrence)
            case "unsupported": return .unknown(.unsupported)
            case "unassigned": return .unknown(.stale)
            default: return .unknown(.unsupported)
            }
        }
    }
}

struct TaskActivity: Equatable, Identifiable, Sendable {
    static let table = "task_activity"
    static let epochTable = "task_activity_epoch"
    static let stateKeys: Set<String> = ["project_id", "section_id", "completed", "completed_at", "due_date", "due_time", "scheduled_at", "time_zone", "deadline_date", "recurrence_parent_id"]
    enum Kind: String, CaseIterable, Sendable {
        case created, completed, reopened, completion_time, rescheduled, moved, deleted
        var title: String {
            switch self { case .created: return "Created"; case .completed: return "Completed"; case .reopened: return "Reopened"; case .completion_time: return "Completion time updated"; case .rescheduled: return "Plan changed"; case .moved: return "Moved"; case .deleted: return "Removed" }
        }
    }
    var id: String
    var sequence: Int64
    var owner: String
    var taskID: String
    var actor: String?
    var recordedAt: Date
    var effectiveAt: Date
    var completionVersion: Int64
    var kinds: [Kind]
    var before: [String: JSON]
    var after: [String: JSON]
    init?(row: Record, parseInstant:(String)->Date? = TaskPlanning.instant, validDay:(String)->Bool = {Dates.parse($0) != nil}) {
        guard UUID(uuidString: row.id) != nil, let sequence = Self.integer(row["sequence"]), sequence > 0,
              Self.validID(row.string("user_id")), Self.validID(row.string("task_id")),
              row["actor_id"] == .null || Self.validID(row.string("actor_id")),
              let recorded = parseInstant(row.string("recorded_at")), let effective = parseInstant(row.string("effective_at")),
              let version = Self.integer(row["completion_version"]),
              case .array(let values) = row["kinds"], !values.isEmpty, values.count <= Kind.allCases.count,
              values.allSatisfy({ if case .string(let value) = $0 { return Kind(rawValue: value) != nil }; return false }),
              Set(values.map(\.text)).count == values.count,
              case .object(let before) = row["before_state"], case .object(let after) = row["after_state"],
              Self.validState(before,parseInstant:parseInstant,validDay:validDay), Self.validState(after,parseInstant:parseInstant,validDay:validDay),
              Self.changes(before: before, after: after).map(\.rawValue) == values.map(\.text) else { return nil }
        id = row.id.lowercased(); self.sequence = sequence; owner = row.string("user_id"); taskID = row.string("task_id").lowercased()
        actor = row["actor_id"] == .null ? nil : row.string("actor_id")
        recordedAt = recorded; effectiveAt = effective; completionVersion = version; kinds = values.compactMap { Kind(rawValue: $0.text) }
        self.before = before; self.after = after
    }
    static func validID(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 256 }
    static func integer(_ value: JSON) -> Int64? {
        guard case .number(let n) = value, n.isFinite, n >= 0, n <= 9_007_199_254_740_991, n.rounded(.down) == n else { return nil }
        return Int64(n)
    }
    static func validState(_ state: [String: JSON],parseInstant:(String)->Date? = TaskPlanning.instant,validDay:(String)->Bool = {Dates.parse($0) != nil}) -> Bool {
        guard state.isEmpty || Set(state.keys) == stateKeys && { if case .bool = state["completed"] { return true }; return false }() else { return false }
        for (key, value) in state {
            if value == .null { continue }
            if key == "completed" { guard case .bool = value else { return false } }
            else { guard case .string(let text) = value, text.utf8.count <= 256 else { return false } }
        }
        for key in ["completed_at", "scheduled_at"] where state[key] != nil && state[key] != .null {
            guard parseInstant(state[key]!.text) != nil else { return false }
        }
        for key in ["due_date", "deadline_date"] where state[key] != nil && state[key] != .null {
            let text = state[key]!.text
            guard text.count == 10, validDay(text) else { return false }
        }
        return true
    }
    static func state(_ task: Record?) -> [String: JSON] {
        guard let task else { return [:] }
        var result = Dictionary(uniqueKeysWithValues: stateKeys.map { ($0, task[$0]) })
        result["completed"] = .bool(task.completed)
        // SQL time/timestamp comparisons are semantic, not spelling comparisons.
        for key in ["completed_at", "scheduled_at"] {
            if let instant = TaskPlanning.instant(task.string(key)) { result[key] = .string(stamp(instant)) }
        }
        if !task.string("due_time").isEmpty { result["due_time"] = .string(task.string("due_time").count == 5 ? task.string("due_time") + ":00" : task.string("due_time")) }
        return result
    }
    static func stamp(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    static func changes(before: [String: JSON], after: [String: JSON]) -> [Kind] {
        if before.isEmpty { return after.isEmpty ? [] : [.created] }
        if after.isEmpty { return [.deleted] }
        var result: [Kind] = []
        if before["completed"] != after["completed"] { result.append(after["completed"] == .bool(true) ? .completed : .reopened) }
        else if before["completed_at"] != after["completed_at"] { result.append(.completion_time) }
        if before["project_id"] != after["project_id"] || before["section_id"] != after["section_id"] { result.append(.moved) }
        let planned = stateKeys.subtracting(["project_id", "section_id", "completed", "completed_at", "recurrence_parent_id"])
        if planned.contains(where: { before[$0] != after[$0] }) { result.append(.rescheduled) }
        return result
    }
    static func recordLocal(_ change: Mutation, before: Record?, after: Record?, snapshot: inout Snapshot, account: String, now: Date = Date()) {
        guard change.table == "tasks", validID(account), let task = after ?? before, validID(task.id) else { return }
        let b = state(before), a = state(after), kinds = changes(before: b, after: a)
        guard !kinds.isEmpty else { return }
        let existing = snapshot.tables[table] ?? []
        guard !existing.contains(where: { $0.id.lowercased() == change.id.uuidString.lowercased() }) else { return }
        let last = existing.compactMap { integer($0["sequence"]) }.max() ?? 0
        guard last < 9_007_199_254_740_991 else { return }
        let effective = kinds.contains(.completed) ? TaskPlanning.instant(task.string("completed_at")) ?? now : now
        let row = Record(["id": .string(change.id.uuidString.lowercased()), "sequence": .number(Double(last + 1)), "user_id": .string(account), "task_id": .string(task.id), "actor_id": .string(account), "recorded_at": .string(stamp(now)), "effective_at": .string(stamp(effective)), "completion_version": task.fields["completion_version"] ?? .number(0), "kinds": .array(kinds.map { .string($0.rawValue) }), "before_state": .object(b), "after_state": .object(a)])
        guard Self(row: row) != nil else { return }
        snapshot.tables[table, default: []].append(row)
        if snapshot.tables[epochTable]?.isEmpty != false { snapshot.tables[epochTable] = [Record(["id": .string("current"), "recorded_from": .string(stamp(now))])] }
    }
    func involves(project: String) -> Bool { before["project_id"]?.text.lowercased() == project.lowercased() || after["project_id"]?.text.lowercased() == project.lowercased() }
}

struct ProjectPulseReading {
    var total = 0
    var completed = 0
    var completions = 0
    var reopens = 0
    var additions = 0
    var movedIn = 0
    var movedOut = 0
    var events: [TaskActivity] = []
    var malformed = 0
    var start: Date
    var end: Date
    init(project: String, tasks: [Record], activity: [Record], now: Date = Date(), calendar input: Calendar = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        start = calendar.date(byAdding: .day, value: -7, to: end)!
        var ids = Set<String>()
        let scope = tasks.filter { $0.string("project_id").lowercased() == project.lowercased() && ids.insert($0.id.lowercased()).inserted }
        total = scope.count; completed = scope.filter(\.completed).count
        var seen = Set<String>(); malformed = 0
        events = activity.compactMap { row in
            guard let event = TaskActivity(row: row) else { malformed += 1; return nil }
            guard seen.insert(event.id).inserted, event.involves(project: project) else { return nil }
            return event
        }.sorted { $0.sequence == $1.sequence ? $0.id > $1.id : $0.sequence > $1.sequence }
        let recent = events.filter { $0.recordedAt >= start && $0.recordedAt < end && $0.recordedAt <= now }
        func before(_ event: TaskActivity) -> Bool { event.before["project_id"]?.text.lowercased() == project.lowercased() }
        func after(_ event: TaskActivity) -> Bool { event.after["project_id"]?.text.lowercased() == project.lowercased() }
        completions = recent.filter { $0.kinds.contains(.completed) && after($0) }.count
        reopens = recent.filter { $0.kinds.contains(.reopened) && before($0) }.count
        additions = recent.filter { $0.kinds.contains(.created) && after($0) }.count
        movedIn = recent.filter { !before($0) && after($0) && $0.kinds.contains(.moved) }.count
        movedOut = recent.filter { before($0) && !after($0) && $0.kinds.contains(.moved) }.count
    }
}


/// Immutable sequence cursors avoid UUID ordering/offset shifts as new activity arrives.
enum TaskActivityPage {
    static func query(after sequence: Int64) -> String { "/rest/v1/task_activity?select=*&order=sequence.asc&sequence=gt.\(sequence)&limit=500" }
    static func cursor(_ rows: [Record], after previous: Int64) throws -> Int64 {
        var cursor = previous
        for row in rows {
            guard let value = TaskActivity.integer(row["sequence"]), value > cursor else { throw AppFailure(message: "Activity history could not be read in order. Refresh your workspace.") }
            cursor = value
        }
        return cursor
    }
}

/// Goal settings are account-owned; the saved zone keeps phone and Mac on the same civil day.
struct ProductivityGoals: Equatable {
    static let recordID = "insights"
    static let field = "productivity_goals"
    var dailyTarget: Int
    var weeklyTarget: Int
    var activeWeekdays: Set<Int>
    var weekStart: Int
    var timeZone: String
    private var original: [String:JSON]
    init(document:JSON = .null, calendar:Calendar = .current) throws {
        if document == .null {
            dailyTarget=0;weeklyTarget=0;activeWeekdays=Set(2...6);weekStart=2;timeZone=calendar.timeZone.identifier;original=[:];return
        }
        guard case .object(let fields)=document, fields["version"] == .number(1),
              let data=try? JSONEncoder().encode(document),data.count<=4096 else { throw AppFailure(message:"These goals need a newer Taskfold version. Your settings are preserved.") }
        func integer(_ field:String,range:ClosedRange<Int>) throws -> Int {
            guard let raw=fields[field],let value=TaskActivity.integer(raw),let number=Int(exactly:value),range.contains(number) else { throw AppFailure(message:"Choose valid whole-number goals and weekdays.") }
            return number
        }
        dailyTarget=try integer("daily_target",range:0...10000);weeklyTarget=try integer("weekly_target",range:0...10000);weekStart=try integer("week_start",range:1...7)
        guard case .array(let days)=fields["active_weekdays"],days.count<=7,
              days.allSatisfy({if case .number(let value)=$0 { return value.isFinite && (1...7).contains(value) && value.rounded(.down)==value };return false}),
              Set(days.map(\.integer)).count==days.count,
              case .string(let zone)=fields["time_zone"],TimeZone(identifier:zone) != nil else { throw AppFailure(message:"Choose a supported time zone and distinct weekdays.") }
        activeWeekdays=Set(days.map(\.integer));timeZone=zone;original=fields
        guard dailyTarget==0 || !activeWeekdays.isEmpty else { throw AppFailure(message:"Choose at least one active day, or turn off the daily goal.") }
    }
    var document:JSON {
        .object(original.merging(["version":.number(1),"daily_target":.number(Double(dailyTarget)),"weekly_target":.number(Double(weeklyTarget)),"active_weekdays":.array(activeWeekdays.sorted().map{.number(Double($0))}),"week_start":.number(Double(weekStart)),"time_zone":.string(timeZone)]){_,new in new})
    }
    var calendar:Calendar { var value=Calendar(identifier:.gregorian);value.timeZone=TimeZone(identifier:timeZone) ?? .gmt;value.firstWeekday=(1...7).contains(weekStart) ? weekStart : 2;return value }
    func target(on day:Date) -> Int? { dailyTarget>0 && activeWeekdays.contains(calendar.component(.weekday,from:day)) ? dailyTarget : nil }
    func validated() throws -> Self { try Self(document:document) }
    static func row(_ snapshot:Snapshot,account:String) -> Record? { snapshot.tables["view_preferences"]?.first{$0.id==recordID && $0.string("user_id")==account} }
}

/// Observed completion credits, corrected by later reopen/time edits. No history is inferred from today's task rows.
struct InsightsReading {
    enum Scope:String,CaseIterable { case mine,workspace;var title:String { self == .mine ? "My completions" : "Workspace completions" } }
    enum Coverage:String { case recorded,partial,untracked }
    struct Day:Identifiable,Equatable {
        var id:String
        var date:Date
        var count:Int
        var coverage:Coverage
        var restDay:Bool
    }
    struct Credit:Equatable {
        var taskID:String
        var lifecycle:String
        var version:Int64
        var date:Date
        var projectID:String
        var actor:String?
    }
    var days:[Day]=[]
    var credits:[Credit]=[]
    var today=0
    var week=0
    var malformed=0
    var recordedFrom:Date?
    var windowStart:Date
    var windowEnd:Date
    var weekStart:Date
    var scope:Scope
    var hasHistory:Bool { recordedFrom != nil }
    var reliable:Bool { hasHistory && malformed==0 }
    init(account:String,activity:[Record],epoch:[Record],goals:ProductivityGoals,scope:Scope = .mine,projectID:String? = nil,accessibleProjects:Set<String> = [],windowDays:Int=7,now:Date=Date()) {
        self.scope=scope
        let validGoals=try? goals.validated()
        let goals=validGoals ?? (try! ProductivityGoals())
        let calendar=goals.calendar,todayStart=calendar.startOfDay(for:now)
        windowStart=calendar.date(byAdding:.day,value:-(min(366,max(1,windowDays))-1),to:todayStart)!
        windowEnd=calendar.date(byAdding:.day,value:1,to:todayStart)!
        weekStart=calendar.date(byAdding:.day,value:-((calendar.component(.weekday,from:now)-goals.weekStart+7)%7),to:todayStart)!
        guard !account.isEmpty,validGoals != nil else { if validGoals==nil { malformed=1 };return }
        // Parsers and caches belong to this fold, with no shared mutable formatter state.
        let fractional=ISO8601DateFormatter();fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let whole=ISO8601DateFormatter();whole.formatOptions=[.withInternetDateTime]
        var instants:[String:Date]=[:],invalidInstants=Set<String>(),validDays:[String:Bool]=[:]
        func instant(_ text:String)->Date? {
            if let date=instants[text] {return date};if invalidInstants.contains(text){return nil}
            if let date=fractional.date(from:text) ?? whole.date(from:text) {instants[text]=date;return date}
            invalidInstants.insert(text);return nil
        }
        func validDay(_ text:String)->Bool {
            if let value=validDays[text]{return value};let value=Dates.parse(text) != nil;validDays[text]=value;return value
        }
        let epochRows=epoch.filter{$0.id=="current"}
        if epochRows.count==1,let date=instant(epochRows[0].string("recorded_from")),date<=now { recordedFrom=date }
        else if !epochRows.isEmpty { malformed+=1 }
        let account=account.lowercased(),accessible=Set(accessibleProjects.map{$0.lowercased()})
        var unique:[String:TaskActivity]=[:],blocked=Set<String>()
        for row in activity {
            let projects=[row["before_state"].object["project_id"]?.text.lowercased() ?? "",row["after_state"].object["project_id"]?.text.lowercased() ?? ""]
            guard row.string("user_id").lowercased()==account || projects.contains(where:{!$0.isEmpty && accessible.contains($0)}) else { continue }
            guard let event=TaskActivity(row:row,parseInstant:instant,validDay:validDay) else { malformed+=1;continue }
            guard event.recordedAt<=now,!blocked.contains(event.id) else { continue }
            if let previous=unique[event.id],previous != event { unique.removeValue(forKey:event.id);blocked.insert(event.id);malformed+=1 }
            else { unique[event.id]=event }
        }
        var latest:[String:Int64]=[:],active:[String:Credit]=[:],deleted=Set<String>(),lifecycles:[String:String]=[:],archived:[Credit]=[]
        for event in unique.values.sorted(by:{$0.sequence==$1.sequence ? $0.id<$1.id : $0.sequence<$1.sequence}) {
            guard recordedFrom != nil else { break }
            if deleted.contains(event.taskID),event.kinds.contains(.created) {
                deleted.remove(event.taskID);latest.removeValue(forKey:event.taskID)
            }
            if event.kinds.contains(.created) {
                if active[event.taskID] != nil { malformed+=1 }
                lifecycles[event.taskID]=event.id
            }
            if let version=latest[event.taskID],event.completionVersion<version { continue }
            if deleted.contains(event.taskID) { if !event.kinds.contains(.deleted) { malformed+=1 };continue }
            latest[event.taskID]=event.completionVersion
            if event.kinds.contains(.reopened) { active.removeValue(forKey:event.taskID) }
            if event.kinds.contains(.completed) {
                let date=event.after["completed_at"].flatMap{instant($0.text)} ?? event.effectiveAt
                let next=Credit(taskID:event.taskID,lifecycle:lifecycles[event.taskID] ?? "existing:"+event.taskID,version:event.completionVersion,date:date,projectID:event.after["project_id"]?.text.lowercased() ?? "",actor:event.actor?.lowercased())
                if let previous=active[event.taskID],previous.version==next.version,previous != next { malformed+=1 }
                else { active[event.taskID]=next }
            } else if event.kinds.contains(.completion_time),var credit=active[event.taskID],event.after["completed"] == .bool(true) {
                if let date=event.after["completed_at"].flatMap({instant($0.text)}) { credit.date=date;credit.version=event.completionVersion;active[event.taskID]=credit }
                else { active.removeValue(forKey:event.taskID);malformed+=1 }
            }
            if event.kinds.contains(.deleted) {
                if let credit=active.removeValue(forKey:event.taskID) { archived.append(credit) }
                deleted.insert(event.taskID)
            }
        }
        credits=(archived+Array(active.values)).filter { credit in
            credit.date<=now && (scope == .workspace || credit.actor==account) && (projectID.map{$0.lowercased()==credit.projectID} ?? true)
        }.sorted{$0.date==$1.date ? $0.taskID<$1.taskID : $0.date<$1.date}
        today=credits.filter{$0.date>=todayStart && $0.date<windowEnd}.count
        week=credits.filter{$0.date>=weekStart && $0.date<windowEnd}.count
        let counts=Dictionary(grouping:credits){TaskPlanner.dayKey($0.date,calendar:calendar)}.mapValues(\.count)
        var day=windowStart
        while day<windowEnd {
            let end=calendar.date(byAdding:.day,value:1,to:day)!,key=TaskPlanner.dayKey(day,calendar:calendar)
            var coverage:Coverage=recordedFrom.map{$0>=end ? .untracked : $0>day ? .partial : .recorded} ?? .untracked
            if coverage == .untracked,counts[key,default:0]>0 { coverage = .partial }
            days.append(Day(id:key,date:day,count:counts[key] ?? 0,coverage:coverage,restDay:!goals.activeWeekdays.contains(calendar.component(.weekday,from:day))))
            day=end
        }
    }
}

/// One guarded preference command; immutable account scope survives retries and explicit review.
enum ProductivityGoalEdit {
    static func matches(_ change:Mutation) -> Bool { change.table=="view_preferences" && change.recordID==ProductivityGoals.recordID && change.fields[ProductivityGoals.field] != nil }
    static func command(_ desired:JSON,previous:Record?,account:String) throws -> Mutation {
        guard !account.isEmpty,previous.map({$0.id==ProductivityGoals.recordID && $0.string("user_id")==account}) ?? true else { throw AppFailure(message:"Reopen goals in your current workspace.") }
        _ = try ProductivityGoals(document:desired)
        let baseline=previous?[ProductivityGoals.field] ?? .null
        _ = try ProductivityGoals(document:baseline)
        return Mutation(table:"view_preferences",recordID:ProductivityGoals.recordID,method:previous==nil ? "POST" : "PATCH",fields:["id":.string(ProductivityGoals.recordID),"user_id":.string(account),ProductivityGoals.field:desired],baseline:["user_id":.string(account),ProductivityGoals.field:baseline])
    }
    static func scoped(_ change:Mutation,account:String) -> Bool {
        matches(change) && ["POST","PATCH"].contains(change.method) && change.recordID==ProductivityGoals.recordID && change.fields["id"] == .string(ProductivityGoals.recordID) && change.fields["user_id"] == .string(account) && Set(change.fields.keys)==["id","user_id",ProductivityGoals.field] && change.baseline?["user_id"] == .string(account) && change.baseline?[ProductivityGoals.field] != nil
    }
    static func valid(_ change:Mutation,account:String) -> Bool { scoped(change,account:account) && (try? ProductivityGoals(document:change.fields[ProductivityGoals.field] ?? .null)) != nil && (try? ProductivityGoals(document:change.baseline?[ProductivityGoals.field] ?? .null)) != nil }
    static func emptyRow(account:String) -> Record { Record(["id":.string(ProductivityGoals.recordID),"user_id":.string(account),ProductivityGoals.field:.null]) }
    static func keepingKnownFields(_ desired:JSON,over remote:JSON) throws -> JSON {
        _ = try ProductivityGoals(document:desired);_ = try ProductivityGoals(document:remote)
        guard desired != .null,remote != .null else { return desired }
        var result=remote.object
        for key in ["version","daily_target","weekly_target","active_weekdays","week_start","time_zone"] { result[key]=desired.object[key] }
        return try ProductivityGoals(document:.object(result)).document
    }
    static func resolving(_ conflict:SyncConflict,snapshot:Snapshot,keepLocal:Bool) -> Snapshot? {
        let change=conflict.mutation,remote=conflict.remote,account=change.fields["user_id"]?.text ?? ""
        guard scoped(change,account:account),!account.isEmpty,remote.id==ProductivityGoals.recordID,remote.string("user_id")==account,
              let index=snapshot.pending.firstIndex(of:change) else { return nil }
        var result=snapshot
        if keepLocal {
            guard valid(change,account:account),let desired=try? keepingKnownFields(change.fields[ProductivityGoals.field] ?? .null,over:remote[ProductivityGoals.field]) else { return nil }
            guard let next=try? command(desired,previous:remote,account:account) else { return nil }
            result.pending[index].method=next.method;result.pending[index].fields=next.fields;result.pending[index].baseline=next.baseline
        } else { result.pending.remove(at:index) }
        var rows=result.tables["view_preferences"] ?? [];rows.removeAll{$0.id==ProductivityGoals.recordID};rows.append(remote);result.tables["view_preferences"]=rows
        for queued in result.pending where queued.table=="view_preferences" && queued.recordID==ProductivityGoals.recordID { result.apply(queued) }
        return result
    }
    static func summary(_ document:JSON) -> String {
        if document == .null { return "Goals are off. A time zone is saved when you configure them." }
        guard let goals=try? ProductivityGoals(document:document) else { return "Goals need a newer Taskfold version. The saved choice is preserved." }
        let names=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        let days=goals.activeWeekdays.sorted().map{names[$0-1]}.joined(separator:", ")
        return "Daily: "+(goals.dailyTarget==0 ? "Off" : "\(goals.dailyTarget)")+"\nWeekly: "+(goals.weeklyTarget==0 ? "Off" : "\(goals.weeklyTarget)")+"\nActive days: "+(days.isEmpty ? "None" : days)+"\nWeek starts: "+names[goals.weekStart-1]+"\nTime zone: "+goals.timeZone
    }
}

#if DEBUG
extension Snapshot {
    static func insightsFixture(account:String,now:Date=Date()) -> Snapshot {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"UTC")!
        let today=calendar.startOfDay(for:now),epoch=calendar.date(byAdding:.day,value:-30,to:today)!
        let names=["Draft the workshop plan","Check the type scale","Read the workspace brief","Polish the chart","Pair on the review"]
        let tasks=names.enumerated().map { index,name -> Record in
            var row=Record.task(user:account);row["id"] = .string("f1741000-0000-4000-8000-00000000000\(index+1)");row["title"] = .string(name);row["created_at"] = .string(TaskActivity.stamp(epoch));return row
        }
        var result=Snapshot(tables:["tasks":tasks])
        let elapsed=max(0,now.timeIntervalSince(today))
        for (index,date) in [(2,calendar.date(byAdding:.day,value:-8,to:today)!),(0,today.addingTimeInterval(elapsed/3)),(1,today.addingTimeInterval(elapsed*2/3)),(4,today.addingTimeInterval(elapsed*3/4))] {
            let before=result.tables["tasks"]![index]
            let change=Mutation(table:"tasks",recordID:before.id,method:"PATCH",fields:["completed":.bool(true),"completed_at":.string(TaskActivity.stamp(date))])
            result.apply(change);TaskActivity.recordLocal(change,before:before,after:result.tables["tasks"]![index],snapshot:&result,account:account,now:date)
            if index==4 { result.tables[TaskActivity.table]![result.tables[TaskActivity.table]!.count-1]["actor_id"] = .string("f1742000-0000-4000-8000-000000000001") }
        }
        result.tables[TaskActivity.epochTable]=[Record(["id":.string("current"),"recorded_from":.string(TaskActivity.stamp(epoch))])]
        var goals=try! ProductivityGoals();goals.dailyTarget=5;goals.weeklyTarget=10;goals.activeWeekdays=Set(1...7);goals.timeZone="UTC"
        result.tables["view_preferences"]=[Record(["id":.string(ProductivityGoals.recordID),"user_id":.string(account),ProductivityGoals.field:goals.document])]
        return result
    }
}
#endif

/// Display context only: ledger authorship is immutable; task routes use current accessible rows.
struct ProjectActivityContext {
    let task: Record?
    let actorLabel: String
    static func isMine(_ event: TaskActivity, account: String) -> Bool {
        guard !account.isEmpty, let actor = event.actor else { return false }
        return actor.lowercased() == account.lowercased()
    }
    init(event: TaskActivity, project: String, tasks: [Record], projects: [Record], members: [Record], account: String) {
        let accessible = Set(projects.map { $0.id.lowercased() })
        guard !account.isEmpty, event.involves(project: project), accessible.contains(project.lowercased()) else {
            task = nil; actorLabel = "Name unavailable"; return
        }
        if Self.isMine(event, account: account) { actorLabel = "You" }
        else if let actor = event.actor {
            let name = members.first { $0.id.lowercased() == actor.lowercased() }?.string("display_name").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            actorLabel = name.isEmpty ? "Collaborator" : name
        } else { actorLabel = "Name unavailable" }
        if let current = tasks.first(where: { $0.id.lowercased() == event.taskID.lowercased() }),
           current.string("project_id").isEmpty ? current.string("user_id").lowercased() == account.lowercased() : accessible.contains(current.string("project_id").lowercased()) {
            task = current
        } else { task = nil }
    }
}
