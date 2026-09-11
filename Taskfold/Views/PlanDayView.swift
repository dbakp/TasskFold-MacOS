import SwiftUI

/// What the planning sheet triages: today's overdue and due tasks, or the next seven days.
enum PlanKind: String, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: String { self == .day ? "Plan Your Day" : "Review This Week" }
}

/// Morning triage, one card at a time. Each decision is its own undoable change; the keyboard drives it:
/// T today, M tomorrow, D pick a date, Space complete, → skip.
struct PlanDayView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: PlanKind
    /// Captured once when the sheet opens; the live store changes as cards are handled, the queue must not.
    @State private var queue: [Record]
    @State private var index = 0
    init(kind: PlanKind, queue: [Record]) { self.kind = kind; _queue = State(initialValue: queue) }
    @State private var handled: [String: String] = [:]
    @State private var pickingDate = false
    @State private var picked = Date()
    @FocusState private var sheetFocused: Bool
    private var current: Record? { index < queue.count ? store.record("tasks", id: queue[index].id) ?? queue[index] : nil }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }

    var body: some View {
        VStack(spacing: 18) {
            header
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
        }
        .padding(22)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($sheetFocused)
        .onAppear { sheetFocused = true }
        .onKeyPress(phases: .down) { press in handle(press) }
        // Arrow keys belong to focus movement before they reach onKeyPress; the move command still arrives.
        .onMoveCommand { direction in if direction == .right, current != nil, !pickingDate { advance("Skip") { _ in } } }
        .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
            VStack(spacing: 12) {
                DatePicker("Date", selection: $picked, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Button("Cancel") { pickingDate = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Schedule") { pickingDate = false; advance("Scheduled") { workspace.reschedule([$0.id], to: Dates.day(picked), label: picked.formatted(date: .abbreviated, time: .omitted)) } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }.padding(14).frame(width: 300)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title).font(.title2.weight(.semibold))
                Spacer()
                Text(current == nil ? "All planned" : "\(min(index + 1, queue.count)) of \(queue.count)")
                    .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
                Button(current == nil ? "Done" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("closePlan")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.accentColor).frame(width: proxy.size.width * CGFloat(min(index, queue.count)) / CGFloat(max(1, queue.count)))
                        .animation(Transitions.Ease.smoothOut(Transitions.Duration.fast), value: index)
                }
            }
            .frame(height: 5)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(min(index, queue.count)) of \(queue.count) planned")
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
                Label("\(task["subtasks"].list.filter { $0.object["completed"]?.flag == true }.count) of \(task["subtasks"].list.count) subtasks done", systemImage: "checklist").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(CardSurface(radius: 16, elevated: true))
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            action("Today", "sun.max.fill", key: "T", tint: Color.taskfold, prominent: true) { workspace.reschedule([$0.id], to: Dates.day(Date()), label: "today") }
            action("Tomorrow", "sunrise.fill", key: "M", tint: .orange) { workspace.reschedule([$0.id], to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }
            Button { picked = current?.due ?? Date(); pickingDate = true } label: { actionLabel("Pick Date", "calendar", key: "D", tint: .blue) }
                .buttonStyle(PressableStyle(scale: 0.96)).accessibilityIdentifier("plan-pick")
            action("Complete", "checkmark.circle.fill", key: "Space", tint: .green) { workspace.complete($0) }
            action("Skip", "arrow.right", key: "→", tint: .secondary) { _ in }
        }
        .accessibilityElement(children: .contain)
    }
    private func action(_ title: String, _ symbol: String, key: String, tint: Color, prominent: Bool = false, perform: @escaping (Record) -> Void) -> some View {
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
        .foregroundStyle(prominent ? Color.white : tint)
        .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
    }
    /// The card shortcuts. Letters are plain keys, so they only apply while the sheet itself has focus.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard current != nil, !pickingDate, press.modifiers.isEmpty else { return .ignored }
        switch press.key {
        case .space: advance("Complete") { workspace.complete($0) }
        case KeyEquivalent("t"): advance("Today") { workspace.reschedule([$0.id], to: Dates.day(Date()), label: "today") }
        case KeyEquivalent("m"): advance("Tomorrow") { workspace.reschedule([$0.id], to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }
        case KeyEquivalent("d"): picked = current?.due ?? Date(); pickingDate = true
        default: return .ignored
        }
        return .handled
    }
    private func advance(_ label: String, _ perform: (Record) -> Void) {
        guard let task = current else { return }
        perform(task)
        handled[task.id] = label
        withAnimation(layout) { index += 1 }
    }

    private var summary: some View {
        let counts = Dictionary(grouping: handled.values, by: { $0 }).mapValues(\.count)
        return VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(Color.accentColor)
            Text(kind == .day ? "Your day is planned" : "Your week is reviewed").font(.title3.weight(.semibold))
            if counts.isEmpty { Text("Nothing needed a decision.").font(.callout).foregroundStyle(.secondary) }
            else { Text(counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key.lowercased())" }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary) }
            Button(kind == .day ? "Start the Day" : "Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("finishPlan")
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
