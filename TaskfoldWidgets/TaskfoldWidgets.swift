import WidgetKit
import SwiftUI

/// The app writes a compact snapshot into the shared App Group after every change; the widget only reads it.
/// Mirrors the iOS Today widget for the Mac's system families.
struct WidgetTask: Codable, Identifiable {
    var id: String
    var title: String
    var due: String
    var time: String
    var priority: Int
    var project: String
    var color: String
}
struct WidgetSnapshot: Codable {
    var updated: TimeInterval
    var tasks: [WidgetTask]
    static let empty = WidgetSnapshot(updated: 0, tasks: [])
    static func load() -> WidgetSnapshot {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dbakp.taskfold")?.appending(path: "widget.json"),
              let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
    static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// Open tasks due today or earlier, soonest and most important first.
    var today: [WidgetTask] {
        let today = Self.day(Date())
        return tasks.filter { !$0.due.isEmpty && $0.due <= today }.sorted { a, b in
            if a.due != b.due { return a.due < b.due }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.time < b.time
        }
    }
}

struct TodayEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: WidgetSnapshot(updated: 0, tasks: [
            WidgetTask(id: "1", title: "Make time for the big idea", due: WidgetSnapshot.day(Date()), time: "09:00", priority: 1, project: "Focus", color: "#e31e4b"),
            WidgetTask(id: "2", title: "A walk, without the phone", due: WidgetSnapshot.day(Date()), time: "", priority: 3, project: "", color: ""),
        ]))
    }
    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) { completion(TodayEntry(date: Date(), snapshot: .load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = TodayEntry(date: Date(), snapshot: .load())
        // Refresh at the next midnight so "today" rolls over even if the app stays closed.
        let midnight = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

private let brand = Color(red: 0.88, green: 0.12, blue: 0.30)

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry
    var tasks: [WidgetTask] { entry.snapshot.today }
    var limit: Int { switch family { case .systemSmall: return 3; case .systemMedium: return 4; case .systemLarge: return 9; default: return 3 } }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.headline).foregroundStyle(brand)
                Spacer()
                Text(tasks.isEmpty ? "" : "\(tasks.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            if tasks.isEmpty {
                Spacer()
                Text("Nothing is due today.").font(.subheadline.weight(.medium))
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(tasks.prefix(limit)) { task in
                    Link(destination: URL(string: "taskfold://task/\(task.id)")!) { row(task) }
                }
                if tasks.count > limit { Text("+\(tasks.count - limit) more").font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        .widgetURL(family == .systemSmall && tasks.count == 1 ? URL(string: "taskfold://task/\(tasks[0].id)") : URL(string: "taskfold://today"))
    }
    private func row(_ task: WidgetTask) -> some View {
        let today = WidgetSnapshot.day(Date())
        let priorityColor: Color = [1: .red, 2: .orange, 3: .blue][task.priority] ?? Color(nsColor: .tertiaryLabelColor)
        return HStack(spacing: 8) {
            Circle().strokeBorder(priorityColor, lineWidth: 1.6).frame(width: 14, height: 14)
            Text(task.title).font(family == .systemSmall ? .caption : .subheadline).lineLimit(1)
            Spacer(minLength: 0)
            if task.due < today { Text("Overdue").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
            else if !task.time.isEmpty && family != .systemSmall { Text(task.time).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskfoldToday", provider: TodayProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Today")
            .description("What is due today, at a glance.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct TaskfoldWidgetBundle: WidgetBundle {
    var body: some Widget { TodayWidget() }
}
