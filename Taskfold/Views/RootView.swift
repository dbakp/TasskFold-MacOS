import SwiftUI
import AppKit
import CoreSpotlight

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var phase
    @State private var pinnedNote: PinnedNoteRequest?
    @State private var pulseRequest: ProjectPulseRequest?
    @State private var mentionsRequest: MentionsRequest?
    @State private var insightsRequest:InsightsRequest?
    @State private var focusRequest: FocusSessionRequest?
    @State private var inboxReview: InboxReviewRequest?
    @Environment(\.openSettings) private var openSettings
    @AppStorage("mac.pendingInvitations") private var pendingInvitations = false
    private var labelsInput: Binding<BulkTaskLabelsRequest?> { Binding(get: { workspace.bulkLabels }, set: { workspace.bulkLabels = $0 }) }
    private var assignmentInput: Binding<BulkTaskAssignmentRequest?> { Binding(get: { workspace.bulkAssignment }, set: { workspace.bulkAssignment = $0 }) }
    private var planningInput: Binding<BulkTaskPlanningRequest?> { Binding(get: { workspace.bulkPlanning }, set: { workspace.bulkPlanning = $0 }) }
    private var planningRequest: Binding<TeamTaskPlanningRequest?> { Binding(get: { workspace.teamTaskPlanning }, set: { workspace.teamTaskPlanning = $0 }) }
    var body: some View {
        @Bindable var store = store
        Group {
            if store.signedIn {
                VStack(spacing: 0) {
                    if store.accessRecoveryPending { AccessRecoveryBanner() }
                    FocusFilterBanner()
                    WorkspaceView()
                }.transition(.opacity)
            }
            else { AuthView().transition(.opacity) }
        }
        .disabled(store.signingOut)
        .overlay {
            if store.signingOut {
                ProgressView("Signing out…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .animation(Motion.respecting(reduceMotion, Motion.layout), value: store.signedIn)
        .onAppear { workspace.reduceMotion = reduceMotion; workspace.undoManager = undoManager; seed() }
        .onChange(of: store.childTaskFieldRecoveryScope) { _, _ in workspace.clearChildCompletion() }
        .onChange(of: store.userID) { _, _ in workspace.clearNavigationMemory(); workspace.section = .today }
        .onChange(of: store.signedIn) { _, signedIn in if !signedIn { workspace.clearNavigationMemory() } }
        .onChange(of: reduceMotion) { _, value in workspace.reduceMotion = value }
        .onChange(of: undoManager) { _, value in workspace.undoManager = value }
        .environment(\.startInboxReview, startInboxReview)
        .environment(\.openPinnedNotes, { pinnedNote = PinnedNoteRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) })
        .environment(\.openFocusSession, { focusRequest = FocusSessionRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) })
        .environment(\.openInsights,{insightsRequest=InsightsRequest(workspace:WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration))})
        .sheet(isPresented: Binding(get: { workspace.mixedGroupReview }, set: { workspace.mixedGroupReview = $0 })) {
            WorkflowShell(title: "Saved task selections") { MixedTaskGroupRecoveryView() }
        }
        .sheet(isPresented: Binding(get: { workspace.childGroupReview }, set: { workspace.childGroupReview = $0 })) {
            WorkflowShell(title: "Saved subtask selections") { ChildTaskGroupRecoveryView() }
        }
        .sheet(isPresented: Binding(get: { workspace.childCompletionReview }, set: { workspace.childCompletionReview = $0 })) {
            WorkflowShell(title: "Saved subtask actions") { ChildTaskCompletionRecoveryView() }
        }
        .sheet(item:$insightsRequest) { InsightsView(request:$0) }
        .environment(\.openMentions, { mentionsRequest = MentionsRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) })
        .sheet(item: $mentionsRequest) { request in MentionsInboxView(request: request) { task in
            guard request.workspace.matches(account: store.userID, generation: store.workspaceGeneration), let current = store.record("tasks", id: task.id), current.string("task_generation") == task.string("task_generation"), current.string("project_id") == task.string("project_id") else { return }
            mentionsRequest = nil; workspace.openExternalTask(current.id)
        } }
        .environment(\.openProjectPulse, { project in pulseRequest = ProjectPulseRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), projectID: project) })
        .sheet(item: $pulseRequest) { request in ProjectPulseView(request: request) { task in
            guard request.workspace.matches(account: store.userID, generation: store.workspaceGeneration),
                  let current = try? store.selectionRecord(task.id), current == task else { return }
            pulseRequest = nil; workspace.openExternalTask(current.id)
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
        .onChange(of: store.workspaceGeneration) { _, _ in
            workspace.clearNavigationMemory(); workspace.section = .today
            inboxReview = nil; pinnedNote = nil; focusRequest = nil; pulseRequest = nil; insightsRequest = nil; mentionsRequest = nil
        }
        .sheet(item: Binding(get: { workspace.teamTaskCreation }, set: { workspace.teamTaskCreation = $0 })) { opening in
            TaskInspectorForm(taskID: opening.task.id, admission: opening.admission)
                .frame(minWidth: 620, idealWidth: 680, minHeight: 620, idealHeight: 760)
        }
        .sheet(item: Binding(get: { workspace.teamTaskMove }, set: { workspace.teamTaskMove = $0 })) { TeamTaskMoveView(request: $0) }
        .sheet(item: Binding(get: { workspace.teamTaskDeletion }, set: { workspace.teamTaskDeletion = $0 })) { TeamTaskDeletionReview(request: $0) }
        .modifier(TeamTaskPlanningSheet(request: planningRequest, input: planningInput, assignment: assignmentInput, labels: labelsInput, completion: Binding(get: { workspace.teamTaskCompletion }, set: { workspace.teamTaskCompletion = $0 })))
        .sheet(item: Binding(get: { workspace.deadlineSelection }, set: { workspace.deadlineSelection = $0 })) { request in
            BulkDeadlineEditor(request: request, records: request.account == store.userID ? request.records : []) { day in
                try workspace.setDeadlines(request, day: day)
            }
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .task(id: "refresh-\(store.signedIn)") {
            guard store.signedIn else { return }
            await store.reschedule()
            await store.sync()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(store.pollInterval)) } catch { return }
                await store.reschedule()
                await store.sync()
            }
        }
        .task(id: "realtime-\(store.signedIn)-\(store.localMode)") {
            guard store.signedIn, !store.localMode else { return }
            #if DEBUG
            if ChildFieldNativeIdentity.mainListTesting { return }
            #endif
            await store.runRealtime()
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
            workspace.openExternalTask(task.id)
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
        .onOpenURL(perform: handleExternalURL)
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let url = store.spotlightURL(for: activity) { handleExternalURL(url) }
        }
        .task(id: "members-\(store.userID)-\(store.lastSync?.timeIntervalSince1970 ?? 0)") { await workspace.loadProjectMembers() }
        #if DEBUG
        .safeAreaInset(edge: .top) { if ProcessInfo.processInfo.arguments.contains("--widget-action-testing") { WidgetActionTestPanel() } }
        #endif
        .modifier(CivilDayRefresh())
        #if DEBUG
        .modifier(CalendarContextFixtureControls())
        #endif
        .modifier(WidgetCapacityRefresh())
        .onChange(of: phase) { _, value in if value == .active { store.reloadFocusFilter(); Task { await store.reschedule(); await store.sync() } } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in Task { await store.reschedule() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in Task { await store.reschedule() } }
    }

    private func handleExternalURL(_ url: URL) {
        guard store.allowsWidgetRecordLink(url) else {
            store.error = "This widget belongs to another workspace or is unavailable. Open a task or list in your current workspace."
            return
        }
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
        if url.scheme == "taskfold", url.host == "add", store.signedIn { workspace.section = .inbox; workspace.quickAddFocusRequest += 1 }
        if url.scheme == "taskfold", url.host == "invitations" {
            pendingInvitations = true; workspace.settingsTab = .invitations; openSettings()
        }
        if url.scheme == "taskfold" && url.host == "task" {
            do { workspace.openExternalTask(try store.widgetLinkedTask(url).id) }
            catch { store.error = error.localizedDescription }
        }
    }

    private func startInboxReview(_ batch: InboxReviewBatch) {
        guard inboxReview == nil else { return }
        inboxReview = store.makeInboxReview(batch: batch)
    }

    /// Debug-only fixtures shared with the UI tests. Release builds ignore these arguments.
    private func seed() {
        #if DEBUG
        if ChildFieldNativeIdentity.mainListTesting { return }
        // Every window shares this workspace; a new window must not reset active routes or data.
        guard !workspace.fixturePrepared else { return }; workspace.fixturePrepared = true
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
        if arguments.contains("--remote-highlight-preview") {
            // Screenshot fixture: tint the first two visible tasks as if another device had just changed them.
            Task { try? await Task.sleep(for: .seconds(1.5)); store.previewRemoteHighlight(Set(store.tasks.prefix(2).map(\.id))) }
        }
        if let value = option("calendar-mode"), let mode = CalendarMode(rawValue: value) { workspace.calendarMode = mode }
        if let value = option("appearance") { NSApp.appearance = NSAppearance(named: value == "dark" ? .darkAqua : .aqua) }
        if let title = option("select-title") {
            Task { try? await Task.sleep(for: .seconds(1)); if let task = store.tasks.first(where: { $0.title == title }) { workspace.selection = [task.id]; workspace.inspectorShown = true } }
        }
        if let path = option("capture") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if arguments.contains("--capture-inspector") {
                    // The split view's inspector column renders blank offscreen, so host the inspector alone.
                    let host = NSHostingView(rootView: TaskInspector().environment(store).environment(workspace).frame(width: 340, height: 860).background(Color(nsColor: .windowBackgroundColor)))
                    let panel = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 340, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSApp.appearance; panel.contentView = host; panel.orderBack(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    if let png = DebugCapture.image(of: host).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                } else if arguments.contains("--capture-momentum") {
                    // Insights hosted alone (a sheet cannot be captured with the window): add --momentum-fixture=streak|vacation.
                    let request = InsightsRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration))
                    let size = NSSize(width: 700, height: 1400)
                    let host = NSHostingView(rootView: InsightsView(request: request).environment(store).environment(workspace).frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
                    let panel = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSApp.appearance; panel.contentView = host; panel.orderBack(nil)
                    try? await Task.sleep(for: .seconds(4))
                    if let png = DebugCapture.image(of: host).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                } else if option("capture-toast") != nil {
                    // The bottom bar hosted alone: --capture-toast=goal shows the daily-goal celebration.
                    // =streak shows a milestone alone, =combined a goal that lands with one, =level a level-up.
                    let kind = option("capture-toast") ?? "goal"
                    let toast = kind == "streak" ? Confirmation(message: MomentumMilestone.streak(7).title, celebration: MomentumMilestone.streak(7).detail)
                        : kind == "level" ? Confirmation(message: MomentumMilestone.level(name: "Focused").title, celebration: MomentumMilestone.level(name: "Focused").detail)
                        : kind == "combined" ? Confirmation(message: "Daily goal reached", celebration: "3 of 3 today · " + MomentumMilestone.streak(7).short)
                        : Confirmation(message: "Daily goal reached", celebration: "5 of 5 today")
                    let host = NSHostingView(rootView: ConfirmationBar(confirmation: toast).environment(store).environment(workspace).frame(width: 640, height: 56).background(Color(nsColor: .windowBackgroundColor)))
                    let panel = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 640, height: 56), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSApp.appearance; panel.contentView = host; panel.orderBack(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    if let png = DebugCapture.image(of: host).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                } else if let state = option("capture-sync-status") {
                    // The sidebar footer hosted alone: --capture-sync-status=synced|syncing|offline|pending.
                    let host = NSHostingView(rootView: SyncFooter(preview: state).environment(store).environment(workspace).frame(width: 260).background(Color(nsColor: .windowBackgroundColor)))
                    let size = NSSize(width: 260, height: ceil(host.fittingSize.height))
                    host.frame = NSRect(origin: .zero, size: size)
                    let panel = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSApp.appearance; panel.contentView = host; panel.orderBack(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    if let png = DebugCapture.image(of: host).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                } else if let spec = option("capture-layout"), spec.hasPrefix("picker:") {
                    // The View Options menu cannot be captured offscreen, so host its Layout control alone for the scope after "picker:".
                    let scope = TaskScope(preferenceKey: String(spec.dropFirst("picker:".count))) ?? .upcoming
                    let host = NSHostingView(rootView: LayoutPickerCaptureCard(layouts: TaskLayout.available(for: scope), selected: workspace.currentLayout).environment(store).environment(workspace).padding(DS.Space.xxl).background(Color(nsColor: .windowBackgroundColor)))
                    host.safeAreaRegions = []
                    let size = NSSize(width: 420, height: ceil(host.fittingSize.height))
                    host.frame = NSRect(origin: .zero, size: size)
                    let panel = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSApp.appearance; panel.contentView = host; panel.orderBack(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    if let png = DebugCapture.image(of: host).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: path.hasPrefix("/") ? URL(fileURLWithPath: path) : FileManager.default.temporaryDirectory.appending(path: path))
                    }
                } else if arguments.contains("--capture-global-quick-add") || arguments.contains("--capture-menu-bar") {
                    // The floating panel and the menu bar window are separate NSWindows, so host their content alone.
                    // --capture-global-quick-add shows the composer (add --global-confirm for the "Added to Inbox" moment);
                    // --capture-menu-bar shows today's list (--menu-bar-text=... pre-fills its Add field).
                    let menuBar = arguments.contains("--capture-menu-bar")
                    let width: CGFloat = menuBar ? 320 : 540
                    let frame: Color = Color(nsColor: .windowBackgroundColor)
                    let content: AnyView = menuBar
                        ? AnyView(MenuBarContent(initialText: option("menu-bar-text") ?? "", staticHint: true))
                        : AnyView(GlobalQuickAddCaptureHost(text: option("quick-add-text") ?? "Call Anna tomorrow at 4pm #Work p1", confirm: arguments.contains("--global-confirm")))
                    let host = NSHostingView(rootView: content.environment(store).environment(workspace)
                        .clipShape(.rect(cornerRadius: DS.Radius.l, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
                        .padding(DS.Space.xxl).background(frame))
                    host.safeAreaRegions = []
                    let size = NSSize(width: width + 2 * DS.Space.xxl, height: ceil(host.fittingSize.height))
                    host.frame = NSRect(origin: .zero, size: size)
                    let panel = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSApp.appearance; panel.contentView = host; panel.orderBack(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    let fitted = NSSize(width: size.width, height: ceil(host.fittingSize.height))
                    if fitted.height != size.height { panel.setContentSize(fitted); host.frame = NSRect(origin: .zero, size: fitted); try? await Task.sleep(for: .seconds(0.5)) }
                    if let png = DebugCapture.image(of: host).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                } else if arguments.contains("--capture-quick-add") {
                    // The sheet cannot be captured with the window, so host the composer alone, pre-filled with --quick-add-text.
                    let sample = option("quick-add-text") ?? "Call Anna tomorrow at 4pm #Work @calls p1 !30m"
                    let host = NSHostingView(rootView: QuickAddCaptureHost(text: sample).environment(store).environment(workspace).frame(width: 540, height: 760, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
                    let panel = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 540, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.appearance = NSApp.appearance; panel.contentView = host; panel.orderBack(nil)
                    try? await Task.sleep(for: .seconds(1.5))
                    if let png = DebugCapture.image(of: host).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                } else if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    window.setContentSize(NSSize(width: 1280, height: 800))
                    window.center(); window.orderBack(nil)
                    window.layoutIfNeeded(); window.displayIfNeeded()
                    try? await Task.sleep(for: .seconds(1.5))
                    // Report capture without screen-recording permission: cache-display the window, then repaint every
                    // visual-effect region (whose backdrop cannot be rendered offscreen) with a solid background and its
                    // own subviews. Sandboxed, so the PNG lands in the container's temporary directory.
                    if let frame = window.contentView?.superview, let png = DebugCapture.image(of: frame).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: path.hasPrefix("/") ? URL(fileURLWithPath: path) : FileManager.default.temporaryDirectory.appending(path: path))
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
        if ConversationFixture.enabled { store.startLocal(); store.seedConversationFixture(); workspace.section = .inbox }
        if arguments.contains("--uitesting") && arguments.contains("--workflow-fixture") { store.startLocal(); store.seedWorkflowFixture(); workspace.section = .inbox }
        // The sandboxed UI runner cannot write this app's protected cache.
        // Seed only inside the reserved synthetic host, never a normal app build.
        if arguments.contains("--uitesting"), arguments.contains("--assignment-tree-fixture"),
           Bundle.main.bundleIdentifier == "com.dbakp.taskfold.mac.workflowteststeameditbridge",
           store.userID == "ui-testing", store.localMode {
            do {
                store.dailyBackupsEnabled = false; store.disableNotifications()
                let origin = "a5110000-0000-4000-8000-000000000002", destination = "a5110000-0000-4000-8000-000000000003"
                var task = Record.task(user: store.userID, project: origin, date: Date())
                task["id"] = .string("a5110000-0000-4000-8000-000000000001"); task["title"] = .string("Project change preservation proof")
                task["assigned_to"] = .string("ui-testing"); task["section_id"] = .null
                let raw = arguments.contains("--assignment-tree-unsupported") ? #"{"future_container":"Keep this unsupported source"}"# : #"[{"id":"a5110000-0000-4000-8000-000000000004","title":"Preserve every detail","assigned_to":"alex","é":9007199254740993,"e\u0301":17,"future":{"keep":"exact"},"subtasks":[{"id":"a5110000-0000-4000-8000-000000000005","title":"Nested proof","assigned_to":"alex","subtasks":null}]},"Legacy text"]"#
                task["subtasks"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(raw.utf8))
                store.snapshot = Snapshot(tables: ["tasks": [task], "projects": [(origin, "Assignment origin"), (destination, "Assignment destination")].map { Record(["id": .string($0.0), "name": .string($0.1), "user_id": .string(store.userID)]) }, "sections": []])
                try store.persist(); workspace.section = .today
            } catch { store.error = error.localizedDescription }
        }
        if arguments.contains("--uitesting") && arguments.contains("--workflow-diagnostics") { try? store.persist() }
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
        if arguments.contains("--uitesting") && arguments.contains("--assignee-pattern-testing") { store.startLocal(); store.startAssigneePatternFixture(); workspace.section = .inbox }
        if arguments.contains("--uitesting") && arguments.contains("--date-phrase-testing") { store.startLocal(); store.startDatePhraseFixture(); workspace.section = .inbox }
        if arguments.contains("--uitesting") && arguments.contains("--clock-window-testing") {
            store.startLocal(); store.startClockWindowFixture(); workspace.section = .inbox
        }
        if arguments.contains("--uitesting") && arguments.contains("--calendar-context-testing") {
            store.startLocal(); store.startCalendarContextFixture(); workspace.section = .saved("live-calendar")
        }
        if arguments.contains("--uitesting") && arguments.contains("--filter-creation-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.filterCreationFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--filter-times-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.filterTimeFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--filter-dates-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.filterDateFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
        }
        if arguments.contains("--uitesting") && arguments.contains("--filter-primitives-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = Snapshot.filterPrimitiveFixture(user: store.userID, unknownSettings: ProcessInfo.processInfo.arguments.contains("--filter-unknown-settings-fixture")); workspace.section = .inbox; try? store.persist()
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
        if arguments.contains("--uitesting") && arguments.contains("--insights-fixture") { store.startLocal();store.seedInsightsFixture();workspace.section = .inbox }
        if arguments.contains("--uitesting") && arguments.contains("--widget-list-fixture") {
            store.startLocal(); store.dailyBackupsEnabled = false; store.disableNotifications()
            store.snapshot = arguments.contains("--widget-ordering-fixture") ? Snapshot.widgetOrderingFixture(user:store.userID) : Snapshot.widgetListFixture(user: store.userID); workspace.section = .inbox; try? store.persist()
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
            store.startLocal(); store.dailyBackupsEnabled = false; store.snapshot = Snapshot()
            var local = Record.task(user: store.userID, date: Date())
            local["id"] = .string("conflict-task"); local["title"] = .string("Review launch copy")
            let legacyEmpty = ProcessInfo.processInfo.arguments.contains("--legacy-null-collection-fixture")
            let before: JSON = legacyEmpty ? .null : .array([.object(["id": .string("a"), "text": .string("Original comment")])])
            local["comments"] = .array([.object(["id": .string("a"), "text": .string("My revised comment")])])
            var remote = local
            remote["comments"] = .array([.object(["id": .string(legacyEmpty ? "remote" : "a"), "text": .string("Shared revised comment")]), .object(["id": .string("b"), "text": .string("Independent teammate comment")])])
            let change = TaskCompletionRevision.capturing(Mutation(table: "tasks", recordID: local.id, method: "PATCH", fields: ["comments": local["comments"]], baseline: ["comments": before]), existing: local)
            let later = TaskCompletionRevision.capturing(Mutation(table: "tasks", recordID: local.id, method: "PATCH", fields: ["duration_minutes": .number(45)], baseline: ["duration_minutes": .null]), existing: local)
            store.snapshot.tables["tasks"] = [local]; store.snapshot.pending = [change, later]; store.snapshot.apply(later)
            store.syncConflict = SyncConflict(mutation: change, remote: remote)
            store.notice = "Changes overlap on the same task. Review this edit to resume sync."
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
            // Plan captures: --plan-fixture adds three tasks held for This Evening and six undated Someday tasks (three older than a month).
            if arguments.contains("--plan-fixture") {
                var added: [Record] = []
                func make(_ title: String, due: Bool, daysOld: Int) -> Record {
                    var task = Record.task(user: store.userID, date: due ? Date() : nil, createdAt: ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -daysOld, to: Date()) ?? Date()))
                    task["title"] = .string(title); return task
                }
                let evening = [make("Cook dinner for the neighbours", due: true, daysOld: 1), make("Evening run along the harbour", due: true, daysOld: 1), make("Read a chapter before bed", due: true, daysOld: 2)]
                let someday = [make("Learn to play the cello", due: false, daysOld: 92), make("Build a bookshelf for the hallway", due: false, daysOld: 61), make("See the northern lights", due: false, daysOld: 47),
                               make("Plan a small herb garden", due: false, daysOld: 9), make("Try a pottery class", due: false, daysOld: 4), make("Write down family recipes", due: false, daysOld: 2)]
                added = evening + someday
                store.snapshot.tables["tasks"] = (store.snapshot.tables["tasks"] ?? []) + added
                let today = Dates.day(Date())
                store.snapshot.tables["view_orders"] = [
                    Record(["id": .string(Planning.eveningKey(today)), "user_id": .string(store.userID), "ids": .array(evening.map { .string($0.id) })]),
                    Record(["id": .string(Planning.somedayKey), "user_id": .string(store.userID), "ids": .array(someday.map { .string($0.id) })])
                ]
            }
            // Debug only: `--focus-filter-fixture` seeds five projects and turns on a Focus filter for three, in memory.
            store.installFocusFilterFixture()
            // Layout captures: --capture-layout=<today|inbox|upcoming|project|label>:<list|board|calendar>, or picker:<scope>.
            if let spec = option("capture-layout") {
                let parts = spec.split(separator: ":").map(String.init)
                let scope: TaskScope
                switch parts.first == "picker" ? (parts.dropFirst().first ?? "upcoming") : (parts.first ?? "today") {
                case "upcoming": scope = .upcoming
                case "inbox": scope = .inbox
                case "project": scope = .project("preview-project")
                case "label": scope = .label("preview-label")
                default: scope = .today
                }
                workspace.section = SidebarItem(key: scope.preferenceKey)
                if parts.count > 1, parts.first != "picker" { store.setViewValue(scope, field: "layout", value: .string(parts[1])) }
            }
            // Momentum captures: --momentum-fixture=streak|vacation|milestone adds a recorded history and goals.
            if let value = MomentumFixture.variant(arguments) { MomentumFixture.apply(to: &store.snapshot, account: store.userID, variant: value) }
            // Empty-state captures: --empty-fixture removes every task; =done leaves only one finished today.
            if let value = option("empty-fixture") ?? (arguments.contains("--empty-fixture") ? "" : nil) {
                store.snapshot.tables["tasks"] = []
                if value == "done" {
                    var task = Record.task(user: "preview", date: Date()); task["title"] = .string("Finished today"); task["completed"] = .bool(true); task["completed_at"] = .string(Dates.timestamp())
                    store.snapshot.tables["tasks"] = [task]
                }
            }
        }
        #endif
    }
}

/// Sidebar ▸ content list ▸ inspector. The inspector is a real trailing column, not a sheet.
struct WorkspaceView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var printCommand = TaskPrintCommand()
    var body: some View {
        @Bindable var workspace = workspace
        // Read during body evaluation so selection invalidates the inspector's
        // presentation. A read only inside Binding.get can leave it stale.
        let inspectorVisible = workspace.inspectorVisible
        let inspectorSelection = workspace.actionSelection
        GeometryReader { window in
            NavigationSplitView(columnVisibility: $columns) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } detail: {
                Group {
                    if workspace.section == .someday { SomedayView() }
                    else if workspace.section == .calendar {
                        // Use the window budget, including space for the expanded sidebar, so
                        // toggling it cannot trigger a second calendar layout mid-transition.
                        CalendarView(showsDayPanel: window.size.width >= (workspace.inspectorVisible ? 1550 : 1240))
                    }
                    else { TaskListView(scope: workspace.scope, preferenceKey: workspace.section.key) }
                }
                .id(workspace.section)
                .inspector(isPresented: Binding(get: { inspectorVisible }, set: { shown in
                    // Automatic hiding for an empty selection is not a user preference change.
                    if !workspace.actionSelection.isEmpty { workspace.inspectorShown = shown }
                })) {
                    TaskInspector()
                        .id(inspectorSelection)
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
        .environment(printCommand)
        .focusedSceneValue(\.taskfoldPrint, printCommand)
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
