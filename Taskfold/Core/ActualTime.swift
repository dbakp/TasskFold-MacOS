import Foundation

/// Actual time: the minutes really spent on a task, taken from Focus and Pomodoro work intervals, set beside the
/// estimate (`duration_minutes`) so planning improves over time. Pure: no Store, no UI.
///
/// Storage (no server schema change). The synced `focus_sessions` row is one account-wide "current" slot that every
/// new session overwrites, so it holds no per-task history and cannot be summed. Time is instead recorded in the
/// existing per-account `view_orders` table, the same approach as This Evening, Someday, pins and habits:
///   - `actual:<task id>`   one row per task; `ids` holds one string per Focus session,
///                          `<session id>|<ended at, UTC ms>|<seconds focused>`
/// A session is identified by its Focus session id, so recording it again (paused, resumed, stopped, seen by a second
/// device) replaces its entry and never counts it twice; a session's seconds only ever grow. Older clients never read
/// the key. A task's actual time is the sum of its entries. When a task has more than `maxEntries` sessions the oldest
/// fold into one `earlier` entry, so the total stays right and the row stays small.
///
/// Honest by construction: nothing is inferred. Only time a Focus or Pomodoro work interval actually ran is
/// counted, breaks never are, and a session under `minimumSeconds` (an accidental start) is ignored.
enum ActualTime {
    static let table = Planning.table
    static let prefix = "actual:"
    static let maxEntries = 120
    static let rollupID = "earlier"
    static let minimumSeconds = 30
    /// How many finished tasks the estimate-versus-actual reading needs before it says anything.
    static let minimumSamples = 5
    static let windowDays = 30

    struct Entry: Equatable, Sendable {
        var sessionID: String
        /// UTC milliseconds the session last stopped counting.
        var endedAt: Int64
        var seconds: Int
        var encoded: String { "\(sessionID)|\(endedAt)|\(seconds)" }
        init(sessionID: String, endedAt: Int64, seconds: Int) { self.sessionID = sessionID; self.endedAt = endedAt; self.seconds = seconds }
        init?(_ text: String) {
            let parts = text.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty, parts[0].utf8.count <= 64,
                  let ended = Int64(parts[1]), ended >= 0, let seconds = Int(parts[2]), (1...100_000_000).contains(seconds) else { return nil }
            self.init(sessionID: String(parts[0]), endedAt: ended, seconds: seconds)
        }
    }

    static func key(_ taskID: String) -> String { prefix + taskID.lowercased() }
    static func isActualKey(_ key: String) -> Bool { key.hasPrefix(prefix) }
    static func taskID(of key: String) -> String? { isActualKey(key) ? String(key.dropFirst(prefix.count)) : nil }

    // MARK: Reading

    /// Tolerant read of one task's row. Other accounts' rows, malformed entries and duplicates are ignored.
    static func entries(_ row: Record?, account: String) -> [Entry] {
        guard let row, !account.isEmpty, isActualKey(row.id), row.string("user_id").lowercased() == account.lowercased(),
              case .array(let values) = row["ids"] else { return [] }
        var seen = Set<String>(), result: [Entry] = []
        for value in values {
            guard case .string(let text) = value, let entry = Entry(text), seen.insert(entry.sessionID).inserted else { continue }
            result.append(entry)
        }
        return result
    }
    static func seconds(_ entries: [Entry]) -> Int { entries.reduce(0) { $0 + $1.seconds } }

    /// Task id to total seconds, for every task that has recorded time.
    static func totals(rows: [Record], account: String) -> [String: Int] {
        var result: [String: Int] = [:], seen = Set<String>()
        for row in rows where isActualKey(row.id) && seen.insert(row.id).inserted {
            guard let id = taskID(of: row.id) else { continue }
            let total = seconds(entries(row, account: account))
            if total > 0 { result[id] = total }
        }
        return result
    }

    // MARK: Recording

    /// The change that records `session`'s time, or nil when there is nothing new to record. A running session is
    /// recorded only once its time has run out; paused and stopped sessions are recorded as they stand.
    static func recording(_ session: FocusSession, at now: Date, rows: [Record], account: String) throws -> Mutation? {
        guard !account.isEmpty else { return nil }
        guard session.status != .running || session.finished(at: now) else { return nil }
        let seconds = Int(session.elapsed(at: now) / 1000)
        guard seconds >= minimumSeconds else { return nil }
        let ended: Int64 = session.status == .running ? (session.endDate.flatMap(FocusSession.milliseconds) ?? session.changedAt) : session.changedAt
        let key = key(session.taskID)
        let existing = rows.first { $0.id == key }
        guard existing == nil || existing?.string("user_id").lowercased() == account.lowercased() else {
            throw AppFailure(message: "This time record belongs to another workspace.")
        }
        var list = entries(existing, account: account)
        if let index = list.firstIndex(where: { $0.sessionID == session.id }) {
            guard list[index].seconds < seconds else { return nil }
            list[index].seconds = seconds; list[index].endedAt = max(list[index].endedAt, ended)
        } else { list.append(Entry(sessionID: session.id, endedAt: ended, seconds: seconds)) }
        return Mutation(table: table, recordID: key, method: existing == nil ? "POST" : "PATCH",
                        fields: ["id": .string(key), "user_id": .string(account), "ids": .array(folded(list).map { .string($0.encoded) })])
    }

