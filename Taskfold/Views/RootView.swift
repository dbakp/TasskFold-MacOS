import SwiftUI
import AppKit

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var phase
    @State private var pinnedNote: PinnedNoteRequest?
    @State private var pulseRequest: ProjectPulseRequest?
    @State private var focusRequest: FocusSessionRequest?
    @State private var inboxReview: InboxReviewRequest?
    @State private var seeded = false
    @Environment(\.openSettings) private var openSettings
    @AppStorage("mac.pendingInvitations") private var pendingInvitations = false
    var body: some View {
        @Bindable var store = store
        Group {
            if store.signedIn { WorkspaceView().transition(.opacity) }
            else { AuthView().transition(.opacity) }
        }
        .animation(Motion.respecting(reduceMotion, Motion.layout), value: store.signedIn)
        .onAppear { workspace.reduceMotion = reduceMotion; workspace.undoManager = undoManager; seed() }
        .onChange(of: store.userID) { _, _ in workspace.clearNavigationMemory(); workspace.section = .today }
        .onChange(of: store.signedIn) { _, signedIn in if !signedIn { workspace.clearNavigationMemory() } }
        .onChange(of: reduceMotion) { _, value in workspace.reduceMotion = value }
        .onChange(of: undoManager) { _, value in workspace.undoManager = value }
        .environment(\.startInboxReview, startInboxReview)
        .environment(\.openPinnedNotes, { pinnedNote = PinnedNoteRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) })
        .environment(\.openFocusSession, { focusRequest = FocusSessionRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) })
        .environment(\.openProjectPulse, { project in pulseRequest = ProjectPulseRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), projectID: project) })
        .sheet(item: $pulseRequest) { request in ProjectPulseView(request: request) { task in
            guard request.workspace.matches(account: store.userID, generation: store.workspaceGeneration), store.record("tasks", id: task.id) != nil else { return }
            pulseRequest = nil; workspace.openFromFinder(task.id)
        } }
        .sheet(item: $focusRequest) { FocusSessionView(request: $0) }
        .safeAreaInset(edge: .top) {
            if store.focusSyncConflict != nil {
                Button { focusRequest = FocusSessionRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) } label: {
                    Label("Review Focus session", systemImage: "exclamationmark.icloud").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.padding(.horizontal).accessibilityIdentifier("reviewFocusConflict")
            }
        }
        .sheet(item: $pinnedNote) { PinnedNotesView(request: $0) }
        .sheet(item: $inboxReview) { InboxReviewView(request: $0) }
        .onChange(of: store.workspaceGeneration) { _, _ in inboxReview = nil; pinnedNote = nil; focusRequest = nil; pulseRequest = nil }
        .sheet(item: Binding(get: { workspace.deadlineSelection }, set: { workspace.deadlineSelection = $0 })) { request in
            BulkDeadlineEditor(request: request, records: request.account == store.userID ? request.ids.sorted().compactMap { workspace.taskRecord($0) } : []) { day in
                try workspace.setDeadlines(request, day: day)
            }
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .task(id: "refresh-\(store.signedIn)") {
            guard store.signedIn else { return }
            await store.reschedule()
            await store.sync()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await store.reschedule()
                await store.sync()
            }
        }
        .task(id: "realtime-\(store.signedIn)-\(store.localMode)") {
            guard store.signedIn, !store.localMode else { return }
            while !Task.isCancelled {
                do { try await store.backend.watchChanges { await store.sync() } }
                catch { if Task.isCancelled { return } }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: "focus-finished-\(NotificationRoute.shared.focusReceipt?.signature ?? "")-\(store.workspaceGeneration)-\(store.widgetPublicationRevision)") {
            guard let receipt = NotificationRoute.shared.focusReceipt, store.signedIn || store.localMode else { return }
            await Task.yield()
            guard !Task.isCancelled, NotificationRoute.shared.focusReceipt == receipt else { return }
            NotificationRoute.shared.focusReceipt = nil
            guard store.validFocusFinish(receipt) else { return }
            focusRequest = FocusSessionRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration))
        }
        .task(id: "reminder-\(NotificationRoute.shared.taskRequest?.signature ?? "")-\(store.workspaceGeneration)-\(store.taskRevision)") {
            guard let route = NotificationRoute.shared.taskRequest else { return }
            await Task.yield()
            guard !Task.isCancelled, NotificationRoute.shared.taskRequest == route else { return }
            NotificationRoute.shared.taskRequest = nil
            guard let task = store.reminderTask(for: route) else { return }
            workspace.open(task.id)
        }
        .task(id: "invitation-route-\(pendingInvitations)-\(store.signedIn)-\(store.localMode)") {
            guard pendingInvitations else { return }
            workspace.settingsTab = .invitations
            openSettings()
            if store.signedIn && !store.localMode {
                await store.sync()
                await workspace.refreshMemberDirectory(force: Set(store.projects.map(\.id)))
                pendingInvitations = false
            }
        }
        .onOpenURL { url in
            if url.scheme == "taskfold", url.host == "pulse" {
                guard let link = ProjectPulseLink.parse(url), store.focusAvailable, link.account == store.userID else { store.error = "This project widget belongs to another workspace or is unavailable. Open Project pulse in your current workspace."; return }
                pulseRequest = ProjectPulseRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), projectID: link.project)
                return
            }
            if url.scheme == "taskfold", url.host == "focus" {
                guard let link = FocusSessionLink.parse(url), store.focusAvailable, link.account == store.userID else { store.error = "This Focus widget belongs to another workspace or is unavailable. Open Focus session in your current workspace."; return }
                focusRequest = FocusSessionRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration))
                return
            }
            if url.scheme == "taskfold", url.host == "note" || url.host == "notes" {
                guard let note = PinnedNoteLink.parse(url), store.signedIn, note.account == store.userID else { store.error = "This note link belongs to another workspace or is unavailable. Open Pinned notes in your current workspace."; return }
                pinnedNote = PinnedNoteRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), taskID: note.taskID)
                return
            }
            if let review = InboxReviewLink.parse(url) {
                guard store.signedIn, review.account == store.userID else { store.error = "This widget belongs to another workspace. Open Inbox to review your current tasks."; return }
                workspace.section = .inbox; startInboxReview(review.batch)
                return
            }
            if let day = PlannerWidgetRoute.day(url) { workspace.calendarDay = day; workspace.calendarMode = .day; workspace.section = .calendar }
            if url.scheme == "taskfold" && url.host == "view" && !url.lastPathComponent.isEmpty { workspace.section = .saved(url.lastPathComponent) }
            if url.scheme == "taskfold", url.host == "project", store.record("projects", id: url.lastPathComponent) != nil { workspace.section = .project(url.lastPathComponent) }
            if url.scheme == "taskfold", url.host == "label", store.record("labels", id: url.lastPathComponent) != nil { workspace.section = .label(url.lastPathComponent) }
            if url.scheme == "taskfold" && url.host == "today" { workspace.section = .today }
            if url.scheme == "taskfold" && url.host == "inbox" { workspace.section = .inbox }
            if url.scheme == "taskfold" && url.host == "all" { workspace.section = .all }
            if url.scheme == "taskfold" && url.host == "upcoming" { workspace.section = .upcoming }
            if url.scheme == "taskfold" && url.host == "add" { workspace.section = .inbox; workspace.quickAddFocusRequest += 1 }
            if url.scheme == "taskfold", url.host == "invitations" {
                pendingInvitations = true; workspace.settingsTab = .invitations; openSettings()
            }
            if url.scheme == "taskfold" && url.host == "task", store.record("tasks", id: url.lastPathComponent) != nil { workspace.open(url.lastPathComponent) }
        }
        .task(id: "members-\(store.userID)-\(store.lastSync?.timeIntervalSince1970 ?? 0)") { await workspace.loadProjectMembers() }
        #if DEBUG
        .safeAreaInset(edge: .top) { if ProcessInfo.processInfo.arguments.contains("--widget-action-testing") { WidgetActionTestPanel() } }
        #endif
        .modifier(WidgetCapacityRefresh())
        .onChange(of: phase) { _, value in if value == .active { Task { await store.reschedule(); await store.sync() } } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in Task { await store.reschedule() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await store.reschedule() } }
    }

    private func startInboxReview(_ batch: InboxReviewBatch) {
        guard inboxReview == nil else { return }
        inboxReview = store.makeInboxReview(batch: batch)
    }

    /// Debug-only fixtures shared with the UI tests. Release builds ignore these arguments.
    private func seed() {
        guard !seeded else { return }; seeded = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // Debug options use --key=value so AppKit never mistakes a bare value for a document to open.
        func option(_ key: String) -> String? { arguments.first { $0.hasPrefix("--\(key)=") }.map { String($0.dropFirst(key.count + 3)) } }
        if let value = option("section") { workspace.section = SidebarItem(key: value) }
        // Preview launches state the accent explicitly so one capture cannot tint the next.
        if let value = option("accent") { UserDefaults.standard.set(value, forKey: "accent") }
        else if arguments.contains("--preview") { UserDefaults.standard.set("rose", forKey: "accent") }
        if arguments.contains("--preview-account") { workspace.previewsAccount = true }
        if let tab = option("open-settings").flatMap(SettingsTab.init(rawValue:)) {
            workspace.settingsTab = tab
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        if arguments.contains("--preview") { Task { try? await Task.sleep(for: .milliseconds(400)); NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 1380, height: 840)) } }
        if let value = option("calendar-mode"), let mode = CalendarMode(rawValue: value) { workspace.calendarMode = mode }
        if let value = option("appearance") { NSApp.appearance = NSAppearance(named: value == "dark" ? .darkAqua : .aqua) }
        if let title = option("select-title") {
            Task { try? await Task.sleep(for: .seconds(1)); if let task = store.tasks.first(where: { $0.title == title }) { workspace.selection = [task.id] } }
        }
        if let path = option("capture") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    window.setContentSize(NSSize(width: 1280, height: 800))
                    window.center(); window.orderBack(nil)
                    window.layoutIfNeeded(); window.displayIfNeeded()
                    try? await Task.sleep(for: .seconds(1.5))
                    // Report capture without screen-recording permission: cache-display the window, then repaint every
                    // visual-effect region (whose backdrop cannot be rendered offscreen) with a solid background and its
                    // own subviews. Sandboxed, so the PNG lands in the container's temporary directory.
                    if let frame = window.contentView?.superview, let png = DebugCapture.image(of: frame).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }
        if arguments.contains("--uitesting") {
            if !arguments.contains("--invitation-link-fixture") && !arguments.contains("--keep-invitation-route") { pendingInvitations = false }
            store.startLocal()
            workspace.section = .today
            workspace.inspectorShown = true
            if arguments.contains("--day-drag-fixture") {
                store.snapshot = Snapshot()
                for scope in ["today", "inbox", "upcoming", "all"] {
                    UserDefaults.standard.set(false, forKey: "mac.view.\(scope).overdueCollapsed")
                    UserDefaults.standard.set("manual", forKey: "mac.view.\(scope).sortBy")
                }
                store.snapshot.tables["tasks"] = [(-1, "Overdue sample"), (0, "Today first"), (0, "Today last"), (1, "Tomorrow sample")].enumerated().map { index, sample in
                    var task = Record.task(user: store.userID, date: Calendar.current.date(byAdding: .day, value: sample.0, to: Date())!)
                    task["id"] = .string("drag-fixture-\(index)")
                    task["title"] = .string(sample.1)
                    return task
                }
                if arguments.contains("--extra-overdue") {
                    var task = Record.task(user: store.userID, date: Calendar.current.date(byAdding: .day, value: -2, to: Date())!)
                    task["id"] = .string("overdue-extra"); task["title"] = .string("Second overdue")
                    store.snapshot.tables["tasks", default: []].append(task)
                }
                try? store.persist()
            }
        }
        if arguments.contains("--uitesting") && arguments.contains("--quick-entry-fixture") {
            store.startLocal(); store.snapshot = Snapshot.quickEntryFixture(user: store.userID); workspace.section = .inbox
            workspace.projectMembers["qe-work"] = store.rows("project_members:qe-work")
            try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--planner-fixture") {
            store.startLocal(); store.snapshot = Snapshot(); workspace.section = .calendar; workspace.calendarMode = .day
            workspace.calendarDay = Calendar.current.startOfDay(for: Date())
            store.snapshot.tables["tasks"] = [("planner-design", "Design session", "09:00", 60), ("planner-review", "Review layout", "09:30", 30), ("planner-anchor", "Call Alex", "11:00", 0), ("planner-report", "Prepare report", "", 25)].map { id, title, time, estimate in
                var task = Record.task(user: store.userID, date: Date())
                task["id"] = .string(id); task["title"] = .string(title); task["due_time"] = time.isEmpty ? .null : .string(time)
                if estimate > 0 { task["duration_minutes"] = .number(Double(estimate)) }
                task["deadline_date"] = .string(Dates.day(Calendar.current.date(byAdding: .day, value: 2, to: Date())!))
                return task
            }
            try? store.persist()
        }
        if arguments.contains("--hierarchy-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            var root = Record.task(user: store.userID, date: Date())
            root["id"] = .string("hierarchy-root"); root["title"] = .string("Launch project")
            root["subtasks"] = .array([
                .object(["id": .string("child-one"), "title": .string("Prepare release"), "completed": .bool(false), "subtasks": .array([
                    .object(["id": .string("grandchild-one"), "title": .string("Review checklist"), "completed": .bool(false)])
                ])]),
                .object(["id": .string("child-two"), "title": .string("Send announcement"), "completed": .bool(false)])
            ])
            var other = Record.task(user: store.userID, date: Date())
            other["id"] = .string("hierarchy-other"); other["title"] = .string("Another task")
            store.snapshot.tables["tasks"] = [root, other]
            try? store.persist()
        }
        if arguments.contains("--assignment-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            let project = Record(["id": .string("shared-fixture"), "user_id": .string(store.userID), "name": .string("Product launch")])
            var root = Record.task(user: store.userID, project: project.id, date: Date())
            root["id"] = .string("assignment-root"); root["title"] = .string("Coordinate launch"); root["assigned_to"] = .string("morgan")
            root["subtasks"] = .array([.object(["id": .string("assigned-child"), "title": .string("Prepare launch notes"), "completed": .bool(false), "assigned_to": .string(store.userID), "subtasks": .array([
                .object(["id": .string("assigned-grand"), "title": .string("Check final wording"), "completed": .bool(false)])
            ])])])
            var own = Record.task(user: store.userID, date: Date())
            own["id"] = .string("assignment-personal"); own["title"] = .string("Review my priorities"); own["assigned_to"] = .string(store.userID)
            store.snapshot.tables["projects"] = [project]; store.snapshot.tables["tasks"] = [root, own]
            workspace.projectMembers[project.id] = [Record(["user_id": .string(store.userID), "display_name": .string("Me")]), Record(["user_id": .string("morgan"), "display_name": .string("Morgan")])]
            workspace.section = .today
            try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--filter-dates-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.filterDateFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--filter-primitives-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.filterPrimitiveFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--parity-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            UserDefaults.standard.set("roomy", forKey: "mac.taskDensity")
            UserDefaults.standard.set("", forKey: "mac.collapsedProjectSections")
            UserDefaults.standard.set("list", forKey: "mac.view.project:parity-project.layout")
            UserDefaults.standard.set("manual", forKey: "mac.view.project:parity-project.sortBy")
            UserDefaults.standard.set(false, forKey: "mac.view.project:parity-project.showCompleted")
            let project = Record(["id": .string("parity-project"), "user_id": .string(store.userID), "name": .string("Release workshop")])
            store.snapshot.tables["projects"] = [project]
            store.snapshot.tables["sections"] = [Record(["id": .string("planning"), "project_id": .string(project.id), "name": .string("Planning")]), Record(["id": .string("ready"), "project_id": .string(project.id), "name": .string("Ready")])]
            store.snapshot.tables["tasks"] = (0..<45).map { i in
                var task = Record.task(user: store.userID, project: project.id)
                task["id"] = .string("parity-\(i)"); task["title"] = .string(i == 0 ? "Review the release with the whole team" : "Workshop task \(i)")
                task["section_id"] = .string("planning")
                if i == 0 { task["description"] = .string("Keep the title aligned while notes grow below it."); task["assigned_to"] = .string("morgan") }
                return task
            }
            workspace.rosterAccount = store.userID
            workspace.projectMembers[project.id] = [Record(["user_id": .string(store.userID), "display_name": .string("Local Workspace")]), Record(["user_id": .string("morgan"), "display_name": .string("Morgan Lee"), "avatar_url": .string("https://www.gravatar.com/avatar/00000000000000000000000000000000?d=identicon&s=64")])]
            workspace.persistMemberCache()
            workspace.section = .project(project.id)
            try? store.persist()
        }
        if arguments.contains("--invitation-link-fixture") { pendingInvitations = true }
        if arguments.contains("--uitesting") && arguments.contains("--widget-list-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.widgetListFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--deadline-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.deadlineFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--reminder-route-testing") {
            store.startLocal(); store.seedReminderRouteFixture(); workspace.section = .today; workspace.inspectorShown = false
        }
        if arguments.contains("--uitesting") && arguments.contains("--reminder-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            var task = Record.task(user: store.userID, date: Date())
            task["id"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"); task["title"] = .string("Reminder review")
            task["due_time"] = .string("23:55"); task["reminder_specs"] = .array([])
            store.snapshot = Snapshot(); store.snapshot.tables["tasks"] = [task]; workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--conflict-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            var local = Record.task(user: store.userID, date: Date())
            local["id"] = .string("conflict-task"); local["title"] = .string("Review launch copy")
            let before: JSON = .array([.object(["id": .string("a"), "text": .string("Original comment")])])
            local["comments"] = .array([.object(["id": .string("a"), "text": .string("My revised comment")])])
            var remote = local
            remote["comments"] = .array([.object(["id": .string("a"), "text": .string("Shared revised comment")]), .object(["id": .string("b"), "text": .string("Independent teammate comment")])])
            let change = Mutation(table: "tasks", recordID: local.id, method: "PATCH", fields: ["comments": local["comments"]], baseline: ["comments": before])
            store.snapshot.tables["tasks"] = [local]; store.snapshot.pending = [change]
            store.syncConflict = SyncConflict(mutation: change, remote: remote)
            workspace.section = .today
            try? store.persist()
        }
                if ProcessInfo.processInfo.arguments.contains("--deletion-conflict-fixture") {
                    store.startLocal(); store.dailyBackupsEnabled = false
                    var before = Record.task(user: store.userID, date: Date())
                    before["id"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"); before["title"] = .string("Next occurrence")
                    var remote = before; remote["title"] = .string("Updated next occurrence")
                    remote["duration_minutes"] = .number(25)
                    remote["comments"] = .array([.object(["id": .string("c"), "text": .string("New work from another device")])])
                    let deletion = Mutation(table: "tasks", recordID: before.id, method: "DELETE", fields: [:], baseline: before.fields)
                    store.snapshot = Snapshot(tables: ["tasks": []], pending: [deletion])
                    store.syncConflict = SyncConflict(mutation: deletion, remote: remote)
                    try? store.persist()
                    workspace.section = .today
                }
        if arguments.contains("--pinned-notes-seed") { store.startLocal(); store.seedPinnedNotesFixture(); workspace.section = .inbox; workspace.inspectorShown = false }
        if arguments.contains("--project-pulse-seed") { store.startLocal(); store.seedProjectPulseFixture(); workspace.section = .inbox; workspace.inspectorShown = false }
        if arguments.contains("--focus-session-seed") {
            store.startLocal(); store.seedFocusSessionFixture(); workspace.section = .inbox; workspace.inspectorShown = false
        }
        if arguments.contains("--inbox-review-seed") { store.startLocal(); store.seedInboxReviewFixture(); workspace.section = .inbox; workspace.inspectorShown = false }
        if arguments.contains("--capacity-widget-seed") { store.startLocal(); store.seedCapacityWidgetFixture(); workspace.section = .today }
        if arguments.contains("--completion-cycle-fixture") { store.startLocal(); store.seedCompletionCycleFixture(); workspace.section = .today }
        if arguments.contains("--widget-action-seed") { store.startLocal(); store.seedWidgetActionFixture(); workspace.section = .today }
        if arguments.contains("--sticky-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            store.snapshot.tables["tasks"] = (0..<100).map { index in
                let offset = index < 60 ? 0 : 1
                var task = Record.task(user: store.userID, date: Calendar.current.date(byAdding: .day, value: offset, to: Date()))
                task["id"] = .string("sticky-\(index)"); task["title"] = .string(String(format: "Date scrolling task %03d", index)); return task
            }
            workspace.section = .upcoming
            try? store.persist()
        }
        if arguments.contains("--link-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            var linked = Record.task(user: store.userID, date: Date())
            linked["id"] = .string("link-0"); linked["title"] = .string("Read https://example.com/guides/focus before Friday")
            var plain = Record.task(user: store.userID, date: Date())
            plain["id"] = .string("link-1"); plain["title"] = .string("A plain task")
            store.snapshot.tables["tasks"] = [linked, plain]
            try? store.persist()
        }
        if arguments.contains("--priority-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            UserDefaults.standard.set("manual", forKey: "mac.view.today.sortBy")
            store.snapshot.tables["tasks"] = [("P1 alpha", 1), ("P1 beta", 1), ("P3 gamma", 3), ("P3 delta", 3)].enumerated().map { index, sample in
                var task = Record.task(user: store.userID, date: Date())
                task["id"] = .string("band-\(index)"); task["title"] = .string(sample.0); task["priority"] = .number(Double(sample.1))
                return task
            }
            try? store.persist()
        }
        if arguments.contains("--navigation-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            for scope in ["today", "inbox", "all", "completed"] {
                UserDefaults.standard.set(false, forKey: "mac.view.\(scope).showCompleted")
                UserDefaults.standard.set(0, forKey: "mac.view.\(scope).priorityFilter")
                UserDefaults.standard.set("title", forKey: "mac.view.\(scope).sortBy")
            }
            store.snapshot.tables["projects"] = [Record(["id": .string("nav-project"), "name": .string("Navigation Studio"), "user_id": .string(store.userID)])]
            store.snapshot.tables["tasks"] = (0..<160).map { index in
                var task = Record.task(user: store.userID, date: Date())
                task["id"] = .string("nav-\(index)")
                task["title"] = .string(String(format: "Navigation task %03d", index))
                task["priority"] = .number(index % 2 == 0 ? 1 : 4)
                return task
            }
            var archived = Record.task(user: store.userID, project: "nav-project", date: Date())
            archived["id"] = .string("nav-archived")
            archived["title"] = .string("Archived navigation target")
            archived["completed"] = .bool(true)
            store.snapshot.tables["tasks", default: []].append(archived)
            try? store.persist()
        }
        if arguments.contains("--preview") {
            store.startLocal(); store.snapshot = Snapshot()
            let focus = Record(["id": .string("preview-project"), "name": .string("A little more focus"), "user_id": .string("preview"), "color": .string("#e31e4b"), "order_index": .number(0)])
            let home = Record(["id": .string("preview-home"), "name": .string("Home"), "user_id": .string("preview"), "color": .string("#3b82f6"), "order_index": .number(1)])
            store.snapshot.tables["projects"] = [focus, home]
            store.snapshot.tables["labels"] = [Record(["id": .string("preview-label"), "user_id": .string("preview"), "name": .string("deep work"), "color": .string("#8b5cf6")])]
            var samples: [Record] = []
            let calendar = Calendar.current
            let plan: [(Int, String, Int, String, String)] = [
                (-1, "Send the revised proposal", 1, focus.id, ""),
                (0, "Make time for the big idea", 1, focus.id, "10:00"),
                (0, "Sketch the next chapter", 2, focus.id, ""),
                (0, "A walk, without the phone", 3, "", ""),
                (0, "Plan something worth looking forward to", 4, home.id, ""),
                (1, "Review the onboarding flow", 2, focus.id, "14:00"),
                (1, "Book the dentist", 4, home.id, ""),
                (2, "Write the release notes", 2, focus.id, ""),
                (3, "Water the plants", 4, home.id, ""),
                (4, "Quarterly reflection", 3, focus.id, "09:00"),
                (6, "Call Grandma", 2, home.id, ""),
                (9, "Draft the talk outline", 2, focus.id, ""),
            ]
            for (i, entry) in plan.enumerated() {
                var task = Record.task(user: "preview", project: entry.3, date: calendar.date(byAdding: .day, value: entry.0, to: Date()))
                task["title"] = .string(entry.1); task["priority"] = .number(Double(entry.2))
                if !entry.4.isEmpty { task["due_time"] = .string(entry.4) }
                if i == 1 { task["description"] = .string("An hour of focus. A little room to think."); task["labels"] = .array([.string("deep work")]); task["subtasks"] = .array([.object(["id": .string("s1"), "title": .string("Clear the desk"), "completed": .bool(true)]), .object(["id": .string("s2"), "title": .string("Open the notebook"), "completed": .bool(false)])]) }
                if i == 8 { task["is_recurring"] = .bool(true); task["recurrence_pattern"] = .object(["type": .string("weekly"), "interval": .number(1), "daysOfWeek": .array([.number(6)])]) }
                samples.append(task)
            }
            var inbox = Record.task(user: "preview"); inbox["title"] = .string("Read that article about slow productivity"); samples.append(inbox)
            store.snapshot.tables["tasks"] = samples
        }
        #endif
    }
}

