import SwiftUI

/// Smart reschedule review: overdue work spread over the next working days, grouped by day with a capacity bar.
/// One file for both apps. The plan is computed by Core/SmartReschedule.swift without any model; the on-device model
/// may only add a one-line note per day. Nothing changes until "Apply", which is one undo group.
struct SmartRescheduleRequest: Identifiable {
    let id = UUID()
    let workspace: WorkspaceBinding
    /// When set, only these tasks are planned (the Weekly review's slipped tasks); other overdue work is left alone.
    var only: Set<String>? = nil
}

struct SmartRescheduleView: View {
    let request: SmartRescheduleRequest
    /// Called with the number of tasks moved, after the commit succeeded.
    var onApplied: (Int) -> Void = { _ in }
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @State private var plan: SmartReschedule.Plan?
    @State private var tasks: [String: Record] = [:]
    @State private var events: [PlannerEvent] = []
    @State private var workingDays = SmartReschedule.defaultWorkingDays
    @State private var notes: [String: String] = [:]
    @State private var notesSession: SmartRescheduleSession
    @State private var notesWork: Task<Void, Never>?
    @State private var notesBusy = false
    @State private var loaded = false
    @State private var applied = false
    @State private var error: String?

    init(request: SmartRescheduleRequest, onApplied: @escaping (Int) -> Void = { _ in }) {
        self.request = request; self.onApplied = onApplied
        _notesSession = State(initialValue: SmartRescheduleSession(workspace: request.workspace, session: UUID()))
    }
    private var session: UUID { store.backend.reminderSessionIncarnation }
    private var binding: WorkspaceBinding { .init(account: store.userID, generation: store.workspaceGeneration) }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    private var noteUnavailable: String? { SmartRescheduleEngine.unavailableReason }
    private var calendar: Calendar { .current }

    var body: some View {
        OnDeviceSheetShell(title: "Find a time", cancelIdentifier: "smartRescheduleCancel", primaryTitle: "Apply", primaryIdentifier: "smartRescheduleApply",
                           primaryEnabled: !(applied || (plan?.includedCount ?? 0) == 0),
                           primaryValue: plan.map { "\($0.includedCount) \($0.includedCount == 1 ? "task" : "tasks")" } ?? "",
                           primaryHint: "Moves the tasks to the days shown. You can undo it.",
                           cancel: { closeNotes(); dismiss() }, primary: { apply() }) {
            Form {
                if let plan {
                    if plan.isEmpty && plan.readOnlyCount == 0 {
                        Section { Text("Nothing is overdue right now.").accessibilityIdentifier("smartRescheduleEmpty") }
                    } else {
                        introSection(plan)
                        if let message = plan.unplacedMessage { unplacedMessageSection(plan, message) }
                        ForEach(plan.days.filter { $0.workingMinutes > 0 || !plan.placements(on: $0.day).isEmpty }) { day in daySection(day, plan) }
                        if !plan.unplaced.isEmpty { stayingOverdueSection(plan) }
                        if plan.readOnlyCount > 0 {
                            Section { Text("\(plan.readOnlyCount) overdue \(plan.readOnlyCount == 1 ? "task is" : "tasks are") shared with you as read-only, so \(plan.readOnlyCount == 1 ? "it stays" : "they stay") as \(plan.readOnlyCount == 1 ? "it is" : "they are").")
                                .font(.callout).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("smartRescheduleReadOnly") }
                        }
                    }
                } else {
                    Section { ProgressView("Planning your next days…").accessibilityIdentifier("smartRescheduleLoading") }
                }
                if let error { Section { Text(error).foregroundStyle(DS.Palette.danger).accessibilityIdentifier("smartRescheduleError") } }
            }
            .formStyle(.grouped)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 460, idealHeight: 700)
        #endif
        .task { await load() }
        .onChange(of: store.workspaceGeneration) { _, _ in closeNotes(); dismiss() }
        .onChange(of: phase) { _, value in if value == .background { stopNotes() } }
        .onChange(of: error) { _, value in if let value { AccessibilityNotification.Announcement(value).post() } }
        .onDisappear { closeNotes() }
    }

