import SwiftUI

// The guided daily ritual: Estimate, Time-block and Done (step 1, Triage, stays in PlanDayView), the evening
// Shutdown, and the Today header chip. One file for both apps; the platform differences are small and marked.
// All decisions live in Core/DayPlan.swift. Every write goes through `DayPlanModel`, which uses the Store's
// ordinary commit paths (and, on the Mac, the window's undo manager), so ⌘Z, sync and reminders behave as usual.

// MARK: - Platform helpers

private extension Color {
    /// Text on the accent colour.
    static var dayPlanOnAccent: Color {
        #if os(macOS)
        Color.onAccent
        #else
        Color.taskfold.accentCheckmark
        #endif
    }
    /// A calm caution colour, never red: being over capacity is information, not an error.
    static var dayPlanCaution: Color { DS.Palette.caution }
}

@MainActor private enum DayPlanHaptic {
    static func done() {
        #if os(macOS)
        Feedback.complete()
        #else
        Haptics.complete()
        #endif
    }
    static func drop() {
        #if os(macOS)
        Feedback.drop()
        #else
        Haptics.drop()
        #endif
    }
}

private extension Font {
    /// Step headings. The shared role is too large for a phone sheet.
    static var dayPlanHeading: Font { .title3.weight(.semibold) }
    static var dayPlanHero: Font { .title2.weight(.semibold) }
}

private func dayPlanClock(_ date: Date) -> String { ClockFormat.string(date) }

// MARK: - Model

/// What a shutdown decision did to a task.
enum ShutdownDecision: Equatable {
    case tomorrow, date(String), evening, someday, keep
    var label: String {
        switch self {
        case .tomorrow: "Moved to tomorrow"
        case .date(let day): "Moved to " + (Dates.parse(day).map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? day)
        case .evening: "Kept for this evening"
        case .someday: "Moved to Someday"
        case .keep: "Kept for today"
        }
    }
    var symbol: String {
        switch self {
        case .tomorrow, .date: "calendar"
        case .evening: "moon.fill"
        case .someday: "moon.zzz"
        case .keep: "checkmark"
        }
    }
}

@MainActor @Observable
final class DayPlanModel {
    let day: Date
    var includeEvening = false
    /// The Fit my day proposal, shown on the timeline until applied or cancelled.
    var preview: DayPlanFit?
    var feedback: String?
    var undoRequest: EditHistoryRequest?
    var failure: String?
    var placing: Record?
    var highlighted: String?
    var customFor: String?
    var customText = ""
    var decisions: [String: ShutdownDecision] = [:]
    var closed = false
    @ObservationIgnored private var lastDecisionIDs: [String] = []
    /// Observed, so views drawn before `attach` redraw once the store arrives.
    private var store: Store?
    @ObservationIgnored private var runBridge: (String, () -> Void) -> Void = { _, body in body() }
    @ObservationIgnored private var undoBridge: (EditHistoryRequest) -> Bool = { _ in false }

    init(day: Date = Date()) { self.day = day }

    /// `run` mirrors a change into the Mac window's undo manager; `undo` undoes through it.
    func attach(store: Store, run: @escaping (String, () -> Void) -> Void, undo: @escaping (EditHistoryRequest) -> Bool) {
        self.store = store; runBridge = run; undoBridge = undo
    }

    var calendar: Calendar { .current }
    /// "Based on your history, today may take ~7h": a caption only. It never changes the scheduling or Fit my day.
    /// Nil until the estimate-versus-actual reading is reliable (ActualTime.swift).
    var historyHint: (text: String, spoken: String)? {
        guard let accuracy = store?.estimateAccuracy, let text = accuracy.dayHint(plannedMinutes: totals.estimatedMinutes),
              let spoken = accuracy.dayHintSpoken(plannedMinutes: totals.estimatedMinutes) else { return nil }
        return (text, spoken)
    }
    var dayStart: Date { calendar.dateInterval(of: .day, for: day)?.start ?? day }
    var events: [PlannerEvent] {
        #if DEBUG
        if DayPlanFixture.enabled { return DayPlanFixture.events(on: day) }
        #endif
        return CalendarBusyStore.shared.events
    }
    var hours: WorkingHours? {
        #if DEBUG
        if DayPlanFixture.enabled { return DayPlanFixture.hours }
        #endif
        return store?.workingHours
    }
    /// Never place anything in the past. Fixtures plan the whole day so screenshots do not depend on the clock.
    var notBefore: Date? {
        #if DEBUG
        if DayPlanFixture.enabled { return nil }
        #endif
        return Date()
    }
    var tasks: [Record] { store?.dayPlanTasks() ?? [] }
    var totals: DayPlanTotals { DayPlan.totals(tasks, events: events, on: day, hours: hours, calendar: calendar) }
    var eveningIDs: Set<String> { Set(store?.planningState.evening ?? []) }
    var timed: [Record] { tasks.filter { DayPlan.isTimed($0, calendar: calendar) } }
    var unscheduled: [Record] { tasks.filter { !DayPlan.isTimed($0, calendar: calendar) } }
    var finishes: Date? { DayPlan.finishesAround(tasks, calendar: calendar) }
    var plannedMinutes: Int { tasks.compactMap(\.durationMinutes).reduce(0, +) }
    var windowInterval: DateInterval? { hours?.interval(on: day, calendar: calendar) }

    private func capture(_ name: String, _ body: () -> Bool) -> Bool {
        guard let store else { return false }
        let previous = store.undoStack.last?.id
        var saved = false
        runBridge(name) { saved = body() }
        if !saved { failure = store.error ?? "That change could not be saved. Try again."; store.error = nil; return false }
        undoRequest = store.undoStack.last?.id != previous ? store.captureHistoryRequest() : nil
        return true
    }

    // MARK: Estimate

