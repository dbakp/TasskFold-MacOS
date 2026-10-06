import SwiftUI
import EventKit

/// One timeline and scheduling form for both apps. Display height never invents task duration.
struct HourlyPlannerView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var textSize
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    private var summaryScrolls: Bool {
        #if os(iOS)
        textSize.isAccessibilitySize || verticalSizeClass == .compact
        #else
        textSize.isAccessibilitySize
        #endif
    }
    let day: Date
    let tasks: [Record]
    @State private var busy = CalendarBusyStore.shared
    @State private var settings = false
    private var events: [PlannerEvent] { busy.events }
    private var hours: WorkingHours { store.workingHours }
    let open: (Record) -> Void
    let complete: (Record) -> Void
    let save: (Record, [String: JSON]) -> Bool
    let undo: () -> Void
    let undoDepth: Int
    @State private var request: PlannerScheduleRequest?
    @State private var feedback: String?
    @State private var feedbackDepth: Int?
    @State private var error: String?
    @State private var allDayRequest = 0
    @State private var timelineRequest: Int?
    private var calendar: Calendar { .current }
    private let scale: CGFloat = 1.5
    private let gutter: CGFloat = 70
    private var bounds: DateInterval { calendar.dateInterval(of: .day, for: day)! }
    private var blocks: [PlannerBlock] { TaskPlanner.blocks(tasks, on: day) }
    private var allDay: [Record] { TaskPlanner.allDay(tasks, on: day) }
    private var capacity: PlannerCapacity { TaskPlanner.capacity(tasks, events: events, on: day, hours: hours) }
    private func clock(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }
    private func choose(_ task: Record?, at start: Date? = nil) {
        request = PlannerScheduleRequest(task: task, start: start ?? task.flatMap { TaskPlanning.start($0) } ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day)
    }
    var body: some View {
        VStack(spacing: 0) {
            if !summaryScrolls { summary }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if summaryScrolls { summary.id("summary") }
                        allDayLane.id("all-day")
                        timeline
                    }.padding(.horizontal, 12).padding(.bottom, 40)
                }
                .task(id: TaskPlanner.dayKey(day)) {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    reader.scrollTo(summaryScrolls ? "summary" : "hour-\(initialHourIndex)", anchor: .top)
                }
                .onChange(of: TaskPlanner.dayKey(day)) { _, _ in reader.scrollTo(summaryScrolls ? "summary" : "hour-\(initialHourIndex)", anchor: .top) }
                .onChange(of: allDayRequest) { _, _ in reader.scrollTo("all-day", anchor: .top) }
                .onChange(of: timelineRequest) { _, index in if let index { reader.scrollTo("hour-\(index)", anchor: .top) } }
            }
            if let feedback {
                HStack {
                    Text(feedback).font(.callout).lineLimit(3)
                    Spacer()
                    if feedbackDepth == undoDepth { Button("Undo") { undo(); self.feedback = nil; feedbackDepth = nil }.accessibilityIdentifier("plannerUndo") }
                    Button { self.feedback = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss scheduling message")
                }.padding(12).background(.regularMaterial)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hourlyPlanner")
        .task(id: "\(store.userID)-\(TaskPlanner.dayKey(day))-\(busy.revision)") {
            busy.bind(account: store.signedIn ? store.userID : "")
            await busy.refresh(on: day)
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await busy.refresh(on: day) } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in Task { await busy.refresh(on: day) } }
        .onChange(of: phase) { _, value in if value == .active { Task { await busy.refresh(on: day) } } }
        .sheet(isPresented: $settings) { PlannerSettingsView(busy: busy) }
        .sheet(item: $request) { request in
            PlannerSchedulingSheet(request: request, tasks: tasks, events: events) { task, fields in
                if apply(task, fields: fields, message: "Scheduled") { self.request = nil }
            }
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 430)
            #endif
        }
        .alert("Could not schedule", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private var initialHour: Int {
        let first = blocks.first.map { calendar.component(.hour, from: $0.clippedStart) } ?? 9
        return max(0, min(9, first) - 1)
    }
    private var initialHourIndex: Int { TaskPlanner.slots(on: day, every: 60).firstIndex { calendar.component(.hour, from: $0) == initialHour } ?? 0 }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if textSize.isAccessibilitySize {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) { scheduleButton; Spacer(minLength: 8); settingsButton }
                estimateSummary
                allDayButton
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline)
                    Spacer(minLength: 8)
                    scheduleButton; settingsButton
                }
                HStack { estimateSummary; Spacer(minLength: 4); allDayButton }
            }
            Text(workingSummary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerWorkingCapacity")
            Text(busy.status).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
    private var estimateSummary: some View {
        Text("\(capacity.estimatedMinutes) min estimated · \(capacity.unknownTasks) without estimates")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerCapacity")
    }
    private var workingSummary: String {
        if busy.ready { return "\(capacity.workingMinutes) min working day · \(capacity.busyMinutes) min calendar busy · \(capacity.afterKnownWork) min after known work" }
        if busy.connected { return "\(capacity.workingMinutes) min working day · calendar data incomplete" }
        return "\(capacity.workingMinutes) min working day · \(capacity.workingMinutes - capacity.estimatedMinutes) min after task estimates"
    }
    private var scheduleButton: some View {
        Button { choose(nil) } label: { Label("Schedule", systemImage: "clock.badge.plus").frame(minHeight: 44) }.accessibilityIdentifier("plannerSchedule")
    }
    private var settingsButton: some View {
        Button { settings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Planner settings").accessibilityIdentifier("plannerSettings")
    }
    private var allDayButton: some View {
        Button { allDayRequest += 1 } label: { Text("All day (\(allDay.count))").font(.caption).frame(minHeight: 44) }.accessibilityIdentifier("plannerShowAllDay")
    }
    private var allDayLane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ALL DAY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
            if allDay.isEmpty { Text("Tasks with a date and no time appear here.").font(.caption).foregroundStyle(.secondary) }
            ForEach(allDay) { task in
                Group {
                    if textSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) {
                            taskTitle(task)
                            HStack(spacing: 12) { completeButton(task); estimate(task); Spacer(minLength: 8); taskScheduleButton(task) }
                        }
                    } else {
                        HStack(spacing: 10) { completeButton(task); taskTitle(task); estimate(task); taskScheduleButton(task) }
                    }
                }.padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(.top, 12)
    }
    private func taskTitle(_ task: Record) -> some View {
        Button { open(task) } label: { Text(task.title).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }.buttonStyle(.plain)
    }
    private func completeButton(_ task: Record) -> some View {
        Button { complete(task) } label: { Image(systemName: "circle").font(.system(size: 24)).foregroundStyle(Color.taskfold).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Complete " + task.title)
    }
    private func taskScheduleButton(_ task: Record) -> some View {
        Button { choose(task) } label: { Image(systemName: "clock").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Schedule " + task.title).accessibilityIdentifier("plannerAllDay-" + task.id)
    }
    private func estimate(_ task: Record) -> some View {
        Text(task.durationMinutes.map { "\($0)m" } ?? "No estimate").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var timeline: some View {
        let ticks = TaskPlanner.slots(on: day, every: 60)
        let minutes = bounds.duration / 60
        return GeometryReader { geometry in
            let available = max(1, geometry.size.width - gutter)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(ticks.indices, id: \.self) { index in Color.clear.frame(height: 60 * scale).id("hour-\(index)") }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, date in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(clock(date)).font(.caption).monospacedDigit()
                            if bounds.duration != 86400 { Text(calendar.timeZone.abbreviation(for: date) ?? calendar.timeZone.identifier).font(.system(size: 9)) }
                        }.foregroundStyle(.secondary).frame(width: gutter - 10, alignment: .trailing)
                        Button { choose(nil, at: date) } label: {
                            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1).frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
                        }.buttonStyle(.plain).accessibilityLabel("Schedule a task at \(clock(date))").accessibilityIdentifier("plannerSlot-\(index)")
                    }.offset(y: CGFloat(date.timeIntervalSince(bounds.start) / 60) * scale)
                }
                ForEach(events.filter { $0.start < bounds.end && $0.end > bounds.start }) { event in
                    let start = max(event.start, bounds.start), end = min(event.end, bounds.end)
                    VStack(alignment: .leading) { Text(event.title).font(.caption).lineLimit(1) }
                        .padding(4).frame(width: available, height: max(6, CGFloat(end.timeIntervalSince(start) / 60) * scale), alignment: .topLeading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .offset(x: gutter, y: CGFloat(start.timeIntervalSince(bounds.start) / 60) * scale)
                        .accessibilityLabel("Calendar: \(event.title), \(clock(start)) to \(clock(end))")
                        .allowsHitTesting(false)
                }
                ForEach(blocks) { block in
                    let width = max(1, available / CGFloat(block.laneCount) - 4)
                    PlannerBlockCard(block: block, width: width, scale: scale, maxLength: minutes - block.minute,
                        open: { open(block.task) }, complete: { complete(block.task) }, schedule: { choose(block.task) },
                        move: { delta in shift(block, minutes: delta) }, resize: { delta in resize(block, minutes: delta) },
                        removeTime: { _ = apply(block.task, fields: ["due_time": .null, "time_zone": .null, "scheduled_at": .null, "due_date": .string(TaskPlanner.dayKey(day))], message: "Moved to all day") })
                        .offset(x: gutter + CGFloat(block.lane) * (width + 4), y: CGFloat(block.minute) * scale)
                }
            }
        }.frame(height: CGFloat(minutes) * scale + 44).coordinateSpace(name: "planner-timeline")
    }
    @discardableResult private func apply(_ task: Record, fields: [String: JSON], message: String) -> Bool {
        guard save(task, fields) else { return false }
        var changed = task; for (key, value) in fields { changed[key] = value }
        if let start = TaskPlanning.start(changed), start >= bounds.start && start < bounds.end {
            timelineRequest = max(0, Int(start.timeIntervalSince(bounds.start) / 3600) - 1)
        }
        let overlaps = TaskPlanning.start(changed).map { TaskPlanner.conflicts(task: changed, start: $0, minutes: changed.durationMinutes, tasks: tasks, events: events) } ?? []
        feedback = overlaps.isEmpty ? message : message + " · overlaps " + overlaps.prefix(3).joined(separator: ", ")
        // The parent updates its undo depth on the next render.
        feedbackDepth = undoDepth + 1
        return true
    }
    private func shift(_ block: PlannerBlock, minutes: Int) {
        guard minutes != 0 else { return }
        do { _ = apply(block.task, fields: try TaskPlanner.fields(task: block.task, start: block.start.addingTimeInterval(Double(minutes * 60))), message: "Moved to \(clock(block.start.addingTimeInterval(Double(minutes * 60))))") }
        catch { self.error = error.localizedDescription }
    }
    private func resize(_ block: PlannerBlock, minutes: Int) {
        guard minutes != 0, let duration = TaskPlanner.resizedMinutes(task: block.task, delta: minutes), duration != block.task.durationMinutes else { return }
        _ = apply(block.task, fields: ["duration_minutes": .number(Double(duration))], message: "Estimate: \(duration) min")
    }
}

