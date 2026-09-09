import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var projectEditor: Record?
    @State private var labelEditor: Record?
    @State private var projectsExpanded = true
    @State private var labelsExpanded = true
    private var today: String { Dates.day(Date()) }
    private var open: [Record] { store.tasks.filter { !$0.completed } }
    var body: some View {
        @Bindable var workspace = workspace
        List(selection: Binding(get: { Optional(workspace.section) }, set: { if let value = $0 { workspace.section = value } })) {
            Section {
                item(.today, "Today", count: open.filter { !$0.string("due_date").isEmpty && $0.string("due_date") <= today }.count, dropDay: today)
                item(.inbox, "Inbox", count: open.filter { $0.string("project_id").isEmpty }.count, dropProject: "")
                item(.upcoming, "Upcoming", count: nil, dropDay: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
                item(.calendar, "Calendar", count: nil)
            }
            Section("Browse") {
                item(.all, "All Tasks", count: open.count)
                item(.completed, "Completed", count: nil)
            }
            Section(isExpanded: $projectsExpanded) {
                ForEach(store.projects) { project in
                    ProjectDropRow(project: project) {
                        Label {
                            HStack {
                                Text(project.name).lineLimit(1)
                                Spacer()
                                count(open.filter { $0.string("project_id") == project.id }.count)
                            }
                        } icon: { Image(systemName: "folder.fill").foregroundStyle(Color.project(project.string("color"))) }
                    }
                    .tag(SidebarItem.project(project.id))
                    .contextMenu {
                        Button("Edit Project…") { projectEditor = project }
                        Button("Delete Project…", role: .destructive) { projectEditor = project }
                    }
                    .accessibilityLabel(project.name)
                }
                .onMove { source, destination in
                    var projects = store.projects; projects.move(fromOffsets: source, toOffset: destination)
                    workspace.run("Reorder Projects") { for (index, var project) in projects.enumerated() { project["order_index"] = .number(Double(index)); store.save("projects", project) } }
                }
                Button { newProject() } label: { Label("New Project", systemImage: "plus").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityIdentifier("newProject")
            } header: { Text("Projects") }
            Section(isExpanded: $labelsExpanded) {
                ForEach(store.labels) { label in
                    Label {
                        HStack { Text(label.name).lineLimit(1); Spacer(); count(open.filter { $0["labels"].list.contains(.string(label.id)) || $0["labels"].list.contains(.string(label.name)) }.count) }
                    } icon: { Image(systemName: "tag.fill").foregroundStyle(Color.project(label.string("color"))) }
                    .tag(SidebarItem.label(label.id))
                    .contextMenu { Button("Edit Label…") { labelEditor = label } }
                }
                Button { labelEditor = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": .string(""), "color": .string("#8b5cf6")]) } label: { Label("New Label", systemImage: "plus").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            } header: { Text("Labels") }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SyncFooter() }
        .sheet(item: $projectEditor) { NamedEditor(table: "projects", record: $0) }
        .sheet(item: $labelEditor) { NamedEditor(table: "labels", record: $0) }
        .onChange(of: workspace.newProjectRequest) { _, _ in newProject() }
        .toolbar { ToolbarItem(placement: .navigation) { EmptyView() } }
    }
    private func newProject() {
        projectEditor = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": .string(""), "color": .string("#e31e4b"), "order_index": .number(Double(store.projects.count))])
    }
    @ViewBuilder private func count(_ value: Int) -> some View {
        if value > 0 { Text("\(value)").font(.callout).monospacedDigit().foregroundStyle(.secondary).id(value).transition(.textSwap).animation(Transitions.Ease.smoothOut, value: value) }
    }
    @ViewBuilder private func item(_ item: SidebarItem, _ title: String, count value: Int?, dropDay: String? = nil, dropProject: String? = nil) -> some View {
        let label = Label { HStack { Text(title); Spacer(); if let value { count(value) } } } icon: { Image(systemName: item.symbol) }
            .tag(item).accessibilityLabel(title)
        if dropDay != nil || dropProject != nil {
            TaskDropTarget(onDrop: { ids in
                if let dropDay { workspace.reschedule(Set(ids), to: dropDay, label: item == .today ? "today" : "tomorrow") }
                else if let dropProject { workspace.move(Set(ids), toProject: dropProject) }
            }) { label }
        } else { label }
    }
}

/// A sidebar project row that accepts dragged tasks and moves them into the project.
struct ProjectDropRow<Content: View>: View {
    @Environment(Workspace.self) private var workspace
    let project: Record
    @ViewBuilder var content: Content
    var body: some View {
        TaskDropTarget(onDrop: { ids in workspace.move(Set(ids), toProject: project.id) }) { content }
    }
}

/// Wraps any view as a drop target for dragged tasks with a highlighted outline while targeted.
struct TaskDropTarget<Content: View>: View {
    @Environment(Workspace.self) private var workspace
    let onDrop: ([String]) -> Void
    @ViewBuilder var content: Content
    @State private var targeted = false
    var body: some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(targeted ? 0.16 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(targeted ? 0.8 : 0), lineWidth: 1.5))
            .padding(.horizontal, -6).padding(.vertical, -2)
            .animation(Motion.quick, value: targeted)
            .onDrop(of: [.taskfoldTask], isTargeted: $targeted) { providers in
                let ids = workspace.drag.ids
                guard !ids.isEmpty else { return false }
                onDrop(ids)
                workspace.drag.end()
                return true
            }
    }
}

/// The sync line at the foot of the sidebar: online state, pending changes, and a retry when sync pauses.
struct SyncFooter: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(store.notice != nil ? .orange : .secondary)
                    .id(symbol).transition(.iconSwap)
                Group {
                    if store.syncing { ShimmerText(text: "Syncing…") }
                    else { Text(status).lineLimit(1).id(status).transition(.textSwap) }
                }
                Spacer(minLength: 0)
                if store.notice != nil { Button("Retry") { Task { await store.sync() } }.buttonStyle(.link).font(.caption) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .animation(Transitions.Ease.smoothOut, value: symbol)
            .animation(Transitions.Ease.smoothOut, value: status)
            .help(store.notice ?? (store.localMode ? "Tasks are stored only on this Mac." : "Changes sync to your Taskfold account."))
        }
        .background(.bar)
    }
    private var symbol: String { store.localMode ? "internaldrive" : !store.online ? "wifi.slash" : store.syncing ? "arrow.triangle.2.circlepath" : store.notice != nil ? "exclamationmark.icloud" : "checkmark.icloud" }
    private var status: String { store.localMode ? "Saved on this Mac" : !store.online ? "Offline · saved on this Mac" : store.syncing ? "Syncing…" : store.pendingCount > 0 ? "\(store.pendingCount) changes waiting" : store.lastSync.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Up to date" }
}
