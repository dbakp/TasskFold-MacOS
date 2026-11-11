import Foundation

// Momentum: streaks, a calm productivity score, lifetime levels and vacation mode.
// Spec: specs/MOMENTUM.md. Everything here is a pure function of the completion history the
// apps already record (InsightsReading) and the goals document. Nothing is stored, nothing is
// sent anywhere, and overdue work never subtracts from any number.

// MARK: - Vacation

/// A closed range of civil days (yyyy-MM-dd in the goals' time zone). `until == nil` means open-ended.
struct VacationRange: Equatable, Sendable {
    var from: String
    var until: String?
    func contains(_ day: String) -> Bool { day >= from && (until.map { day <= $0 } ?? true) }
    func overlaps(_ other: VacationRange) -> Bool {
        (until.map { other.from <= $0 } ?? true) && (other.until.map { from <= $0 } ?? true)
    }
}

enum VacationStatus: Equatable, Sendable {
    case off
    /// Vacation covers today. `until` is nil when the end date is open.
    case on(from: String, until: String?)
    /// A start date in the future; nothing is frozen yet.
    case scheduled(from: String, until: String?)
}

extension ProductivityGoals {
    static let vacationHistoryLimit = 10
    static let vacationFields = ["vacation_from", "vacation_until", "vacation_ranges"]

    static func isDayKey(_ text: String) -> Bool { text.count == 10 && Dates.parse(text) != nil }

    /// Past vacations plus the current one, for streak maths. Ends that already passed count as past.
    var allVacationRanges: [VacationRange] {
        vacationRanges + (vacationFrom.map { [VacationRange(from: $0, until: vacationUntil)] } ?? [])
    }

    func isOnVacation(dayKey: String) -> Bool { allVacationRanges.contains { $0.contains(dayKey) } }

    func vacationStatus(now: Date = Date()) -> VacationStatus {
        guard let from = vacationFrom else { return .off }
        let today = TaskPlanner.dayKey(now, calendar: calendar)
        if let until = vacationUntil, until < today { return .off }
        return from > today ? .scheduled(from: from, until: vacationUntil) : .on(from: from, until: vacationUntil)
    }

    /// Validation for a goals value built in code. Documents read from storage are repaired instead (see `init(document:)`).
    func checkVacation() throws {
        let message = "Choose a vacation end date on or after the start, without overlapping earlier vacations."
        var all: [VacationRange] = vacationRanges
        guard vacationRanges.count <= Self.vacationHistoryLimit else { throw AppFailure(message: message) }
        for range in vacationRanges {
            guard Self.isDayKey(range.from), let until = range.until, Self.isDayKey(until), until >= range.from else { throw AppFailure(message: message) }
        }
        if let from = vacationFrom {
            guard Self.isDayKey(from) else { throw AppFailure(message: message) }
            if let until = vacationUntil { guard Self.isDayKey(until), until >= from else { throw AppFailure(message: message) } }
            all.append(VacationRange(from: from, until: vacationUntil))
        } else if vacationUntil != nil { throw AppFailure(message: message) }
        for (index, range) in all.enumerated() { for other in all[(index + 1)...] where range.overlaps(other) { throw AppFailure(message: message) } }
    }

    /// Moves a current vacation whose end has passed into history, so the next one can start.
    mutating func archiveEndedVacation(now: Date = Date()) {
        guard let from = vacationFrom, let until = vacationUntil, until < TaskPlanner.dayKey(now, calendar: calendar) else { return }
        vacationRanges.append(VacationRange(from: from, until: until))
        vacationRanges = Array(vacationRanges.suffix(Self.vacationHistoryLimit))
        vacationFrom = nil; vacationUntil = nil
    }