    func setEstimate(_ task: Record, minutes: Int) {
        guard let store, capture("Set Estimate", { store.setEstimate(task, minutes: minutes) }) else { return }
        feedback = nil; preview = nil
    }
    /// Keys 1 to 4 pick a chip for the highlighted task, 5 opens the custom field.
    func applyChip(_ index: Int) {
        let pending = DayPlan.withoutEstimate(tasks)
        guard let target = pending.first(where: { $0.id == highlighted }) ?? pending.first else { return }
        guard index < DayPlan.chips.count else { beginCustom(target); return }
        let following = pending.drop { $0.id != target.id }.dropFirst().first ?? pending.first { $0.id != target.id }
        setEstimate(target, minutes: DayPlan.chips[index])
        highlighted = following?.id
    }
    func moveHighlight(_ delta: Int) {
        let pending = DayPlan.withoutEstimate(tasks)
        guard !pending.isEmpty else { return }
        let index = pending.firstIndex { $0.id == highlighted } ?? 0
        highlighted = pending[max(0, min(pending.count - 1, index + delta))].id
    }
    func beginCustom(_ task: Record) { highlighted = task.id; customFor = task.id; customText = task.durationMinutes.map(String.init) ?? "" }
    func commitCustom() {
        guard let id = customFor, let task = tasks.first(where: { $0.id == id }) else { customFor = nil; return }
        guard let minutes = Int(customText.trimmingCharacters(in: .whitespaces)), (1...10080).contains(minutes) else {
            failure = "Choose an estimate between 1 minute and 7 days."; return
        }
        customFor = nil; setEstimate(task, minutes: minutes)
    }

    // MARK: Time-block

    func showFit() {
        preview = DayPlan.fit(tasks: tasks, events: events, on: day, hours: hours, eveningIDs: eveningIDs, placeEvening: includeEvening, notBefore: notBefore, calendar: calendar)
        feedback = nil; undoRequest = nil
    }
    func cancelFit() { preview = nil }
    func applyFit() {
        guard let store, let fit = preview else { return }
        let snapshot = tasks
        guard capture("Fit My Day", { store.applyDayFit(fit, tasks: snapshot) }) else { return }
        preview = nil
        feedback = fit.placements.isEmpty ? "Nothing to place" : (fit.placements.count == 1 ? "Placed 1 task" : "Placed \(fit.placements.count) tasks")
        DayPlanHaptic.drop()
    }
    func suggestedStart(for task: Record) -> Date {
        DayPlan.firstSlot(for: task, tasks: tasks, events: events, on: day, hours: hours, notBefore: notBefore, calendar: calendar)
            ?? windowInterval?.start ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
    @discardableResult
    func place(_ task: Record, at start: Date) -> Bool {
        guard let store, capture("Place Task", { store.place(task, at: start) }) else { return false }
        var changed = task
        if let fields = try? TaskPlanner.fields(task: task, start: start, calendar: calendar) { for (key, value) in fields { changed[key] = value } }
        let overlaps = TaskPlanner.conflicts(task: changed, start: start, minutes: changed.durationMinutes, tasks: tasks.filter { $0.id != task.id }, events: events.filter { !$0.allDay }, calendar: calendar)
        feedback = "Placed at " + dayPlanClock(start) + (overlaps.isEmpty ? "" : " · overlaps " + overlaps.prefix(2).joined(separator: ", "))
        preview = nil; DayPlanHaptic.drop()
        return true
    }
    func undo() {
        guard let request = undoRequest else { return }
        undoRequest = nil
        if undoBridge(request) {
            feedback = "Undone"; preview = nil
            for id in lastDecisionIDs { decisions[id] = nil }
            lastDecisionIDs = []
        } else { failure = store?.error ?? "That could not be undone." ; store?.error = nil }
    }

    // MARK: Done

    /// Remembers that today was planned, with the ids in time order. Not an undoable change.
    func markPlanned() {
        guard let store else { return }
        let ordered = timed.sorted { (TaskPlanning.start($0) ?? .distantFuture) < (TaskPlanning.start($1) ?? .distantFuture) } + unscheduled
        if !store.markDayPlanned(ids: ordered.map(\.id)) { store.error = nil }
    }

    // MARK: Shutdown

    func shutdownTomorrow(_ task: Record) {
        guard let store, capture("Move to Tomorrow", { store.moveToTomorrow([task]) }) else { return }
        decide([task.id], .tomorrow)
    }
    func shutdownDate(_ task: Record, day: String) {
        guard let store, capture("Reschedule", { store.moveToDay([task], day: day) }) else { return }
        decide([task.id], .date(day))
    }
    func shutdownEvening(_ task: Record) {
        guard let store, capture("Move to This Evening", { store.moveToEvening([task.id]) }) else { return }
        decide([task.id], .evening)
    }
    func shutdownSomeday(_ task: Record) {
        guard let store, capture("Move to Someday", { store.moveToSomeday([task.id]) }) else { return }
        decide([task.id], .someday)
    }
    func shutdownKeep(_ task: Record) { decide([task.id], .keep); undoRequest = nil }
    /// One undo group for every task still undecided.
    func shutdownAllTomorrow(_ pending: [Record]) {
        guard let store, !pending.isEmpty, capture("Move All to Tomorrow", { store.moveToTomorrow(pending) }) else { return }
        decide(pending.map(\.id), .tomorrow)
    }
    private func decide(_ ids: [String], _ decision: ShutdownDecision) {
        for id in ids { decisions[id] = decision }
        lastDecisionIDs = ids; feedback = nil
        DayPlanHaptic.drop()
    }
    func closeDay() {
        guard let store else { return }
        if store.markDayShutDown() { closed = true; undoRequest = nil; DayPlanHaptic.done() } else { failure = store.error ?? "Could not close the day."; store.error = nil }
    }
}

// MARK: - Step indicator

struct DayPlanStepIndicator: View {
    let step: DayPlanStep
    let eligible: [DayPlanStep]
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                ForEach(DayPlanStep.allCases, id: \.self) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? DS.Palette.accent : DS.Palette.surfaceSunken)
                        .frame(height: 4).opacity(eligible.contains(item) || item == step ? 1 : 0.5)
                }
            }
            if !textSize.isAccessibilitySize {
                HStack(spacing: DS.Space.xs) {
                    ForEach(DayPlanStep.allCases, id: \.self) { item in
                        Text(item.title).font(DS.Font.chip).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(item == step ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("Step \(step.number) of \(DayPlanStep.count) · \(step.title)").font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.accessibilityLabel)
        .accessibilityIdentifier("dayPlanSteps")
        .accessibilityValue(step.title)
    }
}

// MARK: - Capacity

struct DayPlanCapacityCard: View {
    let totals: DayPlanTotals
    var hint: (text: String, spoken: String)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Today's capacity").font(DS.Font.sectionHeader)
                Text(totals.capacityLabel).font(DS.Font.taskMeta).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Palette.surfaceSunken)
                    Capsule().fill(totals.isOver ? Color.dayPlanCaution : DS.Palette.accent).frame(width: max(6, proxy.size.width * totals.fraction))
                }
            }.frame(height: 8)
            if let note = totals.overNote {
                Label(note, systemImage: "hourglass").font(DS.Font.taskMeta).foregroundStyle(Color.dayPlanCaution)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("dayPlanOverNote")
            } else if totals.unestimatedCount > 0 {
                Text(totals.unestimatedCount == 1 ? "1 task has no estimate yet." : "\(totals.unestimatedCount) tasks have no estimate yet.")
                    .font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            }
            if let hint {
                Text(hint.text).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("dayPlanHistoryHint")
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurface(radius: DS.Radius.l))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(totals.capacityAccessibility)
        .accessibilityValue((totals.overNote ?? "Fits your free time") + (hint.map { ". " + $0.spoken } ?? ""))
        .accessibilityIdentifier("dayPlanCapacity")
    }
}

