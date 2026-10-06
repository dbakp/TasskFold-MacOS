import SwiftUI

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
