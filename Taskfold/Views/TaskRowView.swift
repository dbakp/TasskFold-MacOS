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

private struct TaskRowScopeKey: EnvironmentKey {
    static let defaultValue: TaskScope? = nil
}

extension EnvironmentValues {
    /// Which list the row is shown in. Rows hide the trailing project when the list is that project.
    var taskRowScope: TaskScope? {
        get { self[TaskRowScopeKey.self] }
        set { self[TaskRowScopeKey.self] = newValue }
    }
}

private struct BoardCardKey: EnvironmentKey {
    static let defaultValue: BoardCardStyle? = nil
}

/// Board cards: compact rows with a small inset, full-width title, metadata beneath and a card surface.
struct BoardCardStyle: Equatable {
    /// False on boards already grouped by project, where the name would repeat the column header.
    var showsProject = true
}

extension EnvironmentValues {
    var boardCard: BoardCardStyle? {
        get { self[BoardCardKey.self] }
        set { self[BoardCardKey.self] = newValue }
    }
}

/// One task in the content list: check control, title, metadata, and a hover-revealed action.
struct TaskRowView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("mac.taskDensity") private var density = "roomy"
    let task: Record
    @State private var fullNote: (request: TaskNotePreviewReadCache.Request, reading: Linkify.Reading)?
    @State private var notePresentation: UUID?
    var compactDate = false
    @State private var hovering = false
    @State private var checkHover = false
    @Environment(\.taskRowScope) private var rowScope
    @Environment(\.boardCard) private var card
    @State private var choosingDate = false
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.taskListFocused) private var listFocused
    // Selection is a soft accent wash (DS.Palette.selectionFill), so selected rows keep primary text colour in every window state.
    private var selectedForeground: Color { DS.Palette.textPrimary }
    private var isSelected: Bool { workspace.selection.contains(task.id) }
    private var checked: Bool { task.completed || workspace.isLingering(task.id) }
    /// Just checked: the title fades to the tertiary colour while the row lingers.
    private var lingeringDone: Bool { workspace.isLingering(task.id) }
    var body: some View {
        let planning = TaskRowPlanningRead(task: task, compactDate: compactDate)
        let fullRequest = dynamicTypeSize.isAccessibilitySize ? store.fullTaskNotePreviewRequest(task) : nil
        let fullReading = fullNote?.request == fullRequest ? fullNote?.reading : nil
        let notePreview = fullReading?.text ?? store.taskNotePreview(task)
        let titleLinks = Linkify.reading(task.title), previewLinks = fullReading ?? Linkify.reading(notePreview)
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            if card == nil, !workspace.hierarchyFilter && !workspace.independentWorkRow(task) && workspace.taskDepth(task.id) > 0 { Color.clear.frame(width: CGFloat(min(workspace.taskDepth(task.id), 5)) * 24 - 10, height: 1) /* indent geometry: depth steps, not spacing */.accessibilityHidden(true) }
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
            } else if card == nil { Color.clear.frame(width: DS.Space.l, height: 1) }

            if TaskKind.mayComplete(task) {
            Button { workspace.complete(task) } label: {
                // Selection keeps the priority colour: the selected fill is a soft tint, not a solid highlight.
                CheckMark(checked: checked, color: DS.Palette.priority(task.priority), emphasized: task.priority < 4,
                          size: DS.Size.checkbox, stroke: task.priority < 4 ? nil : DS.Palette.textTertiary,
                          restFill: task.priority < 4 ? 0.1 : 0, previewCheck: checkHover && !checked)
                    .frame(width: DS.Space.xxxl, height: DS.Space.xxxl) // 32 pt hit area
                    .contentShape(.rect)
            }
            .buttonStyle(GlyphStyle())
            .onHover { checkHover = $0 }
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
                        .foregroundStyle(isSelected ? selectedForeground : lingeringDone ? DS.Palette.textTertiary : checked ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                        .strikethrough(checked, color: .secondary)
                        .animation(Motion.respecting(reduceMotion, Transitions.Ease.smoothOut(Transitions.Duration.fast)), value: checked)
                        .lineLimit(3)
                        .accessibilityLabel(accessibilitySummary(planning))
                        .accessibilityIdentifier("title-\(task.id)")
                } else {
                    LinkText(text: task.title, font: TaskKind(task) == .heading ? .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold) : .preferredFont(forTextStyle: .body),
                             color: NSColor(isSelected ? selectedForeground : checked ? Color.secondary : Color.primary),
                             linkColor: isSelected ? NSColor(selectedForeground) : NSColor(Color.taskfold),
                             strikethrough: checked, lineLimit: 3,
                             accessibilityIdentifier: "title-\(task.id)", accessibilityLabel: accessibilitySummary(planning), preparedLinks: titleLinks, autoFetchTitles: store.mayAutoFetchLinkTitles(task))
                }
                if !notePreview.isEmpty && density != "compact" {
                    if previewLinks.matches.isEmpty {
                        Text(notePreview).font(DS.Font.taskNote).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : DS.Palette.textSecondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("notes-\(task.id)")
                    } else {
                        LinkText(text: notePreview, font: .preferredFont(forTextStyle: .subheadline),
                                 color: NSColor(isSelected ? selectedForeground.opacity(0.9) : Color.secondary),
                                 linkColor: isSelected ? NSColor(selectedForeground) : NSColor(Color.taskfold), lineLimit: dynamicTypeSize.isAccessibilitySize ? 0 : 1,
                                 accessibilityIdentifier: "notes-\(task.id)", preparedLinks: previewLinks, autoFetchTitles: store.mayAutoFetchLinkTitles(task))
                    }
                }
                if let fullRequest, fullReading == nil, !fullRequest.source.text.isEmpty {
                    ProgressView("Preparing full note…").controlSize(.small).font(DS.Font.chip)
                        .accessibilityIdentifier("taskNotesPreparing-" + task.id)
                }
                if workspace.section == .assigned || workspace.hierarchyPresentation, let parent = workspace.parentTitle(task.id) {
                    Text(parent).font(DS.Font.taskMeta).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : DS.Palette.textSecondary).lineLimit(1)
                }
                if hasMetadata(planning) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Space.s) { metadata(wrapping: false, planning: planning) }
                            .labelStyle(.titleAndIcon).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        // At accessibility sizes the line wraps onto a second line rather than truncating.
                        VStack(alignment: .leading, spacing: DS.Space.xs) { metadata(wrapping: true, planning: planning) }
                            .labelStyle(WrappingMetadataLabelStyle(wraps: true))
                    }.font(DS.Font.taskMeta).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : DS.Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !task.string("assigned_to").isEmpty {
                AssigneeMenu(task: task, selected: isSelected) { workspace.assign(task.id, to: $0) }
            }
            if card == nil { trailing }
        }
        .overlay(alignment: .topTrailing) { if card != nil { trailing.background(DS.Palette.surfaceRaised, in: .rect(cornerRadius: DS.Radius.s)).opacity(hovering || isSelected ? 1 : 0).allowsHitTesting(hovering || isSelected) } }
        .padding(.vertical, card == nil ? DS.Size.rowVerticalPadding(compact: density == "compact") : DS.Space.s)
        .padding(.horizontal, card == nil ? DS.Space.xs : DS.Space.s)
        .frame(minHeight: DS.Size.rowMinHeight)
        .background {
            if card != nil {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(DS.Palette.surfaceRaised)
                    .overlay { RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(isSelected ? DS.Palette.selectionFill : hovering ? DS.Palette.surfaceSunken.opacity(0.5) : Color.clear) }
                    .overlay { RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.6), lineWidth: 0.5) }
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).fill(isSelected ? DS.Palette.selectionFill : hovering ? DS.Palette.surfaceSunken.opacity(0.5) : Color.clear)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .popover(isPresented: $choosingDate) { TaskDatePopover(task: task) }
        .animation(workspace.layout, value: checked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-\(task.id)")
        .accessibilityAction(named: "Schedule") { choosingDate = true }
        .accessibilityAction(named: "More") { workspace.open(task.id) }
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
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            if let project = trailingProject {
                HStack(spacing: DS.Space.xs) {
                    Text(project.name).lineLimit(1)
                    Circle().fill(Color.project(project.string("color"))).frame(width: 6, height: 6) // dot geometry
                }
                .font(DS.Font.taskMeta).foregroundStyle(isSelected ? selectedForeground.opacity(0.9) : DS.Palette.textSecondary)
                .opacity(hovering || isSelected ? 0 : 1)
                .accessibilityHidden(true)
            }
            HStack(spacing: DS.Space.xs) {
                Button { choosingDate = true } label: { Image(systemName: "calendar").frame(width: DS.Space.xxl, height: DS.Space.xxl).contentShape(.rect) }
                    .buttonStyle(.borderless).foregroundStyle(DS.Palette.textSecondary)
                    .help("Schedule").accessibilityLabel("Schedule \(task.title)").accessibilityIdentifier("schedule-\(task.id)")
                Menu {
                    Button("Change Date…", systemImage: "calendar") { choosingDate = true }
                    Menu("Move to Project") { projectOptions }
                    Menu("Priority") { priorityOptions }
                    Divider()
                    Button("Edit Details…") { workspace.open(task.id) }
                } label: { Image(systemName: "ellipsis").fontWeight(.semibold).foregroundStyle(isSelected ? selectedForeground : DS.Palette.textSecondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .tint(isSelected ? selectedForeground : .secondary)
                .help("Task actions")
                .accessibilityLabel("More actions for \(task.title)")
                .accessibilityIdentifier("actions-\(task.id)")
            }
            .opacity(hovering || isSelected ? 1 : 0)
            .allowsHitTesting(hovering || isSelected)
        }
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
    /// The project shows at the trailing edge only in lists that mix projects.
    private var trailingProject: Record? {
        if card != nil { return nil }
        if case .project = rowScope { return nil }
        return store.record("projects", id: task.string("project_id"))
    }
    /// Board cards carry the project in the metadata line, unless the board is grouped by project.
    private var cardProject: Record? {
        guard let card, card.showsProject else { return nil }
        return store.record("projects", id: task.string("project_id"))
    }
    private var labelNames: [String] { task["labels"].list.map(\.text).filter { !$0.isEmpty }.map { store.record("labels", id: $0)?.name ?? $0 } }
    private func hasMetadata(_ planning: TaskRowPlanningRead) -> Bool {
        cardProject != nil || dateText(planning) != nil || planning.deadline != nil || task["is_recurring"].flag || !task["subtasks"].list.isEmpty || !task["comments"].list.isEmpty
            || !labelNames.isEmpty || !task["attachments"].list.isEmpty || (TaskKind.mayComplete(task) && task.durationMinutes != nil) || store.dependencyIndicator(for: task) != nil
    }
    private enum DateRole { case overdue, today, tomorrow, thisWeek, later }
    private func dateRole(_ planning: TaskRowPlanningRead) -> DateRole {
        guard let day = planning.day else { return .later }
        if planning.overdue { return .overdue }
        if task.completed { return .later }
        let calendar = Calendar.current
        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: day)).day ?? 0
        switch gap { case 0: return .today; case 1: return .tomorrow; case 2...6: return .thisWeek; default: return .later }
    }
    private func dateColor(_ planning: TaskRowPlanningRead) -> Color {
        switch dateRole(planning) {
        case .overdue: return DS.Palette.dateOverdue
        case .today: return DS.Palette.dateToday
        case .tomorrow: return DS.Palette.dateTomorrow
        case .thisWeek: return DS.Palette.dateThisWeek
        case .later: return DS.Palette.dateLater
        }
    }
    /// "Today 14:00", "Tomorrow", "Friday", "12 Nov". Lists that already show the day drop it and keep only the time.
    private func dateText(_ planning: TaskRowPlanningRead) -> String? {
        guard planning.showsDate, let due = planning.day else { return nil }
        let time = planning.clock.isEmpty ? "" : Self.timeText(planning.clock)
        let zone = planning.zone.isEmpty || time.isEmpty ? "" : " " + planning.zone
        let day: String
        if compactDate && !planning.overdue { day = "" }
        else {
            switch dateRole(planning) {
            case .today: day = "Today"
            case .tomorrow: day = "Tomorrow"
            case .thisWeek: day = due.formatted(.dateTime.weekday(.wide))
            case .overdue, .later: day = due.formatted(.dateTime.day().month(.abbreviated))
            }
        }
        let text = [day, time + zone].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
    @ViewBuilder private func metadata(wrapping: Bool, planning: TaskRowPlanningRead) -> some View {
        if let text = dateText(planning) {
            Button { choosingDate = true } label: {
                Label(text, systemImage: "calendar")
                    .accessibilityIdentifier("plannedDate-" + task.id)
                    .foregroundStyle(isSelected ? selectedForeground : dateColor(planning))
            }
            .buttonStyle(.borderless)
            .help("Change date")
            .accessibilityIdentifier("date-\(task.id)")
        }
        if let project = cardProject {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(Color.project(project.string("color"))).frame(width: 6, height: 6) // dot geometry
                Text(project.name).lineLimit(1)
            }.accessibilityHidden(true)
        }
        if let deadline = planning.deadline {
            Label(deadline.formatted(.dateTime.day().month(.abbreviated)), systemImage: "flag.checkered")
                .foregroundStyle(isSelected ? selectedForeground : planning.deadlineOverdue ? DS.Palette.dateOverdue : DS.Palette.textSecondary)
                .accessibilityLabel("Deadline " + deadline.formatted(.dateTime.day().month(.abbreviated)))
                .accessibilityIdentifier("deadline-" + task.id)
        }
        if task["is_recurring"].flag {
            Image(systemName: "repeat").accessibilityLabel("Repeats")
        }
        if let marker = store.dependencyIndicator(for: task) {
            Image(systemName: marker.symbol).accessibilityLabel(marker.label).help(marker.label).accessibilityIdentifier("dependency-" + task.id)
        }
        if !task["subtasks"].list.isEmpty {
            let progress = store.subtaskProgress(task)
            if progress.total > 0 {
                Label("\(progress.completed)/\(progress.total)", systemImage: "list.bullet")
                    .accessibilityLabel("\(progress.completed) of \(progress.total) subtasks completed")
                    .accessibilityIdentifier("subtaskSummary-" + task.id)
            }
        }
        if !task["comments"].list.isEmpty {
            Label("\(task["comments"].list.count)", systemImage: "bubble.left")
                .accessibilityLabel(task["comments"].list.count == 1 ? "1 comment" : "\(task["comments"].list.count) comments")
        }
        // Not in the spec's list, kept so estimates and attachments stay visible.
        if TaskKind.mayComplete(task), let minutes = task.durationMinutes { Label("\(minutes) min", systemImage: "hourglass").accessibilityIdentifier("duration-" + task.id) }
        if !task["attachments"].list.isEmpty {
            Image(systemName: "paperclip")
                .accessibilityLabel(task["attachments"].list.count == 1 ? "1 attachment" : "\(task["attachments"].list.count) attachments")
        }
        let labels = labelNames
        ForEach(Array(labels.prefix(2)), id: \.self) { name in
            Label(name, systemImage: "tag").lineLimit(wrapping ? nil : 1).fixedSize(horizontal: !wrapping, vertical: true)
        }
        if labels.count > 2 { Text("+\(labels.count - 2)") }
    }

    /// VoiceOver reads: title, priority, date, project, labels, then note or subtask state.
    private func accessibilitySummary(_ planning: TaskRowPlanningRead) -> String {
        var parts = [task.title]
        if TaskKind(task) == .heading { parts.append("heading, stays open") }
        if TaskKind(task) == .unsupported { parts.append("task type unavailable") }
        if checked { parts.append("completed") }
        if task.priority < 4 { parts.append("priority \(task.priority)") }
        if let due = planning.day { parts.append(planning.overdue ? "overdue since \(due.formatted(date: .abbreviated, time: .omitted))" : "due \(due.formatted(date: .abbreviated, time: .omitted))" + (planning.clock.isEmpty ? "" : " at " + Self.timeText(planning.clock))) }
        if let project = store.record("projects", id: task.string("project_id")) { parts.append("in \(project.name)") }
        if let marker = store.dependencyIndicator(for: task) { parts.append(marker.label) }
        let labels = labelNames
        if !labels.isEmpty { parts.append("labels " + labels.joined(separator: ", ")) }
        let progress = store.subtaskProgress(task)
        if progress.total > 0 { parts.append("\(progress.completed) of \(progress.total) subtasks done") }
        else if !store.taskNotePreview(task).isEmpty { parts.append("has note") }
        if workspace.hierarchyPresentation, let parent = workspace.parentTitle(task.id) { parts.append("Subtask of " + parent) }
        return parts.joined(separator: ", ")
    }
    static func timeText(_ value: String) -> String {
        ClockFormat.string(clock: value) ?? value
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
