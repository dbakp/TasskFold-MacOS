import Foundation
import CryptoKit

/// Server-confirmed current assignment history. The task author and invitation
/// sender never substitute for a missing actor. Catalogs belong to one workspace.
enum TaskAssignmentProvenance {
    static let table = "task_assignment_provenance"
    static let legacyGeneration = "00000000-0000-0000-0000-000000000000"
    enum Unknown: String, Equatable, Sendable {
        case unavailable, legacy, system, recurrence, unsupported, stale, ambiguous, deletedActor, pending
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
    struct Catalog: Hashable, Sendable {
        private let rows: [Key: [Record]]?
        private let localAccount: String?
        private let fingerprint: Data
        private let instants: [String:Date]
        var available: Bool { rows != nil }
        init(_ source: [Record]?, localAccount: String? = nil) {
            self.localAccount = localAccount
            let grouped = source.map { source in
                Dictionary(grouping: source, by: { row in
                    Key(task: row.string("task_id").lowercased(), generation: row.string("task_generation").lowercased(), node: row.string("node_key"))
                })
            }
            rows = grouped
            let ordered = grouped?.keys.sorted { [$0.task,$0.generation,$0.node].lexicographicallyPrecedes([$1.task,$1.generation,$1.node]) }.map { key in
                JSON.array([.string(key.task),.string(key.generation),.string(key.node),.array(grouped![key]!.map { .object($0.fields) })])
            }
            if let ordered {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                fingerprint = Data(SHA256.hash(data: (try? encoder.encode(ordered)) ?? Data()))
            } else { fingerprint = Data() }
            var parsed: [String:Date] = [:]
            let stamps = Set((source ?? []).filter { ["recorded","local"].contains($0.string("origin")) }.map { $0.string("assigned_at") }.filter { !$0.isEmpty })
            if !stamps.isEmpty {
                // Reuse thread-local parsers for this immutable catalog. Matching
                // thousands of rows must not allocate a date parser per task.
                let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
                let whole = ISO8601DateFormatter()
                for stamp in stamps { parsed[stamp] = fractional.date(from:stamp) ?? whole.date(from:stamp) }
            }
            instants = parsed
        }
        func hash(into hasher: inout Hasher) { hasher.combine(fingerprint); hasher.combine(localAccount) }
        func resolution(root: Record) -> Resolution { resolve(source: root, root: root, path: []) }
        func resolution(projected task: Record) -> Resolution {
            guard task.id.hasPrefix("subtask:") else { return resolution(root: task) }
            guard let path = SubtaskTree.referencePath(task.id), let rootID = path.first else { return .unknown(.unsupported) }
            return resolve(source: task, root: Record(["id":.string(rootID),"task_generation":task["task_generation"]]), path: Array(path.dropFirst()))
        }
        /// Hierarchy items have already passed the bounded identity/tree validator.
        func resolution(item: TaskHierarchyIndex.Item) -> Resolution { resolve(source: item.source, root: item.root, path: item.path) }
        private func resolve(source: Record, root: Record, path: [String]) -> Resolution {
            let recipient = source["assigned_to"]
            if recipient == .null || recipient == .string("") { return .unassigned }
            guard case .string(let recipientID) = recipient, UUID(uuidString: recipientID) != nil || recipientID == localAccount,
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
            case "local":
                guard let localAccount, row.string("scope_account") == localAccount, row.string("actor_id") == localAccount,
                      let recordedAt = instants[row.string("assigned_at")] else { return .unknown(.unsupported) }
                return .known(actor:localAccount,event:row.string("event_id").lowercased(),recordedAt:recordedAt)
            case "recorded":
                guard let recordedAt = instants[row.string("assigned_at")] else { return .unknown(.unsupported) }
                guard row["actor_id"] != .null else { return .unknown(.deletedActor) }
                guard UUID(uuidString: row.string("actor_id")) != nil else { return .unknown(.unsupported) }
                return .known(actor: row.string("actor_id").lowercased(), event: row.string("event_id").lowercased(), recordedAt: recordedAt)
            case "legacy": return .unknown(.legacy)
            case "system": return .unknown(.system)
            case "recurrence": return .unknown(.recurrence)
            case "unsupported": return .unknown(.unsupported)
            case "unassigned": return .unknown(.stale)
            case "pending": return .unknown(.pending)
            default: return .unknown(.unsupported)
            }
        }
    }

