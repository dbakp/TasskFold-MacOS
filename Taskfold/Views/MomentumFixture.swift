#if DEBUG
import Foundation

/// Screenshot and UI-test data for Momentum. Launch with `--momentum-fixture=<variant>` next to `--preview` or `--uitesting`:
/// - `streak`: a nine-day streak ending with a finished today, mid-way to the next level.
/// - `vacation`: the same history with vacation covering the last three days.
/// - `milestone`: six streak days and two of three done today; the next completion reaches goal and a 7-day streak.
/// - `milestone-solo`: as `milestone`, with today's goal toast already used, so the streak milestone shows alone.
/// Goals: three a day, twelve a week, Monday to Friday. Never touches real data; it only rewrites the local fixture snapshot.
enum MomentumFixture {
    static func variant(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        arguments.first { $0.hasPrefix("--momentum-fixture=") }.map { String($0.dropFirst("--momentum-fixture=".count)) }
    }

    static func apply(to snapshot: inout Snapshot, account: String, variant: String, now: Date = Date()) {
        var goals = try! ProductivityGoals()
        goals.dailyTarget = 3; goals.weeklyTarget = 12; goals.activeWeekdays = Set(2...6); goals.weekStart = 2; goals.timeZone = TimeZone.current.identifier
        let calendar = goals.calendar, today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        let vacation = variant == "vacation"
        if vacation {
            goals.vacationFrom = TaskPlanner.dayKey(day(-2), calendar: calendar)
            goals.vacationUntil = TaskPlanner.dayKey(day(5), calendar: calendar)
        }
        let milestone = variant.hasPrefix("milestone")
        // Newest first: the days that can carry a streak.
        var active: [Int] = []
        for offset in stride(from: 0, through: -59, by: -1) {
            if vacation && offset >= -2 { continue }
            if goals.activeWeekdays.contains(calendar.component(.weekday, from: day(offset))) { active.append(offset) }
        }
        let streakDays = milestone ? 7 : 9
        let epoch = day(-60)
        var counts: [Int: Int] = [:]
        for (index, offset) in active.enumerated() {
            if index == streakDays || index == streakDays + 6 || index == streakDays + 14 { counts[offset] = index == streakDays ? 1 : 0; continue }
            counts[offset] = index == 0 && milestone ? 2 : 3 + (index % 3 == 0 ? 1 : 0)
        }
        var tasks: [Record] = [], serial = 0
        var work = Snapshot()
        for offset in counts.keys.sorted() {
            for k in 0..<(counts[offset] ?? 0) {
                serial += 1
                var row = Record.task(user: account)
                row["id"] = .string(String(format: "f1750000-0000-4000-8000-%012d", serial))
                row["title"] = .string("Finished work \(serial)")
                row["created_at"] = .string(TaskActivity.stamp(epoch))
                let instant = offset == 0 ? now.addingTimeInterval(-Double(k + 1) * 600) : day(offset).addingTimeInterval(9 * 3600 + Double(k) * 2700)
                work.tables["tasks", default: []].append(row)
                let before = row
                let change = Mutation(table: "tasks", recordID: before.id, method: "PATCH", fields: ["completed": .bool(true), "completed_at": .string(TaskActivity.stamp(instant))])
                work.apply(change)
                let after = work.tables["tasks"]!.first { $0.id == before.id }
                TaskActivity.recordLocal(change, before: before, after: after, snapshot: &work, account: account, now: instant)
                tasks.append(after ?? row)
            }
        }
        work.tables[TaskActivity.epochTable] = [Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(epoch))])]
        snapshot.tables["tasks", default: []].append(contentsOf: tasks)
        snapshot.tables[TaskActivity.table] = work.tables[TaskActivity.table]
        snapshot.tables[TaskActivity.epochTable] = work.tables[TaskActivity.epochTable]
        snapshot.tables["view_preferences"] = [Record(["id": .string(ProductivityGoals.recordID), "user_id": .string(account), ProductivityGoals.field: goals.document])]
        MomentumCelebration.resetAll()
        if variant == "milestone-solo" {
            #if os(iOS)
            UserDefaults.standard.set(TaskPlanner.dayKey(now, calendar: calendar), forKey: DailyGoal.celebratedKey)
            #else
            UserDefaults.standard.set(TaskPlanner.dayKey(now, calendar: calendar), forKey: "lastGoalCelebration." + account)
            #endif
        }
    }
}
#endif
