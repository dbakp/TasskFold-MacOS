import Foundation

/// Pomodoro rhythm on top of Focus sessions. Pure: no Store, no UI, no storage beyond the Codable values.
///
/// What is synced and what is not (no server schema change). The synced Focus session row is unchanged: its document
/// accepts exactly the eight known keys (`FocusSession.init(document:)` and the database's `valid_focus_state` both
/// reject any other key), so no cycle metadata can be added to it. Each work interval is therefore an ordinary
/// Focus session written through `FocusSessionChange`, and other devices see the work timer as they always did.
/// The cycle (which round, which phase, the break clock) is device-local state, kept by `PomodoroStorage`.
/// Break intervals are local only; nothing about them syncs.
enum PomodoroMode: String, CaseIterable, Sendable {
    case single, pomodoro
    var title: String { self == .single ? "Single" : "Pomodoro" }
}

enum PomodoroPhase: String, Codable, Equatable, Sendable {
    case work, shortBreak, longBreak
    var isBreak: Bool { self != .work }
    var title: String { switch self { case .work: "Work"; case .shortBreak: "Break"; case .longBreak: "Long break" } }
}

/// Per-device settings. Every value is bounded; anything outside is clamped, never trusted.
struct PomodoroSettings: Equatable, Codable, Sendable {
    static let workRange = 1...180
    static let shortBreakRange = 1...60
    static let longBreakRange = 1...120
    static let roundsRange = 2...8
    var workMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var roundsBeforeLongBreak = 4
    /// Off by default: a break or the next round starts only when asked.
    var autoStart = false

    init() {}
    init(work: Int, shortBreak: Int, longBreak: Int, rounds: Int, autoStart: Bool = false) {
        workMinutes = work; shortBreakMinutes = shortBreak; longBreakMinutes = longBreak; roundsBeforeLongBreak = rounds; self.autoStart = autoStart
        self = clamped()
    }
    func clamped() -> Self {
        var value = self
        value.workMinutes = min(max(workMinutes, Self.workRange.lowerBound), Self.workRange.upperBound)
        value.shortBreakMinutes = min(max(shortBreakMinutes, Self.shortBreakRange.lowerBound), Self.shortBreakRange.upperBound)
        value.longBreakMinutes = min(max(longBreakMinutes, Self.longBreakRange.lowerBound), Self.longBreakRange.upperBound)
        value.roundsBeforeLongBreak = min(max(roundsBeforeLongBreak, Self.roundsRange.lowerBound), Self.roundsRange.upperBound)
        return value
    }
    func minutes(for phase: PomodoroPhase) -> Int {
        switch phase { case .work: workMinutes; case .shortBreak: shortBreakMinutes; case .longBreak: longBreakMinutes }
    }
    // UserDefaults keys. Device-local; an App Group suite can be passed so widgets can read them.
    static let defaultsKeys = ["pomodoro.work", "pomodoro.short", "pomodoro.long", "pomodoro.rounds", "pomodoro.auto", "pomodoro.mode"]
    static func load(from defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        if defaults.object(forKey: "pomodoro.work") != nil { value.workMinutes = defaults.integer(forKey: "pomodoro.work") }
        if defaults.object(forKey: "pomodoro.short") != nil { value.shortBreakMinutes = defaults.integer(forKey: "pomodoro.short") }
        if defaults.object(forKey: "pomodoro.long") != nil { value.longBreakMinutes = defaults.integer(forKey: "pomodoro.long") }
        if defaults.object(forKey: "pomodoro.rounds") != nil { value.roundsBeforeLongBreak = defaults.integer(forKey: "pomodoro.rounds") }
        value.autoStart = defaults.bool(forKey: "pomodoro.auto")
        return value.clamped()
    }
    func save(to defaults: UserDefaults = .standard) {
        let value = clamped()
        defaults.set(value.workMinutes, forKey: "pomodoro.work"); defaults.set(value.shortBreakMinutes, forKey: "pomodoro.short")
        defaults.set(value.longBreakMinutes, forKey: "pomodoro.long"); defaults.set(value.roundsBeforeLongBreak, forKey: "pomodoro.rounds")
        defaults.set(value.autoStart, forKey: "pomodoro.auto")
    }
    static func loadMode(from defaults: UserDefaults = .standard) -> PomodoroMode { PomodoroMode(rawValue: defaults.string(forKey: "pomodoro.mode") ?? "") ?? .single }
    static func saveMode(_ mode: PomodoroMode, to defaults: UserDefaults = .standard) { defaults.set(mode.rawValue, forKey: "pomodoro.mode") }
}

