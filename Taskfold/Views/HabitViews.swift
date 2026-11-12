import SwiftUI

// Habits UI shared by name and layout with the other app: the habit card, the seven-day row, the twelve-week
// heatmap, the detail and the Today chip. Everything is drawn from `HabitReading` (Core/Habits.swift). A missed day
// is a neutral gap, never red and never a penalty; shape and symbol, not colour alone, tell the states apart.

enum HabitFormat {
    static func day(_ key: String) -> String { MomentumFormat.shortDate(dayKey: key) }
    static func streak(_ streak: HabitStreak) -> String { "\(streak.length)-day streak" }
    static func since(_ streak: HabitStreak) -> String? { streak.since.map { "since " + day($0) } }
    static func monthLine(_ reading: HabitReading) -> String {
        guard let rate = reading.monthRate else { return "This month: not enough days yet" }
        return "This month \(rate)% · \(reading.monthDone) of \(reading.monthScheduled)"
    }
    static func completion(_ item: HabitCompletion, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        let time = DateFormatter(); time.calendar = calendar; time.timeZone = calendar.timeZone; time.timeStyle = .short; time.dateStyle = .none
        return formatter.string(from: Dates.parse(item.day, calendar: calendar) ?? item.completedAt) + " · " + time.string(from: item.completedAt)
    }
}

// MARK: - Day cells

