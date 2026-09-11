import SwiftUI
import AppKit

/// One task in the content list: check control, title, metadata, and a hover-revealed action.
struct TaskRowView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    let task: Record
    var compactDate = false
    @State private var hovering = false
    @State private var choosingDate = false
    @Environment(\.controlActiveState) private var controlActiveState
    private var selectedForeground: Color { controlActiveState == .inactive ? Color(nsColor: .labelColor) : .white }
    private var isSelected: Bool { workspace.selection.contains(task.id) }
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
                CheckMark(checked: checked, color: isSelected ? selectedForeground : Color.priority(task.priority), emphasized: isSelected || task.priority < 4)
                    .padding(3)
            }
            .buttonStyle(GlyphStyle())
            .modifier(HoverLift())
            .pointerStyle(.link)
            .accessibilityLabel(checked ? "Reopen \(task.title)" : "Complete \(task.title)")
            .accessibilityIdentifier((checked ? "reopen-" : "complete-") + task.id)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                if Linkify.links(in: task.title).isEmpty {
                    Text(task.title.isEmpty ? "Untitled task" : task.title)
                        .foregroundStyle(isSelected ? selectedForeground : checked ? Color.secondary : Color.primary)
                        .strikethrough(checked, color: .secondary)
                        .lineLimit(2)
                        .accessibilityLabel(accessibilitySummary)
                        .accessibilityIdentifier("title-\(task.id)")
                } else {
                    LinkText(text: task.title, font: .preferredFont(forTextStyle: .body),
                             color: NSColor(isSelected ? selectedForeground : checked ? Color.secondary : Color.primary),
                             linkColor: isSelected ? NSColor(selectedForeground) : NSColor(Color.taskfold),
                             strikethrough: checked, lineLimit: 2,
                             accessibilityIdentifier: "title-\(task.id)", accessibilityLabel: accessibilitySummary)
                }
                if !task.string("description").isEmpty {
                    if Linkify.links(in: task.string("description")).isEmpty {
                        Text(task.string("description")).font(.callout).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : .secondary).lineLimit(1)
                    } else {
                        LinkText(text: task.string("description"), font: .preferredFont(forTextStyle: .callout),
                                 color: NSColor(isSelected ? selectedForeground.opacity(0.9) : Color.secondary),
                                 linkColor: isSelected ? NSColor(selectedForeground) : NSColor(Color.taskfold), lineLimit: 1,
                                 accessibilityIdentifier: "notes-\(task.id)")
                    }
                }
                if showsDate || store.record("projects", id: task.string("project_id")) != nil || !task["subtasks"].list.isEmpty || !task["comments"].list.isEmpty || !task["attachments"].list.isEmpty || !task["labels"].list.isEmpty {
                    HStack(spacing: 10) {
                        if showsDate, let due = task.due {
                            let time = task.string("due_time")
                            let text = compactDate && !overdue && !time.isEmpty ? Self.timeText(time) : due.formatted(.dateTime.month(.abbreviated).day()) + (time.isEmpty ? "" : " · " + Self.timeText(time))
                            Button { choosingDate = true } label: {
                                Label(text, systemImage: task["is_recurring"].flag ? "repeat" : overdue ? "exclamationmark.circle" : time.isEmpty ? "calendar" : "clock")
                                    .foregroundStyle(isSelected ? selectedForeground : overdue ? Color.red : dueToday ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Change date")
                            .accessibilityIdentifier("date-\(task.id)")
                        }
                        if let project = store.record("projects", id: task.string("project_id")) {
                            Menu { projectOptions } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color.project(project.string("color"))).frame(width: 7, height: 7)
                                    Text(project.name).lineLimit(1)
                                }
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .tint(isSelected ? selectedForeground : nil)
                            .help("Move to project")
                        }
                        ForEach(task["labels"].list.map(\.text).filter { !$0.isEmpty }, id: \.self) { name in
                            Text(store.record("labels", id: name)?.name ?? name).lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: .capsule)
                        }
                        if !task["subtasks"].list.isEmpty { Label("\(task["subtasks"].list.filter { $0.object["completed"]?.flag == true }.count)/\(task["subtasks"].list.count)", systemImage: "checklist") }
                        if !task["comments"].list.isEmpty { Label("\(task["comments"].list.count)", systemImage: "text.bubble") }
                        if !task["attachments"].list.isEmpty { Image(systemName: "paperclip") }
                    }.font(.caption).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : .secondary).labelStyle(.titleAndIcon).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu { priorityOptions } label: {
                Image(systemName: task.priority < 4 ? "flag.fill" : "flag")
                    .foregroundStyle(isSelected ? selectedForeground : task.priority < 4 ? Color.priority(task.priority) : Color.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(isSelected ? selectedForeground : Color.priority(task.priority))
            .opacity(isSelected || task.priority < 4 || hovering ? 1 : 0.65)
            .help("Change priority")
            .accessibilityLabel("Priority for \(task.title)")
            .accessibilityIdentifier("priority-\(task.id)")
            Menu {
                Button("Change Date…", systemImage: "calendar") { choosingDate = true }
                Menu("Move to Project") { projectOptions }
                Menu("Priority") { priorityOptions }
                Divider()
                Button("Edit Details…") { workspace.open(task.id) }
            } label: { Image(systemName: "ellipsis").fontWeight(.semibold).foregroundStyle(isSelected ? selectedForeground : Color.secondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(isSelected ? selectedForeground : .secondary)
            .opacity(isSelected || hovering ? 1 : 0.65)
            .help("Task actions")
            .accessibilityIdentifier("actions-\(task.id)")
        }
        .tint(nil)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .popover(isPresented: $choosingDate) { TaskDatePopover(task: task) }
        .animation(workspace.layout, value: checked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-\(task.id)")
    }
    @ViewBuilder private var projectOptions: some View {
        Button("Inbox") { workspace.move([task.id], toProject: "") }
        ForEach(store.projects) { project in
            Button(project.name) { workspace.move([task.id], toProject: project.id) }
        }
    }
    @ViewBuilder private var priorityOptions: some View {
        ForEach(1...4, id: \.self) { priority in
            Button(priority == 4 ? "None" : "Priority \(priority)") { workspace.setPriority([task.id], priority) }
        }
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

/// The 2 pt insertion line that shows where a dragged task will land. When the pointer is over another
/// priority band the line stays in the task's own band and a small hint says so.
struct InsertionIndicator: View {
    var hint: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
            if let hint {
                Text(hint).font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .fixedSize()
                    .transition(reduceMotion ? .opacity : .badgePop)
                    .accessibilityIdentifier("bandHint")
            }
        }
        .frame(height: 7)
        .animation(Transitions.Ease.smoothOut(Transitions.Duration.quick), value: hint)
        .transition(.opacity)
        .accessibilityHidden(hint == nil)
        .accessibilityLabel(hint ?? "")
    }
}

/// Date edits commit once, through the same undo path as keyboard and inspector actions.
struct TaskDatePopover: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let task: Record
    @State private var date: Date
    init(task: Record) { self.task = task; _date = State(initialValue: task.due ?? Date()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule task").font(.headline)
            HStack {
                Button("Today") { apply(Date()) }
                Button("Tomorrow") { apply(Calendar.current.date(byAdding: .day, value: 1, to: Date())!) }
                Button("Next Week") { apply(Workspace.next(weekday: 2)) }
            }.controlSize(.small)
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Button("Remove Date") {
                    dismiss()
                    workspace.reschedule([task.id], to: nil, label: "")
                }.disabled(task.due == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(date) }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 330)
    }
    private func apply(_ date: Date) {
        dismiss()
        workspace.reschedule([task.id], to: Dates.day(date), label: date.formatted(date: .abbreviated, time: .omitted))
    }
}
