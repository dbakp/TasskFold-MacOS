import Foundation
import CryptoKit
import Security

struct BackupFailure: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// Portable work, without authentication sessions or executable mutation queues. Retained recovery files
/// additionally preserve the queue inside the encrypted, account-bound vault.
struct WorkspaceBackup: Codable, Sendable {
    var format = "com.taskfold.workspace"
    var version = 1
    var id: String
    var createdAt: String
    var sourceAccount: String
    var tables: [String: [Record]]
    var unsyncedChanges: Int
    var legacy = false
    static let maximumBytes = 256 * 1024 * 1024
    static let workTables = ["projects", "labels", "sections", "tasks", "saved_views", "favorites", "view_preferences", "view_orders", "focus_sessions"]
    static func make(_ snapshot: Snapshot, account: String, now: Date = Date()) -> Self {
        var tables = snapshot.tables
        tables[FocusSessionChange.table] = tables[FocusSessionChange.table]?.map { row in
            var row = row
            if let session = FocusSessionChange.session(in: row, account: account), let checkpoint = try? session.checkpoint(at: now) { row["state"] = checkpoint.document }
            return row
        }
        return Self(id: UUID().uuidString.lowercased(), createdAt: ISO8601DateFormatter().string(from: now), sourceAccount: account,
                    tables: tables, unsyncedChanges: snapshot.pending.count)
    }
    func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw BackupFailure(message: "This backup exceeds the 256 MB file limit.") }
        return data
    }
    static func read(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw BackupFailure(message: "Choose a backup no larger than 256 MB.") }
        do {
            let root = try JSONDecoder().decode(JSON.self, from: data)
            guard case .object(let object) = root else { throw BackupFailure(message: "A Taskfold backup must be a JSON object.") }
            var backup: Self
            if object["format"] != nil || object["version"] != nil {
                guard object["format"] == .string("com.taskfold.workspace"), object["version"] == .number(1) else {
                    throw BackupFailure(message: "This backup format or version is unsupported. Update Taskfold before restoring it.")
                }
                backup = try JSONDecoder().decode(Self.self, from: data)
                guard UUID(uuidString: backup.id) != nil, TaskPlanning.instant(backup.createdAt) != nil,
                      backup.sourceAccount.count <= 200, backup.unsyncedChanges >= 0 else { throw BackupFailure(message: "The backup header is invalid.") }
            } else {
                // Original native exports were the table dictionary. Never interpret a cache/session as one.
                let tables = try JSONDecoder().decode([String: [Record]].self, from: data)
                guard !Set(tables.keys).isDisjoint(with: Set(workTables)) else { throw BackupFailure(message: "This file contains no Taskfold workspace tables.") }
                backup = Self(id: stableID("legacy-file", String(SHA256.hash(data: data).description)), createdAt: Dates.timestamp(), sourceAccount: "", tables: tables, unsyncedChanges: 0, legacy: true)
            }
            try backup.validate()
            return backup
        } catch let error as BackupFailure { throw error }
        catch { throw BackupFailure(message: "This backup could not be read: \(error.localizedDescription)") }
    }
    /// Deterministic application UUIDs: a retry or another native client maps the same source to the same ID.
    static func stableID(_ namespace: String, _ value: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(("com.taskfold.restore.v1|" + namespace + "|" + value).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
    }
    private static let columns: [String: Set<String>] = [
        "projects": ["id","user_id","name","description","color","created_at","order_index","source_metadata"],
        "labels": ["id","user_id","name","color","created_at"],
        "sections": ["id","user_id","project_id","name","created_at","order_index"],
        "tasks": ["id","user_id","title","description","completed","completion_version","task_generation","priority","due_date","due_time","project_id","section_id","labels","subtasks","reminders","attachments","comments","created_at","completed_at","recurrence_pattern","is_recurring","recurrence_parent_id","recurrence_end_date","notification_sent_at","assigned_to","deadline_date","duration_minutes","time_zone","reminder_specs","source_metadata","scheduled_at"],
        "saved_views": ["id","user_id","name","query_ast","layout","grouping","sort_by","include_completed","order_index","created_at","updated_at"],
        "favorites": ["id","user_id","order_index","created_at"],
        "view_preferences": ["id","user_id","layout","grouping","sort_by","include_completed","priority_filter","overdue_collapsed","updated_at","working_hours"],
        "view_orders": ["id","user_id","ids","updated_at"],
        "focus_sessions": ["id","user_id","revision","action_id","state","updated_at"]
    ]
    func validate() throws {
        guard tables.values.reduce(0, { $0 + $1.count }) <= 50000 else { throw BackupFailure(message: "This backup exceeds the 50,000-record limit.") }
        for (table, rows) in tables {
            let activity = table == TaskActivity.table || table == TaskActivity.epochTable
            let metadata = activity || table == "profiles" || table == "project_collaborators" || table.hasPrefix("project_members:") || table == "_local_day_order"
            guard Self.workTables.contains(table) || metadata else { throw BackupFailure(message: "This backup includes the unsupported table “\(table)”. Update Taskfold before restoring it.") }
            var ids = Set<String>()
            for row in rows {
                try Self.checkJSON(.object(row.fields), depth: 0)
                if activity {
                    guard ids.insert(UUID(uuidString: row.id)?.uuidString.lowercased() ?? row.id).inserted else { throw BackupFailure(message: "The activity archive contains a duplicate ID.") }
                    if table == TaskActivity.table {
                        guard TaskActivity(row: row) != nil else { throw BackupFailure(message: "The activity archive contains an invalid event.") }
                    } else {
                        guard rows.count == 1, row.id == "current", Set(row.fields.keys) == ["id", "recorded_from"], TaskPlanning.instant(row.string("recorded_from")) != nil else { throw BackupFailure(message: "The activity recording start is invalid.") }
                    }
                    continue
                }
                if metadata && table != "_local_day_order" { continue }
                guard !row.id.isEmpty, row.id.unicodeScalars.count <= 300, ids.insert(UUID(uuidString: row.id)?.uuidString.lowercased() ?? row.id).inserted else { throw BackupFailure(message: "The \(table) table has a missing, duplicate or invalid ID.") }
                guard let allowed = Self.columns[table == "_local_day_order" ? "view_orders" : table], Set(row.fields.keys).isSubset(of: allowed) else { throw BackupFailure(message: "The \(table) table includes newer or unsupported fields. Update Taskfold before restoring it.") }
                for key in ["id","user_id","name","title","description","color","project_id","section_id","assigned_to","recurrence_parent_id","time_zone","due_date","due_time","deadline_date","recurrence_end_date","scheduled_at"] {
                    if let value = row.fields[key], value != .null, case .string = value {} else if let value = row.fields[key], value != .null { throw BackupFailure(message: "\(table).\(key) must be text.") }
                }
                if let generation = row.fields["task_generation"], generation != .null {
                    guard case .string(let value) = generation, UUID(uuidString: value) != nil,
                          value.lowercased() != "00000000-0000-0000-0000-000000000000" else { throw BackupFailure(message: "A task has an invalid generation ID.") }
                }
                for key in ["completed","is_recurring","include_completed","overdue_collapsed"] {
                    if let value = row.fields[key], value != .null, case .bool = value {} else if row.fields[key] != nil && row.fields[key] != .null { throw BackupFailure(message: "\(table).\(key) must be a boolean.") }
                }
                for (key, low, high) in [("priority",1,4),("priority_filter",0,4),("duration_minutes",1,10080),("order_index",0,2147483647),("completion_version",0,9007199254740991)] {
                    if let value = row.fields[key], value != .null {
                        guard case .number(let number) = value, number.rounded() == number, number >= Double(low), number <= Double(high) else { throw BackupFailure(message: "\(table).\(key) is out of range.") }
                    }
                }
                for key in ["due_date","deadline_date","recurrence_end_date"] where !row.string(key).isEmpty {
                    guard row.string(key).count == 10, Dates.parse(row.string(key)) != nil else { throw BackupFailure(message: "\(table).\(key) is not a real YYYY-MM-DD date.") }
                }
                for key in ["created_at","updated_at","completed_at","notification_sent_at","scheduled_at"] where row.fields[key] != nil && row[key] != .null {
                    guard TaskPlanning.instant(row.string(key)) != nil else { throw BackupFailure(message: "\(table).\(key) is not a valid timestamp.") }
                }
                if !row.string("due_time").isEmpty {
                    guard row.string("due_time").range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\.[0-9]+)?)?$"#, options: .regularExpression) != nil else { throw BackupFailure(message: "A task has an invalid planned time.") }
                }
                if !row.string("time_zone").isEmpty, TimeZone(identifier: row.string("time_zone")) == nil { throw BackupFailure(message: "A task has an unknown time zone.") }
                for key in ["labels","reminders","ids"] where row.fields[key] != nil && row[key] != .null {
                    guard case .array(let values) = row[key], values.count <= 10000, values.allSatisfy({ if case .string = $0 { return true }; return false }) else { throw BackupFailure(message: "\(table).\(key) must be an array of text values.") }
                }
                for key in ["subtasks","comments","attachments","reminder_specs"] where row.fields[key] != nil && row[key] != .null {
                    guard case .array(let values) = row[key], values.count <= (key == "reminder_specs" ? 20 : 10000), values.allSatisfy({ if case .object = $0 { return true }; return false }) else { throw BackupFailure(message: "\(table).\(key) must be an array of objects.") }
                }
                for key in ["source_metadata","recurrence_pattern"] where row.fields[key] != nil && row[key] != .null {
                    guard case .object = row[key] else { throw BackupFailure(message: "\(table).\(key) must be an object.") }
                }
                for (key, options) in [("layout",["list","board","calendar"]),("grouping",["none","project","priority","date","deadline"]),("sort_by",["manual","priority","date","deadline","duration","title"])] where row.fields[key] != nil {
                    guard options.contains(row.string(key)), !(table == "saved_views" && key == "layout" && row.string(key) == "calendar") else { throw BackupFailure(message: "\(table).\(key) is unsupported.") }
                }
                if row["scheduled_at"] != .null {
                    guard !row.string("due_date").isEmpty, !row.string("due_time").isEmpty, let zone = TimeZone(identifier: row.string("time_zone")), let instant = TaskPlanning.instant(row.string("scheduled_at")) else { throw BackupFailure(message: "A fixed task instant needs a planned date, time and time zone.") }
                    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd HH:mm"
                    guard formatter.string(from: instant) == row.string("due_date") + " " + row.string("due_time").prefix(5) else { throw BackupFailure(message: "A fixed task instant does not match its planned date and time.") }
                }
                if table == "tasks", row["is_recurring"].flag {
                    let rule = Record(row["recurrence_pattern"].object)
                    guard Recurrence.valid(rule), Recurrence.number(rule["interval"], in: 1...10000) != nil else { throw BackupFailure(message: "A recurring task has an unsupported or invalid repeat rule.") }
                }
                if table == "saved_views" { _ = try FilterRule(document: row["query_ast"]) }
                if row["working_hours"] != .null { _ = try WorkingHours(document: row["working_hours"]) }
                if table == FocusSessionChange.table, !FocusSessionChange.validRow(row, account: row.string("user_id")) {
                    throw BackupFailure(message: "The backup includes an invalid Focus session.")
                }
                if ["projects","labels","sections","saved_views"].contains(table), row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw BackupFailure(message: "A \(table) record has no name.") }
                if table == "saved_views", row.name.unicodeScalars.count > 120 { throw BackupFailure(message: "A filter name exceeds 120 characters.") }
                if table == "tasks", !(row.fields["title"].map { if case .string = $0 { return true }; return false } ?? false) { throw BackupFailure(message: "A task has no title field.") }
            }
        }
    }
    private static func checkJSON(_ value: JSON, depth: Int) throws {
        guard depth <= 32 else { throw BackupFailure(message: "A backup value is nested too deeply.") }
        switch value {
        case .number(let n): guard n.isFinite && abs(n) <= 9_000_000_000_000_000 else { throw BackupFailure(message: "A backup number is out of range.") }
        case .array(let values): guard values.count <= 10000 else { throw BackupFailure(message: "A backup collection is too large.") }; for v in values { try checkJSON(v, depth: depth + 1) }
        case .object(let values): guard values.count <= 1000 else { throw BackupFailure(message: "A backup object is too large.") }; for v in values.values { try checkJSON(v, depth: depth + 1) }
        default: break
        }
    }
}