/// One day of the seven-day row. Done is a filled mark; today pending is an open ring; a day the rule skips is a dashed outline.
struct HabitDayDot: View {
    let day: HabitDay
    var body: some View {
        ZStack {
            switch day.state {
            case .done:
                Circle().fill(DS.Palette.accent)
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
            case .pending:
                Circle().strokeBorder(DS.Palette.accent, lineWidth: 2)
            case .missed:
                Circle().fill(DS.Palette.surfaceSunken)
                Circle().fill(DS.Palette.textTertiary).frame(width: 5, height: 5)
            case .notScheduled:
                Circle().strokeBorder(DS.Palette.textTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            case .vacation:
                Circle().fill(DS.Palette.accentSecondary.opacity(0.22))
                Image(systemName: "moon.zzz.fill").font(.caption2).foregroundStyle(DS.Palette.accentSecondary)
            case .untracked:
                Circle().fill(DS.Palette.surfaceSunken.opacity(0.45))
            case .future:
                Circle().strokeBorder(DS.Palette.separator, lineWidth: 0.5)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// The last seven days, oldest first, with a weekday letter under each.
struct HabitWeekRow: View {
    let days: [HabitDay]
    let calendar: Calendar
    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                VStack(spacing: DS.Space.xs) {
                    HabitDayDot(day: day)
                    Text(MomentumFormat.weekdayLetter(day.date, calendar: calendar)).font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                }.frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last seven days")
        .accessibilityValue(days.map { MomentumFormat.shortDate($0.date, calendar: calendar) + " " + $0.state.spoken }.joined(separator: ", "))
        .accessibilityIdentifier("habitWeek")
    }
}

// MARK: - Card

struct HabitCard: View {
    let reading: HabitReading
    let calendar: Calendar
    var selected = false
    let checkIn: () -> Void
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    private var checkLabel: String {
        reading.doneToday ? "Done today" : reading.canCheckIn ? "Check in" : reading.occurrenceID == nil ? "Series finished" : "Not scheduled today"
    }
    private var checkButton: some View {
        Button(action: checkIn) {
            ZStack {
                if reading.doneToday {
                    Circle().fill(DS.Palette.accent)
                    Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                } else if reading.canCheckIn {
                    Circle().strokeBorder(DS.Palette.accent, lineWidth: 2)
                } else {
                    Circle().strokeBorder(DS.Palette.textTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            .frame(width: 30, height: 30)
            .frame(minWidth: 44, minHeight: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).allowsHitTesting(reading.canCheckIn)
        .accessibilityLabel(checkLabel).accessibilityHint(reading.canCheckIn ? "Completes today's occurrence of " + reading.title : "")
        .accessibilityIdentifier("habitCheckIn-" + reading.habitID)
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            let arrangement = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DS.Space.m))
            arrangement {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(reading.title).font(.body.weight(.semibold)).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(reading.schedule).font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if !textSize.isAccessibilitySize { Spacer(minLength: DS.Space.s) }
                VStack(alignment: textSize.isAccessibilitySize ? .leading : .trailing, spacing: DS.Space.xxs) {
                    if reading.currentStreak.length > 0 {
                        Label(HabitFormat.streak(reading.currentStreak), systemImage: "bolt.fill").font(DS.Font.chip).foregroundStyle(DS.Palette.accent).labelStyle(.titleAndIcon)
                    } else {
                        Text("No streak yet").font(DS.Font.chip).foregroundStyle(DS.Palette.textTertiary)
                    }
                    if reading.bestStreak.length > 0 { Text("Best \(reading.bestStreak.length)").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary) }
                }
            }
            HabitWeekRow(days: reading.week, calendar: calendar)
            HStack {
                Text(HabitFormat.monthLine(reading)).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.textTertiary).accessibilityHidden(true)
            }
        }.contentShape(Rectangle())
    }
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            checkButton
            Button(action: open) { summary }.buttonStyle(.plain)
                .accessibilityLabel(Habits.spoken(reading)).accessibilityHint("Shows the history")
                .accessibilityIdentifier("habitOpen-" + reading.habitID)
        }
        .padding(DS.Space.m)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(selected ? DS.Palette.accent : DS.Palette.separator.opacity(0.6), lineWidth: selected ? 2 : 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("habitCard-" + reading.habitID)
    }
}

// MARK: - Heatmap

struct HabitHeatCell: View {
    let day: HabitDay
    var size: CGFloat = 16
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            switch day.state {
            case .done: shape.fill(DS.Palette.accent)
            case .pending: shape.strokeBorder(DS.Palette.accent, lineWidth: 1.5)
            case .missed: shape.fill(DS.Palette.surfaceSunken)
            case .notScheduled: shape.strokeBorder(DS.Palette.textTertiary.opacity(0.45), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            case .vacation: shape.fill(DS.Palette.accentSecondary.opacity(0.3))
            case .untracked: shape.fill(DS.Palette.surfaceSunken.opacity(0.35))
            case .future: shape.strokeBorder(DS.Palette.separator.opacity(0.5), lineWidth: 0.5)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Twelve weeks, one column per week, a GitHub-style grid. Each week reads as one VoiceOver element.
struct HabitHeatmap: View {
    let weeks: [HabitHeatWeek]
    let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var textSize
    private var size: CGFloat { textSize.isAccessibilitySize ? 24 : 22 }
    private var weekdayLabels: [String] {
        guard let first = weeks.first else { return [] }
        return first.days.map { MomentumFormat.weekdayLetter($0.date, calendar: calendar) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.xs) {
                VStack(spacing: 3) {
                    ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, letter in
                        Text(letter).font(.caption2).foregroundStyle(DS.Palette.textTertiary).frame(width: 12, height: size)
                    }
                }.accessibilityHidden(true)
                HStack(spacing: 3) {
                    ForEach(weeks) { week in
                        VStack(spacing: 3) { ForEach(week.days) { HabitHeatCell(day: $0, size: size) } }
                            .accessibilityElement(children: .ignore).accessibilityLabel(week.summary)
                    }
                }
            }
            legend
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Last 12 weeks")
        .accessibilityIdentifier("habitHeatmap")
    }
    private var legend: some View {
        HStack(spacing: DS.Space.m) {
            ForEach([(HabitDayState.done, "Done"), (.missed, "Missed"), (.notScheduled, "Not scheduled"), (.vacation, "Vacation")], id: \.1) { state, name in
                HStack(spacing: DS.Space.xs) {
                    HabitHeatCell(day: HabitDay(id: name, date: .distantPast, state: state), size: 12)
                    Text(name).font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }.accessibilityHidden(true)
    }
}

// MARK: - Detail

struct HabitDetailContent: View {
    let reading: HabitReading
    let calendar: Calendar
    let checkIn: () -> Void
    let openTask: (() -> Void)?
    let stopTracking: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(reading.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text(reading.schedule).font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary)
                if let since = reading.trackedSince, reading.heatmap.first.map({ since > $0.id }) == true {
                    Text("History since " + HabitFormat.day(since)).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityIdentifier("habitHistorySince")
                }
            }
            let arrangement = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s)) : AnyLayout(HStackLayout(alignment: .top, spacing: DS.Space.s))
            arrangement {
                tile("Streak", reading.currentStreak.length, caption: HabitFormat.since(reading.currentStreak), id: "habitStreak")
                tile("Best", reading.bestStreak.length, caption: HabitFormat.since(reading.bestStreak), id: "habitBest")
                rateTile
            }
            if reading.canCheckIn {
                Button(action: checkIn) { Label("Check in for today", systemImage: "checkmark.circle").frame(maxWidth: .infinity, minHeight: 36) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("habitDetailCheckIn")
            } else if reading.doneToday {
                Label("Done today", systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.accent).font(DS.Font.sectionHeader).accessibilityIdentifier("habitDoneToday")
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Last 12 weeks").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary).accessibilityAddTraits(.isHeader)
                HabitHeatmap(weeks: reading.heatmap, calendar: calendar)
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Recent completions").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary).accessibilityAddTraits(.isHeader)
                if reading.recent.isEmpty {
                    Text("Nothing checked in yet. Completing today's task counts as a check-in.").font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(reading.recent.prefix(10)) { item in
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.accent).accessibilityHidden(true)
                            Text(HabitFormat.completion(item, calendar: calendar)).font(DS.Font.taskNote)
                            Spacer(minLength: 0)
                        }.accessibilityElement(children: .combine)
                    }
                }
            }.accessibilityIdentifier("habitRecent")
            HStack(spacing: DS.Space.m) {
                if let openTask { Button("Open task", systemImage: "arrow.up.forward.square", action: openTask).accessibilityIdentifier("habitOpenTask") }
                Button("Stop tracking", systemImage: "minus.circle", role: .destructive, action: stopTracking).accessibilityIdentifier("habitStopTracking")
            }.buttonStyle(.bordered)
        }
    }
    private func tile(_ title: String, _ value: Int, caption: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            Text("\(value)").font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
            Text(caption ?? (value == 1 ? "day" : "days")).font(.caption2).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.m)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .accessibilityElement(children: .ignore).accessibilityLabel(title + ", " + "\(value) \(value == 1 ? "day" : "days")" + (caption.map { ", " + $0 } ?? ""))
        .accessibilityIdentifier(id)
    }
    private var rateTile: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text("This month").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            Text(reading.monthRate.map { "\($0)%" } ?? "–").font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
            Text(reading.monthScheduled == 0 ? "no days judged yet" : "\(reading.monthDone) of \(reading.monthScheduled) days").font(.caption2).foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.m)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .accessibilityElement(children: .ignore).accessibilityLabel("This month").accessibilityValue(HabitFormat.monthLine(reading))
        .accessibilityIdentifier("habitRate")
    }
}

