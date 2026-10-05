import Foundation
#if !WIDGET_MODEL_TESTING
import WidgetKit
import SwiftUI
#if os(iOS)
import AppIntents
#endif
#endif

/// A version-tolerant, read-only projection. No credentials or task mutations live in the extension.
struct WidgetTask: Codable, Identifiable {
    var id: String
    var title: String
    var due: String
    var time: String
    var priority: Int
    var project: String
    var color: String
}

struct WidgetDay: Identifiable {
    var date: Date
    var count: Int
    var id: Date { date }
}

struct WidgetSnapshot: Codable {
    var updated: TimeInterval
    var tasks: [WidgetTask]
    static let empty = WidgetSnapshot(updated: 0, tasks: [])
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private func ordered(_ rows: [WidgetTask]) -> [WidgetTask] {
        rows.sorted {
            if $0.due != $1.due { return ($0.due.isEmpty ? "9999" : $0.due) < ($1.due.isEmpty ? "9999" : $1.due) }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.time != $1.time { return ($0.time.isEmpty ? "24:00" : $0.time) < ($1.time.isEmpty ? "24:00" : $1.time) }
            return $0.id < $1.id
        }
    }
    func today(at date: Date, calendar: Calendar = .current) -> [WidgetTask] {
        let key = Self.day(date, calendar: calendar)
        return ordered(tasks.filter { !$0.due.isEmpty && $0.due <= key })
    }
    /// Outstanding scheduled work first, then unscheduled P1/P2 work. Future tasks never jump the queue.
    func focus(at date: Date, calendar: Calendar = .current) -> WidgetTask? {
        today(at: date, calendar: calendar).first ?? ordered(tasks.filter { $0.due.isEmpty && $0.priority <= 2 }).first
    }
    func week(at date: Date, calendar: Calendar = .current) -> [WidgetDay] {
        (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)) else { return nil }
            let key = Self.day(day, calendar: calendar)
            return WidgetDay(date: day, count: tasks.filter { $0.due == key }.count)
        }
    }
    #if !WIDGET_MODEL_TESTING
    static func load() -> WidgetSnapshot {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dbakp.taskfold")?.appending(path: "widget.json"),
              let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
    #endif
}

