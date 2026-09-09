import SwiftUI

/// One task in the content list: check control, title, metadata, and a hover-revealed action.
struct TaskRowView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    let task: Record
    var compactDate = false
    @State private var hovering = false
    private var checked: Bool { task.completed || workspace.completing.contains(task.id) }
    private var overdue: Bool { if let due = task.due { return due < Calendar.current.startOfDay(for: Date()) && !task.completed }; return false }
    private var dueToday: Bool { task.string("due_date") == Dates.day(Date()) }
    private var showsDate: Bool {
        guard task.due != nil else { return false }
        if !compactDate { return true }
        return overdue || !task.string("due_time").isEmpty || task["is_recurring"].flag
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { workspace.complete(task) } label: {
                CheckMark(checked: checked, color: Color.priority(task.priority), emphasized: task.priority < 4)
                    .padding(3)
            }
            .buttonStyle(GlyphStyle())
            .modifier(HoverLift())
            .pointerStyle(.link)
            .accessibilityLabel(checked ? "Reopen \(task.title)" : "Complete \(task.title)")
            .accessibilityIdentifier((checked ? "reopen-" : "complete-") + task.id)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .strikethrough(checked, color: .secondary)
                    .lineLimit(2)
                    .accessibilityLabel(accessibilitySummary)
                    .accessibilityIdentifier("title-\(task.id)")
                if !task.string("description").isEmpty { Text(task.string("description")).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                if showsDate || store.record("projects", id: task.string("project_id")) != nil || !task["subtasks"].list.isEmpty || !task["comments"].list.isEmpty || !task["attachments"].list.isEmpty || !task["labels"].list.isEmpty {
                    HStack(spacing: 10) {
                        if showsDate, let due = task.due {
                            let time = task.string("due_time")
                            let text = compactDate && !overdue && !time.isEmpty ? Self.timeText(time) : due.formatted(.dateTime.month(.abbreviated).day()) + (time.isEmpty ? "" : " · " + Self.timeText(time))
                            Label(text, systemImage: task["is_recurring"].flag ? "repeat" : overdue ? "exclamationmark.circle" : time.isEmpty ? "calendar" : "clock")
                                .foregroundStyle(overdue ? Color.red : dueToday ? Color.accentColor : Color.secondary)
                        }
                        if let project = store.record("projects", id: task.string("project_id")) {
                            HStack(spacing: 5) {
                                Circle().fill(Color.project(project.string("color"))).frame(width: 7, height: 7)
                                Text(project.name).lineLimit(1)
                            }
                        }
                        ForEach(task["labels"].list.map(\.text).filter { !$0.isEmpty }, id: \.self) { name in
                            Text(store.record("labels", id: name)?.name ?? name).lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: .capsule)
                        }
                        if !task["subtasks"].list.isEmpty { Label("\(task["subtasks"].list.filter { $0.object["completed"]?.flag == true }.count)/\(task["subtasks"].list.count)", systemImage: "checklist") }
                        if !task["comments"].list.isEmpty { Label("\(task["comments"].list.count)", systemImage: "text.bubble") }
                        if !task["attachments"].list.isEmpty { Image(systemName: "paperclip") }
                    }.font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if task.priority < 4 && !checked {
                Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Color.priority(task.priority)).opacity(0.85)
                    .accessibilityLabel("Priority \(task.priority)")
            }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: checked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-\(task.id)")
    }
    private var accessibilitySummary: String {
        var parts = [task.title]
        if checked { parts.append("completed") }
        if task.priority < 4 { parts.append("priority \(task.priority)") }
        if let due = task.due { parts.append(overdue ? "overdue since \(due.formatted(date: .abbreviated, time: .omitted))" : "due \(due.formatted(date: .abbreviated, time: .omitted))") }
        if let project = store.record("projects", id: task.string("project_id")) { parts.append("in \(project.name)") }
        return parts.joined(separator: ", ")
    }
    static func timeText(_ value: String) -> String {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) else { return value }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The image that follows the pointer during a drag: the real card, plus a count badge for multi-drags.
struct DragPreview: View {
    let tasks: [Record]
    var body: some View {
        HStack(spacing: 10) {
            CheckMark(checked: false, color: Color.priority(tasks.first?.priority ?? 4), emphasized: (tasks.first?.priority ?? 4) < 4)
            Text(tasks.first?.title ?? "").lineLimit(1)
            if tasks.count > 1 {
                Text("\(tasks.count)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor, in: .capsule)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .modifier(CardSurface(radius: 10, elevated: true))
    }
}

/// The 2 pt insertion line that shows where a dragged task will land.
struct InsertionIndicator: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .frame(height: 7)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}