// MARK: - Empty state and Today chip

struct HabitsEmptyState: View {
    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "circle.hexagongrid").font(.system(size: 38)).foregroundStyle(DS.Palette.textTertiary).accessibilityHidden(true)
            Text("No habits yet").font(.title3.weight(.semibold))
            Text("Open a repeating task and turn on Track as habit. Every check-in is just completing today's task.")
                .font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420).padding(DS.Space.xxl).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine).accessibilityIdentifier("habitsEmpty")
    }
}

/// "Habits 2/4" in the Today header, shown only while at least one habit is due today.
struct HabitsChip: View {
    let summary: Habits.TodaySummary
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "circle.hexagongrid").font(DS.Font.chip).accessibilityHidden(true)
                Text(summary.label).font(DS.Font.chip).lineLimit(1)
            }
            .foregroundStyle(DS.Palette.accentSecondary)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs + DS.Space.xxs)
            .background(DS.Palette.accentSecondary.opacity(0.16), in: Capsule())
            #if os(iOS)
            .frame(minHeight: DS.Size.rowMinHeight)
            #endif
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Habits, \(summary.done) of \(summary.total) done today").accessibilityHint("Opens Habits")
        .accessibilityIdentifier("habitsChip")
        #if os(macOS)
        .help("Open Habits")
        #endif
    }
}