    /// Starts vacation today, or changes the end date of one already running. `until` is a day key or nil for open-ended.
    mutating func startVacation(until: String?, now: Date = Date()) throws {
        archiveEndedVacation(now: now)
        let today = TaskPlanner.dayKey(now, calendar: calendar)
        let previous = (vacationFrom, vacationUntil)
        if case .on = vacationStatus(now: now) { vacationUntil = until } else { vacationFrom = today; vacationUntil = until }
        do { try checkVacation() } catch { (vacationFrom, vacationUntil) = previous; throw error }
    }

    /// Ends vacation now. Today is no longer a vacation day; earlier vacation days stay excluded.
    mutating func endVacation(now: Date = Date()) {
        archiveEndedVacation(now: now)
        guard let from = vacationFrom else { return }
        let today = TaskPlanner.dayKey(now, calendar: calendar)
        if from < today, let todayStart = Dates.parse(today, calendar: calendar), let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            vacationRanges.append(VacationRange(from: from, until: TaskPlanner.dayKey(yesterday, calendar: calendar)))
            vacationRanges = Array(vacationRanges.suffix(Self.vacationHistoryLimit))
        }
        vacationFrom = nil; vacationUntil = nil
    }

    /// Reads the three optional fields leniently: anything that does not parse is ignored, never fatal to the goals.
    static func readVacation(_ fields: [String: JSON]) -> (from: String?, until: String?, ranges: [VacationRange], repaired: Bool) {
        var repaired = false
        func day(_ value: JSON?) -> String? { if case .string(let text)? = value, isDayKey(text) { return text }; return nil }
        var from: String?, until: String?
        if let raw = fields["vacation_from"], raw != .null {
            if let value = day(raw) {
                from = value
                if let rawUntil = fields["vacation_until"], rawUntil != .null {
                    if let end = day(rawUntil), end >= value { until = end } else { from = nil; repaired = true }
                }
            } else { repaired = true }
        } else if let rawUntil = fields["vacation_until"], rawUntil != .null { repaired = true }
        var ranges: [VacationRange] = []
        if let raw = fields["vacation_ranges"], raw != .null {
            if case .array(let items) = raw {
                for item in items {
                    guard case .object(let entry) = item, let start = day(entry["from"]), let end = day(entry["until"]), end >= start else { repaired = true; continue }
                    ranges.append(VacationRange(from: start, until: end))
                }
            } else { repaired = true }
        }
        ranges.sort { $0.from < $1.from }
        var kept: [VacationRange] = []
        let current = from.map { VacationRange(from: $0, until: until) }
        for range in ranges {
            if kept.contains(where: { $0.overlaps(range) }) || current?.overlaps(range) == true { repaired = true; continue }
            kept.append(range)
        }
        if kept.count > vacationHistoryLimit { kept = Array(kept.suffix(vacationHistoryLimit)); repaired = true }
        return (from, until, kept, repaired)
    }

    /// The vacation keys as stored. Absent keys are removed so an ended vacation does not linger.
    func vacationDocumentFields() -> [String: JSON] {
        var result: [String: JSON] = [:]
        if let from = vacationFrom { result["vacation_from"] = .string(from); if let until = vacationUntil { result["vacation_until"] = .string(until) } }
        if !vacationRanges.isEmpty {
            result["vacation_ranges"] = .array(vacationRanges.suffix(Self.vacationHistoryLimit).map { .object(["from": .string($0.from), "until": .string($0.until ?? $0.from)]) })
        }
        return result
    }
}

// MARK: - Days

enum MomentumDayState: String, Sendable {
    case met, missed, rest, vacation
    /// Today, active, goal not reached yet. Never breaks a streak.
    case pending
    /// No recorded history for the day; ends what can be computed.
    case untracked
    case noGoal
}

struct MomentumDay: Identifiable, Equatable, Sendable {
    var id: String
    var date: Date
    var count: Int
    var target: Int?
    var coverage: InsightsReading.Coverage
    var state: MomentumDayState
}

