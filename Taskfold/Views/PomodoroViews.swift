import SwiftUI

// Pomodoro UI shared by name and layout with the other app: the mode control, the settings, the round dots,
// the break card and the per-task count. Drawn from `PomodoroCycle` (Core/Pomodoro.swift). Calm by design: a
// finished work interval asks "Break time", never alarms, and auto-start is off until the person turns it on.

enum PomodoroFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(ceil(seconds))); return String(format: "%02d:%02d", value / 60, value % 60)
    }
    static func minutes(_ value: Int) -> String { "\(value) \(value == 1 ? "minute" : "minutes")" }
}

/// Single (today's behaviour) or Pomodoro.
struct PomodoroModeControl: View {
    let mode: PomodoroMode
    let choose: (PomodoroMode) -> Void
    var body: some View {
        Picker("Focus mode", selection: Binding(get: { mode }, set: choose)) {
            ForEach(PomodoroMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel("Focus mode").accessibilityIdentifier("focusMode")
    }
}

/// "3" with a timer glyph, never a fruit. Reads as "3 work rounds today on this task".
struct PomodoroCount: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "timer").font(DS.Font.chip).foregroundStyle(DS.Palette.accent).labelStyle(.titleAndIcon)
                .accessibilityElement(children: .ignore).accessibilityLabel(PomodoroTally.spoken(count) + " today")
                .accessibilityIdentifier("pomodoroCount")
        }
    }
}

/// One dot per round of the cycle: done, current, still to come.
struct PomodoroRoundDots: View {
    let cycle: PomodoroCycle
    let rounds: Int
    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(1...rounds, id: \.self) { round in
                let finished = round < cycle.round || (cycle.phase.isBreak && round == cycle.round) || (cycle.phase == .work && cycle.stage == .ready && round < cycle.round)
                ZStack {
                    if finished { Circle().fill(DS.Palette.accent) }
                    else if round == cycle.round { Circle().strokeBorder(DS.Palette.accent, lineWidth: 2) }
                    else { Circle().strokeBorder(DS.Palette.textTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3])) }
                }.frame(width: 12, height: 12)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Round \(cycle.round) of \(rounds)")
        .accessibilityIdentifier("pomodoroRounds")
    }
}

/// The editable rhythm, stored on this device.
struct PomodoroSettingsCard: View {
    let settings: PomodoroSettings
    let change: (PomodoroSettings) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            row("Work", value: settings.workMinutes, range: PomodoroSettings.workRange, step: 5, id: "pomodoroWork") { var next = settings; next.workMinutes = $0; change(next) }
            row("Short break", value: settings.shortBreakMinutes, range: PomodoroSettings.shortBreakRange, step: 1, id: "pomodoroShort") { var next = settings; next.shortBreakMinutes = $0; change(next) }
            row("Long break", value: settings.longBreakMinutes, range: PomodoroSettings.longBreakRange, step: 5, id: "pomodoroLong") { var next = settings; next.longBreakMinutes = $0; change(next) }
            Stepper(value: Binding(get: { settings.roundsBeforeLongBreak }, set: { var next = settings; next.roundsBeforeLongBreak = $0; change(next) }), in: PomodoroSettings.roundsRange) {
                Text("Long break after \(settings.roundsBeforeLongBreak) rounds").fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 44).accessibilityIdentifier("pomodoroRoundsStepper")
            Toggle("Start the next interval automatically", isOn: Binding(get: { settings.autoStart }, set: { var next = settings; next.autoStart = $0; change(next) }))
                .frame(minHeight: 44).accessibilityIdentifier("pomodoroAutoStart")
            Text("Saved on this device. Only the work timer syncs, as an ordinary Focus session; breaks stay here.").font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("pomodoroSettings")
    }
    private func row(_ title: String, value: Int, range: ClosedRange<Int>, step: Int, id: String, set: @escaping (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: range, step: step) {
            Text("\(title): \(PomodoroFormat.minutes(value))").fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 44).accessibilityLabel(title).accessibilityValue(PomodoroFormat.minutes(value)).accessibilityIdentifier(id)
    }
}

