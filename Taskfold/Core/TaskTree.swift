import Foundation

/// Child tasks are ordinary `tasks` rows that point at their parent with `parent_id` and sit in
/// a sibling order given by `child_order`. This file is pure: it reads and produces `Record`s and
/// `Mutation`s and never touches the store, the network or the clock (callers pass `now`).
///
/// Vocabulary: a task's depth is its number of ancestors (a root has depth 0). The server guard
/// and `validate` allow at most `maximumAncestors` ancestors, counting the whole moved subtree.
struct TaskTree: Sendable {
    /// Info.plist `TaskfoldChildRowsEnabled`. Absent means off, and then nothing here changes existing behaviour.
    static var rowsEnabled: Bool {
        #if DEBUG
        // UI tests: the fixture forces rows on; `--child-rows-off` pins the legacy JSON subtasks for tests of that UI.
        if ProcessInfo.processInfo.arguments.contains("--child-rows-fixture") { return true }
        if ProcessInfo.processInfo.arguments.contains("--child-rows-off") { return false }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "TaskfoldChildRowsEnabled") as? Bool == true
    }
    static let maximumAncestors = 10
    /// A gap between two neighbouring `child_order` values below this triggers a renumbering.
    static let renumberGap = 1e-6

    struct Failure: LocalizedError, Equatable, Sendable {
        enum Code: String, Sendable { case missingParent, selfParent, cycle, tooDeep, differentContainer, childrenRemain, noPreviousSibling, notNested, unknownTask }
        let code: Code
        let taskID: String
        let message: String
        var errorDescription: String? { message }
        /// The Postgres error the server raises for the same violation, for queue conflict mapping.
        var serverCode: String? { code == .missingParent ? "23503" : nil }
    }

    /// One planned change of fields on one existing task.
    struct Edit: Equatable, Sendable {
        var id: String
        var fields: [String: JSON]
    }

    enum Position: Equatable, Sendable {
        case first, last
        case after(String)
        case before(String)
    }

    // MARK: Index

    private let byID: [String: Record]
    private let order: [String]
    private let parents: [String: String]
    private let kids: [String: [String]]

    static func key(_ id: String) -> String { id.lowercased() }
    static func parentKey(of record: Record) -> String? {
        let value = record.string("parent_id")
        return value.isEmpty ? nil : key(value)
    }
    static func childOrder(of record: Record) -> Double? {
        if case .number(let value) = record["child_order"], value.isFinite { return value }
        return nil
    }

    /// Sibling order: `child_order, created_at, id` (a missing order sorts last).
    private static func precedes(_ a: Record, _ b: Record) -> Bool {
        let x = childOrder(of: a) ?? .infinity, y = childOrder(of: b) ?? .infinity
        if x != y { return x < y }
        let c = a.string("created_at"), d = b.string("created_at")
        if c != d { return c < d }
        return key(a.id) < key(b.id)
    }

    init(_ tasks: [Record]) {
        var records: [String: Record] = [:], ids: [String] = []
        for row in tasks where !row.id.isEmpty {
            let k = Self.key(row.id)
            if records[k] == nil { records[k] = row; ids.append(k) }
        }
        var parents: [String: String] = [:], grouped: [String: [Record]] = [:]
        for k in ids {
            let row = records[k]!
            guard let p = Self.parentKey(of: row), p != k, records[p] != nil else { continue }
            parents[k] = p
            grouped[p, default: []].append(row)
        }
        byID = records; order = ids; self.parents = parents
        kids = grouped.mapValues { $0.sorted(by: Self.precedes).map { Self.key($0.id) } }
    }

    var hasChildren: Bool { !parents.isEmpty }
    func task(_ id: String) -> Record? { byID[Self.key(id)] }

    /// A task is a root when it has no parent, or its parent is not in the data (an orphan is shown as a root).
    var roots: [Record] { order.filter { parents[$0] == nil }.compactMap { byID[$0] } }

    func children(of id: String) -> [Record] { (kids[Self.key(id)] ?? []).compactMap { byID[$0] } }
    func childIDs(of id: String) -> [String] { (kids[Self.key(id)] ?? []).compactMap { byID[$0]?.id } }
    func parentID(of id: String) -> String? { parents[Self.key(id)].flatMap { byID[$0]?.id } }
    func parent(of id: String) -> Record? { parents[Self.key(id)].flatMap { byID[$0] } }
    func hasChildren(_ id: String) -> Bool { !(kids[Self.key(id)] ?? []).isEmpty }

    /// Ancestors nearest first. Stops at a cycle.
    func ancestors(of id: String) -> [Record] {
        var result: [Record] = [], seen: Set<String> = [Self.key(id)], cursor = Self.key(id)
        while let p = parents[cursor], seen.insert(p).inserted, let row = byID[p] { result.append(row); cursor = p }
        return result
    }
    /// Root first, excluding the task itself.
    func breadcrumb(of id: String) -> [Record] { ancestors(of: id).reversed() }
    func depth(of id: String) -> Int { ancestors(of: id).count }

    /// Pre-order (parents before children), siblings in order.
    func descendants(of id: String) -> [Record] {
        var result: [Record] = [], seen: Set<String> = [Self.key(id)]
        func visit(_ k: String) {
            for child in kids[k] ?? [] where seen.insert(child).inserted {
                if let row = byID[child] { result.append(row) }
                visit(child)
            }
        }
        visit(Self.key(id))
        return result
    }
    /// Levels below the task (0 for a leaf).
    func height(of id: String) -> Int {
        var seen: Set<String> = [Self.key(id)]
        func level(_ k: String) -> Int {
            var best = 0
            for child in kids[k] ?? [] where seen.insert(child).inserted { best = max(best, 1 + level(child)) }
            return best
        }
        return level(Self.key(id))
    }

    /// Every descendant that can be completed, counting open and finished ones. Headings are context, not work.
    func childProgress(of id: String) -> (completed: Int, total: Int) {
        let work = descendants(of: id).filter(TaskKind.mayComplete)
        return (work.filter(\.completed).count, work.count)
    }
    func directChildProgress(of id: String) -> (completed: Int, total: Int) {
        let work = children(of: id).filter(TaskKind.mayComplete)
        return (work.filter(\.completed).count, work.count)
    }

    // MARK: Applying mutations (shared by validation, completion and undo)

    static func apply(_ changes: [Mutation], to tasks: [Record]) -> [Record] {
        var rows = tasks, index: [String: Int] = [:], removed = Set<Int>()
        for (i, row) in rows.enumerated() where index[key(row.id)] == nil { index[key(row.id)] = i }
        for change in changes where change.table == "tasks" {
            let k = key(change.recordID)
            switch change.method {
            case "POST":
                if let i = index[k] { if change.insertOnly != true { rows[i].mergeFields(change.fields) } }
                else {
                    var row = Record(change.fields)
                    if row.id.isEmpty { row["id"] = .string(change.recordID) }
                    rows.append(row); index[k] = rows.count - 1
                }
            case "PATCH": if let i = index[k] { rows[i].mergeFields(change.fields) }
            case "DELETE": if let i = index[k] { removed.insert(i); index[k] = nil }
            default: break
            }
        }
        return removed.isEmpty ? rows : rows.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }

    static func mutations(_ edits: [Edit], tasks: [Record]) -> [Mutation] {
        let rows = Dictionary(tasks.map { (key($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        return edits.map { edit in
            Mutation(table: "tasks", recordID: edit.id, method: "PATCH", fields: edit.fields,
                     baseline: rows[key(edit.id)].map { TaskCompletionRevision.editBaseline(for: edit.fields, from: $0) })
        }
    }

    // MARK: Validation

    private static let structural: Set<String> = ["parent_id", "child_order", "project_id", "section_id", "user_id"]

    /// Mirrors the server guard so local mode and the offline queue stay safe: the parent exists, no cycle, at most
    /// ten ancestors counting the moved subtree's height, and the same project and section (or the same
    /// `user_id` when there is no project). Throws the first violation; changes that cannot affect structure pass quickly.
    static func validate(_ changes: [Mutation], tasks: [Record]) throws {
        let relevant = changes.filter { $0.table == "tasks" && ($0.method != "PATCH" || !structural.isDisjoint(with: $0.fields.keys)) }
        guard !relevant.isEmpty else { return }
        let introduces = relevant.contains { $0.method != "DELETE" && !($0.fields["parent_id"]?.text ?? "").isEmpty }
        guard introduces || tasks.contains(where: { !$0.string("parent_id").isEmpty }) else { return }
        // A parent's project/section move carries its subtree (the server cascades), so judge the result after that.
        let after = apply(changes + mutations(cascadeLocal(changes, tasks: tasks), tasks: tasks), to: tasks)
        let tree = TaskTree(after)
        let present = Set(after.map { key($0.id) })
        let before = TaskTree(tasks)
        for change in relevant {
            if change.method == "DELETE" {
                if before.children(of: change.recordID).contains(where: { present.contains(key($0.id)) }) {
                    throw Failure(code: .childrenRemain, taskID: change.recordID, message: "Delete this task's subtasks together with it.")
                }
                continue
            }
            guard let row = tree.task(change.recordID) else { continue }
            let id = row.id
            if let p = parentKey(of: row) {
                if p == key(id) { throw Failure(code: .selfParent, taskID: id, message: "A task cannot be its own parent.") }
                guard let parent = tree.byID[p] else { throw Failure(code: .missingParent, taskID: id, message: "The parent task no longer exists.") }
                var seen: Set<String> = [key(id)], cursor = p
                while true {
                    if !seen.insert(cursor).inserted { throw Failure(code: .cycle, taskID: id, message: "A task cannot be moved inside its own subtasks.") }
                    guard let next = tree.byID[cursor].flatMap(parentKey(of:)), tree.byID[next] != nil else { break }
                    cursor = next
                }
                if !sameContainer(row, parent) {
                    throw Failure(code: .differentContainer, taskID: id, message: "A subtask must stay in its parent's project and section.")
                }
                if tree.depth(of: id) + tree.height(of: id) > maximumAncestors {
                    throw Failure(code: .tooDeep, taskID: id, message: "Subtasks can be nested at most \(maximumAncestors) levels deep.")
                }
            }
            for child in tree.children(of: id) where !sameContainer(child, row) {
                throw Failure(code: .differentContainer, taskID: child.id, message: "Subtasks must move together with their parent.")
            }
        }
    }

    private static func sameContainer(_ child: Record, _ parent: Record) -> Bool {
        let project = child.string("project_id")
        guard project == parent.string("project_id") else { return false }
        if project.isEmpty { return key(child.string("user_id")) == key(parent.string("user_id")) }
        return child.string("section_id") == parent.string("section_id")
    }

    // MARK: Fractional ordering

    static func midpoint(_ lower: Double?, _ upper: Double?) -> Double {
        switch (lower, upper) {
        case (nil, nil): return 1
        case (let l?, nil): return l + 1
        case (nil, let u?): return u - 1
        case (let l?, let u?): return (l + u) / 2
        }
    }
    /// The order that appends after the current last child.
    func nextOrder(under parent: String) -> Double {
        let values = children(of: parent).compactMap(Self.childOrder(of:))
        return (values.max() ?? 0) + 1
    }

    /// Plans where `id` lands among the children of `parent` (nil makes it a root). A root has no `child_order`.
    /// When the neighbours are closer than `renumberGap` every sibling is renumbered 1…n.
    func placement(of id: String, under parent: String?, at position: Position = .last) -> [Edit] {
        guard let parent else { return [Edit(id: id, fields: ["parent_id": .null, "child_order": .null])] }
        let me = Self.key(id)
        let siblings = (kids[Self.key(parent)] ?? []).filter { $0 != me }
        var effective: [Double] = []
        for (i, k) in siblings.enumerated() {
            effective.append(byID[k].flatMap(Self.childOrder(of:)) ?? (i == 0 ? 1 : effective[i - 1] + 1))
        }
        let slot: Int
        switch position {
        case .first: slot = 0
        case .last: slot = siblings.count
        case .after(let anchor): slot = (siblings.firstIndex(of: Self.key(anchor)) ?? (siblings.count - 1)) + 1
        case .before(let anchor): slot = siblings.firstIndex(of: Self.key(anchor)) ?? siblings.count
        }
        let lower = slot > 0 ? effective[slot - 1] : nil, upper = slot < siblings.count ? effective[slot] : nil
        let value = position == .last ? (effective.max() ?? 0) + 1 : Self.midpoint(lower, upper)
        let crowded = lower != nil && upper != nil && (upper! - lower!) < Self.renumberGap
        guard !crowded, value.isFinite else {
            var ordered = siblings; ordered.insert(me, at: slot)
            var edits: [Edit] = []
            for (i, k) in ordered.enumerated() {
                let number = Double(i + 1)
                if k == me { edits.append(Edit(id: id, fields: ["parent_id": .string(parent), "child_order": .number(number)])) }
                else if let row = byID[k], Self.childOrder(of: row) != number { edits.append(Edit(id: row.id, fields: ["child_order": .number(number)])) }
            }
            return edits
        }
        return [Edit(id: id, fields: ["parent_id": .string(parent), "child_order": .number(value)])]
    }

    private func checked(_ edits: [Edit]) throws -> [Edit] {
        try Self.validate(Self.mutations(edits, tasks: Array(order.compactMap { byID[$0] })), tasks: order.compactMap { byID[$0] })
        return edits
    }

    /// Re-parents or reorders one task (and with it, its whole subtree).
    func move(_ id: String, under parent: String?, at position: Position = .last) throws -> [Edit] {
        guard task(id) != nil else { throw Failure(code: .unknownTask, taskID: id, message: "This task no longer exists.") }
        return try checked(placement(of: id, under: parent, at: position))
    }

    /// Indent: the task becomes the last child of its previous sibling. A root has no stored sibling order, so the
    /// caller passes the previous root as it is displayed.
    func indent(_ id: String, previousSibling: String? = nil) throws -> [Edit] {
        guard let row = task(id) else { throw Failure(code: .unknownTask, taskID: id, message: "This task no longer exists.") }
        let target: String?
        if let p = parentID(of: id) {
            let siblings = childIDs(of: p)
            let index = siblings.firstIndex { Self.key($0) == Self.key(id) }
            target = index.flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
        } else { target = previousSibling }
        guard let target, Self.key(target) != Self.key(row.id) else {
            throw Failure(code: .noPreviousSibling, taskID: id, message: "There is no task above to nest this under.")
        }
        return try checked(placement(of: id, under: target, at: .last))
    }

    /// Outdent: the task becomes the next sibling of its old parent.
    func outdent(_ id: String) throws -> [Edit] {
        guard task(id) != nil else { throw Failure(code: .unknownTask, taskID: id, message: "This task no longer exists.") }
        guard let p = parentID(of: id) else { throw Failure(code: .notNested, taskID: id, message: "This task is not a subtask.") }
        return try checked(placement(of: id, under: parentID(of: p), at: .after(p)))
    }

    /// "Make it a task": detach from the parent and keep the subtree.
    func makeTask(_ id: String) throws -> [Edit] {
        guard task(id) != nil else { throw Failure(code: .unknownTask, taskID: id, message: "This task no longer exists.") }
        guard parentID(of: id) != nil else { throw Failure(code: .notNested, taskID: id, message: "This task is not a subtask.") }
        return [Edit(id: id, fields: ["parent_id": .null, "child_order": .null])]
    }

    // MARK: Project and section moves

    /// What the server cascade does to descendants when a parent's project or section changes, applied to the
    /// screen right away. A project change clears assignees, as the server's task guard does.
    static func cascadeLocal(_ changes: [Mutation], tasks: [Record]) -> [Edit] {
        let moves = changes.filter { $0.table == "tasks" && $0.method == "PATCH" && ($0.fields["project_id"] != nil || $0.fields["section_id"] != nil) }
        guard !moves.isEmpty, tasks.contains(where: { !$0.string("parent_id").isEmpty }) else { return [] }
        let tree = TaskTree(tasks)
        var edits: [Edit] = []
        for move in moves {
            for child in tree.descendants(of: move.recordID) {
                var fields: [String: JSON] = [:]
                for name in ["project_id", "section_id"] { if let value = move.fields[name], child[name] != value { fields[name] = value } }
                if let project = move.fields["project_id"], project != tree.task(move.recordID)?["project_id"], child["assigned_to"] != .null { fields["assigned_to"] = .null }
                if !fields.isEmpty { edits.append(Edit(id: child.id, fields: fields)) }
            }
        }
        return edits
    }

    /// Moves a task to another project/section. A subtask is detached first (a child never leaves its parent's
    /// project); descendants follow their moved ancestor.
    func moveToProject(_ id: String, project: String?, section: String?) throws -> [Edit] {
        guard let row = task(id) else { throw Failure(code: .unknownTask, taskID: id, message: "This task no longer exists.") }
        var fields: [String: JSON] = ["project_id": project.map(JSON.string) ?? .null, "section_id": section.map(JSON.string) ?? .null]
        if row.string("parent_id").isEmpty == false, parentID(of: id) != nil,
           row.string("project_id") != (project ?? "") || row.string("section_id") != (section ?? "") {
            fields["parent_id"] = .null; fields["child_order"] = .null
        }
        if row.string("project_id") != (project ?? "") && row["assigned_to"] != .null { fields["assigned_to"] = .null }
        let own = Mutation(table: "tasks", recordID: id, method: "PATCH", fields: fields)
        return [Edit(id: id, fields: fields)] + Self.cascadeLocal([own], tasks: order.compactMap { byID[$0] })
    }

    // MARK: Completion

    struct CompletionPlan: Equatable, Sendable {
        var mutations: [Mutation]
        var inverse: [Mutation]
        /// Descendants completed (or ancestors reopened) in addition to the task itself.
        var cascaded: [String]
    }

    /// Completing a parent completes its open descendants in one commit. Reopening a task also reopens its
    /// completed ancestors. A recurring parent's successor gets successor rows for its subtree. `inverse` restores
    /// every touched field and deletes created rows deepest first, so one Undo reverses the whole commit.
    static func completion(of task: Record, tasks: [Record], at now: Date = Date(), calendar: Calendar = .current, account: String? = nil) -> CompletionPlan? {
        let base = TaskCompletion.toggle(task, tasks: tasks, at: now, calendar: calendar, account: account)
        guard let head = base.first else { return nil }
        let tree = TaskTree(tasks)
        var mutations = base, cascaded: [String] = []
        let stamp = ISO8601DateFormatter().string(from: now)
        if task.completed {
            for ancestor in tree.ancestors(of: task.id) where ancestor.completed && TaskKind.mayComplete(ancestor) {
                let fields: [String: JSON] = ["completed": .bool(false), "completed_at": .null]
                mutations.append(Mutation(table: "tasks", recordID: ancestor.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: ancestor)))
                cascaded.append(ancestor.id)
            }
        } else {
            let completedAt = head.fields["completed_at"] ?? .string(stamp)
            for child in tree.descendants(of: task.id) where !child.completed && TaskKind.mayComplete(child) {
                let fields: [String: JSON] = ["completed": .bool(true), "completed_at": completedAt]
                mutations.append(Mutation(table: "tasks", recordID: child.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: child)))
                cascaded.append(child.id)
            }
            if let successor = base.first(where: { $0.method == "POST" && $0.table == "tasks" && key($0.recordID) != key(task.id) }) {
                mutations += successorRows(of: task, successor: successor, tasks: tasks, tree: tree, at: now, calendar: calendar)
            }
        }
        return CompletionPlan(mutations: mutations, inverse: inverse(of: mutations, before: tasks), cascaded: cascaded)
    }

    /// The id of a successor child: derived from the successor parent and the source child, so every device
    /// computes the same row for the same occurrence.
    static func successorChildID(successorParent: String, source: String) -> String {
        TaskCompletion.successorID(parent: key(successorParent) + "/child/" + key(source), day: "child")
    }

    /// POSTs (parents first) copying the subtree under a recurring parent's successor: open, dates shifted by the
    /// parent's own shift. Children that already exist are skipped, so a retry is idempotent.
    static func successorRows(of task: Record, successor: Mutation, tasks: [Record], tree: TaskTree? = nil, at now: Date = Date(), calendar input: Calendar = .current) -> [Mutation] {
        let tree = tree ?? TaskTree(tasks)
        let existing = Set(tasks.map { key($0.id) })
        let calendar = TaskCompletion.calendar(for: task, input: input)
        let old = Dates.parse(task.string("due_date"), calendar: calendar)
        let new = Dates.parse(successor.fields["due_date"]?.text ?? "", calendar: calendar)
        let delta = old.flatMap { o in new.flatMap { calendar.dateComponents([.day], from: o, to: $0).day } } ?? 0
        let stamp = ISO8601DateFormatter().string(from: now)
        var mapped: [String: String] = [key(task.id): successor.recordID], result: [Mutation] = []
        for child in tree.descendants(of: task.id) {
            guard let parent = Self.parentKey(of: child), let newParent = mapped[parent] else { continue }
            let id = successorChildID(successorParent: successor.recordID, source: child.id)
            mapped[key(child.id)] = id
            guard !existing.contains(key(id)) else { continue }
            var copy = child
            copy["id"] = .string(id); copy["parent_id"] = .string(newParent)
            copy["completed"] = .bool(false); copy["completed_at"] = .null; copy["completion_version"] = .number(0)
            copy["task_generation"] = .string(UUID().uuidString.lowercased())
            copy["notification_sent_at"] = .null; copy["created_at"] = .string(stamp); copy.fields.removeValue(forKey: "updated_at")
            copy["comments"] = .array([]); copy["deadline_date"] = .null
            copy["reminder_specs"] = .array(ReminderSpec.successorRows(ReminderSpec.rows(child)))
            let childCalendar = TaskCompletion.calendar(for: child, input: input)
            if let due = Dates.parse(child.string("due_date"), calendar: childCalendar), let shifted = childCalendar.date(byAdding: .day, value: delta, to: due) {
                copy["due_date"] = .string(TaskPlanner.dayKey(shifted, calendar: childCalendar)); copy["scheduled_at"] = .null
                copy.fields = TaskPlanning.fields(copy.fields, existing: nil, calendar: childCalendar)
            }
            result.append(Mutation(table: "tasks", recordID: id, method: "POST", fields: copy.fields, insertOnly: true))
        }
        return result
    }

    // MARK: Undo

    /// The exact inverse of `changes` applied to `tasks`, in the order Undo must send it: a PATCH restores the
    /// previous values of the fields it set, a created row is deleted, a deleted row is recreated. Reversed, so
    /// children are deleted before their parent is and recreated after it.
    static func inverse(of changes: [Mutation], before tasks: [Record]) -> [Mutation] {
        var current = tasks, back: [Mutation] = []
        for change in changes where change.table == "tasks" {
            let old = current.first { key($0.id) == key(change.recordID) }
            switch (change.method, old) {
            case ("PATCH", let old?):
                let fields = Dictionary(uniqueKeysWithValues: change.fields.keys.map { ($0, old[$0]) })
                let after = apply([change], to: current).first { key($0.id) == key(change.recordID) } ?? old
                back.append(Mutation(table: "tasks", recordID: change.recordID, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: after)))
            case ("POST", nil):
                back.append(Mutation(table: "tasks", recordID: change.recordID, method: "DELETE", fields: [:], baseline: change.fields))
            case ("DELETE", let old?):
                back.append(Mutation(table: "tasks", recordID: change.recordID, method: "POST", fields: old.fields, insertOnly: true))
            default: break
            }
            current = apply([change], to: current)
        }
        return back.reversed()
    }

    // MARK: Deletion

    /// Deletes for the task and all its descendants, deepest first, each with the full row as its baseline (the
    /// server compares every column). `inverse(of:before:)` of this list recreates the parent first.
    static func deletionExpansion(of id: String, tasks: [Record]) -> [Mutation] {
        let tree = TaskTree(tasks)
        guard let root = tree.task(id) else { return [] }
        let doomed = tree.descendants(of: id) + [root]
        let depths = Dictionary(uniqueKeysWithValues: doomed.map { (key($0.id), tree.depth(of: $0.id)) })
        let deepestFirst = doomed.enumerated().sorted {
            let a = depths[key($0.element.id)] ?? 0, b = depths[key($1.element.id)] ?? 0
            return a != b ? a > b : $0.offset > $1.offset
        }.map(\.element)
        return deepestFirst.map { Mutation(table: "tasks", recordID: $0.id, method: "DELETE", fields: [:], baseline: $0.fields) }
    }
    /// Undo for `deletionExpansion`: parent first, so each recreated child finds its parent.
    static func deletionUndo(of id: String, tasks: [Record]) -> [Mutation] {
        inverse(of: deletionExpansion(of: id, tasks: tasks), before: tasks)
    }
}