/// A break's clock. UTC milliseconds are the durable clock, like `FocusSession`: nothing here is a tick counter,
/// so a relaunch mid-break resumes exactly. A clock that moves backwards never produces negative progress.
struct PomodoroClock: Codable, Equatable, Sendable {
    var durationSeconds: Int
    var elapsedMilliseconds: Int64
    var startedAt: Int64
    var changedAt: Int64
    var runningSince: Int64?

    init(minutes: Int, at now: Date) {
        durationSeconds = max(1, minutes) * 60; elapsedMilliseconds = 0
        let time = FocusSession.milliseconds(now) ?? 0
        startedAt = time; changedAt = time; runningSince = time
    }
    var isRunning: Bool { runningSince != nil }
    func elapsed(at now: Date) -> Int64 {
        let limit = Int64(durationSeconds) * 1000
        guard let run = runningSince, let time = FocusSession.milliseconds(now) else { return min(limit, elapsedMilliseconds) }
        return min(limit, elapsedMilliseconds + max(0, time - run))
    }
    func remaining(at now: Date) -> TimeInterval { Double(Int64(durationSeconds) * 1000 - elapsed(at: now)) / 1000 }
    func finished(at now: Date) -> Bool { remaining(at: now) <= 0 }
    var endDate: Date? {
        guard let run = runningSince else { return nil }
        return Date(timeIntervalSince1970: Double(run + Int64(durationSeconds) * 1000 - elapsedMilliseconds) / 1000)
    }
    func paused(at now: Date) -> Self {
        guard isRunning else { return self }
        var next = self; next.elapsedMilliseconds = elapsed(at: now)
        next.changedAt = max(changedAt, FocusSession.milliseconds(now) ?? changedAt); next.runningSince = nil; return next
    }
    func resumed(at now: Date) -> Self {
        guard !isRunning, !finished(at: now) else { return self }
        var next = self
        next.changedAt = max(changedAt, FocusSession.milliseconds(now) ?? changedAt); next.runningSince = next.changedAt; return next
    }
}

/// Where the cycle is waiting: running or paused, or `ready` (the interval ended and the person decides what next).
enum PomodoroStage: String, Codable, Equatable, Sendable { case running, paused, ready }

/// The cycle of one task: work, break, work, ... with a long break after `roundsBeforeLongBreak` work rounds.
struct PomodoroCycle: Codable, Equatable, Sendable {
    var taskID: String
    /// The work round this phase belongs to, 1...rounds. A break belongs to the round it follows.
    var round: Int
    var phase: PomodoroPhase
    var stage: PomodoroStage
    /// The Focus session of the current (or most recent) work round.
    var sessionID: String?
    /// Only breaks have a local clock.
    var clock: PomodoroClock?

    static func start(taskID: String, sessionID: String) -> Self {
        Self(taskID: taskID.lowercased(), round: 1, phase: .work, stage: .running, sessionID: sessionID.lowercased(), clock: nil)
    }

    // MARK: Labels

    func roundText(rounds: Int) -> String { "\(round) of \(rounds)" }
    /// "Work · 2 of 4", "Break", "Long break".
    func label(rounds: Int) -> String { phase == .work ? "Work · " + roundText(rounds: rounds) : phase.title }
    /// "Work round 2 of 4, 14 minutes left".
    func spoken(rounds: Int, remaining: TimeInterval?) -> String {
        var text = phase == .work ? "Focus, work round \(round) of \(rounds)" : "Focus, " + phase.title.lowercased()
        if let remaining {
            let minutes = max(0, Int(ceil(remaining / 60)))
            text += ", " + (minutes == 1 ? "1 minute left" : "\(minutes) minutes left")
        }
        return text
    }

    // MARK: Transitions

    private func nextBreak(_ settings: PomodoroSettings) -> PomodoroPhase { round >= settings.roundsBeforeLongBreak ? .longBreak : .shortBreak }