/// Break time, the break clock, and the way back to work.
struct PomodoroBreakCard: View {
    let cycle: PomodoroCycle
    let rounds: Int
    let settings: PomodoroSettings
    let taskTitle: String?
    let count: Int
    let now: Date
    let startBreak: () -> Void
    let skip: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let backToWork: () -> Void
    let end: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var waitingForWork: Bool { cycle.phase == .work && cycle.stage == .ready }
    private var heading: String {
        if waitingForWork { return "Back to work" }
        switch cycle.stage {
        case .ready: return "Break time"
        case .paused: return cycle.phase.title + " · Paused"
        case .running: return cycle.phase.title
        }
    }
    private var tint: Color { waitingForWork ? DS.Palette.accent : DS.Palette.accentSecondary }
    private var detail: String {
        if waitingForWork { return "Round \(cycle.round) of \(rounds) is next. Start it when you are ready." }
        if cycle.stage == .ready {
            let minutes = settings.minutes(for: cycle.phase)
            return (cycle.phase == .longBreak ? "Round \(rounds) of \(rounds) done. " : "Round \(cycle.round) of \(rounds) done. ") + "Take a \(PomodoroFormat.minutes(minutes))" + (cycle.phase == .longBreak ? " long break." : " break.")
        }
        return "Step away for a moment. Your task is waiting."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack {
                Label(heading, systemImage: waitingForWork ? "play.circle" : "cup.and.saucer").font(.headline).foregroundStyle(tint)
                    .accessibilityIdentifier("pomodoroPhase")
                Spacer(minLength: 0)
                PomodoroCount(count: count)
            }
            if let taskTitle { Text(taskTitle).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("focusTaskTitle") }
            PomodoroRoundDots(cycle: cycle, rounds: rounds)
            if let clock = cycle.clock, cycle.stage != .ready, cycle.phase.isBreak {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Time remaining").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    Text(PomodoroFormat.clock(clock.remaining(at: now)))
                        .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold))
                        .accessibilityLabel(cycle.spoken(rounds: rounds, remaining: clock.remaining(at: now)))
                        .accessibilityIdentifier("pomodoroRemaining")
                }
                ProgressView(value: Double(clock.elapsed(at: now)), total: Double(clock.durationSeconds * 1000)).tint(tint)
                    .accessibilityHidden(true)
            }
            Text(detail).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(DS.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("pomodoroCard")
    }

    @ViewBuilder private var actions: some View {
        if waitingForWork {
            Button(action: backToWork) { Label("Back to work", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("pomodoroBackToWork")
        } else if cycle.stage == .ready {
            Button(action: startBreak) { Label("Start break", systemImage: "cup.and.saucer.fill").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("pomodoroStartBreak")
            Button(action: skip) { Text("Skip").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).accessibilityIdentifier("pomodoroSkip")
        } else {
            Button(action: cycle.stage == .paused ? resume : pause) {
                Label(cycle.stage == .paused ? "Resume break" : "Pause break", systemImage: cycle.stage == .paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("pomodoroPauseResume")
            Button(action: skip) { Text("Skip break").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).accessibilityIdentifier("pomodoroSkip")
        }
        Button(action: end) { Text("End Pomodoro").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderless).accessibilityIdentifier("pomodoroEnd")
    }
}

#if DEBUG
/// Launch fixture for Pomodoro captures: `--pomodoro-fixture=work|break|ready` next to `--preview` or `--uitesting`.
/// A task, a running Focus session through the normal row, and the device-local cycle and tally. Local data only.
enum PomodoroFixture {
    static func variant(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        arguments.first { $0.hasPrefix("--pomodoro-fixture=") }.map { String($0.dropFirst("--pomodoro-fixture=".count)) }
    }
    static let taskID = "f1b00000-0000-4000-8000-000000000001"
    static func apply(to snapshot: inout Snapshot, account: String, today: String, calendar: Calendar, variant: String, now: Date = Date()) -> (settings: PomodoroSettings, cycle: PomodoroCycle?, tally: PomodoroTally) {
        var task = Record.task(user: account, date: Dates.parse(today, calendar: calendar))
        task["id"] = .string(taskID); task["title"] = .string("Draft the launch announcement"); task["priority"] = .number(2)
        snapshot.tables["tasks", default: []].append(task)
        let settings = PomodoroSettings()
        var tally = PomodoroTally()
        tally.record(sessionID: "fixture-1", taskID: taskID, day: today); tally.record(sessionID: "fixture-2", taskID: taskID, day: today)
        var cycle: PomodoroCycle?
        switch variant {
        case "break", "ready":
            // Round 2 of 4 just finished: the work session ended 108 seconds ago.
            if let session = try? FocusSession(taskID: taskID, minutes: 25, now: now.addingTimeInterval(-25 * 60 - 108)),
               let start = try? FocusSessionChange.make(session, current: nil, account: account) {
                snapshot.apply(start)
                var next = PomodoroCycle(taskID: taskID, round: 2, phase: .work, stage: .running, sessionID: session.id, clock: nil)
                next.workEnded(settings: settings, at: now.addingTimeInterval(-108))
                if variant == "break" { next.startBreak(settings: settings, at: now.addingTimeInterval(-108)) }
                cycle = next
            }
        default:
            // Round 3 of 4, eleven minutes in: 14 minutes left.
            if let session = try? FocusSession(taskID: taskID, minutes: 25, now: now.addingTimeInterval(-11 * 60)),
               let start = try? FocusSessionChange.make(session, current: nil, account: account) {
                snapshot.apply(start)
                cycle = PomodoroCycle(taskID: taskID, round: 3, phase: .work, stage: .running, sessionID: session.id, clock: nil)
            }
        }
        return (settings, cycle, tally)
    }
}
#endif
