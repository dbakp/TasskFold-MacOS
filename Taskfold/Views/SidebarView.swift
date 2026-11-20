import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var projectEditor: Record?
    @State private var labelEditor: Record?
    @State private var filterEditor: Record?
    @AppStorage("mac.sidebar.projectsExpanded") private var projectsExpanded = true
    @AppStorage("mac.sidebar.filtersExpanded") private var filtersExpanded = false
    @AppStorage("mac.sidebar.labelsExpanded") private var labelsExpanded = false
    @AppStorage("mac.sidebar.browseExpanded") private var browseExpanded = false
    private var today: String { Dates.day(Date()) }
    private var somedayListed: Set<String> { Planning.listedSomeday(rows: store.rows(Planning.table), account: store.userID) }
    /// "Assigned to me" belongs to team work: it shows once a project is shared or something is assigned (or while it is open).
    private var showsAssigned: Bool {
        workspace.section == .assigned || !workspace.assignedTasks.isEmpty || (!store.localMode && workspace.projectMembers.values.contains { $0.count > 1 })
    }
    var body: some View {
        let navigationCounts = store.navigationCounts
        let reading = store.productiveReading
        let projectOrder = store.projectOrderRequest
        @Bindable var workspace = workspace
        // The foot sits under the list, not in a safe-area inset over it, so it can never print over the last rows.
        VStack(spacing: 0) {
        List(selection: Binding(get: { Optional(workspace.section) }, set: { if let value = $0 { workspace.section = value } })) {
            Section {
                item(.inbox, "Inbox", count: store.focusScope?.hideOtherBadges == true ? 0 : store.inboxProductiveReading.work.filter { InboxReviewRequest.eligible($0) && !Planning.hides($0, listed: somedayListed) }.count, incomplete: store.inboxProductiveReading.incomplete, dropProject: "")
                item(.today, "Today", count: store.matching(TaskQuery(scope: .today), focus: store.focusScope?.hideOtherBadges ?? true).filter { TaskKind.mayComplete($0) && !$0.completed }.count, incomplete: store.productiveReading.incomplete, dropDay: today)
                item(.upcoming, "Upcoming", count: nil, dropDay: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
                item(.calendar, "Calendar", count: nil)
                item(.someday, "Someday", count: store.focusScope?.hideOtherBadges == true ? nil : store.somedayCount)
                item(.habits, "Habits", count: nil)
                // Mentions is a row only while something is unread; otherwise it lives in the foot's "⋯" menu.
                if let unread = store.mentionUnreadCount, unread > 0 {
                    Button { workspace.toolRequest = .mentions } label: {
                        Label { HStack { Text("Mentions"); Spacer(); count(unread) } } icon: { Image(systemName: "at").foregroundStyle(DS.Palette.textSecondary) }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("openMentionsRow")
                }
            }
            if !store.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(store.favorites) { favorite in
                        if let scope = TaskScope(preferenceKey: favorite.id) {
                            Group {
                                if store.available(scope) { Label { Text(store.title(for: scope)) } icon: { Image(systemName: "star").foregroundStyle(DS.Palette.textSecondary) }.tag(SidebarItem(key: favorite.id)) }
                                else { HStack { Label(store.title(for: scope), systemImage: "exclamationmark.circle").foregroundStyle(.secondary); Spacer(); Button { store.toggleFavorite(scope) } label: { Image(systemName: "star.slash") }.buttonStyle(.plain).accessibilityLabel("Remove unavailable favorite") } }
                            }.contextMenu { Button("Remove Favorite") { store.toggleFavorite(scope) }; orderActions(table: "favorites", id: favorite.id, ids: store.favorites.map(\.id)) }.accessibilityIdentifier("favorite-" + favorite.id)
                        }
                    }.onMove { source, destination in var ids = store.favorites.map(\.id); ids.move(fromOffsets: source, toOffset: destination); workspace.run("Reorder Favorites") { store.reorderFavorites(ids) } }
                }
            }
            Section(isExpanded: $projectsExpanded) {
                ForEach(store.focusScope.map { scope in projectOrder.ordering.visible.filter { scope.allows(project: $0.project.id) } } ?? projectOrder.ordering.visible) { item in
                    let project = item.project
                    ProjectDropRow(project: project) {
                        Label {
                            HStack {
                                Text(project.name).lineLimit(1)
                                Spacer()
                                count(navigationCounts.project(project.id), incomplete: reading.incompleteProjects.contains(project.id.lowercased()))
                            }
                        } icon: { ProjectPebble(hue: DS.Palette.project(project), size: 8) }
                    }
                    .padding(.leading, CGFloat(item.depth) * 12)
                    .tag(SidebarItem.project(project.id))
                    .contextMenu {
                        Button("Edit Project…") { projectEditor = project }
                        Button(store.isFavorite(.project(project.id)) ? "Remove Favorite" : "Add Favorite") { store.toggleFavorite(.project(project.id)) }
                        projectOrderActions(project.id, request: projectOrder)
                        Divider()
                        Button("Delete Project…", role: .destructive) { projectEditor = project }
                    }
                    .accessibilityLabel(project.name).accessibilityIdentifier("project-" + project.id)
                }
                .onMove(perform: store.focusScope != nil ? nil : { source, destination in
                    // Reordering waits for the Focus filter to end, so hidden projects keep their place.
                    workspace.run("Reorder Projects") { store.moveProjectOrder(projectOrder, from: source, to: destination) }
                })
            } header: {
                SidebarSectionHeader(title: "Projects", addLabel: "New project", addIdentifier: "newProject", add: newProject)
                    .contextMenu {
                        Button("New Project…") { newProject() }
                        Button("Archived Projects…") { workspace.toolRequest = .archivedProjects }.accessibilityIdentifier("openArchivedProjects")
                    }
            }
            // Filters and Labels are hidden while empty (File ▸ New Filter… / New Label… adds the first) and start collapsed.
            if !store.savedViews.isEmpty {
                Section(isExpanded: $filtersExpanded) {
                    ForEach(store.savedViews) { view in
                        Label { Text(view.name) } icon: { Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(DS.Palette.textSecondary) }.tag(SidebarItem.saved(view.id))
                            .contextMenu { Button("Edit Filter…") { filterEditor = view }; Button(store.isFavorite(.saved(view.id)) ? "Remove Favorite" : "Add Favorite") { store.toggleFavorite(.saved(view.id)) }; orderActions(table: "saved_views", id: view.id, ids: store.savedViews.map(\.id)) }.accessibilityIdentifier("filter-" + view.id)
                    }.onMove { source, destination in
                        var ids = store.savedViews.map(\.id); ids.move(fromOffsets: source, toOffset: destination)
                        workspace.run("Reorder Filters") { store.reorderOrganization("saved_views", ids: ids) }
                    }
                } header: { SidebarSectionHeader(title: "Filters", addLabel: "New filter", addIdentifier: "newSavedView", add: newFilter) }
            }
            if !store.labels.isEmpty {
                Section(isExpanded: $labelsExpanded) {
                    ForEach(store.labels) { label in
                        Label {
                            HStack { Text(label.name).lineLimit(1); Spacer(); count(navigationCounts.label(label.id), incomplete: reading.incomplete) }
                        } icon: { Image(systemName: "number").foregroundStyle(DS.Palette.textSecondary) }
                        .tag(SidebarItem.label(label.id))
                        .contextMenu { Button("Edit Label…") { labelEditor = label }; Button(store.isFavorite(.label(label.id)) ? "Remove Favorite" : "Add Favorite") { store.toggleFavorite(.label(label.id)) } }
                    }
                } header: { SidebarSectionHeader(title: "Labels", addLabel: "New label", addIdentifier: "newLabel", add: newLabel) }
            }
            Section(isExpanded: $browseExpanded) {
                item(.all, "All tasks", count: navigationCounts.total, incomplete: reading.incomplete)
                if showsAssigned { item(.assigned, "Assigned to me", count: workspace.assignedTasks.filter { TaskKind.mayComplete($0) && !$0.completed }.count) }
                item(.completed, "Completed", count: nil)
            } header: { Text("Browse") }
        }
        .listStyle(.sidebar)
        SyncFooter()
        }
        .sheet(item: $projectEditor) { NamedEditor(table: "projects", record: $0) }
        .sheet(item: $labelEditor) { NamedEditor(table: "labels", record: $0) }
        .sheet(item: $filterEditor) { SavedViewEditor(record: $0) }
        .onChange(of: workspace.newProjectRequest) { _, _ in newProject() }
        .onChange(of: workspace.newLabelRequest) { _, _ in newLabel() }
        .onChange(of: workspace.newFilterRequest) { _, _ in newFilter() }
        // A newly selected Browse destination (⌘5, the Finder) opens its group so the selection is visible.
        .onChange(of: workspace.section) { _, section in if [.all, .assigned, .completed].contains(section) { browseExpanded = true } }
        .toolbar { ToolbarItem(placement: .navigation) { EmptyView() } }
    }
    private func newLabel() {
        labelEditor = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": .string(""), "color": .string("#8b5cf6")])
    }
    private func newFilter() { filterEditor = store.newSavedView(); filtersExpanded = true }
    @ViewBuilder private func projectOrderActions(_ id: String, request: ProjectOrderRequest) -> some View {
        let siblings = request.ordering.siblings(of: id)
        if let index = siblings.firstIndex(of: id) {
            Divider()
            Button("Move Up", systemImage: "arrow.up") { workspace.run("Reorder Projects") { store.shiftProjectOrder(request, id: id, by: -1) } }.disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") { workspace.run("Reorder Projects") { store.shiftProjectOrder(request, id: id, by: 1) } }.disabled(index == siblings.count - 1)
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
    @ViewBuilder private func count(_ value: Int, incomplete: Bool = false) -> some View {
        if value > 0 || incomplete { Text((incomplete ? "≥" : "") + String(value)).font(.callout).monospacedDigit().foregroundStyle(.secondary).id(value).transition(.textSwap).animation(Transitions.Ease.smoothOut, value: value) }
    }
    @ViewBuilder private func item(_ item: SidebarItem, _ title: String, count value: Int?, incomplete: Bool = false, dropDay: String? = nil, dropProject: String? = nil) -> some View {
        // Glyphs are quiet secondary ink; only Today keeps crimson, so the colour still means "today" (owner decision 1).
        let label = Label { HStack { Text(title); Spacer(); if let value { count(value, incomplete: incomplete) } } } icon: {
            Image(systemName: item.symbol).foregroundStyle(item == .today ? Color.brandCrimson : DS.Palette.textSecondary)
        }
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

/// The sidebar foot. Signed in: the account chip and the tools menu, with no sync text; a problem shows as a dot on the
/// chip and is explained in its menu. Local mode: a calm "Not synced" card that leads to the sign-in sheet.
struct SyncFooter: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    /// Screenshot fixture (`--capture-sidebar-foot=local|signed`); nil in the app.
    var preview: String? = nil
    private var isLocal: Bool { preview != nil ? preview == "local" : store.localMode }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isLocal { LocalSignInCard(preview: preview != nil) }
            else {
                Divider()
                HStack(spacing: 8) {
                    if preview == nil { AccountMenu(compact: true) }
                    Spacer(minLength: 0)
                    if preview == nil { SidebarToolsMenu() }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            if preview == nil { TeamAudioRestoreRecoveryButton().buttonStyle(.link).font(.caption).padding(.horizontal, 14).padding(.bottom, 8) }
        }
    }
}

/// Local mode's way back to sign-in (OA-2): "Not synced", where the tasks are, and a Sign In… button.
struct LocalSignInCard: View {
    @Environment(Workspace.self) private var workspace
    var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(DS.Palette.textSecondary)
                Text("Not synced").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if !preview { SidebarToolsMenu() }
            }
            Text("Tasks are saved only on this Mac.").font(.system(size: 11)).foregroundStyle(DS.Palette.textSecondary).padding(.leading, 26)
            HStack {
                Button("Sign In…") { workspace.presentSignIn() }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("sidebarSignIn")
                Spacer()
                Text("⇧⌘L").font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary)
            }.padding(.leading, 26).padding(.top, 4)
        }
        .padding(12)
        .background(DS.Palette.surfaceRaised, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.6), lineWidth: 0.5))
        .padding(.horizontal, 8).padding(.bottom, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("localSignInCard")
    }
}