struct MomentumStreak: Equatable, Sendable {
    var length: Int
    /// Set when recorded history, not a missed day, bounds the streak: "since <date>".
    var since: Date?
    static let none = MomentumStreak(length: 0, since: nil)
}

struct MomentumLevel: Equatable, Sendable {
    var index: Int
    var name: String
    var threshold: Int
    var points: Int
    var next: (name: String, threshold: Int)?
    /// 0...1 towards the next level; 1 at the top.
    var progress: Double
    var remaining: Int? { next.map { max(0, $0.threshold - points) } }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.points == rhs.points && lhs.next?.name == rhs.next?.name
    }
}

struct MomentumSummary: Equatable, Sendable {
    var hasDailyGoal: Bool
    var hasWeeklyGoal: Bool
    var dailyStreak: MomentumStreak
    var longestDailyStreak: MomentumStreak
    var weeklyStreak: MomentumStreak
    var longestWeeklyStreak: MomentumStreak
    /// 0...100, nil with no daily goal or no scorable days yet.
    var score: Int?
    var totalCompletions: Int
    var level: MomentumLevel
    /// The last seven days, oldest first.
    var week: [MomentumDay]
    var vacation: VacationStatus
    var reliable: Bool
    /// "7-day streak", for the Today chip, only when the streak is at least two days.
    var chipText: String? { hasDailyGoal && dailyStreak.length >= 2 ? "\(dailyStreak.length)-day streak" : nil }
}

// MARK: - Maths

enum Momentum {
    static let levelNames = ["Starting", "Steady", "Focused", "Flowing", "Unstoppable", "Luminous"]
    static let levelThresholds = [0, 50, 250, 1000, 2500, 5000]
    static let streakMilestones = [7, 30, 100, 365]
    /// A longest-streak milestone adds a little to the level points; completions stay the main driver.
    static let milestoneBonus: [Int: Int] = [7: 10, 30: 40, 100: 150, 365: 500]
    static let halfLifeDays = 7.0
    static let attainmentCap = 1.5

    static func level(totalCompletions: Int, longestDailyStreak: Int) -> MomentumLevel {
        let bonus = milestoneBonus.filter { longestDailyStreak >= $0.key }.values.reduce(0, +)
        let points = max(0, totalCompletions) + bonus
        let index = levelThresholds.lastIndex { points >= $0 } ?? 0
        let next = index + 1 < levelNames.count ? (name: levelNames[index + 1], threshold: levelThresholds[index + 1]) : nil
        let span = next.map { Double($0.threshold - levelThresholds[index]) } ?? 1
        let progress = next == nil ? 1 : min(1, max(0, Double(points - levelThresholds[index]) / span))
        return MomentumLevel(index: index, name: levelNames[index], threshold: levelThresholds[index], points: points, next: next, progress: progress)
    }

    /// One state per day, oldest first. `days` must end today.
    static func dayStates(days: [InsightsReading.Day], goals: ProductivityGoals, now: Date) -> [MomentumDay] {
        let todayKey = TaskPlanner.dayKey(now, calendar: goals.calendar)
        let target = goals.dailyTarget
        return days.map { day in
            let state: MomentumDayState
            if goals.isOnVacation(dayKey: day.id) { state = .vacation }
            else if target == 0 { state = .noGoal }
            else if day.restDay { state = .rest }
            else if day.coverage == .untracked && day.count == 0 { state = .untracked }
            else if day.count >= target { state = .met }
            else if day.id == todayKey { state = .pending }
            else { state = .missed }
            return MomentumDay(id: day.id, date: day.date, count: day.count, target: target > 0 && !day.restDay ? target : nil, coverage: day.coverage, state: state)
        }
    }

    private enum Step { case met, skip, miss, boundary }