// MARK: - Capacity ring

/// The planner header's ring: planned time against free time, with "Fit my day" when the plan does not fit.
/// The ring and its text are one VoiceOver element carrying the numbers; the action is its own 44pt target.
struct CapacityRingView: View {
    let ring: CapacityRing
    var fit: (() -> Void)? = nil
    /// False in Calendar, whose header already draws the day ring: only the overrun line and Fit my day show.
    var showsRing = true
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 40
    private var tint: Color { ring.isOver ? Color.dayPlanCaution : DS.Palette.accent }
    var body: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s)) : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.m))
        layout {
            HStack(spacing: DS.Space.m) {
                if showsRing {
                ZStack {
                    Circle().stroke(DS.Palette.surfaceSunken, lineWidth: 6)
                    Circle().trim(from: 0, to: max(ring.fraction, ring.plannedMinutes > 0 && ring.hasWorkingHours ? 0.02 : 0))
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    if ring.isOver { Image(systemName: "exclamationmark").font(.caption2.weight(.bold)).foregroundStyle(tint) }
                }
                .padding(3) // the stroke is centred on the path: keep its outer edge on the frame
                .frame(width: min(diameter, 72), height: min(diameter, 72))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if showsRing || !ring.isOver { Text(ring.label).font(.caption.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true) }
                    if ring.isOver {
                        Text("\(DayPlan.duration(ring.overMinutes)) over your free time").font(.caption2).foregroundStyle(Color.dayPlanCaution).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ring.accessibilityLabel)
            .accessibilityIdentifier("capacityRing")
            if ring.offersFit, let fit {
                Button(action: fit) {
                    Label("Fit my day", systemImage: "sparkles").font(.caption.weight(.semibold)).lineLimit(1).fixedSize().frame(minWidth: 44, minHeight: 24)
                }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .accessibilityHint("Previews a schedule that fits your free time and asks before moving tasks")
                .accessibilityIdentifier("capacityRingFit")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Step 2: Estimate

struct DayPlanEstimateStep: View {
    @Bindable var model: DayPlanModel
    @FocusState private var customFocused: Bool
    var body: some View {
        let tasks = model.tasks
        let pending = DayPlan.withoutEstimate(tasks)
        let estimated = tasks.filter { $0.durationMinutes != nil }
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("How long will each one take?").font(.dayPlanHeading).accessibilityAddTraits(.isHeader)
            DayPlanCapacityCard(totals: model.totals, hint: model.historyHint)
            if tasks.isEmpty {
                Text("Nothing is planned for today yet.").font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary)
            } else if pending.isEmpty {
                Label("Everything has an estimate.", systemImage: "checkmark.circle").font(DS.Font.taskNote).foregroundStyle(DS.Palette.success)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Needs an estimate").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary)
                    ForEach(pending) { row($0, highlighted: (model.highlighted ?? pending.first?.id) == $0.id) }
                }
            }
            if !estimated.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Estimated").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary)
                    ForEach(estimated) { row($0, highlighted: false) }
                }
            }
            #if os(macOS)
            Text("1–4 pick 15m, 30m, 1h or 2h for the highlighted task · 5 custom · ↑↓ move · ⏎ next step").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textTertiary)
            #endif
        }
        .animation(Motion.layout, value: pending.map(\.id))
    }

    private func row(_ task: Record, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                if task.priority < 4 { Image(systemName: "flag.fill").font(DS.Font.chip).foregroundStyle(Color.priority(task.priority)).accessibilityHidden(true) }
                Text(task.title).font(DS.Font.taskTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let minutes = task.durationMinutes { Text(DayPlan.duration(minutes)).font(DS.Font.badge).foregroundStyle(DS.Palette.textSecondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: DS.Space.s)], alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(DayPlan.chips.enumerated()), id: \.offset) { index, minutes in
                    chip(DayPlan.chipTitle(minutes), key: index + 1, selected: task.durationMinutes == minutes, label: "\(DayPlan.spoken(minutes)) for \(task.title)", id: "dayPlanChip-\(minutes)") {
                        model.highlighted = task.id; model.setEstimate(task, minutes: minutes)
                    }
                }
                chip("Custom", key: 5, selected: task.durationMinutes.map { !DayPlan.chips.contains($0) } ?? false, label: "Custom estimate for \(task.title)", id: "dayPlanChipCustom") { model.beginCustom(task) }
            }
            if model.customFor == task.id {
                HStack(spacing: DS.Space.s) {
                    TextField("Minutes", text: $model.customText)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120).focused($customFocused)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onSubmit { model.commitCustom() }
                        .accessibilityLabel("Custom estimate in minutes").accessibilityIdentifier("dayPlanCustomField")
                    Button("Set") { model.commitCustom() }.buttonStyle(.borderedProminent).tint(Color.taskfold).accessibilityIdentifier("dayPlanCustomSet")
                    Button("Cancel") { model.customFor = nil }.buttonStyle(.bordered)
                }
                .onAppear { customFocused = true }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? DS.Palette.selectionFill : DS.Palette.surfaceSunken.opacity(0.5), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(highlighted ? DS.Palette.accent.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(.rect)
        .onTapGesture { model.highlighted = task.id }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dayPlanEstimateRow")
    }

    private func chip(_ title: String, key: Int, selected: Bool, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Text(title).font(DS.Font.chip)
                #if os(macOS)
                Text("\(key)").font(DS.Font.badge).opacity(0.55)
                #endif
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, DS.Space.s)
            .foregroundStyle(selected ? Color.dayPlanOnAccent : DS.Palette.textPrimary)
            .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised, in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(selected ? 0 : 0.8), lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