    private static func generation(_ root: Record) -> String { root.string("task_generation").isEmpty ? legacyGeneration : root.string("task_generation").lowercased() }
    private static func recipient(_ value: JSON) -> JSON {
        if value == .string("") { return .null }
        if case .string(let id) = value, let uuid = UUID(uuidString:id) { return .string(uuid.uuidString.lowercased()) }
        return value
    }
    /// An index validates stable identities without normalizing or generating any.
    private static func nodes(_ root: Record) -> [String: TaskHierarchyIndex.Item]? {
        let project = root.string("project_id")
        let projects = project.isEmpty ? [] : [Record(["id":.string(project),"name":.string("Containment")])]
        guard let index = try? TaskHierarchyIndex(roots:[root],projects:projects,workspace:WorkspaceBinding(account:"assignment-index",generation:UUID())) else { return nil }
        return Dictionary(uniqueKeysWithValues:index.items.map { ($0.path.last ?? "",$0) })
    }
    /// Cloud optimism never certifies an actor. Invalidate every real transition,
    /// including A→B→A, and retain a proven event across a pure child move.
    static func invalidate(before: Record?, after: Record?, snapshot: inout Snapshot) {
        guard let after else { return }
        if let before, recipient(before["assigned_to"]) == recipient(after["assigned_to"]), before["subtasks"] == after["subtasks"] { return }
        guard var rows = snapshot.tables[table] else { return }
        var keys = Set(rows.filter { $0.string("task_id").lowercased() == after.id.lowercased() && $0.string("task_generation").lowercased() == generation(after) }.map { $0.string("node_key") })
        func appendMissing(_ source: Record, path: [String], changed: Bool) {
            let value = recipient(source["assigned_to"])
            guard changed, value != .null, keys.insert(path.last ?? "").inserted else { return }
            rows.append(Record(["id":.string(UUID().uuidString.lowercased()),"task_id":.string(after.id.lowercased()),"task_generation":.string(generation(after)),"node_key":.string(path.last ?? ""),"node_path":.array(path.map(JSON.string)),"assignee_id":value,"actor_id":.null,"event_id":.string(UUID().uuidString.lowercased()),"assigned_at":.null,"origin":.string("pending"),"active":.bool(true)]))
        }
        guard let before else {
            for i in rows.indices where rows[i].string("task_id").lowercased() == after.id.lowercased() && rows[i].string("task_generation").lowercased() == generation(after) && rows[i].string("origin") != "local" {
                rows[i]["origin"] = .string("pending"); rows[i]["actor_id"] = .null
            }
            appendMissing(after,path:[],changed:true)
            for item in nodes(after)?.values ?? Dictionary<String,TaskHierarchyIndex.Item>().values where item.isSubtask { appendMissing(item.source,path:item.path,changed:true) }
            snapshot.tables[table] = rows; return
        }
        let oldNodes = before["subtasks"] == after["subtasks"] ? nil : nodes(before)
        let newNodes = before["subtasks"] == after["subtasks"] ? nil : nodes(after)
        for i in rows.indices where rows[i].string("task_id").lowercased() == after.id.lowercased() && rows[i].string("task_generation").lowercased() == generation(after) && rows[i].string("origin") != "local" {
            let key = rows[i].string("node_key")
            if key.isEmpty {
                if recipient(before["assigned_to"]) != recipient(after["assigned_to"]) { rows[i]["origin"] = .string("pending"); rows[i]["actor_id"] = .null }
            } else if before["subtasks"] != after["subtasks"] {
                if oldNodes == nil || newNodes == nil || (newNodes?[key] != nil && recipient(oldNodes?[key]?.source["assigned_to"] ?? .null) != recipient(newNodes?[key]?.source["assigned_to"] ?? .null)) {
                    rows[i]["origin"] = .string("pending"); rows[i]["actor_id"] = .null
                } else if let old = oldNodes?[key], let new = newNodes?[key], rows[i]["node_path"] == .array(old.path.map(JSON.string)) {
                    rows[i]["node_path"] = .array(new.path.map(JSON.string))
                }
            }
        }
        appendMissing(after,path:[],changed:recipient(before["assigned_to"]) != recipient(after["assigned_to"]))
        if before["subtasks"] != after["subtasks"] {
            for item in newNodes?.values ?? Dictionary<String,TaskHierarchyIndex.Item>().values where item.isSubtask {
                appendMissing(item.source,path:item.path,changed:oldNodes == nil || recipient(oldNodes?[item.path.last ?? ""]?.source["assigned_to"] ?? .null) != recipient(item.source["assigned_to"]))
            }
        }
        snapshot.tables[table] = rows
    }
    /// Called only by Store's explicit local-workspace commit path. These records
    /// are never accepted as server evidence or exported to another workspace.
    static func recordLocal(_ change: Mutation, before: Record?, after: Record?, snapshot: inout Snapshot, account: String, now: Date = Date()) {
        guard change.table == "tasks", !account.isEmpty, let root = after ?? before, UUID(uuidString:root.id) != nil else { return }
        var rows = snapshot.tables[table] ?? []
        let rootID = root.id.lowercased(), incarnation = generation(root)
        guard let after else { rows.removeAll { $0.string("task_id").lowercased() == rootID }; snapshot.tables[table] = rows; return }
        if let before, recipient(before["assigned_to"]) == recipient(after["assigned_to"]), before["subtasks"] == after["subtasks"] { return }
        let prior = before.flatMap(nodes), current = nodes(after)
        var values = current ?? [:]
        var positions: [String:Int] = [:]
        for i in rows.indices where rows[i].string("task_id").lowercased() == rootID && rows[i].string("task_generation").lowercased() == incarnation {
            positions[rows[i].string("node_key")] = positions[rows[i].string("node_key")] ?? i
        }
        // An unsupported checklist does not prevent a real root assignment.
        values[""] = TaskHierarchyIndex.Item(source:after,root:after,path:[],parentTitles:[],id:after.id)
        if current == nil {
            for i in rows.indices where rows[i].string("task_id").lowercased() == rootID && rows[i].string("task_generation").lowercased() == incarnation && !rows[i].string("node_key").isEmpty {
                rows[i]["active"] = .bool(false); rows[i]["origin"] = .string("unsupported"); rows[i]["actor_id"] = .null
            }
        }
        for i in rows.indices where rows[i].string("task_id").lowercased() == rootID && rows[i].string("task_generation").lowercased() == incarnation && !rows[i].string("node_key").isEmpty && values[rows[i].string("node_key")] == nil { rows[i]["active"] = .bool(false) }
        let recordedAt = JSON.string(TaskActivity.stamp(now))
        for (key,item) in values {
            let recipient = Self.recipient(item.source["assigned_to"])
            let previous = key.isEmpty ? before : prior?[key]?.source
            let oldRecipient = Self.recipient(previous?["assigned_to"] ?? .null)
            let index = positions[key]
            if index == nil, recipient == .null { continue }
            if let index, Self.recipient(rows[index]["assignee_id"]) == recipient, !["unsupported","pending"].contains(rows[index].string("origin")), (key.isEmpty ? before != nil : prior != nil), previous == nil || recipient == oldRecipient {
                rows[index]["node_path"] = .array(item.path.map(JSON.string)); rows[index]["active"] = .bool(recipient != .null); continue
            }
            let legacy = before != nil && ((!key.isEmpty && prior == nil) || (previous != nil && recipient == oldRecipient))
            let recurrence = before == nil && (!after.string("recurrence_parent_id").isEmpty || after["source_metadata"].object["taskfold_recurrence_v1"] != nil)
            let origin = recipient == .null ? "unassigned" : legacy ? "legacy" : recurrence ? "recurrence" : "local"
            let row = Record(["id":.string(index.map { rows[$0].id } ?? UUID().uuidString.lowercased()),"task_id":.string(rootID),"task_generation":.string(incarnation),"node_key":.string(key),"node_path":.array(item.path.map(JSON.string)),"assignee_id":recipient,"actor_id":origin == "local" ? .string(account) : .null,"scope_account":.string(account),"event_id":.string(UUID().uuidString.lowercased()),"assigned_at":origin == "local" ? recordedAt : .null,"origin":.string(origin),"active":.bool(recipient != .null)])
            if let index { rows[index] = row } else { rows.append(row); positions[key] = rows.count-1 }
        }
        snapshot.tables[table] = rows
    }
}

/// Optional annotation on newly observed parent events. Missing metadata is
/// legacy history, never an invitation to infer type from a current task row.
struct TaskRootActivityContext: Equatable, Sendable {
    enum Kind: String, Sendable { case task, heading, unknown }
    let beforeType: Kind?
    let afterType: Kind?
    let beforeGeneration: String?
    let afterGeneration: String?
    var readable: Bool { beforeType != .unknown && afterType != .unknown }
    var generationChanged: Bool { beforeGeneration != nil && afterGeneration != nil && beforeGeneration != afterGeneration }
    init?(document: JSON, beforeExists: Bool, afterExists: Bool) {
        guard case .object(let fields) = document, Set(fields.keys) == ["version", "before_type", "after_type", "before_generation", "after_generation"], fields["version"] == .number(1) else { return nil }
        func type(_ key: String, exists: Bool) -> Kind? {
            guard exists, case .string(let value)? = fields[key] else { return nil }
            return Kind(rawValue: value)
        }
        func generation(_ key: String, exists: Bool) -> String? {
            guard exists, case .string(let value)? = fields[key] else { return nil }
            return UUID(uuidString: value)?.uuidString.lowercased()
        }
        beforeType = type("before_type", exists: beforeExists); afterType = type("after_type", exists: afterExists)
        beforeGeneration = generation("before_generation", exists: beforeExists); afterGeneration = generation("after_generation", exists: afterExists)
        guard beforeExists ? beforeType != nil && beforeGeneration != nil : fields["before_type"] == .null && fields["before_generation"] == .null,
              afterExists ? afterType != nil && afterGeneration != nil : fields["after_type"] == .null && fields["after_generation"] == .null else { return nil }
    }
    static func document(before: Record?, after: Record?) -> JSON {
        func type(_ row: Record?) -> JSON {
            guard let row else { return .null }
            if row["task_generation"] != .null, UUID(uuidString: row.string("task_generation")) == nil { return .string("unknown") }
            switch TaskKind(row) { case .task: return .string("task"); case .heading: return .string("heading"); case .unsupported: return .string("unknown") }
        }
        func generation(_ row: Record?) -> JSON {
            guard let row else { return .null }
            if row["task_generation"] == .null { return .string(TaskNodeActivity.legacyGeneration) }
            return .string(UUID(uuidString: row.string("task_generation"))?.uuidString.lowercased() ?? TaskNodeActivity.legacyGeneration)
        }
        return .object(["version": .number(1), "before_type": type(before), "after_type": type(after), "before_generation": generation(before), "after_generation": generation(after)])
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
    var rootContext: TaskRootActivityContext?
    var workBefore: Bool { !before.isEmpty && (rootContext.map { $0.readable && $0.beforeType == .task } ?? true) }
    var workAfter: Bool { !after.isEmpty && (rootContext.map { $0.readable && $0.afterType == .task } ?? true) }
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
        if row["root_context"] == .null { rootContext = nil }
        else {
            guard let context = TaskRootActivityContext(document: row["root_context"], beforeExists: !before.isEmpty, afterExists: !after.isEmpty) else { return nil }
            rootContext = context
        }
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
        let row = Record(["id": .string(change.id.uuidString.lowercased()), "sequence": .number(Double(last + 1)), "user_id": .string(account), "task_id": .string(task.id), "actor_id": .string(account), "recorded_at": .string(stamp(now)), "effective_at": .string(stamp(effective)), "completion_version": task.fields["completion_version"] ?? .number(0), "kinds": .array(kinds.map { .string($0.rawValue) }), "before_state": .object(b), "after_state": .object(a), "root_context": TaskRootActivityContext.document(before: before, after: after)])
        guard Self(row: row) != nil else { return }
        snapshot.tables[table, default: []].append(row)
        if snapshot.tables[epochTable]?.isEmpty != false { snapshot.tables[epochTable] = [Record(["id": .string("current"), "recorded_from": .string(stamp(now))])] }
    }
    func involves(project: String) -> Bool { before["project_id"]?.text.lowercased() == project.lowercased() || after["project_id"]?.text.lowercased() == project.lowercased() }
}


