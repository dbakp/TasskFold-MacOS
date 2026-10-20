import SwiftUI
import Charts

struct ProjectPulseRequest: Identifiable {
    var id = UUID()
    var workspace: WorkspaceBinding
    var projectID: String?
}
private struct ProjectPulseActionKey: EnvironmentKey { static let defaultValue: (String?) -> Void = { _ in } }
extension EnvironmentValues {
    var openProjectPulse: (String?) -> Void {
        get { self[ProjectPulseActionKey.self] }
        set { self[ProjectPulseActionKey.self] = newValue }
    }
}

struct ProjectPulseView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ProjectPulseRequest
    let openTask: (Record) -> Void
    @State private var projectID = ""
    @State private var limit = 30
    private var active: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) && store.focusAvailable }
    private var project: Record? { store.projects.first { $0.id.lowercased() == projectID.lowercased() } }
    private var recordedFrom: Date? { store.rows(TaskActivity.epochTable).first { $0.id == "current" }.flatMap { TaskPlanning.instant($0.string("recorded_from")) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !active {
                        ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Reopen Project pulse in your current workspace."))
                    } else {
                        #if os(iOS)
                        Menu {
                            Button("Choose a project") { projectID = "" }
                            ForEach(store.projects) { p in
                                Button(projectLabel(p)) { projectID = p.id.lowercased() }
                                    .accessibilityIdentifier("pulseProject-" + p.id.lowercased())
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Project: " + (project.map(projectLabel) ?? (projectID.isEmpty ? "Choose a project" : "Project unavailable")))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 12)
                                Image(systemName: "chevron.up.chevron.down")
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.accessibilityIdentifier("pulseProjectPicker")
                        #else
                        Picker("Project", selection: $projectID) {
                            Text("Choose a project").tag("")
                            if !projectID.isEmpty, project == nil { Text("Project unavailable").tag(projectID) }
                            ForEach(store.projects) { p in Text(projectLabel(p)).tag(p.id.lowercased()) }
                        }.frame(minHeight: 44).accessibilityIdentifier("pulseProjectPicker")
                        #endif
                        if let project {
                            TimelineView(.periodic(from: .now, by: 60)) { context in content(project, now: context.date) }
                        } else {
                            ContentUnavailableView(projectID.isEmpty ? "Choose a project" : "Project unavailable", systemImage: "chart.bar", description: Text(projectID.isEmpty ? "See the work completed and what needs your attention." : "This project may have been removed or its access changed. Choose another project."))
                        }
                    }
                }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }.navigationTitle("Project pulse")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closeProjectPulse") } }
            .onAppear { projectID = request.projectID?.lowercased() ?? "" }
            .onChange(of: projectID) { _, _ in limit = 30 }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 580, minHeight: 540)
        #endif
    }
    private func content(_ project: Record, now: Date) -> some View {
        let reading = ProjectPulseReading(project: project.id, tasks: store.tasks, activity: store.rows(TaskActivity.table), now: now)
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Current project tasks", systemImage: "chart.bar.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(project.name).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pulseProjectName")
                Text("\(reading.completed) of \(reading.total) completed").font(.title.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pulseProgress")
                if reading.total > 0 { ProgressView(value: Double(reading.completed), total: Double(reading.total)).tint(Color.taskfold).accessibilityLabel("Project completion").accessibilityValue("\(reading.completed) of \(reading.total) tasks") }
                Text("\(reading.total - reading.completed) open · Each task occurrence counts once. Checklist items are excluded. Adding or moving work changes this total.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.taskfold.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            if store.pendingCount > 0 { Label("Current counts include this device’s saved changes. Activity updates after sync.", systemImage: "icloud.and.arrow.up").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pulsePending") }
            attention(project, now: now)
            VStack(alignment: .leading, spacing: 12) {
                Text("Recorded in the last 7 days").font(.headline)
                Text("\(reading.start.formatted(date: .abbreviated, time: .omitted)) – \(now.formatted(date: .abbreviated, time: .omitted)) · \(TimeZone.current.identifier)").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let recordedFrom {
                    if reading.malformed == 0 {
                        Text("\(reading.completions) completion \(reading.completions == 1 ? "event" : "events") · \(reading.reopens) reopen \(reading.reopens == 1 ? "event" : "events")").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pulseActivityCounts")
                        Text("\(reading.additions) added · \(reading.movedIn) moved in · \(reading.movedOut) moved out").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else { Label("Some activity could not be read. Refresh before relying on these counts.", systemImage: "exclamationmark.arrow.triangle.2.circlepath").fixedSize(horizontal: false, vertical: true) }
                    Text("History starts \(recordedFrom.formatted(date: .abbreviated, time: .shortened)). Earlier work has no recorded timeline. Offline changes appear when received; a completion’s chosen time is retained.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pulseHistoryCoverage")
                    Text("\(store.localMode ? "Saved on this device." : "Activity is limited to currently accessible work.") These are events, separate from the current task total.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if reading.events.isEmpty { Text("No recorded activity for this project yet.").foregroundStyle(.secondary) }
                    else {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(reading.events.prefix(limit))) { event in activityRow(event) }
                        }
                        if limit < reading.events.count { Button { limit += 30 } label: { Text("Show more activity").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityIdentifier("pulseMoreActivity") }
                    }
                } else {
                    Text(store.localMode ? "Activity will be recorded when you change a task on this device." : "Sync your workspace to load recorded history.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pulseHistoryUnavailable")
                }
            }
        }
    }
    private func attention(_ project: Record, now: Date) -> some View {
        let today = TaskPlanner.dayKey(now)
        let soon = TaskPlanner.dayKey(Calendar.current.date(byAdding: .day, value: 6, to: now)!)
        let tasks = store.tasks.filter { task in
            guard !task.completed, task.string("project_id").lowercased() == project.id.lowercased() else { return false }
            let deadline = task.string("deadline_date"), planned = TaskPlanner.plannedDay(task)
            return (!deadline.isEmpty && Dates.parse(deadline) != nil && deadline <= soon) || (!planned.isEmpty && Dates.parse(planned) != nil && planned < today)
        }.sorted { a, b in
            let first = a.string("deadline_date"), second = b.string("deadline_date")
            if first != second { return (first.isEmpty ? "9999" : first) < (second.isEmpty ? "9999" : second) }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.id < b.id
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Needs attention").font(.headline)
            Text("Open tasks planned before today or with a deadline in the next 7 days.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if tasks.isEmpty { Text("No overdue plans or near deadlines.").foregroundStyle(.secondary) }
            ForEach(Array(tasks.prefix(5))) { task in
                Button { guard active, store.record("tasks", id: task.id) != nil else { return }; dismiss(); openTask(task) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Text(task.string("deadline_date").isEmpty ? "Planned \(TaskPlanner.plannedDay(task))" : "Deadline \(task.string("deadline_date"))").font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityIdentifier("pulseAttention-" + task.id)
            }
            if tasks.count > 5 { Text("\(tasks.count - 5) more in this project").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func activityRow(_ event: TaskActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.kinds.map(\.title).joined(separator: " · ")).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pulseEvent-" + event.id)
            Text(store.tasks.first { $0.id.lowercased() == event.taskID }?.title ?? "Removed or unavailable task").fixedSize(horizontal: false, vertical: true)
            Text("Recorded \(event.recordedAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
            if event.kinds.contains(.completed), abs(event.effectiveAt.timeIntervalSince(event.recordedAt)) >= 60 {
                Text("Completion time \(event.effectiveAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
            }
            if event.kinds.contains(.moved) {
                Text("\(place(event.before)) → \(place(event.after))").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func projectLabel(_ project: Record) -> String {
        store.projects.filter { $0.name.caseInsensitiveCompare(project.name) == .orderedSame }.count > 1 ? project.name + " · " + project.id : project.name
    }
    private func place(_ state: [String: JSON]) -> String {
        guard let id = state["project_id"]?.text, !id.isEmpty else { return "Inbox" }
        return store.projects.first { $0.id.lowercased() == id.lowercased() }?.name ?? "Another project"
    }
}

struct InsightsRequest:Identifiable { var id=UUID();var workspace:WorkspaceBinding }
private struct InsightsActionKey:EnvironmentKey { static let defaultValue:()->Void = {} }
extension EnvironmentValues {
    var openInsights:()->Void { get{self[InsightsActionKey.self]} set{self[InsightsActionKey.self]=newValue} }
}
struct InsightsView:View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    let request:InsightsRequest
    @State private var scope=InsightsReading.Scope.mine
    @State private var windowDays=7
    @State private var selectedDate:Date?
    @State private var editing=false
    @AccessibilityFocusState private var goalsFocused:Bool
    private var active:Bool { request.workspace.matches(account:store.userID,generation:store.workspaceGeneration) && store.insightsAvailable }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    if !active { ContentUnavailableView("Workspace changed",systemImage:"person.crop.circle",description:Text("Reopen Insights in your current workspace.")) }
                    else if let goals=store.productivityGoals {
                        TimelineView(.periodic(from:.now,by:60)) { context in content(goals,now:context.date) }
                    } else { ContentUnavailableView("Goals unavailable",systemImage:"arrow.down.app",description:Text("The saved settings are preserved. Refresh or update Taskfold before editing these goals.")) }
                }.padding(24).frame(maxWidth:760,alignment:.leading).frame(maxWidth:.infinity)
            }.navigationTitle("Insights")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closeInsights") } }
            .sheet(isPresented:$editing,onDismiss:{if active { goalsFocused=true }}) { ProductivityGoalsEditor(workspace:request.workspace) }
            .onChange(of:store.workspaceGeneration) { _,_ in dismiss() }
            .onChange(of:windowDays) { _,_ in selectedDate=nil }
            .onChange(of:scope) { _,_ in selectedDate=nil }
        }
        #if os(macOS)
        .frame(minWidth:520,idealWidth:700,minHeight:580,idealHeight:760)
        #endif
    }
    private func reading(_ goals:ProductivityGoals,scope:InsightsReading.Scope,now:Date) -> InsightsReading {
        InsightsReading(account:store.userID,activity:store.rows(TaskActivity.table),epoch:store.rows(TaskActivity.epochTable),goals:goals,scope:scope,accessibleProjects:Set(store.allProjects.map(\.id)),windowDays:windowDays,now:now)
    }
    private func content(_ goals:ProductivityGoals,now:Date) -> some View {
        let personal=reading(goals,scope:.mine,now:now),shown=scope == .mine ? personal : reading(goals,scope:scope,now:now)
        return VStack(alignment:.leading,spacing:24) {
            if textSize.isAccessibilitySize {
                VStack(alignment:.leading,spacing:12) { personalHeading;goalsButton }
            } else { HStack(alignment:.firstTextBaseline) { personalHeading;Spacer(minLength:12);goalsButton } }
            if personal.reliable {
                if textSize.isAccessibilitySize { VStack(spacing:14) { progressCards(goals,reading:personal,now:now) } }
                else { ViewThatFits(in:.horizontal) {
                    HStack(spacing:14) { progressCards(goals,reading:personal,now:now) }
                    VStack(spacing:14) { progressCards(goals,reading:personal,now:now) }
                } }
                Text("My recorded completions · Week starts \(weekday(goals.weekStart)) · \(goals.timeZone)").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("insightsCalendarContext")
            }
            if store.pendingCount>0 { Label("Saved task changes appear in Insights after sync. Your goal choice can be saved while offline.",systemImage:"icloud.and.arrow.up").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("insightsPending") }
            if !shown.hasHistory {
                ContentUnavailableView("No recorded history yet",systemImage:"chart.bar.xaxis",description:Text(store.localMode ? "Complete a task to start recording progress on this device." : "Sync your workspace to load its recorded activity."))
            } else if !shown.reliable {
                ContentUnavailableView { Label("Activity needs a refresh",systemImage:"exclamationmark.arrow.triangle.2.circlepath") } description: { Text("Some history could not be read. It is preserved; refresh before relying on totals.") } actions: {
                    if !store.localMode { Button("Refresh workspace") { Task{await store.sync()} }.disabled(store.syncing) }
                }
            } else {
                VStack(alignment:.leading,spacing:16) {
                    if textSize.isAccessibilitySize {
                        VStack(alignment:.leading,spacing:8) { Text("Chart scope").font(.headline);scopePicker.pickerStyle(.menu).labelsHidden() }
                        VStack(alignment:.leading,spacing:8) { Text("Recorded completions").font(.headline);windowPicker }
                    } else {
                        scopePicker.pickerStyle(.segmented)
                        HStack { Text("Recorded completions").font(.headline);Spacer();windowPicker }
                    }
                    Text("\(shown.days.reduce(0){$0+$1.count}) recorded · \(date(shown.windowStart,calendar:goals.calendar)) – \(date(now,calendar:goals.calendar))").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("insightsWindowCount")
                    if textSize.isAccessibilitySize {
                        ForEach(shown.days) { day in Text(daySummary(day,calendar:goals.calendar)).fixedSize(horizontal:false,vertical:true).padding(.vertical,4).accessibilityIdentifier("insightsDay-"+day.id) }
                    } else { chart(shown,goals:goals) }
                    if let selection=selectedDate,let day=shown.days.first(where:{$0.id==TaskPlanner.dayKey(selection,calendar:goals.calendar)}) {
                        Text(daySummary(day,calendar:goals.calendar)).font(.callout).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("insightsSelectedDay")
                    } else if !textSize.isAccessibilitySize { Text("Select a day to see its count. Rest days are muted.").font(.caption).foregroundStyle(.secondary) }
                }.padding(20).background(Color.secondary.opacity(0.05),in:RoundedRectangle(cornerRadius:24))
            }
            if let start=shown.recordedFrom {
                Label("Tracking since \(date(start,calendar:goals.calendar)). Earlier days can be incomplete; recorded backdated completions are included.",systemImage:"clock.arrow.circlepath").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("insightsHistoryCoverage")
            }
            Text("A completion counts once per task occurrence. Reopening removes its credit from the original day; changing its completion time moves that credit. Checklist items are excluded. Weekly goals include completions on rest days. Workspace charts include other people’s accessible activity; personal goals use your completions.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("Totals cover currently accessible recorded work. Changes in access can change these totals.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if store.localMode { Label("History and goals are saved on this device.",systemImage:"internaldrive").font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private var personalHeading:some View { Text("Personal progress").font(.title2.weight(.semibold)).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("insightsPersonalHeading") }
    private var goalsButton:some View { Button { editing=true } label: { Label("Goals",systemImage:"slider.horizontal.3").frame(minHeight:44).contentShape(.rect) }.buttonStyle(.bordered).accessibilityIdentifier("editProductivityGoals").accessibilityFocused($goalsFocused) }
    private var scopePicker:some View { Picker("Chart scope",selection:$scope) { ForEach(InsightsReading.Scope.allCases,id:\.self) { Text($0 == .mine ? "Mine" : "Workspace").tag($0).accessibilityLabel($0.title) } }.accessibilityIdentifier("insightsScope") }
    private var windowPicker:some View { Picker("Time window",selection:$windowDays) { Text("7 days").tag(7);Text("28 days").tag(28) }.labelsHidden().fixedSize().accessibilityLabel("Time window").accessibilityIdentifier("insightsWindow") }
    @ViewBuilder private func progressCards(_ goals:ProductivityGoals,reading:InsightsReading,now:Date) -> some View {
        progressCard("Today",count:reading.today,target:goals.target(on:now),detail:goals.dailyTarget>0 && goals.target(on:now)==nil ? "Rest day" : goals.dailyTarget==0 ? "Daily goal off" : "Daily goal",identifier:"insightsTodayCount")
        progressCard("This week",count:reading.week,target:goals.weeklyTarget>0 ? goals.weeklyTarget : nil,detail:goals.weeklyTarget==0 ? "Weekly goal off" : "Weekly goal",identifier:"insightsWeekCount")
    }
    private func progressCard(_ title:String,count:Int,target:Int?,detail:String,identifier:String) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline,spacing:6) { Text("\(count)").font(.system(.largeTitle,design:.rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).accessibilityIdentifier(identifier);if let target { Text("of \(target)").font(.headline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) } }
            if let target { ProgressView(value:Double(min(count,target)),total:Double(target)).tint(Color.taskfold).accessibilityLabel(title+" personal goal").accessibilityValue("\(count) of \(target) recorded") }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth:210,maxWidth:.infinity,alignment:.leading).background(Color.taskfold.opacity(0.08),in:RoundedRectangle(cornerRadius:24))
    }
    private func chart(_ reading:InsightsReading,goals:ProductivityGoals) -> some View {
        let maxCount=max(1,reading.days.map(\.count).max() ?? 0)
        let ticks=Array(Set([0,maxCount,(maxCount+2)/3,(2*maxCount+2)/3])).sorted()
        return Chart {
            ForEach(reading.days) { day in
                if day.coverage != .untracked || day.count>0 {
                    BarMark(x:.value("Day",day.date,unit:.day),y:.value("Recorded completions",day.count)).cornerRadius(4)
                        .foregroundStyle(Color.taskfold.opacity(day.restDay ? 0.35 : 0.9))
                        .accessibilityLabel(Text(date(day.date,calendar:goals.calendar)))
                        .accessibilityValue(Text("\(day.count) recorded completions"+(day.coverage == .partial ? ", partial history" : "")+(day.restDay ? ", rest day" : "")))
                }
            }
        }.chartXScale(domain:reading.windowStart...reading.windowEnd)
            .chartYScale(domain:0...maxCount)
            .chartXAxis { AxisMarks(values:.stride(by:.day,count:windowDays==7 ? 1 : 7)) { _ in AxisValueLabel(format:windowDays==7 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day());AxisGridLine() } }
            .chartYAxis { AxisMarks(values:ticks) { AxisValueLabel();AxisGridLine() } }
            .chartXSelection(value:$selectedDate).frame(height:220).environment(\.calendar,goals.calendar).environment(\.timeZone,goals.calendar.timeZone).accessibilityIdentifier("insightsChart")
    }
    private func weekday(_ value:Int) -> String { ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][value-1] }
    private func date(_ date:Date,calendar:Calendar) -> String { let f=DateFormatter();f.calendar=calendar;f.timeZone=calendar.timeZone;f.dateStyle = .medium;return f.string(from:date) }
    private func daySummary(_ day:InsightsReading.Day,calendar:Calendar) -> String { date(day.date,calendar:calendar)+" · "+(day.coverage == .untracked && day.count==0 ? "No recorded history" : "\(day.count) recorded completions")+(day.coverage == .partial ? " · Partial history" : "")+(day.restDay ? " · Rest day" : "") }
}

struct ProductivityGoalsEditor:View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let workspace:WorkspaceBinding
    @State private var baseline:JSON = .null
    @State private var initial:JSON = .null
    @State private var base:ProductivityGoals?
    @State private var daily=false
    @State private var weekly=false
    @State private var dailyText="5"
    @State private var weeklyText="20"
    @State private var activeDays=Set(2...6)
    @State private var weekStart=2
    @State private var zone=TimeZone.current.identifier
    @State private var choosingZone=false
    @State private var review:JSON?
    @State private var discard=false
    @State private var message:String?
    @State private var loaded=false
    @FocusState private var numberFocused:String?
    private var draft:Result<JSON,Error> {
        Result {
            guard var goals=base else { throw AppFailure(message:"These saved goals need a newer Taskfold version.") }
            guard !daily || Int(dailyText).map({(1...10000).contains($0)})==true else { throw AppFailure(message:"Use a daily goal between 1 and 10,000, or turn it off.") }
            guard !weekly || Int(weeklyText).map({(1...10000).contains($0)})==true else { throw AppFailure(message:"Use a weekly goal between 1 and 10,000, or turn it off.") }
            goals.dailyTarget=daily ? Int(dailyText)! : 0;goals.weeklyTarget=weekly ? Int(weeklyText)! : 0;goals.activeWeekdays=activeDays;goals.weekStart=weekStart;goals.timeZone=zone
            return try goals.validated().document
        }
    }
    private var changed:Bool { (try? draft.get()).map{$0 != initial} ?? true }
    var body:some View {
        NavigationStack {
            Group {
                if let review {
                    List {
                        Section("My draft") { Text((try? draft.get()).map(ProductivityGoalEdit.summary) ?? "Fix the draft before saving.").textSelection(.enabled) }
                        Section("Latest synced choice") { Text(ProductivityGoalEdit.summary(review)).textSelection(.enabled) }
                        Section {
                            Button("Keep my goals") { save(reviewing:review) }.disabled((try? draft.get())==nil || (try? ProductivityGoals(document:review))==nil).accessibilityIdentifier("keepDraftGoals")
                            Button("Use latest in editor") {
                                guard validWorkspace,store.productivityGoalDocument==review else { message="Goals changed again. Open a fresh review.";self.review=nil;return }
                                load(review);self.review=nil
                            }.accessibilityIdentifier("useLatestGoals")
                        }
                        if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("goalReviewError") }
                    }
                } else if base == nil {
                    ContentUnavailableView("Goals unavailable",systemImage:"arrow.down.app",description:Text("The saved choice is preserved. Refresh or update Taskfold to edit it."))
                } else {
                    Form {
                        Section("Personal targets") {
                            Toggle("Daily goal",isOn:$daily).accessibilityIdentifier("dailyGoalEnabled")
                            if daily {
                                numberField("Daily completions",text:$dailyText,id:"dailyGoalTarget")
                                if Int(dailyText).map({(1...10000).contains($0)}) != true { Text("Use a daily goal between 1 and 10,000, or turn it off.").foregroundStyle(.red).accessibilityIdentifier("goalValidation") }
                            }
                            Toggle("Weekly goal",isOn:$weekly).accessibilityIdentifier("weeklyGoalEnabled")
                            if weekly {
                                numberField("Weekly completions",text:$weeklyText,id:"weeklyGoalTarget")
                                if Int(weeklyText).map({(1...10000).contains($0)}) != true { Text("Use a weekly goal between 1 and 10,000, or turn it off.").foregroundStyle(.red).accessibilityIdentifier("weeklyGoalValidation") }
                            }
                            Text("Only your recorded completions count. Reopening a task corrects its original day. Recurring task occurrences count separately; checklist items do not.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Active days") {
                            ForEach(0..<7,id:\.self) { offset in
                                let day=(weekStart-1+offset)%7+1
                                Toggle(weekday(day),isOn:Binding(get:{activeDays.contains(day)},set:{if $0 {activeDays.insert(day)}else{activeDays.remove(day)}})).accessibilityIdentifier("goalWeekday-\(day)")
                            }
                            if daily && activeDays.isEmpty { Text("Choose at least one active day, or turn off the daily goal.").foregroundStyle(.red).accessibilityIdentifier("goalDaysValidation") }
                            Text("Inactive days are rest days, with no daily target. Work completed on a rest day still counts towards the weekly goal.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Calendar") {
                            Picker("Week starts",selection:$weekStart) { ForEach(1...7,id:\.self) { Text(weekday($0)).tag($0) } }.accessibilityIdentifier("goalWeekStart")
                            Button { choosingZone=true } label: { HStack { Text("Time zone");Spacer();Text(zone).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }.frame(minHeight:44) }.accessibilityIdentifier("goalTimeZone")
                            Text("This time zone is saved with your goals so phone and Mac use the same day and week. Task dates stay as planned.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if store.productivityGoalDocument != baseline {
                            Section("Changed on another device") { Button("Review latest goals") { review=store.productivityGoalDocument }.accessibilityIdentifier("reviewLatestGoals") }
                        }
                        if case .failure(let error)=draft { Text(error.localizedDescription).foregroundStyle(.red).accessibilityIdentifier("goalDraftError") }
                        if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("goalSaveError") }
                    }.formStyle(.grouped).accessibilityIdentifier("productivityGoalsForm")
                }
            }.navigationTitle(review==nil ? "Goals" : "Review goals")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { if review != nil { review=nil } else if changed && base != nil { discard=true } else { dismiss() } }.keyboardShortcut(.cancelAction) }
                if review==nil { ToolbarItem(placement:.confirmationAction) { Button("Save") { save(reviewing:nil) }.disabled(!changed || (try? draft.get())==nil).keyboardShortcut("s",modifiers:.command).accessibilityIdentifier("saveProductivityGoals") } }
            }
            #if os(iOS)
            // Use a measured inset, as in the filter editor, to avoid invalid keyboard-toolbar frames.
            .safeAreaInset(edge:.bottom,spacing:0) {
                if numberFocused != nil {
                    HStack {
                        Spacer()
                        Button { numberFocused=nil } label: {
                            Text("Done").font(.body.weight(.medium)).frame(minWidth:44,minHeight:44).contentShape(.rect)
                        }.accessibilityIdentifier("goalsHideKeyboard")
                    }.padding(.horizontal,16).background(.bar)
                }
            }
            #endif
            .sheet(isPresented:$choosingZone) { GoalTimeZonePicker(selection:$zone) }
            .confirmationDialog("Discard goal changes?",isPresented:$discard,titleVisibility:.visible) { Button("Discard changes",role:.destructive) { dismiss() } }
            .interactiveDismissDisabled(changed && base != nil)
            .onAppear { if !loaded {loaded=true;load(store.productivityGoalDocument)} }
            .onChange(of:store.workspaceGeneration) { _,_ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth:500,idealWidth:580,minHeight:500,idealHeight:700)
        #endif
    }
    private var validWorkspace:Bool { workspace.matches(account:store.userID,generation:store.workspaceGeneration) && store.insightsAvailable }
    private func load(_ document:JSON) {
        baseline=document;base=try? ProductivityGoals(document:document);message=nil
        guard let goals=base else {initial=document;return}
        daily=goals.dailyTarget>0;weekly=goals.weeklyTarget>0;dailyText=String(daily ? goals.dailyTarget : 5);weeklyText=String(weekly ? goals.weeklyTarget : 20);activeDays=goals.activeWeekdays;weekStart=goals.weekStart;zone=goals.timeZone;initial=goals.document
    }
    private func save(reviewing latest:JSON?) {
        guard validWorkspace else { message="Reopen goals in your current workspace.";return }
        do {
            var desired=try draft.get()
            if let latest { desired=try ProductivityGoalEdit.keepingKnownFields(desired,over:latest) }
            if store.saveProductivityGoals(desired,expected:latest ?? baseline,workspace:workspace) { review=nil;dismiss() }
            else { message=store.error;store.error=nil;if store.productivityGoalDocument != baseline { review=store.productivityGoalDocument } }
        } catch { message=error.localizedDescription }
    }
    private func weekday(_ value:Int) -> String { ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][value-1] }
    private func numberField(_ name:String,text:Binding<String>,id:String) -> some View {
        TextField(name,text:text).accessibilityIdentifier(id).focused($numberFocused,equals:id)
        #if os(iOS)
            .keyboardType(.numberPad)
        #endif
    }
}
private struct GoalTimeZonePicker:View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection:String
    @State private var query=""
    private var zones:[String] { Array(Set(TimeZone.knownTimeZoneIdentifiers+[selection,"UTC"])).sorted().filter{query.isEmpty || $0.replacingOccurrences(of:"_",with:" ").localizedCaseInsensitiveContains(query)} }
    var body:some View {
        NavigationStack {
            List(zones,id:\.self) { zone in
                Button { selection=zone;dismiss() } label: { HStack { Text(zone.replacingOccurrences(of:"_",with:" "));Spacer();if selection==zone {Image(systemName:"checkmark")} }.frame(minHeight:44) }.accessibilityLabel(zone+(selection==zone ? ", selected" : ""))
            }
            #if os(iOS)
            .searchable(text:$query,placement:.navigationBarDrawer(displayMode:.always),prompt:"Search time zones")
            #else
            .searchable(text:$query,prompt:"Search time zones")
            #endif
            .navigationTitle("Time zone")
                .toolbar { ToolbarItem(placement:.cancellationAction) {Button("Cancel"){dismiss()}} }
        }
        #if os(macOS)
        .frame(width:500,height:600)
        #endif
    }
}
