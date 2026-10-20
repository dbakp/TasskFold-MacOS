import Foundation

/// Checklist operations retain every field and move whole branches by identity.
enum SubtaskTree {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let maximumDepth = 10
    static let readableDepth = 32
    static func referencePath(_ id: String) -> [String]? {
        guard id.hasPrefix("subtask:"), let data = Data(base64Encoded: String(id.dropFirst(8))),
              let path = try? JSONDecoder().decode([String].self, from: data), (2...readableDepth + 1).contains(path.count), path.allSatisfy({ !$0.isEmpty }) else { return nil }
        return path
    }
    static func reference(parent: String, key: String) -> String {
        let path = (referencePath(parent) ?? [parent]) + [key]
        return "subtask:" + (try! JSONEncoder().encode(path)).base64EncodedString()
    }
    static let childQuickEntryExclusions: Set<String> = ["project_id", "section_id", "labels", "recurrence", "reminder_specs"]
    /// Context is visible in the editor but ownership and containment remain on the parent.
    static func detailDraft(_ child: Record, project: String) -> Record {
        var result = child; result["project_id"] = project.isEmpty ? .null : .string(project)
        return result
    }
    static func detailChanges(original: Record, edited: Record, current: Record) throws -> Record {
        guard !original.id.isEmpty, original.id == edited.id, current.id == original.id else {
            throw Failure(message: "This subtask changed. Reopen its current details before saving.")
        }
        let editable: Set<String> = ["title", "description", "completed", "completed_at", "priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes", "assigned_to", "labels", "subtasks", "comments", "attachments"]
        var fields = edited.fields.filter { editable.contains($0.key) && original.fields[$0.key] != $0.value }
        if let title = fields["title"] {
            let value = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw Failure(message: "Give the subtask a name.") }
            fields["title"] = .string(value)
        }
        for key in ["due_date", "deadline_date"] {
            if let value = fields[key], value != .null, !value.text.isEmpty {
                guard case .string = value, Dates.parse(value.text) != nil else { throw Failure(message: "Choose a valid date for the subtask.") }
            }
        }
        if let estimate = fields["duration_minutes"], estimate != .null {
            guard case .number(let minutes) = estimate, minutes.rounded() == minutes, (1...10080).contains(minutes) else { throw Failure(message: "Choose an estimate between 1 minute and 7 days.") }
        }
        if let priority = fields["priority"], priority != .null {
            guard case .number(let value) = priority, value.rounded() == value, (1...4).contains(value) else { throw Failure(message: "Choose a priority between 1 and 4.") }
        }
        if let time = fields["due_time"], time != .null, !time.text.isEmpty {
            let parts = time.text.split(separator: ":", omittingEmptySubsequences: false)
            guard case .string = time, parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { throw Failure(message: "Choose a valid time for the subtask.") }
        }
        if let zone = fields["time_zone"], zone != .null, !zone.text.isEmpty {
            guard case .string = zone, TimeZone(identifier: zone.text) != nil else { throw Failure(message: "Choose a valid time zone for the subtask.") }
        }
        fields = TaskPlanning.fields(fields, existing: current)
        var result = current
        for (key, value) in fields { result[key] = value }
        return result
    }
    static func path(_ value: JSON, id: String) -> [String]? {
        let rows = Dictionary(uniqueKeysWithValues: outline(value).map { ($0.id, $0) })
        guard var item = rows[id] else { return nil }
        var result = [item.id], seen: Set<String> = [item.id]
        while let parent = item.parent {
            guard seen.insert(parent).inserted, let row = rows[parent] else { return nil }
            result.insert(parent, at: 0); item = row
        }
        return result
    }
    struct Item: Identifiable {
        let record: Record
        let parent: String?
        let depth: Int
        var id: String { record.id }
    }
    enum Move { case up, down, indent, outdent }

    static func prepared(_ value: JSON) throws -> JSON {
        guard value == .null || { if case .array = value { return true }; return false }() else {
            throw Failure(message: "This checklist uses an unsupported format. Your saved subtasks are unchanged.")
        }
        var seen = Set<String>()
        func normalize(_ values: [JSON], depth: Int) throws -> [JSON] {
            guard depth <= 32 else { throw Failure(message: "This checklist is too deeply nested to organize here.") }
            return try values.map { value in
                guard case .object(var fields) = value, case .string? = fields["title"] else {
                    throw Failure(message: "A subtask uses an unsupported format. Your saved subtasks are unchanged.")
                }
                if let identity = fields["id"], identity != .null {
                    guard case .string = identity else { throw Failure(message: "A subtask identity is malformed. Your saved subtasks are unchanged.") }
                }
                let id = fields["id"]?.text ?? ""
                guard id.isEmpty || seen.insert(id).inserted else { throw Failure(message: "This checklist contains duplicate subtask identities. Your saved subtasks are unchanged.") }
                if id.isEmpty { let fresh = UUID().uuidString.lowercased(); fields["id"] = .string(fresh); seen.insert(fresh) }
                if let children = fields["subtasks"], children != .null {
                    guard case .array(let rows) = children else { throw Failure(message: "A nested checklist uses an unsupported format.") }
                    fields["subtasks"] = .array(try normalize(rows, depth: depth + 1))
                }
                return .object(fields)
            }
        }
        return .array(try normalize(value.list, depth: 0))
    }

    static func outline(_ value: JSON) -> [Item] {
        var result: [Item] = []
        func visit(_ rows: [JSON], parent: String?, depth: Int) {
            guard depth <= 32 else { return }
            for value in rows {
                let row = Record(value.object)
                result.append(Item(record: row, parent: parent, depth: depth))
                visit(row["subtasks"].list, parent: row.id, depth: depth + 1)
            }
        }
        visit(value.list, parent: nil, depth: 0)
        return result
    }
    static func progress(_ value: JSON) -> (completed: Int, total: Int) {
        let items = outline(value)
        return (items.filter { $0.record.completed }.count, items.count)
    }
    static func changing(_ value: JSON, id: String, fields: [String: JSON]) -> JSON {
        .array(value.list.map { value in
            var row = value.object
            if row["id"]?.text == id { row.merge(fields) { _, new in new } }
            else if case .array? = row["subtasks"] { row["subtasks"] = changing(row["subtasks"]!, id: id, fields: fields) }
            return .object(row)
        })
    }
    private static func siblings(_ value: JSON, parent: String?) -> [JSON] {
        guard let parent else { return value.list }
        return outline(value).first { $0.id == parent }?.record["subtasks"].list ?? []
    }
    private static func replacing(_ value: JSON, parent: String?, rows: [JSON]) -> JSON {
        guard let parent else { return .array(rows) }
        return changing(value, id: parent, fields: ["subtasks": .array(rows)])
    }
    static func removing(_ value: JSON, id: String) -> JSON {
        guard let item = outline(value).first(where: { $0.id == id }) else { return value }
        return replacing(value, parent: item.parent, rows: siblings(value, parent: item.parent).filter { $0.object["id"]?.text != id })
    }
    static func adding(_ value: JSON, title: String, parent: String? = nil, baseDepth: Int = 0) throws -> JSON {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure(message: "Give the subtask a name.") }
        guard baseDepth >= 0, baseDepth < maximumDepth else { throw Failure(message: "Subtasks can be nested up to 10 levels.") }
        if let parent {
            guard let item = outline(value).first(where: { $0.id == parent }), item.depth + baseDepth + 1 < maximumDepth else {
                throw Failure(message: "Subtasks can be nested up to 10 levels.")
            }
        }
        let row: JSON = .object(["id": .string(UUID().uuidString.lowercased()), "title": .string(title), "completed": .bool(false)])
        return replacing(value, parent: parent, rows: siblings(value, parent: parent) + [row])
    }
    static func moving(_ value: JSON, id: String, direction: Move, baseDepth: Int = 0) throws -> JSON {
        let items = outline(value)
        guard let item = items.first(where: { $0.id == id }) else { throw Failure(message: "This subtask is no longer available.") }
        var rows = siblings(value, parent: item.parent)
        guard let index = rows.firstIndex(where: { $0.object["id"]?.text == id }) else { return value }
        switch direction {
        case .up, .down:
            let target = index + (direction == .up ? -1 : 1)
            guard rows.indices.contains(target) else { throw Failure(message: "The subtask is already at the edge of this checklist.") }
            rows.swapAt(index, target)
            return replacing(value, parent: item.parent, rows: rows)
        case .indent:
            guard index > 0 else { throw Failure(message: "Move this subtask below another subtask before indenting it.") }
            let height = (outline(item.record["subtasks"]).map(\.depth).max().map { $0 + 1 }) ?? 0
            guard baseDepth + item.depth + height + 1 < maximumDepth else { throw Failure(message: "Subtasks can be nested up to 10 levels.") }
            var previous = rows[index - 1].object
            previous["subtasks"] = .array((previous["subtasks"]?.list ?? []) + [rows[index]])
            rows[index - 1] = .object(previous); rows.remove(at: index)
            return replacing(value, parent: item.parent, rows: rows)
        case .outdent:
            guard let parentID = item.parent, let parent = items.first(where: { $0.id == parentID }) else {
                throw Failure(message: "This subtask is already at the top level.")
            }
            let branch = rows.remove(at: index)
            var result = replacing(value, parent: parentID, rows: rows)
            var uncles = siblings(result, parent: parent.parent)
            guard let parentIndex = uncles.firstIndex(where: { $0.object["id"]?.text == parentID }) else { return value }
            uncles.insert(branch, at: parentIndex + 1)
            result = replacing(result, parent: parent.parent, rows: uncles)
            return result
        }
    }

    /// Rebase fields by identity even when a child has moved to another parent.
    /// An explicitly reviewed local layout wins; remote-only children are retained.
    static func rebased(base: JSON, desired: JSON, remote: JSON) -> JSON? {
        let values = [base, desired, remote].map { $0 == .null ? JSON.array([]) : $0 }
        guard values.allSatisfy({ (try? prepared($0)) == $0 }) else { return nil }
        let lists = values.map(outline)
        let maps = lists.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) }) }
        let before = maps[0], after = maps[1], current = maps[2]
        func layout(_ rows: [Item]) -> [String] { rows.map { ($0.parent ?? "") + ":" + $0.id } }
        let shared = Set(before.keys).intersection(after.keys)
        let localLayoutChanged = layout(lists[0].filter { shared.contains($0.id) }) != layout(lists[1].filter { shared.contains($0.id) })
        let deleted = Set(before.keys).subtracting(after.keys)
        var ids = Set(current.keys).subtracting(deleted)
        for row in lists[1] where before[row.id] == nil || before[row.id]?.record != row.record || before[row.id]?.parent != row.parent {
            ids.insert(row.id)
            var parent = row.parent
            while let id = parent, let ancestor = after[id] { ids.insert(id); parent = ancestor.parent }
        }
        // Follow one valid source tree for each parent chain, so competing moves
        // cannot create a cycle or duplicate the same child under two parents.
        let preferred = localLayoutChanged ? after : current
        let fallback = localLayoutChanged ? current : after
        func parent(_ id: String) -> String? {
            var next = preferred[id]?.parent ?? (preferred[id] == nil ? fallback[id]?.parent : nil)
            var seen: Set<String> = [id]
            while let candidate = next {
                guard seen.insert(candidate).inserted else { return nil }
                if ids.contains(candidate) { return candidate }
                next = preferred[candidate]?.parent ?? (preferred[candidate] == nil ? fallback[candidate]?.parent : nil)
            }
            return nil
        }
        var parents = Dictionary(uniqueKeysWithValues: ids.map { ($0, parent($0) ?? "") })
        // A remote-only node may attach beneath a locally moved known node.
        // If that combination closes a cycle, retain the node at the top level.
        for id in ids.sorted() {
            var cursor = id, seen = Set<String>()
            while !cursor.isEmpty {
                if !seen.insert(cursor).inserted { parents[id] = ""; break }
                cursor = parents[cursor] ?? ""
            }
        }
        let ordering = localLayoutChanged ? lists[1] + lists[2] : lists[2] + lists[1]
        var order: [String] = [], seen = Set<String>()
        for item in ordering where ids.contains(item.id) && seen.insert(item.id).inserted { order.append(item.id) }
        func render(_ parent: String, depth: Int) -> [JSON] {
            guard depth <= 64 else { return [] }
            return order.filter { parents[$0] == parent }.map { id in
                let old = before[id]?.record, local = after[id]?.record, saved = current[id]?.record
                func fields(_ row: Record?) -> JSON { .object((row?.fields ?? [:]).filter { $0.key != "subtasks" }) }
                let merged: JSON
                if let local, let old, saved != nil { merged = TaskEdit.keepingLocal(base: fields(old), desired: fields(local), remote: fields(saved)) }
                else { merged = fields(saved ?? local) }
                var result = merged.object
                let children = render(id, depth: depth + 1)
                let source = (localLayoutChanged ? local ?? saved : saved ?? local)?["subtasks"] ?? .null
                if !children.isEmpty || source != .null { result["subtasks"] = .array(children) }
                else if (saved ?? local)?.fields["subtasks"] != nil { result["subtasks"] = .null }
                return .object(result)
            }
        }
        return .array(render("", depth: 0))
    }
}