// MARK: - Step 3: Time-block

struct DayPlanTimeBlockStep: View {
    @Bindable var model: DayPlanModel
    var body: some View {
        let tasks = model.tasks
        let preview = model.preview
        let shown = preview.map { DayPlan.applying($0, to: tasks, calendar: model.calendar) } ?? tasks
        let previewIDs = Set(preview?.placements.map(\.taskID) ?? [])
        let blocks = TaskPlanner.blocks(shown.filter { DayPlan.isTimed($0, calendar: model.calendar) }, on: model.day, calendar: model.calendar)
        let items = PlannerTimelineItem.layout(blocks: blocks, events: model.events, on: model.day, calendar: model.calendar)
        let allDay = model.events.filter(\.allDay)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Fit it in").font(.dayPlanHeading).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: DS.Space.s)
                    Text(model.totals.capacityLabel).font(DS.Font.taskMeta).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(model.totals.capacityAccessibility)
                }
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Fit it in").font(.dayPlanHeading).accessibilityAddTraits(.isHeader)
                    Text(model.totals.capacityLabel).font(DS.Font.taskMeta).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityLabel(model.totals.capacityAccessibility)
                }
            }
            controls(preview: preview)
            if let hint = model.historyHint {
                Text(hint.text).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel(hint.spoken).accessibilityIdentifier("dayPlanTimeBlockHistoryHint")
            }
            if let preview { previewBanner(preview) }
            else if let message = model.feedback { feedbackBanner(message) }
            if !allDay.isEmpty {
                HStack(spacing: DS.Space.s) {
                    ForEach(allDay) { event in
                        Label(event.title, systemImage: "calendar").font(DS.Font.chip).padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                            .background(DS.Palette.surfaceSunken, in: Capsule()).accessibilityLabel("All-day: \(event.title)")
                    }
                    Spacer(minLength: 0)
                }
            }
            #if os(macOS)
            HStack(alignment: .top, spacing: DS.Space.l) {
                timeline(items: items, previewIDs: previewIDs).frame(maxWidth: .infinity)
                unscheduledList(tasks: tasks, preview: preview).frame(width: 240)
            }
            #else
            timeline(items: items, previewIDs: previewIDs)
            unscheduledList(tasks: tasks, preview: preview)
            #endif
        }
        .animation(Motion.respecting(false, Motion.layout), value: preview)
    }

    private func controls(preview: DayPlanFit?) -> some View {
        let hasEvening = !model.eveningIDs.isEmpty && model.tasks.contains { model.eveningIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            // Once a preview exists its banner is the one control for this action (round 3), so the pill hides.
            if preview == nil {
            HStack(spacing: DS.Space.s) {
                Button { model.showFit() } label: {
                    Label("Fit my day", systemImage: "sparkles").font(DS.Font.chip)
                    #if os(macOS)
                    Text("F").font(DS.Font.badge).opacity(0.6)
                    #endif
                }
                .buttonStyle(.bordered).tint(Color.taskfold)
                .disabled(model.unscheduled.isEmpty)
                .accessibilityIdentifier("dayPlanFit")
                .accessibilityHint("Places unscheduled, estimated tasks into your free time. Shows a preview first.")
                Spacer(minLength: 0)
            }
            }
            if hasEvening {
                Toggle("Also place This Evening tasks after work", isOn: $model.includeEvening).font(DS.Font.taskMeta)
                    .toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("dayPlanEveningToggle")
                    .onChange(of: model.includeEvening) { _, _ in if model.preview != nil { model.showFit() } }
            }
        }
    }

    private func previewBanner(_ fit: DayPlanFit) -> some View {
        let skipped = fit.didntFit.filter { $0.reason != .noEstimate }.count
        let title = fit.placements.isEmpty ? "Nothing fits right now" : "\(fit.placements.count) fit, \(DayPlan.duration(fit.placedMinutes))" + (skipped > 0 ? " · \(skipped) don't" : "")
        return HStack(alignment: .top, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Label(title, systemImage: "sparkles").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.accent).accessibilityIdentifier("dayPlanPreview")
            }
            Spacer(minLength: 0)
            Button("Cancel") { model.cancelFit() }.buttonStyle(.borderless).accessibilityIdentifier("dayPlanFitCancel")
        }
        .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.accent.opacity(0.10), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
    }

    private func feedbackBanner(_ message: String) -> some View {
        HStack(spacing: DS.Space.s) {
            Label(message, systemImage: "checkmark.circle").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("dayPlanFeedback")
            Spacer(minLength: 0)
            if model.undoRequest != nil {
                // On the Mac, ⌘Z is bound once by the sheet (PlanDayView), so this button carries no shortcut.
                Button("Undo") { model.undo() }.buttonStyle(.borderless).accessibilityIdentifier("dayPlanUndo")
            }
        }
        .padding(DS.Space.m).background(DS.Palette.surfaceSunken.opacity(0.6), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
    }

    private func timeline(items: [PlannerTimelineItem], previewIDs: Set<String>) -> some View {
        DayPlanTimeline(day: model.day, items: items, previewIDs: previewIDs, window: model.windowInterval) { id, start in
            guard let task = model.tasks.first(where: { $0.id == id }) else { return false }
            return model.place(task, at: start)
        }
    }

    private func unscheduledList(tasks: [Record], preview: DayPlanFit?) -> some View {
        let open = model.unscheduled
        let placedByPreview = Set(preview?.placements.map(\.taskID) ?? [])
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(open.isEmpty ? "Everything has a time" : "Unscheduled").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary)
            ForEach(open) { task in
                HStack(spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(task.title).font(DS.Font.taskMeta).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(task.durationMinutes.map(DayPlan.duration) ?? "No estimate").font(DS.Font.badge).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button { model.placing = task } label: { Label("Place at…", systemImage: "clock").labelStyle(.iconOnly).frame(minWidth: 32, minHeight: 32) }
                        .buttonStyle(.bordered).accessibilityLabel("Place \(task.title) at a time").accessibilityIdentifier("dayPlanPlace")
                        #if os(macOS)
                        .popover(item: placingBinding(task), arrowEdge: .leading) { DayPlanPlaceSheet(model: model, task: $0) }
                        #else
                        .sheet(item: placingBinding(task)) { DayPlanPlaceSheet(model: model, task: $0) }
                        #endif
                }
                .padding(DS.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                .background(placedByPreview.contains(task.id) ? DS.Palette.accent.opacity(0.12) : DS.Palette.surfaceSunken.opacity(0.5), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
                #if os(macOS)
                .draggable(task.id) { Text(task.title).padding(DS.Space.s).background(DS.Palette.surfaceRaised, in: .rect(cornerRadius: DS.Radius.s)) }
                #endif
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("dayPlanUnscheduledRow")
            }
            if let preview {
                let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let skipped = preview.didntFit.filter { $0.reason != .noEstimate }
                if !skipped.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Didn't fit").font(DS.Font.sectionHeader).foregroundStyle(Color.dayPlanCaution)
                        ForEach(skipped) { item in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(byID[item.taskID]?.title ?? "Task").font(DS.Font.taskMeta).lineLimit(1)
                                Text(item.reason.message).font(DS.Font.badge).foregroundStyle(DS.Palette.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, DS.Space.xs).accessibilityIdentifier("dayPlanDidntFit")
                }
            }
            #if os(macOS)
            if !open.isEmpty { Text("Drag onto the timeline, or press F").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textTertiary) }
            #endif
        }
    }
    private func placingBinding(_ task: Record) -> Binding<Record?> {
        Binding(get: { model.placing?.id == task.id ? model.placing : nil }, set: { if $0 == nil { model.placing = nil } })
    }
}