// MARK: - Display

/// Presentation rules for lists: nested in a project, flat (with a breadcrumb) everywhere a task is found by
/// something other than its place in a project.
enum TaskTreeDisplay {
    struct OutlineRow: Equatable, Sendable {
        let record: Record
        let depth: Int
        let hasChildren: Bool
        let isCollapsed: Bool
    }
    struct FlatRow: Equatable, Sendable {
        let record: Record
        /// Root first, excluding the task.
        let breadcrumb: [Record]
        var parentTitle: String? { breadcrumb.last.map(\.title) }
        /// "↳ Parent" for dated lists.
        var parentLine: String? { parentTitle.map { "↳ " + $0 } }
        var breadcrumbText: String { breadcrumb.map(\.title).joined(separator: " › ") }
    }
    struct Counts: Equatable, Sendable {
        var open = 0, completed = 0, headings = 0
        var total: Int { open + completed }
    }

    static func deduplicated(_ rows: [Record]) -> [Record] {
        var seen = Set<String>()
        return rows.filter { !$0.id.isEmpty && seen.insert(TaskTree.key($0.id)).inserted }
    }

    /// Project and Inbox: roots in the given order, each followed by its children, depth first. A collapsed
    /// parent hides its subtree. `rows` must hold the whole container so children are found.
    static func outline(_ rows: [Record], collapsed: Set<String> = [], includeCompleted: Bool = true) -> [OutlineRow] {
        let unique = deduplicated(rows)
        let tree = TaskTree(unique)
        let collapsed = Set(collapsed.map(TaskTree.key))
        let rootKeys = Set(tree.roots.map { TaskTree.key($0.id) })
        var result: [OutlineRow] = []
        func visit(_ row: Record, depth: Int) {
            let k = TaskTree.key(row.id), kids = tree.children(of: row.id), folded = collapsed.contains(k) && !kids.isEmpty
            if includeCompleted || !row.completed { result.append(OutlineRow(record: row, depth: depth, hasChildren: !kids.isEmpty, isCollapsed: folded)) }
            guard !folded else { return }
            for kid in kids { visit(kid, depth: depth + 1) }
        }
        for row in unique where rootKeys.contains(TaskTree.key(row.id)) { visit(row, depth: 0) }
        return result
    }

    /// Today, Upcoming, Calendar, labels, filters and search: every row once, at its own place in the list, with
    /// its breadcrumb. `datedOnly` keeps only tasks with their own due date.
    static func flat(_ rows: [Record], tree: TaskTree, datedOnly: Bool = false) -> [FlatRow] {
        deduplicated(rows).filter { !datedOnly || !$0.string("due_date").isEmpty }.map { FlatRow(record: $0, breadcrumb: tree.breadcrumb(of: $0.id)) }
    }

    /// Counts include subtasks (each is a row). Headings are context and are counted apart.
    static func counts(_ rows: [Record]) -> Counts {
        var counts = Counts()
        for row in deduplicated(rows) {
            switch TaskKind(row) {
            case .task: if row.completed { counts.completed += 1 } else { counts.open += 1 }
            case .heading, .unsupported: counts.headings += 1
            }
        }
        return counts
    }
    /// Open work beneath and including one task.
    static func openCount(under id: String, tree: TaskTree) -> Int {
        var count = tree.task(id).map { TaskKind.mayComplete($0) && !$0.completed ? 1 : 0 } ?? 0
        count += tree.descendants(of: id).filter { TaskKind.mayComplete($0) && !$0.completed }.count
        return count
    }
}
