import Foundation

struct FocusFailure: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// UTC milliseconds are the durable clock. No in-memory tick counter is persisted.
struct FocusSession: Equatable, Sendable {
    enum Status: String, Sendable { case running, paused, stopped }
    var id: String
    var taskID: String
    var durationSeconds: Int
    var elapsedMilliseconds: Int64
    var startedAt: Int64
    var changedAt: Int64
    var runningSince: Int64?
    var status: Status
    static let maximumTimestamp: Int64 = 4_133_980_800_000 // 2101-01-01 UTC
    private static let keys: Set<String> = ["session_id", "task_id", "duration_seconds", "elapsed_ms", "started_at_ms", "changed_at_ms", "running_since_ms", "status"]

    init(taskID: String, minutes: Int, now: Date = Date(), id: UUID = UUID()) throws {
        guard UUID(uuidString: taskID) != nil, (1...180).contains(minutes), let time = Self.milliseconds(now) else {
            throw FocusFailure(message: "Choose a task and a Focus duration from 1 to 180 minutes.")
        }
        self.id = id.uuidString.lowercased(); self.taskID = taskID.lowercased()
        durationSeconds = minutes * 60; elapsedMilliseconds = 0
        startedAt = time; changedAt = time; runningSince = time; status = .running
    }
    init(document: JSON) throws {
        let row = document.object
        guard case .object = document, Set(row.keys) == Self.keys,
              let session = UUID(uuidString: row["session_id"]?.text ?? ""),
              let task = UUID(uuidString: row["task_id"]?.text ?? ""),
              let duration = Self.integer(row["duration_seconds"], in: 60...10800), duration % 60 == 0,
              let elapsed = Self.integer(row["elapsed_ms"], in: 0...(duration * 1000)),
              let start = Self.integer(row["started_at_ms"], in: 0...Self.maximumTimestamp),
              let change = Self.integer(row["changed_at_ms"], in: start...Self.maximumTimestamp),
              let status = Status(rawValue: row["status"]?.text ?? "") else {
            throw FocusFailure(message: "This Focus session is invalid or uses a newer format. Refresh before changing it.")
        }
        let run = Self.integer(row["running_since_ms"], in: start...change)
        guard (status == .running && run != nil) || (status != .running && row["running_since_ms"] == .null) else {
            throw FocusFailure(message: "This Focus session has an invalid clock.")
        }
        id = session.uuidString.lowercased(); taskID = task.uuidString.lowercased(); durationSeconds = Int(duration)
        elapsedMilliseconds = elapsed; startedAt = start; changedAt = change; runningSince = run; self.status = status
    }
    var document: JSON {
        .object(["session_id": .string(id), "task_id": .string(taskID), "duration_seconds": .number(Double(durationSeconds)),
                 "elapsed_ms": .number(Double(elapsedMilliseconds)), "started_at_ms": .number(Double(startedAt)),
                 "changed_at_ms": .number(Double(changedAt)), "running_since_ms": runningSince.map { .number(Double($0)) } ?? .null,
                 "status": .string(status.rawValue)])
    }
    func elapsed(at now: Date) -> Int64 {
        let limit = Int64(durationSeconds) * 1000
        guard status == .running, let run = runningSince, let time = Self.milliseconds(now) else { return elapsedMilliseconds }
        return min(limit, elapsedMilliseconds + max(0, time - run))
    }
    func remaining(at now: Date) -> TimeInterval { Double(Int64(durationSeconds) * 1000 - elapsed(at: now)) / 1000 }
    func finished(at now: Date) -> Bool { remaining(at: now) == 0 }
    var endDate: Date? {
        guard status == .running, let run = runningSince else { return nil }
        return Date(timeIntervalSince1970: Double(run + Int64(durationSeconds) * 1000 - elapsedMilliseconds) / 1000)
    }
    func paused(at now: Date) throws -> Self {
        guard status == .running else { throw FocusFailure(message: "This session is already paused or ended.") }
        var next = self; next.elapsedMilliseconds = elapsed(at: now); next.changedAt = try commandTime(now)
        next.runningSince = nil; next.status = .paused; return next
    }
    func resumed(at now: Date) throws -> Self {
        guard status == .paused, !finished(at: now) else { throw FocusFailure(message: "Start a new session to focus again.") }
        var next = self; next.changedAt = try commandTime(now); next.runningSince = next.changedAt; next.status = .running; return next
    }
    func stopped(at now: Date) throws -> Self {
        guard status != .stopped else { throw FocusFailure(message: "This session has already ended.") }
        var next = self; next.elapsedMilliseconds = elapsed(at: now); next.changedAt = try commandTime(now)
        next.runningSince = nil; next.status = .stopped; return next
    }
    /// A portable backup is a paused checkpoint, never a timer that starts itself on restore.
    func checkpoint(at now: Date) throws -> Self { status == .running ? try paused(at: now) : self }
    private func commandTime(_ date: Date) throws -> Int64 {
        guard let time = Self.milliseconds(date) else { throw FocusFailure(message: "Check the device clock before changing this session.") }
        return max(changedAt, time)
    }
    static func milliseconds(_ date: Date) -> Int64? {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard value.isFinite, value >= 0, value <= Double(maximumTimestamp) else { return nil }
        return Int64(value)
    }
    static func integer(_ value: JSON?, in range: ClosedRange<Int64>) -> Int64? {
        guard case .number(let number)? = value, number.isFinite, number.rounded() == number,
              number >= Double(range.lowerBound), number <= Double(range.upperBound) else { return nil }
        return Int64(number)
    }
}

