import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(\.openMentions) private var openMentions
    @Environment(\.openInsights) private var openInsights
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var projectEditor: Record?
    @State private var labelEditor: Record?
    @State private var filterEditor: Record?
    @State private var templatesPresented = false
    @State private var sharedDraftsPresented = false
    @State private var archivePresented = false
    @State private var multiLinePresented = false
    @State private var projectsExpanded = true
    @State private var labelsExpanded = true
    private var today: String { Dates.day(Date()) }
    private var open: [Record] { store.activeTasks.filter { TaskKind.mayComplete($0) && !$0.completed } }
    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            Button { workspace.finderPresented = true } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Search Everywhere")
                    Spacer()
                    Text("⌘F").font(.caption).foregroundStyle(.tertiary)
                }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityIdentifier("openFinder")
        List(selection: Binding(get: { Optional(workspace.section) }, set: { if let value = $0 { workspace.section = value } })) {
            Section {
                item(.today, "Today", count: store.matching(TaskQuery(scope: .today)).filter { TaskKind.mayComplete($0) && !$0.completed }.count, dropDay: today)
                item(.inbox, "Inbox", count: store.inboxProductiveReading.work.filter(InboxReviewRequest.eligible).count, dropProject: "")
                item(.upcoming, "Upcoming", count: nil, dropDay: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
                item(.calendar, "Calendar", count: nil)
            }
            Section("Browse") {
                item(.all, "All Tasks", count: open.count)
                item(.assigned, "Assigned to Me", count: workspace.assignedTasks.filter { TaskKind.mayComplete($0) && !$0.completed }.count)
                item(.completed, "Completed", count: nil)
                Button { openMentions() } label: { HStack { Label("Mentions", systemImage: "at"); Spacer(); if let count = store.mentionUnreadCount, count > 0 { Text("\(count)").foregroundStyle(.secondary) } } }.accessibilityIdentifier("openMentions")
                Button("Insights",systemImage:"chart.xyaxis.line") { openInsights() }.accessibilityIdentifier("openInsights")
                Button { sharedDraftsPresented = true } label: { HStack { Label("Shared drafts", systemImage: "square.and.arrow.down"); Spacer(); if store.sharedCaptureDraftCount > 0 { Text("\(store.sharedCaptureDraftCount)").monospacedDigit().foregroundStyle(.secondary) } } }.accessibilityIdentifier("openSharedDrafts")
                Button("Templates", systemImage: "square.stack.3d.up") { templatesPresented = true }.accessibilityIdentifier("openTemplates")
                Button("Add Multiple Tasks…", systemImage: "text.badge.plus") { multiLinePresented = true }.accessibilityIdentifier("openMultiLineCapture")
            }
            if !store.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(store.favorites) { favorite in
                        if let scope = TaskScope(preferenceKey: favorite.id) {
                            Group {
                                if store.available(scope) { Label(store.title(for: scope), systemImage: "star.fill").tag(SidebarItem(key: favorite.id)) }
                                else { HStack { Label(store.title(for: scope), systemImage: "exclamationmark.circle").foregroundStyle(.secondary); Spacer(); Button { store.toggleFavorite(scope) } label: { Image(systemName: "star.slash") }.buttonStyle(.borderless).accessibilityLabel("Remove unavailable favorite") } }
                            }.contextMenu { Button("Remove favorite") { store.toggleFavorite(scope) }; orderActions(table: "favorites", id: favorite.id, ids: store.favorites.map(\.id)) }.accessibilityIdentifier("favorite-" + favorite.id)
                        }
                    }.onMove { source, destination in var ids = store.favorites.map(\.id); ids.move(fromOffsets: source, toOffset: destination); workspace.run("Reorder Favorites") { store.reorderFavorites(ids) } }
                }
            }
            Section("Filters") {
                ForEach(store.savedViews) { view in
                    Label(view.name, systemImage: "line.3.horizontal.decrease.circle").tag(SidebarItem.saved(view.id))
                        .contextMenu { Button("Edit Filter…") { filterEditor = view }; Button(store.isFavorite(.saved(view.id)) ? "Remove Favorite" : "Add Favorite") { store.toggleFavorite(.saved(view.id)) }; orderActions(table: "saved_views", id: view.id, ids: store.savedViews.map(\.id)) }.accessibilityIdentifier("filter-" + view.id)
                }.onMove { source, destination in
                    var ids = store.savedViews.map(\.id); ids.move(fromOffsets: source, toOffset: destination)
                    workspace.run("Reorder Filters") { store.reorderOrganization("saved_views", ids: ids) }
                }
                Button("New Filter", systemImage: "plus") { filterEditor = store.newSavedView() }.accessibilityIdentifier("newSavedView")
            }
            Section(isExpanded: $projectsExpanded) {
                ForEach(ProjectOrganization.outline(store.allProjects)) { item in
                    let project = item.project
                    ProjectDropRow(project: project) {
                        Label {
                            HStack {
                                Text(project.name).lineLimit(1)
                                Spacer()
                                count(open.filter { $0.string("project_id") == project.id }.count)
                            }
                        } icon: { Image(systemName: "folder.fill").foregroundStyle(Color.project(project.string("color"))) }
                    }
                    .padding(.leading, CGFloat(item.depth) * 12)
                    .tag(SidebarItem.project(project.id))
                    .contextMenu {
                        Button("Edit Project…") { projectEditor = project }
                        Button(store.isFavorite(.project(project.id)) ? "Remove Favorite" : "Add Favorite") { store.toggleFavorite(.project(project.id)) }
                        orderActions(table: "projects", id: project.id, ids: store.allProjects.map(\.id))
                        Button("Delete Project…", role: .destructive) { projectEditor = project }
                    }
                    .accessibilityLabel(project.name).accessibilityIdentifier("project-" + project.id)
                }
                .onMove { source, destination in
                    var projects = store.projects; projects.move(fromOffsets: source, toOffset: destination)
                    workspace.run("Reorder Projects") { store.reorderOrganization("projects", ids: projects.map(\.id) + store.archivedProjects.map(\.id)) }
                }
                Button { newProject() } label: { Label("New Project", systemImage: "plus").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityIdentifier("newProject")
            Button("Archived Projects", systemImage: "archivebox") { archivePresented = true }.accessibilityIdentifier("openArchivedProjects")
            } header: { Text("Projects") }
            Section(isExpanded: $labelsExpanded) {
                ForEach(store.labels) { label in
                    Label {
                        HStack { Text(label.name).lineLimit(1); Spacer(); count(open.filter { $0["labels"].list.contains(.string(label.id)) || $0["labels"].list.contains(.string(label.name)) }.count) }
                    } icon: { Image(systemName: "tag.fill").foregroundStyle(Color.project(label.string("color"))) }
                    .tag(SidebarItem.label(label.id))
                    .contextMenu { Button("Edit Label…") { labelEditor = label }; Button(store.isFavorite(.label(label.id)) ? "Remove Favorite" : "Add Favorite") { store.toggleFavorite(.label(label.id)) } }
                }
                Button { labelEditor = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": .string(""), "color": .string("#8b5cf6")]) } label: { Label("New Label", systemImage: "plus").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            } header: { Text("Labels") }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { VStack(spacing: 0) { AccountMenu(); SyncFooter() } }
        .sheet(isPresented: $templatesPresented) { TemplateLibraryView() }
        .sheet(isPresented: $sharedDraftsPresented) { SharedDraftsView() }
        .sheet(isPresented: $archivePresented) { ArchivedProjectsView() }
        .sheet(isPresented: $multiLinePresented) { MultiLineCaptureView() }
        .sheet(item: $projectEditor) { NamedEditor(table: "projects", record: $0) }
        .sheet(item: $labelEditor) { NamedEditor(table: "labels", record: $0) }
        .sheet(item: $filterEditor) { SavedViewEditor(record: $0) }
        .onChange(of: workspace.newProjectRequest) { _, _ in newProject() }
        .toolbar { ToolbarItem(placement: .navigation) { EmptyView() } }
        }
    }
    @ViewBuilder private func orderActions(table: String, id: String, ids: [String]) -> some View {
        if let index = ids.firstIndex(of: id) {
            Divider()
            Button("Move Up", systemImage: "arrow.up") { moveOrder(table: table, ids: ids, from: index, by: -1) }
                .disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") { moveOrder(table: table, ids: ids, from: index, by: 1) }
                .disabled(index == ids.count - 1)
        }
    }
    private func moveOrder(table: String, ids: [String], from index: Int, by offset: Int) {
        let destination = index + offset
        guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
        var reordered = ids
        reordered.swapAt(index, destination)
        workspace.run("Reorder") { store.reorderOrganization(table, ids: reordered) }
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
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.taskfold.opacity(targeted ? 0.16 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.taskfold.opacity(targeted ? 0.8 : 0), lineWidth: 1.5))
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
    @State private var reviewing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(store.notice != nil ? .orange : .secondary)
                    .id(symbol).transition(.iconSwap)
                Group {
                    if store.syncing { ShimmerText(text: "Syncing…") }
                    else { Text(status).lineLimit(2).fixedSize(horizontal: false, vertical: true).id(status).transition(.textSwap).accessibilityIdentifier("syncStatus") }
                }
                Spacer(minLength: 0)
                if store.syncConflict != nil { Button("Review") { reviewing = true }.buttonStyle(.link).font(.caption).accessibilityIdentifier("reviewSyncConflict") }
                else if store.canSignInForSync && store.focusSyncConflict == nil { SyncSignInButton().buttonStyle(.link).font(.caption) }
                else if store.notice != nil && store.focusSyncConflict == nil { Button("Retry") { Task { await store.sync() } }.buttonStyle(.link).font(.caption) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .animation(Transitions.Ease.smoothOut, value: symbol)
            .animation(Transitions.Ease.smoothOut, value: status)
            .help(store.notice ?? (store.localMode ? "Tasks are stored only on this Mac." : "Changes sync to your Taskfold account."))
        }
        .background(.bar)
        .sheet(isPresented: $reviewing) { if let conflict = store.syncConflict { ConflictReview(conflict: conflict) } }
    }
    private var presentation: SyncStatus.Presentation {
        SyncStatus.presentation(local: store.localMode, online: store.online, syncing: store.syncing,
                                needsAttention: store.notice != nil || store.canSignInForSync, pending: store.pendingCount, lastSync: store.lastSync)
    }
    private var symbol: String { presentation.symbol }
    private var status: String { presentation.title }
}