private struct PlannerScheduleRequest: Identifiable {
    var id = UUID()
    var task: Record?
    var start: Date
}

private struct PlannerSchedulingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: PlannerScheduleRequest
    let tasks: [Record]
    let events: [PlannerEvent]
    let save: (Record, [String: JSON]) -> Void
    @State private var chosen: Record?
    init(request: PlannerScheduleRequest, tasks: [Record], events: [PlannerEvent], save: @escaping (Record, [String: JSON]) -> Void) {
        self.request = request; self.tasks = tasks; self.events = events; self.save = save
        _chosen = State(initialValue: request.task)
    }
    var body: some View {
        NavigationStack {
            if let task = chosen {
                PlannerScheduleForm(task: task, start: request.start, tasks: tasks, events: events) { save(task, $0) }
            } else {
                List {
                    Section { Text("Choose a task for " + request.start.formatted(.dateTime.hour().minute()) + ". Its deadline will stay the same.").foregroundStyle(.secondary) }
                    ForEach(tasks.filter { !$0.completed }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { task in
                        Button { chosen = task } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).foregroundStyle(.primary)
                                Text(task.durationMinutes.map { "\($0) min" } ?? "No estimate").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("plannerChoose-" + task.id)
                    }
                    if tasks.allSatisfy(\.completed) { Text("Add a task to start planning your day.").foregroundStyle(.secondary) }
                }
                .navigationTitle("Schedule a task")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            }
        }
    }
}