enum RestorePolicy: String, CaseIterable, Identifiable { case keepCurrent, backupValues; var id: String { rawValue }; var title: String { self == .keepCurrent ? "Keep current edits" : "Use backup values" } }
struct RestorePlan {
    var changes: [Mutation] = []
    var added = 0, updated = 0, kept = 0
    var counts: [String: Int] = [:]
    var warnings: [String] = []
    var mappedIDs: [String: [String: String]] = [:]
    var total: Int { added + updated }
}

extension WorkspaceBackup {
    func plan(current: Snapshot, account: String, policy: RestorePolicy = .keepCurrent) throws -> RestorePlan {
        try validate()
        guard !account.isEmpty else { throw BackupFailure(message: "Open a workspace before restoring a backup.") }
        var result = RestorePlan()
        func canonical(_ value: String) -> String { UUID(uuidString: value)?.uuidString.lowercased() ?? value }
        let source = sourceAccount.isEmpty ? "legacy" : canonical(sourceAccount)
        var tables = self.tables
        if tables["view_orders"] == nil, let orders = tables["_local_day_order"] { tables["view_orders"] = orders }
        let defaults: [String: [String: JSON]] = [
            "projects": ["order_index": .number(0), "source_metadata": .object([:])],
            "sections": ["order_index": .number(0)],
            "saved_views": ["layout": .string("list"), "grouping": .string("none"), "sort_by": .string("manual"), "include_completed": .bool(false), "order_index": .number(0)],
            "favorites": ["order_index": .number(0)],
            "view_preferences": ["layout": .string("list"), "grouping": .string("none"), "sort_by": .string("manual"), "include_completed": .bool(false), "priority_filter": .number(0), "overdue_collapsed": .bool(false)],
            "view_orders": ["ids": .array([])]
        ]
        let currentRows = current.tables.mapValues { Dictionary($0.map { (canonical($0.id), $0) }, uniquingKeysWith: { first, _ in first }) }
        for table in Self.workTables.prefix(5) {
            for row in tables[table] ?? [] {
                let existing = currentRows[table]?[canonical(row.id)]
                let own = canonical(row.string("user_id")) == canonical(account) && (canonical(sourceAccount) == canonical(account) || legacy)
                let unchangedProject = !["tasks", "sections"].contains(table) || row.string("project_id").isEmpty || (result.mappedIDs["projects"]?[row.string("project_id")] ?? result.mappedIDs["projects"]?[canonical(row.string("project_id"))]) == canonical(row.string("project_id"))
                let reuse = own && unchangedProject && UUID(uuidString: row.id) != nil && (existing == nil || existing.map { canonical($0.string("user_id")) == canonical(account) } == true)
                let target = reuse ? canonical(row.id) : Self.stableID(source + "|" + canonical(account) + "|" + table, canonical(row.id))
                result.mappedIDs[table, default: [:]][row.id] = target
                result.mappedIDs[table, default: [:]][canonical(row.id)] = target
            }
        }
        func mapped(_ table: String, _ value: String, required: Bool = false) throws -> String {
            if value.isEmpty { return "" }
            if let id = result.mappedIDs[table]?[value] ?? result.mappedIDs[table]?[canonical(value)] { return id }
            if (canonical(sourceAccount) == canonical(account) || legacy), currentRows[table]?[canonical(value)].map({ canonical($0.string("user_id")) == canonical(account) }) == true { return canonical(value) }
            if required { throw BackupFailure(message: "A \(table) reference is missing from this backup and workspace.") }
            return Self.stableID(source + "|" + canonical(account) + "|" + table, canonical(value))
        }
        let scopeReferences = try NSRegularExpression(pattern: "(?<![a-zA-Z0-9_])(project|label|view|section|note):([^:|]+)")
        func scope(_ key: String) throws -> String {
            guard key.unicodeScalars.count <= 300 else { throw BackupFailure(message: "A view key is too long.") }
            let matches = scopeReferences.matches(in: key, range: NSRange(key.startIndex..., in: key))
            var updated = key
            // Replace right-to-left to retain each original range. Unknown targets are
            // namespaced too, so a foreign order cannot bind unrelated recipient work.
            for match in matches.reversed() {
                guard let kindRange = Range(match.range(at: 1), in: key), let idRange = Range(match.range(at: 2), in: key), let wholeRange = Range(match.range, in: updated) else { continue }
                let kind = String(key[kindRange]), id = String(key[idRange])
                if kind == "project" && id == "none" && key[..<kindRange.lowerBound].hasSuffix("group:") { continue }
                let table = ["project":"projects", "label":"labels", "view":"saved_views", "section":"sections", "note":"tasks"][kind]!
                updated.replaceSubrange(wholeRange, with: kind + ":" + (try mapped(table, id)))
            }
            if key.hasPrefix("group:") {
                let parts = key.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 3 && !parts[1].isEmpty {
                    updated = "group:" + (try mapped("projects", String(parts[1]))) + ":" + (parts[2] == "none" ? "none" : try mapped("sections", String(parts[2])))
                }
            }
            guard updated.unicodeScalars.count <= 300 else { throw BackupFailure(message: "A restored view key is too long.") }
            return updated
        }
        var clearedAssignments = 0, missingFilterTargets = 0
        func person(_ value: JSON, project: String) -> JSON {
            guard !value.text.isEmpty else { return .null }
            if canonical(value.text) == canonical(sourceAccount) || canonical(value.text) == canonical(account) { return .string(account) }
            let allowed = currentRows["projects"]?[project]?.string("user_id") == value.text || current.tables["project_collaborators"]?.contains { $0.string("project_id") == project && $0.string("user_id") == value.text && $0.string("status") == "accepted" } == true
            if allowed { return value }
            clearedAssignments += 1; return .null
        }
        var childIDs = Set<String>()
        func children(_ values: [JSON], root: String, project: String, reuseIDs: Bool, path: String = "") throws -> [JSON] {
            return try values.enumerated().map { index, child in
                guard case .object(var fields) = child, case .string = fields["title"] else { throw BackupFailure(message: "A subtask is malformed.") }
                let old = fields["id"]?.text ?? "", location = path + "/" + String(index)
                guard old.isEmpty || childIDs.insert(old).inserted else { throw BackupFailure(message: "A task contains duplicate subtask IDs.") }
                for key in ["id", "assigned_to"] where fields[key] != nil && fields[key] != .null { guard case .string = fields[key] else { throw BackupFailure(message: "A subtask has an invalid \(key).") } }
                if let completed = fields["completed"], case .bool = completed {} else if fields["completed"] != nil { throw BackupFailure(message: "A subtask completion value is invalid.") }
                fields["id"] = .string(reuseIDs && !old.isEmpty ? old : Self.stableID(source + "|" + account + "|child", root + "|" + (old.isEmpty ? location : old)))
                if fields["assigned_to"] != nil { fields["assigned_to"] = person(fields["assigned_to"]!, project: project) }
                if let nested = fields["subtasks"] { guard case .array(let rows) = nested else { throw BackupFailure(message: "A nested subtask collection is malformed.") }; fields["subtasks"] = .array(try children(rows, root: root, project: project, reuseIDs: reuseIDs, path: location)) }
                return .object(fields)
            }
        }
        func remapRule(_ rule: FilterRule) throws -> FilterRule {
            switch rule {
            case .predicate(let field, let value):
                if ["project","section","label"].contains(field) {
                    let table = field == "project" ? "projects" : field == "section" ? "sections" : "labels"
                    if result.mappedIDs[table]?[value] == nil { missingFilterTargets += 1 }
                    return .predicate(field, try mapped(table, value))
                }
                if field == "assignee" && value == sourceAccount { return .predicate(field, "me") }
                return rule
            case .and(let r): return .and(try r.map(remapRule))
            case .or(let r): return .or(try r.map(remapRule))
            case .not(let r): return .not(try remapRule(r))
            }
        }
        func orderedRows(_ table: String) throws -> [Record] {
            let rows = tables[table] ?? []
            guard table == "tasks" else { return rows }
            let byID = Dictionary(uniqueKeysWithValues: rows.map { (canonical($0.id), $0) })
            var remaining: [String: Int] = [:], children: [String: [String]] = [:]
            for row in rows {
                let parent = canonical(row.string("recurrence_parent_id"))
                remaining[canonical(row.id)] = byID[parent] == nil ? 0 : 1
                if byID[parent] != nil { children[parent, default: []].append(canonical(row.id)) }
            }
            var queue = rows.filter { remaining[canonical($0.id)] == 0 }, cursor = 0
            while cursor < queue.count {
                let row = queue[cursor]; cursor += 1
                for child in children[canonical(row.id)] ?? [] { remaining[child] = 0; queue.append(byID[child]!) }
            }
            guard queue.count == rows.count else { throw BackupFailure(message: "Recurring task relationships contain a cycle.") }
            return queue
        }
        for table in Self.workTables {
            for original in try orderedRows(table) {
                if table == FocusSessionChange.table {
                    let existing = currentRows[table]?[FocusSessionChange.recordID]
                    if existing != nil && policy == .keepCurrent { result.kept += 1; continue }
                    var session = try original["state"] == .null ? nil : FocusSession(document: original["state"])
                    if var value = session {
                        value = try value.checkpoint(at: TaskPlanning.instant(createdAt) ?? Date(timeIntervalSince1970: Double(value.changedAt) / 1000))
                        value.taskID = try mapped("tasks", value.taskID, required: true)
                        value.id = Self.stableID(id + "|" + account + "|focus-session", value.id)
                        session = value
                    }
                    if session == nil && existing == nil { result.kept += 1; continue }
                    if existing?["state"] == session?.document { result.kept += 1; continue }
                    guard let revision = FocusSession.integer(existing?["revision"] ?? .number(0), in: 0...FocusSessionChange.maximumRevision) else {
                        throw BackupFailure(message: "Refresh Focus before restoring its session. The current revision could not be read.")
                    }
                    let baseKey = String(revision) + "|" + (existing?.string("action_id") ?? "")
                    let action = UUID(uuidString: Self.stableID(id + "|" + account + "|focus-action", baseKey))!
                    result.changes.append(try FocusSessionChange.make(session, current: existing, account: account, action: action))
                    if existing == nil { result.added += 1 } else { result.updated += 1 }
                    result.counts[table, default: 0] += 1
                    continue
                }
                var row = original
                row["user_id"] = .string(account)
                for (key, value) in defaults[table] ?? [:] where row[key] == .null { row[key] = value }
                if Self.columns[table]?.contains("created_at") == true && row["created_at"] == .null { row["created_at"] = .string(createdAt) }
                if let id = result.mappedIDs[table]?[original.id] { row["id"] = .string(id) }
                else { row["id"] = .string(try scope(original.id)) }
                if ["favorites", "view_preferences"].contains(table), row.id.unicodeScalars.count > 200 { throw BackupFailure(message: "A restored view key exceeds 200 characters.") }
                if ["projects","labels"].contains(table), row.string("color").isEmpty { row["color"] = .string("#e31e4b") }
                if ["sections","tasks"].contains(table) && !original.string("project_id").isEmpty { row["project_id"] = .string(try mapped("projects", original.string("project_id"), required: true)) }
                if table == "sections", row.string("project_id").isEmpty { throw BackupFailure(message: "A section has no project.") }
                if table == "tasks" {
                    row["completion_version"] = .number(0)
                    if !original.string("section_id").isEmpty {
                        let section = try mapped("sections", original.string("section_id"), required: true)
                        let parent = tables["sections"]?.first { $0.id == original.string("section_id") }?.string("project_id") ?? currentRows["sections"]?[section]?.string("project_id")
                        if let parent, canonical(parent) != canonical(original.string("project_id")) { throw BackupFailure(message: "A task section belongs to a different project.") }
                        row["section_id"] = .string(section)
                    }
                    for key in ["due_date","due_time","deadline_date","recurrence_end_date","time_zone","scheduled_at"] where row.string(key).isEmpty { row[key] = .null }
                    let normalized = TaskLabels.normalized(original["labels"].list, labels: tables["labels"] ?? [])
                    row["labels"] = .array(normalized.map { value in (result.mappedIDs["labels"]?[value.text] ?? result.mappedIDs["labels"]?[canonical(value.text)]).map(JSON.string) ?? value })
                    row["assigned_to"] = person(original["assigned_to"], project: row.string("project_id"))
                    childIDs = []
                    row["subtasks"] = .array(try children(original["subtasks"].list, root: original.id, project: row.string("project_id"), reuseIDs: row.id == original.id))
                    if !original.string("recurrence_parent_id").isEmpty { row["recurrence_parent_id"] = (result.mappedIDs["tasks"]?[original.string("recurrence_parent_id")] ?? result.mappedIDs["tasks"]?[canonical(original.string("recurrence_parent_id"))]).map(JSON.string) ?? .null }
                    for (key, fallback) in [("completed",JSON.bool(false)),("priority",.number(4)),("is_recurring",.bool(false)),("reminder_specs",.array([])),("source_metadata",.object([:]))] where row.fields[key] == nil || row[key] == .null { row[key] = fallback }
                    // The new task needs its own notification scheduling; provider import mappings are not replayed.
                    row["notification_sent_at"] = .null
                }
                if table == "saved_views" { row["query_ast"] = try remapRule(FilterRule(document: row["query_ast"])).document }
                if table == "view_orders" { row["ids"] = .array(try original["ids"].list.map { .string(try mapped("tasks", $0.text)) }) }
                row.fields.removeValue(forKey: "updated_at")
                let existing = currentRows[table]?[canonical(row.id)]
                if let existing {
                    guard existing.string("user_id") == account else { throw BackupFailure(message: "A restore target belongs to another account. Your workspace was not changed.") }
                    if policy == .keepCurrent { result.kept += 1; continue }
                    let fields = row.fields.filter { !["id","user_id","created_at","completion_version","task_generation"].contains($0.key) && existing.fields[$0.key] != $0.value }
                    if fields.isEmpty { result.kept += 1; continue }
                    result.changes.append(Mutation(table: table, recordID: row.id, method: "PATCH", fields: fields, baseline: Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, existing[$0]) })))
                    // The ordinary project-move mutation clears assignments first. Restore
                    // only explicitly validated destinations after that move has completed.
                    if fields["project_id"] != nil && fields["project_id"] != existing["project_id"] {
                        var assignments: [String: JSON] = [:]
                        if (fields["assigned_to"] == nil || row.string("project_id").isEmpty) && !row.string("assigned_to").isEmpty { assignments["assigned_to"] = row["assigned_to"] }
                        func hasAssignment(_ values: [JSON]) -> Bool {
                            values.contains { value in let child = Record(value.object); return !child.string("assigned_to").isEmpty || hasAssignment(child["subtasks"].list) }
                        }
                        if hasAssignment(row["subtasks"].list) { assignments["subtasks"] = row["subtasks"] }
                        if !assignments.isEmpty { result.changes.append(Mutation(table: table, recordID: row.id, method: "PATCH", fields: assignments, baseline: Dictionary(uniqueKeysWithValues: assignments.keys.map { ($0, $0 == "assigned_to" ? JSON.null : TaskAssignment.clearChildren(row["subtasks"])) }))) }
                    }
                    result.updated += 1
                } else {
                    if table == "tasks" { row["task_generation"] = .string(UUID().uuidString.lowercased()) }
                    result.changes.append(Mutation(table: table, recordID: row.id, method: "POST", fields: row.fields, insertOnly: true)); result.added += 1
                }
                result.counts[table, default: 0] += 1
            }
        }
        if legacy { result.warnings.append("This is an older unversioned export. Its records and references were validated before preview.") }
        if unsyncedChanges > 0 { result.warnings.append("The backup includes \(unsyncedChanges) changes that had not synced. Their visible work is included; the old network queue is not replayed.") }
        if clearedAssignments > 0 { result.warnings.append("\(clearedAssignments) assignments will be cleared because those people are not current members of the restored projects.") }
        if missingFilterTargets > 0 { result.warnings.append("Some saved filter targets are unavailable. Those filters will request repair rather than match unrelated work.") }
        if tables[TaskActivity.table]?.isEmpty == false { result.warnings.append("Recorded activity is retained in this file as an archive. It is not replayed as new history; restored task copies start their own activity.") }
        if tables.keys.contains(where: { $0 == "project_collaborators" || $0.hasPrefix("project_members:") }) { result.warnings.append("Collaborators and invitations are not recreated. Restored project copies belong to you.") }
        result.warnings.append("Existing work outside this backup is kept. Sign-in, profile identity and device calendar permissions are not changed.")
        return result
    }
}

