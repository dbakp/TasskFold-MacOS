import SwiftUI

// Momentum UI shared by name and layout with the other app: the Insights card, the vacation banner and
// the Today streak chip. Everything is drawn from `MomentumSummary` (Core/Momentum.swift); this file only
// presents it. Spec: specs/MOMENTUM.md. No flames, no red: a missed day is a neutral gap, never a penalty.

enum MomentumFormat {
    /// "Oct 20" in the goals' time zone.
    static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
    /// A stored civil day (yyyy-MM-dd) shown as "Oct 20".
    static func shortDate(dayKey: String) -> String {
        guard let date = Dates.parse(dayKey) else { return dayKey }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
    static func weekdayLetter(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter.string(from: date)
    }
    static func vacationLine(_ status: VacationStatus) -> String? {
        guard case .on(_, let until) = status else { return nil }
        return until.map { "On vacation until " + shortDate(dayKey: $0) } ?? "On vacation"
    }
    static func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)" + (count == 1 ? "" : "s") }
}

// MARK: - Today chip model

/// Keeps one personal summary for the Today header. Reads run off the main actor and only when the
/// activity, the goals or the day change, so the header never waits on history.
@MainActor @Observable
final class MomentumModel {
    private(set) var summary: MomentumSummary?
    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var task: Task<Void, Never>?
    private struct Key: Equatable {
        var account: String; var goals: JSON; var activityCount: Int; var lastActivity: String?; var epochCount: Int; var childCount: Int; var day: String
    }

    /// Changes to this value mean the summary may be stale: new activity, new goals, another workspace.
    struct Trigger: Equatable { var account: String; var goals: JSON; var activity: Int; var epoch: Int }
    static func trigger(_ store: Store) -> Trigger {
        Trigger(account: store.userID, goals: store.productivityGoalDocument, activity: store.rows(TaskActivity.table).count, epoch: store.rows(TaskActivity.epochTable).count)
    }

    func refresh(store: Store, now: Date = Date()) {
        guard store.insightsAvailable, let goals = store.productivityGoals, goals.dailyTarget > 0 else { task?.cancel(); key = nil; summary = nil; return }
        let activity = store.rows(TaskActivity.table), epoch = store.rows(TaskActivity.epochTable), children = store.childActivityHistory
        let next = Key(account: store.userID, goals: goals.document, activityCount: activity.count, lastActivity: activity.last?.id, epochCount: epoch.count,
                       childCount: children.rows?.count ?? 0, day: TaskPlanner.dayKey(now, calendar: goals.calendar))
        guard next != key else { return }
        task?.cancel()
        let account = store.userID
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let value = await Task.detached(priority: .utility) {
                Momentum.summary(account: account, activity: activity, epoch: epoch, goals: goals, children: children, now: now)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.summary = value; self.key = next
        }
    }
}

// MARK: - Streak chip

/// "7-day streak", shown on Today only when the streak is at least two days and goals are on.
struct StreakChip: View {
    let summary: MomentumSummary
    let open: () -> Void
    var body: some View {
        if let text = summary.chipText {
            let paused = summary.vacation != .off
            Button(action: open) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: paused ? "moon.zzz.fill" : "bolt.fill").font(DS.Font.chip).accessibilityHidden(true)
                    Text(text).font(DS.Font.chip).lineLimit(1)
                }
                .foregroundStyle(DS.Palette.accent)
                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs + DS.Space.xxs)
                .background(DS.Palette.accent.opacity(0.16), in: Capsule())
                #if os(iOS)
                .frame(minHeight: DS.Size.rowMinHeight)
                #endif
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityHint("Opens Insights")
            .accessibilityIdentifier("streakChip")
            #if os(macOS)
            .help("Open Insights")
            #endif
        }
    }
}

// MARK: - Card