    /// Current streak ends at the newest step (a skipped or pending newest step is passed over); longest is the best run anywhere.
    private static func streaks(_ steps: [(step: Step, date: Date)]) -> (current: MomentumStreak, longest: MomentumStreak) {
        var current = 0, currentSince: Date?, endedByMiss = false
        scan: for item in steps.reversed() {
            switch item.step {
            case .met: current += 1; currentSince = item.date
            case .skip: break
            case .miss: endedByMiss = true; break scan
            case .boundary: break scan
            }
        }
        // A missed day is a real end; only a boundary or the start of the window bounds what we can know.
        let currentLimited = current > 0 && !endedByMiss
        var best = 0, bestSince: Date?, bestLimited = false
        var run = 0, runSince: Date?, runLimited = true
        for item in steps {
            switch item.step {
            case .met:
                if run == 0 { runSince = item.date }
                run += 1
                if run > best { best = run; bestSince = runSince; bestLimited = runLimited }
            case .skip: break
            case .miss: run = 0; runLimited = false
            case .boundary: run = 0; runLimited = true
            }
        }
        return (MomentumStreak(length: current, since: currentLimited ? currentSince : nil),
                MomentumStreak(length: best, since: bestLimited && best > 0 ? bestSince : nil))
    }

    static func dailyStreaks(_ days: [MomentumDay]) -> (current: MomentumStreak, longest: MomentumStreak) {
        streaks(days.map { day in
            switch day.state {
            case .met: return (.met, day.date)
            case .missed: return (.miss, day.date)
            case .untracked: return (.boundary, day.date)
            case .rest, .vacation, .pending, .noGoal: return (.skip, day.date)
            }
        })
    }

    /// Weeks follow the saved week start. The current week counts once its goal is met; a week that cannot be
    /// judged (history starts inside it) ends what is computable.
    static func weeklyStreaks(_ days: [MomentumDay], goals: ProductivityGoals, now: Date) -> (current: MomentumStreak, longest: MomentumStreak) {
        let target = goals.weeklyTarget
        guard target > 0, !days.isEmpty else { return (.none, .none) }
        let calendar = goals.calendar
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        var order: [Date] = [], groups: [Date: [MomentumDay]] = [:]
        for day in days {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: day.date)?.start else { continue }
            if groups[start] == nil { order.append(start) }
            groups[start, default: []].append(day)
        }
        let windowStart = days[0].date
        let steps: [(step: Step, date: Date)] = order.map { start in
            let week = groups[start] ?? []
            let count = week.reduce(0) { $0 + $1.count }
            if count >= target { return (.met, start) }
            if start == currentWeek { return (.skip, start) }
            if start < windowStart || week.contains(where: { $0.state == .untracked }) { return (.boundary, start) }
            if week.contains(where: { $0.state == .vacation }) { return (.skip, start) }
            return (.miss, start)
        }
        return streaks(steps)
    }

    /// Exponentially weighted attainment over active, tracked, non-vacation days, scaled to 0...100.
    /// Rest and vacation days carry no weight. Today counts only once its goal is met, so a day in progress never lowers it.
    static func score(_ days: [MomentumDay]) -> Int? {
        var weighted = 0.0, weights = 0.0
        for (index, day) in days.enumerated() {
            guard let target = day.target, target > 0 else { continue }
            switch day.state {
            case .met: break
            case .missed: if day.coverage == .partial { continue }  // Incomplete history is not a miss.
            default: continue
            }
            let age = Double(days.count - 1 - index)
            let weight = pow(0.5, age / halfLifeDays)
            weighted += weight * min(Double(day.count) / Double(target), attainmentCap)
            weights += weight
        }
        guard weights > 0 else { return nil }
        return min(100, max(0, Int((100 * weighted / (weights * attainmentCap)).rounded())))
    }

    static func summary(reading: InsightsReading, goals: ProductivityGoals, now: Date) -> MomentumSummary {
        let days = dayStates(days: reading.days, goals: goals, now: now)
        let daily = goals.dailyTarget > 0 ? dailyStreaks(days) : (current: MomentumStreak.none, longest: MomentumStreak.none)
        let weekly = weeklyStreaks(days, goals: goals, now: now)
        let total = reading.credits.count
        return MomentumSummary(
            hasDailyGoal: goals.dailyTarget > 0, hasWeeklyGoal: goals.weeklyTarget > 0,
            dailyStreak: daily.current, longestDailyStreak: daily.longest,
            weeklyStreak: weekly.current, longestWeeklyStreak: weekly.longest,
            score: goals.dailyTarget > 0 ? score(days) : nil,
            totalCompletions: total, level: level(totalCompletions: total, longestDailyStreak: daily.longest.length),
            week: Array(days.suffix(7)), vacation: goals.vacationStatus(now: now), reliable: reading.reliable)
    }

    /// The history window Momentum reads: as far back as Insights can.
    static let windowDays = 366

    static func summary(account: String, activity: [Record], epoch: [Record], goals: ProductivityGoals, children: ChildWorkHistory?, now: Date = Date()) -> MomentumSummary {
        let reading = InsightsReading(account: account, activity: activity, epoch: epoch, goals: goals, scope: .mine, windowDays: windowDays, now: now, children: children)
        return summary(reading: reading, goals: goals, now: now)
    }
}