    // MARK: Sections

    private func introSection(_ plan: SmartReschedule.Plan) -> some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                OnDeviceBadge()
                Text("Overdue tasks are spread over your next \(plan.workingDays) working days, using free time from your working hours and calendar. Nothing changes until you apply.")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            if noteUnavailable == nil {
                if notesBusy {
                    HStack { ProgressView().controlSize(.small); Text("Writing day notes on this device…").font(.callout).foregroundStyle(DS.Palette.textSecondary) }
                        .accessibilityIdentifier("smartRescheduleNotesProgress")
                } else if notes.isEmpty && !plan.includedPlacements.isEmpty {
                    Button("Add day notes", systemImage: "sparkles") { writeNotes() }.accessibilityIdentifier("smartRescheduleNotes")
                }
            }
        }
    }
    private func unplacedMessageSection(_ plan: SmartReschedule.Plan, _ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(DS.Palette.textPrimary).accessibilityIdentifier("smartRescheduleDidntFit")
            if plan.canExtend {
                Button("Extend to \(SmartReschedule.extendedWorkingDays) days") { workingDays = SmartReschedule.extendedWorkingDays; rebuild() }
                    .accessibilityIdentifier("smartRescheduleExtend")
            }
        }
    }

    private func dayTitle(_ day: SmartReschedule.Day) -> String {
        let today = TaskPlanner.dayKey(Date(), calendar: calendar)
        let name = day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        if day.day == today { return "Today, " + name }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())), day.day == TaskPlanner.dayKey(tomorrow, calendar: calendar) { return "Tomorrow, " + name }
        return name
    }
    private func ordered(_ placements: [SmartReschedule.Placement]) -> [SmartReschedule.Placement] {
        let rank = Dictionary(SmartReschedule.prioritised(placements.compactMap { tasks[$0.taskID] }, calendar: calendar).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return placements.sorted { (rank[$0.taskID] ?? 0, $0.taskID) < (rank[$1.taskID] ?? 0, $1.taskID) }
    }

    private func daySection(_ day: SmartReschedule.Day, _ plan: SmartReschedule.Plan) -> some View {
        let load = plan.includedLoad(on: day.day), over = plan.isOver(day.day), off = day.workingMinutes == 0
        return Section {
            ForEach(ordered(plan.placements(on: day.day))) { placement in placementRow(placement, plan) }
            if plan.placements(on: day.day).isEmpty { Text("Nothing moved here").font(.callout).foregroundStyle(DS.Palette.textSecondary) }
        } header: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(dayTitle(day)).font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    Text(plan.summary(on: day.day)).font(DS.Font.taskMeta).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                }
                if off {
                    Text("Not a working day").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                } else {
                    CapacityBar(load: load, free: day.freeMinutes, over: over)
                    Text("\(DayPlan.duration(load)) of \(DayPlan.duration(day.freeMinutes)) free" + (over ? " · over by \(DayPlan.duration(load - day.freeMinutes))" : ""))
                        .font(DS.Font.taskMeta).monospacedDigit().foregroundStyle(over ? DS.Palette.dateTomorrow : DS.Palette.textSecondary)
                }
                if let note = notes[day.day] {
                    Label(note, systemImage: "sparkles").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityIdentifier("smartRescheduleNote-" + day.day)
                }
            }
            .textCase(nil).padding(.vertical, DS.Space.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(plan.accessibility(on: day.day, calendar: calendar) + (notes[day.day].map { ". " + $0 } ?? ""))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("smartRescheduleDay-" + day.day)
        }
    }

    private func placementRow(_ placement: SmartReschedule.Placement, _ plan: SmartReschedule.Plan) -> some View {
        let task = tasks[placement.taskID], excluded = plan.excluded.contains(placement.taskID), targets = plan.moveTargets(for: placement.taskID)
        let title = task?.title ?? "Task"
        return HStack(alignment: .top, spacing: DS.Space.s) {
            Button { edit { $0.setExcluded(placement.taskID, !excluded) } } label: {
                Image(systemName: excluded ? "circle" : "checkmark.circle.fill").font(.title3)
                    .foregroundStyle(excluded ? DS.Palette.textSecondary : DS.Palette.accent).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).accessibilityLabel(excluded ? "Include \(title)" : "Keep \(title) overdue")
            .accessibilityIdentifier("smartRescheduleInclude-" + placement.taskID)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).strikethrough(excluded).foregroundStyle(excluded ? DS.Palette.textSecondary : DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                Text(meta(placement, task, excluded: excluded)).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if placement.afterDeadline {
                    Label("After its deadline", systemImage: "exclamationmark.triangle.fill").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.dateTomorrow)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if placement.isRecurring { Button("Repeats: stays on its next date") {}.disabled(true) }
                ForEach(targets) { day in
                    Button { edit { $0.move(placement.taskID, to: day.day, deadline: task?.string("deadline_date")) } } label: {
                        if day.day == placement.day { Label(dayTitle(day), systemImage: "checkmark") } else { Text(dayTitle(day)) }
                    }.accessibilityIdentifier("smartRescheduleMoveTo-\(placement.taskID)-\(day.day)")
                }
                Divider()
                Button(excluded ? "Include" : "Keep overdue", systemImage: excluded ? "arrow.uturn.backward" : "xmark") { edit { $0.setExcluded(placement.taskID, !excluded) } }
            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
            .buttonStyle(.borderless)
            .accessibilityLabel("Options for \(title)").accessibilityIdentifier("smartRescheduleOptions-" + placement.taskID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("smartRescheduleRow-" + placement.taskID)
    }
    private func meta(_ placement: SmartReschedule.Placement, _ task: Record?, excluded: Bool) -> String {
        var parts: [String] = []
        if let task, task.priority < 4 { parts.append("Priority \(task.priority)") }
        parts.append(DayPlan.duration(placement.minutes) + (placement.guessed ? " (assumed)" : ""))
        if let clock = task.map({ TaskPlanner.clockValue($0, calendar: calendar) }), !clock.isEmpty { parts.append("at " + clock) }
        if let skipped = placement.repeatSkipped { parts.append("Repeats · skips \(skipped) missed \(skipped == 1 ? "date" : "dates")") }
        if let deadline = task?.string("deadline_date"), !deadline.isEmpty, let date = Dates.parse(deadline) { parts.append("Deadline " + date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) }
        if let due = task.flatMap({ Dates.parse(TaskPlanner.plannedDay($0, calendar: calendar)) }) { parts.append("Was " + due.formatted(.dateTime.day().month(.abbreviated))) }
        if excluded { parts.append("Stays overdue") }
        return parts.joined(separator: " · ")
    }

    private func stayingOverdueSection(_ plan: SmartReschedule.Plan) -> some View {
        Section {
            ForEach(plan.unplaced) { item in
                let task = tasks[item.taskID]
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(task?.title ?? "Task")
                        Text(item.reason.message).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if item.reason != .recurringBeyondWindow {
                        Menu {
                            ForEach(plan.days.filter { $0.workingMinutes > 0 }) { day in
                                Button(dayTitle(day)) {
                                    edit { $0.place(item.taskID, on: day.day, minutes: task?.durationMinutes ?? SmartReschedule.defaultEstimateMinutes,
                                                    guessed: task?.durationMinutes == nil, deadline: task?.string("deadline_date")) }
                                }
                            }
                        } label: { Image(systemName: "calendar.badge.plus").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).accessibilityLabel("Choose a day for \(task?.title ?? "task")")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("smartRescheduleUnplaced-" + item.taskID)
            }
        } header: { Text("Staying overdue").textCase(nil) }
    }

    // MARK: Plan

    private func load() async {
        guard !loaded else { return }
        loaded = true
        notesSession = SmartRescheduleSession(workspace: request.workspace, session: session)
        #if DEBUG
        if AIFixture.enabled { events = AIFixture.events() } else { events = await calendarEvents() }
        #else
        events = await calendarEvents()
        #endif
        rebuild()
        if SmartRescheduleFixtureNotes.enabled { notes = SmartRescheduleFixtureNotes.notes(for: plan) }
        else if noteUnavailable == nil { writeNotes() }
    }
    private func calendarEvents() async -> [PlannerEvent] {
        guard let window = await CalendarBusyStore.shared.capacityWindow(), window.state == "ready" else { return [] }
        return window.events
    }
    private func rebuild() {
        guard store.workflowReady(request.workspace) else { error = store.error; return }
        invalidateNotes()
        var next: SmartReschedule.Plan
        #if DEBUG
        if AIFixture.enabled { next = store.smartReschedulePlan(events: events, workingDays: workingDays, now: AIFixture.now(), hours: AIFixture.hours, only: request.only) }
        else { next = store.smartReschedulePlan(events: events, workingDays: workingDays, only: request.only) }
        #else
        next = store.smartReschedulePlan(events: events, workingDays: workingDays, only: request.only)
        #endif
        let planned = Set(next.placements.map(\.taskID) + next.unplaced.map(\.taskID))
        tasks = Dictionary(store.activeTasks.filter { planned.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        withAnimation(layout) { plan = next }
    }
    private func edit(_ change: (inout SmartReschedule.Plan) -> Void) {
        guard !applied, var next = plan else { return }
        change(&next)
        invalidateNotes()
        withAnimation(layout) { plan = next }
    }

    // MARK: Notes (never change the plan)

    private func writeNotes() {
        guard noteUnavailable == nil, let current = plan, !current.includedPlacements.isEmpty,
              let token = notesSession.begin(plan: current, workspace: binding, session: session) else { return }
        notesBusy = true
        let titles = Dictionary(tasks.map { ($0.key, $0.value.title) }, uniquingKeysWith: { first, _ in first })
        notesWork = Task {
            do {
                let raw = try await SmartRescheduleEngine.notes(for: current, titles: titles)
                guard !Task.isCancelled else { return }
                notesBusy = false; notesWork = nil
                if let latest = plan, let cleaned = notesSession.receive(raw, token: token, plan: latest, workspace: binding, session: session) { withAnimation(layout) { notes = cleaned } }
            } catch {
                guard !Task.isCancelled else { return }
                notesBusy = false; notesWork = nil; notesSession.stop()
            }
        }
    }
    private func stopNotes() { notesWork?.cancel(); notesWork = nil; notesSession.stop(); notesBusy = false }
    private func invalidateNotes() { stopNotes(); notes = [:] }
    private func closeNotes() { stopNotes(); notesSession.close() }

    // MARK: Apply

    private func apply() {
        guard !applied, let plan, store.workflowReady(request.workspace) else { error = store.error; return }
        var moved: Int?
        #if os(macOS)
        workspace.run("Reschedule Smartly") { moved = store.applySmartReschedule(plan, now: fixtureNow) }
        #else
        moved = store.applySmartReschedule(plan, now: fixtureNow)
        #endif
        guard let moved else { error = store.error; return }
        store.error = nil; applied = true; closeNotes()
        AccessibilityNotification.Announcement(moved == 1 ? "1 task rescheduled" : "\(moved) tasks rescheduled").post()
        onApplied(moved); dismiss()
    }
    private var fixtureNow: Date {
        #if DEBUG
        if AIFixture.enabled { return AIFixture.now() }
        #endif
        return Date()
    }
}

/// A day's load against its free time. Over capacity is information, so it turns a calm caution colour, never red.
struct CapacityBar: View {
    let load: Int
    let free: Int
    let over: Bool
    private var fraction: Double { free > 0 ? min(1, Double(load) / Double(free)) : (load > 0 ? 1 : 0) }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.surfaceSunken)
                Capsule().fill(over ? DS.Palette.dateTomorrow : DS.Palette.accent).frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * fraction))
            }
        }
        .frame(height: 6).accessibilityHidden(true)
    }
}