private struct PlannerBlockCard: View {
    let block: PlannerBlock
    let width: CGFloat, scale: CGFloat
    let maxLength: Double
    let open: () -> Void, complete: () -> Void, schedule: () -> Void
    let move: (Int) -> Void, resize: (Int) -> Void, removeTime: () -> Void
    @State private var movement: CGFloat = 0
    @State private var resizing: CGFloat = 0
    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("planner-timeline")).onChanged { movement = $0.translation.height }.onEnded { value in movement = 0; move(Int((value.translation.height / scale / 15).rounded()) * 15) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: complete) { Image(systemName: "circle").font(.caption) }.buttonStyle(.plain).accessibilityLabel("Complete " + block.task.title)
                Text(block.task.title).font(.subheadline.weight(.medium)).lineLimit(block.renderLength < 40 ? 1 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            }
            Text((block.start < block.clippedStart ? "Continues" : block.start.formatted(.dateTime.hour().minute())) + " · " + (block.task.durationMinutes.map { "\($0)m" } ?? "No estimate"))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, block.end == nil ? 4 : 8)
        .frame(width: width, height: max(36, min(CGFloat(maxLength) * scale, CGFloat(block.renderLength) * scale + resizing)), alignment: .topLeading)
        .background(Color.taskfold.opacity(block.end == nil ? 0.06 : 0.14), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.taskfold.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: block.end == nil ? [4, 3] : [])) }
        .contentShape(.rect).onTapGesture(perform: open)
        #if os(iOS)
        .gesture(LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(minimumDistance: 8, coordinateSpace: .named("planner-timeline"))).onChanged { value in if case .second(true, let drag?) = value { movement = drag.translation.height } }.onEnded { value in movement = 0; if case .second(true, let drag?) = value { move(Int((drag.translation.height / scale / 15).rounded()) * 15) } })
        #else
        .gesture(moveDrag)
        #endif
        .overlay(alignment: .bottom) {
            if block.end != nil {
                Capsule().fill(Color.taskfold.opacity(0.65)).frame(width: min(30, width / 2), height: 3)
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .bottom).padding(.bottom, 2).contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("planner-timeline")).onChanged { resizing = $0.translation.height }.onEnded { value in resizing = 0; resize(Int((value.translation.height / scale / 15).rounded()) * 15) })
                    .accessibilityLabel("Resize estimate for " + block.task.title)
                    .accessibilityAdjustableAction { direction in resize(direction == .increment ? 15 : -15) }
                    .accessibilityIdentifier("plannerResize-" + block.id)
            }
        }
        .offset(y: movement)
        .zIndex(movement == 0 && resizing == 0 ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plannerBlock-" + block.id)
        .accessibilityAction(named: "Schedule") { schedule() }
        .accessibilityAction(named: "15 minutes earlier") { move(-15) }
        .accessibilityAction(named: "15 minutes later") { move(15) }
        .contextMenu {
            Button("Open task", action: open)
            Button("Schedule…", action: schedule)
            Button("15 minutes earlier") { move(-15) }
            Button("15 minutes later") { move(15) }
            if block.end != nil { Button("Add 15 minutes") { resize(15) }; Button("Remove 15 minutes") { resize(-15) } }
            Button("Move to all day", action: removeTime)
        }
    }
}