/// One account-owned current slot; retaining its revision after Stop prevents stale-start ABA.
enum FocusSessionChange {
    static let table = "focus_sessions"
    static let recordID = "current"
    static let maximumRevision: Int64 = 9_007_199_254_740_991
    static func emptyRow(account: String) -> Record {
        Record(["id": .string(recordID), "user_id": .string(account), "revision": .number(0), "action_id": .null, "state": .null])
    }
    static func validRow(_ row: Record, account: String) -> Bool {
        guard row.id == recordID, !account.isEmpty, row.string("user_id").lowercased() == account.lowercased(),
              let revision = FocusSession.integer(row["revision"], in: 0...maximumRevision) else { return false }
        if revision == 0 { return row["action_id"] == .null && row["state"] == .null }
        return UUID(uuidString: row.string("action_id")) != nil && (row["state"] == .null || (try? FocusSession(document: row["state"])) != nil)
    }
    static func session(in row: Record?, account: String) -> FocusSession? {
        guard let row, validRow(row, account: account) else { return nil }
        return try? FocusSession(document: row["state"])
    }
    static func baseline(_ row: Record?) -> [String: JSON] {
        ["revision": row?["revision"] ?? .number(0), "action_id": row?["action_id"] ?? .null]
    }
    static func make(_ session: FocusSession?, current: Record?, account: String, action: UUID = UUID()) throws -> Mutation {
        guard !account.isEmpty, current.map({ validRow($0, account: account) }) ?? true,
              let revision = FocusSession.integer(current?["revision"] ?? .number(0), in: 0...(maximumRevision - 1)) else {
            throw FocusFailure(message: "Refresh this workspace before changing its Focus session.")
        }
        if let session { _ = try FocusSession(document: session.document) }
        return Mutation(table: table, recordID: recordID, method: "POST", fields: [
            "id": .string(recordID), "user_id": .string(account), "revision": .number(Double(revision + 1)),
            "action_id": .string(action.uuidString.lowercased()), "state": session?.document ?? .null], baseline: baseline(current))
    }
    static func valid(_ mutation: Mutation, account: String) -> Bool {
        guard mutation.table == table, mutation.recordID == recordID, mutation.method == "POST", mutation.insertOnly != true,
              Set(mutation.fields.keys) == ["id", "user_id", "revision", "action_id", "state"],
              let base = mutation.baseline, Set(base.keys) == ["revision", "action_id"],
              let revision = FocusSession.integer(base["revision"], in: 0...(maximumRevision - 1)),
              mutation.fields["revision"] == .number(Double(revision + 1)),
              (revision == 0 ? base["action_id"] == .null : UUID(uuidString: base["action_id"]?.text ?? "") != nil),
              mutation.fields["action_id"] != base["action_id"] else { return false }
        return validRow(Record(mutation.fields), account: account)
    }
}