    /// The work interval finished. Returns true exactly once per interval: the caller counts the round then.
    /// With auto-start the break begins at `end`, so a relaunch after the interval does not lose break time.
    @discardableResult
    mutating func workEnded(settings: PomodoroSettings, at end: Date) -> Bool {
        guard phase == .work, stage != .ready else { return false }
        phase = nextBreak(settings); stage = .ready; clock = nil
        if settings.autoStart { startBreak(settings: settings, at: end) }
        return true
    }
    /// "Start break".
    mutating func startBreak(settings: PomodoroSettings, at now: Date) {
        guard phase.isBreak, stage == .ready else { return }
        clock = PomodoroClock(minutes: settings.minutes(for: phase), at: now); stage = .running
    }
    /// "Skip": leave a break (waiting, running or paused) for the next work round, which waits to be started.
    mutating func skipBreak(settings: PomodoroSettings) {
        guard phase.isBreak else { return }
        round = phase == .longBreak || round >= settings.roundsBeforeLongBreak ? 1 : round + 1
        phase = .work; stage = .ready; clock = nil
    }
    /// A running break whose clock ran out moves on, once. Returns true when it did.
    @discardableResult
    mutating func breakEnded(settings: PomodoroSettings, at now: Date) -> Bool {
        guard phase.isBreak, stage == .running, let clock, clock.finished(at: now) else { return false }
        skipBreak(settings: settings); return true
    }
    mutating func pauseBreak(at now: Date) {
        guard phase.isBreak, stage == .running, let clock else { return }
        self.clock = clock.paused(at: now); stage = .paused
    }
    mutating func resumeBreak(at now: Date) {
        guard phase.isBreak, stage == .paused, let clock else { return }
        self.clock = clock.resumed(at: now); stage = .running
    }
    /// "Back to work": the new work round starts as this Focus session.
    mutating func beginWork(sessionID: String) {
        guard phase == .work, stage == .ready else { return }
        self.sessionID = sessionID.lowercased(); stage = .running
    }

    // MARK: Reconciling with the synced session

    struct Outcome: Equatable, Sendable {
        var cycle: PomodoroCycle?
        /// A work interval that finished: count one round for this session.
        var completed: Completed?
        struct Completed: Equatable, Sendable { var sessionID: String; var taskID: String; var end: Date }
    }
    /// Brings the cycle in line with the synced session and the clock. Called on launch, on every tick and after
    /// every sync. Idempotent: running it twice changes nothing the second time.
    ///   - an interval ended while the app was closed: it is counted once, and the break begins
    ///   - the session was ended early, replaced elsewhere or removed: the cycle ends and nothing is counted
    static func reconcile(_ cycle: PomodoroCycle?, session: FocusSession?, settings: PomodoroSettings, now: Date) -> Outcome {
        guard var cycle else { return Outcome(cycle: nil, completed: nil) }
        var completed: Outcome.Completed?
        for _ in 0..<4 {
            switch cycle.phase {
            case .work:
                if cycle.stage == .ready { return Outcome(cycle: cycle, completed: completed) }
                guard let session, session.id == cycle.sessionID, session.taskID == cycle.taskID else { return Outcome(cycle: nil, completed: completed) }
                if session.finished(at: now) {
                    let end = session.endDate ?? Date(timeIntervalSince1970: Double(session.changedAt) / 1000)
                    if cycle.workEnded(settings: settings, at: end) { completed = Outcome.Completed(sessionID: session.id, taskID: session.taskID, end: end) }
                    continue
                }
                if session.status == .stopped { return Outcome(cycle: nil, completed: completed) }
                cycle.stage = session.status == .paused ? .paused : .running
                return Outcome(cycle: cycle, completed: completed)
            case .shortBreak, .longBreak:
                // Another session started elsewhere ends this cycle; the one that just finished is expected.
                if let session, session.id != cycle.sessionID, session.status == .running, !session.finished(at: now) { return Outcome(cycle: nil, completed: completed) }
                if cycle.breakEnded(settings: settings, at: now) { continue }
                return Outcome(cycle: cycle, completed: completed)
            }
        }
        return Outcome(cycle: cycle, completed: completed)
    }
}

/// Completed work rounds, per task and per day. Device-local; a round is counted once per Focus session.
struct PomodoroTally: Codable, Equatable, Sendable {
    static let keepDays = 60
    static let keepSessions = 64
    /// day (`yyyy-MM-dd`) -> task id -> rounds
    var days: [String: [String: Int]] = [:]
    /// Recently counted session ids.
    var counted: [String] = []

    /// Returns false when this session was already counted.
    @discardableResult
    mutating func record(sessionID: String, taskID: String, day: String) -> Bool {
        let id = sessionID.lowercased()
        guard !counted.contains(id) else { return false }
        counted.append(id); if counted.count > Self.keepSessions { counted.removeFirst(counted.count - Self.keepSessions) }
        days[day, default: [:]][taskID.lowercased(), default: 0] += 1
        return true
    }
    func rounds(task: String, day: String) -> Int { days[day]?[task.lowercased()] ?? 0 }
    func rounds(on day: String) -> Int { days[day]?.values.reduce(0, +) ?? 0 }
    /// Keeps the newest days only.
    mutating func prune() {
        let keep = Set(days.keys.sorted(by: >).prefix(Self.keepDays))
        days = days.filter { keep.contains($0.key) }
    }
    /// "3 rounds", for VoiceOver.
    static func spoken(_ count: Int) -> String { count == 1 ? "1 work round" : "\(count) work rounds" }
}