struct MomentumCard: View {
    let summary: MomentumSummary
    let calendar: Calendar
    let setGoal: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 92
    @State private var shown = false
    private var large: Bool { textSize.isAccessibilitySize }
    private var animation: Animation? { Motion.respecting(reduceMotion, Motion.settle) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Momentum").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary).accessibilityAddTraits(.isHeader)
            let arrangement = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.l)) : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.xl))
            arrangement {
                ring
                levelBlock
            }
            if summary.hasDailyGoal {
                stats
                strip
            } else {
                noGoal
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.xl + DS.Space.xs, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("momentumCard")
        .onAppear { withAnimation(animation) { shown = true } }
    }

    // MARK: Score ring

    private var ring: some View {
        let score = summary.score
        let line = max(6, ringSize * 0.09)
        return ZStack {
            Circle().inset(by: line / 2).stroke(DS.Palette.accent.opacity(0.16), lineWidth: line)
            Circle().inset(by: line / 2).trim(from: 0, to: shown ? Double(score ?? 0) / 100 : 0)
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(animation, value: score)
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "–").font(.system(size: ringSize * 0.34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("of 100").font(.caption2).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }.padding(line + DS.Space.xs).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "Momentum \($0) of 100" } ?? "Momentum not available yet")
        .accessibilityIdentifier("momentumScore")
    }

    // MARK: Level

    private var levelBlock: some View {
        let level = summary.level
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(level.name).font(.system(.title3, design: .rounded).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            ProgressCapsule(progress: level.progress, animation: animation, shown: shown)
            Text(level.next.map { "\(level.remaining ?? 0) to \($0.name)" } ?? "Highest level reached")
                .font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Text(MomentumFormat.plural(summary.totalCompletions, "completion") + " recorded").font(.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level.name)")
        .accessibilityValue((level.next.map { "\(level.remaining ?? 0) more to reach \($0.name). " } ?? "Highest level. ") + MomentumFormat.plural(summary.totalCompletions, "completion") + " recorded")
        .accessibilityIdentifier("momentumLevel")
    }

    // MARK: Streaks

    private var stats: some View {
        let arrangement = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.m)) : AnyLayout(HStackLayout(alignment: .top, spacing: DS.Space.l))
        let paused = summary.vacation != .off
        return arrangement {
            stat("Streak", value: summary.dailyStreak.length, unit: "day", icon: paused ? "moon.zzz.fill" : "bolt.fill",
                 caption: paused ? "Paused" : summary.dailyStreak.since.map { "since " + MomentumFormat.shortDate($0, calendar: calendar) }, id: "momentumStreak")
            stat("Longest", value: summary.longestDailyStreak.length, unit: "day", icon: nil,
                 caption: summary.longestDailyStreak.since.map { "since " + MomentumFormat.shortDate($0, calendar: calendar) }, id: "momentumLongest")
            if summary.hasWeeklyGoal {
                stat("Weekly", value: summary.weeklyStreak.length, unit: "week", icon: nil,
                     caption: summary.weeklyStreak.since.map { "since " + MomentumFormat.shortDate($0, calendar: calendar) }, id: "momentumWeekly")
            }
        }
    }

    private func stat(_ title: String, value: Int, unit: String, icon: String?, caption: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title).font(.caption).foregroundStyle(DS.Palette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                if let icon { Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(DS.Palette.accent).accessibilityHidden(true) }
                Text("\(value)").font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(value == 1 ? unit : unit + "s").font(.footnote).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
            if let caption { Text(caption).font(.caption2).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(MomentumFormat.plural(value, unit) + (caption.map { ", " + $0 } ?? ""))
        .accessibilityIdentifier(id)
    }

    // MARK: Seven days

    private var strip: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Last 7 days").font(.caption).foregroundStyle(DS.Palette.textSecondary)
            if large {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(summary.week) { day in
                        HStack(spacing: DS.Space.m) {
                            MomentumDayCell(day: day).frame(width: 44)
                            Text(MomentumFormat.shortDate(day.date, calendar: calendar) + " · " + Self.value(day)).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        }.accessibilityElement(children: .ignore).accessibilityLabel(MomentumFormat.shortDate(day.date, calendar: calendar)).accessibilityValue(Self.value(day))
                    }
                }
            } else {
                HStack(spacing: DS.Space.s) {
                    ForEach(summary.week) { day in
                        VStack(spacing: DS.Space.xs) {
                            MomentumDayCell(day: day)
                            Text(MomentumFormat.weekdayLetter(day.date, calendar: calendar)).font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(MomentumFormat.shortDate(day.date, calendar: calendar))
                        .accessibilityValue(Self.value(day))
                    }
                }
            }
        }.accessibilityIdentifier("momentumWeek")
    }

    static func value(_ day: MomentumDay) -> String {
        let progress = day.target.map { "\(day.count) of \($0)" } ?? "\(day.count)"
        switch day.state {
        case .met: return "Goal met, " + progress
        case .missed: return "Goal not met, " + progress
        case .pending: return "In progress, " + progress
        case .rest: return "Rest day"
        case .vacation: return "On vacation"
        case .untracked: return "No recorded history"
        case .noGoal: return "No daily goal"
        }
    }

    private var noGoal: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Set a daily goal to start a streak and see your Momentum build.").font(.subheadline).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button(action: setGoal) { Text("Set a daily goal").frame(minHeight: DS.Size.rowMinHeight - DS.Space.m).contentShape(.rect) }
                .buttonStyle(.bordered).accessibilityIdentifier("setDailyGoalFromMomentum")
        }
    }
}

