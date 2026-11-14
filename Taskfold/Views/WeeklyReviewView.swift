import SwiftUI
import UserNotifications

/// The guided Weekly review, one file for both apps. It adds no logic of its own: each step reuses an existing flow
/// (Inbox review, Smart reschedule, the Estimates insight, Quick Add, the Someday review, the capacity numbers) and the
/// pure decisions live in Core/WeeklyReview.swift. Every step can be skipped, and nothing is saved until the person acts.
struct WeeklyReviewRequest: Identifiable {
    let id = UUID()
    let workspace: WorkspaceBinding
}

private struct WeeklyReviewActionKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var openWeeklyReview: () -> Void {
        get { self[WeeklyReviewActionKey.self] }
        set { self[WeeklyReviewActionKey.self] = newValue }
    }
}

/// The optional weekly reminder: one repeating local notification, owned by this file and removed when turned off.
@MainActor
enum WeeklyReviewReminder {
    /// Schedules (or removes) the reminder. False when the person asked for it but notifications are not allowed.
    static func apply(enabled: Bool, weekday: Int, minutes: Int) async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [WeeklyReview.reminderIdentifier])
        guard enabled else { return true }
        guard (1...7).contains(weekday), (0..<1440).contains(minutes) else { return false }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Weekly review"
        content.body = "A few quiet minutes to clear your Inbox and look at next week."
        var components = DateComponents(); components.weekday = weekday; components.hour = minutes / 60; components.minute = minutes % 60
        let request = UNNotificationRequest(identifier: WeeklyReview.reminderIdentifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
        return (try? await center.add(request)) != nil
    }
}

struct WeeklyReviewView: View {
    let request: WeeklyReviewRequest
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @AppStorage("somedayLastReview") private var lastSomedayReview = 0.0
    @AppStorage("weeklyReviewReminder") private var reminderOn = false
    @AppStorage("weeklyReviewReminderWeekday") private var reminderWeekday = WeeklyReview.defaultReminderWeekday
    @AppStorage("weeklyReviewReminderMinutes") private var reminderMinutes = WeeklyReview.defaultReminderMinutes

    private enum Phase: Equatable { case intro, step(Int), done }
    private struct LastAction {
        var message: String
        var ids: [UUID]?
        var revert: (inout WeeklyReviewProgress) -> Void
    }