// MARK: - Timeline

/// A compact read-mostly day: the working-hours window, calendar events as read-only blocks, timed tasks, and
/// the Fit preview as dashed blocks. The vertical axis is elapsed real time, so a DST day is drawn honestly.
struct DayPlanTimeline: View {
    let day: Date
    let items: [PlannerTimelineItem]
    let previewIDs: Set<String>
    let window: DateInterval?
    var onDrop: ((String, Date) -> Bool)? = nil
    @Environment(Store.self) private var store
    /// One scale with Calendar Day (TimeGrid): 64pt per hour.
    private let hourHeight: CGFloat = TimeGrid.hourHeight
    @State private var targeted = false
    private let gutter: CGFloat = 46
    /// The smallest a tile is drawn, so a 15 minute item can still be read and tapped. Longer items are exactly duration x scale.
    private let compactTileHeight: CGFloat = 20

    private var dayStart: Date { Calendar.current.dateInterval(of: .day, for: day)?.start ?? day }
    private func minute(_ date: Date) -> Double { date.timeIntervalSince(dayStart) / 60 }
    private var range: (start: Double, end: Double) {
        var lower = window.map { minute($0.start) } ?? 9 * 60, upper = window.map { minute($0.end) } ?? 17 * 60
        for item in items { lower = min(lower, item.minute); upper = max(upper, item.minute + max(item.length, 30)) }
        let start = (lower / 60).rounded(.down) * 60, end = max(start + 120, (upper / 60).rounded(.up) * 60)
        return (start, end)
    }

    var body: some View {
        let r = range, ppm = hourHeight / 60
        let height = CGFloat(r.end - r.start) * ppm
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - gutter)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(DS.Palette.surfaceSunken.opacity(0.45))
                if let window {
                    Rectangle().fill(DS.Palette.surface)
                        .frame(width: width, height: CGFloat(minute(window.end) - minute(window.start)) * ppm)
                        .offset(x: gutter, y: CGFloat(minute(window.start) - r.start) * ppm)
                }
                ForEach(Array(stride(from: r.start, to: r.end, by: 60)), id: \.self) { m in
                    let y = CGFloat(m - r.start) * ppm
                    Text(dayPlanClock(dayStart.addingTimeInterval(m * 60))).font(DS.Font.badge).foregroundStyle(DS.Palette.textTertiary)
                        .frame(width: gutter - DS.Space.xs, alignment: .trailing).offset(y: y - 6)
                    Rectangle().fill(DS.Palette.separator.opacity(0.5)).frame(width: width, height: 1).offset(x: gutter, y: y)
                }
                ForEach(items) { item in
                    let laneWidth = width / CGFloat(max(1, item.laneCount))
                    block(item, height: CGFloat(item.length) * ppm).frame(width: max(20, laneWidth - 3), height: CGFloat(item.length) * ppm, alignment: .topLeading)
                        .offset(x: gutter + laneWidth * CGFloat(item.lane), y: CGFloat(item.minute - r.start) * ppm)
                }
            }
            #if os(macOS)
            .dropDestination(for: String.self) { ids, location in
                guard let id = ids.first, let onDrop else { return false }
                let snapped = ((r.start + Double(location.y / ppm)) / 5).rounded() * 5
                return onDrop(id, dayStart.addingTimeInterval(snapped * 60))
            } isTargeted: { targeted = $0 }
            #endif
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.accent, lineWidth: targeted ? 2 : 0))
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Day timeline")
        .accessibilityIdentifier("dayPlanTimeline")
    }

    /// The shared time-grid block: exactly start and duration, events neutral, tasks solid in their project colour,
    /// Fit my day suggestions dashed.
    @ViewBuilder private func block(_ item: PlannerTimelineItem, height: CGFloat) -> some View {
        switch item.content {
        case .event(let event):
            TimeGridBlock(title: event.title, time: dayPlanClock(event.start) + "–" + dayPlanClock(event.end), kind: .event(event.calendarColour), height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calendar: \(event.title), \(dayPlanClock(event.start)) to \(dayPlanClock(event.end))")
        case .task(let block):
            let preview = previewIDs.contains(block.task.id)
            let end = block.end.map { "–" + dayPlanClock($0) } ?? ""
            let project = store.record("projects", id: block.task.string("project_id"))
            let hue = DS.Palette.project(project)
            TimeGridBlock(title: block.task.title, time: dayPlanClock(block.start) + (preview ? "" : end), detail: preview ? nil : project?.name,
                          kind: preview ? .suggestion(hue) : .task(hue), height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((preview ? "Proposed: " : "Scheduled: ") + block.task.title + ", " + dayPlanClock(block.start) + (block.end.map { " to " + dayPlanClock($0) } ?? ""))
        }
    }
}

// MARK: - Place at…

struct DayPlanPlaceSheet: View {
    @Bindable var model: DayPlanModel
    let task: Record
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    init(model: DayPlanModel, task: Record) {
        self.model = model; self.task = task
        _start = State(initialValue: model.suggestedStart(for: task))
    }
    private var overlaps: [String] {
        guard let fields = try? TaskPlanner.fields(task: task, start: start, calendar: model.calendar) else { return [] }
        var changed = task; for (key, value) in fields { changed[key] = value }
        return TaskPlanner.conflicts(task: changed, start: start, minutes: task.durationMinutes, tasks: model.tasks.filter { $0.id != task.id }, events: model.events.filter { !$0.allDay }, calendar: model.calendar)
    }
    var body: some View {
        #if os(macOS)
        content.padding(DS.Space.l).frame(width: 280)
        #else
        NavigationStack {
            content.padding(DS.Space.l)
                .navigationTitle("Place at…").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss(); model.placing = nil } } }
        }.presentationDetents([.medium])
        #endif
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(task.title).font(DS.Font.sectionHeader).lineLimit(2)
            if let minutes = task.durationMinutes { Text(DayPlan.duration(minutes)).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary) }
            DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute).accessibilityIdentifier("dayPlanPlaceTime")
            if !overlaps.isEmpty {
                Label("Overlaps " + overlaps.prefix(2).joined(separator: ", "), systemImage: "exclamationmark.circle").font(DS.Font.taskMeta).foregroundStyle(Color.dayPlanCaution)
            }
            HStack {
                #if os(macOS)
                Button("Cancel") { model.placing = nil; dismiss() }.keyboardShortcut(.cancelAction)
                #endif
                Spacer()
                Button("Place") { if model.place(task, at: start) { model.placing = nil; dismiss() } }
                    .buttonStyle(.borderedProminent).tint(Color.taskfold).keyboardShortcut(.defaultAction).accessibilityIdentifier("dayPlanPlaceConfirm")
            }
        }
    }
}

