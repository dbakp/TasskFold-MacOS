import SwiftUI
import AppKit

private struct TaskListFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var taskListFocused: Bool {
        get { self[TaskListFocusedKey.self] }
        set { self[TaskListFocusedKey.self] = newValue }
    }
}

/// One task in the content list: check control, title, metadata, and a hover-revealed action.
struct TaskRowView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("mac.taskDensity") private var density = "roomy"
    let task: Record
    @State private var fullNote: (request: TaskNotePreviewReadCache.Request, reading: Linkify.Reading)?
    @State private var notePresentation: UUID?
    var compactDate = false
    @State private var hovering = false
    @State private var choosingDate = false
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.taskListFocused) private var listFocused
    // Selection is a soft accent wash (DS.Palette.selectionFill), so selected rows keep primary text colour in every window state.
    private var selectedForeground: Color { DS.Palette.textPrimary }
    private var isSelected: Bool { workspace.selection.contains(task.id) }
    private var checked: Bool { task.completed || workspace.completing.contains(task.id) }
    var body: some View {
        let planning = TaskRowPlanningRead(task: task, compactDate: compactDate)
        let fullRequest = dynamicTypeSize.isAccessibilitySize ? store.fullTaskNotePreviewRequest(task) : nil
        let fullReading = fullNote?.request == fullRequest ? fullNote?.reading : nil
        let notePreview = fullReading?.text ?? store.taskNotePreview(task)
        let titleLinks = Linkify.reading(task.title), previewLinks = fullReading ?? Linkify.reading(notePreview)
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            if !workspace.hierarchyFilter && !workspace.independentWorkRow(task) && workspace.taskDepth(task.id) > 0 { Color.clear.frame(width: CGFloat(min(workspace.taskDepth(task.id), 5)) * 24 - 10, height: 1) /* indent geometry: depth steps, not spacing */.accessibilityHidden(true) }
            if workspace.canExpandTask(task) {
                Button {
                    if !workspace.expandedTasks.insert(task.id).inserted { workspace.expandedTasks.remove(task.id) }
                } label: {
                    Image(systemName: workspace.expandedTasks.contains(task.id) ? "chevron.down" : "chevron.right")
                        .font(DS.Font.chip).frame(width: DS.Space.l, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isSelected ? selectedForeground : DS.Palette.textSecondary)
                .accessibilityLabel("Subtasks of \(task.title)")
                .accessibilityValue(workspace.expandedTasks.contains(task.id) ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("expand-" + task.id)
            } else { Color.clear.frame(width: DS.Space.l, height: 1) }

            if TaskKind.mayComplete(task) {
            Button { workspace.complete(task) } label: {
                CheckMark(checked: checked, color: isSelected ? selectedForeground : DS.Palette.priority(task.priority), emphasized: isSelected || task.priority < 4)
                    .padding(DS.Space.xs)
            }
            .buttonStyle(GlyphStyle())
            .modifier(HoverLift())
            .pointerStyle(.link)
            .accessibilityLabel(checked ? "Reopen \(task.title)" : "Complete \(task.title)")
            .disabled(store.childTaskCompletionEnabled && Workspace.subtaskPath(task.id) != nil && store.childListCompletionBusy)
            .accessibilityIdentifier((checked ? "reopen-" : "complete-") + task.id)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            } else {
                Image(systemName: TaskKind(task) == .heading ? "textformat" : "questionmark.square")
                    .foregroundStyle(isSelected ? selectedForeground : DS.Palette.textSecondary).frame(width: DS.Space.xxl, height: DS.Space.xxl)
                    .accessibilityLabel(TaskKind(task) == .heading ? "Heading, stays open" : "Task type unavailable")
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if titleLinks.matches.isEmpty {
                    Text(task.title.isEmpty ? "Untitled task" : task.title)
                        .font(DS.Font.taskTitle)
                        .fontWeight(TaskKind(task) == .heading ? .semibold : .regular)
                        .accessibilityAddTraits(TaskKind(task) == .heading ? .isHeader : [])
                        .foregroundStyle(isSelected ? selectedForeground : checked ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                        .strikethrough(checked, color: .secondary)
                        .lineLimit(2)
                        .accessibilityLabel(accessibilitySummary(planning))
                        .accessibilityIdentifier("title-\(task.id)")
                } else {
                    LinkText(text: task.title, font: TaskKind(task) == .heading ? .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold) : .preferredFont(forTextStyle: .body),
                             color: NSColor(isSelected ? selectedForeground : checked ? Color.secondary : Color.primary),
                             linkColor: isSelected ? NSColor(selectedForeground) : NSColor(Color.taskfold),
                             strikethrough: checked, lineLimit: 2,
                             accessibilityIdentifier: "title-\(task.id)", accessibilityLabel: accessibilitySummary(planning), preparedLinks: titleLinks)
                }
                if !notePreview.isEmpty {
                    if previewLinks.matches.isEmpty {
                        Text(notePreview).font(DS.Font.taskNote).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : DS.Palette.textSecondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("notes-\(task.id)")
                    } else {
                        LinkText(text: notePreview, font: .preferredFont(forTextStyle: .subheadline),
                                 color: NSColor(isSelected ? selectedForeground.opacity(0.9) : Color.secondary),
                                 linkColor: isSelected ? NSColor(selectedForeground) : NSColor(Color.taskfold), lineLimit: dynamicTypeSize.isAccessibilitySize ? 0 : 1,
                                 accessibilityIdentifier: "notes-\(task.id)", preparedLinks: previewLinks)
                    }
                }
                if let fullRequest, fullReading == nil, !fullRequest.source.text.isEmpty {
                    ProgressView("Preparing full note…").controlSize(.small).font(DS.Font.chip)
                        .accessibilityIdentifier("taskNotesPreparing-" + task.id)
                }
                if workspace.section == .assigned || workspace.hierarchyPresentation, let parent = workspace.parentTitle(task.id) {
                    Text(parent).font(DS.Font.taskMeta).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : DS.Palette.textSecondary).lineLimit(1)
                }
                if planning.deadline != nil || (TaskKind.mayComplete(task) && task.durationMinutes != nil) || planning.showsDate || store.record("projects", id: task.string("project_id")) != nil || !task["subtasks"].list.isEmpty || !task["comments"].list.isEmpty || !task["attachments"].list.isEmpty || !task["labels"].list.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Space.s) { metadata(wrapping: false, planning: planning) }
                            .labelStyle(.titleAndIcon).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: DS.Space.xs) { metadata(wrapping: true, planning: planning) }
                            .labelStyle(WrappingMetadataLabelStyle(wraps: true))
                    }.font(DS.Font.taskMeta).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : DS.Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !task.string("assigned_to").isEmpty {
                AssigneeMenu(task: task, selected: isSelected) { workspace.assign(task.id, to: $0) }
            }
            Menu { priorityOptions } label: {
                Image(systemName: task.priority < 4 ? "flag.fill" : "flag")
                    .foregroundStyle(isSelected ? selectedForeground : task.priority < 4 ? DS.Palette.priority(task.priority) : DS.Palette.textSecondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(isSelected ? selectedForeground : DS.Palette.priority(task.priority))
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
            } label: { Image(systemName: "ellipsis").fontWeight(.semibold).foregroundStyle(isSelected ? selectedForeground : DS.Palette.textSecondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(isSelected ? selectedForeground : .secondary)
            .opacity(isSelected || hovering ? 1 : 0.65)
            .help("Task actions")
            .accessibilityIdentifier("actions-\(task.id)")
        }
        .padding(.vertical, DS.Size.rowVerticalPadding(compact: density == "compact"))
        .padding(.horizontal, DS.Space.xs)
        .frame(minHeight: DS.Size.rowMinHeight)
        .background(isSelected ? DS.Palette.selectionFill : Color.clear, in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .popover(isPresented: $choosingDate) { TaskDatePopover(task: task) }
        .animation(workspace.layout, value: checked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-\(task.id)")
        .task(id: fullRequest) {
            let ticket = UUID(); notePresentation = ticket
            guard let fullRequest else { fullNote = nil; return }
            guard fullNote?.request != fullRequest else { return }
            fullNote = nil
            while !Task.isCancelled, store.fullTaskNotePreviewRequest(task) == fullRequest {
                do {
                    let text = try await store.prepareFullTaskNotePreview(fullRequest)
                    let reading = try await Linkify.prepareReading(text)
                    guard !Task.isCancelled, notePresentation == ticket, store.fullTaskNotePreviewRequest(task) == fullRequest else { return }
                    fullNote = (fullRequest, reading)
                    return
                } catch is CancellationError {
                    // A same-context cache invalidation can cancel preparation
                    // without cancelling this row. Retry only while still current.
                    if Task.isCancelled { return }
                    await Task.yield()
                } catch { return }
            }
        }
        .onDisappear { notePresentation = nil; fullNote = nil }
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
    @ViewBuilder private func metadata(wrapping: Bool, planning: TaskRowPlanningRead) -> some View {
        if planning.showsDate, let due = planning.day {
            let time = planning.clock
            let text = (compactDate && !planning.overdue && !time.isEmpty ? Self.timeText(time) : due.formatted(.dateTime.month(.abbreviated).day()) + (time.isEmpty ? "" : " · " + Self.timeText(time))) + (planning.zone.isEmpty ? "" : " · " + planning.zone)
            Button { choosingDate = true } label: {
                Label(text, systemImage: task["is_recurring"].flag ? "repeat" : planning.overdue ? "exclamationmark.circle" : time.isEmpty ? "calendar" : "clock")
                    .accessibilityIdentifier("plannedDate-" + task.id)
                    .foregroundStyle(isSelected ? selectedForeground : planning.overdue ? DS.Palette.dateOverdue : planning.dueToday ? DS.Palette.accent : DS.Palette.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Change date")
            .accessibilityIdentifier("date-\(task.id)")
        }
        if let deadline = planning.deadline {
            Label("Deadline " + deadline.formatted(.dateTime.month(.abbreviated).day()), systemImage: "flag.checkered")
                .foregroundStyle(isSelected ? selectedForeground : planning.deadlineOverdue ? DS.Palette.dateOverdue : DS.Palette.textSecondary)
                .accessibilityIdentifier("deadline-" + task.id)
        }
        if TaskKind.mayComplete(task), let minutes = task.durationMinutes { Label("\(minutes) min", systemImage: "hourglass").accessibilityIdentifier("duration-" + task.id) }
        if let project = store.record("projects", id: task.string("project_id")) {
            Menu { projectOptions } label: {
                HStack(spacing: DS.Space.xs) {
                    Circle().fill(Color.project(project.string("color"))).frame(width: 8, height: 8) // dot geometry
                    Text(project.name).lineLimit(wrapping ? nil : 1).fixedSize(horizontal: false, vertical: true)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: !wrapping, vertical: true)
            .tint(isSelected ? selectedForeground : nil)
            .disabled(workspace.hierarchyPresentation && Workspace.subtaskPath(task.id) != nil)
            .help(workspace.hierarchyPresentation && Workspace.subtaskPath(task.id) != nil ? "Subtasks stay in their parent's project" : "Move to project")
        }
        ForEach(task["labels"].list.map(\.text).filter { !$0.isEmpty }, id: \.self) { name in
            Text(store.record("labels", id: name)?.name ?? name).lineLimit(wrapping ? nil : 1).fixedSize(horizontal: !wrapping, vertical: true).font(DS.Font.chip).padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs)
                .background(DS.Palette.surfaceSunken, in: .capsule)
        }
        if !task["subtasks"].list.isEmpty {
                let progress = store.subtaskProgress(task)
            if progress.total > 0 {
Label("\(progress.completed)/\(progress.total)", systemImage: "checklist")
                .accessibilityLabel("\(progress.completed) of \(progress.total) subtasks completed")
                .accessibilityIdentifier("subtaskSummary-" + task.id)
                            }
        }
        if !task["comments"].list.isEmpty {
            Label("\(task["comments"].list.count)", systemImage: "text.bubble")
                .accessibilityLabel(task["comments"].list.count == 1 ? "1 comment" : "\(task["comments"].list.count) comments")
        }
        if !task["attachments"].list.isEmpty {
            Image(systemName: "paperclip")
                .accessibilityLabel(task["attachments"].list.count == 1 ? "1 attachment" : "\(task["attachments"].list.count) attachments")
        }
    }

    private func accessibilitySummary(_ planning: TaskRowPlanningRead) -> String {
        var parts = [task.title]
        if TaskKind(task) == .heading { parts.append("heading, stays open") }
        if TaskKind(task) == .unsupported { parts.append("task type unavailable") }
        if checked { parts.append("completed") }
        if workspace.hierarchyPresentation, let parent = workspace.parentTitle(task.id) { parts.append("Subtask of " + parent) }
        if task.priority < 4 { parts.append("priority \(task.priority)") }
        if let due = planning.day { parts.append(planning.overdue ? "overdue since \(due.formatted(date: .abbreviated, time: .omitted))" : "due \(due.formatted(date: .abbreviated, time: .omitted))") }
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
        HStack(spacing: DS.Space.s) {
            CheckMark(checked: false, color: DS.Palette.priority(tasks.first?.priority ?? 4), emphasized: (tasks.first?.priority ?? 4) < 4)
            Text(tasks.first?.title ?? "").lineLimit(1)
            if tasks.count > 1 {
                Text("\(tasks.count)").font(DS.Font.badge).foregroundStyle(Color.onAccent)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs).background(Color.taskfold, in: .capsule)
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .frame(width: 300, alignment: .leading)
        .modifier(CardSurface(radius: DS.Radius.m, elevated: true))
    }
}

/// The 2 pt insertion line that shows where a dragged task will land. When the pointer is over another
/// priority band the line stays in the task's own band and a small hint says so.
struct InsertionIndicator: View {
    var hint: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 0) {
                Circle().fill(DS.Palette.accent).frame(width: 8, height: 8) // dot geometry
                Rectangle().fill(Color.taskfold).frame(height: 2)
            }
            if let hint {
                Text(hint).font(DS.Font.badge).foregroundStyle(DS.Palette.accent)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs)
                    .background(DS.Palette.surfaceRaised, in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.taskfold.opacity(0.35), lineWidth: 1))
                    .fixedSize()
                    .transition(reduceMotion ? .opacity : .badgePop)
                    .accessibilityIdentifier("bandHint")
            }
        }
        .frame(height: 8)
        .animation(Transitions.Ease.smoothOut(Transitions.Duration.quick), value: hint)
        .transition(.opacity)
        .accessibilityHidden(hint == nil)
        .accessibilityLabel(hint ?? "")
    }
}

/// Date edits commit once, through the same undo path as keyboard and inspector actions.
struct TaskDatePopover: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let task: Record
    @State private var date: Date
    init(task: Record) { self.task = task; _date = State(initialValue: TaskPlanner.dayDate(task) ?? Date()) }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Schedule task").font(.headline)
            HStack {
                Button("Today") { apply(Date()) }
                Button("Tomorrow") { apply(Calendar.current.date(byAdding: .day, value: 1, to: Date())!) }
                Button("Next Week") { if let day = store.datePhraseDay("next week") { apply(day) } }.disabled(store.datePhrasePreferences == nil)
                Button("This Weekend") { if let day = store.datePhraseDay("this weekend") { apply(day) } }.disabled(store.datePhrasePreferences == nil)
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
        }.padding(DS.Space.l).frame(width: 330)
    }
    private func apply(_ date: Date) {
        dismiss()
        workspace.reschedule([task.id], to: Dates.day(date), label: date.formatted(date: .abbreviated, time: .omitted))
    }
}
