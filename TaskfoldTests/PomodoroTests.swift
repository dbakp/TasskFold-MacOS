import XCTest
@testable import TaskfoldCore

/// Pomodoro (Core/Pomodoro.swift): the phase machine, long-break cadence, pause and resume, relaunch mid-phase,
/// clock changes, the tally and the settings bounds.
final class PomodoroTests: XCTestCase {
    let task = "00000000-0000-4000-8000-0000000000aa"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func later(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    let settings = PomodoroSettings()

    func session(minutes: Int = 25, start: Date? = nil, id: UUID = UUID()) throws -> FocusSession {
        try FocusSession(taskID: task, minutes: minutes, now: start ?? t0, id: id)
    }

    // MARK: Settings

    func testDefaultsAreTheClassicRhythm() {
        XCTAssertEqual(settings.workMinutes, 25); XCTAssertEqual(settings.shortBreakMinutes, 5)
        XCTAssertEqual(settings.longBreakMinutes, 15); XCTAssertEqual(settings.roundsBeforeLongBreak, 4)
        XCTAssertFalse(settings.autoStart, "auto-start is off by default")
        XCTAssertEqual(settings.minutes(for: .work), 25); XCTAssertEqual(settings.minutes(for: .shortBreak), 5); XCTAssertEqual(settings.minutes(for: .longBreak), 15)
    }

    func testSettingsAreClampedToTheirBounds() {
        let low = PomodoroSettings(work: 0, shortBreak: -4, longBreak: 0, rounds: 1)
        XCTAssertEqual([low.workMinutes, low.shortBreakMinutes, low.longBreakMinutes, low.roundsBeforeLongBreak], [1, 1, 1, 2])
        let high = PomodoroSettings(work: 999, shortBreak: 999, longBreak: 999, rounds: 99, autoStart: true)
        XCTAssertEqual([high.workMinutes, high.shortBreakMinutes, high.longBreakMinutes, high.roundsBeforeLongBreak], [180, 60, 120, 8])
        XCTAssertTrue(high.autoStart)
        XCTAssertLessThanOrEqual(PomodoroSettings.workRange.upperBound, 180, "a work interval must fit a Focus session")
    }

    func testSettingsRoundTripThroughDefaultsAndIgnoreGarbage() {
        let defaults = UserDefaults(suiteName: "pomodoro-tests-" + UUID().uuidString)!
        XCTAssertEqual(PomodoroSettings.load(from: defaults), PomodoroSettings())
        PomodoroSettings(work: 50, shortBreak: 10, longBreak: 30, rounds: 3, autoStart: true).save(to: defaults)
        XCTAssertEqual(PomodoroSettings.load(from: defaults), PomodoroSettings(work: 50, shortBreak: 10, longBreak: 30, rounds: 3, autoStart: true))
        defaults.set(100_000, forKey: "pomodoro.work"); defaults.set(-3, forKey: "pomodoro.rounds")
        let loaded = PomodoroSettings.load(from: defaults)
        XCTAssertEqual(loaded.workMinutes, 180); XCTAssertEqual(loaded.roundsBeforeLongBreak, 2)
        XCTAssertEqual(PomodoroSettings.loadMode(from: defaults), .single)
        PomodoroSettings.saveMode(.pomodoro, to: defaults)
        XCTAssertEqual(PomodoroSettings.loadMode(from: defaults), .pomodoro)
        defaults.set("nonsense", forKey: "pomodoro.mode")
        XCTAssertEqual(PomodoroSettings.loadMode(from: defaults), .single)
    }

    // MARK: Phase machine

    func testAFullCycleHasThreeShortBreaksAndALongOne() {
        var cycle = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        var phases: [PomodoroPhase] = [cycle.phase]
        for round in 1...4 {
            XCTAssertEqual(cycle.round, round)
            XCTAssertTrue(cycle.workEnded(settings: settings, at: t0))
            phases.append(cycle.phase)
            XCTAssertEqual(cycle.stage, .ready, "a break waits for \"Start break\"")
            cycle.skipBreak(settings: settings)
            phases.append(cycle.phase)
            XCTAssertEqual(cycle.stage, .ready, "work waits for \"Back to work\"")
            cycle.beginWork(sessionID: UUID().uuidString)
            XCTAssertEqual(cycle.stage, .running)
        }
        XCTAssertEqual(phases, [.work, .shortBreak, .work, .shortBreak, .work, .shortBreak, .work, .longBreak, .work])
        XCTAssertEqual(cycle.round, 1, "after the long break the count starts again")
    }

    func testTheLongBreakCadenceFollowsTheSetting() {
        let two = PomodoroSettings(work: 25, shortBreak: 5, longBreak: 15, rounds: 2)
        var cycle = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        cycle.workEnded(settings: two, at: t0); XCTAssertEqual(cycle.phase, .shortBreak)
        cycle.skipBreak(settings: two); cycle.beginWork(sessionID: UUID().uuidString)
        cycle.workEnded(settings: two, at: t0); XCTAssertEqual(cycle.phase, .longBreak)
    }

    func testWorkEndsOnlyOnceAndOnlyFromWork() {
        var cycle = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        XCTAssertTrue(cycle.workEnded(settings: settings, at: t0))
        XCTAssertFalse(cycle.workEnded(settings: settings, at: t0), "a second call must not count again")
        var fresh = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        fresh.skipBreak(settings: settings); XCTAssertEqual(fresh.phase, .work, "skipping outside a break does nothing")
        fresh.startBreak(settings: settings, at: t0); XCTAssertNil(fresh.clock)
    }

    func testBreakTimerRunsPausesAndResumesWithoutLosingTime() {
        var cycle = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        cycle.workEnded(settings: settings, at: t0)
        cycle.startBreak(settings: settings, at: later(10))
        XCTAssertEqual(cycle.stage, .running); XCTAssertEqual(cycle.clock?.durationSeconds, 300)
        cycle.pauseBreak(at: later(70))
        XCTAssertEqual(cycle.stage, .paused); XCTAssertEqual(cycle.clock?.remaining(at: later(900)), 240, "paused time does not run")
        cycle.resumeBreak(at: later(1000))
        XCTAssertEqual(cycle.clock?.remaining(at: later(1100)), 140)
        XCTAssertFalse(cycle.breakEnded(settings: settings, at: later(1100)))
        XCTAssertTrue(cycle.breakEnded(settings: settings, at: later(1240)))
        XCTAssertEqual(cycle.phase, .work); XCTAssertEqual(cycle.stage, .ready); XCTAssertEqual(cycle.round, 2)
        XCTAssertFalse(cycle.breakEnded(settings: settings, at: later(1300)), "once")
    }

    func testLongBreakUsesItsOwnLength() {
        var cycle = PomodoroCycle(taskID: task, round: 4, phase: .work, stage: .running, sessionID: UUID().uuidString, clock: nil)
        cycle.workEnded(settings: settings, at: t0); cycle.startBreak(settings: settings, at: t0)
        XCTAssertEqual(cycle.phase, .longBreak); XCTAssertEqual(cycle.clock?.durationSeconds, 900)
    }

    func testAutoStartBeginsTheBreakAtTheEndOfTheWorkInterval() {
        let auto = PomodoroSettings(work: 25, shortBreak: 5, longBreak: 15, rounds: 4, autoStart: true)
        var cycle = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        cycle.workEnded(settings: auto, at: t0)
        XCTAssertEqual(cycle.stage, .running)
        XCTAssertEqual(cycle.clock?.remaining(at: later(120)), 180, "the break counts from when work ended")
    }

    func testLabelsAndSpokenText() {
        var cycle = PomodoroCycle(taskID: task, round: 2, phase: .work, stage: .running, sessionID: nil, clock: nil)
        XCTAssertEqual(cycle.label(rounds: 4), "Work · 2 of 4"); XCTAssertEqual(cycle.roundText(rounds: 4), "2 of 4")
        XCTAssertEqual(cycle.spoken(rounds: 4, remaining: 14 * 60), "Focus, work round 2 of 4, 14 minutes left")
        XCTAssertEqual(cycle.spoken(rounds: 4, remaining: 30), "Focus, work round 2 of 4, 1 minute left")
        cycle.phase = .shortBreak; XCTAssertEqual(cycle.label(rounds: 4), "Break")
        cycle.phase = .longBreak; XCTAssertEqual(cycle.label(rounds: 4), "Long break")
        XCTAssertEqual(cycle.spoken(rounds: 4, remaining: nil), "Focus, long break")
    }

    // MARK: Reconciling with the synced session

    func testReconcileMirrorsAPausedAndResumedSession() throws {
        let s = try session()
        let cycle = PomodoroCycle.start(taskID: task, sessionID: s.id)
        let paused = try s.paused(at: later(60))
        XCTAssertEqual(PomodoroCycle.reconcile(cycle, session: paused, settings: settings, now: later(61)).cycle?.stage, .paused)
        let resumed = try paused.resumed(at: later(120))
        let outcome = PomodoroCycle.reconcile(cycle, session: resumed, settings: settings, now: later(121))
        XCTAssertEqual(outcome.cycle?.stage, .running); XCTAssertNil(outcome.completed)
    }

    func testRelaunchAfterTheWorkIntervalCountsOneRoundAndMovesToBreak() throws {
        let s = try session()
        let cycle = PomodoroCycle.start(taskID: task, sessionID: s.id)
        let outcome = PomodoroCycle.reconcile(cycle, session: s, settings: settings, now: later(25 * 60 + 90))
        XCTAssertEqual(outcome.cycle?.phase, .shortBreak); XCTAssertEqual(outcome.cycle?.stage, .ready)
        XCTAssertEqual(outcome.completed?.sessionID, s.id); XCTAssertEqual(outcome.completed?.taskID, task)
        XCTAssertEqual(outcome.completed?.end, later(25 * 60), "counted for the day the interval ended, not the day of the relaunch")
        let again = PomodoroCycle.reconcile(outcome.cycle, session: s, settings: settings, now: later(25 * 60 + 100))
        XCTAssertNil(again.completed, "reconcile is idempotent")
        XCTAssertEqual(again.cycle, outcome.cycle)
    }

    func testRelaunchMidBreakKeepsTheBreakClock() throws {
        let s = try session()
        var cycle = PomodoroCycle.start(taskID: task, sessionID: s.id)
        cycle.workEnded(settings: settings, at: later(1500)); cycle.startBreak(settings: settings, at: later(1500))
        let mid = PomodoroCycle.reconcile(cycle, session: s, settings: settings, now: later(1500 + 120))
        XCTAssertEqual(mid.cycle?.phase, .shortBreak); XCTAssertEqual(mid.cycle?.clock?.remaining(at: later(1620)), 180)
        let over = PomodoroCycle.reconcile(cycle, session: s, settings: settings, now: later(1500 + 400))
        XCTAssertEqual(over.cycle?.phase, .work); XCTAssertEqual(over.cycle?.stage, .ready); XCTAssertEqual(over.cycle?.round, 2)
    }

    func testAutoStartAcrossARelaunchSpendsTheBreakThatAlreadyPassed() throws {
        let auto = PomodoroSettings(work: 25, shortBreak: 5, longBreak: 15, rounds: 4, autoStart: true)
        let s = try session()
        let cycle = PomodoroCycle.start(taskID: task, sessionID: s.id)
        // Away for 8 minutes after the interval: the whole 5-minute break is over.
        let outcome = PomodoroCycle.reconcile(cycle, session: s, settings: auto, now: later(1500 + 480))
        XCTAssertEqual(outcome.cycle?.phase, .work); XCTAssertEqual(outcome.cycle?.round, 2); XCTAssertEqual(outcome.cycle?.stage, .ready)
        XCTAssertEqual(outcome.completed?.sessionID, s.id)
    }

    func testEndingTheSessionEarlyEndsTheCycleWithoutCounting() throws {
        let s = try session()
        let cycle = PomodoroCycle.start(taskID: task, sessionID: s.id)
        let stopped = try s.stopped(at: later(300))
        let outcome = PomodoroCycle.reconcile(cycle, session: stopped, settings: settings, now: later(301))
        XCTAssertNil(outcome.cycle); XCTAssertNil(outcome.completed)
    }

    func testEndingAFinishedSessionStillCountsTheRound() throws {
        let s = try session()
        let cycle = PomodoroCycle.start(taskID: task, sessionID: s.id)
        let finished = try s.stopped(at: later(1500))
        XCTAssertEqual(finished.elapsedMilliseconds, 1_500_000)
        XCTAssertNotNil(PomodoroCycle.reconcile(cycle, session: finished, settings: settings, now: later(1600)).completed)
    }

    func testAnotherDeviceReplacingTheSessionEndsTheCycle() throws {
        let mine = try session(), theirs = try session(start: later(100))
        let cycle = PomodoroCycle.start(taskID: task, sessionID: mine.id)
        XCTAssertNil(PomodoroCycle.reconcile(cycle, session: theirs, settings: settings, now: later(200)).cycle)
        XCTAssertNil(PomodoroCycle.reconcile(cycle, session: nil, settings: settings, now: later(200)).cycle)
        var inBreak = cycle; inBreak.workEnded(settings: settings, at: later(1500)); inBreak.startBreak(settings: settings, at: later(1500))
        XCTAssertNil(PomodoroCycle.reconcile(inBreak, session: try session(start: later(1550)), settings: settings, now: later(1560)).cycle,
                     "a new session running elsewhere during a break ends the cycle")
        XCTAssertNotNil(PomodoroCycle.reconcile(inBreak, session: mine, settings: settings, now: later(1560)).cycle, "the work session that just finished is expected")
    }

    func testAWaitingWorkRoundKeepsTheCycleWithoutASession() {
        let cycle = PomodoroCycle(taskID: task, round: 2, phase: .work, stage: .ready, sessionID: nil, clock: nil)
        XCTAssertEqual(PomodoroCycle.reconcile(cycle, session: nil, settings: settings, now: t0).cycle, cycle)
        XCTAssertNil(PomodoroCycle.reconcile(nil, session: nil, settings: settings, now: t0).cycle)
    }

    // MARK: Clock changes

    func testABackwardsClockNeverMakesNegativeProgressOrAFreeBreak() {
        var clock = PomodoroClock(minutes: 5, at: later(1000))
        XCTAssertEqual(clock.remaining(at: later(900)), 300, "the clock moved back: no time has passed")
        XCTAssertEqual(clock.elapsed(at: later(900)), 0)
        clock = clock.paused(at: later(900))
        XCTAssertEqual(clock.elapsedMilliseconds, 0); XCTAssertGreaterThanOrEqual(clock.changedAt, clock.startedAt)
        XCTAssertFalse(clock.finished(at: later(10_000_000)) && clock.isRunning)
    }

    func testAForwardJumpFinishesTheBreakAndNeverOverruns() {
        let clock = PomodoroClock(minutes: 5, at: t0)
        XCTAssertTrue(clock.finished(at: later(1_000_000)))
        XCTAssertEqual(clock.elapsed(at: later(1_000_000)), 300_000)
        XCTAssertEqual(clock.remaining(at: later(1_000_000)), 0)
        XCTAssertEqual(clock.resumed(at: later(10)), clock, "a running clock does not restart")
    }

    // MARK: Tally

    func testRoundsAreCountedOncePerSessionPerTaskAndDay() {
        var tally = PomodoroTally()
        XCTAssertTrue(tally.record(sessionID: "S1", taskID: task, day: "2026-11-11"))
        XCTAssertFalse(tally.record(sessionID: "s1", taskID: task, day: "2026-11-11"), "the same session is never counted twice")
        XCTAssertTrue(tally.record(sessionID: "s2", taskID: task, day: "2026-11-11"))
        XCTAssertTrue(tally.record(sessionID: "s3", taskID: "other", day: "2026-11-11"))
        XCTAssertTrue(tally.record(sessionID: "s4", taskID: task, day: "2026-11-12"))
        XCTAssertEqual(tally.rounds(task: task, day: "2026-11-11"), 2)
        XCTAssertEqual(tally.rounds(task: task.uppercased(), day: "2026-11-11"), 2)
        XCTAssertEqual(tally.rounds(on: "2026-11-11"), 3); XCTAssertEqual(tally.rounds(task: task, day: "2026-11-10"), 0)
        XCTAssertEqual(PomodoroTally.spoken(1), "1 work round"); XCTAssertEqual(PomodoroTally.spoken(3), "3 work rounds")
    }

    func testTheTallyStaysBounded() {
        var tally = PomodoroTally()
        for i in 0..<200 { tally.record(sessionID: "s\(i)", taskID: task, day: String(format: "2026-%02d-%02d", 1 + i / 28 % 12, 1 + i % 28)) }
        XCTAssertLessThanOrEqual(tally.counted.count, PomodoroTally.keepSessions)
        tally.prune()
        XCTAssertLessThanOrEqual(tally.days.count, PomodoroTally.keepDays)
    }

    func testStorageRoundTripsPerAccountAndRejectsDamage() throws {
        let defaults = UserDefaults(suiteName: "pomodoro-storage-" + UUID().uuidString)!
        var cycle = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        cycle.workEnded(settings: settings, at: t0); cycle.startBreak(settings: settings, at: t0)
        PomodoroStorage.saveCycle(cycle, account: "a", defaults: defaults)
        XCTAssertEqual(PomodoroStorage.loadCycle(account: "a", defaults: defaults), cycle)
        XCTAssertNil(PomodoroStorage.loadCycle(account: "b", defaults: defaults), "one slot per account")
        PomodoroStorage.saveCycle(nil, account: "a", defaults: defaults)
        XCTAssertNil(PomodoroStorage.loadCycle(account: "a", defaults: defaults))
        defaults.set(Data("not json".utf8), forKey: PomodoroStorage.cycleKey("a"))
        XCTAssertNil(PomodoroStorage.loadCycle(account: "a", defaults: defaults))
        var bad = cycle; bad.taskID = "not-a-uuid"
        defaults.set(try JSONEncoder().encode(bad), forKey: PomodoroStorage.cycleKey("a"))
        XCTAssertNil(PomodoroStorage.loadCycle(account: "a", defaults: defaults))
        var tally = PomodoroTally(); tally.record(sessionID: "x", taskID: task, day: "2026-11-11")
        PomodoroStorage.saveTally(tally, account: "a", defaults: defaults)
        XCTAssertEqual(PomodoroStorage.loadTally(account: "a", defaults: defaults), tally)
        XCTAssertEqual(PomodoroStorage.loadTally(account: "b", defaults: defaults), PomodoroTally())
    }

    // MARK: The synced row is untouched

    func testTheFocusSessionDocumentStillRejectsExtraFields() throws {
        let s = try session()
        guard case .object(var document) = s.document else { return XCTFail() }
        document["phase"] = .string("work"); document["round"] = .number(2)
        XCTAssertThrowsError(try FocusSession(document: .object(document)), "extra keys are refused, so cycle metadata stays device-local")
    }

    // MARK: Widget overlay

    func testTheWidgetOverlayCarriesPhaseRoundAndTheBreakClock() throws {
        var cycle = PomodoroCycle.start(taskID: task, sessionID: UUID().uuidString)
        let work = PomodoroCycle.widgetOverlay(cycle.widgetDocument(rounds: 4))
        XCTAssertEqual(work?.phase, "work"); XCTAssertEqual(work?.round, 1); XCTAssertEqual(work?.rounds, 4); XCTAssertNil(work?.clock)
        cycle.workEnded(settings: settings, at: t0); cycle.startBreak(settings: settings, at: t0)
        let overlay = try XCTUnwrap(PomodoroCycle.widgetOverlay(cycle.widgetDocument(rounds: 4)))
        XCTAssertEqual(overlay.phase, "break"); XCTAssertEqual(overlay.clock?.durationSeconds, 300)
        XCTAssertNotNil(UUID(uuidString: overlay.breakID))
        XCTAssertNil(PomodoroCycle.widgetOverlay(.object(["phase": .string("work")])))
        XCTAssertNil(PomodoroCycle.widgetOverlay(.object(["phase": .string("boom"), "round": .number(1), "rounds": .number(4), "taskID": .string(task)])))
        XCTAssertNil(PomodoroCycle.widgetOverlay(.string("x")))
    }

    func testThePhaseReachesTheWidgetSnapshot() throws {
        let s = try session()
        var row = Record(["id": .string("current"), "user_id": .string("acct"), "revision": .number(1), "action_id": .string(UUID().uuidString.lowercased()), "state": s.document])
        var cycle = PomodoroCycle.start(taskID: task, sessionID: s.id)
        row["pomodoro"] = cycle.widgetDocument(rounds: 4)
        var open = Record.task(user: "acct"); open["id"] = .string(task); open["title"] = .string("Write the chapter")
        func clock(_ row: Record) throws -> FocusWidgetClock {
            let json = WidgetProjection.focusPayload(row, tasks: [open], account: "acct", conflict: false)
            let data = try TaskfoldJSONEncoder().encode(json)
            return try XCTUnwrap(try TaskfoldJSONDecoder().decode(FocusWidgetSnapshot.self, from: data).clock)
        }
        let work = try clock(row)
        XCTAssertEqual(work.phaseLabel, "Work · 1 of 4"); XCTAssertTrue(work.valid)
        cycle.workEnded(settings: settings, at: t0); cycle.startBreak(settings: settings, at: t0)
        row["pomodoro"] = cycle.widgetDocument(rounds: 4)
        let rest = try clock(row)
        XCTAssertEqual(rest.phaseLabel, "Break"); XCTAssertTrue(rest.valid); XCTAssertEqual(rest.durationSeconds, 300); XCTAssertEqual(rest.title, "Write the chapter")
        // An ordinary session has no phase, and an old widget's JSON without the new keys still decodes.
        row["pomodoro"] = .null
        XCTAssertNil(try clock(row).phaseLabel)
        let legacy = Data(#"{"sessionID":"\#(s.id)","taskID":"\#(task)","durationSeconds":1500,"elapsedMilliseconds":0,"startedAt":1,"changedAt":1,"runningSince":1,"status":"running","taskState":"open"}"#.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(FocusWidgetClock.self, from: legacy))
    }
}