// MARK: - Launch fixture

#if DEBUG
/// Screenshot and UI-test data for Habits. Launch with `--habits-fixture` next to `--preview` or `--uitesting`.
/// Four habits whose histories are produced through the real completion path, all keyed on the Store's civil today:
/// a daily reading habit done today (12-day streak), a weekday habit (still to do today), a Mon/Wed/Fri habit and a
/// daily habit that missed yesterday. Local fixture data only; it only rewrites the local fixture snapshot.
enum HabitFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--habits-fixture") }

    static func apply(to snapshot: inout Snapshot, account: String, today: String, calendar: Calendar) {
        func key(_ offset: Int) -> String {
            let base = Dates.parse(today, calendar: calendar)!
            return TaskPlanner.dayKey(calendar.date(byAdding: .day, value: offset, to: base)!, calendar: calendar)
        }
        func instant(_ offset: Int) -> Date { calendar.date(byAdding: .hour, value: 8, to: Dates.parse(key(offset), calendar: calendar)!)! }
        let specs: [(id: String, title: String, days: [Int]?, history: Int, skipYesterday: Bool, checkToday: Bool)] = [
            ("f1a00000-0000-4000-8000-000000000001", "Read 20 pages", nil, 70, false, true),
            ("f1a00000-0000-4000-8000-000000000002", "Stretch for ten minutes", [1, 2, 3, 4, 5], 70, false, false),
            ("f1a00000-0000-4000-8000-000000000003", "Water the plants", [1, 3, 5], 70, false, false),
            ("f1a00000-0000-4000-8000-000000000004", "Write in the journal", nil, 40, true, false)
        ]
        var all: [Record] = []
        for (index, spec) in specs.enumerated() {
            var root = Record.task(user: account, createdAt: TaskActivity.stamp(instant(-spec.history)))
            root["id"] = .string(spec.id); root["title"] = .string(spec.title); root["is_recurring"] = .bool(true)
            root["due_date"] = .string(key(-spec.history))
            var pattern: [String: JSON] = ["type": .string(spec.days == nil ? "daily" : "weekly"), "interval": .number(1)]
            if let days = spec.days { pattern["daysOfWeek"] = .array(days.map { .number(Double($0)) }) }
            root["recurrence_pattern"] = .object(pattern)
            var work = Snapshot(); work.tables["tasks"] = [root]
            // A deterministic rhythm: an occasional gap early on, then a clean recent run (twelve days for the first habit).
            let last = spec.checkToday ? 0 : -1
            let cleanFrom = spec.title == "Read 20 pages" ? -11 : -8
            for offset in stride(from: -spec.history, through: last, by: 1) {
                let tasks = work.tables["tasks"] ?? []
                guard let open = tasks.filter({ !$0.completed }).min(by: { $0.string("due_date") < $1.string("due_date") }) else { break }
                guard String(open.string("due_date").prefix(10)) <= key(offset) else { continue }   // not a scheduled day yet
                let gap = offset == cleanFrom - 1 || (offset < cleanFrom - 1 && (offset + index * 3) % 9 == 0)
                if gap || (spec.skipYesterday && offset == -1) { continue }
                for change in TaskCompletion.complete(open, tasks: tasks, at: instant(offset), calendar: calendar, account: account) { work.apply(change) }
            }
            all += work.tables["tasks"] ?? []
        }
        snapshot.tables["tasks", default: []].append(contentsOf: all)
        snapshot.tables[Habits.table, default: []].removeAll { $0.id == Habits.key }
        // `--habits-untracked` leaves the series as plain repeating tasks, so a UI test can turn tracking on itself.
        if ProcessInfo.processInfo.arguments.contains("--habits-untracked") { return }
        snapshot.tables[Habits.table, default: []].append(Record(["id": .string(Habits.key), "user_id": .string(account), "ids": .array(specs.map { .string($0.id) })]))
    }
}
#endif
