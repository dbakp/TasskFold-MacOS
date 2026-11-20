import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The day ring as Today's hero on the Mac (day-ring design round: frames A, C, D, E and F; B was not chosen).
// Every figure comes from Core (`DayPlan.heroFigure`, `dropPreview`, `planCandidates`, `overflowFix`); this file draws them.

/// Today's header (frame A): the 72 pt ring leads the title line, then "Today" over the date, and on the right the
/// figure, one quieter line and Plan. Dragging a task over the header grows the ring 8% and previews where it lands
/// (frame C); dropping plans it for today (frame D). Overbooked, the figure leads in crimson and Plan becomes
/// "Fix it…" (frame E). With nothing estimated the right side teaches instead (frame F).
struct TodayHero: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @AppStorage(DayRingSetting.key) private var showRing = true
    var title: String
    var subtitle: String
    var ring: TodayRing
    var hue: (String) -> ProjectHue
    var pending: Set<String> = []
    var flight: FoldFlight
    let shutdown: () -> Void
    let setHours: () -> Void

    private var dropPreview: RingDropPreview? {
        guard let drop = workspace.ringDrop else { return nil }
        let tasks = workspace.ringPlannable(drop.ids)
        guard let first = tasks.first else { return nil }
        let minutes = tasks.compactMap(\.durationMinutes).reduce(0, +)
        return DayPlan.dropPreview(ring, id: first.id, projectID: first.string("project_id"), minutes: minutes > 0 ? minutes : nil)
    }

    var body: some View {
        let preview = dropPreview
        let fix = DayPlan.overflowFix(store.tasks, ring: ring, on: Date())
        let hero = preview?.hero ?? DayPlan.heroFigure(ring, suggestion: DayPlan.overflowSuggestion(fix))
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                if showRing { ringView(preview) }
                titleBlock
                Spacer(minLength: DS.Space.l)
                trailing(hero: hero, fix: fix, previewing: preview != nil, alignment: .trailing)
            }
            // Large text: the figure and Plan wrap under the title instead of truncating.
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.xl) {
                    if showRing { ringView(preview) }
                    titleBlock
                }
                trailing(hero: hero, fix: fix, previewing: preview != nil, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onDrop(of: [.taskfoldTask], delegate: RingDropDelegate(workspace: workspace))
        .overlay(alignment: .topLeading) { if let preview { tooltip(preview) } }
        .onChange(of: workspace.drag.active) { _, active in if !active { workspace.ringDrop = nil } }
        #if DEBUG
        .overlay(alignment: .topLeading) { if DayRingFixture.frame == "c", let preview { DayRingFixture.LiftedRow(id: preview.ghostID ?? "", hue: hue) } }
        .task {
            // Captures: --day-ring-hover=<title> hovers that row, as the pointer would.
            guard let title = DayRingFixture.hoverTitle else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            flight.hoveredID = store.tasks.first { $0.title == title }?.id
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ringDropTarget")
    }

    // MARK: Pieces

    private func ringView(_ preview: RingDropPreview?) -> some View {
        let shown = preview?.ring ?? ring
        return TodayRingView(ring: shown, hue: hue, pending: pending, flight: preview == nil ? flight : nil, showsOverflow: true,
                             focusID: preview == nil ? flight.hoveredID : nil, ghostID: preview?.ghostID, freshID: workspace.justPlanned)
            .scaleEffect(preview != nil ? DS.Size.ringDropScale : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.25), value: preview != nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Day ring")
            .accessibilityValue(ring.segments.isEmpty ? "No estimates yet" : ring.accessibilityLabel)
            .accessibilityChildren {
                ForEach(ring.segments) { segment in
                    Text(segmentLabel(segment)).accessibilityIdentifier("ringSegment-" + segment.id)
                }
            }
            .accessibilityIdentifier("todayRingGraphic")
    }
    private func segmentLabel(_ segment: RingSegment) -> String {
        let title = store.record("tasks", id: segment.id)?.title ?? "Task"
        return "\(title.isEmpty ? "Untitled task" : title), \(DayPlan.spoken(segment.minutes)), \(segment.done ? "done" : "open")"
    }
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DS.Font.heroTitle).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("listTitle")
            Text(subtitle).font(DS.Font.dateLine).foregroundStyle(DS.Palette.textSecondary).monospacedDigit().lineLimit(1)
                .accessibilityIdentifier("listSubtitle")
        }
        .fixedSize()
    }
    @ViewBuilder private func trailing(hero: DayHeroFigure, fix: [Record], previewing: Bool, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            if hero.isEmpty && !previewing {
                teachLine(alignment: alignment)
            } else {
                (Text(hero.figure.lead).font(DS.Font.heroFigure).foregroundStyle(hero.figure.leadIsAlert ? DS.Palette.dateOverdue : DS.Palette.textPrimary)
                 + Text(hero.figure.rest).font(DS.Font.heroFigureRest).foregroundStyle(DS.Palette.textSecondary))
                    .lineLimit(1).fixedSize()
                    .contentTransition(.numericText())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ring.accessibilityLabel(for: "Today", reportsOver: true) + (hero.meta.isEmpty || !ring.isOver ? "" : ". " + hero.meta))
                    .accessibilityIdentifier("todayRing")
                if !hero.meta.isEmpty {
                    Text(hero.meta).font(DS.Font.heroMeta).foregroundStyle(DS.Palette.textSecondary).lineLimit(1).fixedSize()
                        .accessibilityIdentifier(ring.isOver && !fix.isEmpty && !previewing ? "overflowSuggestion" : "todayRingDetail")
                }
            }
            button(fix: fix).padding(.top, 3)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hero)
    }
    /// Frame F: "Add estimates like [30m] or drag a task onto the ring to see your day fill up."
    @ViewBuilder private func teachLine(alignment: HorizontalAlignment) -> some View {
        let chip = Text("30m").font(DS.Font.heroMeta).foregroundStyle(DS.Palette.textPrimary)
            .padding(.horizontal, 8).frame(height: 22).background(DS.Palette.chipFill, in: Capsule())
        ViewThatFits(in: .horizontal) {
            VStack(alignment: alignment, spacing: 4) {
                HStack(spacing: 5) { Text("Add estimates like"); chip; Text("or drag a task") }
                Text("onto the ring to see your day fill up.")
            }
            .fixedSize()
            Text("Add estimates like 30m or drag a task onto the ring to see your day fill up.")
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading).fixedSize(horizontal: false, vertical: true)
        }
        .font(DS.Font.heroMeta).foregroundStyle(DS.Palette.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No estimates yet. Add estimates like 30m, or drag a task onto the ring to see your day fill up.")
        .accessibilityIdentifier("todayRing")
    }
    @ViewBuilder private func button(fix: [Record]) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let prompt = store.dayPlanPrompt(now: context.date)
            if workspace.planTrayShown {
                textButton("Done planning", identifier: "planDay", hint: "Closes Plan your day") { workspace.planTrayShown = false }
            } else if ring.isOver && !fix.isEmpty {
                textButton("Fix it\u{2026}", identifier: "fixOverbooked", hint: DayPlan.overflowSuggestion(fix) ?? "") { workspace.fixOverbooked(fix) }
            } else if !ring.hasWorkingHours {
                textButton("Set hours", identifier: "setWorkingHours", hint: "Sets your working hours so the ring can show free time", action: setHours)
            } else if prompt == .shutdown && !DayRingFixture.holdsPlan {
                textButton("Shut down", identifier: "dayShutdown", hint: "Review today and close it", action: shutdown)
            } else {
                textButton("Plan", shortcut: "\u{2318}P", identifier: "planDay", hint: "Opens Plan your day. Drag tasks onto the ring to plan them for today") { workspace.planTrayShown = true }
            }
        }
    }
    private func textButton(_ title: String, shortcut: String? = nil, identifier: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title + (shortcut.map { " " + $0 } ?? "")).font(DS.Font.sectionHeader).foregroundStyle(Color.brandCrimson)
                .frame(minHeight: 22).contentShape(.rect)
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityLabel(title)
        .accessibilityHint(hint).accessibilityIdentifier(identifier)
    }
    /// "Drop to plan · **+45m** → 5h 15m of 7h 30m", near the pointer.
    private func tooltip(_ preview: RingDropPreview) -> some View {
        let parts = preview.tooltip.components(separatedBy: " \u{2192} ")
        let head = parts.first ?? preview.tooltip
        let lead = head.components(separatedBy: " · ")
        let text: Text = lead.count == 2 && parts.count == 2
            ? Text(lead[0] + " · ") + Text(lead[1]).fontWeight(.bold) + Text(" \u{2192} " + parts[1])
            : Text(preview.tooltip)
        let point = workspace.ringDrop?.location ?? CGPoint(x: 24, y: 60)
        return text.font(DS.Font.heroMeta.weight(.medium)).foregroundStyle(DS.Palette.onTooltip)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DS.Palette.tooltip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .fixedSize()
            .offset(x: point.x + 16, y: point.y + 26)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("ringDropTooltip")
    }
}