/// Sidebar ▸ content list ▸ inspector. The inspector is a real trailing column, not a sheet.
struct WorkspaceView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var columns = NavigationSplitViewVisibility.all
    var body: some View {
        @Bindable var workspace = workspace
        GeometryReader { window in
            NavigationSplitView(columnVisibility: $columns) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } detail: {
                Group {
                    if workspace.section == .calendar {
                        // Use the window budget, including space for the expanded sidebar, so
                        // toggling it cannot trigger a second calendar layout mid-transition.
                        CalendarView(showsDayPanel: window.size.width >= (workspace.inspectorVisible ? 1550 : 1240))
                    }
                    else { TaskListView(scope: workspace.scope, preferenceKey: workspace.section.key) }
                }
                .id(workspace.section)
                .inspector(isPresented: Binding(get: { workspace.inspectorVisible }, set: { shown in
                    // Automatic hiding for an empty selection is not a user preference change.
                    if !workspace.actionSelection.isEmpty { workspace.inspectorShown = shown }
                })) {
                    TaskInspector()
                        .inspectorColumnWidth(min: 270, ideal: 310, max: 460)
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .navigationTitle(workspace.navigationTitle)
            .navigationSubtitle(workspace.navigationSubtitle)
        }
        .sheet(isPresented: $workspace.finderPresented, onDismiss: { workspace.finishFinderDismissal() }) { FinderView() }
        .sheet(item: $workspace.planning) { kind in PlanDayView(kind: kind, queue: workspace.planQueue(kind)) }
        .sheet(isPresented: $workspace.onboarding) { OnboardingView() }
        .onAppear {
            // First launch shows the tour once; fixtures opt in with --onboarding so tests stay deterministic.
            let arguments = ProcessInfo.processInfo.arguments
            let fixture = arguments.contains("--uitesting") || arguments.contains("--preview")
            if arguments.contains("--onboarding") || (!fixture && !UserDefaults.standard.bool(forKey: "onboardingSeen")) {
                Task { try? await Task.sleep(for: .milliseconds(600)); workspace.onboarding = true }
            }
        }
        .modifier(KeyRouter())
        .accessibilityIdentifier("nativeWorkspace")
    }
}