struct FocusSyncConflict: Identifiable {
    var mutation: Mutation
    var remote: Record
    var id: UUID { mutation.id }
    /// Timer commands form one dependent chain. Review its final state, retaining unrelated task edits.
    func resolving(_ snapshot: Snapshot, account: String, keepLocal: Bool) -> Snapshot? {
        guard FocusSessionChange.valid(mutation, account: account), FocusSessionChange.validRow(remote, account: account),
              let first = snapshot.pending.firstIndex(of: mutation) else { return nil }
        let chain = snapshot.pending.enumerated().filter { $0.offset >= first && $0.element.table == FocusSessionChange.table }
        guard !chain.isEmpty, chain.allSatisfy({ FocusSessionChange.valid($0.element, account: account) }) else { return nil }
        for (previous, next) in zip(chain, chain.dropFirst()) {
            guard next.element.baseline == FocusSessionChange.baseline(Record(previous.element.fields)) else { return nil }
        }
        var result = snapshot
        let ids = Set(chain.map { $0.element.id })
        result.pending.removeAll { ids.contains($0.id) }
        result.tables[FocusSessionChange.table] = [remote]
        if keepLocal {
            let value = chain.last!.element.fields["state"] ?? .null
            guard let change = try? FocusSessionChange.make(value == .null ? nil : FocusSession(document: value), current: remote, account: account) else { return nil }
            result.pending.insert(change, at: min(first, result.pending.count)); result.apply(change)
        }
        return result
    }
}

/// A transient directory of visible tasks, never a second persisted task model.
struct FocusTaskCatalog {
    struct Choice: Identifiable, Equatable {
        var id: String
        var generation: JSON
        var title: String
        var context: String
        var description: String
    }
    var choices: [Choice]
    init(tasks: [Record], projects: [Record], sections: [Record], search: String = "") {
        let projects = Self.directory(projects), sections = Self.directory(sections), parents = Self.directory(tasks)
        let words = QuickEntryContext.key(search).split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<String>()
        choices = tasks.compactMap { task in
            let id = task.id.lowercased()
            guard UUID(uuidString: id) != nil, !task.completed, seen.insert(id).inserted else { return nil }
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let choice = Choice(id: id, generation: task["task_generation"], title: title.isEmpty ? "Untitled task" : title,
                                context: Self.context(task, projects: projects, sections: sections, parents: parents),
                                description: task.string("description").trimmingCharacters(in: .whitespacesAndNewlines))
            let haystack = QuickEntryContext.key(choice.title + " " + choice.context + " " + choice.description)
            return words.allSatisfy { haystack.contains($0) } ? choice : nil
        }.sorted {
            let a = QuickEntryContext.key($0.title), b = QuickEntryContext.key($1.title)
            if a != b {
                let order = a.compare(b, options: .numeric, locale: Locale(identifier: "en_US_POSIX"))
                return order == .orderedSame ? a < b : order == .orderedAscending
            }
            let ac = QuickEntryContext.key($0.context), bc = QuickEntryContext.key($1.context)
            if ac != bc { return ac < bc }
            return $0.id < $1.id
        }
    }
    static func selectable(_ choice: Choice, tasks: [Record]) -> Bool {
        tasks.contains { $0.id.lowercased() == choice.id && !$0.completed && $0["task_generation"] == choice.generation }
    }
    static func context(_ task: Record, tasks: [Record], projects: [Record], sections: [Record]) -> String {
        context(task, projects: directory(projects), sections: directory(sections), parents: directory(tasks))
    }
    private static func directory(_ records: [Record]) -> [String: Record] {
        records.reduce(into: [:]) { if !$1.id.isEmpty { $0[$1.id.lowercased()] = $1 } }
    }
    private static func context(_ task: Record, projects: [String: Record], sections: [String: Record], parents: [String: Record]) -> String {
        let projectID = task.string("project_id").lowercased()
        var parts = [projectID.isEmpty ? "Inbox" : projects[projectID]?.name.nonemptyFocusName ?? "Project unavailable"]
        if !projectID.isEmpty, projects[projectID] != nil,
           let section = sections[task.string("section_id").lowercased()], section.string("project_id").lowercased() == projectID,
           let name = section.name.nonemptyFocusName { parts.append(name) }
        if let parent = parents[task.string("parent_id").lowercased()], parent.id.lowercased() != task.id.lowercased(),
           parent.string("project_id").lowercased() == projectID, let title = parent.title.nonemptyFocusName { parts.append(title) }
        return parts.joined(separator: " · ")
    }
}
private extension String {
    var nonemptyFocusName: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
}