/// How the person's estimates compare with the time tasks took (ActualTime.swift). Personal and calm: one sentence
/// and its basis, no score, no streak. Drawn only once there are enough finished tasks to say something honest.
struct EstimateInsightCard: View {
    let accuracy: EstimateAccuracy
    var body: some View {
        if let message = accuracy.message {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Estimates").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary).accessibilityAddTraits(.isHeader)
                Text(message).font(.system(.title3, design: .rounded).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let detail = accuracy.detail {
                    Text(detail).font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.xl + DS.Space.xs, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Estimates")
            .accessibilityValue(message + ". " + (accuracy.detail ?? ""))
            .accessibilityIdentifier("estimateInsightCard")
        }
    }
}

/// A thin capsule track with a rounded fill.
private struct ProgressCapsule: View {
    let progress: Double
    let animation: Animation?
    let shown: Bool
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.accent.opacity(0.16))
                Capsule().fill(DS.Palette.accent).frame(width: max(progress > 0 ? 6 : 0, proxy.size.width * (shown ? progress : 0)))
                    .animation(animation, value: progress)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// One day in the seven-day strip. Shape and symbol differ by state, not colour alone.
struct MomentumDayCell: View {
    let day: MomentumDay
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
        ZStack {
            switch day.state {
            case .met:
                shape.fill(DS.Palette.accent)
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
            case .pending:
                shape.strokeBorder(DS.Palette.accent, lineWidth: 1.5)
            case .missed:
                shape.fill(DS.Palette.surfaceSunken)
            case .rest:
                shape.strokeBorder(DS.Palette.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            case .vacation:
                shape.fill(DS.Palette.accentSecondary.opacity(0.22))
                Image(systemName: "moon.zzz.fill").font(.caption2).foregroundStyle(DS.Palette.accentSecondary)
            case .untracked, .noGoal:
                shape.fill(DS.Palette.surfaceSunken.opacity(0.5))
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

// MARK: - Vacation banner

/// Where goal progress is shown: "On vacation until Oct 20", with a way back.
struct VacationBanner: View {
    let status: VacationStatus
    let turnOff: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        if let line = MomentumFormat.vacationLine(status) {
            let arrangement = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.m)) : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.m))
            arrangement {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(DS.Palette.accentSecondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(line).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vacationStatus")
                        Text("Streaks are paused and goal celebrations stay quiet.").font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !textSize.isAccessibilitySize { Spacer(minLength: DS.Space.s) }
                Button(action: turnOff) { Text("Turn off").frame(minHeight: DS.Size.rowMinHeight - DS.Space.m).contentShape(.rect) }
                    .buttonStyle(.bordered).accessibilityIdentifier("turnOffVacation")
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.accentSecondary.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("vacationBanner")
        }
    }
}