// MARK: - Step 4: Done

struct DayPlanDoneStep: View {
    @Bindable var model: DayPlanModel
    let startFocus: () -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let tasks = model.tasks
        let finish = model.finishes.map(dayPlanClock)
        let line = DayPlan.summaryLine(taskCount: tasks.count, plannedMinutes: model.plannedMinutes, finish: finish)
        VStack(spacing: DS.Space.l) {
            Image(systemName: "sparkles").font(.system(size: 40, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(DS.Palette.accent)
                .accessibilityHidden(true)
            Text("Your day is planned").font(.dayPlanHero).accessibilityAddTraits(.isHeader)
            Text(line).font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).monospacedDigit()
                .accessibilityIdentifier("dayPlanSummary")
            let untimed = model.unscheduled.count
            if untimed > 0 {
                Text(untimed == 1 ? "1 task has no set time. Fit it in as the day goes." : "\(untimed) tasks have no set time. Fit them in as the day goes.")
                    .font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center)
            }
            if let note = model.totals.overNote {
                Label(note, systemImage: "hourglass").font(DS.Font.taskMeta).foregroundStyle(Color.dayPlanCaution)
            }
            VStack(spacing: DS.Space.s) {
                Button(action: startFocus) { Text("Start first focus session").frame(maxWidth: .infinity).padding(.vertical, DS.Space.xs) }
                    .buttonStyle(.borderedProminent).tint(Color.taskfold).controlSize(.large).disabled(tasks.isEmpty).accessibilityIdentifier("dayPlanStartFocus")
                Button(action: close) { Text("Close").frame(maxWidth: .infinity).padding(.vertical, DS.Space.xs) }
                    .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("dayPlanClose")
            }.frame(maxWidth: 360)
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity)
        .modifier(CardSurface(radius: DS.Radius.xl))
        .onAppear { DayPlanHaptic.done() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shutdown

struct DayPlanShutdownView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @State private var model = DayPlanModel()
    @State private var momentum = MomentumModel()
    @State private var ids: [String] = []
    @State private var loaded = false
    @State private var pickingFor: Record?
    @State private var picked = Date()

    private var open: [Record] { ids.compactMap { store.record("tasks", id: $0) } }
    private var undecided: [Record] { open.filter { model.decisions[$0.id] == nil } }

    var body: some View {
        #if os(macOS)
        content.frame(width: 560, height: 620).background(DS.Palette.surface)
        #else
        NavigationStack {
            content.background(Color(.systemGroupedBackground))
                .navigationTitle("Shut down").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.closed ? "Done" : "Close") { dismiss() }.accessibilityIdentifier("closeShutdown") } }
        }
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    #if os(macOS)
                    HStack {
                        Text("Shut down").font(.dayPlanHeading).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button(model.closed ? "Done" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("closeShutdown")
                    }
                    #endif
                    if model.closed { closing } else { review }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            if !model.closed { footer }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            model.attach(store: store, run: runBridge, undo: undoBridge)
            ids = store.shutdownTasks().map(\.id)
            #if DEBUG
            // Screenshot fixture: one task already moved to tomorrow and one kept for this evening.
            if DayPlanFixture.enabled, DayPlanFixture.step == "shutdown" {
                let rows = open
                if rows.count > 1 { model.shutdownTomorrow(rows[0]); model.shutdownEvening(rows[1]); model.feedback = nil }
            }
            #endif
        }
        .task { momentum.refresh(store: store) }
        .alert("Could not save", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) { Button("OK") { model.failure = nil } } message: { Text(model.failure ?? "") }
        .popover(item: $pickingFor, arrowEdge: .bottom) { task in datePicker(task) }
    }

    private var runBridge: (String, () -> Void) -> Void {
        #if os(macOS)
        { name, body in workspace.run(name, body) }
        #else
        { _, body in body() }
        #endif
    }
    private var undoBridge: (EditHistoryRequest) -> Bool {
        #if os(macOS)
        { request in
            if store.canApplyHistory(request), let manager = workspace.undoManager, manager.canUndo { manager.undo(); return true }
            return store.undo(request)
        }
        #else
        { request in store.undo(request) }
        #endif
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        let done = store.completedTodayRoots()
        HStack(spacing: DS.Space.m) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(DS.Palette.success).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Done today: \(done)").font(DS.Font.sectionHeader).monospacedDigit()
                Text(done == 0 ? "Some days are for the work that does not show." : "Look at what you moved forward.").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.l).modifier(CardSurface(radius: DS.Radius.l))
        .accessibilityElement(children: .ignore).accessibilityLabel("Done today: \(done)").accessibilityIdentifier("shutdownDone")

        if open.isEmpty {
            Label("Nothing planned for today is still open.", systemImage: "checkmark.seal").font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary)
                .accessibilityIdentifier("shutdownEmpty")
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(undecided.isEmpty ? "All decided" : "Still open (\(undecided.count))").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Move all to tomorrow") { model.shutdownAllTomorrow(undecided) }
                    .buttonStyle(.bordered).disabled(undecided.isEmpty).accessibilityIdentifier("shutdownAllTomorrow")
                    .accessibilityHint("Moves every undecided task to tomorrow as one change you can undo.")
            }
            ForEach(open) { task in shutdownRow(task) }
        }
    }

    private func shutdownRow(_ task: Record) -> some View {
        let decision = model.decisions[task.id]
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(task.title).font(DS.Font.taskTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let minutes = task.durationMinutes { Text(DayPlan.duration(minutes)).font(DS.Font.badge).foregroundStyle(DS.Palette.textSecondary) }
            }
            if let decision {
                Label(decision.label, systemImage: decision.symbol).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("shutdownDecision")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: DS.Space.s)], alignment: .leading, spacing: DS.Space.s) {
                    action("Tomorrow", "sunrise.fill", id: "shutdownTomorrow", task: task) { model.shutdownTomorrow(task) }
                    action("Pick a date", "calendar", id: "shutdownPick", task: task) { picked = Date(); pickingFor = task }
                    action("This Evening", "moon.fill", id: "shutdownEvening", task: task, enabled: store.canMoveToEvening([task.id])) { model.shutdownEvening(task) }
                    action("Someday", "moon.zzz", id: "shutdownSomeday", task: task, enabled: store.canMoveToSomeday([task.id])) { model.shutdownSomeday(task) }
                    action("Keep", "checkmark", id: "shutdownKeep", task: task) { model.shutdownKeep(task) }
                }
            }
        }
        .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceSunken.opacity(0.5), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
        .accessibilityElement(children: .contain)
        .animation(Motion.respecting(reduceMotion, Motion.layout), value: decision)
    }
    private func action(_ title: String, _ symbol: String, id: String, task: Record, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(DS.Font.chip).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 32).padding(.horizontal, DS.Space.xs)
                .background(DS.Palette.surfaceRaised, in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.8), lineWidth: 1))
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.96)).disabled(!enabled).opacity(enabled ? 1 : 0.45)
        .accessibilityLabel("\(title): \(task.title)").accessibilityIdentifier(id)
    }

    private func datePicker(_ task: Record) -> some View {
        VStack(spacing: DS.Space.m) {
            DatePicker("Date", selection: $picked, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            HStack {
                Button("Cancel") { pickingFor = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move") { let day = Dates.day(picked); pickingFor = nil; model.shutdownDate(task, day: day) }
                    .buttonStyle(.borderedProminent).tint(Color.taskfold).keyboardShortcut(.defaultAction).accessibilityIdentifier("shutdownPickConfirm")
            }
        }
        .padding(DS.Space.l).frame(minWidth: 300)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var footer: some View {
        VStack(spacing: DS.Space.s) {
            if let message = model.feedback { Text(message).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary) }
            HStack(spacing: DS.Space.s) {
                if model.undoRequest != nil {
                    Button("Undo") { model.undo() }.buttonStyle(.bordered).accessibilityIdentifier("shutdownUndo")
                        #if os(macOS)
                        .keyboardShortcut("z", modifiers: .command)
                        #endif
                }
                Spacer(minLength: 0)
                Button { model.closeDay() } label: { Text("Close the day").padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.xs) }
                    .buttonStyle(.borderedProminent).tint(Color.taskfold).controlSize(.large).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("shutdownClose")
                    .accessibilityHint("Nothing moves unless you chose it above.")
            }
        }
        .padding(DS.Space.l).background(.bar)
    }

    // MARK: Closing

    private var closing: some View {
        let streak = DayPlan.streakText(momentum.summary)
        return VStack(spacing: DS.Space.l) {
            Image(systemName: "moon.stars.fill").font(.system(size: 44, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(DS.Palette.accent)
                .symbolEffect(.bounce, value: reduceMotion ? false : model.closed).accessibilityHidden(true)
            Text(DayPlan.closingLine(for: store.calendarContext.today)).font(.dayPlanHero).multilineTextAlignment(.center).accessibilityIdentifier("shutdownClosingLine")
            if let streak {
                Label(streak, systemImage: "bolt.fill").font(DS.Font.chip).foregroundStyle(DS.Palette.accent)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs).background(DS.Palette.accent.opacity(0.16), in: Capsule()).accessibilityIdentifier("shutdownStreak")
            }
            Button { dismiss() } label: { Text("Done").frame(maxWidth: 200).padding(.vertical, DS.Space.xs) }
                .buttonStyle(.borderedProminent).tint(Color.taskfold).controlSize(.large).keyboardShortcut(.defaultAction).accessibilityIdentifier("shutdownDoneButton")
        }
        .padding(DS.Space.xxl).frame(maxWidth: .infinity).modifier(CardSurface(radius: DS.Radius.xl))
    }
}

// MARK: - Today header chip

/// "Plan your day" until the day is planned, "Shut down" once working hours are over, and a quiet confirmation.
struct DayPlanHeaderChip: View {
    let prompt: DayPlanPrompt
    let plan: () -> Void
    let shutdown: () -> Void
    var body: some View {
        switch prompt {
        case .plan:
            Button(action: plan) { chipLabel("Plan your day", symbol: "sparkles", prominent: true) }
                .buttonStyle(.plain).accessibilityLabel("Plan your day").accessibilityIdentifier("dayPlanPrompt")
                .accessibilityHint("Triage, estimate and time-block today")
        case .shutdown:
            Button(action: shutdown) { chipLabel("Shut down", symbol: "moon.fill", prominent: true) }
                .buttonStyle(.plain).accessibilityLabel("Shut down your day").accessibilityIdentifier("dayShutdown")
        case .planned:
            chipLabel("Planned", symbol: "checkmark", prominent: false)
                .accessibilityElement(children: .ignore).accessibilityLabel("Today is planned").accessibilityIdentifier("dayPlanned")
        case .shutDown:
            chipLabel("Shut down", symbol: "moon.stars", prominent: false)
                .accessibilityElement(children: .ignore).accessibilityLabel("Today is shut down").accessibilityIdentifier("dayShutDown")
        }
    }
    private func chipLabel(_ text: String, symbol: String, prominent: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).font(DS.Font.chip).accessibilityHidden(true)
            Text(text).font(DS.Font.chip).lineLimit(1)
        }
        .foregroundStyle(prominent ? DS.Palette.accent : DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs + DS.Space.xxs)
        .background((prominent ? DS.Palette.accent.opacity(0.16) : DS.Palette.surfaceSunken), in: Capsule())
        #if os(iOS)
        .frame(minHeight: DS.Size.rowMinHeight)
        #endif
        .contentShape(Capsule())
    }
}

