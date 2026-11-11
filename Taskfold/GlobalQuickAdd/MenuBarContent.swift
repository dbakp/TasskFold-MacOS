import SwiftUI
import AppKit

/// The `MenuBarExtra` window: today at a glance. A parser-backed "Add task" field on top, today's and overdue tasks
/// with working checkboxes, and a footer with the shortcut hint. Completion goes through `Workspace.complete`, the same
/// path as the task list (sound, haptics, linger, undo).
struct MenuBarContent: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accent") private var accent = "rose"
    @State private var text: String
    @State private var addedTo: String?
    @State private var remembered: [String] = []
    @FocusState private var focused: Bool
    /// Debug captures render this view offscreen with a fixed text and shortcut hint.
    private let staticHint: Bool
    init(initialText: String = "", staticHint: Bool = false) {
        _text = State(initialValue: initialText)
        self.staticHint = staticHint
    }

    static let limit = 8
    private struct Row: Identifiable { var task: Record; var overdue: Bool; var id: String { task.id } }

    // MARK: Data

    private var rows: [Row] {
        let now = Date(), calendar = Calendar.current, today = Dates.day(now)
        let read = store.taskDayGroups(TaskQuery(scope: .today), today: today, calendar: calendar)
        let overdue = read.overdue.filter(TaskKind.mayComplete).sorted { ($0.due ?? .distantPast, $0.priority) < ($1.due ?? .distantPast, $1.priority) }
        var result = overdue.map { Row(task: $0, overdue: true) } + (read.rowsByDay[today] ?? []).filter(TaskKind.mayComplete).map { Row(task: $0, overdue: false) }
        // A task checked a moment ago keeps its row (checked) until the linger ends, as in the main list.
        for entry in workspace.lingering.values.sorted(by: { (remembered.firstIndex(of: $0.before.id) ?? .max) < (remembered.firstIndex(of: $1.before.id) ?? .max) })
        where workspace.isLingering(entry.before.id) && !result.contains(where: { $0.id == entry.before.id }) {
            guard let position = remembered.firstIndex(of: entry.before.id) else { continue }
            let predecessor = remembered[..<position].last { id in result.contains { $0.id == id } }
            let index = predecessor.flatMap { id in result.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            result.insert(Row(task: entry.before, overdue: false), at: min(index, result.count))
        }
        return result
    }
    private var parsed: QuickEntry { QuickEntry(text, context: workspace.quickEntryContext(), task: workspace.captureTask(date: nil, scope: .inbox)) }

    // MARK: Body

    var body: some View {
        let all = rows
        let shown = Array(all.prefix(Self.limit))
        let remaining = all.count - shown.count
        VStack(alignment: .leading, spacing: 0) {
            header(count: all.filter { !workspace.isLingering($0.id) }.count)
            if store.signedIn || store.localMode {
                addField
                Divider().padding(.horizontal, DS.Space.l)
                if shown.isEmpty { emptyState } else { list(shown, remaining: remaining) }
            } else {
                Text("Open Taskfold to sign in.").font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, DS.Space.xxl)
            }
            Divider().padding(.horizontal, DS.Space.l)
            footer
        }
        .frame(width: 320)
        .background(DS.Palette.surface)
        .tint(Color.adaptiveAccent(accent))
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .onChange(of: all.map(\.id), initial: true) { _, ids in if workspace.lingering.isEmpty { remembered = ids } }
        .accessibilityIdentifier("menuBarToday")
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Today").font(DS.Font.screenTitle)
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            if count > 0 {
                Text("\(count)").font(DS.Font.badge).foregroundStyle(Color.taskfold)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs)
                    .background(Color.taskfold.opacity(0.14), in: .capsule)
                    .accessibilityLabel(count == 1 ? "1 task" : "\(count) tasks").accessibilityIdentifier("menuBarCount")
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.l).padding(.bottom, DS.Space.m)
    }

    // MARK: Add

    private var addField: some View {
        let entry = parsed
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "plus").font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
                TextField("Add task", text: $text).textFieldStyle(.plain).font(DS.Font.taskTitle)
                    .focused($focused).onSubmit(add).accessibilityIdentifier("menuBarAdd")
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            .background(DS.Palette.surfaceSunken, in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.taskfold.opacity(focused ? 0.55 : 0), lineWidth: 1))
            if let addedTo {
                Label("Added to \(addedTo)", systemImage: "checkmark.circle.fill").font(DS.Font.taskMeta)
                    .foregroundStyle(DS.Palette.textSecondary).symbolRenderingMode(.hierarchical).transition(.opacity)
                    .accessibilityIdentifier("menuBarAdded")
            } else if !entry.tokens.isEmpty {
                let tint = entry.fieldPreview(to: workspace.captureTask(date: nil, scope: .inbox)).due.map { TaskDetailFormat.relativeDay($0).tint } ?? DS.Palette.accent
                QuickAddTokenLine(tokens: entry.tokens, dateTint: tint)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
        .animation(Motion.respecting(reduceMotion, Motion.quick), value: addedTo)
    }

    private func add() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let id = workspace.add(input, project: "", date: nil, scope: .inbox) else {
            if workspace.teamTaskCreation != nil { GlobalQuickAddController.openMainWindow() }
            return
        }
        let project = store.record("tasks", id: id).flatMap { store.record("projects", id: $0.string("project_id")) }
        text = ""
        addedTo = project?.name ?? "Inbox"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            addedTo = nil
        }
    }

    // MARK: Tasks

    private func list(_ shown: [Row], remaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { row in
                MenuBarTaskRow(task: row.task, overdue: row.overdue, lingering: workspace.isLingering(row.id),
                               complete: { workspace.complete(row.task) }, open: { open(row.task) })
            }
            if remaining > 0 {
                Button { openToday() } label: {
                    Text("\(remaining) more").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s).contentShape(.rect)
                }
                .buttonStyle(.plain).pointerStyle(.link).accessibilityLabel("\(remaining) more, open Today").accessibilityIdentifier("menuBarMore")
            }
        }
        .padding(.vertical, DS.Space.xs)
        .animation(Motion.respecting(reduceMotion, Motion.layout), value: shown.map(\.id))
    }

    private var emptyState: some View {
        let done = workspace.completedTodayCount() > 0
        return VStack(spacing: DS.Space.s) {
            Image(systemName: done ? "sparkles" : "sun.max").font(.system(size: 26, weight: .light) /* empty-state glyph */).foregroundStyle(DS.Palette.dateToday.opacity(0.75))
            Text(done ? "You did it" : "All clear for today").font(DS.Font.sectionHeader)
            Text(done ? "Everything for today is done." : "Enjoy the rest of your day.").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, DS.Space.xxl).accessibilityElement(children: .combine).accessibilityIdentifier("menuBarEmpty")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Button("Open Taskfold") { GlobalQuickAddController.openMainWindow() }
                .buttonStyle(.plain).font(DS.Font.taskMeta.weight(.medium)).foregroundStyle(Color.taskfold).pointerStyle(.link)
                .accessibilityIdentifier("menuBarOpen")
            Spacer()
            Text(staticHint ? "⌃⌥Space to add from anywhere" : (GlobalQuickAddController.shared.hint ?? "Set a shortcut in Settings"))
                .font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textTertiary).lineLimit(1).accessibilityIdentifier("menuBarShortcutHint")
            Menu {
                Button("Settings…") { NSApp.activate(); openSettings() }
                Divider()
                Button("Quit Taskfold") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis").font(DS.Font.chip).frame(width: 22, height: 22).contentShape(.rect) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(DS.Palette.textSecondary)
            .accessibilityLabel("More").accessibilityIdentifier("menuBarMoreMenu")
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
    }

    // MARK: Opening

    private func open(_ task: Record) {
        workspace.openExternalTask(task.id)
        GlobalQuickAddController.openMainWindow()
    }
    private func openToday() {
        workspace.section = .today
        GlobalQuickAddController.openMainWindow()
    }
}