    /// Oldest entries first; beyond `maxEntries` the oldest fold into the single `earlier` entry.
    static func folded(_ list: [Entry]) -> [Entry] {
        let earlier = list.first { $0.sessionID == rollupID }
        let sessions = list.filter { $0.sessionID != rollupID }.sorted { ($0.endedAt, $0.sessionID) < ($1.endedAt, $1.sessionID) }
        guard sessions.count > maxEntries else { return (earlier.map { [$0] } ?? []) + sessions }
        let extra = sessions.count - maxEntries
        let old = Array(sessions.prefix(extra)) + (earlier.map { [$0] } ?? [])
        let rolled = Entry(sessionID: rollupID, endedAt: old.map(\.endedAt).max() ?? 0, seconds: old.reduce(0) { $0 + $1.seconds })
        return [rolled] + Array(sessions.dropFirst(extra))
    }

    // MARK: Wording

    /// Whole minutes, rounded. Nil under a minute: too little to call "spent".
    static func spentMinutes(_ seconds: Int) -> Int? {
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes >= 1 ? minutes : nil
    }
    /// "Spent 1h 20m".
    static func spentText(seconds: Int) -> String? { spentMinutes(seconds).map { "Spent " + DayPlan.duration($0) } }
    /// "Spent 1 hour 20 minutes", for VoiceOver.
    static func spentSpoken(seconds: Int) -> String? { spentMinutes(seconds).map { "Spent " + DayPlan.spoken($0) } }
}

/// How far the estimates of recently finished tasks were from the time they took.
struct EstimateAccuracy: Equatable, Sendable {
    /// Finished tasks in the window that have both an estimate and recorded time.
    var samples: Int
    /// The median of actual over estimate across those tasks. 1.3 means tasks usually take 30% longer.
    var ratio: Double

    var isReliable: Bool { samples >= ActualTime.minimumSamples }
    /// How far from "about right", rounded to the nearest 5 percent.
    var percent: Int { Int((abs(ratio - 1) * 100 / 5).rounded()) * 5 }
    enum Verdict: Equatable, Sendable { case short, long, close }
    var verdict: Verdict { percent < 10 ? .close : (ratio > 1 ? .short : .long) }

    /// Calm, personal, never a score. Nil until there are enough tasks.
    var message: String? {
        guard isReliable else { return nil }
        switch verdict {
        case .close: return "Your estimates are close to the time tasks take"
        case .short: return "Your estimates run about \(percent)% short"
        case .long: return "Your estimates run about \(percent)% long"
        }
    }
    var detail: String? {
        guard isReliable else { return nil }
        return "Based on \(samples) tasks you finished in the last \(ActualTime.windowDays) days with Focus time recorded."
    }

    /// Finished tasks from the last `windowDays` that have an estimate and at least a minute of recorded time.
    static func reading(tasks: [Record], totals: [String: Int], now: Date, calendar: Calendar = .current) -> EstimateAccuracy? {
        guard let cutoff = calendar.date(byAdding: .day, value: -ActualTime.windowDays, to: now) else { return nil }
        var ratios: [Double] = []
        for task in tasks where task.completed {
            guard let estimate = task.durationMinutes, let seconds = totals[task.id], seconds >= 60,
                  let done = TaskPlanning.instant(task.string("completed_at")), done >= cutoff, done <= now else { continue }
            ratios.append(min(10, max(0.1, Double(seconds) / 60 / Double(estimate))))
        }
        guard !ratios.isEmpty else { return nil }
        ratios.sort()
        let mid = ratios.count / 2
        let median = ratios.count % 2 == 1 ? ratios[mid] : (ratios[mid - 1] + ratios[mid]) / 2
        return EstimateAccuracy(samples: ratios.count, ratio: median)
    }

    /// A planning caption such as "Based on your history, today may take ~7h". Shown only when the reading is reliable
    /// and differs from the plain sum by at least 10%. It never changes the scheduling arithmetic.
    func dayHint(plannedMinutes: Int) -> String? {
        guard isReliable, plannedMinutes >= 15 else { return nil }
        let expected = Double(plannedMinutes) * min(3, max(0.5, ratio))
        guard abs(expected - Double(plannedMinutes)) / Double(plannedMinutes) >= 0.1 else { return nil }
        let rounded = Int((expected / 5).rounded()) * 5
        return "Based on your history, today may take ~" + DayPlan.duration(rounded)
    }
    func dayHintSpoken(plannedMinutes: Int) -> String? {
        guard dayHint(plannedMinutes: plannedMinutes) != nil else { return nil }
        let expected = Double(plannedMinutes) * min(3, max(0.5, ratio))
        return "Based on your history, today may take about " + DayPlan.spoken(Int((expected / 5).rounded()) * 5)
    }
}
