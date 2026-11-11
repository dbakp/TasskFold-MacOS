import SwiftUI

/// What the planning sheet triages: today's overdue and due tasks, or the next seven days.
enum PlanKind: String, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: String { self == .day ? "Plan Your Day" : "Review This Week" }
}

/// Morning triage, one card at a time. Each decision is its own undoable change; the keyboard drives it:
/// T today, M tomorrow, D pick a date, Space complete, → skip.
///
/// "Plan Your Day" continues past triage into Estimate, Time-block and Done (Views/DayPlanViews.swift). Keys:
/// ⏎ next step, ⌘Z undo, 1–5 estimate chips, F Fit my day. The weekly review is triage only.
struct PlanDayView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openFocusSession) private var openFocusSession
    let kind: PlanKind
    /// Captured once when the sheet opens; the live store changes as cards are handled, the queue must not.
    @State private var queue: [Record]
    @State private var index = 0
    init(kind: PlanKind, queue: [Record], start: DayPlanStep? = nil) {
        self.kind = kind; _queue = State(initialValue: queue)
        _step = State(initialValue: kind == .day ? (start ?? (queue.isEmpty ? .estimate : .triage)) : .triage)
    }
    @State private var step: DayPlanStep
    @State private var plan = DayPlanModel()
    private var guided: Bool { kind == .day }
    private var inTriage: Bool { !guided || step == .triage }
    private var eligible: [DayPlanStep] { DayPlan.eligibleSteps(triageCount: queue.count, today: plan.tasks) }
    @State private var binding: WorkspaceBinding?
    @State private var session: UUID?
    @State private var failure: String?
    @State private var handled: [String: String] = [:]
    @State private var pickingDate = false
    @State private var picked = Date()
    @FocusState private var sheetFocused: Bool
    private var current: Record? { index < queue.count ? (try? store.selectionRecord(queue[index].id)) ?? queue[index] : nil }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }

    var body: some View {
        VStack(spacing: 18) {
            header
            if inTriage {
                ZStack {
                    if let task = current {
                        card(task)
                            .id(task.id)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.97)),
                                removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.94))))
                    } else {
                        summary.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
                .animation(layout, value: index)
                if current != nil { actions }
            } else {
                ScrollView { stepContent.padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .topLeading) }
                    .frame(height: step == .timeBlock ? 540 : step == .done ? 380 : 440)
                stepFooter
            }
        }
        .padding(22)
        .frame(width: guided && step == .timeBlock ? 820 : 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($sheetFocused)
        .background {
            // ⌘Z inside the sheet undoes the last estimate, placement or Fit my day. The sheet has its own responder chain, so
            // the main window's Undo item is not reachable from here.
            if guided && step != .triage {
                Button("Undo") { plan.undo() }.keyboardShortcut("z", modifiers: .command).opacity(0).frame(width: 0, height: 0)
                    .disabled(plan.undoRequest == nil).accessibilityHidden(true)
            }
        }
        .onAppear {
            sheetFocused = true
            if binding == nil { binding = .init(account: store.userID, generation: store.workspaceGeneration); session = store.backend.reminderSessionIncarnation }
            guard guided else { return }
            plan.attach(store: store, run: { name, body in workspace.run(name, body) }, undo: { request in
                if store.canApplyHistory(request), let manager = workspace.undoManager, manager.canUndo { manager.undo(); return true }
                return store.undo(request)
            })
            #if DEBUG
            // Screenshot fixtures: the time-block step shows the Fit preview, the done step has it applied.
            if DayPlanFixture.enabled, let name = DayPlanFixture.step {
                if name == "timeblock" { plan.showFit() }
                if name == "done" { plan.showFit(); plan.applyFit(); plan.markPlanned() }
            }
            #endif
        }
        .alert("Could not save decision", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        .alert("Could not save", isPresented: Binding(get: { plan.failure != nil }, set: { if !$0 { plan.failure = nil } })) { Button("OK") { plan.failure = nil } } message: { Text(plan.failure ?? "") }
        .onKeyPress(phases: .down) { press in handle(press) }
        // Arrow keys belong to focus movement before they reach onKeyPress; the move command still arrives.
        .onMoveCommand { direction in
            if guided && step == .estimate {
                if direction == .up { plan.moveHighlight(-1) } else if direction == .down { plan.moveHighlight(1) }
            } else if inTriage, direction == .right, current != nil, !pickingDate { advance("Skip") { _ in true } }
        }
        .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
            VStack(spacing: 12) {
                DatePicker("Date", selection: $picked, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Button("Cancel") { pickingDate = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Schedule") { pickingDate = false; advance("Scheduled") { schedule($0, day: Dates.day(picked)) } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }.padding(14).frame(width: 300)
        }
    }

    // MARK: Guided steps

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .estimate: DayPlanEstimateStep(model: plan)
        case .timeBlock: DayPlanTimeBlockStep(model: plan)
        case .done: DayPlanDoneStep(model: plan, startFocus: startFocus, close: { dismiss() })
        case .triage: EmptyView()
        }
    }
    private var stepFooter: some View {
        HStack(spacing: 10) {
            if step != .done, plan.preview == nil, DayPlan.previous(before: step, eligible: eligible) != nil {
                Button("Back") { goBack() }.accessibilityIdentifier("dayPlanBack")
            }
            Spacer()
            if step != .done {
                Button(plan.preview != nil ? "Apply" : (DayPlan.next(after: step, eligible: eligible) == .done ? "Finish" : "Next")) { goNext() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier(plan.preview != nil ? "dayPlanApply" : "dayPlanNext")
                    .accessibilityHint(plan.preview != nil ? "Places the proposed tasks on your day. You can undo it." : "Shortcut Return")
            }
        }
    }
    private func goNext() {
        if step == .timeBlock, plan.preview != nil { plan.applyFit(); return }
        go(DayPlan.next(after: step, eligible: eligible))
    }
    private func goBack() { if let previous = DayPlan.previous(before: step, eligible: eligible) { go(previous) } }
    private func go(_ target: DayPlanStep) {
        plan.preview = nil; plan.customFor = nil
        withAnimation(layout) { step = target }
        if target == .done { plan.markPlanned() }
    }
    private func startFocus() {
        let open = openFocusSession
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.title2.weight(.semibold))
                Spacer()
                if guided && step != .triage {
                    Text(step.accessibilityLabel.replacingOccurrences(of: ", ", with: " · ")).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(current == nil ? "All planned" : "\(min(index + 1, queue.count)) of \(queue.count)")
                        .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Button(guided && step != .triage ? "Close" : (current == nil ? "Done" : "Close")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("closePlan")
            }
            if guided { DayPlanStepIndicator(step: step, eligible: eligible) }
            if inTriage {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.taskfold).frame(width: proxy.size.width * CGFloat(min(index, queue.count)) / CGFloat(max(1, queue.count)))
                            .animation(Transitions.Ease.smoothOut(Transitions.Duration.fast), value: index)
                    }
                }
                .frame(height: 5)
                .accessibilityElement()
                .accessibilityLabel("Progress")
                .accessibilityValue("\(min(index, queue.count)) of \(queue.count) planned")
            }
        }
    }

    private func card(_ task: Record) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if task.priority < 4 { Label("P\(task.priority)", systemImage: "flag.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.priority(task.priority)) }
                if let project = store.record("projects", id: task.string("project_id")) {
                    HStack(spacing: 5) { Circle().fill(Color.project(project.string("color"))).frame(width: 7, height: 7); Text(project.name) }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                if let due = task.due {
                    let today = Calendar.current.startOfDay(for: Date())
                    let overdueDays = Calendar.current.dateComponents([.day], from: due, to: today).day ?? 0
                    Label(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), systemImage: overdueDays > 0 ? "exclamationmark.circle" : "calendar")
                        .font(.caption).foregroundStyle(overdueDays > 0 ? Color.red : Color.secondary)
                    if overdueDays > 0 { Text(overdueDays == 1 ? "1 day overdue" : "\(overdueDays) days overdue").font(.caption.weight(.medium)).foregroundStyle(.red) }
                }
            }
            Text(task.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("planCardTitle")
            if !task.string("description").isEmpty {
                if Linkify.links(in: task.string("description")).isEmpty {
                    Text(task.string("description")).foregroundStyle(.secondary).lineLimit(5)
                } else {
                    LinkText(text: task.string("description"), color: .secondaryLabelColor, linkColor: NSColor(Color.taskfold), lineLimit: 5)
                }
            }
            if !task["subtasks"].list.isEmpty {
                let progress = store.subtaskProgress(task)
                Label("\(progress.completed) of \(progress.total) subtasks done", systemImage: "checklist").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(CardSurface(radius: 16, elevated: true))
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            actionRow
            if guided { planningActions }
            if guided {
                Button("Skip triage, go to estimates") { go(DayPlan.next(after: .triage, eligible: eligible)) }
                    .buttonStyle(.link).font(.callout).accessibilityIdentifier("planSkipTriage")
            }
        }
    }
    private var actionRow: some View {
        HStack(spacing: 8) {
            action("Today", "sun.max.fill", key: "T", tint: Color.taskfold, prominent: true) { schedule($0, day: Dates.day(Date())) }
            action("Tomorrow", "sunrise.fill", key: "M", tint: .orange) { schedule($0, day: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)) }
            Button { picked = current?.due ?? Date(); pickingDate = true } label: { actionLabel("Pick Date", "calendar", key: "D", tint: .blue) }
                .buttonStyle(PressableStyle(scale: 0.96)).accessibilityIdentifier("plan-pick")
            action("Complete", "checkmark.circle.fill", key: "Space", tint: .green) { store.toggleNativeTask($0) }
            action("Skip", "arrow.right", key: "→", tint: .secondary) { _ in true }
        }
        .accessibilityElement(children: .contain)
    }
    /// This Evening and Someday: the two calm shelves, offered where they are valid for the card in view.
    private var planningActions: some View {
        let id = current?.id ?? ""
        return HStack(spacing: 8) {
            miniAction("This Evening", "moon.fill", key: "E", enabled: store.canMoveToEvening([id])) { advance("This Evening") { store.moveToEvening([$0.id]) } }
            miniAction("Someday", "moon.zzz", key: "S", enabled: store.canMoveToSomeday([id])) { advance("Someday") { store.moveToSomeday([$0.id]) } }
        }
    }
    private func miniAction(_ title: String, _ symbol: String, key: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.callout.weight(.semibold))
                Text(title).font(.caption.weight(.semibold))
                Text(key).font(.caption2.weight(.medium)).monospaced().opacity(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(Color.indigo)
            .background(Color.indigo.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.97)).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier("plan-" + title.lowercased().replacingOccurrences(of: " ", with: ""))
        .accessibilityHint("Shortcut \(key)")
    }
    private func action(_ title: String, _ symbol: String, key: String, tint: Color, prominent: Bool = false, perform: @escaping (Record) -> Bool) -> some View {
        Button { advance(title, perform) } label: { actionLabel(title, symbol, key: key, tint: tint, prominent: prominent) }
            .buttonStyle(PressableStyle(scale: 0.96))
            .accessibilityIdentifier("plan-\(title.lowercased())")
            .accessibilityHint("Shortcut \(key)")
    }
    private func actionLabel(_ title: String, _ symbol: String, key: String, tint: Color, prominent: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title3.weight(.semibold))
            Text(title).font(.caption.weight(.semibold))
            Text(key).font(.caption2.weight(.medium)).monospaced().opacity(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 68)
        .foregroundStyle(prominent ? Color.contrastingForeground(on: tint) : tint)
        .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
    }
    /// The card shortcuts. Letters are plain keys, so they only apply while the sheet itself has focus.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        if guided && step != .triage {
            guard plan.customFor == nil, plan.placing == nil else { return .ignored }
            switch step {
            case .estimate:
                guard let digit = press.characters.first.flatMap({ Int(String($0)) }), (1...5).contains(digit) else { return .ignored }
                plan.applyChip(digit - 1); return .handled
            case .timeBlock:
                guard press.key == KeyEquivalent("f"), plan.preview == nil, !plan.unscheduled.isEmpty else { return .ignored }
                plan.showFit(); return .handled
            default: return .ignored
            }
        }
        guard let card = current, !pickingDate else { return .ignored }
        switch press.key {
        case KeyEquivalent("e") where guided && store.canMoveToEvening([card.id]): advance("This Evening") { store.moveToEvening([$0.id]) }
        case KeyEquivalent("s") where guided && store.canMoveToSomeday([card.id]): advance("Someday") { store.moveToSomeday([$0.id]) }
        case .space: advance("Complete") { store.toggleNativeTask($0) }
        case KeyEquivalent("t"): advance("Today") { schedule($0, day: Dates.day(Date())) }
        case KeyEquivalent("m"): advance("Tomorrow") { schedule($0, day: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)) }
        case KeyEquivalent("d"): picked = current?.due ?? Date(); pickingDate = true
        default: return .ignored
        }
        return .handled
    }
    private func advance(_ label: String, _ perform: (Record) -> Bool) {
        guard let task = current else { return }
        guard binding == WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), session == store.backend.reminderSessionIncarnation, let live = try? store.selectionRecord(task.id), live == task, !live.completed else { failure = "This task or workspace changed. Close planning and reopen the current list."; return }
        guard perform(task) else { failure = store.error ?? "This decision could not be saved. Try again."; store.error = nil; return }
        handled[task.id] = label
        withAnimation(layout) { index += 1 }
    }

    private func schedule(_ task: Record, day: String) -> Bool {
        do {
            let fields = TaskPlanner.dayFields(task: task, day: day)
            return try store.commitSelection([task], action: { _ in .patch(fields) })
        } catch { store.error = error.localizedDescription; return false }
    }

    private var summary: some View {
        let counts = Dictionary(grouping: handled.values, by: { $0 }).mapValues(\.count)
        return VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(Color.taskfold)
            Text(guided ? "Triage complete" : (kind == .day ? "Your day is planned" : "Your week is reviewed")).font(.title3.weight(.semibold))
            if counts.isEmpty { Text("Nothing needed a decision.").font(.callout).foregroundStyle(.secondary) }
            else { Text(counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.lowercased())" }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary) }
            if guided {
                Button("Estimate your day") { go(DayPlan.next(after: .triage, eligible: eligible)) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("planContinue")
                Button("Finish for now") { dismiss() }.buttonStyle(.link).accessibilityIdentifier("finishPlan")
            } else {
                Button(kind == .day ? "Start the Day" : "Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("finishPlan")
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .modifier(CardSurface(radius: 16))
        .onAppear { Feedback.complete() }
    }
}

extension Workspace {
    /// The triage queue: overdue and today's open tasks, or open tasks over the next seven days, in list order.
    func planQueue(_ kind: PlanKind) -> [Record] {
        let today = Dates.day(Date())
        let open = store.tasks.filter { !$0.completed && !$0.string("due_date").isEmpty }
        let overdue = arranged(open.filter { $0.string("due_date") < today }, key: "overdue").sorted { $0.string("due_date") < $1.string("due_date") }
        let days: [String] = (0..<(kind == .day ? 1 : 7)).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Date()).map(Dates.day) }
        return overdue + days.flatMap { day in arranged(open.filter { $0.string("due_date") == day }, key: day) }
    }
}