/// A sidebar section header with a "+" that appears on hover (still reachable by VoiceOver and the keyboard).
struct SidebarSectionHeader: View {
    let title: String
    let addLabel: String
    let addIdentifier: String
    let add: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 0)
            Button(action: add) { Image(systemName: "plus").fontWeight(.medium).frame(width: 20, height: 20).contentShape(.rect) }
                .buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary)
                .opacity(hovering ? 1 : 0)
                .help(addLabel).accessibilityLabel(addLabel).accessibilityIdentifier(addIdentifier)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// The sidebar foot's "⋯": the tools that used to be a sidebar section and toolbar icons. The same items are in the
/// Window menu. A dot marks unread mentions.
struct SidebarToolsMenu: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    var body: some View {
        let unread = store.mentionUnreadCount ?? 0
        Menu {
            if store.localMode {
                Button("Sign In to Sync…", systemImage: "person.crop.circle") { workspace.presentSignIn() }.accessibilityIdentifier("toolsSignIn")
            } else {
                Button(unread > 0 ? "Mentions (\(unread) unread)" : "Mentions", systemImage: "at") { workspace.toolRequest = .mentions }.accessibilityIdentifier("openMentions")
            }
            Button("Weekly review", systemImage: "checklist") { workspace.toolRequest = .weeklyReview }.accessibilityIdentifier("openWeeklyReview")
            Button("Insights", systemImage: "chart.xyaxis.line") { workspace.toolRequest = .insights }.accessibilityIdentifier("openInsights")
            Button("Templates", systemImage: "square.stack.3d.up") { workspace.toolRequest = .templates }.accessibilityIdentifier("openTemplates")
            if !store.localMode {
                Button(store.sharedCaptureDraftCount > 0 ? "Shared drafts (\(store.sharedCaptureDraftCount))" : "Shared drafts", systemImage: "square.and.arrow.down") { workspace.toolRequest = .sharedDrafts }.accessibilityIdentifier("openSharedDrafts")
            }
            Divider()
            Button("Pinned notes", systemImage: "pin") { workspace.toolRequest = .pinnedNotes }.accessibilityIdentifier("openPinnedNotes")
            Button("Project pulse", systemImage: "chart.bar") { workspace.toolRequest = .projectPulse }.accessibilityIdentifier("openProjectPulse")
            Button("Archived projects", systemImage: "archivebox") { workspace.toolRequest = .archivedProjects }
        } label: {
            Image(systemName: "ellipsis").fontWeight(.semibold).frame(width: 24, height: 22).contentShape(.rect)
                .overlay(alignment: .topTrailing) { if unread > 0 { Circle().fill(Color.brandCrimson).frame(width: 6, height: 6).offset(x: 1, y: 1) } }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(DS.Palette.textSecondary).foregroundStyle(DS.Palette.textSecondary)
        .disabled(!store.signedIn)
        .help("Mentions, reviews and other tools")
        .accessibilityLabel(unread > 0 ? "Tools, \(unread) unread mentions" : "Tools")
        .accessibilityIdentifier("sidebarTools")
    }
}