private struct PlannerScheduleForm: View {
    @Environment(\.dismiss) private var dismiss
    let task: Record
    let tasks: [Record]
    let events: [PlannerEvent]
    let save: ([String: JSON]) -> Void
    @State private var start: Date
    @State private var fixed: Bool
    @State private var estimated: Bool
    @State private var estimate: String
    @State private var error: String?
    init(task: Record, start: Date, tasks: [Record], events: [PlannerEvent], save: @escaping ([String: JSON]) -> Void) {
        self.task = task; self.tasks = tasks; self.events = events; self.save = save
        _start = State(initialValue: start); _fixed = State(initialValue: !task.string("time_zone").isEmpty || task.string("due_time").isEmpty)
        _estimated = State(initialValue: task.durationMinutes != nil); _estimate = State(initialValue: task.durationMinutes.map(String.init) ?? "")
    }
    private var overlaps: [String] { TaskPlanner.conflicts(task: task, start: start, minutes: estimated ? Int(estimate) : nil, tasks: tasks, events: events) }
    var body: some View {
        Form {
            Section {
                Text(task.title).font(.headline)
                DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("plannerStart")
                Toggle("Fixed time", isOn: $fixed).accessibilityIdentifier("plannerFixedTime")
                Text(fixed ? "Keeps the same moment when you travel. Displayed in \(TimeZone.current.identifier)." : "Keeps this clock time when you travel.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Estimate") {
                Toggle("Set an estimate", isOn: $estimated).accessibilityIdentifier("plannerHasEstimate")
                if estimated { TextField("Minutes", text: $estimate).accessibilityIdentifier("plannerEstimate")
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                }
                Text(estimated ? "Choose 1–10,080 minutes. Resize the block to adjust later." : "The timeline shows an anchor. No time is reserved without an estimate.").font(.caption).foregroundStyle(.secondary)
            }
            if let deadline = task.deadline { Section("Deadline") { Text(deadline.formatted(date: .abbreviated, time: .omitted)); Text("Scheduling keeps this deadline.").font(.caption).foregroundStyle(.secondary) } }
            if !overlaps.isEmpty { Section("Overlaps") { ForEach(Array(overlaps.enumerated()), id: \.offset) { _, title in Text(title) }; Text("You can keep these overlaps or choose another time.").font(.caption).foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle("Schedule task")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { submit() }.accessibilityIdentifier("plannerSave") }
        }
    }
    private func submit() {
        do {
            let minutes = estimated ? Int(estimate.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            if estimated && (minutes == nil || !(1...10080).contains(minutes!)) { throw PlannerFailure(message: "Choose an estimate between 1 minute and 7 days.") }
            // DatePicker can retain seconds. Normalize before comparing DST folds or storing a clock minute.
            let rounded = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 60) * 60)
            let zone = fixed ? (task.string("time_zone").isEmpty ? TimeZone.current.identifier : task.string("time_zone")) : ""
            var fields = try TaskPlanner.fields(task: task, start: rounded, minutes: minutes, timeZone: zone)
            if !estimated { fields["duration_minutes"] = .null }
            save(fields)
        } catch { self.error = error.localizedDescription }
    }
}


/// Keep app-owned calendar totals current without requesting access from a widget.
struct WidgetCapacityRefresh: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content
            .task(id: "\(store.userID)-\(CalendarBusyStore.shared.revision)-\(phase == .active)") {
                guard store.signedIn, phase == .active else { return }
                await store.refreshWidgetCapacity()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(900)) } catch { return }
                    await store.refreshWidgetCapacity()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await store.refreshWidgetCapacity() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in Task { await store.refreshWidgetCapacity() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await store.refreshWidgetCapacity() } }
    }
}