struct RecoveryEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var kind: String
    var records: Int
}
struct RecoveryPayload: Codable, Sendable { var workspace: WorkspaceBackup; var snapshot: Snapshot }

/// Ciphertext and bounded metadata live in the app sandbox. A per-account device key stays in Keychain.
struct BackupVault: Sendable {
    var directory: URL
    var account: String
    var key: @Sendable () throws -> SymmetricKey
    var retention = 20
    private static let lock = NSRecursiveLock()
    func entries() throws -> [RecoveryEntry] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = directory.appendingPathComponent("index.json")
        if !FileManager.default.fileExists(atPath: url.path) { return [] }
        return try JSONDecoder().decode([RecoveryEntry].self, from: Data(contentsOf: url)).sorted { $0.createdAt > $1.createdAt }
    }
    func save(_ snapshot: Snapshot, kind: String, now: Date = Date()) throws -> RecoveryEntry {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let backup = WorkspaceBackup.make(snapshot, account: account, now: now)
        let plaintext = try JSONEncoder().encode(RecoveryPayload(workspace: backup, snapshot: snapshot))
        guard plaintext.count <= WorkspaceBackup.maximumBytes else { throw BackupFailure(message: "This recovery backup exceeds the 256 MB limit.") }
        let sealed = try AES.GCM.seal(plaintext, using: key())
        guard let data = sealed.combined else { throw BackupFailure(message: "Could not encrypt the recovery backup.") }
        let entry = RecoveryEntry(id: UUID(), createdAt: now, kind: kind, records: WorkspaceBackup.workTables.reduce(0) { $0 + (snapshot.tables[$1]?.count ?? 0) })
        var list = try entries(); list.insert(entry, at: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(entry), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let kept = Array(list.prefix(max(1, retention)))
        do { try JSONEncoder().encode(kept).write(to: directory.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { try? FileManager.default.removeItem(at: file(entry)); throw error }
        for old in list.dropFirst(kept.count) { try? FileManager.default.removeItem(at: file(old)) }
        return entry
    }
    func load(_ entry: RecoveryEntry) throws -> RecoveryPayload {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let data = try Data(contentsOf: file(entry))
        guard data.count <= WorkspaceBackup.maximumBytes + 1024 else { throw BackupFailure(message: "The recovery file is too large.") }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key())
            let payload = try JSONDecoder().decode(RecoveryPayload.self, from: plain)
            guard payload.workspace.sourceAccount == account else { throw BackupFailure(message: "This recovery file belongs to another workspace.") }
            try payload.workspace.validate(); return payload
        } catch let error as BackupFailure { throw error }
        catch { throw BackupFailure(message: "This recovery backup is damaged or its device key is unavailable.") }
    }
    func file(_ entry: RecoveryEntry) -> URL { directory.appendingPathComponent(entry.id.uuidString.lowercased() + ".taskfoldbackup") }
    static func deviceKey(account: String) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.taskfold.recovery.v1", kSecAttrAccount as String: account]
        var read = query; read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw BackupFailure(message: "The backup key is unavailable. Unlock this device and try again.") }
        let key = SymmetricKey(size: .bits256)
        var add = query; add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(add as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try deviceKey(account: account) }
        guard saved == errSecSuccess else { throw BackupFailure(message: "Could not securely save the backup key.") }; return key
    }
}