#if DEBUG
enum DebugCapture {
    /// Cache-displays the window frame, then repaints each visual-effect region with a solid background and
    /// its own subviews, because material backdrops cannot be rendered offscreen.
    @MainActor static func image(of root: NSView) -> NSImage {
        let image = NSImage(size: root.bounds.size)
        guard let layer = root.layer else { return image }
        // Material backdrop layers sample what is behind the window, which does not exist offscreen and renders as
        // noise; hide them and render the Core Animation tree, which includes vibrant content that view caching skips.
        for effect in allEffects(under: root) { effect.material = .windowBackground; effect.state = .inactive; effect.blendingMode = .withinWindow }
        hideBackdrops(layer)
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        let scale = root.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width * scale), pixelsHigh: Int(root.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = root.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill(); root.bounds.fill()
        layer.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }
    private static func allEffects(under view: NSView) -> [NSVisualEffectView] {
        view.subviews.flatMap { (($0 as? NSVisualEffectView).map { [$0] } ?? []) + allEffects(under: $0) }
    }
    private static func hideBackdrops(_ layer: CALayer) {
        if String(describing: type(of: layer)).contains("Backdrop") { layer.isHidden = true }
        layer.sublayers?.forEach(hideBackdrops)
    }
    /// Rect of `view` in the (unflipped) bitmap coordinate space of `root`.
    private static func rect(of view: NSView, in root: NSView) -> NSRect {
        var r = root.convert(view.bounds, from: view)
        if root.isFlipped { r.origin.y = root.bounds.height - r.origin.y - r.height }
        return r
    }
    @MainActor private static func paint(_ view: NSView, root: NSView) {
        guard !view.isHidden, view.alphaValue > 0 else { return }
        let target = rect(of: view, in: root)
        if view is NSVisualEffectView {
            NSColor.windowBackgroundColor.setFill(); target.fill()
            for sub in view.subviews { paint(sub, root: root) }
            return
        }
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        for effect in topEffects(under: view) { paint(effect, root: root) }
    }
    private static func topEffects(under view: NSView) -> [NSView] {
        view.subviews.flatMap { $0 is NSVisualEffectView ? [$0] : topEffects(under: $0) }
    }
}
#endif