/// Read-only child transitions. The separate feed preserves the original parent
/// ledger for older clients; no title, note, attachment or invented identity is retained.
struct TaskNodeActivity: Equatable, Identifiable, Sendable {
    static let table = "task_node_activity"
    static let epochTable = "task_node_activity_epoch"
    static let legacyGeneration = "00000000-0000-0000-0000-000000000000"
    enum Kind: String, CaseIterable, Sendable {
        case created, completed, reopened, completion_time, moved, rescheduled, deleted, scope_changed, type_changed, coverage_gap
    }
    let id: String
    let sequence: Int64
    let owner: String
    let rootID: String
    let generation: String?
    let nodeKey: String
    let beforePath: [String]
    let afterPath: [String]
    let actor: String?
    let recordedAt: Date
    let effectiveAt: Date
    let completionVersion: Int64
    let before: [String: JSON]
    let after: [String: JSON]
    let typeBefore: String?
    let typeAfter: String?
    let workBefore: Bool
    let workAfter: Bool
    let kinds: [Kind]
    var isGap: Bool { kinds == [.coverage_gap] }
    var path: [String] { afterPath.isEmpty ? beforePath : afterPath }
    var subject: String { [rootID, generation ?? "unknown", nodeKey].joined(separator: ":") }
    init?(row: Record) { self.init(row: row, parseInstant: TaskPlanning.instant, validDay: { Dates.parse($0) != nil }) }
    init?(row: Record, parseInstant: (String) -> Date?, validDay: (String) -> Bool) {
        guard row["format_version"] == .number(1), UUID(uuidString: row.id) != nil,
              let sequence = TaskActivity.integer(row["sequence"]), sequence > 0,
              TaskActivity.validID(row.string("user_id")), TaskActivity.validID(row.string("task_id")),
              row["actor_id"] == .null || TaskActivity.validID(row.string("actor_id")),
              let recorded = parseInstant(row.string("recorded_at")), let effective = parseInstant(row.string("effective_at")),
              let revision = TaskActivity.integer(row["completion_version"]),
              case .bool(let workBefore) = row["work_before"], case .bool(let workAfter) = row["work_after"],
              case .object(let before) = row["before_state"], case .object(let after) = row["after_state"],
              TaskActivity.validState(before, parseInstant: parseInstant, validDay: validDay), TaskActivity.validState(after, parseInstant: parseInstant, validDay: validDay),
              let beforePath = Self.path(row["before_path"]), let afterPath = Self.path(row["after_path"]),
              case .array(let rawKinds) = row["kinds"], !rawKinds.isEmpty,
              rawKinds.allSatisfy({ if case .string(let key) = $0 { return Kind(rawValue: key) != nil }; return false }),
              Set(rawKinds.map(\.text)).count == rawKinds.count else { return nil }
        let kinds = rawKinds.compactMap { Kind(rawValue: $0.text) }
        func type(_ key: String) -> String? { row[key] == .null ? nil : row.string(key) }
        let typeBefore = type("type_before"), typeAfter = type("type_after")
        guard [typeBefore, typeAfter].allSatisfy({ $0 == nil || ["task", "heading"].contains($0!) }) else { return nil }
        let generation = row["task_generation"] == .null ? nil : UUID(uuidString: row.string("task_generation"))?.uuidString.lowercased()
        guard row["task_generation"] == .null || generation != nil else { return nil }
        if kinds == [.coverage_gap] {
            guard row["node_key"] == .string(""), beforePath.isEmpty, afterPath.isEmpty,
                  !workBefore, !workAfter, typeBefore == nil, typeAfter == nil, revision == 0 else { return nil }
        } else {
            guard let generation, !generation.isEmpty,
                  ChecklistRecovery.validIdentity(row.string("node_key")),
                  before.isEmpty == beforePath.isEmpty, after.isEmpty == afterPath.isEmpty,
                  !(before.isEmpty && after.isEmpty),
                  beforePath.isEmpty || beforePath.last == row.string("node_key"),
                  afterPath.isEmpty || afterPath.last == row.string("node_key"),
                  before.isEmpty == (typeBefore == nil), after.isEmpty == (typeAfter == nil),
                  !workBefore || typeBefore == "task", !workAfter || typeAfter == "task",
                  typeBefore != "heading" || before["completed"] == .bool(false) && before["completed_at"] == .null,
                  typeAfter != "heading" || after["completed"] == .bool(false) && after["completed_at"] == .null,
                  kinds == Self.changes(before: before, after: after, beforePath: beforePath, afterPath: afterPath, workBefore: workBefore, workAfter: workAfter, typeBefore: typeBefore, typeAfter: typeAfter) else { return nil }
        }
        id = row.id.lowercased(); self.sequence = sequence; owner = row.string("user_id")
        rootID = row.string("task_id").lowercased(); self.generation = generation; nodeKey = row.string("node_key")
        self.beforePath = beforePath; self.afterPath = afterPath; actor = row["actor_id"] == .null ? nil : row.string("actor_id")
        recordedAt = recorded; effectiveAt = effective; completionVersion = revision
        self.before = before; self.after = after; self.typeBefore = typeBefore; self.typeAfter = typeAfter; self.workBefore = workBefore; self.workAfter = workAfter; self.kinds = kinds
    }
    static func path(_ value: JSON) -> [String]? {
        guard case .array(let list) = value, list.count <= SubtaskTree.readableDepth,
              list.allSatisfy({ if case .string(let key) = $0 { return ChecklistRecovery.validIdentity(key) }; return false }),
              let data = try? JSONEncoder().encode(value), data.count <= 65_536 else { return nil }
        return list.map(\.text)
    }
    static func changes(before: [String: JSON], after: [String: JSON], beforePath: [String], afterPath: [String], workBefore: Bool, workAfter: Bool, typeBefore: String?, typeAfter: String?) -> [Kind] {
        var result = TaskActivity.changes(before: before, after: after).compactMap { Kind(rawValue: $0.rawValue) }
        guard !before.isEmpty, !after.isEmpty else { return result }
        if beforePath != afterPath, !result.contains(.moved) {
            result.insert(.moved, at: result.firstIndex(of: .rescheduled) ?? result.count)
        }
        if typeBefore != typeAfter { result.append(.type_changed) }
        else if workBefore != workAfter { result.append(.scope_changed) }
        return result
    }
    func involves(project: String) -> Bool {
        before["project_id"]?.text.lowercased() == project.lowercased() || after["project_id"]?.text.lowercased() == project.lowercased()
    }
    /// A historical path is never editing authority. Follow a stable key only
    /// within the same current root incarnation and a freshly validated tree.
    func currentTask(tasks: [Record], projects: [Record], account: String) -> Record? {
        guard !isGap, !account.isEmpty, let generation, generation != Self.legacyGeneration,
              let root = tasks.first(where: { $0.id.lowercased() == rootID }),
              tasks.filter({ $0.id.lowercased() == rootID }).count == 1,
              Self.generation(root) == generation, root.string("user_id").lowercased() == owner.lowercased(),
              !root.string("project_id").isEmpty || root.string("user_id").lowercased() == account.lowercased(),
              let index = try? TaskHierarchyIndex(roots: [root], projects: projects, workspace: WorkspaceBinding(account: account, generation: UUID())),
              let item = index.items.first(where: { $0.isSubtask && $0.path.last == nodeKey }) else { return nil }
        return item.record
    }
    private struct Node {
        let generation: String
        let path: [String]
        let state: [String: JSON]
        let type: String
        let work: Bool
        let revision: Int64
        var key: String { generation + ":" + path.last! }
    }
    private static func generation(_ root: Record) -> String? {
        if root["task_generation"] == .null { return legacyGeneration }
        return UUID(uuidString: root.string("task_generation"))?.uuidString.lowercased()
    }
    private static func nodes(_ root: Record?) -> [String: Node]? {
        guard let root else { return [:] }
        guard let generation = generation(root), TaskKind(root) != .unsupported,
              let bytes = try? JSONEncoder().encode(root["subtasks"]), bytes.count <= ChecklistRecovery.maximumBytes else { return nil }
        let p = root.string("project_id"), projects = p.isEmpty ? [] : [Record(["id": .string(p), "name": .string("Containment")])]
        guard let index = try? TaskHierarchyIndex(roots: [root], projects: projects, workspace: WorkspaceBinding(account: "node-history", generation: UUID())) else { return nil }
        let work = ProductiveTaskReading(tasks: [root]); guard !work.incomplete else { return nil }
        var result: [String: Node] = [:]
        for item in index.items where item.isSubtask {
            guard TaskKind(item.source) != .unsupported,
                  !item.source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.source["completed"] == .null || { if case .bool = item.source["completed"] { return true }; return false }() else { return nil }
            if TaskKind(item.source) == .heading && (item.source.completed || item.source["completed_at"] != .null) { return nil }
            let state = TaskActivity.state(item.record)
            guard TaskActivity.validState(state), path(.array(item.path.map(JSON.string))) != nil,
                  let revision = item.source["completion_version"] == .null ? 0 : TaskActivity.integer(item.source["completion_version"]) else { return nil }
            let node = Node(generation: generation, path: item.path, state: state, type: TaskKind(item.source) == .heading ? "heading" : "task", work: TaskKind.mayComplete(item.source) && work.contains(item.id), revision: revision)
            result[node.key] = node
        }
        return result
    }
    /// Stable retry identities derive from the actual mutation and node occurrence.
    /// This is a ledger record, never a client-supplied table mutation.
    static func localRows(_ change: Mutation, before: Record?, after: Record?, account: String, recordedAt: Date, afterSequence: Int64 = 0) -> [Record] {
        guard change.table == "tasks", ["POST", "PATCH", "DELETE"].contains(change.method),
              TaskActivity.validID(account), let root = after ?? before, TaskActivity.validID(root.id),
              change.recordID == root.id, before == nil || before?.id == root.id,
              [before, after].compactMap({ $0 }).allSatisfy({ $0.string("user_id").isEmpty || $0.string("user_id") == account }),
              afterSequence >= 0, afterSequence < 9_007_199_254_740_991,
              (change.method == "POST" && before == nil && after != nil) || (change.method == "PATCH" && before != nil && after != nil) || (change.method == "DELETE" && before != nil && after == nil) else { return [] }
        if let before, let after, before["subtasks"] == after["subtasks"], before["is_heading"] == after["is_heading"],
           before["project_id"] == after["project_id"], before["section_id"] == after["section_id"], before["task_generation"] == after["task_generation"] { return [] }
        let prior = nodes(before), current = nodes(after)
        var result: [Record] = [], sequence = afterSequence, overflow = false
        func append(_ key: String, generation: String?, nodeKey: String, b: [String: JSON], a: [String: JSON], oldPath: [String], newPath: [String], oldWork: Bool, newWork: Bool, oldType: String?, newType: String?, revision: Int64, kinds: [Kind]) {
            guard !kinds.isEmpty else { return }
            guard sequence < 9_007_199_254_740_991 else { overflow = true; return }; sequence += 1
            let identity = try! JSONEncoder().encode([change.id.uuidString.lowercased(), root.id, key])
            let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let raw = String(hash.prefix(32)), points = [8,12,16,20]
            let id = raw.enumerated().map { (points.contains($0.offset) ? "-" : "") + String($0.element) }.joined()
            let effective = kinds.contains(.completed) ? a["completed_at"].flatMap { TaskPlanning.instant($0.text) } ?? recordedAt : recordedAt
            let row = Record(["id": .string(id), "format_version": .number(1), "sequence": .number(Double(sequence)), "user_id": .string(account), "task_id": .string(root.id), "task_generation": generation.map(JSON.string) ?? .null,
                "node_key": .string(nodeKey), "before_path": .array(oldPath.map(JSON.string)), "after_path": .array(newPath.map(JSON.string)), "actor_id": .string(account),
                "recorded_at": .string(TaskActivity.stamp(recordedAt)), "effective_at": .string(TaskActivity.stamp(effective)), "completion_version": .number(Double(revision)),
                "before_state": .object(b), "after_state": .object(a), "type_before": oldType.map(JSON.string) ?? .null, "type_after": newType.map(JSON.string) ?? .null, "work_before": .bool(oldWork), "work_after": .bool(newWork), "kinds": .array(kinds.map { .string($0.rawValue) })])
            if Self(row: row) != nil { result.append(row) }
        }
        guard let prior, let current else {
            append("coverage-gap", generation: generation(root), nodeKey: "", b: TaskActivity.state(before), a: TaskActivity.state(after), oldPath: [], newPath: [], oldWork: false, newWork: false, oldType: nil, newType: nil, revision: 0, kinds: [.coverage_gap]); return result
        }
        for key in Set(prior.keys).union(current.keys).sorted() {
            let old = prior[key], new = current[key], node = new ?? old!
            let b = old?.state ?? [:], a = new?.state ?? [:], oldPath = old?.path ?? [], newPath = new?.path ?? []
            append(key, generation: node.generation, nodeKey: node.path.last!, b: b, a: a, oldPath: oldPath, newPath: newPath, oldWork: old?.work ?? false, newWork: new?.work ?? false, oldType: old?.type, newType: new?.type, revision: node.revision,
                   kinds: changes(before: b, after: a, beforePath: oldPath, afterPath: newPath, workBefore: old?.work ?? false, workAfter: new?.work ?? false, typeBefore: old?.type, typeAfter: new?.type))
        }
        return overflow ? [] : result
    }
    static func recordLocal(_ change: Mutation, before: Record?, after: Record?, snapshot: inout Snapshot, account: String, now: Date = Date()) {
        let existing = snapshot.tables[table] ?? []
        let parser = Parser()
        guard existing.allSatisfy({ parser.event($0) != nil }), Set(existing.compactMap { TaskActivity.integer($0["sequence"]) }).count == existing.count else { return }
        let ids = Set(existing.map { $0.id.lowercased() })
        let start = existing.compactMap { TaskActivity.integer($0["sequence"]) }.max() ?? 0
        let rows = localRows(change, before: before, after: after, account: account, recordedAt: now, afterSequence: start).filter { !ids.contains($0.id.lowercased()) }
        guard !rows.isEmpty else { return }
        snapshot.tables[table, default: []] += rows
        if snapshot.tables[epochTable]?.isEmpty != false { snapshot.tables[epochTable] = [Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])] }
    }
    /// One parser belongs to one immutable read/validation pass. Formatters and
    /// memoized dates are never shared between accounts, threads or refreshes.
    final class Parser {
        private let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
        private let whole = ISO8601DateFormatter()
        private var instants: [String: Date] = [:]
        private var invalidInstants = Set<String>()
        private var days: [String: Bool] = [:]
        private func instant(_ text: String) -> Date? {
            if let value = instants[text] { return value }
            if invalidInstants.contains(text) { return nil }
            if let value = fractional.date(from: text) ?? whole.date(from: text) { instants[text] = value; return value }
            invalidInstants.insert(text); return nil
        }
        private func validDay(_ text: String) -> Bool {
            if let value = days[text] { return value }
            let value = Dates.parse(text) != nil; days[text] = value; return value
        }
        func date(_ text: String) -> Date? { instant(text) }
        func parent(_ row: Record) -> TaskActivity? { TaskActivity(row: row, parseInstant: instant, validDay: validDay) }
        func event(_ row: Record) -> TaskNodeActivity? { TaskNodeActivity(row: row, parseInstant: instant, validDay: validDay) }
    }
    struct Feed: Equatable, Sendable {
        let rows: [Record]
        let epoch: [Record]
        var tables: [String: [Record]] { [TaskNodeActivity.table: rows, TaskNodeActivity.epochTable: epoch] }
    }
    static func validEpoch(_ rows: [Record]) -> Bool {
        rows.count == 1 && rows[0].id == "current" && Set(rows[0].fields.keys) == ["id", "recorded_from"] && TaskPlanning.instant(rows[0].string("recorded_from")) != nil
    }
    /// A fresh task read cannot certify an unavailable optional ledger. Remove
    /// both halves together, including cached history after access recovery.
    static func discardUnavailable(in tables: inout [String: [Record]], remote: [String: [Record]]) {
        guard remote["tasks"] != nil, remote[table] == nil || !validEpoch(remote[epochTable] ?? []) else { return }
        tables.removeValue(forKey: table); tables.removeValue(forKey: epochTable)
    }
    static func query(after sequence: Int64) -> String { "/rest/v1/task_node_activity?select=*&order=sequence.asc&sequence=gt.\(sequence)&limit=500" }
}