// MARK: - Milestones

/// A calm moment worth marking. At most one per completion; the daily-goal toast carries it when both land together.
enum MomentumMilestone: Equatable, Sendable {
    case streak(Int)
    case level(name: String)

    var title: String {
        switch self {
        case .streak(let days): return "\(days)-day streak"
        case .level: return "Level up"
        }
    }
    /// Appended to the daily-goal toast when both land on the same completion.
    var short: String {
        switch self {
        case .streak(let days): return "\(days)-day streak"
        case .level(let name): return "Level up · \(name)"
        }
    }
    var detail: String {
        switch self {
        case .streak: return "Daily goal met \(days) days in a row"
        case .level(let name): return "You reached \(name)"
        }
    }
    private var days: Int { if case .streak(let value) = self { return value }; return 0 }
}

enum MomentumCelebration {
    static func levelKey(_ account: String) -> String { "momentumLevel." + account }
    static func streakKey(_ account: String) -> String { "momentumStreakDay." + account }
    /// Fixtures start from a fresh day, like the daily-goal celebration.
    static func resetAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("momentumLevel.") || key.hasPrefix("momentumStreakDay.") { defaults.removeObject(forKey: key) }
    }

    /// Called right after a completion with a fresh summary. Streak milestones fire when this completion
    /// just met today's goal, once per day. A level-up fires once per level; the first read only records the level.
    /// Nothing fires on vacation. A milestone is returned, and recorded as celebrated, only when `record` is true.
    static func milestone(summary: MomentumSummary, goals: ProductivityGoals, todayCount: Int, account: String,
                          now: Date = Date(), defaults: UserDefaults = .standard, record: Bool = true) -> MomentumMilestone? {
        guard !account.isEmpty, goals.dailyTarget > 0, summary.vacation == .off, summary.reliable else { return nil }
        let day = TaskPlanner.dayKey(now, calendar: goals.calendar)
        var found: MomentumMilestone?
        let stored = defaults.object(forKey: levelKey(account)) as? Int
        if stored == nil { if record { defaults.set(summary.level.index, forKey: levelKey(account)) } }
        else if let stored, summary.level.index > stored {
            found = .level(name: summary.level.name)
            if record { defaults.set(summary.level.index, forKey: levelKey(account)) }
        }
        if let target = goals.target(on: now), todayCount == target, Momentum.streakMilestones.contains(summary.dailyStreak.length),
           defaults.string(forKey: streakKey(account)) != day {
            if record { defaults.set(day, forKey: streakKey(account)) }
            // A streak outranks a level-up when both land on the same completion.
            found = .streak(summary.dailyStreak.length)
        }
        return found
    }
}