    @State private var phase = Phase.intro
    @State private var steps: [WeeklyReviewStep] = []
    @State private var progress = WeeklyReviewProgress()
    @State private var inboxAtStart = 0
    @State private var events: [PlannerEvent] = []
    @State private var eventsLoaded = false
    @State private var inboxReview: InboxReviewRequest?
    @State private var reschedule: SmartRescheduleRequest?
    @State private var deleting: Record?
    @State private var keptIdeas = Set<String>()
    @State private var skippedProjects = Set<String>()
    @State private var last: LastAction?
    @State private var failure: String?
    @State private var reminderNote: String?
    @State private var stamped = false
    #if os(macOS)
    @State private var addingTo: Record?
    @State private var draft = ""
    @State private var declined = Set<String>()
    @State private var choices: [String: String] = [:]
    @State private var manual: [String: JSON] = [:]
    #else
    @State private var addingTask: Record?
    #endif

    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    private var available: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) }
    private let target: CGFloat = 44

    // MARK: Live readings

    private var inboxCount: Int { store.inboxProductiveReading.work.filter(InboxReviewRequest.eligible).count }
    private var slipped: [Record] { store.weeklySlipped() }
    private var projectsWithout: [Record] { store.weeklyProjectsWithoutNextAction().filter { !skippedProjects.contains($0.id) } }
    private var staleIdeas: [Record] { store.weeklyStaleSomeday().filter { !keptIdeas.contains($0.id) } }
    private var accuracy: EstimateAccuracy? { store.estimateAccuracy.flatMap { $0.isReliable ? $0 : nil } }
    private var undoIDs: [UUID]? { store.undoStack.last?.redo.map(\.id) }
    private var canUndo: Bool { available && last.map { $0.ids == nil || $0.ids == undoIDs } == true }

    // MARK: Body

    var body: some View {
        shell
            .sheet(item: $inboxReview) { InboxReviewView(request: $0) }
            .sheet(item: $reschedule) { request in
                SmartRescheduleView(request: request, onApplied: { count in
                    progress.rescheduled += count
                    last = LastAction(message: count == 1 ? "Rescheduled 1 task" : "Rescheduled \(count) tasks", ids: undoIDs) { $0.rescheduled = max(0, $0.rescheduled - count) }
                })
            }
            #if os(macOS)
            .sheet(item: $addingTo) { project in
                TaskCapturePanel(text: $draft, declined: $declined, choices: $choices, prompt: "What is the next action for \(project.name)?",
                                 context: workspace.quickEntryContext(project: project.id), task: workspace.captureTask(project: project.id, date: nil),
                                 submit: { submitNextAction(project) }, manualChoices: $manual)
            }
            #else
            .sheet(item: $addingTask) { template in
                QuickAddView(task: template, onExpand: { _, _ in }, allowsExpand: false, onAdded: { added in nextActionAdded(projectID: added.string("project_id")) })
            }
            #endif
            .confirmationDialog(deleting.map { "Delete “\($0.title)”?" } ?? "Delete task?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { task in
                Button("Delete", role: .destructive) { delete(task) }.accessibilityIdentifier("weeklyReviewConfirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { task in
                Text(Planning.isRepeating(task) ? "This also stops it repeating. You can undo right after." : "You can undo right after.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
            .onChange(of: reminderOn) { _, _ in updateReminder() }
            .onChange(of: reminderWeekday) { _, _ in if reminderOn { updateReminder() } }
            .onChange(of: reminderMinutes) { _, _ in if reminderOn { updateReminder() } }
    }

    @ViewBuilder private var shell: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack { Text("Weekly review").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader); Spacer()
                Button(phase == .done ? "Done" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("weeklyReviewClose") }
                .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.xl).padding(.bottom, DS.Space.s)
            pageScroll
            footer
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 520, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        NavigationStack {
            pageScroll
                .navigationTitle("Weekly review").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(phase == .done ? "Done" : "Close") { dismiss() }.accessibilityIdentifier("weeklyReviewClose") } }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
        #endif
    }

    private var pageScroll: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if !available {
                        ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("Close this review and open it again."))
                    } else {
                        switch phase {
                        case .intro: intro
                        case .step(let index): stepPage(index)
                        case .done: doneScreen
                        }
                    }
                    if let last, canUndo, phase != .done {
                        HStack(spacing: DS.Space.m) {
                            Text(last.message).font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                            Button("Undo", action: undoLast).buttonStyle(.bordered).frame(minHeight: target).accessibilityIdentifier("weeklyReviewUndo")
                        }
                    }
                }
                .padding(DS.Space.xl).frame(maxWidth: .infinity, alignment: .leading).id("weekly-top")
            }
            .onChange(of: phase) { _, _ in reader.scrollTo("weekly-top", anchor: .top) }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("weeklyReview")
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("A quiet look at your week").font(.system(.title2, design: .rounded).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("About five minutes. Skip anything that doesn’t need you.").foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            // This week in rings (round 6): what was planned and what got done, before the six steps.
            WeekRingsCard(summary: weekSummary, hue: { DS.Palette.project($0.isEmpty ? nil : store.record("projects", id: $0)) })
                .task { await loadEvents() }
            Text(WeeklyReview.statusText(lastReviewed: store.weeklyLastReviewed, now: Date(), calendar: store.habitCalendar))
                .font(.footnote).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("weeklyReviewLastReviewed")
                .padding(.top, -DS.Space.s)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(WeeklyReviewStep.allCases, id: \.self) { step in
                    let detail = introDetail(step)
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: step.symbol).symbolVariant(.none).fontWeight(.regular).font(.system(size: 20)).frame(width: 28).foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true) // one ink for all six (round 3); crimson is for act / today
                        Text(step.title).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.s)
                        Text(detail.text).font(.callout).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.trailing)
                    }
                    .frame(minHeight: target)
                    .accessibilityElement(children: .combine)
                }
            }
            Button(action: begin) {
                Label("Start review", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: target)
            }.buttonStyle(.borderedProminent).tint(DS.Palette.accentFill).disabled(!available).accessibilityIdentifier("weeklyReviewStart")
            reminderSection
        }
    }
    private var weekSummary: WeekSummary {
        WeeklyReview.weekSummary(tasks: store.tasks, events: events, hours: store.workingHours, now: Date(), calendar: store.habitCalendar, locale: .autoupdatingCurrent)
    }
    private func introDetail(_ step: WeeklyReviewStep) -> (needed: Bool, text: String) {
        func count(_ n: Int, _ unit: String) -> (Bool, String) { n == 0 ? (false, "Empty") : (true, "\(n) \(unit)") }
        switch step {
        case .inbox: return count(inboxCount, inboxCount == 1 ? "task" : "tasks")
        case .slipped: return count(slipped.count, slipped.count == 1 ? "task" : "tasks")
        case .estimates: return accuracy == nil ? (false, "After a week of estimates") : (true, "Ready")
        case .projects: return count(projectsWithout.count, projectsWithout.count == 1 ? "project" : "projects")
        case .someday: return count(staleIdeas.count, staleIdeas.count == 1 ? "idea" : "ideas")
        case .nextWeek:
            let planned = store.weeklyLoad(events: events).taskCount
            return (planned > 0, planned == 0 ? "Empty" : planned == 1 ? "1 task" : "\(planned) tasks")
        }
    }
    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Toggle("Remind me weekly", isOn: $reminderOn).tint(DS.Palette.accent).frame(minHeight: target).accessibilityIdentifier("weeklyReviewReminderToggle")
            if reminderOn {
                Picker("Day", selection: $reminderWeekday) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }.frame(minHeight: target).accessibilityIdentifier("weeklyReviewReminderDay")
                DatePicker("Time", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: Date()) ?? Date() },
                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); reminderMinutes = (c.hour ?? 16) * 60 + (c.minute ?? 0) }),
                    displayedComponents: .hourAndMinute).frame(minHeight: target).accessibilityIdentifier("weeklyReviewReminderTime")
            }
            if let reminderNote { Text(reminderNote).font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.top, DS.Space.s)
        .overlay(alignment: .top) { Divider() }
    }
    private func updateReminder() {
        let on = reminderOn, day = reminderWeekday, minutes = reminderMinutes
        Task {
            let scheduled = await WeeklyReviewReminder.apply(enabled: on, weekday: day, minutes: minutes)
            if on && !scheduled { reminderOn = false; reminderNote = "Notifications are off for TaskFold. Turn them on in Settings to get a reminder." }
            else { reminderNote = nil }
        }
    }

    // MARK: Flow

    private func begin() {
        guard available else { return }
        inboxAtStart = inboxCount
        steps = WeeklyReview.steps(inbox: inboxCount, slipped: slipped.count, estimatesReliable: accuracy != nil,
                                   projectsWithoutNext: projectsWithout.count, somedayStale: staleIdeas.count)
        progress = WeeklyReviewProgress(); last = nil; keptIdeas = []; skippedProjects = []; stamped = false
        withAnimation(layout) { phase = .step(0) }
    }
    private func leave(_ index: Int, skipping: Bool) {
        let step = steps[index]
        if skipping { progress.skipped += 1 }
        if step == .inbox { progress.inboxCleared = max(0, inboxAtStart - inboxCount) }
        if step == .someday, progress.somedayReviewed > 0 { lastSomedayReview = Date().timeIntervalSinceReferenceDate }
        last = nil
        withAnimation(layout) { phase = index + 1 < steps.count ? .step(index + 1) : .done }
    }
    private func back(_ index: Int) { last = nil; withAnimation(layout) { phase = index > 0 ? .step(index - 1) : .intro } }
    private func hasWork(_ step: WeeklyReviewStep) -> Bool {
        switch step {
        case .inbox: inboxCount > 0
        case .slipped: !slipped.isEmpty
        case .estimates, .nextWeek: false
        case .projects: !projectsWithout.isEmpty
        case .someday: !staleIdeas.isEmpty
        }
    }

    private func stepPage(_ index: Int) -> some View {
        let step = steps[index]
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Step \(index + 1) of \(steps.count)").font(.footnote.weight(.semibold)).foregroundStyle(DS.Palette.textSecondary)
                Text(step.title).font(.system(.title2, design: .rounded).weight(.semibold)).accessibilityAddTraits(.isHeader)
                ProgressView(value: Double(index + 1), total: Double(steps.count)).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(index + 1) of \(steps.count), \(step.title)")
            Group {
                switch step {
                case .inbox: inboxStep
                case .slipped: slippedStep
                case .estimates: estimatesStep
                case .projects: projectsStep
                case .someday: somedayStep
                case .nextWeek: nextWeekStep
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier(step.identifier)
        }
    }

    @ViewBuilder private var footer: some View {
        if case .step(let index) = phase, available {
            let work = hasWork(steps[index])
            let finalStep = index + 1 == steps.count
            HStack(spacing: DS.Space.m) {
                Button("Back") { back(index) }.buttonStyle(.bordered).frame(minHeight: target).accessibilityIdentifier("weeklyReviewBack")
                Spacer(minLength: DS.Space.s)
                if work {
                    Button("Skip") { leave(index, skipping: true) }.buttonStyle(.bordered).frame(minHeight: target).accessibilityIdentifier("weeklyReviewSkip")
                } else {
                    Button(finalStep ? "Finish" : "Next") { leave(index, skipping: false) }.buttonStyle(.borderedProminent).frame(minHeight: target).accessibilityIdentifier("weeklyReviewNext")
                }
            }
            .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m).background(.bar)
        }
    }

    // MARK: Steps

    private func clearLine(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.textPrimary).frame(minHeight: target, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func lede(_ text: String) -> some View {
        Text(text).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    private func action(_ title: String, _ symbol: String, prominent: Bool = false, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: symbol).frame(minHeight: target) }
            .buttonStyle(.bordered).tint(prominent ? DS.Palette.accent : nil).accessibilityIdentifier(id)
    }

    // 1. Inbox: the existing Inbox review.
    @ViewBuilder private var inboxStep: some View {
        let count = inboxCount
        if count == 0 { clearLine("Inbox zero. Nothing waiting to be sorted.") }
        else {
            lede(count == 1 ? "1 task is waiting in your Inbox. Keep it, move it to a project or finish it." : "\(count) tasks are waiting in your Inbox. Keep, move or finish each one.")
            action("Review Inbox", "tray", prominent: true, id: "weeklyReviewInbox") { inboxReview = store.makeInboxReview(batch: .all) }
        }
    }

    // 2. Slipped last week: Smart reschedule's plan, plus per-task choices.
    private static let slippedShown = 20
    @ViewBuilder private var slippedStep: some View {
        let rows = slipped
        if rows.isEmpty { clearLine("Nothing slipped. Last week’s tasks are all handled.") }
        else {
            lede(rows.count == 1 ? "1 task was planned last week and is still open." : "\(rows.count) tasks were planned last week and are still open.")
            action("Reschedule all (\(rows.count))", "calendar.badge.clock", prominent: true, id: "weeklyReviewRescheduleAll") {
                reschedule = SmartRescheduleRequest(workspace: request.workspace, only: Set(rows.map(\.id)))
            }
            Text("You review the plan before anything moves, and can undo it.").font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(rows.prefix(Self.slippedShown)) { slippedRow($0) }
            if rows.count > Self.slippedShown {
                Text("and \(rows.count - Self.slippedShown) more, included in Reschedule all").font(.footnote).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }
    private func slippedRow(_ task: Record) -> some View {
        let day = TaskPlanner.plannedDay(task)
        let when = Dates.parse(day)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? day
        let buttons = Group {
            if !Planning.isRepeating(task) {
                Button { moveToSomeday(task) } label: { Label("Someday", systemImage: "moon.zzz").frame(minHeight: target) }
                    .buttonStyle(.bordered).accessibilityIdentifier("weeklyReviewSomeday")
            }
            Button(role: .destructive) { deleting = task } label: { Label("Delete", systemImage: "trash").frame(minHeight: target) }
                .buttonStyle(.bordered).accessibilityIdentifier("weeklyReviewDelete")
        }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "Untitled" : task.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text("Planned \(when)" + (Planning.isRepeating(task) ? " · Repeats" : "")).font(.footnote).foregroundStyle(DS.Palette.textSecondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) { buttons }
                VStack(alignment: .leading, spacing: DS.Space.s) { buttons }
            }
        }
        .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.textSecondary.opacity(0.08), in: .rect(cornerRadius: DS.Radius.l, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("weeklyReviewSlipped-" + task.id)
    }
    private func moveToSomeday(_ task: Record) {
        let before = undoIDs
        guard perform("Move to Someday", { store.moveToSomeday([task.id]) }), undoIDs != before else { failure = store.error; return }
        progress.movedToSomeday += 1
        last = LastAction(message: "Moved “\(task.title)” to Someday", ids: undoIDs) { $0.movedToSomeday = max(0, $0.movedToSomeday - 1) }
    }
    private func delete(_ task: Record) {
        let before = undoIDs
        deleting = nil
        guard perform("Delete Task", { store.weeklyDelete(task.id) }), undoIDs != before else { failure = store.error; return }
        progress.deleted += 1
        last = LastAction(message: "Deleted “\(task.title)”", ids: undoIDs) { $0.deleted = max(0, $0.deleted - 1) }
    }

    // 3. Estimates: the insight card that Insights already shows.
    @ViewBuilder private var estimatesStep: some View {
        if let accuracy {
            EstimateInsightCard(accuracy: accuracy)
            lede("Keep this in mind when you give next week’s tasks an estimate.")
        } else {
            lede("There aren’t enough finished tasks with Focus time yet. This appears once you have a few.")
        }
    }

    // 4. Projects without a next action: the existing Quick Add.
    @ViewBuilder private var projectsStep: some View {
        let rows = projectsWithout
        if rows.isEmpty { clearLine("Every active project has a next action.") }
        else {
            lede("These projects have no open task without a date, so nothing is ready to pick up. Add one small next action.")
            ForEach(rows) { project in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Label(project.name, systemImage: "folder").font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Space.s) { projectButtons(project) }
                        VStack(alignment: .leading, spacing: DS.Space.s) { projectButtons(project) }
                    }
                }
                .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.textSecondary.opacity(0.08), in: .rect(cornerRadius: DS.Radius.l, style: .continuous))
                .accessibilityElement(children: .contain).accessibilityIdentifier("weeklyReviewProject-" + project.id)
            }
        }
    }
    @ViewBuilder private func projectButtons(_ project: Record) -> some View {
        Button { startNextAction(project) } label: { Label("Add next action", systemImage: "plus").frame(minHeight: target) }
            .buttonStyle(.bordered).tint(DS.Palette.accent).accessibilityIdentifier("weeklyReviewAddNext")
        Button { withAnimation(layout) { _ = skippedProjects.insert(project.id) } } label: { Text("Not now").frame(minHeight: target) }
            .buttonStyle(.bordered).accessibilityIdentifier("weeklyReviewProjectSkip")
    }
    private func startNextAction(_ project: Record) {
        #if os(macOS)
        draft = ""; declined = []; choices = [:]; manual = [:]; addingTo = project
        #else
        addingTask = Record.task(user: store.userID, project: project.id)
        #endif
    }
    private func nextActionAdded(projectID: String) {
        guard !projectID.isEmpty else { return }
        progress.projectsFixed += 1
        skippedProjects.insert(projectID)
    }
    #if os(macOS)
    private func submitNextAction(_ project: Record) {
        guard workspace.add(draft, project: project.id, date: nil, declined: declined, referenceChoices: choices, manual: manual) != nil else { return }
        draft = ""; declined = []; choices = [:]; manual = [:]; addingTo = nil
        nextActionAdded(projectID: project.id)
    }
    #endif

    // 5. Someday: the existing weekly Someday review (older than a month), with its same decisions.
    @ViewBuilder private var somedayStep: some View {
        let rows = staleIdeas
        if rows.isEmpty { clearLine("Someday is light. Nothing has waited too long.") }
        else {
            lede("These ideas have waited over a month. Schedule what is ready, delete what is not, or keep it for later.")
            ForEach(rows.prefix(Self.slippedShown)) { ideaRow($0) }
            if rows.count > Self.slippedShown {
                Text("and \(rows.count - Self.slippedShown) more in Someday").font(.footnote).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }
    private func ideaRow(_ task: Record) -> some View {
        let created = TaskPlanning.instant(task.string("created_at")).map { $0.formatted(.dateTime.day().month(.abbreviated)) }
        let buttons = Group {
            Button { keep(task) } label: { Label("Keep", systemImage: "moon.zzz").frame(minHeight: target) }
                .buttonStyle(.bordered).accessibilityIdentifier("weeklyReviewKeepIdea")
            Menu {
                Button("Tomorrow") { schedule(task, offsetDays: 1) }
                Button("Next Monday") { schedule(task, nextMonday: true) }
            } label: { Label("Schedule", systemImage: "calendar").frame(minHeight: target) }
                .buttonStyle(.bordered).accessibilityIdentifier("weeklyReviewScheduleIdea")
            Button(role: .destructive) { deleting = task } label: { Label("Delete", systemImage: "trash").frame(minHeight: target) }
                .buttonStyle(.bordered).accessibilityIdentifier("weeklyReviewDeleteIdea")
        }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "Untitled" : task.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let created { Text("Added \(created)").font(.footnote).foregroundStyle(DS.Palette.textSecondary) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s) { buttons }
                VStack(alignment: .leading, spacing: DS.Space.s) { buttons }
            }
        }
        .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.accent.opacity(0.10), in: .rect(cornerRadius: DS.Radius.l, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("weeklyReviewIdea-" + task.id)
    }
    private func keep(_ task: Record) {
        withAnimation(layout) { _ = keptIdeas.insert(task.id) }
        progress.somedayReviewed += 1
    }
    private func schedule(_ task: Record, offsetDays: Int = 0, nextMonday: Bool = false) {
        let calendar = store.habitCalendar, start = calendar.startOfDay(for: Date())
        var date = calendar.date(byAdding: .day, value: offsetDays, to: start) ?? start
        if nextMonday { date = calendar.nextDate(after: start, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? date }
        let day = TaskPlanner.dayKey(date, calendar: calendar), before = undoIDs
        guard perform("Schedule Task", { store.scheduleFromSomeday([task.id], day: day) }), undoIDs != before else { failure = store.error; return }
        progress.somedayReviewed += 1
        last = LastAction(message: "Scheduled “\(task.title)”", ids: undoIDs) { $0.somedayReviewed = max(0, $0.somedayReviewed - 1) }
    }

    // 6. Next week: capacity numbers from the day planner.
    @ViewBuilder private var nextWeekStep: some View {
        let load = store.weeklyLoad(events: events)
        Text(load.message()).font(.system(.title3, design: .rounded).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("weeklyReviewLoadMessage")
        VStack(alignment: .leading, spacing: DS.Space.s) { ForEach(load.days) { dayRow($0) } }
        if load.unestimatedCount > 0 {
            Text(load.unestimatedCount == 1 ? "1 task has no estimate, so the real load may be higher." : "\(load.unestimatedCount) tasks have no estimate, so the real load may be higher.")
                .font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        Color.clear.frame(height: 0).task { await loadEvents() }
    }
    private func dayRow(_ day: WeeklyDayLoad) -> some View {
        let name = day.date.formatted(.dateTime.weekday(.wide).day())
        let tint: Color = day.state == .over ? DS.Palette.danger : (day.state == .full ? DS.Palette.dateTomorrow : DS.Palette.accent)
        let detail: String = switch day.state {
        case .off: "Day off"
        case .clear: "Clear"
        default: day.totals.capacityLabel
        }
        let spoken: String = day.state == .off ? "Day off" : (day.state == .clear ? "Nothing planned" : "\(day.totals.taskCount == 1 ? "1 task" : "\(day.totals.taskCount) tasks"), \(day.totals.capacityAccessibility)" + (day.totals.overNote.map { ". " + $0 } ?? ""))
        return VStack(alignment: .leading, spacing: 4) {
            if textSize.isAccessibilitySize {
                Text(name).font(.body.weight(.medium)); Text(detail).font(.callout).foregroundStyle(DS.Palette.textSecondary)
            } else {
                HStack { Text(name).font(.body.weight(.medium)); Spacer(minLength: DS.Space.s); Text(detail).font(.callout).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.trailing) }
            }
            Capsule().fill(DS.Palette.textSecondary.opacity(0.15)).frame(height: 6)
                .overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(tint).frame(width: proxy.size.width * (day.state == .off || day.state == .clear ? 0 : day.totals.fraction)) } }
                .accessibilityHidden(true)
            if let note = day.totals.overNote { Text(note).font(.footnote).foregroundStyle(DS.Palette.danger).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(minHeight: target)
        .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityValue(spoken)
        .accessibilityIdentifier("weeklyReviewDay-" + day.day)
    }
    private func loadEvents() async {
        guard !eventsLoaded else { return }
        eventsLoaded = true
        guard let window = await CalendarBusyStore.shared.capacityWindow(), window.state == "ready" else { return }
        events = window.events
    }

    // MARK: Done

    private var doneScreen: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(DS.Palette.accent).accessibilityHidden(true)
            Text(progress.headline).font(.system(.title, design: .rounded).weight(.semibold)).accessibilityAddTraits(.isHeader)
            if progress.isEmpty { Text(progress.summary).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
            else {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(progress.lines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if progress.skipped > 0 {
                Text(progress.skipped == 1 ? "You skipped 1 step. It will be here next time." : "You skipped \(progress.skipped) steps. They will be here next time.")
                    .font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { dismiss() }) { Text("Close").frame(maxWidth: .infinity, minHeight: target) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("weeklyReviewDone")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("weeklyReviewSummary")
        .onAppear {
            guard !stamped else { return }
            stamped = true
            if !store.markWeeklyReviewed() { failure = store.error }
            AccessibilityNotification.Announcement(progress.headline + ". " + progress.summary).post()
        }
    }

    // MARK: Undo and commits

    private func perform(_ name: String, _ body: () -> Bool) -> Bool {
        #if os(macOS)
        var saved = false
        workspace.run(name) { saved = body() }
        return saved
        #else
        return body()
        #endif
    }
    private func undoLast() {
        guard canUndo, let action = last else { return }
        if action.ids != nil {
            #if os(macOS)
            if let manager = workspace.undoManager, manager.canUndo { manager.undo() } else { store.undo() }
            #else
            store.undo()
            #endif
            guard action.ids != undoIDs else { return }
        }
        action.revert(&progress); last = nil
    }
}