/// The ring's drop target: a task held over Today's header previews; dropping plans it for today. Leaving, or Escape
/// (which ends the drag session), clears the preview.
struct RingDropDelegate: DropDelegate {
    let workspace: Workspace
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.taskfoldTask]) && (!workspace.drag.active || !workspace.ringPlannable(workspace.drag.ids).isEmpty)
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { workspace.ringDrop = nil }
    func performDrop(info: DropInfo) -> Bool {
        let ids = workspace.drag.ids
        workspace.ringDrop = nil
        if !ids.isEmpty { workspace.drag.end(); return workspace.planIntoToday(ids) }
        // A drag that did not start through the coordinator still carries the ids.
        for provider in info.itemProviders(for: [.taskfoldTask]) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.taskfoldTask.identifier) { data, _ in
                guard let data, let ids = try? TaskfoldJSONDecoder().decode([String].self, from: data) else { return }
                Task { @MainActor in workspace.planIntoToday(ids) }
            }
        }
        return true
    }
    private func update(_ info: DropInfo) {
        guard workspace.drag.active, !workspace.ringPlannable(workspace.drag.ids).isEmpty else { return }
        let next = Workspace.RingDrop(ids: workspace.drag.ids, location: info.location)
        if workspace.ringDrop?.ids != next.ids { Feedback.tick() }
        workspace.ringDrop = next
    }
}