#if DEBUG
/// Screenshot and UI-test fixtures (`--ai-fixture`, with `--preview` or `--uitesting`): overdue tasks keyed to today.
enum AIFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ai-fixture") }
    /// Seven days of working hours, so a capture never depends on the weekday it was taken.
    static let hours = WorkingHours(start: 9 * 60, end: 17 * 60, weekdays: Set(1...7))
    /// 08:00 today, so today's hours are whole whatever the clock says.
    static func now(calendar: Calendar = .current) -> Date { calendar.startOfDay(for: Date()).addingTimeInterval(8 * 3600) }
    static func events(calendar: Calendar = .current) -> [PlannerEvent] {
        let start = calendar.startOfDay(for: Date())
        func event(_ offset: Int, _ title: String, _ from: Int, _ to: Int) -> PlannerEvent {
            let base = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return PlannerEvent(id: "ai-\(offset)-\(from)", calendarID: "work", title: title, source: "Work", start: base.addingTimeInterval(Double(from) * 60), end: base.addingTimeInterval(Double(to) * 60))
        }
        return [event(0, "Team standup", 9 * 60 + 30, 10 * 60), event(0, "Design review", 11 * 60, 12 * 60 + 30),
                event(1, "Client call", 10 * 60, 11 * 60 + 30), event(1, "Planning", 13 * 60, 16 * 60), event(2, "Workshop", 9 * 60, 14 * 60)]
    }
    /// Seven overdue tasks (one with a deadline, one repeating, one timed) and two for today, keyed to `store.calendarContext.today`.
    static func tasks(user: String, today: String) -> [Record] {
        func day(_ offset: Int) -> String {
            let base = Dates.parse(today) ?? Date()
            return Dates.day(Calendar.current.date(byAdding: .day, value: offset, to: base) ?? base)
        }
        let rows: [(String, Int, Int?, Int, [String: JSON])] = [
            ("Send the Q3 report to finance", 1, 90, -6, ["deadline_date": .string(day(3))]),
            ("Reply to the supplier contract", 1, 60, -4, [:]),
            ("Prepare the client workshop", 2, 150, -9, [:]),
            ("Review the open pull requests", 2, 60, -3, ["due_time": .string("14:00")]),
            ("Book travel for the offsite", 3, nil, -5, [:]),
            ("Water the office plants", 4, 15, -4, ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("weekly"), "interval": .number(1), "daysOfWeek": .array([.number(Double(Calendar.current.component(.weekday, from: Dates.parse(day(2)) ?? Date()) - 1))])])]),
            ("Tidy the shared drive", 4, 45, -11, [:]),
            ("Plan the next sprint", 2, 60, 0, [:]), ("Write the release notes", 3, 45, 0, [:])]
        return rows.enumerated().map { index, row in
            var task = Record.task(user: user, createdAt: "2026-10-01T09:00:00Z")
            task["id"] = .string("ai-fixture-\(index)"); task["title"] = .string(row.0); task["priority"] = .number(Double(row.1))
            task["due_date"] = .string(day(row.3))
            if let minutes = row.2 { task["duration_minutes"] = .number(Double(minutes)) }
            for (key, value) in row.4 { task[key] = value }
            return task
        }
    }
}

/// With `--ai-fixture-notes`, day notes are fixed text (never inference), for screenshots of the model-written note layout.
enum SmartRescheduleFixtureNotes {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ai-fixture-notes") }
    static func notes(for plan: SmartReschedule.Plan?) -> [String: String] {
        guard let plan else { return [:] }
        let lines = ["Busy start: two meetings, then the report", "Lighter day: a call and two quick replies", "Open afternoon for deep work"]
        return Dictionary(plan.days.filter { !plan.included(on: $0.day).isEmpty }.enumerated().map { ($1.day, lines[$0 % lines.count]) }, uniquingKeysWith: { first, _ in first })
    }
}
#endif