/// The Today header's planning chip, re-read every minute so "Shut down" appears when working hours end.
struct DayPlanTodayPrompt: View {
    @Environment(Store.self) private var store
    /// Where another control already offers planning (iOS lists overdue work), the "Plan your day" chip steps aside.
    var offersPlanElsewhere = false
    let plan: () -> Void
    let shutdown: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let prompt = store.dayPlanPrompt(now: context.date), !(prompt == .plan && offersPlanElsewhere) {
                DayPlanHeaderChip(prompt: prompt, plan: plan, shutdown: shutdown)
            }
        }
    }
}

// MARK: - Fixture

#if DEBUG
/// Screenshot and UI-test data for the daily planning ritual. Launch with `--dayplan-fixture` next to `--preview` or
/// `--uitesting`: nine tasks due today (six estimated for 6h 45m, three not), four calendar events, 6h 45m of estimated work
/// against 4h 45m free, and three tasks already finished today. Local fixture workspace only.
enum DayPlanFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--dayplan-fixture") }
    /// `--dayplan-step=estimate|timeblock|done` (or the Mac's `--capture-dayplan=`) opens the sheet at that step: timeblock shows the
    /// Fit preview, done has it applied.
    static var step: String? {
        let arguments = ProcessInfo.processInfo.arguments
        for prefix in ["--dayplan-step=", "--capture-dayplan="] { if let value = arguments.first(where: { $0.hasPrefix(prefix) }) { return String(value.dropFirst(prefix.count)) } }
        return nil
    }
    /// The step a fixture launch opens at; nil opens the normal flow.
    static var start: DayPlanStep? {
        switch step { case "estimate": .estimate; case "timeblock": .timeBlock; case "done": .done; default: nil }
    }
    static let hours = WorkingHours(start: 9 * 60, end: 17 * 60, weekdays: Set(1...7))
    static func events(on day: Date, calendar: Calendar = .current) -> [PlannerEvent] {
        let start = calendar.dateInterval(of: .day, for: day)?.start ?? day
        func at(_ hour: Int, _ minute: Int) -> Date { start.addingTimeInterval(Double(hour * 60 + minute) * 60) }
        return [PlannerEvent(id: "fx-standup", calendarID: "work", title: "Team standup", source: "Work", start: at(9, 30), end: at(10, 0), color: "#1BADF8"),
                PlannerEvent(id: "fx-review", calendarID: "work", title: "Design review", source: "Work", start: at(11, 0), end: at(12, 30), color: "#1BADF8"),
                PlannerEvent(id: "fx-lunch", calendarID: "personal", title: "Lunch with Sam", source: "Personal", start: at(12, 30), end: at(13, 15), color: "#63DA38"),
                PlannerEvent(id: "fx-oneonone", calendarID: "work", title: "1:1 with Alex", source: "Work", start: at(15, 30), end: at(16, 0), color: "#1BADF8")]
    }
    /// An all-day event for the Calendar's all-day strip (round 3 re-shoot). Not counted as busy time.
    static func allDayEvents(on day: Date, calendar: Calendar = .current) -> [PlannerEvent] {
        let start = calendar.dateInterval(of: .day, for: day)?.start ?? day
        return [PlannerEvent(id: "fx-birthday", calendarID: "personal", title: "Mum’s birthday", source: "Personal", start: start,
                             end: start.addingTimeInterval(86_400), allDay: true, color: "#63DA38")]
    }
    /// Three projects, so placed blocks show their colours (round 3: the grid was all grey with project-less tasks).
    static func projects(user: String) -> [Record] {
        [("dayplan-work", "Work", "#2F5BD3"), ("dayplan-studio", "Studio", "#4338A8"), ("dayplan-home", "Home", "#0B7B73")].enumerated().map { index, row in
            Record(["id": .string(row.0), "name": .string(row.1), "user_id": .string(user), "color": .string(row.2), "order_index": .number(Double(index + 10))])
        }
    }
    /// `shutdown` also finishes the first three, so the review has six done and six open. Completions are seconds old, so they count
    /// as today at any hour.
    static func tasks(user: String, now: Date = Date(), shutdown: Bool = false) -> [Record] {
        let rows: [(String, Int, Int?)] = [
            ("Draft the Q4 roadmap", 1, 120), ("Review the open pull requests", 2, 60), ("Prepare the client workshop", 2, 90),
            ("Write the release notes", 3, 45), ("Plan the next sprint", 3, 60), ("Reply to partner emails", 4, 30),
            ("Book travel for the offsite", 4, nil), ("Call the accountant", 4, nil), ("Tidy the shared drive", 4, nil)]
        var result = rows.enumerated().map { index, row -> Record in
            var task = Record.task(user: user, date: now)
            task["id"] = .string("dayplan-\(index)"); task["title"] = .string(row.0); task["priority"] = .number(Double(row.1))
            if let minutes = row.2 { task["duration_minutes"] = .number(Double(minutes)) }
            task["project_id"] = .string(["dayplan-work", "dayplan-studio", "dayplan-work", "dayplan-studio", "dayplan-work", "dayplan-home", "dayplan-home", "dayplan-home", "dayplan-work"][index])
            if shutdown && index < 3 { task["completed"] = .bool(true); task["completed_at"] = .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(index + 4) * 20))) }
            return task
        }
        for (index, title) in ["Send the weekly update", "Approve the invoices", "Fix the login typo"].enumerated() {
            var task = Record.task(user: user, date: now)
            task["id"] = .string("dayplan-done-\(index)"); task["title"] = .string(title); task["completed"] = .bool(true)
            task["completed_at"] = .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(index + 1) * 20)))
            result.append(task)
        }
        return result
    }
}
#endif