/// Plan your day (frame C): candidates under Inbox, Tomorrow and Waiting a while, each draggable onto the ring.
/// A row is also a button, so planning works from the keyboard: Space or Return plans it for today.
struct PlanTray: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    var hue: (String) -> ProjectHue
    var body: some View {
        // The task being held over the ring leaves the tray while it is held.
        let held = Set(workspace.ringDrop?.ids ?? [])
        let candidates = DayPlan.planCandidates(store.tasks.filter { !held.contains($0.id) }, today: Date(), someday: Set(store.somedayTasks.map(\.id)))
        VStack(alignment: .leading, spacing: 0) {
            Text("Plan your day").font(DS.Font.screenTitle).foregroundStyle(DS.Palette.textPrimary).accessibilityAddTraits(.isHeader)
            Text("Drag a task onto the ring. It joins Today and fills the ring by its estimate.")
                .font(DS.Font.heroMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs).padding(.bottom, DS.Space.xs)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("Inbox", candidates.inbox)
                    section("Tomorrow", candidates.tomorrow)
                    section("Waiting a while", candidates.waiting)
                    if candidates.isEmpty {
                        Text("Nothing is waiting to be planned. You can also drag a task from any list onto the ring.")
                            .font(DS.Font.heroMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, DS.Space.m).accessibilityIdentifier("planTrayEmpty")
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 18).padding(.horizontal, 14)
        .frame(width: DS.Size.planTrayWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Palette.tray).background(DS.Palette.surface)
        .overlay(alignment: .leading) { Rectangle().fill(DS.Palette.separator).frame(width: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan your day")
        .accessibilityIdentifier("planTray")
    }
    @ViewBuilder private func section(_ title: String, _ tasks: [Record]) -> some View {
        if !tasks.isEmpty {
            Text(title).font(DS.Font.taskNote.weight(.semibold)).foregroundStyle(DS.Palette.textTertiary)
                .padding(.top, 14).padding(.bottom, DS.Space.xs).accessibilityAddTraits(.isHeader)
            ForEach(tasks) { task in PlanTrayRow(task: task, hue: hue(task.string("project_id"))).padding(.bottom, 6) }
        }
    }
}

private struct PlanTrayRow: View {
    @Environment(Workspace.self) private var workspace
    var task: Record
    var hue: ProjectHue
    var body: some View {
        Button { workspace.planIntoToday([task.id]) } label: {
            HStack(spacing: 10) {
                Circle().strokeBorder(DS.Palette.textTertiary, lineWidth: 1.3).frame(width: 16, height: 16)
                Circle().fill(task.string("project_id").isEmpty ? Color.clear : hue.color).frame(width: 7, height: 7)
                Text(task.title.isEmpty ? "Untitled task" : task.title).font(DS.Font.taskTitle).foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                if let minutes = task.durationMinutes {
                    HStack(spacing: 6) {
                        Text(DayPlan.duration(minutes)).font(DS.Font.rowEstimate).foregroundStyle(DS.Palette.textSecondary)
                        EstimatePip(hue: hue, done: false)
                    }
                }
            }
            .padding(.horizontal, DS.Space.s).frame(minHeight: 36)
            .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Palette.textPrimary.opacity(0.13), lineWidth: 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onDrag {
            workspace.drag.begin([task.id], order: [], priorities: [task.id: task.priority])
            return taskItemProvider(for: [task])
        } preview: { DragPreview(tasks: [task]) }
        .help("Drag onto the ring, or click, to plan for today")
        .accessibilityLabel(task.title + (task.durationMinutes.map { ", " + DayPlan.spoken($0) } ?? ""))
        .accessibilityHint("Plans this task for today")
        .accessibilityIdentifier("planCandidate-" + task.id)
    }
}

/// The 3 pt colour pip after a Today row's estimate: its segment's colour, full strength when done, dimmer while open.
struct EstimatePip: View {
    var hue: ProjectHue
    var done: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(hue.color)
            .opacity(done ? 1 : DS.Size.estimatePipOpenOpacity)
            .frame(width: DS.Size.estimatePip.width, height: DS.Size.estimatePip.height)
            .accessibilityHidden(true)
    }
}

// MARK: - Captures (Debug only)

/// `--preview --day-ring-fixture=a|c|d|e|f` replaces the preview data with the approved mockup's day (working hours
/// 9:00–16:30, five projects). `c` opens the tray and holds "Draft the newsletter intro" over the ring; `d` plans it;
/// `e` adds three tasks so the day is 1h 15m over; `f` has no estimates. `--day-ring-hover=<title>` hovers a row.
enum DayRingFixture {
    #if DEBUG
    static var frame: String? { ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--day-ring-fixture=") }.map { String($0.dropFirst(19)) } }
    #else
    static var frame: String? { nil }
    #endif
    #if DEBUG
    static var hoverTitle: String? { ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--day-ring-hover=") }.map { String($0.dropFirst(17)) } }
    /// Frame C's capture: the system drag image cannot be captured, so the held row is drawn where the mockup has it.
    struct LiftedRow: View {
        @Environment(Store.self) private var store
        var id: String
        var hue: (String) -> ProjectHue
        var body: some View {
            if let task = store.record("tasks", id: id) {
                HStack(spacing: 10) {
                    Circle().strokeBorder(DS.Palette.textTertiary, lineWidth: 1.3).frame(width: 16, height: 16)
                    Circle().fill(hue(task.string("project_id")).color).frame(width: 7, height: 7)
                    Text(task.title).font(DS.Font.taskTitle).foregroundStyle(DS.Palette.textPrimary)
                    Spacer(minLength: 8)
                    if let minutes = task.durationMinutes {
                        Text(DayPlan.duration(minutes)).font(DS.Font.rowEstimate).foregroundStyle(DS.Palette.textSecondary)
                        EstimatePip(hue: hue(task.string("project_id")), done: false)
                    }
                }
                .padding(.horizontal, 10).frame(width: 330, height: 36)
                .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 17, y: 14).shadow(color: .black.opacity(0.1), radius: 4, y: 3)
                .rotationEffect(.degrees(-1.5))
                .offset(x: 200, y: 112)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
    #endif
    /// Captures run at any hour, so the fixture never swaps Plan for Shut down.
    static var holdsPlan: Bool { frame != nil }

    #if DEBUG
    @MainActor static func apply(store: Store, workspace: Workspace) {
        guard let frame else { return }
        let user = store.userID, calendar = Calendar.current
        let projects: [(String, String, String)] = [("dr-work", "Work", "#2F5BD3"), ("dr-writing", "Writing", "#C77B12"), ("dr-health", "Health", "#3E8E4A"),
                                                    ("dr-home", "Home", "#1B8F8A"), ("dr-admin", "Admin", "#8E44AD")]
        store.snapshot.tables["projects"] = projects.enumerated().map { index, entry in
            Record(["id": .string(entry.0), "name": .string(entry.1), "user_id": .string(user), "color": .string(entry.2), "order_index": .number(Double(index))])
        }
        let estimates = frame != "f"
        func make(_ id: String, _ title: String, _ project: String, _ minutes: Int, day: Int?, time: String? = nil, done: Bool = false, priority: Int = 4, age: Int = 1) -> Record {
            let created = ISO8601DateFormatter().string(from: calendar.date(byAdding: .day, value: -age, to: Date()) ?? Date())
            var task = Record.task(user: user, project: project, date: day.flatMap { calendar.date(byAdding: .day, value: $0, to: Date()) }, createdAt: created)
            task["id"] = .string(id); task["title"] = .string(title); task["priority"] = .number(Double(priority))
            if let time { task["due_time"] = .string(time) }
            if estimates { task["duration_minutes"] = .number(Double(minutes)) }
            if done && frame != "f" { task["completed"] = .bool(true); task["completed_at"] = .string(Dates.timestamp()) }
            return task
        }
        var tasks = [
            make("dr-proposal", "Send the revised proposal", "dr-work", 30, day: -1, priority: 1),
            make("dr-idea", "Make time for the big idea", "dr-writing", 60, day: 0, time: "10:00", done: true),
            make("dr-q4", "Review the Q4 numbers", "dr-work", 90, day: 0, time: "13:00"),
            make("dr-sketch", "Sketch the next chapter", "dr-writing", 45, day: 0),
            make("dr-walk", "A walk, without the phone", "dr-health", 30, day: 0, done: true),
            // 45m rather than the mockup's 15m: Today's ring counts today's tasks, not overdue ones, so this keeps 4h 30m.
            make("dr-plan", "Plan something worth looking forward to", "dr-home", 45, day: 0),
            make("dr-dentist", "Book the dentist", "dr-admin", 15, day: nil, age: 2),
            make("dr-newsletter", "Draft the newsletter intro", "dr-writing", 45, day: nil, age: 1),
            make("dr-landlord", "Call the landlord about the boiler", "dr-home", 20, day: 1),
            make("dr-expense", "Expense report", "dr-admin", 30, day: nil, age: 30),
        ]
        if frame == "e" {
            tasks.removeAll { $0.id == "dr-newsletter" }
            tasks += [make("dr-deck", "Rewrite the pitch deck", "dr-work", 120, day: 0), make("dr-newsletter", "Draft the newsletter intro", "dr-writing", 45, day: 0),
                      make("dr-board", "Prepare the board update", "dr-work", 90, day: 0, time: "15:00")]
        }
        store.snapshot.tables["tasks"] = tasks
        store.snapshot.tables["view_preferences"] = [Record(["id": .string("planner"), "user_id": .string(user),
                                                             "working_hours": WorkingHours(start: 540, end: 990, weekdays: Set(1...7)).document])]
        store.setViewValue(.today, field: "include_completed", value: .bool(frame != "f"))
        store.setViewValue(.today, field: "sort_by", value: .string("manual"))
        workspace.section = .today
        workspace.inspectorShown = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            switch frame {
            case "c":
                workspace.planTrayShown = true
                workspace.ringDrop = Workspace.RingDrop(ids: ["dr-newsletter"], location: CGPoint(x: 260, y: 150))
            case "d":
                workspace.planTrayShown = true
                workspace.planIntoToday(["dr-newsletter"])
            default: break
            }
        }
    }
    #endif
}