/// The device-local cycle and tally, one slot per account. Values are bounded and read defensively.
enum PomodoroStorage {
    static func cycleKey(_ account: String) -> String { "pomodoro.cycle." + account }
    static func tallyKey(_ account: String) -> String { "pomodoro.tally." + account }
    static func loadCycle(account: String, defaults: UserDefaults = .standard) -> PomodoroCycle? {
        guard !account.isEmpty, let data = defaults.data(forKey: cycleKey(account)), data.count <= 4096,
              let value = try? JSONDecoder().decode(PomodoroCycle.self, from: data),
              UUID(uuidString: value.taskID) != nil, value.round >= 1, value.round <= PomodoroSettings.roundsRange.upperBound else { return nil }
        return value
    }
    static func saveCycle(_ cycle: PomodoroCycle?, account: String, defaults: UserDefaults = .standard) {
        guard !account.isEmpty else { return }
        if let cycle, let data = try? JSONEncoder().encode(cycle) { defaults.set(data, forKey: cycleKey(account)) }
        else { defaults.removeObject(forKey: cycleKey(account)) }
    }
    static func loadTally(account: String, defaults: UserDefaults = .standard) -> PomodoroTally {
        guard !account.isEmpty, let data = defaults.data(forKey: tallyKey(account)), data.count <= 65536,
              let value = try? JSONDecoder().decode(PomodoroTally.self, from: data) else { return PomodoroTally() }
        return value
    }
    static func saveTally(_ tally: PomodoroTally, account: String, defaults: UserDefaults = .standard) {
        guard !account.isEmpty, let data = try? JSONEncoder().encode(tally) else { return }
        defaults.set(data, forKey: tallyKey(account))
    }
}

// MARK: - Widget overlay

extension PomodoroCycle {
    /// The cycle as the small, bounded document the widget projection reads from the record it is handed.
    func widgetDocument(rounds: Int) -> JSON {
        var fields: [String: JSON] = ["phase": .string(phase == .work ? "work" : phase == .longBreak ? "longBreak" : "break"),
            "round": .number(Double(round)), "rounds": .number(Double(rounds)), "stage": .string(stage.rawValue), "taskID": .string(taskID),
            "sessionID": .string(sessionID ?? "")]
        if let clock, phase.isBreak, stage != .ready {
            fields["clock"] = .object(["durationSeconds": .number(Double(clock.durationSeconds)), "elapsedMilliseconds": .number(Double(clock.elapsedMilliseconds)),
                "startedAt": .number(Double(clock.startedAt)), "changedAt": .number(Double(clock.changedAt)),
                "runningSince": clock.runningSince.map { .number(Double($0)) } ?? .null])
        }
        return .object(fields)
    }
    struct WidgetOverlay: Equatable, Sendable {
        var phase: String, round: Int, rounds: Int, taskID: String, sessionID: String, breakID: String
        var clock: PomodoroClock?
    }
    /// Reads `widgetDocument` back, defensively: anything malformed means no overlay.
    static func widgetOverlay(_ value: JSON?) -> WidgetOverlay? {
        guard case .object(let o)? = value, let phase = o["phase"]?.text, ["work", "break", "longBreak"].contains(phase),
              case .number(let r)? = o["round"], case .number(let n)? = o["rounds"], r >= 1, n >= 2, n <= 8, r <= n, r.rounded() == r, n.rounded() == n,
              let task = o["taskID"]?.text, UUID(uuidString: task) != nil else { return nil }
        var clock: PomodoroClock?
        if case .object(let c)? = o["clock"] {
            func number(_ key: String) -> Int64? { if case .number(let v)? = c[key], v.isFinite, v >= 0, v <= 4_133_980_800_000, v.rounded() == v { return Int64(v) }; return nil }
            guard let duration = number("durationSeconds"), (60...7200).contains(duration), duration % 60 == 0, let elapsed = number("elapsedMilliseconds"), elapsed <= duration * 1000,
                  let started = number("startedAt"), let changed = number("changedAt"), changed >= started else { return nil }
            var value = PomodoroClock(minutes: Int(duration / 60), at: Date(timeIntervalSince1970: 0))
            value.elapsedMilliseconds = elapsed; value.startedAt = started; value.changedAt = changed
            if case .number(let run)? = c["runningSince"] {
                guard run.isFinite, run.rounded() == run, Int64(run) >= started, Int64(run) <= changed else { return nil }
                value.runningSince = Int64(run)
            } else { value.runningSince = nil }
            clock = value
        }
        let suffix = String(format: "%012llx", UInt64(clock?.startedAt ?? 0))
        return WidgetOverlay(phase: phase, round: Int(r), rounds: Int(n), taskID: task.lowercased(), sessionID: (o["sessionID"]?.text ?? "").lowercased(),
                             breakID: "00000000-0000-4000-8000-" + String(suffix.suffix(12)), clock: clock)
    }
}