/// One today or overdue task: checkbox, title, and a trailing date (red when overdue) or time.
private struct MenuBarTaskRow: View {
    let task: Record
    let overdue: Bool
    let lingering: Bool
    let complete: () -> Void
    let open: () -> Void
    @State private var hover = false
    @State private var checkHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meta: (text: String, tint: Color)? {
        if overdue, let due = task.due { return (TaskDetailFormat.relativeDay(due).text, DS.Palette.dateOverdue) }
        if !task.string("due_time").isEmpty { return (TaskDetailFormat.clock(task.string("due_time")), DS.Palette.textSecondary) }
        return nil
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button(action: complete) {
                CheckMark(checked: lingering, color: DS.Palette.priority(task.priority), emphasized: task.priority < 4, size: DS.Size.checkbox,
                          stroke: task.priority < 4 ? nil : DS.Palette.textTertiary, restFill: task.priority < 4 ? 0.1 : 0, previewCheck: checkHover && !lingering)
                    .frame(width: DS.Space.xxxl - DS.Space.xs, height: DS.Space.xxxl - DS.Space.xs).contentShape(.rect)
            }
            .buttonStyle(.plain).onHover { checkHover = $0 }.pointerStyle(.link)
            .accessibilityLabel(lingering ? "Reopen \(task.title)" : "Complete \(task.title)").accessibilityIdentifier("menuBarComplete-" + task.id)
            Button(action: open) {
                HStack(spacing: DS.Space.s) {
                    Text(task.title.isEmpty ? "Untitled task" : task.title).font(DS.Font.taskTitle).lineLimit(1)
                        .foregroundStyle(lingering ? DS.Palette.textTertiary : DS.Palette.textPrimary).strikethrough(lingering, color: .secondary)
                    Spacer(minLength: DS.Space.s)
                    if let meta { Text(meta.text).font(DS.Font.taskMeta).foregroundStyle(meta.tint).lineLimit(1).fixedSize() }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain).pointerStyle(.link).accessibilityLabel(task.title).accessibilityHint("Opens in Taskfold").accessibilityIdentifier("menuBarTask-" + task.id)
        }
        .padding(.horizontal, DS.Space.m).frame(minHeight: DS.Size.rowMinHeight)
        .background(hover ? DS.Palette.selectionFill.opacity(0.6) : .clear, in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
        .padding(.horizontal, DS.Space.xs)
        .onHover { hover = $0 }
        .animation(Motion.respecting(reduceMotion, Motion.quick), value: lingering)
    }
}

/// A single quiet line of what the parser recognised in the menu bar field.
private struct QuickAddTokenLine: View {
    let tokens: [QuickEntry.Token]
    let dateTint: Color
    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(tokens.prefix(4).enumerated()), id: \.offset) { _, token in
                let tint = QuickEntryChips.tint(for: token, date: dateTint)
                Text(token.text).font(DS.Font.chip).foregroundStyle(tint).lineLimit(1)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: DS.Radius.xs, style: .continuous))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("menuBarTokens")
    }
}