/// Current work follows ordinary task occurrences. A heading is transparent:
/// its nearest ordinary descendants take its place, while an ordinary task's
/// checklist remains part of that task. This is a read model, never live rows.
struct ProjectWorkScope {
    struct Item: Identifiable {
        let id: String
        let task: Record
        let root: Record
        let navigationTask: Record?
        let parentTitles: [String]
        var nested: Bool { id != root.id }
    }
    private(set) var items: [Item] = []
    private(set) var contexts: [Record] = []
    private(set) var outline: [Record] = []
    private(set) var incompleteProjects = Set<String>()
    private var groups: [String: [Item]] = [:]
    func items(project: String) -> [Item] { groups[project.lowercased()] ?? [] }
    func incomplete(project: String) -> Bool { incompleteProjects.contains(project.lowercased()) }
    init(tasks: [Record]) {
        var roots: [String: Record] = [:], visited = 0
        for root in tasks {
            let project = root.string("project_id").lowercased(), key = root.id.lowercased()
            guard !key.isEmpty, !root.id.hasPrefix("subtask:") else { incompleteProjects.insert(project); continue }
            if let previous = roots[key] {
                if previous != root { incompleteProjects.insert(project); incompleteProjects.insert(previous.string("project_id").lowercased()) }
                continue
            }
            roots[key] = root
            func visit(_ source: Record, positions: [Int], keys: [String], reference: String?, titles: [String], depth: Int) {
                visited += 1
                guard depth <= SubtaskTree.readableDepth, visited <= TaskHierarchyIndex.maximumItems else { incompleteProjects.insert(project); return }
                switch TaskKind(source) {
                case .unsupported:
                    incompleteProjects.insert(project)
                    if let reference {
                        let context = TaskHierarchyIndex.Item(source: source, root: root, path: keys, parentTitles: titles, id: reference).record
                        contexts.append(context); outline.append(context)
                    }
                case .task:
                    let id: String
                    if positions.isEmpty { id = root.id }
                    else {
                        let identity = try! JSONEncoder().encode([root.id.lowercased()] + positions.map(String.init))
                        id = "work:" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
                    }
                    var task = source; task["id"] = .string(id)
                    for field in ["project_id", "section_id", "user_id", "task_generation"] { task[field] = root[field] }
                    let navigation = reference.map { TaskHierarchyIndex.Item(source: source, root: root, path: keys, parentTitles: titles, id: $0).record }
                    let item = Item(id: id, task: task, root: root, navigationTask: navigation, parentTitles: titles)
                    items.append(item); groups[project, default: []].append(item)
                    if let navigation { outline.append(navigation) }
                case .heading:
                    if let reference {
                        let context = TaskHierarchyIndex.Item(source: source, root: root, path: keys, parentTitles: titles, id: reference).record
                        contexts.append(context); outline.append(context)
                    }
                    if source.completed { incompleteProjects.insert(project) }
                    let children = source["subtasks"]
                    guard SubtaskTree.hasListContainer(children) else { incompleteProjects.insert(project); return }
                    let indices = SubtaskTree.uniqueChildIndices(children)
                    for (index, child) in children.list.enumerated() {
                        let row: Record
                        if case .string(let title) = child, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { row = Record(["title": .string(title)]) }
                        else if case .object(let fields) = child, case .string(let title)? = fields["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { row = Record(fields) }
                        else { incompleteProjects.insert(project); continue }
                        let childKey = row.id
                        let unique = !childKey.isEmpty && indices[childKey] != nil
                        let next = unique ? reference.map { SubtaskTree.reference(parent: $0, key: childKey) } : nil
                        visit(row, positions: positions + [index], keys: keys + [childKey], reference: next, titles: titles + [source.title], depth: depth + 1)
                    }
                }
            }
            visit(root, positions: [], keys: [], reference: root.id, titles: [], depth: 0)
        }
    }
    func attention(project: String, now: Date, calendar: Calendar = .current) -> [Item] {
        let today = TaskPlanner.dayKey(now, calendar: calendar)
        let soon = TaskPlanner.dayKey(calendar.date(byAdding: .day, value: 6, to: now)!, calendar: calendar)
        return items(project: project).filter {
            guard !$0.task.completed else { return false }
            let deadline = $0.task.string("deadline_date"), planned = TaskPlanner.plannedDay($0.task, calendar: calendar)
            return (!deadline.isEmpty && Dates.parse(deadline) != nil && deadline <= soon) || (!planned.isEmpty && Dates.parse(planned) != nil && planned < today)
        }.sorted {
            let a = $0.task.string("deadline_date"), b = $1.task.string("deadline_date")
            if a != b { return (a.isEmpty ? "9999" : a) < (b.isEmpty ? "9999" : b) }
            return $0.task.priority == $1.task.priority ? $0.id < $1.id : $0.task.priority < $1.task.priority
        }
    }
}

/// Read-only workload: headings provide context; their nearest ordinary descendants
/// are independent work. An ordinary task's checklist is already part of its work.
/// Only `presentation` rows may enter native actions, where Store revalidates them.
struct ProductiveTaskReading {
    let work: [Record]
    let presentation: [Record]
    let outline: [Record]
    let incomplete: Bool
    let incompleteProjects: Set<String>
    func countLabel(_ count: Int, project: String? = nil) -> String {
        let partial = project.map { incompleteProjects.contains($0.lowercased()) } ?? incomplete
        return (partial ? "≥" : "") + String(count)
    }
    let unavailable: Int
    let parents: [String: String]
    private let presentationIDs: Set<String>
    func contains(_ id: String) -> Bool { presentationIDs.contains(id) }
    init(tasks: [Record]) {
        let roots = tasks.filter { SubtaskTree.referencePath($0.id) == nil }
        let rootIDs = Set(roots.map { $0.id.lowercased() })
        let scope = ProjectWorkScope(tasks: roots)
        var work: [Record] = [], rows: [Record] = [], seen = Set<String>(), unavailable = 0
        var parents: [String: String] = [:]
        for item in scope.items {
            let row = item.navigationTask ?? item.task
            work.append(row)
            if !item.parentTitles.isEmpty { parents[row.id] = item.parentTitles.joined(separator: " › ") }
            if item.navigationTask != nil { rows.append(row) }
            else { unavailable += 1 }
            seen.insert(row.id)
        }
        // Already projected native rows are valid read inputs too. A source root
        // wins over its projections, so repeated projection never double-counts.
        for task in tasks {
            guard let path = SubtaskTree.referencePath(task.id), !rootIDs.contains(path[0].lowercased()), seen.insert(task.id).inserted else { continue }
            if TaskKind.mayComplete(task) { work.append(task); rows.append(task) }
        }
        // Retain addressable heading context, including legacy branches that need
        // parent review. Do not invent routable identities for unreadable children.
        var contexts = Set<String>()
        rows += scope.contexts.filter { contexts.insert($0.id.lowercased()).inserted }
        self.work = work; presentation = rows; presentationIDs = Set(rows.map(\.id))
        var outlineIDs = Set<String>()
        outline = (scope.outline + rows).filter { outlineIDs.insert($0.id).inserted }
        incompleteProjects = scope.incompleteProjects.union(scope.items.filter { $0.navigationTask == nil }.map { $0.root.string("project_id").lowercased() })
        incomplete = !incompleteProjects.isEmpty
        self.unavailable = unavailable
        self.parents = parents
    }
}

struct ProjectPulseReading {
    var countsIncomplete = false
    var total = 0
    var completed = 0
    var completions = 0
    var reopens = 0
    var additions = 0
    var movedIn = 0
    var movedOut = 0
    var events: [TaskActivity] = []
    var timeline: [WorkActivity] = []
    var historyIncomplete = false
    var malformed = 0
    var start: Date
    var end: Date
    init(project: String, tasks: [Record], activity: [Record], now: Date = Date(), calendar input: Calendar = .current, work suppliedWork: ProjectWorkScope? = nil, children: ChildWorkHistory? = nil, childReading suppliedChildren: ChildWorkReading? = nil) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        start = calendar.date(byAdding: .day, value: -7, to: end)!
        let work = suppliedWork ?? ProjectWorkScope(tasks: tasks), scope = work.items(project: project)
        countsIncomplete = work.incomplete(project: project)
        total = scope.count; completed = scope.filter { $0.task.completed }.count
        var seen = Set<String>(); malformed = 0
        let parser = TaskNodeActivity.Parser()
        events = activity.compactMap { row in
            guard let event = parser.parent(row) else { malformed += 1; return nil }
            guard seen.insert(event.id).inserted, event.involves(project: project) else { return nil }
            if let context = event.rootContext, !context.readable { malformed += 1 }
            return event
        }.sorted { $0.sequence == $1.sequence ? $0.id > $1.id : $0.sequence > $1.sequence }
        let child = suppliedChildren ?? children.map { ChildWorkReading($0, now: now) }
        let childEvents = child?.events(project: project) ?? []
        historyIncomplete = child.map { $0.incomplete(project: project) || ($0.recordedFrom.map { $0 > start } ?? true) } ?? false
        timeline = (events.filter { $0.recordedAt <= now }.map(WorkActivity.root) + childEvents.map(WorkActivity.child)).sorted(by: WorkActivity.newestFirst)
        let recent = events.filter { $0.recordedAt >= start && $0.recordedAt < end && $0.recordedAt <= now }
        func before(_ event: TaskActivity) -> Bool { event.before["project_id"]?.text.lowercased() == project.lowercased() }
        func after(_ event: TaskActivity) -> Bool { event.after["project_id"]?.text.lowercased() == project.lowercased() }
        completions = recent.filter { $0.kinds.contains(.completed) && !($0.rootContext?.generationChanged ?? false) && $0.workBefore && $0.workAfter && after($0) }.count
        reopens = recent.filter { $0.kinds.contains(.reopened) && !($0.rootContext?.generationChanged ?? false) && $0.workBefore && $0.workAfter && before($0) }.count
        additions = recent.filter { $0.kinds.contains(.created) && $0.workAfter && after($0) }.count
        movedIn = recent.filter { !before($0) && after($0) && $0.workAfter && $0.kinds.contains(.moved) }.count
        movedOut = recent.filter { before($0) && !after($0) && $0.workBefore && $0.kinds.contains(.moved) }.count
        for e in childEvents where e.recordedAt >= start && e.recordedAt < end {
            let before = e.before["project_id"]?.text.lowercased() == project.lowercased(), after = e.after["project_id"]?.text.lowercased() == project.lowercased()
            if e.kinds.contains(.completed), e.workBefore && e.workAfter, after { completions += 1 }
            if e.kinds.contains(.reopened), e.workBefore && e.workAfter, before { reopens += 1 }
            if e.kinds.contains(.created), e.workAfter, after { additions += 1 }
            if e.kinds.contains(.moved), e.workAfter, !before && after { movedIn += 1 }
            if e.kinds.contains(.moved), e.workBefore, before && !after { movedOut += 1 }
        }

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
    var historyIncomplete = false
    var childRecordedFrom: Date?
    var windowStart:Date
    var windowEnd:Date
    var weekStart:Date
    var scope:Scope
    var hasHistory:Bool { recordedFrom != nil }
    var reliable:Bool { hasHistory && malformed==0 }
    init(account:String,activity:[Record],epoch:[Record],goals:ProductivityGoals,scope:Scope = .mine,projectID:String? = nil,accessibleProjects:Set<String> = [],windowDays:Int=7,now:Date=Date(),children:ChildWorkHistory?=nil) {
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
        let rootRecordedFrom = recordedFrom
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
        var occurrences: [String: String] = [:]
        for event in unique.values.sorted(by:{$0.sequence==$1.sequence ? $0.id<$1.id : $0.sequence<$1.sequence}) {
            guard rootRecordedFrom != nil else { break }
            if let context = event.rootContext {
                guard context.readable else { malformed += 1; continue }
                let generation = context.afterGeneration ?? context.beforeGeneration
                if let generation {
                    if context.generationChanged || occurrences[event.taskID].map({ $0 != generation }) == true {
                        // A new occurrence cannot inherit a prior counter or active
                        // completion. Keep genuine earlier work as archived credit.
                        if let credit = active.removeValue(forKey: event.taskID) { archived.append(credit) }
                        latest.removeValue(forKey: event.taskID); deleted.remove(event.taskID)
                        lifecycles[event.taskID] = "generation:" + generation
                    }
                    occurrences[event.taskID] = generation
                }
            }
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
            if let context = event.rootContext, !event.before.isEmpty, !event.after.isEmpty, context.beforeType != context.afterType {
                if let credit = active.removeValue(forKey: event.taskID) { archived.append(credit) }
                latest.removeValue(forKey: event.taskID); lifecycles[event.taskID] = "scope:" + event.id
            }
            if event.kinds.contains(.reopened), event.workBefore && event.workAfter { active.removeValue(forKey:event.taskID) }
            if event.kinds.contains(.completed), event.workBefore && event.workAfter, event.rootContext?.generationChanged != true {
                let date=event.after["completed_at"].flatMap{instant($0.text)} ?? event.effectiveAt
                let next=Credit(taskID:event.taskID,lifecycle:lifecycles[event.taskID] ?? "existing:"+event.taskID,version:event.completionVersion,date:date,projectID:event.after["project_id"]?.text.lowercased() ?? "",actor:event.actor?.lowercased())
                if let previous=active[event.taskID],previous.version==next.version,previous != next { malformed+=1 }
                else { active[event.taskID]=next }
            } else if event.kinds.contains(.completion_time),var credit=active[event.taskID],event.after["completed"] == .bool(true), event.workAfter, event.rootContext?.generationChanged != true {
                if let date=event.after["completed_at"].flatMap({instant($0.text)}) { credit.date=date;credit.version=event.completionVersion;active[event.taskID]=credit }
                else { active.removeValue(forKey:event.taskID);malformed+=1 }
            }
            if event.kinds.contains(.deleted) {
                if let credit=active.removeValue(forKey:event.taskID) { archived.append(credit) }
                deleted.insert(event.taskID)
            }
        }
        var childCredits: [Credit] = []
        if let children {
            let visible = children.rows.map { rows in rows.filter { row in
                let scopes = [row["before_state"].object["project_id"]?.text.lowercased() ?? "", row["after_state"].object["project_id"]?.text.lowercased() ?? ""].filter { !$0.isEmpty }
                return scopes.isEmpty ? row.string("user_id").lowercased() == account : scopes.allSatisfy { accessible.contains($0) }
            } }
            let child = ChildWorkReading(ChildWorkHistory(rows: visible, epoch: children.epoch), now: now)
            childCredits = child.credits()
            historyIncomplete = child.incomplete || rootRecordedFrom == nil
            childRecordedFrom = child.recordedFrom
            if let childStart = child.recordedFrom { recordedFrom = rootRecordedFrom.map { min($0, childStart) } ?? childStart }
        }
        credits=(archived+Array(active.values)+childCredits).filter { credit in
            credit.date<=now && (scope == .workspace || credit.actor==account) && (projectID.map{$0.lowercased()==credit.projectID} ?? true)
        }.sorted{$0.date==$1.date ? $0.taskID<$1.taskID : $0.date<$1.date}
        today=credits.filter{$0.date>=todayStart && $0.date<windowEnd}.count
        week=credits.filter{$0.date>=weekStart && $0.date<windowEnd}.count
        let counts=Dictionary(grouping:credits){TaskPlanner.dayKey($0.date,calendar:calendar)}.mapValues(\.count)
        var day=windowStart
        while day<windowEnd {
            let end=calendar.date(byAdding:.day,value:1,to:day)!,key=TaskPlanner.dayKey(day,calendar:calendar)
            func coverageSince(_ from: Date?) -> Coverage { from.map { $0 >= end ? .untracked : $0 > day ? .partial : .recorded } ?? .untracked }
            var coverage = coverageSince(rootRecordedFrom)
            if children != nil {
                let other = coverageSince(childRecordedFrom)
                coverage = coverage == .recorded && other == .recorded ? .recorded : coverage == .untracked && other == .untracked ? .untracked : .partial
            }
            if coverage == .untracked,counts[key,default:0]>0 { coverage = .partial }
            if historyIncomplete, coverage == .recorded { coverage = .partial }
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
            if let context = event.rootContext {
                let generation = context.afterGeneration ?? context.beforeGeneration
                guard context.readable, generation != TaskNodeActivity.legacyGeneration,
                      current.string("user_id").lowercased() == event.owner.lowercased(),
                      generation == UUID(uuidString: current.string("task_generation"))?.uuidString.lowercased(),
                      tasks.filter({ $0.id.lowercased() == event.taskID.lowercased() }).count == 1 else { task = nil; return }
            }
            task = current
        } else { task = nil }
    }
}

/// Optional child history is distinct from a loaded empty ledger.
struct ChildWorkHistory: Sendable {
    let rows: [Record]?
    let epoch: [Record]?
    var recordedFrom: Date? {
        guard let epoch, TaskNodeActivity.validEpoch(epoch) else { return nil }
        return TaskPlanning.instant(epoch[0].string("recorded_from"))
    }
}

/// Display identity includes its feed. Sequences are comparable only within a feed.
enum WorkActivity: Identifiable, Equatable {
    case root(TaskActivity), child(TaskNodeActivity)
    var id: String { switch self { case .root(let e): return "root:" + e.id; case .child(let e): return "child:" + e.id } }
    var accessibilityKey: String { switch self { case .root(let e): return e.id; case .child(let e): return "child-" + e.id } }
    var recordedAt: Date { switch self { case .root(let e): return e.recordedAt; case .child(let e): return e.recordedAt } }
    var effectiveAt: Date { switch self { case .root(let e): return e.effectiveAt; case .child(let e): return e.effectiveAt } }
    var sequence: Int64 { switch self { case .root(let e): return e.sequence; case .child(let e): return e.sequence } }
    var actor: String? { switch self { case .root(let e): return e.actor; case .child(let e): return e.actor } }
    var before: [String: JSON] { switch self { case .root(let e): return e.before; case .child(let e): return e.before } }
    var after: [String: JSON] { switch self { case .root(let e): return e.after; case .child(let e): return e.after } }
    var kinds: [String] {
        switch self {
        case .root(let e):
            if let context = e.rootContext, context.readable, context.beforeType != nil, context.afterType != nil, context.beforeType != context.afterType {
                return e.kinds.filter { $0 != .completed && $0 != .reopened }.map(\.rawValue) + ["type_changed"]
            }
            return e.kinds.map(\.rawValue)
        case .child(let e):
            let changed = !e.before.isEmpty && !e.after.isEmpty && (e.workBefore != e.workAfter || e.typeBefore != e.typeAfter)
            return e.kinds.filter { !changed || $0 != .completed && $0 != .reopened }.map(\.rawValue)
        }
    }
    var title: String { kinds.map { key in
        if let kind = TaskActivity.Kind(rawValue: key) { return kind.title }
        switch key { case "scope_changed": return "Work scope changed"; case "type_changed": return "Type changed"; default: return "Some history unavailable" }
    }.joined(separator: " · ") }
    var isChild: Bool { if case .child = self { return true }; return false }
    func involves(project: String) -> Bool { before["project_id"]?.text.lowercased() == project.lowercased() || after["project_id"]?.text.lowercased() == project.lowercased() }
    func context(project: String, tasks: [Record], projects: [Record], members: [Record], account: String) -> (task: Record?, actor: String) {
        switch self {
        case .root(let event):
            let c = ProjectActivityContext(event: event, project: project, tasks: tasks, projects: projects, members: members, account: account)
            return (c.task, c.actorLabel)
        case .child(let event):
            guard !account.isEmpty, involves(project: project), projects.contains(where: { $0.id.lowercased() == project.lowercased() }) else { return (nil, "Name unavailable") }
            let name: String
            if actor?.lowercased() == account.lowercased() { name = "You" }
            else if let actor { let current = members.first { $0.id.lowercased() == actor.lowercased() }?.string("display_name").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; name = current.isEmpty ? "Collaborator" : current }
            else { name = "Name unavailable" }
            return (event.currentTask(tasks: tasks, projects: projects, account: account), name)
        }
    }
    static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        if a.recordedAt != b.recordedAt { return a.recordedAt > b.recordedAt }
        if a.isChild == b.isChild, a.sequence != b.sequence { return a.sequence > b.sequence }
        return a.id < b.id
    }
}

