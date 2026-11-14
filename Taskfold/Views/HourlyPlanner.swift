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
    let work: ProductiveTaskReading
    private var tasks: [Record] { work.presentation }
    var calendarHeader: AnyView? = nil
    @State private var busy = CalendarBusyStore.shared
    @State private var settings = false
    @State private var largeTextTimeline = false
    @State private var preferList = false
    @State private var selectedEvent:PlannerCalendarRequest?
    private var usesAgenda: Bool { preferList || (textSize.isAccessibilitySize && !largeTextTimeline) }
    private func changeLayout() {if usesAgenda {preferList=false;largeTextTimeline=textSize.isAccessibilitySize} else {preferList=true;largeTextTimeline=false}}
    private var events: [PlannerEvent] { busy.events }
    private var hours: WorkingHours? { store.workingHours }
    let open: (Record) -> Void
    let complete: (Record) -> Void
    let save: (Record, [String: JSON]) -> Bool
    let undo: (EditHistoryRequest) -> Bool
    /// Applies a "Fit my day" proposal as one undoable change; each app routes it through its own undo wiring.
    var fitDay: ((DayPlanFit, [Record]) -> Bool)? = nil
    @State private var fitProposal: DayPlanFit?
    @State private var request: PlannerScheduleRequest?
    @State private var feedback: String?
    @State private var feedbackRequest: EditHistoryRequest?
    @State private var error: String?
    @State private var allDayRequest = 0
    @State private var timelineRequest: Int?
    @State private var agendaRequest: String?
    private var calendar: Calendar { .current }
    /// One scale with Plan your day (TimeGrid): 64pt per hour.
    private let scale: CGFloat = TimeGrid.pointsPerMinute
    @ScaledMetric(relativeTo: .caption) private var clockGutter: CGFloat = 70
    private var gutter: CGFloat { min(140, clockGutter) }
    private var bounds: DateInterval { calendar.dateInterval(of: .day, for: day)! }
    private func clock(_ date: Date) -> String { ClockFormat.string(date) }
    private func showCalendar(_ event:PlannerEvent) {
        selectedEvent=PlannerCalendarRequest(eventID:event.id,workspace:WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration))
    }
    private func choose(_ task: Record?, at start: Date? = nil) {
        request = PlannerScheduleRequest(task: task, start: start ?? task.flatMap { TaskPlanning.start($0) } ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day, workspace: .init(account: store.userID, generation: store.workspaceGeneration), session: store.backend.reminderSessionIncarnation, roots: store.activeTasks)
    }
    var body: some View {
        let reading = PlannerDayReading(work: work, events: events, on: day, hours: hours, calendar: calendar, includeTimeline: !usesAgenda)
        VStack(spacing: 0) {
            if !summaryScrolls {
                if let calendarHeader { calendarHeader }
                summary(reading)
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if summaryScrolls {
                            if let calendarHeader { calendarHeader }
                            summary(reading).id("summary")
                        }
                        allDayLane(reading).id("all-day")
                        if usesAgenda { readableAgenda(reading) } else { timeline(reading) }
                    }.padding(.horizontal, 12).padding(.bottom, 40)
                }
                .accessibilityIdentifier("plannerScroll")
                .task(id: TaskPlanner.dayKey(day)) {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    reader.scrollTo(summaryScrolls ? "summary" : "hour-\(reading.initialHourIndex)", anchor: .top)
                }
                .onChange(of: TaskPlanner.dayKey(day)) { _, _ in reader.scrollTo(summaryScrolls ? "summary" : "hour-\(reading.initialHourIndex)", anchor: .top) }
                .onChange(of:usesAgenda) { _,_ in
                    reader.scrollTo(summaryScrolls ? "summary":usesAgenda ? "all-day":"hour-\(reading.initialHourIndex)",anchor:.top)
                }
                .onChange(of: allDayRequest) { _, _ in
                    reader.scrollTo("all-day", anchor: .top)
                }
                .onChange(of: timelineRequest) { _, index in if !usesAgenda, let index { reader.scrollTo("hour-\(index)", anchor: .top) } }
                .onChange(of: agendaRequest) { _, id in if usesAgenda, let id { reader.scrollTo("agenda-" + id, anchor: .top) } }
            }
            if let feedback {
                HStack {
                    Text(feedback).font(.callout).lineLimit(3)
                    Spacer()
                    if let request = feedbackRequest, store.canApplyHistory(request) { Button("Undo") { if undo(request) { self.feedback = nil; feedbackRequest = nil } }.accessibilityIdentifier("plannerUndo") }
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
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in Task { await busy.refresh(on: day) } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in Task { await busy.refresh(on: day) } }
        .onChange(of: phase) { _, value in if value == .active { Task { await busy.refresh(on: day) } } }
        .sheet(isPresented: $settings) { PlannerSettingsView(busy: busy) }
        .sheet(item:$selectedEvent) {request in PlannerCalendarDetails(request:request,busy:busy)}
        .sheet(item: $request) { request in
            PlannerSchedulingSheet(request: request, events: events) { task, fields in
                let saved = apply(task, fields: fields, message: "Scheduled")
                if saved { self.request = nil }; return saved
            }
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 430)
            #endif
        }
        .confirmationDialog(fitTitle, isPresented: Binding(get: { fitProposal != nil }, set: { if !$0 { fitProposal = nil } }), titleVisibility: .visible, presenting: fitProposal) { fit in
            Button("Fit my day") { applyFit(fit) }.accessibilityIdentifier("capacityRingFitConfirm")
            Button("Cancel", role: .cancel) { fitProposal = nil }
        } message: { fit in Text(fitMessage(fit)) }
        .alert("Could not schedule", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func summary(_ reading: PlannerDayReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if textSize.isAccessibilitySize {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) { scheduleButton; Spacer(minLength: 8); settingsButton }
                estimateSummary(reading.capacity)
                VStack(alignment: .leading, spacing: 4) {
                    allDayButton(reading)
                    Button(usesAgenda ? "Show timeline" : "Show readable list") { changeLayout() }.font(.caption).frame(minHeight: 44).accessibilityIdentifier("plannerLargeTextLayout")
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline)
                    Spacer(minLength: 8)
                    scheduleButton; settingsButton
                }
                HStack { estimateSummary(reading.capacity); Spacer(minLength: 4); allDayButton(reading)
                    Button {changeLayout()} label: {Image(systemName:usesAgenda ? "calendar.day.timeline.left":"list.bullet").frame(width:44,height:44)}
                        .accessibilityLabel(usesAgenda ? "Show timeline":"Show readable list").accessibilityIdentifier("plannerLayoutToggle")
                }
            }
            capacityRing
            capacityDetails(reading.capacity)
            if work.incomplete {
                Label("Some grouped tasks need review. Capacity includes readable estimates only.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerGroupedWorkReview")
            }
            if busy.anyConnected { Text(busy.status).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerBusyStatus") }
            if !usesAgenda,reading.laneCount>1 {
                Label("Overlapping plans sit side by side. Scroll sideways if needed.",systemImage:"arrow.left.and.right")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("plannerOverlapHint")
            }
        }.modifier(PlannerSummarySurface())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var fitTitle: String { "Fit my day?" }
    private func fitMessage(_ fit: DayPlanFit) -> String {
        let moved = fit.placements.count == 1 ? "1 task" : "\(fit.placements.count) tasks"
        let left = fit.didntFit.filter { $0.reason != .noEstimate }.count
        return "This gives \(moved) (\(DayPlan.duration(fit.placedMinutes))) a time in your free hours." + (left > 0 ? " \(left) will not fit." : "") + " You can undo it afterwards."
    }
    private var dayKey: String { TaskPlanner.dayKey(day, calendar: calendar) }
    private var dayTasks: [Record] { DayPlan.todayTasks(tasks, day: dayKey, calendar: calendar) }
    @ViewBuilder private var capacityRing: some View {
        let ring = DayPlan.capacityRing(dayTasks, events: events, on: day, hours: hours, calendar: calendar)
        CapacityRingView(ring: ring, fit: fitDay == nil ? nil : { proposeFit() })
    }
    private func proposeFit() {
        let isToday = calendar.isDateInToday(day)
        let fit = DayPlan.fit(tasks: dayTasks, events: events, on: day, hours: hours, eveningIDs: Set(store.planningState.evening), notBefore: isToday ? Date() : nil, calendar: calendar)
        if fit.placements.isEmpty { feedback = "Nothing could be moved to fit your free time."; feedbackRequest = nil; return }
        fitProposal = fit
    }
    private func applyFit(_ fit: DayPlanFit) {
        guard let fitDay else { return }
        let previousHistory = store.undoStack.last?.id
        let saved = fitDay(fit, dayTasks)
        fitProposal = nil
        guard saved else { error = store.error ?? "Could not fit your day."; store.error = nil; return }
        feedback = fit.placements.count == 1 ? "Placed 1 task" : "Placed \(fit.placements.count) tasks"
        feedbackRequest = store.undoStack.last?.id != previousHistory ? store.captureHistoryRequest() : nil
    }
    /// The ring already says how much is planned and how much is free, so the visible line only names what it cannot count.
    private func estimateSummary(_ capacity: PlannerCapacity) -> some View {
        Text(capacity.unknownTasks == 0 ? "All estimated" : capacity.unknownTasks == 1 ? "1 task has no estimate" : "\(capacity.unknownTasks) tasks have no estimate")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerUnestimated")
    }
    /// The exact minute figures stay in the accessibility tree (VoiceOver and tests) without a second and third line of statistics on screen.
    private func capacityDetails(_ capacity: PlannerCapacity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(capacity.estimatedMinutes) min estimated · \(capacity.unknownTasks) without estimates").accessibilityIdentifier("plannerCapacity")
            Text(workingSummary(capacity)).accessibilityIdentifier("plannerWorkingCapacity")
        }
        .font(.caption2).frame(width: 1, height: 1, alignment: .topLeading).clipped().opacity(0)
    }
    private func workingSummary(_ capacity: PlannerCapacity) -> String {
        if capacity.incomplete { return "Review grouped tasks before relying on remaining capacity." }
        guard hours != nil else { return "Capacity unavailable. Update Taskfold to read these working hours." }
        if busy.ready {
            let remaining=capacity.afterKnownWork>=0 ? "\(capacity.afterKnownWork) min after known work":"\(capacity.afterKnownWork.magnitude) min over capacity"
            return "\(capacity.workingMinutes) min working day · \(capacity.busyMinutes) min calendar busy · \(remaining)"
        }
        if busy.anyConnected { return "\(capacity.workingMinutes) min working day · calendar data incomplete" }
        let remaining=capacity.workingMinutes-capacity.estimatedMinutes
        return "\(capacity.workingMinutes) min working day · "+(remaining>=0 ? "\(remaining) min after task estimates":"\(remaining.magnitude) min over capacity")
    }
    private var scheduleButton: some View {
        Button { choose(nil) } label: { Label("Schedule", systemImage: "clock.badge.plus").frame(minHeight: 44) }.accessibilityIdentifier("plannerSchedule")
    }
    private var settingsButton: some View {
        Button { settings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Planner settings").accessibilityIdentifier("plannerSettings")
    }
    private func allDayButton(_ reading: PlannerDayReading) -> some View {
        Button { allDayRequest += 1 } label: { Text("All day (\(reading.allDay.count+reading.allDayEvents.count))").font(.caption).frame(minHeight: 44) }.accessibilityIdentifier("plannerShowAllDay")
    }
    private func allDayLane(_ reading: PlannerDayReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ALL DAY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
            if reading.allDay.isEmpty && reading.allDayEvents.isEmpty { Text("Tasks with a date and no time appear here.").font(.caption).foregroundStyle(.secondary) }
            ForEach(reading.allDayEvents) {event in
                Button {showCalendar(event)} label: {
                    VStack(alignment:.leading,spacing:6) {Label(event.title,systemImage:"calendar").font(.callout);Text("Calendar · All day · "+event.source).font(.caption).foregroundStyle(.secondary)}
                        .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,minHeight:44,alignment:.leading).padding(10)
                        .background(Color.secondary.opacity(0.09),in:RoundedRectangle(cornerRadius:12))
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("plannerCalendarAllDay-"+event.id)
            }
            ForEach(reading.allDay) { task in
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
        Button { open(task) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).fixedSize(horizontal: false, vertical: true)
                if let parent = work.parents[task.id] { Text(parent).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.buttonStyle(.plain)
    }
    private func completeButton(_ task: Record) -> some View {
        Group {
            if TaskKind.mayComplete(task) {
                Button { complete(task) } label: { Image(systemName: "circle").font(.system(size: 24)).foregroundStyle(Color.taskfold).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Complete " + task.title).accessibilityIdentifier("plannerComplete-" + task.id)
            } else { Image(systemName: "text.alignleft").foregroundStyle(.secondary).frame(width: 44, height: 44).accessibilityLabel("Heading") }
        }
    }
    private func taskScheduleButton(_ task: Record) -> some View {
        Button { choose(task) } label: { Image(systemName: "clock").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Schedule " + task.title).accessibilityIdentifier("plannerAllDay-" + task.id).id("all-day-action-" + task.id)
    }
    private func estimate(_ task: Record) -> some View {
        Text(TaskKind(task) == .heading ? "Heading" : task.durationMinutes.map { "\($0)m" } ?? "No estimate").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    /// Fixed-height blocks cannot contain full accessibility-size text. Keep the same plans and
    /// mutations in a readable agenda, with the graphical timeline available as a view choice.
    private func readableAgenda(_ reading: PlannerDayReading) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timed tasks").font(.headline)
            if reading.blocks.isEmpty { Text("Use Schedule to give a task a time.").foregroundStyle(.secondary) }
            ForEach(reading.blocks) { block in
                VStack(alignment: .leading, spacing: 12) {
                    Button { open(block.task) } label: {
                        Text(block.task.title).font(.headline).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityIdentifier("plannerOpen-" + block.id)
                    if let parent = work.parents[block.id] { Text(parent).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    Text((block.start < block.clippedStart ? "Continues from an earlier day · " : "") + clock(block.start) + (block.end.map { " – " + $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "") + " · " + (block.task.durationMinutes.map { "\($0) min" } ?? "No estimate"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let deadline = block.task.deadline { Text("Deadline: " + deadline.formatted(date: .abbreviated, time: .omitted)).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    let conflicts = TaskPlanner.conflicts(task: block.task, start: block.start, minutes: block.task.durationMinutes, tasks: tasks, events: events)
                    if !conflicts.isEmpty { Text("Overlaps: " + conflicts.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: 12) {
                        completeButton(block.task)
                        Spacer(minLength: 8)
                        Button { choose(block.task) } label: { Image(systemName: "clock").frame(width: 44, height: 44) }.accessibilityLabel("Schedule " + block.task.title).accessibilityIdentifier("plannerAgendaSchedule-" + block.id)
                        Menu {
                            Button("15 minutes earlier") { shift(block, minutes: -15) }
                            Button("15 minutes later") { shift(block, minutes: 15) }
                            if block.end != nil {
                                Button("Add 15 minutes") { resize(block, minutes: 15) }
                                Button("Remove 15 minutes") { resize(block, minutes: -15) }
                            }
                            Button("Move to all day") { _ = apply(block.task, fields: ["due_time": .null, "time_zone": .null, "scheduled_at": .null, "due_date": .string(TaskPlanner.dayKey(day))], message: "Moved to all day") }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Adjust " + block.task.title).accessibilityIdentifier("plannerAgendaAdjust-" + block.id)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.taskfold.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("plannerBlock-" + block.id).id("agenda-" + block.id)
            }
            let visibleEvents = reading.timedEvents
            if !visibleEvents.isEmpty {
                Text("Calendar busy time").font(.headline)
                ForEach(visibleEvents) { event in
                    Button {showCalendar(event)} label: {
                        VStack(alignment:.leading,spacing:8) {
                            Label(event.title,systemImage:"calendar").font(.headline)
                            Text(clock(max(event.start,bounds.start))+" – "+clock(min(event.end,bounds.end))).font(.callout).foregroundStyle(.secondary)
                            Text(event.source).font(.caption).foregroundStyle(.secondary)
                        }.fixedSize(horizontal:false,vertical:true).padding(14).frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                            .background(Color.secondary.opacity(0.09),in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("plannerAgendaCalendar-"+event.id)
                }
            }
        }
    }
    private func timeline(_ reading: PlannerDayReading) -> some View {
        let ticks=reading.ticks,minutes=bounds.duration/60
        let items=reading.timeline
        let lanes=reading.laneCount,height=CGFloat(minutes)*scale+44
        return GeometryReader { geometry in
            let viewport=max(1,geometry.size.width-gutter),contentWidth=max(viewport,CGFloat(lanes)*140)
            VStack(alignment:.leading,spacing:0) {
                HStack(alignment:.top,spacing:0) {
                    ZStack(alignment:.topTrailing) {
                        Color.clear.frame(width:gutter,height:height)
                        VStack(spacing:0) {
                            ForEach(ticks.indices,id:\.self) {index in Color.clear.frame(width:gutter,height:60*scale).id("hour-\(index)")}
                        }.allowsHitTesting(false).accessibilityHidden(true)
                        ForEach(Array(ticks.enumerated()),id:\.offset) { index,date in
                            VStack(alignment:.trailing,spacing:2) {
                                Text(clock(date)).font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).accessibilityIdentifier("plannerClock-"+String(index))
                                if bounds.duration != 86400 {Text(calendar.timeZone.abbreviation(for:date) ?? calendar.timeZone.identifier).font(.system(size:9))}
                            }.foregroundStyle(.secondary).frame(width:gutter-10,alignment:.trailing)
                                .padding(.trailing,10).offset(y:CGFloat(date.timeIntervalSince(bounds.start)/60)*scale)
                        }
                    }.frame(width:gutter,height:height)
                    ScrollView(.horizontal,showsIndicators:true) {
                        ZStack(alignment:.topLeading) {
                            Color.clear.frame(width:contentWidth,height:height).allowsHitTesting(false)
                            ForEach(Array(ticks.enumerated()),id:\.offset) { index,date in
                                Button {choose(nil,at:date)} label: {
                                    Rectangle().fill(Color.primary.opacity(0.09)).frame(height:1).frame(width:contentWidth,height:44,alignment:.top)
                                }.buttonStyle(.plain).accessibilityLabel("Schedule a task at \(clock(date))").accessibilityIdentifier("plannerSlot-\(index)")
                                    .offset(y:CGFloat(date.timeIntervalSince(bounds.start)/60)*scale)
                            }
                            ForEach(items) {item in
                                timelineCard(item,viewport:viewport,minutes:minutes)
                                    .offset(x:CGFloat(item.lane)*(CGFloat(item.width(in:Double(viewport)))+4),y:CGFloat(item.minute)*scale)
                            }
                        }.frame(width:contentWidth,height:height).coordinateSpace(name:"planner-timeline")
                    }.frame(width:viewport,height:height).scrollDisabled(contentWidth<=viewport+1)
                        .accessibilityIdentifier("plannerTimelinePlans")
                }
            }
        }.frame(height:height).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    @ViewBuilder private func timelineCard(_ item:PlannerTimelineItem,viewport:CGFloat,minutes:Double)->some View {
        let width=CGFloat(item.width(in:Double(viewport)))
        switch item.content {
        case .task(let original):
            let block=original
            PlannerBlockCard(block:block,width:width,scale:scale,maxLength:minutes-block.minute,
                open:{open(block.task)},complete:{complete(block.task)},schedule:{choose(block.task)},
                move:{delta in shift(block,minutes:delta)},resize:{delta in resize(block,minutes:delta)},
                removeTime:{_ = apply(block.task,fields:["due_time":.null,"time_zone":.null,"scheduled_at":.null,"due_date":.string(TaskPlanner.dayKey(day))],message:"Moved to all day")})
        case .event(let event):
            Button {showCalendar(event)} label: {
                // Neutral glass, exactly start and duration (TimeGrid).
                let height=min(CGFloat(minutes-item.minute)*scale,CGFloat(item.renderLength)*scale)
                TimeGridBlock(title:event.title,time:clock(event.start)+"–"+clock(event.end),detail:item.length>=50 ? event.source:nil,kind:.event,height:height)
                    .frame(width:width,height:height,alignment:.topLeading)
            }.buttonStyle(.plain).foregroundStyle(.primary)
                .accessibilityLabel("Calendar: \(event.title), \(event.source), \(clock(event.start)) to \(clock(event.end))")
                .accessibilityHint("View this calendar event")
                .accessibilityIdentifier("plannerCalendar-"+event.id)
        }
    }
    @discardableResult private func apply(_ task: Record, fields: [String: JSON], message: String) -> Bool {
        let previousHistory = store.undoStack.last?.id
        guard save(task, fields) else { return false }
        var changed = task; for (key, value) in fields { changed[key] = value }
        if let start = TaskPlanning.start(changed), start >= bounds.start && start < bounds.end {
            timelineRequest = max(0, Int(start.timeIntervalSince(bounds.start) / 3600) - 1)
            agendaRequest = changed.id
        }
        let overlaps = TaskPlanning.start(changed).map { TaskPlanner.conflicts(task: changed, start: $0, minutes: changed.durationMinutes, tasks: tasks, events: events) } ?? []
        feedback = overlaps.isEmpty ? message : message + " · overlaps " + overlaps.prefix(3).joined(separator: ", ")
        // Read the actual committed entry, including at the 30-entry cap.
        feedbackRequest = store.undoStack.last?.id != previousHistory ? store.captureHistoryRequest() : nil
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

struct PlannerScheduleRequest: Identifiable {
    let id = UUID()
    let task: Record?
    let start: Date
    let workspace: WorkspaceBinding
    let session: UUID
    let selection: PlannerTaskSelection?
    init(task: Record?, start: Date, workspace: WorkspaceBinding, session: UUID, roots: [Record]) {
        self.task = task; self.start = start; self.workspace = workspace; self.session = session
        selection = task.flatMap { try? PlannerTaskSelection(task: $0, roots: roots, workspace: workspace, session: session) }
    }
}

struct PlannerSchedulingSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PlannerScheduleRequest
    let events: [PlannerEvent]
    let save: (Record, [String: JSON]) -> Bool
    @State private var chosen: PlannerTaskSelection?
    @State private var query = ""
    @State private var limit = PlannerTaskCatalog.pageSize
    @State private var catalog: PlannerTaskCatalog?
    @State private var loaded: Version?
    @State private var token: UUID?
    @State private var result: SearchResult?
    @State private var message: String?
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    private struct Version: Equatable {
        let readable: Bool
        let tasks: [Record]
        let projects: [Record]
        let sections: [Record]
        let parents: [String: String]
        let calendar: Calendar
    }
    private struct SearchKey: Equatable { let token: UUID?; let query: String; let limit: Int }
    private struct SearchResult { let key: SearchKey; let page: PlannerTaskCatalog.Page }
    init(request: PlannerScheduleRequest, events: [PlannerEvent], save: @escaping (Record, [String: JSON]) -> Bool) {
        self.request = request; self.events = events; self.save = save
        _chosen = State(initialValue: request.selection)
    }
    private var readable: Bool { store.workflowPreviewReady(request.workspace) && request.session == store.backend.reminderSessionIncarnation }
    private var workspace: WorkspaceBinding { .init(account: store.userID, generation: store.workspaceGeneration) }
    private var tasks: [Record] { store.productiveReading.presentation }
    private var version: Version {
        let reading = store.productiveReading
        return Version(readable: readable, tasks: readable ? reading.presentation : [], projects: readable ? store.allProjects : [], sections: readable ? store.rows("sections") : [], parents: readable ? reading.parents : [:], calendar: .current)
    }
    private func current(_ selection: PlannerTaskSelection, fields: [String: JSON]? = nil) -> Record? {
        guard readable else { return nil }
        return selection.current(tasks: tasks, roots: store.activeTasks, workspace: workspace, session: store.backend.reminderSessionIncarnation, fields: fields)
    }
    private func choose(_ option: PlannerTaskCatalog.Option) {
        guard readable, loaded == version,
              let task = PlannerTaskCatalog.current(option, tasks: tasks, projects: store.allProjects) else {
            message = "This task changed. Choose an available task."; return
        }
        do {
            let selection = try PlannerTaskSelection(task: task, roots: store.activeTasks, workspace: request.workspace, session: request.session)
            guard current(selection) != nil else { throw PlannerFailure(message: "This task changed. Choose an available task.") }
            searchFocused = false; chosen = selection
        } catch { message = error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            Group {
                if !readable {
                    ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Close this planner and reopen it in your current workspace."))
                } else if let chosen {
                    if current(chosen) != nil {
                        PlannerScheduleForm(task: chosen.task, start: request.start, tasks: tasks, events: events) { fields in
                            guard let current = current(chosen, fields: fields) else { return "This task or its schedule changed. Your choices are still here; reopen the current task before scheduling." }
                            if fields.allSatisfy({ current[$0.key] == $0.value }) { dismiss(); return nil }
                            if save(chosen.task, fields) { return nil }
                            let message = store.error ?? "The task could not be scheduled. Your choices are still here; try again."
                            store.error = nil
                            return message
                        }
                    } else { changedTask }
                } else if request.task != nil { changedTask }
                else { chooser }
            }
            .toolbar {
                if !readable || (chosen != nil && current(chosen!) == nil) || (request.task != nil && chosen == nil) {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
        }
    }
    private var changedTask: some View {
        ContentUnavailableView {
            Label("Task changed", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("This task was completed, moved or is no longer available. Close this planner and choose its current entry.")
        } actions: {
            if request.task == nil { Button("Back to tasks") { chosen = nil; message = nil } }
        }
    }
    private var chooser: some View {
        let currentVersion = version
        let key = SearchKey(token: token, query: query, limit: limit)
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find a task or project", text: $query).focused($searchFocused).onSubmit { searchFocused = false }
                    .textFieldStyle(.plain).frame(minHeight: 44).accessibilityLabel("Search tasks to schedule").accessibilityIdentifier("plannerTaskSearch")
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    #endif
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).accessibilityLabel("Clear search").accessibilityIdentifier("clearPlannerTaskSearch")
                }
            }.padding().background(.bar)
            if loaded == currentVersion, let result, result.key.token == token, result.key.query == query {
                List {
                    Section { Text("For " + request.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerTaskTargetTime") }
                    if result.page.total == 0 {
                        ContentUnavailableView(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No open tasks" : "No tasks found", systemImage: "magnifyingglass", description: Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Add a task to start planning your day." : "Try another task or project name."))
                    }
                    ForEach(result.page.options) { option in
                        Button { choose(option) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                Text(option.location).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text(option.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(option.title).accessibilityValue(option.location + ", " + option.summary)
                            .accessibilityIdentifier("plannerChoose-" + option.id)
                    }
                    if result.page.options.count < result.page.total {
                        Text("Showing \(result.page.options.count) of \(result.page.total) tasks").font(.caption).foregroundStyle(.secondary)
                        Button("Show more") { limit += PlannerTaskCatalog.pageSize }.disabled(searching).accessibilityIdentifier("showMorePlannerTasks")
                    }
                    if searching { ProgressView("Searching tasks…") }
                    if let message { Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerTaskSearchError") }
                }.accessibilityIdentifier("plannerTaskChoices")
            } else if let message { ContentUnavailableView("Tasks unavailable", systemImage: "exclamationmark.triangle", description: Text(message)) }
            else { ProgressView("Finding tasks…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle("Schedule a task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelPlannerTaskSearch") }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { searchFocused = false }.accessibilityIdentifier("dismissPlannerTaskKeyboard") }
        }
        .onChange(of: query) { _, _ in limit = PlannerTaskCatalog.pageSize; message = nil }
        .task(id: currentVersion) {
            catalog = nil; loaded = nil; token = nil; result = nil; message = nil
            guard readable else { return }
            do {
                let value = try await PlannerTaskCatalog.load(tasks: currentVersion.tasks, projects: currentVersion.projects, sections: currentVersion.sections, parents: currentVersion.parents, calendar: currentVersion.calendar)
                try Task.checkCancellation(); guard readable, version == currentVersion else { return }
                catalog = value; loaded = currentVersion; token = UUID()
            } catch is CancellationError { }
            catch { guard readable, version == currentVersion else { return }; message = error.localizedDescription }
        }
        .task(id: key) {
            guard readable, let catalog, loaded == currentVersion, key.token != nil else { return }
            searching = true
            do {
                let page = try await catalog.search(query: key.query, limit: key.limit)
                try Task.checkCancellation()
                guard readable, loaded == version, key == SearchKey(token: token, query: query, limit: limit) else { return }
                result = SearchResult(key: key, page: page); searching = false
            } catch is CancellationError { }
            catch { guard key == SearchKey(token: token, query: query, limit: limit) else { return }; searching = false; message = error.localizedDescription }
        }
    }
}

private struct PlannerBlockCard: View {
    @Environment(Store.self) private var store
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
        // The shared time-grid block: solid project colour, exactly start and duration; an open-ended task is dashed.
        let height = min(CGFloat(maxLength) * scale, CGFloat(block.renderLength) * scale + resizing)
        let project = store.record("projects", id: block.task.string("project_id"))
        let hue = DS.Palette.project(project)
        let time = block.start < block.clippedStart ? "Continues" : ClockFormat.string(block.start) + (block.end.map { "–" + ClockFormat.string($0) } ?? "")
        TimeGridBlock(title: block.task.title, time: time, detail: block.end == nil ? "no estimate" : project?.name,
                      kind: block.end == nil ? .suggestion(hue) : .task(hue), height: height)
        .frame(width: width, height: max(1, height), alignment: .topLeading)
        .contentShape(.rect).onTapGesture(perform: open)
        #if os(iOS)
        .gesture(LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(minimumDistance: 8, coordinateSpace: .named("planner-timeline"))).onChanged { value in if case .second(true, let drag?) = value { movement = drag.translation.height } }.onEnded { value in movement = 0; if case .second(true, let drag?) = value { move(Int((drag.translation.height / scale / 15).rounded()) * 15) } })
        #else
        .gesture(moveDrag)
        #endif
        .overlay(alignment: .bottom) {
            if block.end != nil {
                Capsule().fill(Color.white.opacity(0.7)).frame(width: min(30, width / 2), height: 3)
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
        .accessibilityAction(named: "Complete") { if TaskKind.mayComplete(block.task) { complete() } }
        .contextMenu {
            if TaskKind.mayComplete(block.task) { Button("Complete", systemImage: "checkmark.circle", action: complete) }
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
    let save: ([String: JSON]) -> String?
    @State private var start: Date
    @State private var fixed: Bool
    @State private var estimated: Bool
    @State private var estimate: String
    @State private var error: String?
    @FocusState private var estimateFocused: Bool
    private var validatedEstimate: Int? { Int(estimate.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var estimateFailure: String? {
        guard estimated else { return nil }
        guard let minutes = validatedEstimate, (1...10080).contains(minutes) else { return "Choose an estimate between 1 minute and 7 days." }
        return nil
    }
    init(task: Record, start: Date, tasks: [Record], events: [PlannerEvent], save: @escaping ([String: JSON]) -> String?) {
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
                if TaskKind(task) == .heading { Text("Headings keep their date as context. Their estimates do not count toward capacity.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Toggle("Set an estimate", isOn: $estimated).accessibilityIdentifier("plannerHasEstimate")
                if estimated { TextField("Minutes", text: $estimate).focused($estimateFocused).accessibilityLabel("Minutes").accessibilityIdentifier("plannerEstimate")
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                }
                if let estimateFailure { Text(estimateFailure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("plannerEstimateValidation") }
                Text(estimated ? "Choose 1–10,080 minutes. Resize the block to adjust later." : "The timeline shows an anchor. No time is reserved without an estimate.").font(.caption).foregroundStyle(.secondary)
            }
            if let deadline = task.deadline { Section("Deadline") { Text(deadline.formatted(date: .abbreviated, time: .omitted)); Text("Scheduling keeps this deadline.").font(.caption).foregroundStyle(.secondary) } }
            if !overlaps.isEmpty { Section("Overlaps") { ForEach(Array(overlaps.enumerated()), id: \.offset) { _, title in Text(title) }; Text("You can keep these overlaps or choose another time.").font(.caption).foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("plannerScheduleForm")
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Schedule task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if estimateFocused {
                HStack {
                    Spacer()
                    Button { estimateFocused = false } label: {
                        Text("Done").font(.body.weight(.medium)).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                    }.accessibilityIdentifier("dismissPlannerKeyboard")
                }.padding(.horizontal, 16).background(.bar)
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { submit() }.disabled(estimateFailure != nil).accessibilityIdentifier("plannerSave") }
        }
    }
    private func submit() {
        do {
            if let estimateFailure { throw PlannerFailure(message: estimateFailure) }
            let minutes = estimated ? validatedEstimate : nil
            // DatePicker can retain seconds. Normalize before comparing DST folds or storing a clock minute.
            let rounded = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 60) * 60)
            let zone = fixed ? (task.string("time_zone").isEmpty ? TimeZone.current.identifier : task.string("time_zone")) : ""
            var fields = try TaskPlanner.fields(task: task, start: rounded, minutes: minutes, timeZone: zone)
            if !estimated { fields["duration_minutes"] = .null }
            if let failure = save(fields) { error = failure }
        } catch { self.error = error.localizedDescription }
    }
}


/// Active native windows keep date-dependent lists and editor previews current.
struct CivilDayRefresh: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content
            .onChange(of: phase, initial: true) { _, value in
                if value == .active { store.refreshCalendarContext() }
            }
            .task(id: "\(phase == .active)-\(store.calendarContext.today)-\(store.calendarContext.timeZone)") {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    store.refreshCalendarContext()
                    do { try await Task.sleep(for: .seconds(store.calendarRefreshDelay)) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in store.refreshCalendarContext() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in store.refreshCalendarContext() }
    }
}

/// Keep app-owned calendar totals current without requesting access from a widget.
struct WidgetCapacityRefresh: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content
            .task(id: "\(store.userID)-\(CalendarBusyStore.shared.revision)-\(phase == .active)") {
                guard store.signedIn || store.localMode, phase == .active else { return }
                await store.refreshWidgetCapacity()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(900)) } catch { return }
                    await store.refreshWidgetCapacity()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in Task { await store.refreshWidgetCapacity() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in Task { await store.refreshWidgetCapacity() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in Task { await store.refreshWidgetCapacity() } }
    }
}

private struct PlannerCalendarRequest:Identifiable {
    let id=UUID()
    let eventID:String
    let workspace:WorkspaceBinding
}
/// Read-only details resolve current data and never retain another workspace's event content.
private struct PlannerCalendarDetails:View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let request:PlannerCalendarRequest
    let busy:CalendarBusyStore
    private var event:PlannerEvent? {
        guard request.workspace.matches(account:store.userID,generation:store.workspaceGeneration),busy.account==store.userID else {return nil}
        return busy.events.first{$0.id==request.eventID}
    }
    var body:some View {
        NavigationStack {
            Form {
                if let event {
                    Section {
                        Text(event.title).font(.headline).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("plannerCalendarTitle")
                        Text(event.source).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        Text("Read-only calendar event").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("When") {
                        LabeledContent("Starts",value:event.start.formatted(date:.abbreviated,time:.shortened))
                        LabeledContent("Ends",value:event.end.formatted(date:.abbreviated,time:.shortened))
                        if event.allDay {Text("All day")}
                    }
                } else {
                    Text("This calendar event is unavailable. Refresh your calendars or choose another event.")
                        .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("plannerCalendarUnavailable")
                }
            }.formStyle(.grouped).navigationTitle("Calendar event")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Done") {dismiss()}.accessibilityIdentifier("plannerCalendarDone")}}
        }
        .onChange(of:store.workspaceGeneration) {_,_ in dismiss()}
        #if os(macOS)
        .frame(minWidth:400,minHeight:330)
        #endif
    }
}

/// The stats block above the grid. On iPhone it has no panel fill (so the first hour label never sits on a band edge), sits on the
/// 16pt page margin and leaves 16pt before the grid. The Mac keeps its material panel.
private struct PlannerSummarySurface: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.padding(14).background(.regularMaterial)
        #else
        content.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        #endif
    }
}