#if !WIDGET_MODEL_TESTING
struct TodayEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    static var preview: TodayEntry {
        let now = Date()
        return TodayEntry(date: now, snapshot: WidgetSnapshot(updated: now.timeIntervalSinceReferenceDate, tasks: [
            WidgetTask(id: "preview-1", title: "Sketch the next big idea", due: WidgetSnapshot.day(now), time: "09:00", priority: 1, project: "Studio", color: "#e31e4b"),
            WidgetTask(id: "preview-2", title: "Send the proposal", due: WidgetSnapshot.day(now), time: "14:30", priority: 2, project: "Work", color: "#7863c8"),
            WidgetTask(id: "preview-3", title: "Take a proper lunch break", due: WidgetSnapshot.day(now), time: "", priority: 3, project: "Personal", color: "#32856d"),
            WidgetTask(id: "preview-4", title: "Review the first draft", due: WidgetSnapshot.day(Calendar.current.date(byAdding: .day, value: 2, to: now)!), time: "", priority: 2, project: "Studio", color: "#e31e4b")
        ]))
    }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .preview }
    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? .preview : TodayEntry(date: Date(), snapshot: .load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        // Precomputed daily entries keep date-sensitive widgets accurate through a week without foregrounding.
        let entries = (0..<8).compactMap { offset -> TodayEntry? in
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: now)) else { return nil }
            return TodayEntry(date: offset == 0 ? now : day, snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private func adaptiveWidgetTint(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    #if os(iOS)
    return Color(uiColor: UIColor { traits in
        let rgb = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    })
    #else
    return Color(nsColor: NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    })
    #endif
}
private let brand = adaptiveWidgetTint((0.88, 0.12, 0.30), (1, 0.43, 0.60))
private let plum = adaptiveWidgetTint((0.39, 0.28, 0.65), (0.73, 0.63, 0.98))
private let mint = adaptiveWidgetTint((0.16, 0.48, 0.39), (0.43, 0.80, 0.66))
private func widgetColor(_ hex: String) -> Color {
    let value = hex.replacingOccurrences(of: "#", with: "")
    guard value.count == 6, let number = UInt64(value, radix: 16) else { return brand }
    return Color(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
}

struct WidgetSurface: View {
    var tint: Color
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.24 : 0.10), tint.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct WidgetFooter: View {
    let entry: TodayEntry
    var body: some View {
        if entry.snapshot.updated == 0 {
            Text("Open Taskfold to begin").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else if entry.date.timeIntervalSinceReferenceDate - entry.snapshot.updated > 86_400 {
            Label("Open app to refresh", systemImage: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("TASKFOLD").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.5).foregroundStyle(.secondary)
        }
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry
    var tasks: [WidgetTask] { entry.snapshot.today(at: entry.date) }
    var limit: Int { family == .systemLarge ? 7 : 2 }
    var body: some View {
        #if os(iOS)
        switch family {
        case .accessoryCircular:
            ZStack { AccessoryWidgetBackground(); VStack(spacing: 0) { Text("\(tasks.count)").font(.title2.bold()).monospacedDigit(); Text("due").font(.caption2) } }
                .widgetURL(URL(string: "taskfold://today"))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) { Text(tasks.first?.title ?? "All clear").font(.headline).lineLimit(1); Text("\(tasks.count) due · including overdue").font(.caption2).lineLimit(1) }
                .widgetURL(URL(string: tasks.first.map { "taskfold://task/\($0.id)" } ?? "taskfold://today"))
        case .accessoryInline:
            Text("Taskfold · \(tasks.count) due").widgetURL(URL(string: "taskfold://today"))
        default: content
        }
        #else
        content
        #endif
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) { Text("Today").font(.headline); Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text("\(tasks.count)").font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(brand)
            }
            if tasks.isEmpty {
                Spacer(minLength: 0)
                Label("All clear for today", systemImage: "sun.max").font(.subheadline.weight(.medium))
                Text("No scheduled tasks outstanding.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(tasks.prefix(limit)) { task in
                    Link(destination: URL(string: "taskfold://task/\(task.id)")!) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(widgetColor(task.color)).frame(width: 3, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text(task.due < WidgetSnapshot.day(entry.date) ? "Overdue · P\(task.priority)" : task.time.isEmpty ? "P\(task.priority)" : task.time).font(.system(size: 9)).foregroundStyle(task.due < WidgetSnapshot.day(entry.date) ? brand : .secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            HStack { WidgetFooter(entry: entry); Spacer(); if tasks.count > limit { Text("+\(tasks.count - limit)").font(.caption2).foregroundStyle(.secondary) }; Link(destination: URL(string: "taskfold://add")!) { Image(systemName: "plus.circle.fill").foregroundStyle(brand) }.accessibilityLabel("Add task") }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: brand) }
        .widgetURL(URL(string: "taskfold://today"))
    }
}

struct FocusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry
    var task: WidgetTask? { entry.snapshot.focus(at: entry.date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Focus", systemImage: "scope").font(.caption.weight(.semibold)).foregroundStyle(plum)
            if let task {
                Text(task.title).font(family == .systemSmall ? .headline : .title2.bold()).lineLimit(3).minimumScaleFactor(0.85)
                Text(task.due.isEmpty ? "Unscheduled priority · P\(task.priority)" : task.due < WidgetSnapshot.day(entry.date) ? "Overdue · P\(task.priority)" : "Today · P\(task.priority)\(task.time.isEmpty ? "" : " · \(task.time)")").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                HStack { if entry.date.timeIntervalSinceReferenceDate - entry.snapshot.updated > 86_400 { WidgetFooter(entry: entry) } else { Text(task.project.isEmpty ? "Inbox" : task.project).font(.caption2).lineLimit(1) }; Spacer(); Image(systemName: "arrow.up.right.circle.fill").font(.title2).foregroundStyle(plum) }
            } else {
                Text("Space to focus").font(.headline)
                Text("Nothing due or high priority. Capture your next step.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if family != .systemSmall || task == nil { WidgetFooter(entry: entry) }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: plum) }
        .widgetURL(URL(string: task.map { "taskfold://task/\($0.id)" } ?? "taskfold://add"))
    }
}

struct WeekWidgetView: View {
    let entry: TodayEntry
    var days: [WidgetDay] { entry.snapshot.week(at: entry.date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Next 7 days", systemImage: "calendar").font(.headline); Spacer(); Text("\(days.reduce(0) { $0 + $1.count }) scheduled").font(.caption).foregroundStyle(mint) }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        Text("\(day.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                        RoundedRectangle(cornerRadius: 5).fill(mint.opacity(day.count == 0 ? 0.12 : 0.75)).frame(height: day.count == 0 ? 4 : max(9, 40 * Double(day.count) / Double(max(1, days.map(\.count).max() ?? 1))))
                        Text(day.date.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))), \(day.count) scheduled tasks")
                }
            }
            HStack { WidgetFooter(entry: entry); Spacer(); let overdue = entry.snapshot.today(at: entry.date).filter { $0.due < WidgetSnapshot.day(entry.date) }.count; if overdue > 0 { Text("\(overdue) overdue").font(.caption2).foregroundStyle(brand) } }
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: mint) }
        .widgetURL(URL(string: "taskfold://upcoming"))
    }
}

struct CaptureWidgetView: View {
    let entry: TodayEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "plus.circle.fill").font(.system(size: 32, weight: .light)).foregroundStyle(brand)
            Text("Catch a thought").font(.headline)
            Text("Add a task in one tap.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("QUICK CAPTURE").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.2).foregroundStyle(brand)
        }
        .containerBackground(for: .widget) { WidgetSurface(tint: brand) }
        .widgetURL(URL(string: "taskfold://add"))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskfoldToday", provider: TodayProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Today").description("Your scheduled tasks, including overdue work, with quick capture.")
            #if os(iOS)
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
            #else
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            #endif
    }
}
struct FocusWidget: Widget {
    var body: some WidgetConfiguration { StaticConfiguration(kind: "TaskfoldFocus", provider: TodayProvider()) { FocusWidgetView(entry: $0) }.configurationDisplayName("Focus").description("One next action: outstanding scheduled work, then unscheduled priorities.").supportedFamilies([.systemSmall, .systemMedium]) }
}
struct WeekWidget: Widget {
    var body: some WidgetConfiguration { StaticConfiguration(kind: "TaskfoldWeek", provider: TodayProvider()) { WeekWidgetView(entry: $0) }.configurationDisplayName("Week ahead").description("See scheduled task counts for the next seven days. Tap to review your week.").supportedFamilies([.systemMedium]) }
}
struct CaptureWidget: Widget {
    var body: some WidgetConfiguration { StaticConfiguration(kind: "TaskfoldCapture", provider: TodayProvider()) { CaptureWidgetView(entry: $0) }.configurationDisplayName("Quick capture").description("Capture a thought before it gets away.").supportedFamilies([.systemSmall]) }
}

@main
struct TaskfoldWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        FocusWidget()
        WeekWidget()
        CaptureWidget()
        #if os(iOS)
        AddTaskControl()
        #endif
    }
}
#if os(iOS)
struct OpenQuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Task"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "taskfold://add")!))
    }
}
struct AddTaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TaskfoldAddTask") {
            ControlWidgetButton(action: OpenQuickAddIntent()) { Label("Add Task", systemImage: "plus.circle.fill") }
        }.displayName("Add Task").description("Opens Taskfold ready to type a new task.")
    }
}
#endif
#endif