/// Immutable child read. Ambiguous rows never lend authority or completion credit.
struct ChildWorkReading {
    let events: [TaskNodeActivity]
    let recordedFrom: Date?
    let incomplete: Bool
    let malformed: Int
    let blockedSubjects: Set<String>
    private let grouped: [String: [TaskNodeActivity]]
    private let incompleteProjects: Set<String>
    private let globallyIncomplete: Bool
    func events(project: String) -> [TaskNodeActivity] { grouped[project.lowercased()] ?? [] }
    func incomplete(project: String) -> Bool { globallyIncomplete || incompleteProjects.contains(project.lowercased()) }
    init(_ history: ChildWorkHistory, now: Date) {
        recordedFrom = history.rows == nil ? nil : history.recordedFrom.flatMap { $0 <= now ? $0 : nil }
        guard let rows = history.rows, recordedFrom != nil else { events = []; incomplete = true; malformed = 0; blockedSubjects = []; grouped = [:]; incompleteProjects = []; globallyIncomplete = true; return }
        let parser = TaskNodeActivity.Parser()
        var unique: [String: TaskNodeActivity] = [:], sequences: [Int64: TaskNodeActivity] = [:]
        var badIDs = Set<String>(), blocked = Set<String>(), blockedRoots = Set<String>(), unknownRoot = false, malformed = 0
        var partial = Set<String>(), global = false
        func mark(_ before: [String: JSON], _ after: [String: JSON]) {
            let ids = [before["project_id"]?.text.lowercased() ?? "", after["project_id"]?.text.lowercased() ?? ""].filter { !$0.isEmpty }
            if ids.isEmpty { global = true }; partial.formUnion(ids)
        }
        for row in rows {
            guard let event = parser.event(row) else {
                malformed += 1; mark(row["before_state"].object, row["after_state"].object)
                if let gen = UUID(uuidString: row.string("task_generation")), UUID(uuidString: row.string("task_id")) != nil, !row.string("node_key").isEmpty { blocked.insert(row.string("task_id").lowercased() + ":" + gen.uuidString.lowercased() + ":" + row.string("node_key")) }
                else if UUID(uuidString: row.string("task_id")) != nil { blockedRoots.insert(row.string("task_id").lowercased()) }
                else { unknownRoot = true }
                continue
            }
            guard event.recordedAt <= now else { continue }
            if let previous = unique[event.id], previous != event { blocked.insert(previous.subject); blocked.insert(event.subject); badIDs.insert(event.id); malformed += 1; mark(previous.before, previous.after); mark(event.before, event.after) }
            if let previous = sequences[event.sequence], previous.id != event.id { blocked.insert(previous.subject); blocked.insert(event.subject); malformed += 1; mark(previous.before, previous.after); mark(event.before, event.after) }
            unique[event.id] = event; sequences[event.sequence] = event
        }
        events = unique.values.filter { event in
            if unknownRoot || blockedRoots.contains(event.rootID) { mark(event.before, event.after); return false }
            return !badIDs.contains(event.id) && !blocked.contains(event.subject)
        }.sorted { $0.sequence == $1.sequence ? $0.id < $1.id : $0.sequence < $1.sequence }
        self.malformed = malformed; blockedSubjects = blocked
        var groups: [String: [TaskNodeActivity]] = [:]
        for event in events {
            let ids = Set([event.before["project_id"]?.text.lowercased() ?? "", event.after["project_id"]?.text.lowercased() ?? ""]).subtracting([""])
            for id in ids { groups[id, default: []].append(event) }
            if event.isGap { mark(event.before, event.after) }
        }
        grouped = groups; incompleteProjects = partial; globallyIncomplete = global
        incomplete = malformed > 0 || events.contains(where: \.isGap)
    }
    func credits() -> [InsightsReading.Credit] {
        var active: [String: InsightsReading.Credit] = [:], archived: [InsightsReading.Credit] = []
        var latest: [String: Int64] = [:], deleted = Set<String>(), lifecycle: [String: String] = [:], roots: [String: String] = [:]
        let dates = TaskNodeActivity.Parser()
        for e in events {
            if e.isGap {
                for subject in roots.keys.filter({ roots[$0] == e.rootID }) { active.removeValue(forKey: subject); latest.removeValue(forKey: subject); deleted.remove(subject); lifecycle[subject] = "after-gap:" + e.id }
                continue
            }
            let subject = e.subject; roots[subject] = e.rootID
            if e.kinds.contains(.created) { deleted.remove(subject); latest.removeValue(forKey: subject); lifecycle[subject] = e.id }
            // Becoming a heading/checklist detail closes productive scope without
            // undoing genuine earlier work. Promotion cannot manufacture a credit.
            if !e.before.isEmpty, !e.after.isEmpty, e.workBefore != e.workAfter || e.typeBefore != e.typeAfter {
                if let credit = active.removeValue(forKey: subject) { archived.append(credit) }
                latest.removeValue(forKey: subject); lifecycle[subject] = "scope:" + e.id
            }
            if deleted.contains(subject) || latest[subject].map({ e.completionVersion < $0 }) == true { continue }
            latest[subject] = e.completionVersion
            if e.kinds.contains(.reopened), e.workBefore && e.workAfter { active.removeValue(forKey: subject) }
            if e.kinds.contains(.completed), e.workBefore && e.workAfter, e.typeBefore == "task", e.typeAfter == "task" {
                active[subject] = InsightsReading.Credit(taskID: "child:" + subject, lifecycle: lifecycle[subject] ?? "existing:" + subject, version: e.completionVersion, date: e.after["completed_at"].flatMap { dates.date($0.text) } ?? e.effectiveAt, projectID: e.after["project_id"]?.text.lowercased() ?? "", actor: e.actor?.lowercased())
            } else if e.kinds.contains(.completion_time), e.workBefore && e.workAfter, var credit = active[subject], e.after["completed"] == .bool(true) {
                if let date = e.after["completed_at"].flatMap({ dates.date($0.text) }) { credit.date = date; credit.version = e.completionVersion; active[subject] = credit }
                else { active.removeValue(forKey: subject) }
            }
            if e.kinds.contains(.deleted) { if let credit = active.removeValue(forKey: subject) { archived.append(credit) }; deleted.insert(subject) }
        }
        return archived + Array(active.values)
    }
}
