import SwiftUI
import Security
import Network
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor @Observable
final class Store {
    /// One store per process so notification actions and App Intents share the app's data.
    static let shared = Store()
    #if DEBUG
    private(set) var teamRecoveryRaceStatus = "Ready"
    private(set) var recordedDraftAdmissionStatus = "Ready"
    #endif
    #if DEBUG
    @ObservationIgnored private var workflowFixtureFailureConsumed = false
    @ObservationIgnored private var sharedCaptureFixtureFailureConsumed = false
    #endif
    private(set) var workspaceReadRevision = UUID()
    var workspaceAccessToken: String? { (activeTeamMask ?? snapshot.teamWorkspace)?.boundary.raw["token"]?.text }
    var nativeConversationTeamCache: TeamWorkspaceCache? { activeTeamMask ?? snapshot.teamWorkspace }
    var snapshot = Snapshot() {
        didSet {
            if oldValue.teamWorkspace?.boundary != snapshot.teamWorkspace?.boundary || oldValue.tables["projects"] != snapshot.tables["projects"] || oldValue.tables["project_collaborators"] != snapshot.tables["project_collaborators"] { workspaceReadRevision = UUID() }
            if taskCache.update(presentedTables["tasks"] ?? []) { taskRevision += 1 }
        }
    }
    private var teamAccessMask:TeamWorkspaceCache? {
        didSet {
            if oldValue?.boundary != teamAccessMask?.boundary {workspaceReadRevision = UUID()}
            if taskCache.update(presentedTables["tasks"] ?? []) {taskRevision+=1}
            publishWidgetSnapshot(scheduleCapacityRefresh:false)
            Task {await reschedule()}
        }
    }
    private var activeTeamMask:TeamWorkspaceCache? {
        guard let teamAccessMask,teamAccessMask.boundary.account==userID,teamAccessMask.boundary.origin==(try? backend.accountRemovalOrigin) else {return nil}
        return teamAccessMask
    }
    private var teamAccessFenceDisk:TeamAccessFenceDisk? {
        guard !localMode,TeamProjectValue.id(userID),let origin=try? backend.accountRemovalOrigin else {return nil}
        return TeamAccessFenceDisk(disk:AccountRemovalDisk(directory:cacheURL.deletingLastPathComponent(),account:userID),origin:origin)
    }
    private var presentedTables:[String:[Record]] {workspaceCacheReadable ? (activeTeamMask?.presentation(snapshot) ?? snapshot.tables):[:]}
    var presentationSnapshot:Snapshot {var visible=snapshot;visible.tables=presentedTables;return visible}
    @ObservationIgnored private let taskCache = TaskCache()
    private(set) var taskRevision = 0
    private(set) var calendarContext = TaskCalendarContext()
    /// Read synchronously on scene activation and clock notifications, before network work.
    @discardableResult func refreshCalendarContext() -> Bool {
        let next = TaskCalendarContext(now: calendarNow, timeZone: calendarTimeZone)
        guard next != calendarContext else { return false }
        let dayOrZoneChanged = next.today != calendarContext.today || next.timeZone != calendarContext.timeZone
        calendarContext = next
        let clockViews = savedViews.contains { (try? FilterRule(document: $0["query_ast"]))?.usesClockWindow == true }
        if dayOrZoneChanged || clockViews { publishWidgetSnapshot(scheduleCapacityRefresh: false) }
        return true
    }
    var calendarRefreshDelay: TimeInterval { TaskCalendarContext.refreshDelay(after: calendarNow, timeZone: calendarTimeZone) }
    private var calendarNow: Date {
        #if DEBUG
        if calendarContextFixtureEnabled || clockWindowFixtureEnabled, let calendarFixtureInstant { return calendarFixtureInstant }
        #endif
        return Date()
    }
    private var calendarTimeZone: TimeZone {
        #if DEBUG
        if calendarContextFixtureEnabled || clockWindowFixtureEnabled, let calendarFixtureZone { return calendarFixtureZone }
        #endif
        return .autoupdatingCurrent
    }
    #if DEBUG
    @ObservationIgnored private var calendarFixtureInstant: Date?
    @ObservationIgnored private var calendarFixtureZone: TimeZone?
    @ObservationIgnored private var calendarFixtureBaseline: Snapshot?
    var calendarContextFixtureEnabled: Bool {
        userID == "ui-testing" && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--calendar-context-testing")
    }
    var assigneePatternFixtureEnabled: Bool {
        userID == "ui-testing" && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--assignee-pattern-testing")
    }
    func startAssigneePatternFixture() {
        guard assigneePatternFixtureEnabled else { return }
        dailyBackupsEnabled = false; disableNotifications()
        if ProcessInfo.processInfo.arguments.contains("--assignee-pattern-fixture") {
            snapshot = Snapshot(); undoStack = []; redoStack = []
            let project = "assignee-pattern-project"
            snapshot.tables["projects"] = [Record(["id": .string(project), "name": .string("Studio"), "user_id": .string(userID)])]
            snapshot.tables["project_collaborators"] = [("22222222-2222-4222-8222-222222222222", "Mary Smith"), ("33333333-3333-4333-8333-333333333333", "Marc Smith"), ("44444444-4444-4444-8444-444444444444", "Jane Smith")].map { id, name in
                Record(["id": .string("member-" + id), "user_id": .string(id), "project_id": .string(project), "display_name": .string(name), "status": .string("accepted")])
            }
            snapshot.tables["tasks"] = [("Mary task", "22222222-2222-4222-8222-222222222222"), ("Marc task", "33333333-3333-4333-8333-333333333333"), ("Jane task", "44444444-4444-4444-8444-444444444444")].map { title, person in
                var task = Record.task(user: userID, project: project); task["title"] = .string(title); task["assigned_to"] = .string(person); return task
            }
            do { try persist() } catch { self.error = error.localizedDescription }
        }
    }
    var datePhraseFixtureEnabled: Bool {
        userID == "ui-testing" && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--date-phrase-testing")
    }
    func startDatePhraseFixture() {
        guard datePhraseFixtureEnabled else { return }
        dailyBackupsEnabled = false; disableNotifications()
        if ProcessInfo.processInfo.arguments.contains("--date-phrase-fixture") {
            snapshot = Snapshot()
            snapshot.tables["saved_views"] = [("date-pref-week", "Next week choices", "next week"), ("date-pref-weekend", "Weekend choices", "this weekend")].map { id, name, phrase in
                Record(["id": .string(id), "user_id": .string(userID), "name": .string(name), "query_ast": FilterRule.predicate("planned_on", ProcessInfo.processInfo.arguments.contains("--compound-date-testing") ? "1 week after " + phrase : phrase).document, "layout": .string("list"), "sort_by": .string("title")])
            }
            do { try persist() } catch { self.error = error.localizedDescription }
        }
    }
    var clockWindowFixtureEnabled: Bool {
        userID == "ui-testing" && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--clock-window-testing")
    }
    func startClockWindowFixture() {
        guard clockWindowFixtureEnabled else { return }
        dailyBackupsEnabled = false; disableNotifications()
        if ProcessInfo.processInfo.arguments.contains("--clock-window-fixture") {
            snapshot = Snapshot.filterClockWindowFixture(user: userID); undoStack = []; redoStack = []
            do { try persist() } catch { self.error = error.localizedDescription }
        }
        calendarFixtureBaseline = snapshot
        setClockWindowFixtureClock(ProcessInfo.processInfo.arguments.contains("--clock-window-shifted") ? 1 : 0)
        refreshCalendarContext()
    }
    func setClockWindowFixtureClock(_ stage: Int) {
        guard clockWindowFixtureEnabled, (0...1).contains(stage) else { return }
        calendarFixtureInstant = ISO8601DateFormatter().date(from: stage == 0 ? "2026-10-08T10:00:59Z" : "2026-10-08T10:01:00Z")
        calendarFixtureZone = TimeZone(secondsFromGMT: 0)
    }
    var clockWindowFixtureDataStatus: String {
        calendarFixtureBaseline?.tables["tasks"] == snapshot.tables["tasks"] && !snapshot.pending.contains(where: { $0.table == "tasks" }) ? "Task plans unchanged" : "Task plans changed"
    }
    func startCalendarContextFixture() {
        guard calendarContextFixtureEnabled else { return }
        dailyBackupsEnabled = false; disableNotifications()
        snapshot = Snapshot.calendarContextFixture(user: userID); undoStack = []; redoStack = []
        setCalendarFixtureClock(0)
        do { try persist(); calendarFixtureBaseline = snapshot } catch { self.error = error.localizedDescription }
        refreshCalendarContext()
    }
    /// Clock injection changes only the reader. Notifications/activation perform the refresh.
    func setCalendarFixtureClock(_ stage: Int) {
        guard calendarContextFixtureEnabled, (0...3).contains(stage) else { return }
        calendarFixtureInstant = ISO8601DateFormatter().date(from: ["2026-03-28T22:59:59Z", "2026-03-28T23:00:00Z", "2026-03-28T23:00:00Z", "2026-03-29T10:00:00Z"][stage])
        calendarFixtureZone = TimeZone(identifier: stage < 2 ? "Europe/Copenhagen" : "Pacific/Honolulu")
    }
    var calendarFixtureDataStatus: String {
        calendarFixtureBaseline == snapshot && undoStack.isEmpty && redoStack.isEmpty ? "Workspace unchanged" : "Workspace changed"
    }
    #endif
    @ObservationIgnored private let reminderScheduler = ReminderScheduler()
    @ObservationIgnored private var reminderRevision = 0
    @ObservationIgnored private var reminderRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var reminderRefreshRequest = 0
    private var reminderPreferenceRevision = 0
    @ObservationIgnored private var reminderDeviceLifecycle: ReminderDeviceLifecycle?
    @ObservationIgnored private lazy var reminderAppIdentity = ReminderAppIdentity.signed()
    var remoteReminderStatus = "Remote reminders are not available yet."
    var remoteReminderBusy = false
    private var reminderAuthority: ReminderDeliveryAuthority?
    private var reminderAuthorityRead = false
    private var reminderAuthorityUnreadable = false
    var remoteReminderAvailable = false
    @ObservationIgnored private var reminderAvailability: (account: String, session: UUID, value: Bool, checked: Date)?
    var remoteReminderSelected: Bool { reminderAuthority?.account == reminderAuthorityAccount && reminderAuthority?.wantsRemote == true }
    var remoteReminderNeedsConfirmation: Bool { remoteReminderHoldingOriginals }
    private var remoteReminderHoldingOriginals: Bool { reminderAuthorityUnreadable || reminderAuthority?.account == reminderAuthorityAccount && reminderAuthority?.phase != .local }
    private var systemTimeSensitiveAllowed = false
    var timeSensitiveReminderStatus = "System notification settings control Time Sensitive delivery."
    var reminderStatus = "Choose whether this device delivers reminders."
    var focusAlertStatus = "Finish alerts are off on this device."
    private var focusPermissionDenied = false
    var requestingFocusAlerts = false
    var requestingNotifications = false
    var signedIn = false
    var localMode = false
    var syncing = false
    var online = true
    @ObservationIgnored private var teamCompletionErrorRevision = UUID()
    @ObservationIgnored private var teamCompletionReviewFailure: TeamCompletionReviewFailure?
    var error: String? {
        didSet { teamCompletionErrorRevision = UUID(); teamCompletionReviewFailure = nil }
    }
    var notice: String?
    /// A confirmed Auth refusal is scoped to this workspace, never inferred from text.
    private(set) var syncSignInWorkspace: WorkspaceBinding?
    private var syncAfterSignInRequested: WorkspaceBinding?
    var canSignInForSync: Bool {
        syncSignInWorkspace?.matches(account:userID,generation:workspaceGeneration) == true &&
        signedIn && !localMode && !signingOut && !accountRemovalBlocked
    }
    func syncSignInContext() throws -> AccountReauthentication {
        guard canSignInForSync else { throw CancellationError() }
        return try backend.reauthenticationContext(account:userID)
    }
    func resumeSyncAfterSignIn(workspace: WorkspaceBinding) async {
        guard workspace.matches(account:userID,generation:workspaceGeneration), signedIn,
              !localMode, !signingOut, !accountRemovalBlocked else { return }
        syncSignInWorkspace = nil
        if syncing { syncAfterSignInRequested = workspace; return }
        await sync()
    }
    var accessRecoveryPending = false
    private var accessRecoveryNoticeKey: String { "taskfold.accessRecoveryPending." + userID.lowercased() }
    func acknowledgeAccessRecovery() {
        UserDefaults.standard.removeObject(forKey: accessRecoveryNoticeKey)
        accessRecoveryPending = false
    }
    private func markAccessRecovery() {
        UserDefaults.standard.set(true, forKey: accessRecoveryNoticeKey)
        accessRecoveryPending = true
    }
    var sharedCaptureDraftCount = 0
    var widgetActionStatus: String?
    var syncConflict: SyncConflict?
    var focusSyncConflict: FocusSyncConflict?
    var lastSync: Date?
    var undoStack: [EditHistory] = []
    var redoStack: [EditHistory] = []
    let backend: Backend
    var conversationSyncID: UUID?
    var conversationSyncGeneration: UUID?
    var conversationError: String?
    var conversationPageTokens: [String: UUID] = [:]
    #if DEBUG
    var conversationFixtureRevision = 0
    var conversationFixtureHolding = false
    var conversationFixtureWaiting = false
    var conversationFixtureRelease: CheckedContinuation<Void,Never>?
    func changeConversationAccessFixture(readable: Bool) {
        guard ConversationFixture.enabled, ProcessInfo.processInfo.arguments.contains("--conversation-access-testing"), let origin=try? backend.accountRemovalOrigin else {return}
        do {
            var raw:[String:JSON] = ["workspace_boundary_protocol":.number(1),"account":.string(userID),"native_team_reads_enabled":.bool(false),"setup_paused":.bool(false),"teams":.array([]),"projects":.array([]),"token":.string(String(repeating:"b",count:64))]
            if readable {
                let team="f1799000-0000-4000-8000-000000000099"
                raw["native_team_reads_enabled"] = .bool(true);raw["token"] = .string(String(repeating:"a",count:64))
                raw["teams"] = .array([.object(["id":.string(team),"state":.string("active"),"revision":.number(1),"access_revision":.number(1)])])
                raw["projects"] = .array([.object(["id":.string(ConversationFixture.project),"team_id":.string(team),"role":.string("viewer"),"archived":.bool(false),"can_send_tasks":.bool(false)])])
            }
            let boundary=try TeamWorkspaceBoundary(raw,account:userID,origin:origin)
            let cache=try TeamWorkspaceCache(boundary:boundary,previous:snapshot.teamWorkspace,pending:snapshot.pending,tasks:snapshot.tables["tasks"] ?? [])
            teamAccessMask=cache
            snapshot=cache.merging(cache.filtering(snapshot.tables),into:snapshot)
            try persist()
            if !readable {
                conversationFixtureHolding=false;conversationFixtureWaiting=false
                let reply=conversationFixtureRelease;conversationFixtureRelease=nil;reply?.resume()
            }
        } catch {self.conversationError=error.localizedDescription;self.error=error.localizedDescription}
    }

    #endif
    private let monitor = NWPathMonitor()
    private var accountGeneration = UUID() { didSet {
        syncSignInWorkspace = nil; syncAfterSignInRequested = nil; conversationError = nil; conversationPageTokens.removeAll(); conversationSyncID = nil; conversationSyncGeneration = nil } }
    @ObservationIgnored private var consumingWidgetActions = false
    @ObservationIgnored var sharedCapturePublishedWorkspace: SharedCaptureWorkspace?
    @ObservationIgnored var sharedCapturePublicationReady = false
    @ObservationIgnored private var widgetCalendarWindow: CalendarCapacityWindow?
    @ObservationIgnored private var widgetCalendarRevision = -1
    @ObservationIgnored private var capacityRequest: (UUID, String)?
    private(set) var widgetPublicationRevision = 0
    private var workspaceRepairFingerprint: String?
    var workspaceNeedsRepair: Bool { !workspaceCacheDecoded }
    private var workspaceCacheDecoded = true
    private var workspaceCacheReadable = true {
        didSet {if oldValue != workspaceCacheReadable {workspaceReadRevision=UUID()};if taskCache.update(presentedTables["tasks"] ?? []) {taskRevision+=1}}
    }
    #if DEBUG
    var reminderRouteFixtureOutcome = "Waiting"
    var todoistImportFixture: Bool { userID == "ui-testing" && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--todoist-import-testing") }
    var widgetFixtureFailSave = false
    var inboxFixtureFailSave = false
    var focusFixtureFailSave = false
    @ObservationIgnored private var savedFilterFixtureFailureConsumed = false
    @ObservationIgnored private var savedFilterFixtureFailNextPersist = false
    var widgetFixtureReady = false
    #endif
    #if !DEBUG
    var todoistImportFixture: Bool { false }
    #endif
    var workspaceGeneration: UUID { accountGeneration }
    var teamOrganizationReadable: Bool { workspaceCacheReadable && signedIn && !localMode && !signingOut && !accountRemovalBlocked }
    var sharedCaptureAvailable: Bool { !accountRemovalBlocked && workspaceCacheReadable && (signedIn || localMode) && !signingOut && !userID.isEmpty }
    var backupWarning: String?
    @ObservationIgnored private var dailyBackupRunning = false
    var dailyBackupsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "dailyBackups." + userID) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dailyBackups." + userID); if newValue { scheduleDailyBackup() } }
    }
    var backupVault: BackupVault {
        let account = userID
        let folder = cacheURL.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
            .appending(path: WorkspaceBackup.stableID("vault", account), directoryHint: .isDirectory)
        return BackupVault(directory: folder, account: account, key: { try BackupVault.deviceKey(account: account) }, removalGate: UUID(uuidString: account) == nil ? nil : AccountRemovalDisk(directory: cacheURL.deletingLastPathComponent(), account: account))
    }
    var teamDraftVault: TeamCompletionDraftVault? {
        guard signedIn,!localMode,!signingOut,!accountRemovalBlocked,TeamProjectValue.id(userID),let origin=try? backend.accountRemovalOrigin else {return nil}
        let vault=backupVault
        return TeamCompletionDraftVault(directory:vault.directory.appendingPathComponent("Team drafts",isDirectory:true).appendingPathComponent(WorkspaceBackup.stableID("origin",origin),isDirectory:true),account:userID,origin:origin,key:vault.key,removalGate:vault.removalGate)
    }
    var teamRecordedRecoveryVault: TeamCompletionRecoveryDraftVault? {
        guard let base = teamDraftVault else { return nil }
        return TeamCompletionRecoveryDraftVault(directory: base.directory.appendingPathComponent("Recorded recovery", isDirectory: true), account: base.account, origin: base.origin, key: base.key, removalGate: base.removalGate)
    }
    var teamCancelledRecoveryVault: TeamCompletionRecoveryDraftVault? {
        guard let base = teamDraftVault else { return nil }
        return TeamCompletionRecoveryDraftVault(directory: base.directory.appendingPathComponent("Cancelled recovery", isDirectory: true), account: base.account, origin: base.origin, key: base.key, removalGate: base.removalGate, cancelled: true)
    }
    func teamRecoveryVault(for draft: TeamCompletionRecoveryDraft) -> TeamCompletionRecoveryDraftVault? {
        draft.isCancellationDraft ? teamCancelledRecoveryVault : teamRecordedRecoveryVault
    }
    var teamSelectionDraftVault: TeamCompletionBatchDraftVault? {
        guard let base = teamDraftVault else { return nil }
        return TeamCompletionBatchDraftVault(directory: base.directory.appendingPathComponent("Selections", isDirectory: true), account: base.account, origin: base.origin, key: base.key, removalGate: base.removalGate)
    }
    func makeRecoveryBackup(kind: String = "Manual") async throws -> RecoveryEntry {
        guard workspaceCacheDecoded, !accountRemovalBlocked, !signingOut, signedIn || localMode, !userID.isEmpty else { throw BackupFailure(message: "Open a readable workspace before backing it up.") }
        let vault = backupVault, before = snapshot, generation = accountGeneration
        let entry = try await Task.detached(priority: .utility) { try vault.save(before, kind: kind) }.value
        guard generation == accountGeneration else { throw BackupFailure(message: "The workspace changed. The backup belongs to the previous workspace.") }
        backupWarning = nil
        return entry
    }
    func preserveUnreadableWorkspace() async throws {
        guard workspaceNeedsRepair, !accountRemovalBlocked, !signingOut, !syncing, signedIn || localMode,
              let fingerprint = workspaceRepairFingerprint else { throw BackupFailure(message: "The original file cannot be safely read yet. Reopen your workspace and try again.") }
        let vault = backupVault, source = cacheURL, generation = accountGeneration
        _ = try await Task.detached(priority: .utility) { try vault.preserveAndReopen(source, expectedDigest: fingerprint) }.value
        guard generation == accountGeneration, !signingOut, !accountRemovalBlocked else { throw CancellationError() }
        accountGeneration = UUID()
        snapshot = Snapshot(); teamAccessMask = nil; undoStack = []; redoStack = []; syncConflict = nil; focusSyncConflict = nil
        error = nil; load(); publishWidgetSnapshot(scheduleCapacityRefresh: false)
        guard !workspaceNeedsRepair else { throw BackupFailure(message: "The original is preserved, but the workspace could not reopen. Try reopening the app.") }
        notice = "Original file preserved. Restore a recovery copy or wait for cloud sync."
        Task { await reschedule(); await sync() }
    }
    @ObservationIgnored private var editorSessions: [UUID:TaskEditorSession] = [:]
    func editorAdmission(_ record: Record, kind: TaskEditorAdmission.Kind = .existing, workspace: WorkspaceBinding? = nil, root: Record? = nil) -> TaskEditorAdmission {
        let capturedRoot = root ?? self.record("tasks", id: SubtaskTree.referencePath(record.id)?.first ?? record.id)
        let team = kind == .existing && capturedRoot?.id == record.id ? capturedRoot.flatMap { try? captureTeamTaskEditor($0) } : nil
        return TaskEditorAdmission(workspace:workspace ?? WorkspaceBinding(account:userID,generation:workspaceGeneration),record:record,root:capturedRoot,kind:kind,teamDraft:team)
    }
    func teamTaskCreationOpening(_ source: Record) throws -> TaskEditorOpening {
        let draft = try captureTeamTaskCreation(source)
        return TaskEditorOpening(task: source, admission: TaskEditorAdmission(workspace: draft.workspace, record: source, root: nil, kind: .new, teamDraft: draft))
    }
    func beginEditorSession(_ original: Record) throws -> TaskEditorSession {
        guard !accountRemovalBlocked,signedIn || localMode else {throw CancellationError()}
        let session=TaskEditorSession(vault:backupVault,origin:localMode ? nil:try backend.accountRemovalOrigin,original:original,labels:labels)
        editorSessions=editorSessions.filter{!$0.value.closed}
        editorSessions[session.id]=session
        return session
    }
    /// Team editors require their captured scope; ordinary personal writers stay closed.
    func editorMayWrite(source: Record, proposed: Record, teamDraft: TeamTaskEditorDraft? = nil) -> Bool {
        guard workspaceCacheReadable,!accountRemovalBlocked,!signingOut,signedIn || localMode else {return false}
        let cache=nativeConversationTeamCache
        if let teamDraft {
            guard let cache, !localMode, teamDraft.source.id == source.id,
                  ["id", "user_id", "project_id", "task_generation"].allSatisfy({ teamDraft.source[$0] == source[$0] }),
                  teamDraft.scope.origin == (try? backend.accountRemovalOrigin) else { return false }
            return teamDraft.permits(current: record("tasks", id: teamDraft.source.id), workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
        }
        if cache?.knownTasks.contains(source.id)==true {return false}
        for project in Set([source.string("project_id"),proposed.string("project_id")]) where !project.isEmpty {
            guard record("projects",id:project) != nil, cache?.knownTeams[project]==nil else {return false}
            if let permission=cache?.boundary.projects[project],!permission.canSend {return false}
        }
        return true
    }
    /// This explicit path never infers team scope for an ordinary personal save.
    /// Organization rollout and the service's task capability both stay required.
    private var nativeTeamEditorEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "TaskfoldTeamsEnabled") as? Bool == true }
    var teamWorkflowCreationAvailable: Bool { nativeTeamEditorEnabled && workspaceCacheReadable && signedIn && !localMode && !signingOut && !accountRemovalBlocked && online && !syncing && snapshot.pending.isEmpty }
    var teamTaskMovesAvailable: Bool { nativeTeamEditorEnabled && workspaceCacheReadable && signedIn && !localMode && !signingOut && !accountRemovalBlocked }
    func teamTaskMoveContextCurrent(account: String, origin: String, workspace: WorkspaceBinding, session: UUID) -> Bool {
        teamTaskMovesAvailable && workspace.matches(account: userID, generation: workspaceGeneration) && account == userID && origin == (try? backend.accountRemovalOrigin) && session == backend.reminderSessionIncarnation
    }
    func teamTaskMoveDestinations(_ admission: TeamTaskMoveAdmission) throws -> [Record] {
        guard teamTaskMovesAvailable, online, !syncing, let cache = nativeConversationTeamCache else { throw AppFailure(message: "Wait for sync to finish before moving a shared task.") }
        let ids = try admission.destinations(current: record("tasks", id: admission.draft.source.id), workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, pending: snapshot.pending, enabled: nativeTeamEditorEnabled)
        return projects.filter { ids.contains($0.id) }
    }
    func teamTaskMoveScope(_ admission: TeamTaskMoveAdmission, destination: String) throws -> TeamTaskMoveScope {
        guard try teamTaskMoveDestinations(admission).contains(where: { $0.id == destination }), let cache = nativeConversationTeamCache else { throw TeamTaskMoveCommand.invalid }
        return try admission.scope(destination: destination, current: record("tasks", id: admission.draft.source.id), workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, pending: snapshot.pending, enabled: nativeTeamEditorEnabled)
    }
    func teamTaskMoveReviewCurrent(_ scope: TeamTaskMoveScope, token: String) -> Bool {
        guard teamTaskMovesAvailable, online, !syncing, snapshot.pending.isEmpty, let cache = nativeConversationTeamCache,
              cache.boundary.belongs(account: scope.account, origin: scope.origin), cache.boundary.raw["token"] == .string(token) else { return false }
        return [scope.source, scope.destination].allSatisfy { id in
            guard let permission = cache.boundary.projects[id] else { return false }
            return permission.team == scope.team && permission.canSend && !permission.archived && ["manager", "editor"].contains(permission.role)
        }
    }
    var teamTaskMoveService: any TeamTaskMoveService {
        #if DEBUG
        if TeamTaskMoveNativePeer.enabled { return TeamTaskMoveNativePeer(store: self) }
        #endif
        return backend
    }
    func refreshAfterTeamTaskMove(_ receipt: TeamTaskMoveReceipt) async -> Bool {
        #if DEBUG
        if TeamTaskMoveNativePeer.enabled { return applyTeamTaskMoveNativeReceipt(receipt) }
        #endif
        let generation = workspaceGeneration, account = userID, session = backend.reminderSessionIncarnation, started = Date()
        await sync()
        return generation == workspaceGeneration && account == userID && session == backend.reminderSessionIncarnation && (lastSync ?? .distantPast) >= started
    }
    func captureTeamTaskEditor(_ source: Record) throws -> TeamTaskEditorDraft {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              let cache = nativeConversationTeamCache, cache.boundary.origin == (try backend.accountRemovalOrigin),
              record("tasks", id: source.id) == source else { throw TeamTaskEditorDraft.unavailable }
        return try TeamTaskEditorDraft(source: source, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
    }
    func captureTeamTaskCreation(_ source: Record) throws -> TeamTaskEditorDraft {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              let cache = nativeConversationTeamCache, cache.boundary.origin == (try backend.accountRemovalOrigin),
              record("tasks", id: source.id) == nil else { throw TeamTaskEditorDraft.unavailable }
        return try TeamTaskEditorDraft(creating: source, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
    }
    @discardableResult
    func saveTeamTaskEditor(_ desired: Record, draft: TeamTaskEditorDraft) -> Bool {
        do {
            guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
                  let cache = nativeConversationTeamCache, draft.scope.origin == (try backend.accountRemovalOrigin) else { throw TeamTaskEditorDraft.unavailable }
            let change = try draft.mutation(desired: desired, current: record("tasks", id: draft.source.id), workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
            guard let change else { return true }
            return commit([change])
        } catch { self.error = error.localizedDescription; return false }
    }
    func reviewedPersonalTaskPlanning(_ records: [Record], workspace: WorkspaceBinding, session: UUID, origin: String?) throws {
        guard (1...TaskHierarchyIndex.maximumEdits).contains(records.count) else { throw AppFailure(message: "Select up to 1,000 tasks at a time.") }
        guard Set(records.map(\.id)).count == records.count, workspace.matches(account: userID, generation: workspaceGeneration), session == backend.reminderSessionIncarnation, origin == (try? backend.accountRemovalOrigin), signedIn, !signingOut, !accountRemovalBlocked, workspaceCacheReadable else { throw TeamTaskBatch.conflict }
        for source in records {
            let root = SubtaskTree.referencePath(source.id)?.first ?? source.id
            if let cache = nativeConversationTeamCache {
                guard let origin, cache.boundary.belongs(account: workspace.account, origin: origin), cache.knownTeams[source.string("project_id")] == nil, !cache.knownTasks.contains(root) else { throw TeamTaskBatch.conflict }
            }
            guard try selectionRecord(source.id) == source else { throw TeamTaskBatch.conflict }
        }
    }
    func hasSharedTaskSelection(_ ids: Set<String>) -> Bool {
        ids.contains { id in
            let root = SubtaskTree.referencePath(id)?.first ?? id
            return nativeConversationTeamCache?.knownTasks.contains(root) == true || record("tasks", id: root).map { nativeConversationTeamCache?.knownTeams[$0.string("project_id")] != nil } == true
        }
    }
    func captureTeamTaskCompletionSelection(_ records: [Record]) throws -> TeamTaskCompletionSelection {
        let selection = try TeamTaskCompletionSelection(drafts: records.map { try captureTeamTaskEditor($0) }, tasks: snapshot.tables["tasks"] ?? [])
        _ = try reviewedTeamTaskCompletionSelection(selection); return selection
    }
    func reviewedTeamTaskCompletionSelection(_ selection: TeamTaskCompletionSelection) throws -> Mutation {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              let cache = nativeConversationTeamCache,
              selection.drafts.allSatisfy({ $0.scope.origin == (try? backend.accountRemovalOrigin) }) else { throw TeamTaskEditorDraft.unavailable }
        return try selection.mutation(tasks: snapshot.tables["tasks"] ?? [], workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
    }
    @discardableResult func saveTeamTaskCompletionSelection(_ selection: TeamTaskCompletionSelection) -> Bool {
        do { return commit([try reviewedTeamTaskCompletionSelection(selection)]) }
        catch { self.error = error.localizedDescription; return false }
    }
    func captureTeamTaskPlanningAdmission(_ records: [Record]) throws -> TeamTaskPlanningAdmission {
        guard !records.isEmpty, records.count <= 100, Set(records.map(\.id)).count == records.count else { throw TeamTaskBatch.invalid }
        let admission = try TeamTaskPlanningAdmission(drafts: records.map { try captureTeamTaskEditor($0) })
        try reviewedTeamTaskPlanningAdmission(admission); return admission
    }
    func reviewedTeamTaskPlanningAdmission(_ admission: TeamTaskPlanningAdmission) throws {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              let cache = nativeConversationTeamCache,
              admission.drafts.allSatisfy({ $0.scope.origin == (try? backend.accountRemovalOrigin) }) else { throw TeamTaskEditorDraft.unavailable }
        let current = Dictionary(uniqueKeysWithValues: admission.drafts.compactMap { draft in record("tasks", id: draft.source.id).map { (draft.source.id, $0) } })
        guard admission.permits(current: current, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled) else { throw TeamTaskBatch.conflict }
    }
    func captureTeamTaskPlanningSelection(_ records: [Record], changes: [String: [String: JSON]]) throws -> TeamTaskPlanningSelection {
        guard !records.isEmpty, records.count <= 100, Set(records.map(\.id)).count == records.count else { throw TeamTaskBatch.invalid }
        let selection = try TeamTaskPlanningSelection(drafts: records.map { try captureTeamTaskEditor($0) }, changes: changes)
        _ = try reviewedTeamTaskPlanningSelection(selection); return selection
    }
    func reviewedTeamTaskPlanningSelection(_ selection: TeamTaskPlanningSelection) throws -> Mutation {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              let cache = nativeConversationTeamCache,
              selection.drafts.allSatisfy({ $0.scope.origin == (try? backend.accountRemovalOrigin) }) else { throw TeamTaskEditorDraft.unavailable }
        let current = Dictionary(uniqueKeysWithValues: selection.drafts.compactMap { draft in record("tasks", id: draft.source.id).map { (draft.source.id, $0) } })
        return try selection.mutation(current: current, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
    }
    @discardableResult func saveTeamTaskPlanningSelection(_ selection: TeamTaskPlanningSelection) -> Bool {
        do { return commit([try reviewedTeamTaskPlanningSelection(selection)]) }
        catch { self.error = error.localizedDescription; return false }
    }
    func captureTeamTaskDeletionSelection(_ records: [Record]) throws -> TeamTaskDeletionSelection {
        guard (2...100).contains(records.count), Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ nativeConversationTeamCache?.knownTeams[$0.string("project_id")] != nil }) else {
            throw AppFailure(message: "Choose between 2 and 100 tasks from one shared team. Nothing has been removed.")
        }
        let selection = try TeamTaskDeletionSelection(drafts: records.map { try captureTeamTaskEditor($0) })
        _ = try reviewedTeamTaskDeletionSelection(selection)
        return selection
    }
    func reviewedTeamTaskDeletionSelection(_ selection: TeamTaskDeletionSelection) throws -> Mutation {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              let cache = nativeConversationTeamCache,
              selection.drafts.allSatisfy({ $0.scope.origin == (try? backend.accountRemovalOrigin) }) else { throw TeamTaskEditorDraft.unavailable }
        let current = Dictionary(uniqueKeysWithValues: selection.drafts.compactMap { draft in record("tasks", id: draft.source.id).map { (draft.source.id, $0) } })
        return try selection.mutation(current: current, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
    }
    @discardableResult func deleteTeamTaskSelection(_ selection: TeamTaskDeletionSelection) -> Bool {
        do { return commit([try reviewedTeamTaskDeletionSelection(selection)]) }
        catch { self.error = error.localizedDescription; return false }
    }
    /// Both review and commit use the original admission; no fresh authority or
    /// source baseline is acquired by a confirmation sheet.
    func reviewedTeamTaskDeletion(_ draft: TeamTaskEditorDraft, requestID: UUID) throws -> Mutation {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              let cache = nativeConversationTeamCache, draft.scope.origin == (try backend.accountRemovalOrigin) else { throw TeamTaskEditorDraft.unavailable }
        return try draft.deletion(current: record("tasks", id: draft.source.id), workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled, requestID: requestID)
    }
    @discardableResult func deleteTeamTaskEditor(_ draft: TeamTaskEditorDraft, requestID: UUID) -> Bool {
        do { return commit([try reviewedTeamTaskDeletion(draft, requestID: requestID)]) }
        catch { self.error = error.localizedDescription; return false }
    }
    func flushEditorSessions() -> Bool {
        var success=true
        for session in editorSessions.values where !session.closed {if !session.flush() {success=false}}
        return success
    }
    func preserveEditorEdit(_ value: TaskEditorRecovery, workspace: WorkspaceBinding) async throws {
        guard workspace.matches(account:userID,generation:workspaceGeneration), value.account==userID,
              !accountRemovalBlocked,!signingOut,signedIn || localMode else {throw CancellationError()}
        let origin=localMode ? nil:try backend.accountRemovalOrigin
        guard value.origin==origin else {throw CancellationError()}
        let vault=backupVault
        try await Task.detached(priority:.utility) {try vault.saveEditorDraft(value)}.value
        guard workspace.matches(account:userID,generation:workspaceGeneration),!accountRemovalBlocked,!signingOut else {throw CancellationError()}
    }
    private func scheduleDailyBackup() {
        guard workspaceCacheDecoded, !accountRemovalBlocked, !signingOut, (signedIn || localMode), !userID.isEmpty, dailyBackupsEnabled, !dailyBackupRunning else { return }
        let vault = backupVault, before = snapshot, generation = accountGeneration
        dailyBackupRunning = true
        Task {
            defer { dailyBackupRunning = false }
            do {
                try await Task.detached(priority: .utility) {
                    if try vault.entries().contains(where: { $0.kind == "Daily" && Calendar.current.isDateInToday($0.createdAt) }) { return }
                    _ = try vault.save(before, kind: "Daily")
                }.value
                if generation == accountGeneration { backupWarning = nil }
            } catch { if generation == accountGeneration { backupWarning = "Daily backup could not be saved: " + error.localizedDescription } }
        }
    }
    /// The reviewed snapshot must still be current after the encrypted checkpoint is written.
    func restore(_ backup: WorkspaceBackup, policy: RestorePolicy, reviewed: Snapshot, generation: UUID, onlyNewTask: Bool = false) async throws -> RestorePlan {
        guard activeTeamMask==nil else {throw BackupFailure(message:"Finish the project-access recovery before restoring another workspace. Your saved work is kept.")}
        guard workspaceCacheDecoded else {throw BackupFailure(message:"This device’s saved workspace could not be read. Its original file is protected and needs repair before it can be replaced.")}
        guard generation == accountGeneration, snapshot == reviewed, signedIn || localMode else { throw BackupFailure(message: "Your workspace changed. Refresh the restore preview before continuing.") }
        guard !syncing else { throw BackupFailure(message: "Wait for sync to finish, then refresh the restore preview.") }
        let plan = try backup.plan(current: reviewed, account: userID, policy: policy)
        if onlyNewTask {try TaskEditorRecovery.requireNewTaskPlan(plan)}
        guard plan.total > 0 else { return plan }
        _ = try await makeRecoveryBackup(kind: "Before restore")
        guard generation == accountGeneration, snapshot == reviewed, !syncing else { throw BackupFailure(message: "Your workspace changed while the recovery copy was saved. Refresh the preview before continuing.") }
        guard commit(plan.changes, remember: false) else {
            let message = error ?? "The restore could not be saved. Your workspace was not changed."
            error = nil
            throw BackupFailure(message: message)
        }
        workspaceCacheDecoded=true
        undoStack = []; redoStack = []
        return plan
    }
    var userID: String {
        if localMode {
            #if DEBUG
            if ConversationFixture.enabled { return ConversationFixture.owner }
            if ProcessInfo.processInfo.arguments.contains("--uitesting") { return "ui-testing" }
            if ProcessInfo.processInfo.arguments.contains("--preview") { return "preview" }
            #endif
            return "local"
        }
        return backend.session?.user.id ?? ""
    }
    var email: String { backend.session?.user.email ?? "On this iPhone" }
    var tasks: [Record] { _ = taskRevision; return taskCache.tasks }
    private var filterCollaborators: [Record]? { presentedTables["project_collaborators"] ?? (localMode ? [] : nil) }
    @ObservationIgnored private var cachedAssignments: (rows:[Record]?,scope:String?,catalog:TaskAssignmentProvenance.Catalog)?
    var assignmentCatalog: TaskAssignmentProvenance.Catalog {
        let rows = presentedTables[TaskAssignmentProvenance.table] ?? (localMode ? [] : nil), scope = localMode ? userID : nil
        if let cachedAssignments, cachedAssignments.rows == rows, cachedAssignments.scope == scope { return cachedAssignments.catalog }
        let catalog = TaskAssignmentProvenance.Catalog(rows,localAccount:scope)
        cachedAssignments = (rows,scope,catalog); return catalog
    }
    var filterContext: FilterContext { FilterContext(projects: projects, sections: rows("sections"), labels: labels, userID: userID, people: projects.flatMap { project in projectMembers(project.id).map { person in var scoped = person; scoped["project_id"] = .string(project.id); return scoped } }, datePreferences: datePhrasePreferences, collaborators: filterCollaborators, assignments: assignmentCatalog) }
    var savedViews: [Record] { OrganizationOrder.sorted(rows("saved_views")) }
    var favorites: [Record] { OrganizationOrder.sorted(rows("favorites")) }
    var workingHours: WorkingHours? { workingHoursDocument == .null ? WorkingHours() : try? WorkingHours(document: workingHoursDocument) }
    var workingHoursDocument: JSON { record("view_preferences", id: "planner")?["working_hours"] ?? .null }
    var workingHoursEditable: Bool { workspaceCacheReadable && (signedIn || localMode) && WorkingHours.editable(workingHoursDocument) }
    var insightsAvailable:Bool { workspaceCacheReadable && (signedIn || localMode) }
    var productivityGoalRow:Record? { ProductivityGoals.row(snapshot,account:userID) }
    var productivityGoalDocument:JSON { productivityGoalRow?[ProductivityGoals.field] ?? .null }
    var productivityGoals:ProductivityGoals? { try? ProductivityGoals(document:productivityGoalDocument) }
    @discardableResult func saveProductivityGoals(_ desired:JSON,expected:JSON,workspace:WorkspaceBinding) -> Bool {
        guard workspace.matches(account:userID,generation:workspaceGeneration),workspaceCacheReadable,signedIn || localMode else { error="Reopen goals in your current workspace.";return false }
        guard productivityGoalDocument==expected else { error="Goals changed while you were editing. Your draft is kept; review the latest goals before saving.";return false }
        do { return commit([try ProductivityGoalEdit.command(desired,previous:productivityGoalRow,account:userID)],remember:false) }
        catch { self.error=error.localizedDescription;return false }
    }
    var datePhraseRecord: Record? { DatePhrasePreferences.row(snapshot, account: userID) }
    var datePhrasePreferences: DatePhrasePreferences? { try? DatePhrasePreferences(document: datePhraseRecord?["date_preferences"] ?? .null) }
    var datePhraseEditable: Bool { workspaceCacheReadable && (signedIn || localMode) && datePhrasePreferences != nil }
    func datePhraseDay(_ phrase: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        datePhrasePreferences?.resolve(phrase, from: now, calendar: calendar)
    }
    @discardableResult func setDatePhraseWeekday(_ day: Int, field: String, workspace: WorkspaceBinding) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), datePhraseEditable,
              let document = DatePhrasePreferences.changing(datePhraseRecord?["date_preferences"] ?? .null, field: field, weekday: day) else {
            error = "These date preferences changed or are unsupported. Reopen settings before changing them."; return false
        }
        var row = datePhraseRecord ?? Record(["id": .string(DatePhrasePreferences.recordID), "user_id": .string(userID)])
        row["date_preferences"] = document
        return save("view_preferences", row)
    }
    var reminderSnoozeRecord: Record? { ReminderSnooze.row(rows(ReminderSnooze.table), account: userID) }
    var reminderSnoozeMinutes: Int { ReminderSnooze.minutes(reminderSnoozeRecord?["settings"] ?? .null) ?? 60 }
    var reminderSnoozeEditable: Bool {
        workspaceCacheReadable && (signedIn || localMode) && (reminderSnoozeRecord == nil || ReminderSnooze.validDocument(reminderSnoozeRecord!["settings"]) && ReminderSnooze.version(reminderSnoozeRecord!["settings"]) == 1)
    }
    @discardableResult func setReminderSnooze(_ minutes: Int, workspace: WorkspaceBinding) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), reminderSnoozeEditable,
              let settings = ReminderSnooze.changing(reminderSnoozeRecord?["settings"] ?? .null, minutes: minutes) else {
            error = "Reopen Notifications before changing this workspace's snooze preference."; return false
        }
        if settings == reminderSnoozeRecord?["settings"] { return true }
        let change = Mutation(table: ReminderSnooze.table, recordID: ReminderSnooze.recordID, method: "POST",
            fields: ["id": .string(ReminderSnooze.recordID), "user_id": .string(userID), "settings": settings])
        let saved = commit([change], remember: false)
        if saved { ReminderCategory.register(minutes: reminderSnoozeMinutes) }
        return saved
    }
    var reminderAutomaticMinutes: Int { ReminderAutomatic.minutes(reminderSnoozeRecord?["settings"] ?? .null) ?? 0 }
    @discardableResult func setReminderAutomatic(_ minutes: Int, workspace: WorkspaceBinding) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), reminderSnoozeEditable,
              let settings = ReminderAutomatic.changing(reminderSnoozeRecord?["settings"] ?? .null, minutes: minutes) else {
            error = "Reopen Notifications before changing this workspace's automatic reminder."; return false
        }
        if settings == reminderSnoozeRecord?["settings"] { return true }
        return commit([Mutation(table: ReminderSnooze.table, recordID: ReminderSnooze.recordID, method: "POST",
            fields: ["id": .string(ReminderSnooze.recordID), "user_id": .string(userID), "settings": settings], reminderPreferenceField: ReminderAutomatic.field)], remember: false)
    }
    func applyingReminderDefault(_ task: Record, previous: Record?) -> Record {
        // An unsupported preference is not permission to invent a legacy default.
        guard reminderSnoozeEditable else { return task }
        let current = record("tasks", id: task.id)
        if let previous, let current, task["reminder_specs"] == previous["reminder_specs"],
           current["reminder_specs"] != previous["reminder_specs"] { return task }
        // A newly synced clock/choice belongs to the task already; a stale editor's
        // implicit default must not replace it. Explicit reminder edits keep their guard.
        return ReminderAutomatic.applying(to: task, previous: current ?? previous, minutes: reminderAutomaticMinutes)
    }
    var focusRecord: Record? { record(FocusSessionChange.table, id: FocusSessionChange.recordID) }
    func allowsWidgetRecordLink(_ url: URL) -> Bool {
        WidgetRecordLink.allows(url, account: userID, available: workspaceCacheReadable && (signedIn || localMode))
    }
    var focusAvailable: Bool { !accountRemovalBlocked && !signingOut && workspaceCacheReadable && (signedIn || localMode) }
    var focusSession: FocusSession? { FocusSessionChange.session(in: focusRecord, account: userID) }
    @discardableResult func changeFocus(_ session: FocusSession?, expected: Record?, workspace: WorkspaceBinding) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), workspaceCacheReadable, signedIn || localMode,
              focusSyncConflict == nil, FocusSessionChange.baseline(focusRecord) == FocusSessionChange.baseline(expected) else {
            error = "This Focus session changed. Review its current state before continuing."; return false
        }
        if let session, session.status == .running || session.id != focusSession?.id {
            guard tasks.contains(where: { $0.id.lowercased() == session.taskID && TaskKind.mayComplete($0) && !$0.completed }) else {
                error = "Choose an open task to start or resume Focus."; return false
            }
        }
        do { return commit([try FocusSessionChange.make(session, current: focusRecord, account: userID)], remember: false) }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func resolveFocusConflict(id: UUID, keepLocal: Bool) -> Bool {
        guard let conflict = focusSyncConflict, conflict.id == id,
              let next = conflict.resolving(snapshot, account: userID, keepLocal: keepLocal) else {
            error = "Reopen the current Focus review before choosing a session."; return false
        }
        let old = snapshot; snapshot = next
        do { try persist() } catch { snapshot = old; self.error = error.localizedDescription; return false }
        focusSyncConflict = nil; notice = nil; publishWidgetSnapshot(scheduleCapacityRefresh: false); Task { await reschedule(); await sync() }; return true
    }
    @discardableResult func setWorkingHours(_ hours: WorkingHours, workspace: WorkspaceBinding) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), workingHoursEditable else {
            error = "These working hours changed or are unsupported. Reopen settings before changing them."; return false
        }
        do {
            let document = try hours.replacing(workingHoursDocument)
            var row = record("view_preferences", id: "planner") ?? Record(["id": .string("planner"), "user_id": .string(userID)])
            row["working_hours"] = document
            return save("view_preferences", row)
        } catch { self.error = error.localizedDescription; return false }
    }
    /// Native queries share the observed clock; selected calendar days remain explicit.
    func matching(_ query: TaskQuery) -> [Record] {
        _ = taskRevision
        var query = calendarContext.applying(to: query)
        if case .saved(let id) = query.scope {
            guard let view = record("saved_views", id: id), let rule = try? FilterRule(document: view["query_ast"]), (try? rule.validate(in: filterContext)) != nil else { return [] }
            query.filterProjects = filterContext.projectReferences; query.filterSections = rows("sections").map { FilterReference(id: $0.id, name: $0.name, projectID: $0.string("project_id").isEmpty ? nil : $0.string("project_id")) }
            query.filterPeople = filterContext.personReferences
            query.filter = rule; query.datePreferences = datePhrasePreferences; query.now = rule.usesClockWindow ? calendarContext.minute : nil; query.filterLabels = labels.map { FilterReference(id: $0.id, name: $0.name) }; query.userID = userID
            query.includeCompleted = query.includeCompleted || view["include_completed"].flag || (!rule.hasQuerySections && rule.includesCompletion)
        }
        if query.filter?.usesAssignmentHistory == true { query.filterAssignments = assignmentCatalog }
        let matches = taskCache.matching(query)
        if case .project = query.scope { return matches }
        let archived = ProjectOrganization.archivedIDs(in: allProjects)
        return matches.filter { !archived.contains($0.string("project_id")) }
    }
    func filterGroups(_ scope: TaskScope, tasks: [Record], includeCompleted: Bool = false) -> [TaskGrouping.Group] {
        let view: Record? = { if case .saved(let id) = scope { return record("saved_views", id: id) }; return nil }()
        let rule = view.flatMap { try? FilterRule(document: $0["query_ast"]) }
        return TaskGrouping.queryGroups(tasks, rule: rule, by: viewValue(scope, field: "grouping", fallback: .string("none")).text, context: filterContext, today: calendarContext.today, timeZone: calendarContext.timeZone, includeCompleted: includeCompleted || view?["include_completed"].flag == true, now: calendarContext.minute, work: productiveReading)
    }
    func captureDefaults(_ scope: TaskScope) -> [String: JSON] {
        guard case .saved(let id) = scope, let view = record("saved_views", id: id), let rule = try? FilterRule(document: view["query_ast"]), (try? rule.validate(in: filterContext)) != nil else { return [:] }
        return rule.captureDefaults(in: filterContext, today: calendarContext.today, timeZone: calendarContext.timeZone)
    }
    func filterError(_ scope: TaskScope) -> String? {
        guard case .saved(let id) = scope else { return nil }
        guard let view = record("saved_views", id: id) else { return "This saved filter was deleted or is unavailable on this account." }
        do {
            let rule = try FilterRule(document: view["query_ast"]); try rule.validate(in: filterContext)
            if rule.usesTaskHierarchy { _ = try taskCache.hierarchyCandidates(for: rule, projects: filterContext.projectReferences, userID: userID) }
            return nil
        }
        catch { return error.localizedDescription }
    }
    func title(for scope: TaskScope) -> String {
        switch scope {
        case .project(let id): return record("projects", id: id)?.name ?? "Unavailable project"
        case .label(let id): return record("labels", id: id)?.name ?? "Unavailable label"
        case .saved(let id): return record("saved_views", id: id)?.name ?? "Unavailable filter"
        default: return scope.title
        }
    }
    func available(_ scope: TaskScope) -> Bool {
        switch scope { case .project(let id): return record("projects", id: id) != nil; case .label(let id): return record("labels", id: id) != nil; case .saved(let id): return record("saved_views", id: id) != nil; default: return true }
    }
    func viewValue(_ scope: TaskScope, field: String, fallback: JSON) -> JSON {
        if case .saved(let id) = scope, ["layout", "grouping", "sort_by", "include_completed"].contains(field) { return record("saved_views", id: id)?.fields[field] ?? fallback }
        return record("view_preferences", id: scope.preferenceKey)?.fields[field] ?? fallback
    }
    func setViewValue(_ scope: TaskScope, field: String, value: JSON) {
        if case .saved(let id) = scope, ["layout", "grouping", "sort_by", "include_completed"].contains(field), var row = record("saved_views", id: id) { row[field] = value; _ = save("saved_views", row); return }
        var row = record("view_preferences", id: scope.preferenceKey) ?? Record(["id": .string(scope.preferenceKey), "user_id": .string(userID)])
        row[field] = value; _ = save("view_preferences", row)
    }
    func newSavedView() -> Record {
        Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(userID), "name": .string(""), "query_ast": FilterRule.predicate("today", "").document, "layout": .string("list"), "grouping": .string("none"), "sort_by": .string("manual"), "include_completed": .bool(false), "order_index": .number(Double((savedViews.map { $0["order_index"].integer }.max() ?? -1) + 1))])
    }
    func isFavorite(_ scope: TaskScope) -> Bool { record("favorites", id: scope.preferenceKey) != nil }
    func toggleFavorite(_ scope: TaskScope) {
        if isFavorite(scope) { remove("favorites", scope.preferenceKey) }
        else { _ = save("favorites", Record(["id": .string(scope.preferenceKey), "user_id": .string(userID), "order_index": .number(Double((favorites.map { $0["order_index"].integer }.max() ?? -1) + 1))])) }
    }
    func reorderFavorites(_ keys: [String]) { _ = reorderOrganization("favorites", ids: keys) }
    @discardableResult
    func reorderOrganization(_ table: String, ids: [String], projectID: String? = nil) -> Bool {
        let current = rows(table).filter { table != "sections" || $0.string("project_id") == projectID }
        do {
            let changes = try OrganizationOrder.command(table: table, rows: current, ids: ids, projectID: projectID)
            return changes.isEmpty || commit(changes)
        } catch { self.error = error.localizedDescription; return false }
    }
    var allProjects: [Record] { OrganizationOrder.sorted(rows("projects")) }
    var projects: [Record] { ProjectOrganization.outline(allProjects).map(\.project) }
    var personalConnectionProjects: [Record] {
        let cache = nativeConversationTeamCache, account = userID, origin = try? backend.accountRemovalOrigin
        return projects.filter { PersonalConnectionDestination.resolve(project: $0.id, projects: [$0], cache: cache, account: account, origin: origin).supported }
    }
    func personalConnectionDestination(_ project: String?) -> PersonalConnectionDestination {
        PersonalConnectionDestination.resolve(project: project, projects: allProjects, cache: nativeConversationTeamCache, account: userID, origin: try? backend.accountRemovalOrigin)
    }
    var archivedProjects: [ProjectOrganization.Item] { ProjectOrganization.outline(allProjects, archived: true) }
    var inboxProductiveReading: ProductiveTaskReading {
        _ = taskRevision
        return taskCache.inboxProductiveReading()
    }
    var productiveReading: ProductiveTaskReading {
        _ = taskRevision
        return taskCache.productiveReading(excluding: ProjectOrganization.archivedIDs(in: allProjects))
    }
    var activeTasks: [Record] { let archived = ProjectOrganization.archivedIDs(in: allProjects); return tasks.filter { !archived.contains($0.string("project_id")) } }
    var workflowTemplates: [Record] { rows(WorkflowTemplate.table).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var labels: [Record] { rows("labels").sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    func quickEntryContext(project: String = "") -> QuickEntryContext {
        QuickEntryContext(projects: projects, sections: rows("sections"), labels: labels,
            members: Dictionary(uniqueKeysWithValues: projects.map { ($0.id, projectMembers($0.id)) }),
            currentProject: project, currentUser: userID, datePreferences: datePhrasePreferences)
    }
    var profile: Record { rows("profiles").first(where: { $0.string("user_id") == userID }) ?? Record() }
    private(set) var googleAvatarURL: URL?
    private var avatarMetadataLoaded = false
    var avatarURL: URL? { localMode ? nil : ProfileAvatar.resolved(uploaded: profile.string("avatar_url"), google: googleAvatarURL) }
    var childActivityHistory: ChildWorkHistory {
        let tables = presentedTables
        return ChildWorkHistory(rows: tables[TaskNodeActivity.table], epoch: tables[TaskNodeActivity.epochTable])
    }
    var pendingCount: Int { snapshot.pending.count + ConversationOutbox.rows(snapshot, account: userID).filter { $0.string("state") != "draft" }.count }
    var cacheURL: URL {
        #if DEBUG
        if AccountRemovalNativeFixture.enabled { return AccountRemovalNativeFixture.dataRoot.appendingPathComponent(userID + ".json") }
        #endif
        #if DEBUG
        if LocationHandoffNativeFixture.enabled { return LocationHandoffNativeFixture.root.appendingPathComponent("task-cache.json") }
        #endif
        let folder = URL.applicationSupportDirectory.appending(path: "Taskfold", directoryHint: .isDirectory)
        return folder.appending(path: "\(userID.isEmpty ? "signed-out" : userID).json")
    }
    init() {
        #if DEBUG
        // This local-only fixture must never read another app's stored cloud credentials.
        // Keep authenticated test variants and every normal app launch on the existing path.
        if TeamEditorNativeFixture.enabled { backend = TeamEditorNativeFixture.backend() }
        else if AccountRemovalNativeFixture.enabled { backend = AccountRemovalNativeFixture.backend() }
        else if LocationHandoffNativeFixture.enabled { backend = LocationHandoffNativeFixture.backend() }
        else if let bundle = Bundle.main.bundleIdentifier,
           (bundle == "com.dbakp.taskfold.mac.p0grammaruitests" || bundle == "com.dbakp.taskfold.mac.p0widgethosts" || bundle.hasPrefix("com.dbakp.taskfold.mac.workflowtests")),
           ProcessInfo.processInfo.arguments.contains("--uitesting"),
           !ProcessInfo.processInfo.arguments.contains("--live-auth-ui-test"),
           UserDefaults.standard.bool(forKey: "localMode") {
            backend = Backend(session: nil)
        } else { backend = Backend() }
        #else
        backend = Backend()
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--live-auth-ui-test") {
            try? SecureSession.save(nil); backend.session = nil
            UserDefaults.standard.set(false, forKey: "localMode")
        }
        #endif
        localMode = UserDefaults.standard.bool(forKey: "localMode")
        #if DEBUG
        if TeamEditorNativeFixture.enabled { localMode = false }
        #endif
        googleAvatarURL = backend.session?.user.googleAvatarURL
        signedIn = backend.session != nil || localMode
        #if DEBUG
        if TeamEditorNativeFixture.enabled { try? TeamRecoveryStorageNativeFixture.restoreIfRequested() }
        #endif
        if signedIn { load() } else { publishWidgetSnapshot() }
        #if DEBUG
        prepareTeamEditorNativeFixture()
        #endif
        #if DEBUG
        if LocationHandoffNativeFixture.enabled {
            if !rows("tasks").contains(where: { $0.id == LocationHandoffNativeFixture.taskID }) { snapshot.tables["tasks"] = [LocationHandoffNativeFixture.task()] }
            dailyBackupsEnabled = false
            try? persist()
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.online = path.status == .satisfied
                if path.status == .satisfied { await self?.refreshRemoteReminderRegistration(); await self?.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "taskfold.connectivity"))
        Task { await refreshRemoteReminderRegistration() }
    }
    func rows(_ table: String) -> [Record] { presentedTables[table] ?? [] }
    func record(_ table: String, id: String) -> Record? { rows(table).first { $0.id == id } }
    func projectMembers(_ projectID: String) -> [Record] {
        guard let project = record("projects", id: projectID) else { return [] }
        let key = "project_members:" + projectID
        let people = presentedTables[key] ?? rows("project_collaborators").filter { $0.string("project_id") == projectID }
        return TaskAssignment.members(project: project, collaborators: people, currentUser: userID, profile: profile)
    }
    func assigneeName(_ task: Record) -> String {
        let id = task.string("assigned_to")
        guard !id.isEmpty else { return "Unassigned" }
        return projectMembers(task.string("project_id")).first { $0.id == id }?.string("display_name") ?? "Assigned collaborator"
    }
    @discardableResult
    func refreshProjectMembers(_ projectID: String) async throws -> [Record] {
        guard !projectID.isEmpty, !localMode else { return projectMembers(projectID) }
        guard record("projects",id:projectID) != nil else {throw TeamProjectAccessUnavailable()}
        let generation = accountGeneration, accessRevision=workspaceReadRevision, account=userID
        let data = try await backend.request("/rest/v1/rpc/taskfold_project_members", method: "POST", body: ["_project_id": .string(projectID)], expectedAccount:account)
        let people = try JSONDecoder().decode([Record].self, from: data).map { person in
            var member = person; member["status"] = .string("accepted"); return member
        }
        guard generation == accountGeneration, accessRevision==workspaceReadRevision, record("projects",id:projectID) != nil else { throw CancellationError() }
        snapshot.tables["project_members:" + projectID] = people
        try persist()
        return projectMembers(projectID)
    }
    func load() {
        accessRecoveryPending = UserDefaults.standard.bool(forKey: accessRecoveryNoticeKey)
        workspaceCacheReadable = false;workspaceCacheDecoded=false;workspaceRepairFingerprint=nil
        defer {
            if localMode, workspaceCacheReadable { migrateOrganization() }
            if workspaceCacheReadable {
                do { try persist(); consumeWidgetCompletions() }
                catch { self.error = "Could not prepare widget actions: " + error.localizedDescription }
            }
        }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { snapshot = Snapshot(); workspaceCacheDecoded=true;workspaceCacheReadable = true; return }
        do {
            let loaded=try JSONDecoder().decode(Snapshot.self,from:Data(contentsOf:cacheURL))
            snapshot=loaded;workspaceCacheDecoded=true
            if let boundary=try teamAccessFenceDisk?.load() {
                teamAccessMask=try TeamWorkspaceCache(boundary:boundary,previous:loaded.teamWorkspace,pending:loaded.pending,tasks:loaded.tables["tasks"] ?? [])
            }
            workspaceCacheReadable = true
            if snapshot.tables[DayPlacement.table] == nil, let legacy = snapshot.tables["_local_day_order"] {
                snapshot.tables[DayPlacement.table] = legacy.map { row in var row = row; row["user_id"] = .string(userID); return row }
            }
        }
        catch { if !workspaceCacheDecoded { workspaceRepairFingerprint = try? backupVault.unreadableFingerprint(cacheURL) }; self.error = "Could not read saved tasks: \(error.localizedDescription)"; if let disk = try? widgetActionDisk() { try? disk.clearProjection() } }
    }
    func persist(acceptingTimeSnooze timeSnooze: TimeSnoozeIntent? = nil) throws {
        #if DEBUG
        if savedFilterFixtureFailNextPersist {
            savedFilterFixtureFailNextPersist = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        if inboxFixtureFailSave { throw WidgetActionFailure("Isolated Inbox review save-failure fixture") }
        if focusFixtureFailSave { throw WidgetActionFailure("Isolated Focus save-failure fixture") }
        if widgetFixtureFailSave, !snapshot.widgetCompletion.receipts.isEmpty { throw WidgetActionFailure("Isolated widget save-failure fixture") }
        #endif
        WidgetCompletion.prepare(&snapshot)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = FileManager.default.fileExists(atPath: cacheURL.path) ? try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cacheURL)) : Snapshot()
        var durable = snapshot
        durable.locationImports = try LocationHandoffImportLedger.staging(previous: previous, proposed: durable)
        durable.timeSnoozes = try stagedTimeSnoozes(previous: previous, proposed: durable, newIntent: timeSnooze)
        durable = try WearableReceiptLedger.applying(previous: previous, proposed: durable)
        let data = try JSONEncoder().encode(durable)
        if UUID(uuidString: userID) != nil {
            try AccountRemovalDisk(directory: cacheURL.deletingLastPathComponent(), account: userID).writable {
                try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } else { try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        snapshot = durable
        publishWidgetSnapshot()
        #if DEBUG
        if userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--uitesting"), ProcessInfo.processInfo.arguments.contains("--workflow-diagnostics"), Bundle.main.bundleIdentifier?.contains(".workflowtests") == true {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) { print("WORKFLOW_SNAPSHOT " + text); fflush(stdout) }
        }
        #endif
        scheduleDailyBackup()
    }
    func makeInboxReview(batch: InboxReviewBatch = .five, excluding: Set<String> = []) -> InboxReviewRequest? {
        guard signedIn || localMode, workspaceCacheReadable else { error = "Open a readable workspace before reviewing Inbox."; return nil }
        let order = record(DayPlacement.table, id: "scope:inbox")?["ids"].list.map(\.text) ?? []
        return InboxReviewRequest(workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), tasks: tasks, batch: batch, order: order, excluding: excluding, reading: inboxProductiveReading)
    }

    static let appGroup = "group.com.dbakp.taskfold"
    /// The private cache is saved before its actionable projection is published.
    private func publishWidgetSnapshot(scheduleCapacityRefresh: Bool = true) {
        publishSharedCaptureWorkspace()
        guard let disk = try? widgetActionDisk() else { return }
        let account = sharedCaptureAvailable ? userID : ""
        let busy = CalendarBusyStore.shared; busy.bind(account: account)
        let current = widgetCalendarWindow.flatMap { value -> CalendarCapacityWindow? in
            value.account == account && value.timeZone == TimeZone.current.identifier && busy.revision == widgetCalendarRevision && Date() < value.updated.addingTimeInterval(3600) ? value : nil
        }
        let fallback = busy.anyConnected ? (busy.connected && busy.selected.isEmpty && busy.links?.active != true ? "choose" : "refresh") : "off"
        var payload = WidgetProjection.payload(tasks: activeTasks, projects: projects, account: account, labels: labels, sections: rows("sections"), savedViews: savedViews, completionTokens: (activeTeamMask ?? snapshot.teamWorkspace)?.widgetTokens(presentationSnapshot) ?? WidgetCompletion.tokens(snapshot), pendingSync: pendingCount, workingHours: workingHours, calendarWindow: current, calendarFallback: fallback, notePins: rows("view_orders"), focusRecord: focusRecord, focusConflict: focusSyncConflict != nil, focusReadable: workspaceCacheReadable, pulseActivity: rows(TaskActivity.table), pulseEpoch: rows(TaskActivity.epochTable), pulseChildren: childActivityHistory, datePreferences: datePhrasePreferences, people: filterContext.people, viewPreferences: rows("view_preferences"), viewOrders: rows("view_orders"), collaborators: filterCollaborators, assignments: assignmentCatalog)
        if let feedback = snapshot.widgetCompletion.feedback, feedback.account == account,
           Date() < feedback.expiresAt, widgetFeedbackIsCurrent(feedback) {
            payload["completionFeedback"] = try? JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(feedback))
        }
        do { try disk.publish(JSONEncoder().encode(payload)); widgetPublicationRevision += 1 }
        catch { try? disk.clearProjection() } // A failed publication must not leave actionable old data.
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        if scheduleCapacityRefresh, !account.isEmpty, workspaceCacheReadable, current == nil, capacityRequest?.1 != account {
            capacityRequest = (UUID(), account)
            Task { await refreshWidgetCapacity() }
        }
    }

    /// Calendar reads remain in the app. Publication never blocks a durable task save.
    func refreshWidgetCapacity() async {
        let account = sharedCaptureAvailable ? userID : ""
        guard !account.isEmpty, workspaceCacheReadable else { return }
        let request = UUID(), generation = accountGeneration
        capacityRequest = (request, account)
        let busy = CalendarBusyStore.shared; busy.bind(account: account)
        let revision = busy.revision
        widgetCalendarWindow = nil
        publishWidgetSnapshot(scheduleCapacityRefresh: false)
        let window = await busy.capacityWindow()
        guard capacityRequest?.0 == request else { return }
        capacityRequest = nil
        guard generation == accountGeneration, account == userID, !Task.isCancelled, busy.revision == revision, let window else { return }
        widgetCalendarWindow = window; widgetCalendarRevision = revision
        publishWidgetSnapshot(scheduleCapacityRefresh: false)
    }

    private func widgetActionDisk() throws -> WidgetActionDisk {
        #if DEBUG
        if AccountRemovalNativeFixture.enabled { return WidgetActionDisk(directory: AccountRemovalNativeFixture.sharedRoot) }
        #endif
        #if DEBUG
        if calendarContextFixtureEnabled || clockWindowFixtureEnabled || datePhraseFixtureEnabled || assigneePatternFixtureEnabled {
            return WidgetActionDisk(directory: cacheURL.deletingLastPathComponent().appending(path: "CalendarContextTests", directoryHint: .isDirectory))
        }
        // These isolated native test apps have no App Group entitlement. Keep each
        // projection in its own sandbox without requiring the widget fixture's UI overlay.
        let isolatedNativeBundles: Set<String> = [
            "com.dbakp.taskfold.mac.p0uitests", "com.dbakp.taskfold.mac.p0localuitests",
            "com.dbakp.taskfold.mac.p0importa11ytests", "com.dbakp.taskfold.mac.p0focuscontrasttests",
            "com.dbakp.taskfold.mac.p0grammaruitests", "com.dbakp.taskfold.mac.p0signeduitests",
            "com.dbakp.taskfold.mac.p0notificationtests"
        ]
        if ProcessInfo.processInfo.arguments.contains("--widget-action-testing") || isolatedNativeBundles.contains(Bundle.main.bundleIdentifier ?? "") {
            return WidgetActionDisk(directory: cacheURL.deletingLastPathComponent().appending(path: "WidgetActionTests", directoryHint: .isDirectory))
        }
        #endif
        return try WidgetActionDisk.system()
    }
    /// Intent execution returns only after task edits, queue and receipt are saved together.
    func performWidgetCompletion(_ incoming: WidgetCompletionRequest) throws {
        guard signedIn || localMode, workspaceCacheReadable, userID == incoming.account else {
            throw WidgetActionFailure("Open the widget's workspace in Taskfold before completing this task.")
        }
        let disk = try widgetActionDisk()
        if snapshot.widgetCompletion.saved(incoming) { try? disk.acknowledge(incoming); return }
        let request = try disk.enqueue(incoming)
        guard try applyWidgetCompletion(request) else {
            try? disk.acknowledge(request)
            throw WidgetActionFailure("This task changed after the widget was shown. Refresh the widget and try again.")
        }
        try? disk.acknowledge(request) // A failed acknowledgement is retried using the durable receipt.
    }
    @discardableResult private func applyWidgetCompletion(_ request: WidgetCompletionRequest) throws -> Bool {
        switch WidgetCompletion.plan(request, snapshot: snapshot, account: userID) {
        case .saved: return true
        case .stale: return false
        case .complete(let changes):
            let feedback = WidgetCompletionFeedback.capture(request, projection: try? widgetActionDisk().read().data)
            guard commit(changes, widgetReceipt: request, widgetFeedback: feedback) else {
                throw WidgetActionFailure(error ?? "Your widget completion could not be saved. Open Taskfold to retry.")
            }
            return true
        }
    }
    /// Startup, foreground refresh and connectivity retry the same credential-free handoff.
    func consumeWidgetCompletions() {
        refreshSharedCaptureDraftCount()
        guard !consumingWidgetActions, workspaceCacheReadable, signedIn || localMode,
              let disk = try? widgetActionDisk() else { return }
        consumingWidgetActions = true; defer { consumingWidgetActions = false }
        // A successful local retry returns before cloud sync can clear the banner.
        // Clear only the notice owned by this widget attempt, preserving other warnings.
        if let previous = widgetActionStatus, notice == previous { notice = nil }
        widgetActionStatus = nil
        do {
            for request in try disk.pending(account: userID) {
                let applied = try applyWidgetCompletion(request)
                if !applied { widgetActionStatus = "A widget completion became out of date. Refresh the widget before trying again."; notice = widgetActionStatus }
                try disk.acknowledge(request)
            }
        } catch { widgetActionStatus = "Widget actions need attention: " + error.localizedDescription; notice = widgetActionStatus }
    }
    func startLocal() {
        guard !signingOut else { return }
        // Re-entering the current workspace is not an account switch. Preserve its
        // session-bound routes and already scheduled one-shot snoozes.
        guard !localMode || !signedIn || !workspaceCacheReadable else { return }
        let firstRun = !FileManager.default.fileExists(atPath: URL.applicationSupportDirectory.appending(path: "Taskfold/local.json").path)
        if !remoteReminderTestWorkspace {
            do { try prepareReminderDeviceRetirement() } catch { remoteReminderStatus = "Device unlinking could not be saved securely. Retry remote setup." }
        }
        accountGeneration = UUID(); localMode = true; signedIn = true; UserDefaults.standard.set(true, forKey: "localMode"); load()
        CalendarBusyStore.shared.bind(account: userID)
        if firstRun && userID == "local" && tasks.isEmpty { seedGettingStarted() }
    }
    /// A small sample project so the first screen teaches the gestures instead of being empty.
    private func seedGettingStarted() {
        let project = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(userID), "name": .string("Getting started"), "color": .string("#e31e4b"), "order_index": .number(0), "description": .string("A few tasks to try Taskfold with. Delete them whenever you like.")])
        #if os(macOS)
        let samples: [(String, String, Int)] = [
            ("Press Space to complete this task", "Or click the circle. Undo with ⌘Z or the confirmation strip.", 1),
            ("Drag me onto Tomorrow in Upcoming", "Drops land inside the task's priority group; an indicator shows where.", 2),
            ("Press ⌘N and type “Call mom tomorrow at 20.51 p1”", "Dates, times, priorities, and #labels are picked out of the text as chips.", 3),
            ("Open Calendar and switch to Week", "Select a day to see its tasks beside the grid; ⌘T jumps back to today.", 4),
        ]
        #else
        let samples: [(String, String, Int)] = [
            ("Swipe right to complete this task", "Or tap the circle. An Undo pill appears for a few seconds.", 1),
            ("Press and hold, then drag me to tomorrow", "Rows lift under your finger and a gap opens where they will land.", 2),
            ("Tap + and type “Call mom tomorrow at 20.51 p1”", "Dates, times, priorities, and #labels are picked out of the text as chips.", 3),
            ("Open the Calendar tab and drag it upward", "The calendar collapses into a week strip so the day gets the screen.", 4),
        ]
        #endif
        var changes = [Mutation(table: "projects", recordID: project.id, method: "POST", fields: project.fields)]
        for (title, notes, priority) in samples {
            var task = Record.task(user: userID, project: project.id, date: Date())
            task["title"] = .string(title); task["description"] = .string(notes); task["priority"] = .number(Double(priority))
            changes.append(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields))
        }
        commit(changes, remember: false)
    }
    func authenticated() async {
        // A newer authenticated session supersedes an in-flight sign-out.
        guard backend.session != nil else { return }
        if let account = backend.session?.user.id, UUID(uuidString: account) != nil, AccountRemovalDisk(directory: cacheURL.deletingLastPathComponent(), account: account).removed {
            do { try await backend.clearSession() } catch { return }
            resetRemovedWorkspaceIfSignedOut(); return
        }
        googleAvatarURL = backend.session?.user.googleAvatarURL; avatarMetadataLoaded = false
        accountGeneration = UUID(); localMode = false; signedIn = true; syncConflict = nil; focusSyncConflict = nil
        CalendarBusyStore.shared.bind(account: userID)
        UserDefaults.standard.set(false, forKey: "localMode")
        snapshot = Snapshot(); undoStack = []; redoStack = []; load(); Task { await refreshRemoteReminderRegistration(); await sync() }
    }
    func permitsTeamTemplateTransfer(_ review: TeamTemplateTransferReview) -> Bool {
        teamOrganizationReadable && review.workspace.matches(account: userID, generation: workspaceGeneration)
            && review.session == backend.reminderSessionIncarnation && review.detail.scope.origin == (try? backend.accountRemovalOrigin)
    }
    func revalidateTeamTemplateTransfer(_ review: TeamTemplateTransferReview) async throws {
        guard permitsTeamTemplateTransfer(review) else { throw TeamTemplateLibraryValue.invalid }
        let latest = try await backend.teamTemplateDetail(team: review.detail.scope.team, template: review.detail.metadata.id, account: review.detail.scope.account, origin: review.detail.scope.origin)
        guard permitsTeamTemplateTransfer(review) else { throw TeamTemplateLibraryValue.invalid }
        try review.verify(latest: latest, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation)
    }
    var teamTemplateRecoveryAvailable: Bool { signedIn && !localMode && !signingOut && !accountRemovalBlocked }
    /// Uses the confirmed account for cleanup, never whichever account is now active.
    func teamTemplateCommandVault(account: String, origin: String) throws -> TeamTemplateCommandVault {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        let root = cacheURL.deletingLastPathComponent()
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("vault", account), isDirectory: true)
            .appendingPathComponent("Team template requests", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("origin", origin), isDirectory: true)
        let io = TeamTemplateCommandFileIO(directory: directory, account: account, origin: origin, encryptionKey: { try BackupVault.deviceKey(account: account) })
        return TeamTemplateCommandVault(io: io, coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: root)
    }
    func teamWorkflowRunVault(account: String, origin: String) throws -> TeamWorkflowRunVault {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        let root = cacheURL.deletingLastPathComponent()
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("vault", account), isDirectory: true)
            .appendingPathComponent("Shared workflow requests", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("origin", origin), isDirectory: true)
        let io = TeamWorkflowRunFileIO(directory: directory, account: account, origin: origin, encryptionKey: { try BackupVault.deviceKey(account: account) })
        return TeamWorkflowRunVault(io: io, coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: root)
    }
    @ObservationIgnored lazy var teamProjectCommandVault = TeamProjectCommandVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".team-project-commands"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: cacheURL.deletingLastPathComponent())
    @ObservationIgnored lazy var teamTaskMoveVault = TeamTaskMoveVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".team-task-moves"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: cacheURL.deletingLastPathComponent())
    @ObservationIgnored lazy var projectAdoptionVault = TeamProjectAdoptionVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".team-project-adoption"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: cacheURL.deletingLastPathComponent())
    @ObservationIgnored lazy var teamOrganizationCommandVault = TeamOrganizationCommandVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".team-commands"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: cacheURL.deletingLastPathComponent())
    @ObservationIgnored lazy var emailAddressVault = EmailAddressVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".email-addresses"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("EmailAddressLocks", isDirectory: true))
    @ObservationIgnored lazy var webhookEnrollmentVault = WebhookEnrollmentVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".webhook-enrollment"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("WebhookEnrollmentLocks", isDirectory: true))
    @ObservationIgnored lazy var automationEnrollmentVault = AutomationEnrollmentVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".automation-enrollment"), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("AutomationEnrollmentLocks", isDirectory: true))
    @ObservationIgnored private lazy var accountRemovalVault = AccountRemovalVault(io: CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "com.taskfold") + ".account-removal"))
    private(set) var accountRemovalStatus: String?
    private var removalPendingAccounts = Set<String>()
    private var removalRecoveryRunning = false
    var accountRemovalBusy: Bool { signingOut || removalRecoveryRunning }
    var accountRemovalBlocked: Bool {
        !localMode && (removalPendingAccounts.contains(userID) || UserDefaults.standard.bool(forKey: "accountRemoval.pending." + userID) ||
            UUID(uuidString: userID) != nil && AccountRemovalDisk(directory: cacheURL.deletingLastPathComponent(), account: userID).removed)
    }
    /// The only new-account entry point is an explicit destructive confirmation.
    func deleteAccount(expected: WorkspaceBinding) async throws {
        guard expected.matches(account: userID, generation: workspaceGeneration), !localMode, !signingOut, !removalRecoveryRunning,
              let account = backend.session?.user.id, account == expected.account, UUID(uuidString: account) != nil else { throw AppFailure(message: "Sign in and finish the current account action first.") }
        signingOut = true; defer { signingOut = false; publishWidgetSnapshot(); Task { await reschedule() } }
        try persist()
        let incarnation = backend.reminderSessionIncarnation
        let origin = try backend.accountRemovalOrigin
        var command = try await accountRemovalVault.command(account: account, origin: origin)
        if command == nil {
            let fresh = try await backend.accountRemovalCommand()
            guard backend.reminderSessionIncarnation == incarnation, backend.session?.user.id == account else { throw CancellationError() }
            command = try await accountRemovalVault.begin(fresh)
        }
        guard let command else { throw CancellationError() }
        markRemovalPending(command.account)
        do { try await finishAccountRemoval(command) }
        catch { accountRemovalStatus = "Account removal needs attention. Your remaining device copies are kept until cleanup can finish."; throw error }
    }
    /// Runs on launch and by explicit Retry, including after ordinary sign-out.
    /// Only commands that already reached this app's private vault may resume.
    func resumeAccountRemovals() async {
        guard !removalRecoveryRunning, !signingOut else { return }
        removalRecoveryRunning = true; defer { removalRecoveryRunning = false; Task { await reschedule() } }
        do {
            let commands = try await accountRemovalVault.pending()
            guard !commands.isEmpty else { return }
            var needsAttention = false
            for command in commands {
                markRemovalPending(command.account)
                do { try await finishAccountRemoval(command) }
                catch { needsAttention = true }
            }
            if needsAttention { accountRemovalStatus = "Account removal needs attention. Your remaining device copies are kept until cleanup can finish." }
        } catch { accountRemovalStatus = "Account removal needs attention. Your remaining device copies are kept until cleanup can finish." }
    }
    private func markRemovalPending(_ account: String) {
        removalPendingAccounts.insert(account)
        UserDefaults.standard.set(true, forKey: "accountRemoval.pending." + account)
        accountRemovalStatus = "Finishing account removal…"
        if userID == account {
            accountGeneration = UUID(); undoStack = []; redoStack = []
            CalendarBusyStore.shared.bind(account: "")
            publishWidgetSnapshot()
        }
    }
    private func finishAccountRemoval(_ original: AccountRemovalCommand) async throws {
        guard original.valid, original.origin == (try backend.accountRemovalOrigin) else { throw AppFailure(message: "Return to this account's original server to finish removal.") }
        var command = original
        if !command.confirmed {
            do {
                if command.statusProof == nil {
                    let proof = try await backend.prepareAccountRemoval(command)
                    command = try await accountRemovalVault.prepare(command, proof: proof)
                }
                try await backend.performAccountRemoval(command)
            }
            catch is AccountRemovalAuthorizationRequired {
                guard backend.session?.user.id == command.account else { throw AccountRemovalAuthorizationRequired() }
                let session = backend.reminderSessionIncarnation
                let fresh = try await backend.accountRemovalCommand(forceRefresh: backend.session?.access_token == command.authorization)
                guard fresh.account == command.account, backend.reminderSessionIncarnation == session else { throw CancellationError() }
                command = try await accountRemovalVault.renew(command, with: fresh)
                let proof = try await backend.prepareAccountRemoval(command)
                command = try await accountRemovalVault.prepare(command, proof: proof)
                try await backend.performAccountRemoval(command)
            }
            command = try await accountRemovalVault.confirm(command)
        }
        // All paths and keys below derive from the confirmed command, never from
        // whichever account may have become active while network/Keychain awaited.
        let account = command.account
        let root = cacheURL.deletingLastPathComponent()
        let gate = AccountRemovalDisk(directory: root, account: account)
        let vault = BackupVault(directory: root.appendingPathComponent("Backups").appendingPathComponent(WorkspaceBackup.stableID("vault", account)), account: account,
            key: { try BackupVault.deviceKey(account: account) }, removalGate: gate)
        try gate.removeCache()
        let privateRoot = LocationPrivateStore.applicationSupport
        if privateRoot != root { try AccountRemovalDisk(directory: privateRoot, account: account).removeCache() }
        try await LocationPrivateStore(applicationSupport: privateRoot).removeAccountData(account)
        #if os(iOS)
        // Reject a hydration that read the old archive before this cleanup.
        // The next serialized reschedule installs the current workspace's engine.
        locationRefreshID = UUID(); locationArchive = nil; locationEngine = nil
        #endif
        try widgetActionDisk().removeAccount(account)
        try sharedCaptureDisk().removeAccount(account)
        try await CalendarBusyStore.shared.eraseAccount(account)
        try await Task.detached(priority: .utility) { try vault.removeAll(); try BackupVault.removeDeviceKey(account: account) }.value
        for key in ["dailyBackups." + account, ReminderPreferences.timeSensitiveKey(account), FocusFinish.preferenceKey(account)] { UserDefaults.standard.removeObject(forKey: key) }
        if backend.session?.user.id == account {
            // Confirmed Auth removal covers every incarnation of this account.
            // Backend's conditional clear still protects a concurrent B sign-in.
            do { try await backend.clearSession() } catch is CancellationError { }
            resetRemovedWorkspaceIfSignedOut()
        }
        try await automationEnrollmentVault.removeAccount(account, origin: command.origin)
        try await webhookEnrollmentVault.removeAccount(account, origin: command.origin)
        try await emailAddressVault.removeAccount(account, origin: command.origin)
        try await teamOrganizationCommandVault.removeAccount(account, origin: command.origin)
        try await teamProjectCommandVault.removeAccount(account, origin: command.origin)
        try await teamTemplateCommandVault(account: account, origin: command.origin).removeAccount(account, origin: command.origin)
        try await teamWorkflowRunVault(account: account, origin: command.origin).removeAccount(account, origin: command.origin)
        try await teamTaskMoveVault.removeAccount(account, origin: command.origin)
        try await projectAdoptionVault.removeAccount(account, origin: command.origin)
        try await accountRemovalVault.finish(command)
        removalPendingAccounts.remove(account)
        UserDefaults.standard.removeObject(forKey: "accountRemoval.pending." + account)
        accountRemovalStatus = nil
    }
    private func resetRemovedWorkspaceIfSignedOut() {
        guard backend.session == nil else { return }
        googleAvatarURL = nil; avatarMetadataLoaded = false
        accountGeneration = UUID(); signedIn = false; localMode = false
        UserDefaults.standard.set(false, forKey: "localMode")
        snapshot = Snapshot(); error = nil; undoStack = []; redoStack = []; lastSync = nil; syncConflict = nil; focusSyncConflict = nil; accessRecoveryPending = false
        CalendarBusyStore.shared.bind(account: ""); publishWidgetSnapshot(); clearScheduledReminders()
    }
    private(set) var signingOut = false
    func signOut() async {
        guard !signingOut else { return }
        signingOut = true; defer { signingOut = false; publishWidgetSnapshot(); Task { await reschedule() } }

        let leavingSnoozeEpochKey = timeSnoozeEpochKey
        // The account-specific cache and unsent queue stay on disk for the next sign-in.
        do {
            try persist(); try prepareReminderDeviceRetirement(); accountGeneration = UUID()
            try await backend.clearSession()
        } catch is CancellationError {
            // A newer sign-in owns the session; do not clear its workspace or show an old error.
            return
        } catch { self.error = error.localizedDescription; return }
        UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: leavingSnoozeEpochKey)
        googleAvatarURL = nil; avatarMetadataLoaded = false
        accountGeneration = UUID(); backend.session = nil; signedIn = false; localMode = false
        UserDefaults.standard.set(false, forKey: "localMode")
        snapshot = Snapshot(); undoStack = []; redoStack = []; lastSync = nil; syncConflict = nil; focusSyncConflict = nil
        accessRecoveryPending = false
        CalendarBusyStore.shared.bind(account: "")
        publishWidgetSnapshot()
        clearScheduledReminders()
    }
    @discardableResult
    func commit(_ changes: [Mutation], remember: Bool = true, widgetReceipt: WidgetCompletionRequest? = nil, widgetFeedback: WidgetCompletionFeedback? = nil, sharedCaptureReceipt: SharedCaptureDraft? = nil) -> Bool {
        guard !signingOut, !accountRemovalBlocked else { error = "Finish account removal before changing this workspace."; return false }
        guard workspaceCacheDecoded else {error="Your saved workspace needs recovery before more changes can be saved. Its original file is kept.";return false}
        if let access=activeTeamMask ?? snapshot.teamWorkspace,
           changes.contains(where:{!access.canSend($0,in:snapshot)}) {
            error="Team editing is not available for this change. Your existing work is kept.";return false
        }
        let prepared:[Mutation]
        do {
            prepared=try TeamTaskBatch.preparing(changes,snapshot:snapshot)
            for change in prepared {
                if change.method == "TEAM_COMPLETE" || change.teamCompletion != nil {
                    guard let command=change.teamCompletion else { throw TeamCompletion.invalid }
                    guard !localMode,command.scope.account == userID,command.scope.origin == (try backend.accountRemovalOrigin) else { throw TeamCompletion.invalid }
                    var preview=snapshot
                    guard command.apply(to:&preview,header:change) else { throw TeamCompletion.conflict }
                }
                if let batch=change.teamTaskBatch {
                    guard !localMode,batch.account == userID,batch.origin == (try backend.accountRemovalOrigin) else { throw TeamTaskBatch.invalid }
                    var preview=snapshot
                    guard batch.apply(to:&preview,header:change) else { throw TeamTaskBatch.invalid }
                }
            }
        } catch { self.error=error.localizedDescription;return false }
        let preparedChanges=prepared
        guard !preparedChanges.contains(where: { $0.table == "tasks" && $0.recordID.hasPrefix("subtask:") }) else {
            error = "Open this subtask's details to make this change."; return false
        }
        if let draft = sharedCaptureReceipt {
            guard draft.workspace.account == userID, preparedChanges.count == 1,
                  preparedChanges[0].table == "tasks", preparedChanges[0].method == "POST",
                  preparedChanges[0].recordID == draft.taskID, preparedChanges[0].insertOnly == true else { return false }
        }
        #if DEBUG
        if userID == "ui-testing", sharedCaptureReceipt != nil,
           ProcessInfo.processInfo.arguments.contains("--uitesting"), ProcessInfo.processInfo.arguments.contains("--shared-capture-save-failure-once"),
           !sharedCaptureFixtureFailureConsumed {
            sharedCaptureFixtureFailureConsumed = true; savedFilterFixtureFailNextPersist = true
        }
        if userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--uitesting"), ProcessInfo.processInfo.arguments.contains("--workflow-save-failure-once"), !workflowFixtureFailureConsumed,
           preparedChanges.filter({ $0.table == "tasks" && $0.method == "POST" }).count > 1 {
            workflowFixtureFailureConsumed = true; savedFilterFixtureFailNextPersist = true
        }
        #endif
        guard preparedChanges.filter(ProductivityGoalEdit.matches).allSatisfy({ProductivityGoalEdit.valid($0,account:userID)}) else { error="These goals need a supported choice and current workspace.";return false }
        guard preparedChanges.allSatisfy({ $0.table != TaskNodeActivity.table && $0.table != TaskNodeActivity.epochTable && $0.table != TaskActivity.table && $0.table != TaskActivity.epochTable && $0.table != TaskAssignmentProvenance.table && $0.table != SharedComment.table && $0.table != SharedMention.table && !$0.table.hasPrefix("_conversation_") }) else { error = "Activity history is read-only."; return false }
        guard preparedChanges.filter({ $0.table == FocusSessionChange.table }).allSatisfy({ FocusSessionChange.valid($0, account: userID) }) else {
            error = "This Focus command needs a valid workspace and revision."; return false
        }
        guard preparedChanges.filter({ $0.organizationOrder != nil || $0.method == "ORDER" }).allSatisfy(OrganizationOrder.valid) else {
            error = "This ordering command is invalid."; return false
        }
        // Undo and redo are new commands; a persisted retry keeps its existing identity.
        let orderingCommands = preparedChanges.map { change in
            var change = change
            if change.organizationOrder != nil { change.id = UUID() }
            return change
        }
        let old = snapshot
        let changes = orderingCommands.flatMap { TaskAssignment.mutations($0, existing: record($0.table, id: $0.recordID)) }.map { change in
            var change = change
            if change.table == "tasks", change.method != "DELETE" {
                change.fields = TaskPlanning.fields(change.fields, existing: record("tasks", id: change.recordID))
                if change.method == "PATCH", change.fields["reminder_specs"] == nil,
                   !Set(change.fields.keys).isDisjoint(with: ["due_date", "due_time", "scheduled_at", "time_zone"]),
                   let existing = record("tasks", id: change.recordID) {
                    let proposed = Record(existing.fields.merging(change.fields) { _, new in new })
                    let resolved = applyingReminderDefault(proposed, previous: existing)
                    if resolved["reminder_specs"] != proposed["reminder_specs"] {
                        change.fields["reminder_specs"] = resolved["reminder_specs"]
                        if change.baseline != nil { change.baseline?["reminder_specs"] = existing["reminder_specs"] }
                    }
                }
                change = TeamTaskLabelsDraft.normalizing(change, existing: record("tasks", id: change.recordID), catalog: labels, cache: nativeConversationTeamCache)
            }
            if change.table == DayPlacement.table, change.method != "DELETE" {
                change.method = "POST" // Stable composite upsert also handles pre-sync legacy rows.
                change.fields["id"] = .string(change.recordID); change.fields["user_id"] = .string(userID)
            }
            return change
        }
        var committedChanges: [Mutation] = []
        for var change in changes {
            if change.table == "tasks", change.method == "PATCH", change.baseline == nil, let existing = record("tasks", id: change.recordID) {
                change.baseline = TaskCompletionRevision.editBaseline(for: change.fields, from: existing)
            }
            if change.table == "tasks", change.method == "DELETE", change.baseline == nil, let existing = record("tasks", id: change.recordID) {
                change.baseline = existing.fields
            }
            if change.table == WorkflowTemplate.table, ["PATCH","DELETE"].contains(change.method), let existing=record(change.table,id:change.recordID) {
                change.baseline = existing.fields.merging(change.baseline ?? [:]) { _, original in original }
            }
            change = TaskCompletionRevision.capturing(change, existing: record(change.table, id: change.recordID))
            guard TaskGeneration.permitsLocalAction(change, existing: record(change.table, id: change.recordID)) else {
                snapshot = old
                error = "This task was deleted and restored while you were editing. Reopen its current copy before applying this change."
                return false
            }
            guard taskHeadingsAuthoringEnabled || teamHeadingAuthoringAvailable(change.teamTaskScope) || !TaskKind.requiresAuthoring(change, existing: record(change.table, id: change.recordID)) else {
                snapshot = old; error = "Heading creation is not available in this workspace yet. Your source and saved draft are unchanged."; return false
            }
            guard TaskKind.permits(change, existing: record(change.table, id: change.recordID)) else {
                snapshot = old
                error = "This task type or checklist needs review before completion. Your work is unchanged."
                return false
            }
            do { try TaskKind.validateCapturedTypeEdit(change, existing: record(change.table, id: change.recordID)) }
            catch { snapshot = old; self.error = error.localizedDescription; return false }
            if let scope = change.teamTaskScope {
                do {
                    guard !localMode, scope.account == userID, scope.origin == (try backend.accountRemovalOrigin) else { throw TeamTaskEditScope.invalid }
                    change = try scope.capturing(change, existing: record("tasks", id: change.recordID))
                } catch { snapshot = old; self.error = error.localizedDescription; return false }
            }
            if change.table == "view_orders" { change = capturingTaskOrderRecovery(change) }
            committedChanges.append(change)
            let before = change.table == "tasks" ? record("tasks", id: change.recordID) : nil
            snapshot.apply(change)
            if localMode {
                TaskActivity.recordLocal(change, before: before, after: record("tasks", id: change.recordID), snapshot: &snapshot, account: userID)
                TaskNodeActivity.recordLocal(change, before: before, after: record("tasks", id: change.recordID), snapshot: &snapshot, account: userID)
                TaskAssignmentProvenance.recordLocal(change, before: before, after: record("tasks", id: change.recordID), snapshot: &snapshot, account: userID)
            }
            if !localMode { snapshot.pending.append(change) }
        }
        if let widgetReceipt { snapshot.widgetCompletion.record(widgetReceipt); snapshot.widgetCompletion.feedback = widgetFeedback }
        if let draft = sharedCaptureReceipt {
            if snapshot.sharedCaptureReceipts == nil { snapshot.sharedCaptureReceipts = [:] }
            snapshot.sharedCaptureReceipts?[draft.taskID] = draft.taskID
        }
        do { try persist() } catch { snapshot = old; self.error = "Your change could not be saved: \(error.localizedDescription)"; return false }
        let historyChanges = committedChanges.filter { $0.table != FocusSessionChange.table }
        if remember, !historyChanges.isEmpty { undoStack.append(EditHistory(changes: historyChanges, snapshot: old)); if undoStack.count > 30 { undoStack.removeFirst() }; redoStack = [] }
        Task { await reschedule(); await sync() }
        return true
    }
    @discardableResult
    func save(_ table: String, _ record: Record, baseline: Record? = nil, applyReminderDefaults: Bool = true) -> Bool {
        let existing = self.record(table, id: record.id)
        if table == "tasks", let existing, let baseline {
            do { try TaskKind.validateTypeEdit(original: baseline, edited: record, current: existing) }
            catch { self.error = error.localizedDescription; return false }
        }
        if table == "projects" {
            let intended = baseline.map { old in record.fields.filter { old.fields[$0.key] != $0.value } } ?? record.fields
            let proposed = Record((existing?.fields ?? [:]).merging(intended) { _, new in new })
            do { try ProjectOrganization.validate(proposed, previous: existing, account: userID, projects: allProjects) }
            catch { self.error = error.localizedDescription; return false }
        }
        if table == WorkflowTemplate.table {
            do { _ = try WorkflowTemplate(document: record["document"]) }
            catch { self.error = error.localizedDescription; return false }
        }
        let record = table == "tasks" && applyReminderDefaults ? applyingReminderDefault(record, previous: baseline ?? existing) : record
        let editable = record.fields.filter { !(table == "projects" && $0.key == "ancestor_archived") && (table != "tasks" || $0.key != "completion_version" && (existing == nil || $0.key != "task_generation")) }
        let changed = (baseline ?? existing).map { old in editable.filter { old.fields[$0.key] != $0.value } } ?? editable
        guard !changed.isEmpty else { return true }
        var changes = [Mutation(table: table, recordID: record.id, method: existing == nil ? "POST" : "PATCH", fields: changed, baseline: baseline.map { old in
            table == WorkflowTemplate.table ? old.fields : table == "tasks" ? TaskCompletionRevision.editBaseline(for: changed, from: old) : Dictionary(uniqueKeysWithValues: changed.keys.map { ($0, old[$0]) })
        })]
        if table == "labels", let existing, existing.name != record.name {
            for task in tasks where TeamTaskLabelsDraft.usesPersonalCatalog(task, cache: nativeConversationTeamCache) {
                let values = TaskLabels.normalized(task["labels"].list, labels: labels)
                // Bind legacy names before the rename; IDs belonging to another label survive.
                if values != task["labels"].list && values.contains(.string(existing.id)) {
                    changes.append(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["labels": .array(values)]))
                }
            }
        }
        #if DEBUG
        if table == "saved_views", assigneePatternFixtureEnabled,
           ProcessInfo.processInfo.arguments.contains("--filter-save-failure-once"), !savedFilterFixtureFailureConsumed {
            savedFilterFixtureFailureConsumed = true; savedFilterFixtureFailNextPersist = true
        }
        #endif
        return commit(changes)
    }
    func isPinnedNote(_ taskID: String) -> Bool { PinnedNotes.contains(taskID, pins: rows("view_orders"), account: userID) }
    /// Task edits and selection reach disk together before any sync begins.
    /// Capture optional recovery evidence without changing the user's row write.
    /// Older/unsupported choices keep their original queue and remain protected.
    func capturingTaskOrderRecovery(_ change: Mutation) -> Mutation {
        var result = change; result.orderRecovery = nil
        guard result.table == "view_orders", !localMode,
              let origin = try? backend.accountRemovalOrigin,
              let captured = try? TaskOrderRecovery.capturing(result, snapshot: snapshot, account: userID, origin: origin) else { return result }
        return captured
    }
    @discardableResult
    func saveTaskWithNotePin(_ task: Record, pin: Bool?, baseline: Record? = nil) -> Bool {
        guard let pin else { return save("tasks", task, baseline: baseline) }
        guard workspaceCacheReadable, signedIn || localMode, PinnedNotes.validID(task.id) else { error = "Open your workspace before pinning notes."; return false }
        guard record("view_orders", id: PinnedNotes.key(task.id)).map({ $0.string("user_id") == userID }) ?? true else { error = "This pin belongs to another workspace."; return false }
        let task = applyingReminderDefault(task, previous: baseline ?? record("tasks", id: task.id))
        let changes = [PinnedNotes.edit(task, existing: record("tasks", id: task.id), baseline: baseline),
                       PinnedNotes.change(taskID: task.id, enabled: pin, pins: rows("view_orders"), account: userID)].compactMap { $0 }
        return changes.isEmpty || commit(changes)
    }
    @discardableResult
    func setPinnedNote(_ taskID: String, enabled: Bool) -> Bool {
        guard workspaceCacheReadable, signedIn || localMode, record("tasks", id: taskID) != nil, PinnedNotes.validID(taskID) else { error = "This note is no longer available in your workspace."; return false }
        guard let change = PinnedNotes.change(taskID: taskID, enabled: enabled, pins: rows("view_orders"), account: userID) else { return isPinnedNote(taskID) == enabled }
        return commit([change])
    }
    func remove(_ table: String, _ id: String) {
        var changes: [Mutation] = []
        if table == "saved_views", record("favorites", id: "view:" + id) != nil { changes.append(Mutation(table: "favorites", recordID: "view:" + id, method: "DELETE", fields: [:])) }
        if table == "labels", let label = record("labels", id: id) {
            for task in tasks where TeamTaskLabelsDraft.usesPersonalCatalog(task, cache: nativeConversationTeamCache) {
                let values = TaskLabels.normalized(task["labels"].list, labels: labels)
                if values.contains(.string(label.id)) {
                    changes.append(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["labels": .array(values.filter { $0 != .string(id) })]))
                }
            }
        }
        if table == "projects" {
            for child in allProjects where child.string("parent_id") == id {
                changes.append(Mutation(table: "projects", recordID: child.id, method: "PATCH", fields: ["parent_id": .null, "ancestor_archived": .bool(false)]))
            }
            for task in tasks where task.string("project_id") == id {
                changes.append(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["project_id": .null, "section_id": .null]))
            }
            for section in rows("sections") where section.string("project_id") == id {
                changes.append(Mutation(table: "sections", recordID: section.id, method: "DELETE", fields: [:]))
            }
        }
        if table == "sections" {
            for task in tasks where task.string("section_id") == id {
                changes.append(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["section_id": .null]))
            }
        }
        changes.append(Mutation(table: table, recordID: id, method: "DELETE", fields: [:]))
        commit(changes)
    }
    /// Source-only local acceptance switch. Normal app configuration omits it;
    /// shared authoring additionally requires negotiated capabilities and live team admission.
    var taskHeadingsAuthoringEnabled: Bool {
        localMode && (Bundle.main.object(forInfoDictionaryKey: "TaskfoldHeadingsEnabled") as? Bool == true)
    }
    private func teamHeadingAuthoringAvailable(_ scope: TeamTaskEditScope?) -> Bool {
        guard let scope, workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              scope.account == userID, scope.origin == (try? backend.accountRemovalOrigin), let cache = nativeConversationTeamCache else { return false }
        return TeamTaskTypes.authoringAvailable(scope: scope, cache: cache, enabled: nativeTeamEditorEnabled && (Bundle.main.object(forInfoDictionaryKey: "TaskfoldHeadingsEnabled") as? Bool == true))
    }
    func canAuthorTaskHeadings(teamDraft: TeamTaskEditorDraft?) -> Bool {
        guard let teamDraft else { return taskHeadingsAuthoringEnabled }
        guard teamHeadingAuthoringAvailable(teamDraft.scope), let cache = nativeConversationTeamCache else { return false }
        return teamDraft.permits(current: record("tasks", id: teamDraft.source.id), workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
    }
    func toggle(_ task: Record) { toggleNativeTask(task) }
    /// Explicit native gesture admission. Shared rows never fall back to the
    /// personal writer if their captured access, source or workspace is unavailable.
    @discardableResult func toggleNativeTask(_ task: Record) -> Bool {
        guard TaskKind.mayComplete(task) else { error = "Headings stay open. Open the heading to edit its details."; return false }
        do {
            if hasSharedTaskSelection([task.id]) {
                let draft = try captureTeamTaskEditor(task)
                guard let cache = nativeConversationTeamCache else { throw TeamTaskEditorDraft.unavailable }
                let change = try draft.completionMutation(current: record("tasks", id: task.id), tasks: tasks,
                    workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration),
                    session: backend.reminderSessionIncarnation, cache: cache, enabled: nativeTeamEditorEnabled)
                return commit([change])
            }
            return commit(toggleChanges(task))
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Completes or reopens several tasks as one undoable change.
    func toggleAll(_ tasks: [Record]) {
        guard tasks.allSatisfy(TaskKind.mayComplete) else { error = "Headings stay open. Select tasks to complete."; return }
        let changes = tasks.flatMap(toggleChanges); if !changes.isEmpty { commit(changes) }
    }
    /// Patches the same fields on several tasks as one undoable change.
    func update(_ ids: [String], fields: [String: JSON]) {
        let changes = ids.compactMap { id -> Mutation? in
            guard let task = record("tasks", id: id) else { return nil }
            let changed = fields.filter { task.fields[$0.key] != $0.value }
            return changed.isEmpty ? nil : Mutation(table: "tasks", recordID: id, method: "PATCH", fields: changed)
        }
        if !changes.isEmpty { commit(changes) }
    }
    /// Deletes several tasks as one undoable change.
    func removeAll(_ ids: [String]) {
        let changes = ids.filter { record("tasks", id: $0) != nil }.map { Mutation(table: "tasks", recordID: $0, method: "DELETE", fields: [:]) }
        if !changes.isEmpty { commit(changes) }
    }
    func toggleChanges(_ task: Record) -> [Mutation] { TaskCompletion.toggle(task, tasks: tasks, account: userID) }
    private func historyChanges(_ changes: [Mutation]) -> [Mutation] {
        changes.map { original in
            var change = TeamCompletion.historyAction(original,snapshot:snapshot)
            if change.table == "view_orders" { change.id = UUID(); change.orderRecovery = nil }
            if change.table == "tasks", change.method == "POST" {
                return TaskGeneration.restoring(change, existing: record("tasks", id: change.recordID))
            }
            guard change.table == "tasks", change.method == "PATCH", let base = change.baseline,
                  let current = record("tasks", id: change.recordID) else { return change }
            var next = change
            next.fields = Dictionary(uniqueKeysWithValues: change.fields.map { key, value in
                (key, TaskEdit.keepingLocal(field: key, base: base[key] ?? .null, desired: value, remote: current[key]))
            })
            next.baseline = nil // commit captures the actual state before applying the rebased inverse.
            return next
        }
    }
    func captureHistoryRequest(_ direction: EditHistoryRequest.Direction = .undo) -> EditHistoryRequest? {
        guard (signedIn || localMode), !signingOut, !accountRemovalBlocked else { return nil }
        return EditHistoryRequest(direction: direction, history: direction == .undo ? undoStack.last : redoStack.last,
            workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation)
    }
    func canApplyHistory(_ request: EditHistoryRequest) -> Bool {
        (signedIn || localMode) && !signingOut && !accountRemovalBlocked && request.matches(direction: request.direction,
            history: request.direction == .undo ? undoStack.last : redoStack.last,
            workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation)
    }
    @discardableResult func undo(_ request: EditHistoryRequest? = nil) -> Bool {
        if let request, request.direction != .undo || !canApplyHistory(request) {
            error = "This Undo belongs to an earlier change or workspace. Use the current Undo controls."; return false
        }
        guard let entry = undoStack.popLast() else { return false }
        let changes = historyChanges(entry.undo), applied = EditHistory(changes: changes, snapshot: snapshot, id: entry.id)
        if commit(changes, remember: false) { redoStack.append(applied.reversed); return true }
        undoStack.append(entry); return false
    }
    @discardableResult func redo(_ request: EditHistoryRequest? = nil) -> Bool {
        if let request, request.direction != .redo || !canApplyHistory(request) {
            error = "This Redo belongs to an earlier change or workspace. Use the current Redo controls."; return false
        }
        guard let entry = redoStack.popLast() else { return false }
        let changes = historyChanges(entry.redo), applied = EditHistory(changes: changes, snapshot: snapshot, id: entry.id)
        if commit(changes, remember: false) { undoStack.append(applied); return true }
        redoStack.append(entry); return false
    }
    /// A denied queued change must not block the refresh that removes revoked shared work.
    /// Keep its complete local snapshot in the encrypted vault before changing the live cache.
    private func recoverUnavailableProject(_ mutation: Mutation, generation: UUID, account: String) async -> Bool {
        guard mutation.teamTaskScope == nil, mutation.teamCompletion == nil, mutation.teamTaskBatch == nil, generation == accountGeneration, snapshot.pending.contains(mutation) else { return false }
        let reviewed = snapshot
        let projectIDs = reviewed.recoveryProjectIDs(for: mutation)
        guard !projectIDs.isEmpty else { return false }
        do {
            var remote: [String: [Record]] = [:]
            for table in ["projects", "tasks", "sections", "labels", "profiles", "project_collaborators", "saved_views", "favorites", "view_preferences", "view_orders", WorkflowTemplate.table, ReminderSnooze.table, "focus_sessions", "task_activity_epoch", "task_activity"] {
                remote[table] = try await backend.rows(table)
                guard generation == accountGeneration, snapshot == reviewed else { return false }
                if table == "projects", projectIDs.allSatisfy({ id in remote[table]!.contains { $0.id.lowercased() == id } }) { return false }
                if table == mutation.table, remote[table]!.contains(where: { $0.id.lowercased() == mutation.recordID.lowercased() }) { return false }
            }
            remote[TaskAssignmentProvenance.table] = await backend.assignmentProvenanceRows()
            if let history = await backend.nodeActivityHistory(expectedAccount: account) { remote.merge(history.tables) { _, new in new } }
            guard generation == accountGeneration, snapshot == reviewed else { return false }
            guard let recovered = reviewed.recoveringUnavailableProject(for: mutation, remote: remote), recovered.pending.count < reviewed.pending.count else { return false }
            _ = try await makeRecoveryBackup(kind: "Access removed")
            guard generation == accountGeneration, account == userID, snapshot == reviewed else { return false }
            markAccessRecovery()
            snapshot = recovered
            do { try persist() } catch { snapshot = reviewed; throw error }
            undoStack = []; redoStack = []; syncConflict = nil; lastSync = Date()
            notice = "A shared project is no longer available. Your unsynced changes were saved in Backups & restore."
            await reschedule()
            if !snapshot.pending.isEmpty { Task { await self.sync() } }
            return true
        } catch { return false }
    }
    func sync() async {
        #if DEBUG
        if (TeamEditorNativeFixture.enabled && !ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-blocked-sync")) || LocationHandoffNativeFixture.enabled { return }
        #endif
        guard workspaceCacheDecoded else {notice="Your saved workspace needs recovery before sync can continue. Its original file is kept.";return}
        consumeWidgetCompletions()
        guard !signingOut, !accountRemovalBlocked, signedIn, !localMode, online, !syncing else { return }
        let hadConflict=syncConflict != nil || focusSyncConflict != nil
        syncing = true; let generation = accountGeneration, account = userID
        var sending: Mutation?
        defer {
            syncing = false
            #if DEBUG
            if TeamBatchRecoveryNativePeer.blockedSync {
                let proof: [String: JSON] = ["completionReview": .bool(syncConflict?.completionReview != nil), "batchReview": .bool(syncConflict?.completionBatchReview != nil), "notice": notice.map(JSON.string) ?? .null, "error": error.map(JSON.string) ?? .null,
                    "windowCount": .number(Double(NSApp.windows.count)), "visibleWindows": .number(Double(NSApp.windows.filter(\.isVisible).count))]
                try? JSONEncoder().encode(proof).write(to: TeamBatchRecoveryNativePeer.traceFile.deletingLastPathComponent().appendingPathComponent("taskfold-cold-discovery-diagnostic.json"), options: .atomic)
            }
            #endif
            if let retry = syncAfterSignInRequested {
                syncAfterSignInRequested = nil
                Task { await self.resumeSyncAfterSignIn(workspace: retry) }
            }
        }
        do {
            let boundary:TeamWorkspaceBoundary?
            let allowLegacy=snapshot.teamWorkspace==nil && !snapshot.pending.contains{$0.teamTaskScope != nil || $0.teamCompletion != nil || $0.teamTaskBatch != nil}
            do {boundary=try await backend.workspaceBoundary(account:account)}
            catch is TeamWorkspaceUnavailable {guard allowLegacy else {throw TeamWorkspaceUnavailable()};boundary=nil}
            guard generation==accountGeneration else {return}
            if boundary==nil && hadConflict {await syncConversations();return}
            let access=try boundary.map{try TeamWorkspaceCache(boundary:$0,previous:snapshot.teamWorkspace,pending:snapshot.pending,tasks:snapshot.tables["tasks"] ?? [])}
            if let access,access.requiresRecovery(snapshot) {
                teamAccessMask=access
                if let fence=teamAccessFenceDisk,let boundary {
                    try await Task.detached(priority:.utility){try fence.save(boundary)}.value
                    guard generation==accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
                }
            }
            let initialRequests=Set(snapshot.pending.map(\.id)),blockedRequests=access?.blocked(snapshot) ?? []
            while !hadConflict,let mutation = snapshot.pending.first {
                if blockedRequests.contains(mutation.id) || (!initialRequests.contains(mutation.id) && access?.canSend(mutation,in:snapshot)==false) {
                    if let access, try await discoverBlockedTeamCompletion(access: access) { return }
                    break
                }
                sending = mutation
                let saved = try await backend.send(mutation, expectedAccount: account)
                guard generation == accountGeneration else { return }
                guard snapshot.acknowledge(mutation, saved: saved) else { throw TeamCompletion.conflict }
                try persist()
                if let command=mutation.teamCompletion,command.operation == .undo,let saved,
                   case .object(let raw)=saved["team_completion_reply"],let receipt=try? command.receipt(raw,for:mutation),
                   !receipt.removed,receipt.successor != nil,
                   !snapshot.pending.contains(where:{$0.teamCompletion?.source.id == command.source.id}),
                   record("tasks",id:command.source.id)?["task_generation"] == command.source["task_generation"],
                   record("tasks",id:command.source.id)?.completed == false {
                    notice = "Task reopened. The next occurrence was kept."
                }
            }
            let read=try await backend.workspaceRead(account:account,initial:boundary,allowLegacy:allowLegacy)
            guard generation==accountGeneration else {return}
            if let boundary=read.boundary {
                let cache=try TeamWorkspaceCache(boundary:boundary,previous:snapshot.teamWorkspace,pending:snapshot.pending,tasks:(snapshot.tables["tasks"] ?? [])+(read.tables["tasks"] ?? []))
                let before=snapshot,protect=cache.requiresRecovery(before)
                if protect {
                    teamAccessMask=cache
                    if let fence=teamAccessFenceDisk {
                        try await Task.detached(priority:.utility){try fence.save(boundary)}.value
                        guard generation==accountGeneration,!signingOut,!accountRemovalBlocked,snapshot==before else {throw TeamWorkspaceChanged()}
                    }
                    _=try await makeRecoveryBackup(kind:"Before team access refresh")
                    guard generation==accountGeneration,!signingOut,!accountRemovalBlocked,snapshot==before else {throw TeamWorkspaceChanged()}
                }
                if hadConflict && !protect {
                    // Keep a current review's optimistic drafts untouched until
                    // its explicit resolution; only cull inaccessible content.
                    snapshot.tables=cache.filtering(snapshot.tables);snapshot.teamWorkspace=cache
                } else {snapshot=cache.merging(read.tables,into:snapshot)}
                do {try persist()} catch {snapshot=before;throw error}
                if let fence=teamAccessFenceDisk {try fence.clear(after:boundary)}
                let wasUnreadable = !workspaceCacheReadable
                workspaceCacheReadable=true
                if teamAccessMask != nil {teamAccessMask=nil}
                else if wasUnreadable {publishWidgetSnapshot(scheduleCapacityRefresh:false)}
                if protect {
                    undoStack=[];redoStack=[];syncConflict=nil;markAccessRecovery()
                    notice="Project access changed. Your queued work is kept, and a Recovery copy is saved."
                }
            } else {snapshot.mergeRemote(read.tables);try persist()}
            lastSync=Date();migrateOrganization()
            await syncConversations()
            if !avatarMetadataLoaded {
                do { try await backend.refreshUser(); if generation == accountGeneration { avatarMetadataLoaded = true } }
                catch { /* Optional avatar refresh must not interrupt task synchronization. */ }
            }
            guard generation == accountGeneration else { return }
            googleAvatarURL = backend.session?.user.googleAvatarURL
            await reschedule()
        } catch {
            if !(error is TeamTaskReviewRequired), let mutation = sending, await recoverUnavailableProject(mutation, generation: generation, account: account) { return }
            if generation == accountGeneration {
                syncSignInWorkspace = error is AccountSessionAuthorizationRequired ? WorkspaceBinding(account:account,generation:generation) : nil
                notice = SyncStatus.failureMessage(error)
                if let mutation = sending, mutation.teamTaskBatch?.isCompletion == true,
                   !(error is CancellationError), !(error is AccountSessionAuthorizationRequired),
                   let review = try? await backend.reviewTeamCompletionBatch(mutation, expectedAccount: account),
                   generation == accountGeneration, snapshot.pending.first == mutation {
                    installTeamCompletionBatchReview(review)
                    notice = "Your task selection is saved. Review its sync status to continue."; return
                }
                if let mutation=sending,mutation.teamCompletion != nil,
                   !(error is CancellationError),!(error is AccountSessionAuthorizationRequired),
                   let review=try? await backend.reviewTeamCompletion(mutation,expectedAccount:account),
                   generation == accountGeneration,snapshot.pending.first == mutation {
                    syncConflict=SyncConflict(mutation:mutation,remote:review.task ?? mutation.teamCompletion!.source,completionReview:review)
                    notice="Your completion is saved. Review its sync status to continue."
                    return
                }
                if error.localizedDescription.contains("TASKFOLD_FOCUS_CONFLICT:"), let mutation = sending,
                   mutation.table == FocusSessionChange.table,
                   let data = try? await backend.request("/rest/v1/focus_sessions?id=eq.current&select=*"),
                   let remoteRows = try? JSONDecoder().decode([Record].self, from: data),
                   generation == accountGeneration, snapshot.pending.contains(mutation) {
                    let remote = remoteRows.first ?? FocusSessionChange.emptyRow(account: userID)
                    guard FocusSessionChange.validRow(remote, account: userID) else { return }
                    focusSyncConflict = FocusSyncConflict(mutation: mutation, remote: remote)
                    Task { await reschedule() }
                    publishWidgetSnapshot(scheduleCapacityRefresh: false)
                    notice = "Focus changed on another device. Open Focus session to review it and resume sync."
                }
                if error.localizedDescription.contains("TASKFOLD_CONFLICT:"),let mutation=sending,ProductivityGoalEdit.matches(mutation),
                   let data=try? await backend.request("/rest/v1/view_preferences?id=eq.insights&select=*",expectedAccount:account),
                   let rows=try? JSONDecoder().decode([Record].self,from:data),generation==accountGeneration,snapshot.pending.contains(mutation) {
                    let remote=rows.first ?? ProductivityGoalEdit.emptyRow(account:account)
                    if remote.id==ProductivityGoals.recordID,remote.string("user_id")==account {
                        syncConflict=SyncConflict(mutation:mutation,remote:remote);notice="Goals changed on another device. Review both choices to resume sync."
                    }
                }
                if error.localizedDescription.contains("TASKFOLD_CONFLICT:"), let mutation=sending,mutation.table==WorkflowTemplate.table,
                   let escaped=mutation.recordID.addingPercentEncoding(withAllowedCharacters:.alphanumerics),
                   let data=try? await backend.request("/rest/v1/project_templates?id=eq.\(escaped)&select=*"),
                   let rows=try? JSONDecoder().decode([Record].self,from:data),generation==accountGeneration,snapshot.pending.contains(mutation) {
                    syncConflict=SyncConflict(mutation:mutation,remote:rows.first ?? Record(["id":.string(mutation.recordID),"name":.string("Deleted template")]))
                    notice="This template changed on another device. Review it to resume sync."
                }
                if error.localizedDescription.contains("TASKFOLD_CONFLICT:"), let mutation = sending,
                   mutation.table == "tasks", ["PATCH", "DELETE"].contains(mutation.method),
                   let escaped = mutation.recordID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                   let data = try? await backend.request("/rest/v1/tasks?id=eq.\(escaped)&select=*"),
                   let remote = try? JSONDecoder().decode([Record].self, from: data).first,
                   generation == accountGeneration, snapshot.pending.contains(mutation),
                   remote.id.lowercased() == mutation.recordID.lowercased() {
                    syncConflict = SyncConflict(mutation: mutation, remote: remote)
                    notice = mutation.method == "DELETE" ? "This task changed before deletion. Review it to resume sync." : "Changes overlap on the same task. Review this edit to resume sync."
                }
            }
            return
        }
        guard generation == accountGeneration else { return }
        syncSignInWorkspace = nil
        let accessBlocked=snapshot.pending.first.map{snapshot.teamWorkspace?.blocked(snapshot).contains($0.id)==true} ?? false
        if !accessBlocked && !hadConflict {notice = widgetActionStatus}
        // A blocked head needs review, not an immediate busy retry loop.
        if !snapshot.pending.isEmpty && !accessBlocked && syncConflict==nil && focusSyncConflict==nil {Task {await self.sync()}}
    }
    /// Only fill missing remote rows after a successful fetch. Existing synchronized choices win.
    private func migrateOrganization() {
        let legacyOrders = rows("_local_day_order").filter { record(DayPlacement.table, id: $0.id) == nil }.map { row in
            Mutation(table: DayPlacement.table, recordID: row.id, method: "POST", fields: ["id": .string(row.id), "user_id": .string(userID), "ids": row["ids"]])
        }
        if !legacyOrders.isEmpty { _ = commit(legacyOrders, remember: false) }
        let defaults = UserDefaults.standard
        let fixture = userID == "ui-testing" || userID == "preview"
        let ownerKey = "taskfold.legacyViewPreferencesOwner" + (fixture ? ".fixture" : "")
        if defaults.string(forKey: ownerKey) == nil { defaults.set(userID, forKey: ownerKey) }
        guard defaults.string(forKey: ownerKey) == userID else { return }
        #if os(macOS)
        let scopes = [TaskScope.today, .inbox, .upcoming, .all, .completed] + projects.map { .project($0.id) } + labels.map { .label($0.id) }
        for scope in scopes where record("view_preferences", id: scope.preferenceKey) == nil {
            let prefix = "mac.view." + scope.preferenceKey + "."
            var fields: [String: JSON] = ["id": .string(scope.preferenceKey), "user_id": .string(userID)]
            for (old, field) in [("layout","layout"),("sortBy","sort_by")] {
                if let value = defaults.string(forKey: prefix + old) { fields[field] = .string(value) }
            }
            for (old, field) in [("showCompleted","include_completed"),("overdueCollapsed","overdue_collapsed")] {
                if defaults.object(forKey: prefix + old) != nil { fields[field] = .bool(defaults.bool(forKey: prefix + old)) }
            }
            if defaults.object(forKey: prefix + "priorityFilter") != nil { fields["priority_filter"] = .number(Double(defaults.integer(forKey: prefix + "priorityFilter"))) }
            if fields.count > 2 { _ = save("view_preferences", Record(fields)) }
        }
        #else
        for (scope, key) in [(TaskScope.today, "overdueCollapsedToday"), (.upcoming, "overdueCollapsedUpcoming")] where record("view_preferences", id: scope.preferenceKey) == nil {
            if defaults.object(forKey: key) != nil {
                _ = save("view_preferences", Record(["id": .string(scope.preferenceKey), "user_id": .string(userID), "overdue_collapsed": .bool(defaults.bool(forKey: key))]))
            }
        }
        #endif
    }
    func reviewSavedTeamDraft(_ draft:TeamCompletionDraft,command:TeamCompletionDraft.CopyCommand) async throws -> TeamCompletionDraft.CopyReview {
        let generation=accountGeneration,account=userID
        guard let vault=teamDraftVault,draft.scope.account == account,draft.scope.origin == vault.origin,
              snapshot.tables["projects"]?.contains(where:{$0.id == draft.scope.project}) == true else {
            throw AppFailure(message:"Reopen the original project to review a task copy. Your draft is kept.")
        }
        let saved=try await Task.detached(priority:.utility){try vault.load(draft.id)}.value
        guard generation == accountGeneration,!signingOut,!accountRemovalBlocked,saved.sameWork(as:draft),
              saved.copyAttempt == nil || saved.copyAttempt == command else {throw TeamCompletionDraft.invalid}
        let review=try await backend.copyTeamDraft(saved,command:command,commit:false,expectedAccount:account)
        guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
        if review.cancelled,saved.copyAttempt == command {
            try await Task.detached(priority:.utility){try vault.clearCopyAttempt(saved,proof:review)}.value
            guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
        }
        return review
    }
    func createSavedTeamDraftCopy(_ draft:TeamCompletionDraft,review:TeamCompletionDraft.CopyReview) async throws -> TeamCompletionDraft.CopyReview {
        let generation=accountGeneration,account=userID
        guard let vault=teamDraftVault,draft.scope.account == account,draft.scope.origin == vault.origin,review.matches(draft),
              snapshot.tables["projects"]?.contains(where:{$0.id == draft.scope.project}) == true else {throw TeamCompletionDraft.invalid}
        _=try await makeRecoveryBackup(kind:"Before copying team draft")
        guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
        let saved=try await Task.detached(priority:.utility){try vault.prepareCopy(draft,command:review.command)}.value
        guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
        let result=try await backend.copyTeamDraft(saved,command:review.command,commit:true,expectedAccount:account)
        guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
        if result.cancelled {
            try await Task.detached(priority:.utility){try vault.clearCopyAttempt(saved,proof:result)}.value
            guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
            return result
        }
        // An in-flight workspace read may predate this server write. Let its
        // authorized refresh finish rather than inserting a row it could then
        // erase. The same copy remains recoverable through the saved request.
        if !syncing,let next=result.installing(in:snapshot) {
            let before=snapshot;snapshot=next
            do {try persist()} catch {snapshot=before;throw error}
        }
        // The draft and frozen request remain encrypted even after success.
        // A retry reads the same copy; it never rewinds local edits or recreates
        // a deleted/replaced task. Ordinary sync can refresh other shared work.
        notice=result.task == nil ? "This task copy is no longer available. Your saved draft is kept." : "Task copy saved. Your original draft is kept."
        return result
    }

    func cancelSavedTeamDraftCopy(_ draft:TeamCompletionDraft,command:TeamCompletionDraft.CopyCommand) async throws -> TeamCompletionDraft.CopyReview {
        let generation=accountGeneration,account=userID
        guard let vault=teamDraftVault,draft.scope.account == account,draft.scope.origin == vault.origin else {throw CancellationError()}
        let saved=try await Task.detached(priority:.utility){try vault.load(draft.id)}.value
        guard generation == accountGeneration,!signingOut,!accountRemovalBlocked,saved.sameWork(as:draft),saved.copyAttempt == command else {throw TeamCompletionDraft.invalid}
        let result=try await backend.copyTeamDraft(saved,command:command,commit:false,cancel:true,expectedAccount:account)
        guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
        if result.cancelled {
            try await Task.detached(priority:.utility){try vault.clearCopyAttempt(saved,proof:result)}.value
            guard generation == accountGeneration,!signingOut,!accountRemovalBlocked else {throw CancellationError()}
        }
        return result
    }

    @discardableResult func parkTeamCompletionDraft(_ expected:TeamCompletion.Review) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        let session = backend.reminderSessionIncarnation
        let generation=accountGeneration,account=userID,before=snapshot,access=nativeConversationTeamCache,revision=workspaceReadRevision
        guard currentTeamCompletionReview(expected),let access,let candidate=TeamCompletionDraft.Candidate(review:expected,snapshot:before),let vault=teamDraftVault,
              candidate.draft.scope.account == account,candidate.draft.scope.origin == vault.origin else {return false}
        do {
            _=try await makeRecoveryBackup(kind:"Before saving team draft")
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation,!signingOut,!accountRemovalBlocked,snapshot == before,revision == workspaceReadRevision,nativeConversationTeamCache == access,currentTeamCompletionReview(expected) else {return false}
            _=try await Task.detached(priority:.utility){try vault.save(candidate.draft)}.value
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation,!signingOut,!accountRemovalBlocked,snapshot == before,revision == workspaceReadRevision,nativeConversationTeamCache == access,currentTeamCompletionReview(expected) else {return false}
            let proof=try await backend.retireTeamProvisional(expected.mutation,expectedAccount:account)
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation,!signingOut,!accountRemovalBlocked,snapshot == before,revision == workspaceReadRevision,nativeConversationTeamCache == access,currentTeamCompletionReview(expected) else {return false}
            guard let projected=candidate.parking(snapshot,proof:proof), let next=access.retainingRecoveryAccess(in:projected,from:before) else {
                syncConflict=SyncConflict(mutation:expected.mutation,remote:proof.review.task ?? expected.mutation.teamCompletion!.source,completionReview:proof.review)
                recordTeamCompletionReviewFailure("Your draft is saved. The shared task changed; check the current review before continuing.", origin: presentation);return false
            }
            snapshot=next
            do {try persist()} catch {snapshot=before;recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation);return false}
            undoStack=[];redoStack=[];syncConflict=nil;notice="Edits kept in Saved team drafts. Sync can continue."
            Task {await sync()};return true
        } catch {
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionReview(expected) else {return false}
            recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation);return false
        }
    }

    @discardableResult func parkConnectedTeamCompletionDraft(_ expected: TeamCompletionReviewPresentation) async -> Bool {
        guard expected == teamCompletionReviewPresentation, let initial = syncConflict?.completionReview,
              currentTeamCompletionReview(initial), initial.isRecorded,
              let access = nativeConversationTeamCache, let copyVault = teamDraftVault,
              let archiveVault = teamRecordedRecoveryVault else { return false }
        let generation = accountGeneration, session = backend.reminderSessionIncarnation, account = userID
        let before = snapshot, revision = workspaceReadRevision
        var observed = initial
        func unchanged() -> Bool {
            generation == accountGeneration && session == backend.reminderSessionIncarnation && before == snapshot &&
            revision == workspaceReadRevision && nativeConversationTeamCache == access && currentTeamCompletionReview(observed) &&
            syncConflict?.completionBatchReview == expected.group && teamCompletionReviewMayFinish(expected)
        }
        do {
            let candidate = try await Task.detached(priority: .userInitiated) {
                guard let value = TeamConnectedProvisionalDraft(review: initial, snapshot: before),
                      value.recovery.preserving(readable: access) != nil else { throw TeamCompletionDraft.invalid }
                return value
            }.value
            guard unchanged() else { return false }
            _ = try await makeRecoveryBackup(kind: "Before saving connected recurring draft")
            guard unchanged() else { return false }
            let saved = try await Task.detached(priority: .utility) { () -> (TeamCompletionRecoveryDraft, TeamCompletionDraft) in
                let archive = try archiveVault.save(candidate.recovery)
                let copy = try copyVault.saveConnected(candidate.copy, recovery: archive)
                guard archive.sameWork(as: candidate.recovery), copy.original == candidate.copy.original,
                      copy.record == candidate.copy.record, copy.connectedRecoveryIDs?.contains(archive.id) == true else { throw TeamCompletionDraft.invalid }
                return (archive, copy)
            }.value
            guard unchanged() else { return false }
            // Existing actor-bound retirement only; this never creates a task copy.
            let proof = try await backend.retireTeamProvisional(initial.mutation, expectedAccount: account)
            guard unchanged() else { return false }
            syncConflict = SyncConflict(mutation: proof.review.mutation, remote: proof.review.task ?? initial.mutation.teamCompletion!.source, completionReview: proof.review)
            observed = proof.review
            let next = try await Task.detached(priority: .utility) { () -> Snapshot in
                let archive = try archiveVault.recordProvisionalRetirement(saved.0, proof: proof)
                let copy = try copyVault.load(saved.1.id)
                guard archive.provisionalRetirements?.last == proof.response,
                      copy.original == candidate.copy.original, copy.record == candidate.copy.record,
                      copy.connectedRecoveryIDs?.contains(archive.id) == true,
                      let projection = candidate.parking(proof: proof, readable: access) else { throw TeamCompletionDraft.invalid }
                return projection
            }.value
            guard unchanged() else { return false }
            snapshot = next
            do { try persist() } catch { snapshot = before; recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: expected); return false }
            undoStack = []; redoStack = []; syncConflict = nil
            notice = "Recurring draft kept. Review its task copy and connected saved edits in Saved team drafts."
            Task { await sync() }; return true
        } catch {
            guard unchanged() else { return false }
            recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: expected); return false
        }
    }

    @discardableResult func cancelTeamCompletionReview(_ expected:TeamCompletion.Review) async -> Bool {
        await resolveTeamCompletionReview(expected,rebase:false)
    }
    @discardableResult func rebaseTeamCompletionReview(_ expected:TeamCompletion.Review) async -> Bool {
        await resolveTeamCompletionReview(expected,rebase:true)
    }
    private func resolveTeamCompletionReview(_ expected:TeamCompletion.Review,rebase:Bool) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        let session = backend.reminderSessionIncarnation
        let generation=accountGeneration,account=userID,before=snapshot,access=nativeConversationTeamCache,revision=workspaceReadRevision
        guard currentTeamCompletionReview(expected), let access,
              (rebase ? expected.canRequestRebase(before):expected.canRequestCancellation(before)),
              let command=expected.mutation.teamCompletion,command.scope.account == account,
              command.scope.origin == (try? backend.accountRemovalOrigin),!signingOut, !rebase || access.canSend(expected.mutation, in: before) else {return false}
        var observedReview = expected
        do {
            _=try await makeRecoveryBackup(kind:"Before sync review")
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation,snapshot == before,revision == workspaceReadRevision,nativeConversationTeamCache == access,currentTeamCompletionReview(expected) else {return false}
            let review: TeamCompletion.Review
            if expected.isCancelled { review = expected }
            else { review = try await backend.cancelTeamCompletion(expected.mutation,expectedAccount:account) }
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation,snapshot == before,revision == workspaceReadRevision,nativeConversationTeamCache == access,currentTeamCompletionReview(expected) else {return false}
            syncConflict=SyncConflict(mutation:expected.mutation,remote:review.task ?? command.source,completionReview:review)
            observedReview = review
            guard review.isCancelled else {
                notice="This action had already synced. Review its result to continue.";return false
            }
            let next:Snapshot
            let history:EditHistory?
            if rebase {
                guard review.matchesRebaseObservation(expected),let plan=review.rebasing(snapshot, readable: access) else {
                    notice="Task access or content changed. Review the current task before applying your action.";return false
                }
                next=plan.snapshot;history=EditHistory(changes:[plan.action],snapshot:plan.base)
            } else {
                guard let cancelled=review.cancelling(snapshot, readable: access) else {
                    notice="Your action was cancelled. Additional changes remain saved for review.";return false
                }
                next=cancelled;history=nil
            }
            let old=snapshot;snapshot=next
            do {try persist()} catch {snapshot=old;recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation);return false}
            undoStack=history.map{[$0]} ?? [];redoStack=[];syncConflict=nil
            notice=rebase ? "Your reviewed action is saved and ready to sync." : "Synced task kept. A recovery copy is saved."
            Task {await sync()};return true
        } catch {
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionReview(observedReview) else {return false}
            recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation);return false
        }
    }

    /// Inspect a blocked immutable completion before a workspace merge can replace
    /// its optimistic projection. This never calls a completion writer.
    private func discoverBlockedTeamCompletion(access: TeamWorkspaceCache) async throws -> Bool {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              syncConflict == nil, focusSyncConflict == nil, access.boundary.account == userID,
              access.boundary.origin == (try? backend.accountRemovalOrigin) else { return false }
        let generation = accountGeneration, before = snapshot, initialAccess = nativeConversationTeamCache, initialRevision = workspaceReadRevision, account = userID
        let requests = await Task.detached(priority: .userInitiated) { (TeamCompletionBatchDiscovery(snapshot: before, access: access), TeamCompletionDiscovery(snapshot: before, access: access)) }.value
        guard generation == accountGeneration, snapshot == before, initialRevision == workspaceReadRevision,
              nativeConversationTeamCache == initialAccess, !signingOut, !accountRemovalBlocked,
              syncConflict == nil, focusSyncConflict == nil else { throw CancellationError() }
        guard requests.0 != nil || requests.1 != nil else { return false }
        if teamAccessMask != access { teamAccessMask = access }
        let revision = workspaceReadRevision
        let groupReview: TeamTaskBatch.Review?
        let singleReview: TeamCompletion.Review?
        if let request = requests.0 {
            groupReview = try await backend.reviewTeamCompletionBatch(request.mutation, expectedAccount: account); singleReview = nil
        } else if let request = requests.1 {
            singleReview = try await backend.reviewTeamCompletion(request.mutation, expectedAccount: account); groupReview = nil
        } else { return false }
        guard generation == accountGeneration, snapshot == before, revision == workspaceReadRevision,
              nativeConversationTeamCache == access, !signingOut, !accountRemovalBlocked,
              syncConflict == nil, focusSyncConflict == nil else { throw CancellationError() }
        if let request = requests.0, let review = groupReview, let terminal = request.terminal(review, current: snapshot, readable: access) {
            installTeamCompletionBatchReview(terminal)
            notice = terminal.isCancelled ? "This saved task selection was cancelled. Review your work to continue." : "This task selection already synced. Review its result to continue."
        } else if let request = requests.1, let review = singleReview, let terminal = request.terminal(review, current: snapshot, readable: access) {
            syncConflict = SyncConflict(mutation: terminal.mutation, remote: terminal.task ?? terminal.mutation.teamCompletion!.source, completionReview: terminal)
            notice = terminal.isCancelled ? "This saved task action was cancelled. Review your work to continue." : "This task action already synced. Review its result to continue."
        } else { return false }
        return true
    }

    var teamCompletionReviewPresentation: TeamCompletionReviewPresentation {
        TeamCompletionReviewPresentation(workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, snapshot: snapshot, access: nativeConversationTeamCache, revision: workspaceReadRevision, errorRevision: teamCompletionErrorRevision, single: syncConflict?.completionReview, group: syncConflict?.completionBatchReview)
    }
    func teamCompletionReviewMayFinish(_ context: TeamCompletionReviewPresentation) -> Bool {
        context.matchesWorkspace(WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation) && signedIn && !localMode && !signingOut && !accountRemovalBlocked && (syncConflict == nil || syncConflict?.id == context.request)
    }
    private func recordTeamCompletionReviewFailure(_ message: String, origin: TeamCompletionReviewPresentation) {
        guard teamCompletionReviewMayFinish(origin), teamCompletionErrorRevision == origin.errorRevision else { return }
        error = message
        teamCompletionReviewFailure = TeamCompletionReviewFailure(origin: origin, current: teamCompletionReviewPresentation, message: message)
    }
    func takeTeamCompletionReviewFailure(_ context: TeamCompletionReviewPresentation, fallback: String) -> String? {
        guard teamCompletionReviewMayFinish(context) else { return nil }
        if let failure = teamCompletionReviewFailure, failure.mayConsume(origin: context, current: teamCompletionReviewPresentation, error: error) {
            let message = failure.message; error = nil; return message
        }
        guard context.ownsFailure(workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, snapshot: snapshot, access: nativeConversationTeamCache, revision: workspaceReadRevision, single: syncConflict?.completionReview, group: syncConflict?.completionBatchReview) else {
            return "The review changed while it was being checked. Check the current result before continuing."
        }
        return fallback
    }

    /// Local acceptance only: the recorded receipt is already authoritative.
    /// Durable safety copies and current read access precede retiring any intent.
    @discardableResult func preserveRecordedCompletionDraft(_ expected: TeamCompletionReviewPresentation) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        guard expected == presentation else { return false }
        let generation = accountGeneration, session = backend.reminderSessionIncarnation
        let before = snapshot, access = nativeConversationTeamCache, revision = workspaceReadRevision
        let single = syncConflict?.completionReview, group = syncConflict?.completionBatchReview
        guard let access, let vault = teamRecordedRecoveryVault,
              single.map({ currentTeamCompletionReview($0) && $0.isRecorded }) ?? group.map({ currentTeamCompletionBatchReview($0) && $0.isRecorded }) ?? false else { return false }
        func unchanged() -> Bool {
            generation == accountGeneration && session == backend.reminderSessionIncarnation && before == snapshot &&
            revision == workspaceReadRevision && nativeConversationTeamCache == access &&
            syncConflict?.completionReview == single && syncConflict?.completionBatchReview == group &&
            teamCompletionReviewMayFinish(presentation)
        }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) { () -> (TeamCompletionRecoveryDraft, Snapshot) in
                let draft: TeamCompletionRecoveryDraft
                if let single { draft = try TeamCompletionRecoveryDraft(single: single, snapshot: before) }
                else if let group { draft = try TeamCompletionRecoveryDraft(group: group, snapshot: before) }
                else { throw TeamCompletionRecoveryDraft.invalid }
                guard let next = draft.preserving(readable: access) else { throw TeamCompletionRecoveryDraft.invalid }
                return (draft, next)
            }.value
            guard unchanged() else { return false }
            _ = try await makeRecoveryBackup(kind: "Before keeping recorded edits")
            guard unchanged() else { return false }
            let saved = try await Task.detached(priority: .utility) { try vault.save(prepared.0) }.value
            guard unchanged(), saved.sameWork(as: prepared.0) else { return false }
            snapshot = prepared.1
            do { try persist() } catch { snapshot = before; recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false }
            undoStack = []; redoStack = []; syncConflict = nil
            notice = "Edits kept in Saved team drafts. Sync can continue."
            Task { await sync() }; return true
        } catch {
            guard unchanged() else { return false }
            recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false
        }
    }

    /// A saved preflight is not a cancellation certificate. Retain the actual
    /// terminal reply in the encrypted archive and verify it before local retirement.
    @discardableResult func preserveCancelledCompletionDraft(_ expected: TeamCompletionReviewPresentation) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        guard expected == presentation, let initial = syncConflict?.completionReview,
              currentTeamCompletionReview(initial), !initial.isRecorded,
              let access = nativeConversationTeamCache, let vault = teamCancelledRecoveryVault else { return false }
        let generation = accountGeneration, session = backend.reminderSessionIncarnation, account = userID
        let before = snapshot, revision = workspaceReadRevision
        var observed = initial
        func unchanged() -> Bool {
            generation == accountGeneration && session == backend.reminderSessionIncarnation && before == snapshot &&
            revision == workspaceReadRevision && nativeConversationTeamCache == access && currentTeamCompletionReview(observed) &&
            syncConflict?.completionBatchReview == presentation.group && teamCompletionReviewMayFinish(presentation)
        }
        do {
            let draft = try await Task.detached(priority: .userInitiated) {
                let draft = try TeamCompletionRecoveryDraft(single: initial, snapshot: before)
                guard draft.previewCancellation(readable: access) != nil else { throw TeamCompletionRecoveryDraft.invalid }
                return draft
            }.value
            guard unchanged() else { return false }
            _ = try await makeRecoveryBackup(kind: "Before cancelling saved action")
            guard unchanged() else { return false }
            let saved = try await Task.detached(priority: .utility) { try vault.save(draft) }.value
            guard unchanged(), saved.sameWork(as: draft) else { return false }
            let proof: TeamCompletion.Review
            if initial.isCancelled { proof = initial }
            else { proof = try await backend.cancelTeamCompletion(initial.mutation, expectedAccount: account) }
            guard unchanged() else { return false }
            syncConflict = SyncConflict(mutation: proof.mutation, remote: proof.task ?? proof.mutation.teamCompletion!.source, completionReview: proof)
            observed = proof
            guard proof.isCancelled else {
                let message = "This action already synced. Your draft is kept; review the recorded result to continue."
                notice = message; recordTeamCompletionReviewFailure(message, origin: presentation); return false
            }
            let prepared = try await Task.detached(priority: .utility) { () -> (TeamCompletionRecoveryDraft, Snapshot) in
                let verified = try vault.recordCancellation(saved, proof: proof)
                guard verified.cancellations?.last == proof.response, let next = verified.preserving(readable: access) else { throw TeamCompletionRecoveryDraft.invalid }
                return (verified, next)
            }.value
            guard unchanged(), prepared.0.sameWork(as: draft) else { return false }
            snapshot = prepared.1
            do { try persist() } catch { snapshot = before; recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false }
            undoStack = []; redoStack = []; syncConflict = nil
            notice = "Saved action cancelled. Your edits are kept in Saved team drafts."
            Task { await sync() }; return true
        } catch {
            guard unchanged() else { return false }
            recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false
        }
    }

    func currentTeamCompletionBatchReview(_ review: TeamTaskBatch.Review) -> Bool {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              syncConflict?.completionBatchReview == review, snapshot.pending.first == review.mutation,
              let batch = review.mutation.teamTaskBatch, batch.account == userID,
              batch.origin == (try? backend.accountRemovalOrigin), let cache = nativeConversationTeamCache,
              cache.boundary.belongs(account: batch.account, origin: batch.origin),
              cache.boundary.raw["native_team_reads_enabled"] == .bool(true),
              cache.boundary.raw["teams"]?.list.contains(where: { $0.object["id"] == .string(batch.team) && $0.object["state"] == .string("active") }) == true else { return false }
        return batch.items.allSatisfy { item in
            guard let command = item.teamCompletion else { return false }
            return [command.scope.project, command.seriesProject].allSatisfy { cache.boundary.projects[$0]?.team == batch.team }
        }
    }
    private func installTeamCompletionBatchReview(_ review: TeamTaskBatch.Review) {
        syncConflict = SyncConflict(mutation: review.mutation, remote: review.members.first?.task ?? review.mutation.teamTaskBatch!.items[0].teamCompletion!.source, completionBatchReview: review)
    }
    @discardableResult func refreshTeamCompletionBatchReview(_ expected: TeamTaskBatch.Review) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        let session = backend.reminderSessionIncarnation
        let generation = accountGeneration, account = userID, before = snapshot, access = nativeConversationTeamCache, revision = workspaceReadRevision
        guard currentTeamCompletionBatchReview(expected) else { return false }
        do {
            let review = try await backend.reviewTeamCompletionBatch(expected.mutation, expectedAccount: account)
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(expected) else { return false }
            installTeamCompletionBatchReview(review); return true
        } catch {
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(expected) else { return false }
            recordTeamCompletionReviewFailure(SyncStatus.failureMessage(error), origin: presentation); return false
        }
    }
    @discardableResult func continueTeamCompletionBatchReview(_ review: TeamTaskBatch.Review) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        let session = backend.reminderSessionIncarnation
        let generation = accountGeneration, before = snapshot
        guard currentTeamCompletionBatchReview(review), !review.isCancelled else { return false }
        if review.isRecorded {
            guard let access = nativeConversationTeamCache else { return false }
            let readRevision = workspaceReadRevision
            let next = await Task.detached(priority: .userInitiated) { review.acknowledging(before, readable: access) }.value
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, readRevision == workspaceReadRevision,
                  nativeConversationTeamCache == access, currentTeamCompletionBatchReview(review) else { return false }
            guard let next else { recordTeamCompletionReviewFailure("Later task changes still need review. The entire saved selection and its drafts are kept.", origin: presentation); return false }
            snapshot = next
            do { try persist() } catch { snapshot = before; recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false }
            undoStack = []; redoStack = []
        }
        syncConflict = nil; notice = nil; Task { await sync() }; return true
    }
    @discardableResult func cancelTeamCompletionBatchReview(_ expected: TeamTaskBatch.Review) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        let session = backend.reminderSessionIncarnation
        let generation = accountGeneration, before = snapshot, account = userID
        guard currentTeamCompletionBatchReview(expected), !expected.isRecorded, let access = nativeConversationTeamCache else { return false }
        let revision = workspaceReadRevision
        var observedReview = expected
        do {
            var savedDraft: TeamCompletionBatchDraft?
            let independent = await Task.detached(priority: .userInitiated) { expected.canRequestCancellation(before) }.value
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(expected) else { return false }
            if !independent {
                guard let vault = teamSelectionDraftVault else { throw TeamCompletionBatchDraft.invalid }
                savedDraft = try await Task.detached(priority: .userInitiated) {
                    let draft = try TeamCompletionBatchDraft(review: expected, snapshot: before)
                    return try vault.save(draft)
                }.value
                guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(expected) else { return false }
                guard savedDraft?.snapshot == before else { throw TeamCompletionBatchDraft.invalid }
            }
            _ = try await makeRecoveryBackup(kind: "Before selection sync review")
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(expected) else { return false }
            let review: TeamTaskBatch.Review
            if expected.isCancelled { review = expected }
            else { review = try await backend.reviewTeamCompletionBatch(expected.mutation, expectedAccount: account, cancel: true) }
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(expected) else { return false }
            installTeamCompletionBatchReview(review)
            observedReview = review
            guard review.isCancelled else { notice = "This selection had already synced. Review its result to continue. Any saved draft is kept."; return false }
            let archived = savedDraft != nil
            let next = await Task.detached(priority: .userInitiated) {
                archived ? review.parkingCancellation(before, readable: access) : review.cancelling(before, readable: access)
            }.value
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(review) else { return false }
            guard let next else { notice = "The selection was cancelled. Your additional changes remain saved for review."; return false }
            snapshot = next
            do { try persist() } catch { snapshot = before; recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false }
            undoStack = []; redoStack = []; syncConflict = nil
            notice = archived ? "Synced tasks kept. Your later edits are in Saved team drafts." : "Synced tasks kept. A recovery copy is saved."
            Task { await sync() }; return true
        } catch {
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionBatchReview(observedReview) else { return false }
            recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false
        }
    }

    func currentTeamCompletionReview(_ review: TeamCompletion.Review) -> Bool {
        guard workspaceCacheReadable, signedIn, !localMode, !signingOut, !accountRemovalBlocked,
              syncConflict?.completionReview == review, snapshot.pending.first == review.mutation,
              let command = review.mutation.teamCompletion, command.scope.account == userID,
              command.scope.origin == (try? backend.accountRemovalOrigin), let cache = nativeConversationTeamCache else { return false }
        return command.canReview(review.mutation, readable: cache)
    }
    func canContinueTeamCompletionReview(_ review: TeamCompletion.Review) -> Bool {
        guard currentTeamCompletionReview(review), !review.isCancelled, let cache = nativeConversationTeamCache else { return false }
        return !review.isRecorded || review.acknowledging(snapshot, readable: cache) != nil
    }
    @discardableResult func refreshTeamCompletionReview(_ expected: TeamCompletion.Review) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        let session = backend.reminderSessionIncarnation
        let generation = accountGeneration, account = userID, before = snapshot, access = nativeConversationTeamCache, revision = workspaceReadRevision
        guard currentTeamCompletionReview(expected) else { return false }
        do {
            let review = try await backend.reviewTeamCompletion(expected.mutation, expectedAccount: account)
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision,
                  nativeConversationTeamCache == access, currentTeamCompletionReview(expected) else { return false }
            syncConflict = SyncConflict(mutation: expected.mutation, remote: review.task ?? expected.mutation.teamCompletion!.source, completionReview: review)
            return true
        } catch {
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision, nativeConversationTeamCache == access, currentTeamCompletionReview(expected) else { return false }
            recordTeamCompletionReviewFailure(SyncStatus.failureMessage(error), origin: presentation); return false
        }
    }
    @discardableResult func continueTeamCompletionReview(_ review: TeamCompletion.Review) async -> Bool {
        let presentation = teamCompletionReviewPresentation
        let session = backend.reminderSessionIncarnation
        let generation = accountGeneration, before = snapshot
        guard currentTeamCompletionReview(review), !review.isCancelled else { return false }
        if review.isRecorded {
            guard let access = nativeConversationTeamCache else { return false }
            let revision = workspaceReadRevision
            let next = await Task.detached(priority: .userInitiated) { review.acknowledging(before, readable: access) }.value
            guard generation == accountGeneration, session == backend.reminderSessionIncarnation, snapshot == before, revision == workspaceReadRevision,
                  nativeConversationTeamCache == access, currentTeamCompletionReview(review) else { return false }
            guard let next else { recordTeamCompletionReviewFailure("Your additional task changes are still saved. Keep this review for now.", origin: presentation); return false }
            snapshot = next
            do { try persist() } catch { snapshot = before; recordTeamCompletionReviewFailure(TeamCompletionRecoveryFailure.message(error), origin: presentation); return false }
            undoStack = []; redoStack = []
        }
        // Unrecorded reads retain the original nonce and immutable command.
        syncConflict = nil; notice = nil; Task { await sync() }; return true
    }

    /// Resolution is persisted before resuming. A second simultaneous edit can still conflict safely.
    @discardableResult func resolveConflict(id: UUID, keepLocal: Bool) -> Bool {
        guard let conflict = syncConflict, conflict.id == id,
              let next = conflict.resolving(snapshot, keepLocal: keepLocal) else {
            error = "This edit is no longer waiting for review. Reopen the current sync review."
            return false
        }
        let old = snapshot
        snapshot = next
        do { try persist() } catch { snapshot = old; self.error = error.localizedDescription; return false }
        undoStack = []; redoStack = []; syncConflict = nil; notice = nil
        Task { await sync() }
        return true
    }


    private var isolatedReminderDeviceFixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--uitesting") || ProcessInfo.processInfo.arguments.contains("--preview")
        #else
        return false
        #endif
    }
    var remoteReminderTestWorkspace: Bool {
        #if DEBUG
        return userID == "ui-testing" && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--reminder-authority-testing")
        #else
        return false
        #endif
    }
    private var reminderAuthorityAccount: String {
        remoteReminderTestWorkspace ? "f0729000-0000-4000-8000-000000000001" : userID.lowercased()
    }
    #if DEBUG
    @ObservationIgnored private var reminderAuthorityFixturePrepared = false
    @ObservationIgnored private var reminderAuthorityFixtureSession = UUID()
    var remoteReminderFixturePhase: String { reminderAuthority?.phase.rawValue ?? "local" }
    private func reminderAuthorityFixture(create: Bool) throws -> ReminderDeviceLifecycle? {
        guard remoteReminderTestWorkspace else { return nil }
        if let reminderDeviceLifecycle { return reminderDeviceLifecycle }
        let defaults = UserDefaults.standard, prefix = "taskfold.ui-testing.reminder-authority."
        if !reminderAuthorityFixturePrepared {
            reminderAuthorityFixturePrepared = true
            if ProcessInfo.processInfo.arguments.contains("--reminder-authority-reset") {
                for key in ["installation", "authority", "lostAck", "serverRevision", "serverExpiry"] { defaults.removeObject(forKey: prefix + key) }
            }
            if let data = defaults.data(forKey: prefix + "authority") {
                let value = try JSONDecoder().decode(ReminderDeliveryAuthority.self, from: data)
                guard value.valid else { throw AppFailure(message: "Invalid isolated authority fixture.") }
                reminderAuthority = value
            }
        }
        var installation = defaults.data(forKey: prefix + "installation").flatMap { try? JSONDecoder().decode(ReminderDeviceInstallation.self, from: $0) }
        if installation == nil, create { installation = ReminderDeviceInstallation(id: "f0729000-0000-4000-8000-000000000101", secret: String(repeating: "a", count: 64)) }
        guard let installation else { return nil }
        let engine = try ReminderDeviceLifecycle(installation: installation,
            save: { defaults.set(try JSONEncoder().encode($0), forKey: prefix + "installation") },
            send: { command, _ in
                // Synthetic receipts only. This path never calls Backend or APNs registration.
                let serverRevision = Int64(defaults.double(forKey: prefix + "serverRevision"))
                guard command.revision >= serverRevision else { throw AppFailure(message: "Stale isolated fixture revision.") }
                if command.revision > serverRevision {
                    defaults.set(Double(command.revision), forKey: prefix + "serverRevision")
                    defaults.set(Date().addingTimeInterval(30 * 86400).timeIntervalSince1970 * 1000, forKey: prefix + "serverExpiry")
                }
                try await Task.sleep(for: .milliseconds(80))
                if command.binding?.enabled == true, ProcessInfo.processInfo.arguments.contains("--reminder-authority-lost-ack"), !defaults.bool(forKey: prefix + "lostAck") {
                    defaults.set(true, forKey: prefix + "lostAck"); throw AppFailure(message: "Isolated lost activation acknowledgement.")
                }
                let clock = Int64(Date().timeIntervalSince1970 * 1000)
                return ReminderDeviceReceipt(version: 1, device: command.device, revision: command.revision, account: command.account,
                    state: command.binding == nil ? "retired" : "registered", enabled: command.binding?.enabled ?? false,
                    expires_at_ms: Int64(defaults.double(forKey: prefix + "serverExpiry")), authority_version: 1, server_time_ms: clock,
                    enabled_since_ms: command.binding?.enabled == true ? max(clock, (command.localCutoffMS ?? 0) + 1) : nil,
                    authority_nonce: command.authorityTransition)
            },
            changed: { [weak self] status, busy in self?.remoteReminderStatus = status; self?.remoteReminderBusy = busy },
            authority: reminderAuthority,
            saveAuthority: { defaults.set(try JSONEncoder().encode($0), forKey: prefix + "authority") },
            authorityChanged: { [weak self] next in
                guard let self else { return }; self.reminderAuthority = next
                Task { await self.reschedule() }
            },
            quiesceLocal: { [weak self] authority in
                guard let self else { throw CancellationError() }; return try await self.quiesceOriginalReminders(authority)
            })
        reminderDeviceLifecycle = engine; return engine
    }
    private func refreshReminderAuthorityFixture(force: Bool) async {
        guard remoteReminderTestWorkspace else { return }
        do {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let permission: ReminderDeviceBinding.Permission = settings.authorizationStatus == .authorized ? .authorized : settings.authorizationStatus == .provisional ? .provisional : .denied
            let context = remindersEnabled && permission != .denied ? ReminderDeviceContext(account: reminderAuthorityAccount,
                workspace: accountGeneration, session: reminderAuthorityFixtureSession,
                identity: .init(platform: .ios, bundle: "com.dbakp.taskfold", environment: .development), timeZone: TimeZone.current.identifier, permission: permission) : nil
            let engine = try reminderAuthorityFixture(create: context != nil)
            try engine?.update(context, online: true)
            remoteReminderAvailable = context != nil
            if let context { engine?.setAvailability(true, account: context.account, session: context.session) }
            try engine?.retry(force: force)
            if engine?.needsToken == true { try engine?.receivedToken(Data([0xfa, 0xce])) }
        } catch { remoteReminderStatus = "The isolated delivery fixture could not finish."; remoteReminderBusy = false }
    }
    #endif
    private func readReminderAuthority(force: Bool = false) throws {
        guard !isolatedReminderDeviceFixture, let bundle = Bundle.main.bundleIdentifier else { return }
        guard !reminderAuthorityRead || force else {
            if reminderAuthorityUnreadable { throw AppFailure(message: "The reminder delivery choice could not be read.") }; return
        }
        reminderAuthorityRead = true
        do {
            reminderAuthority = try ReminderAuthorityVault.read(bundle: bundle)
            if reminderAuthority == nil, try ReminderDeviceVault.read(bundle: bundle)?.mayHaveRemoteAuthority == true {
                throw AppFailure(message: "The previous remote delivery choice cannot be confirmed. Task reminders remain paused until secure setup is recovered.")
            }
            reminderAuthorityUnreadable = false
        }
        catch { reminderAuthorityUnreadable = true; throw error }
    }
    private func quiesceOriginalReminders(_ authority: ReminderDeliveryAuthority) async throws -> Int64 {
        let generation = accountGeneration, account = userID
        guard reminderAuthority?.transition == authority.transition, reminderAuthority?.phase == .stoppingLocal,
              reminderAuthorityAccount == authority.account else { throw CancellationError() }
        let state = reminderState()
        _ = await reminderScheduler.update(state)
        guard generation == accountGeneration, account == userID,
              reminderAuthority?.transition == authority.transition, reminderAuthority?.phase == .stoppingLocal else { throw CancellationError() }
        let cutoff = Date().timeIntervalSince1970 * 1000
        guard cutoff.isFinite, (0...Double(ReminderDeliveryAuthority.maximumTimestamp)).contains(cutoff) else { throw CancellationError() }
        return Int64(cutoff)
    }
    func chooseRemoteReminders(_ enabled: Bool) {
        do {
            try readReminderAuthority()
            guard let lifecycle = try deviceRegistration(create: false) else { throw AppFailure(message: "Check remote setup before choosing delivery.") }
            try lifecycle.chooseRemote(enabled)
        } catch { remoteReminderStatus = error.localizedDescription; remoteReminderBusy = false }
    }
    private func deviceRegistration(create: Bool) throws -> ReminderDeviceLifecycle? {
        #if DEBUG
        if remoteReminderTestWorkspace { return try reminderAuthorityFixture(create: create) }
        #endif
        guard !isolatedReminderDeviceFixture, let bundle = Bundle.main.bundleIdentifier else { return nil }
        try readReminderAuthority()
        if let reminderDeviceLifecycle { return reminderDeviceLifecycle }
        var installation = try ReminderDeviceVault.read(bundle: bundle)
        if installation == nil, reminderAuthority?.mayBeRemote == true {
            throw AppFailure(message: "The previous remote registration cannot be confirmed. Task reminders remain paused. Retry remote setup when this device’s secure registration is available.")
        }
        if installation == nil, create { installation = try .make(); try ReminderDeviceVault.save(installation!, bundle: bundle) }
        guard let installation else { return nil }
        let lifecycle = try ReminderDeviceLifecycle(installation: installation,
            save: { try ReminderDeviceVault.save($0, bundle: bundle) },
            send: { [backend] command, incarnation in try await backend.sendReminderDevice(command, expectedIncarnation: incarnation) },
            changed: { [weak self] status, busy in self?.remoteReminderStatus = status; self?.remoteReminderBusy = busy },
            authority: reminderAuthority,
            saveAuthority: { try ReminderAuthorityVault.save($0, bundle: bundle) },
            authorityChanged: { [weak self] next in
                guard let self else { return }; self.reminderAuthority = next; self.reminderAuthorityUnreadable = false
                Task { await self.reschedule() }
            },
            quiesceLocal: { [weak self] authority in
                guard let self else { throw CancellationError() }; return try await self.quiesceOriginalReminders(authority)
            })
        reminderDeviceLifecycle = lifecycle; return lifecycle
    }
    /// Persist proof retirement synchronously before clearing the session, including when the
    /// installation was loaded after a restart and no APNs token has yet been received.
    private func prepareReminderDeviceRetirement() throws {
        try deviceRegistration(create: false)?.retire()
    }
    func refreshRemoteReminderRegistration(force: Bool = false) async {
        #if DEBUG
        if remoteReminderTestWorkspace { await refreshReminderAuthorityFixture(force: force); return }
        #endif
        guard !isolatedReminderDeviceFixture else {
            remoteReminderStatus = "Remote reminders are not available in this workspace."; return
        }
        let generation = accountGeneration, incarnation = backend.reminderSessionIncarnation, account = userID
        remoteReminderAvailable = false
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard generation == accountGeneration, incarnation == backend.reminderSessionIncarnation, account == userID else { return }
        let permission: ReminderDeviceBinding.Permission = settings.authorizationStatus == .authorized ? .authorized : settings.authorizationStatus == .provisional ? .provisional : .denied
        let eligible = signedIn && !localMode && remindersEnabled && permission != .denied && UUID(uuidString: account) != nil
        do {
            try readReminderAuthority(force: force && reminderDeviceLifecycle == nil)
            let lifecycle = try deviceRegistration(create: eligible && reminderAppIdentity != nil)
            let context = eligible ? reminderAppIdentity.map {
                ReminderDeviceContext(account: account.lowercased(), workspace: generation, session: incarnation, identity: $0,
                                      timeZone: TimeZone.current.identifier, permission: permission)
            } : nil
            try lifecycle?.update(context, online: online)
            if let context, online {
                let available: Bool
                if !force, let cached = reminderAvailability, cached.account == context.account, cached.session == incarnation,
                   (0..<60).contains(Date().timeIntervalSince(cached.checked)) {
                    available = cached.value
                } else {
                    available = (try? await backend.reminderDeliveryAvailable(account: context.account, expectedIncarnation: incarnation)) ?? false
                    guard generation == accountGeneration, incarnation == backend.reminderSessionIncarnation, account == userID else { return }
                    reminderAvailability = (context.account, incarnation, available, Date())
                }
                remoteReminderAvailable = available
                lifecycle?.setAvailability(available, account: context.account, session: incarnation)
            }
            try lifecycle?.retry(force: force)
            if lifecycle?.needsToken == true {
                lifecycle?.requestedToken()
                #if os(iOS)
                UIApplication.shared.registerForRemoteNotifications()
                #elseif os(macOS)
                NSApplication.shared.registerForRemoteNotifications()
                #endif
            } else if lifecycle == nil || context == nil && lifecycle?.busy != true && lifecycle?.retirementPending != true {
                remoteReminderStatus = localMode || !signedIn ? "Sign in to prepare remote reminders." :
                    eligible && reminderAppIdentity == nil ? "Remote setup is unavailable in this build." :
                    "Remote reminders are not available yet."
            }
        } catch {
            remoteReminderStatus = remoteReminderHoldingOriginals ? "Task reminders are waiting for confirmed delivery. Check remote setup to retry." : "Device registration could not be saved securely. Check remote setup to retry."; remoteReminderBusy = false
        }
    }
    func receivedRemoteReminderToken(_ token: Data) async {
        guard !isolatedReminderDeviceFixture else { return }
        await refreshRemoteReminderRegistration()
        do { try reminderDeviceLifecycle?.receivedToken(token) }
        catch { remoteReminderStatus = remoteReminderHoldingOriginals ? "Task reminders are waiting for confirmed delivery. Check remote setup to retry." : "Device registration could not be saved securely. Check remote setup to retry."; remoteReminderBusy = false }
    }
    func failedRemoteReminderToken() {
        guard !isolatedReminderDeviceFixture else { return }
        reminderDeviceLifecycle?.failedToken()
    }

    private var reminderPreferenceKey: String { ReminderPreferences.key(userID) }
    var remindersEnabled: Bool {
        _ = reminderPreferenceRevision
        guard !signingOut, !accountRemovalBlocked, signedIn || localMode, !userID.isEmpty else { return false }
        return ReminderPreferences.enabled(account: userID, fixture: userID == "ui-testing" || userID == "preview")
    }
    var timeSensitiveRemindersEnabled: Bool {
        _ = reminderPreferenceRevision
        return (signedIn || localMode) && ReminderPreferences.timeSensitiveEnabled(account: userID)
    }
    func setTimeSensitiveReminders(_ enabled: Bool) {
        guard signedIn || localMode, !userID.isEmpty else { return }
        UserDefaults.standard.set(enabled, forKey: ReminderPreferences.timeSensitiveKey(userID))
        reminderPreferenceRevision += 1
        Task { await reschedule() }
    }
    func enableNotifications() async {
        guard !requestingNotifications, !requestingFocusAlerts, signedIn || localMode else { return }
        let generation = accountGeneration, account = userID, key = reminderPreferenceKey
        requestingNotifications = true
        defer { requestingNotifications = false }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard generation == accountGeneration, account == userID else { return }
            UserDefaults.standard.set(allowed, forKey: key); reminderPreferenceRevision += 1
            if allowed { await reschedule() }
            else { reminderStatus = "Permission is off. Allow Taskfold notifications in system settings." }
            await refreshRemoteReminderRegistration()
        } catch { if generation == accountGeneration { reminderStatus = "Notifications could not be enabled: " + error.localizedDescription } }
    }
    var focusAlertsEnabled: Bool {
        _ = reminderPreferenceRevision
        return focusAvailable && !userID.isEmpty && UserDefaults.standard.bool(forKey: FocusFinish.preferenceKey(userID))
    }
    private var focusFinishEvent: DueReminder? {
        FocusFinish.event(row: focusRecord, tasks: tasks, account: userID, available: focusAvailable, conflict: focusSyncConflict != nil)
    }
    func validFocusFinish(_ receipt: FocusFinishReceipt, now: Date = Date()) -> Bool {
        focusAlertsEnabled && receipt.valid(account: userID, event: focusFinishEvent, now: now)
    }
    func enableFocusAlerts() async {
        guard !requestingFocusAlerts, !requestingNotifications, focusAvailable else { return }
        let generation = accountGeneration, account = userID
        requestingFocusAlerts = true; defer { requestingFocusAlerts = false }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard generation == accountGeneration, account == userID else { return }
            UserDefaults.standard.set(allowed, forKey: FocusFinish.preferenceKey(account)); reminderPreferenceRevision += 1; focusPermissionDenied = !allowed
            await reschedule()
        } catch { if generation == accountGeneration { focusAlertStatus = "Finish alerts could not be enabled: " + error.localizedDescription } }
    }
    func disableFocusAlerts() {
        UserDefaults.standard.set(false, forKey: FocusFinish.preferenceKey(userID)); reminderPreferenceRevision += 1
        focusPermissionDenied = false; focusAlertStatus = "Finish alerts are off on this device."
        Task { await reschedule() }
    }
    private func reminderState() -> ReminderState {
        let generation = accountGeneration
        reminderRevision += 1
        var events = remindersEnabled ? DueReminder.events(tasks: activeTasks) : []
        if focusAlertsEnabled, let event = focusFinishEvent { events.append(event) }
        return ReminderState(revision: reminderRevision, account: remindersEnabled || focusAlertsEnabled ? userID : "", events: events, validationTasks: remindersEnabled ? activeTasks : [], deliveryAuthority: reminderAuthority, deliveryAuthorityUnreadable: reminderAuthorityUnreadable, deliveryAuthorityAccount: remoteReminderTestWorkspace ? reminderAuthorityAccount : nil, timeSensitiveAllowed: timeSensitiveRemindersEnabled && systemTimeSensitiveAllowed, queuedTimeSnoozes: queuedTimeSnoozes, timeSnoozeTransition: { [weak self] request, transition in await self?.transitionTimeSnooze(request, transition: transition, generation: generation) ?? .obsolete })
    }
    func reschedule() async {
        reminderRefreshRequest &+= 1
        if let current = reminderRefreshTask { await current.value; return }
        let work = Task { [weak self] in
            guard let self else { return }
            while true {
                let request = self.reminderRefreshRequest
                await self.refreshScheduledReminders()
                if request == self.reminderRefreshRequest { self.reminderRefreshTask = nil; return }
            }
        }
        reminderRefreshTask = work
        await work.value
    }
    private func refreshScheduledReminders() async {
        ReminderCategory.register(minutes: reminderSnoozeMinutes)
        refreshCalendarContext()
        await refreshRemoteReminderRegistration()
        let generation = accountGeneration
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard generation == accountGeneration else { return }
        systemTimeSensitiveAllowed = settings.timeSensitiveSetting == .enabled
        await reconcileTimeSnoozes(generation: generation)
        guard generation == accountGeneration else { return }
        let state = reminderState()
        let report = await reminderScheduler.update(state)
        guard generation == accountGeneration, state.revision == reminderRevision, report.revision == state.revision else { return }
        switch settings.timeSensitiveSetting {
        case .enabled: timeSensitiveReminderStatus = "System Time Sensitive delivery is allowed. Focus settings still apply."
        case .disabled: timeSensitiveReminderStatus = "Time Sensitive delivery is off in system settings. Marked reminders follow normal delivery settings."
        default: timeSensitiveReminderStatus = "Time Sensitive delivery is unavailable in this build or on this device. Marked reminders follow normal delivery settings."
        }
        var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        #if os(iOS)
        allowed = allowed || settings.authorizationStatus == .ephemeral
        #endif
        guard allowed else {
            reminderStatus = remindersEnabled ? "Permission is off. Allow Taskfold notifications in system settings." : "Reminders are off for this workspace on this device."
            focusAlertStatus = focusAlertsEnabled || focusPermissionDenied ? "Permission is off. Allow Taskfold notifications in system settings." : "Finish alerts are off on this device."
            return
        }
        if !focusAlertsEnabled { focusAlertStatus = "Finish alerts are off on this device." }
        else if report.focusFailure { focusAlertStatus = "The finish alert could not be scheduled. Open Focus to retry." }
        else if report.focusScheduled { focusAlertStatus = "A finish alert is scheduled on this device." }
        else if report.focusDeferred { focusAlertStatus = "There’s no room for the finish alert yet. Taskfold will retry while this session is running." }
        else if focusSyncConflict != nil { focusAlertStatus = "Review the session changes before a finish alert can be scheduled." }
        else if focusSession?.finished(at: Date()) == true { focusAlertStatus = "Start another session to receive its finish alert." }
        else { focusAlertStatus = "Start or resume a session to schedule its finish alert." }
        guard remindersEnabled else { reminderStatus = "Reminders are off for this workspace on this device."; return }
        if remoteReminderHoldingOriginals { reminderStatus = remoteReminderStatus; return }
        if report.failures > 0 { reminderStatus = "\(report.failures) \(report.failures == 1 ? "reminder" : "reminders") could not be scheduled. Taskfold will retry when opened." }
        else if report.deferred > 0 { reminderStatus = "\(report.scheduled) upcoming reminders scheduled; \(report.deferred) later ones will be refreshed while Taskfold is open." }
        else { reminderStatus = "\(report.scheduled) upcoming \(report.scheduled == 1 ? "reminder" : "reminders") scheduled on this device." }
    }
    func disableNotifications() {
        UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: timeSnoozeEpochKey)
        do { try prepareReminderDeviceRetirement() } catch { remoteReminderStatus = "Device unlinking could not be saved securely. Retry remote setup." }
        UserDefaults.standard.set(false, forKey: reminderPreferenceKey); reminderPreferenceRevision += 1
        if focusAlertsEnabled { Task { await reschedule() } } else { clearScheduledReminders() }
    }
    private func clearScheduledReminders() {
        reminderRevision += 1
        let state = ReminderState(revision: reminderRevision, account: "", events: [])
        reminderStatus = "Reminders are off for this workspace on this device."
        focusPermissionDenied = false; focusAlertStatus = "Finish alerts are off on this device."
        Task { _ = await reminderScheduler.update(state) }
    }
    func validReminder(_ info: [AnyHashable: Any]) -> DueReminder? {
        guard remindersEnabled, let account = info["accountID"] as? String, account == userID,
              let task = info["taskID"] as? String, let spec = info["specID"] as? String,
              let signature = info["signature"] as? String else { return nil }
        return DueReminder.validated(tasks: activeTasks, taskID: task, specID: spec, signature: signature, originalAt: (info["originalAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
    func reminderTask(for route: ReminderTaskRoute) -> Record? {
        let valid = workspaceCacheReadable && (signedIn || localMode) && remindersEnabled &&
            route.workspace.matches(account: userID, generation: workspaceGeneration) &&
            DueReminder.validated(tasks: activeTasks, taskID: route.taskID, specID: route.specID, signature: route.signature, originalAt: route.originalAt) != nil
        #if DEBUG
        if userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--reminder-route-testing") {
            reminderRouteFixtureOutcome = valid ? "Opened" : "Ignored"
        }
        #endif
        return valid ? record("tasks", id: route.taskID) : nil
    }
    /// Actions are scoped to the receiving workspace and the current task/reminder version.
    func handleReminder(_ info: [AnyHashable: Any], action: String) async -> ReminderTaskRoute? {
        guard let event = validReminder(info), let task = record("tasks", id: event.taskID) else { return nil }
        switch action {
        case ReminderCategory.complete: toggle(task)
        case ReminderCategory.tomorrow:
            let fields = TaskPlanner.tomorrowFields(task: task)
            if !fields.isEmpty {
                _ = commit([Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: fields)])
            }
        case let action where ReminderSnooze.minutes(action: action) != nil:
            guard let minutes = ReminderSnooze.minutes(action: action) else { return nil }
            let generation = accountGeneration
            await reschedule()
            guard generation == accountGeneration, validReminder(info) != nil else { return nil }
            await saveTimeSnooze(event: event, minutes: minutes, generation: generation)
        case let action where action.hasPrefix("taskfold.snooze."): return nil
        default: return ReminderTaskRoute(workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), taskID: task.id, specID: event.specID, signature: event.signature, originalAt: event.date)
        }
        return nil
    }
}

/// Actionable reminder category: complete or snooze straight from the notification.
enum ReminderCategory {
    static let identifier = "taskfold.reminder"
    static let complete = "taskfold.complete"
    static let snoozeHour = "taskfold.snooze.hour"
    static let tomorrow = "taskfold.tomorrow"
    static func register(minutes: Int = 60) {
        let minutes = ReminderSnooze.validMinutes(minutes) ? minutes : 60
        let category = UNNotificationCategory(identifier: identifier, actions: [
            UNNotificationAction(identifier: complete, title: "Complete", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")),
            UNNotificationAction(identifier: ReminderSnooze.action(minutes: minutes)!, title: "Remind me in " + ReminderSnooze.label(minutes), options: [], icon: UNNotificationActionIcon(systemImageName: "clock")),
            UNNotificationAction(identifier: tomorrow, title: "Move to tomorrow", options: [], icon: UNNotificationActionIcon(systemImageName: "sunrise")),
        ], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, UNNotificationCategory(identifier: FocusFinish.category, actions: [], intentIdentifiers: [], options: [])])
    }
}

#if DEBUG
extension Store {
    func seedReminderRouteFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--reminder-route-testing") else { return }
        dailyBackupsEnabled = false; disableNotifications(); disableFocusAlerts()
        var task = Record.task(user: userID, date: Date().addingTimeInterval(-86400))
        task.fields.removeValue(forKey: "task_generation") // Existing pre-migration task for the legacy alert walk.
        task["id"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa81"); task["title"] = .string("Reminder route check")
        task["due_time"] = .string("08:00")
        snapshot = Snapshot(tables: ["tasks": [task]])
        // The fixture's event is in the past, so this cannot schedule an upcoming test notification.
        UserDefaults.standard.set(true, forKey: reminderPreferenceKey); reminderPreferenceRevision += 1
        try? persist()
    }
    func restoreReminderRouteFixtureTask() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--reminder-route-testing"), let task = tasks.first else { return }
        remove("tasks", task.id); undo()
    }
    func renewReminderRouteFixtureWorkspace() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--reminder-route-testing") else { return }
        accountGeneration = UUID()
    }
    func legacyReminderRouteFixtureRequest() async -> ReminderTaskRoute? {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--reminder-route-testing"),
              let event=DueReminder.events(tasks:tasks).first, let old=event.legacySignature else { return nil }
        return await handleReminder(["accountID":userID,"taskID":event.taskID,"specID":event.specID,"signature":old],action:UNNotificationDefaultActionIdentifier)
    }
    func reminderRouteFixtureRequest() -> ReminderTaskRoute? {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--reminder-route-testing"), let event = DueReminder.events(tasks: activeTasks).first else { return nil }
        return ReminderTaskRoute(workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), taskID: event.taskID, specID: event.specID, signature: event.signature)
    }
    func seedInsightsFixture() {
        guard userID=="ui-testing",ProcessInfo.processInfo.arguments.contains("--uitesting"),ProcessInfo.processInfo.arguments.contains("--insights-fixture") else { return }
        dailyBackupsEnabled=false;disableNotifications();snapshot=Snapshot.insightsFixture(account:userID);undoStack=[];redoStack=[];try? persist()
    }
    func seedWidgetActionFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--widget-action-testing") else { return }
        widgetFixtureFailSave = false; dailyBackupsEnabled = false; disableNotifications()
        if let disk = try? widgetActionDisk() {
            for request in (try? disk.pending(account: userID)) ?? [] { try? disk.acknowledge(request) }
        }
        var task = Record.task(user: userID, date: Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        task["id"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa10"); task["title"] = .string("Daily widget review")
        task["is_recurring"] = .bool(true); task["recurrence_pattern"] = .object(["type": .string("daily")])
        snapshot = Snapshot(tables: ["tasks": [task]]); undoStack = []; redoStack = []; try? persist()
        widgetFixtureFailSave = ProcessInfo.processInfo.arguments.contains("--widget-action-fail-save")
        widgetFixtureReady = true
    }

    func seedPinnedNotesFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--pinned-notes-seed") else { return }
        inboxFixtureFailSave = false; dailyBackupsEnabled = false; disableNotifications()
        var first = Record.task(user: userID); first["id"] = .string("note-first"); first["title"] = .string("Launch reference")
        first["description"] = .string("Start with a clear thought.\nKeep the café and 👩🏽‍💻 details.\nFinal instruction remains available.")
        var done = Record.task(user: userID); done["id"] = .string("note-done"); done["title"] = .string("Completed reference"); done["completed"] = .bool(true)
        done["description"] = .string("A completed task can still hold useful instructions.")
        var privateTask = Record.task(user: userID); privateTask["id"] = .string("note-private"); privateTask["title"] = .string("Private reference"); privateTask["description"] = .string("Do not publish this unpinned description.")
        snapshot = Snapshot(tables: ["tasks": [first, done, privateTask]])
        for task in [first, done] { if let change = PinnedNotes.change(taskID: task.id, enabled: true, pins: [], account: userID) { snapshot.apply(change) } }
        undoStack = []; redoStack = []; try? persist()
    }
    func focusWidgetFixtureProjection() -> String {
        _ = widgetPublicationRevision
        guard let data = try? widgetActionDisk().read().data, let payload = try? JSONDecoder().decode([String: JSON].self, from: data),
              let encoded = try? JSONEncoder().encode(payload["focusSession"] ?? .null),
              let focus = try? JSONDecoder().decode(FocusWidgetSnapshot.self, from: encoded), focus.valid(for: userID) else { return "Focus: refresh" }
        return "Focus: " + (focus.conflict ? "review" : focus.clock?.status ?? "idle")
    }
    func pulseWidgetFixtureProjection() -> String {
        _ = widgetPublicationRevision
        guard let data = try? widgetActionDisk().read().data, let payload = try? JSONDecoder().decode([String: JSON].self, from: data),
              let encoded = try? JSONEncoder().encode(payload["projectPulse"] ?? .null),
              let pulse = try? JSONDecoder().decode(ProjectPulseSnapshot.self, from: encoded), pulse.valid(for: userID),
              let project = pulse.projects.first, let day = project.days[ProjectPulseSnapshot.day(Date())] else { return "Pulse: refresh" }
        return "Pulse: \(project.completed)/\(project.total) · \(day.completions) completion events · \(day.reopens) reopen events"
    }
    func seedProjectPulseFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--project-pulse-seed") else { return }
        dailyBackupsEnabled = false; disableNotifications(); disableFocusAlerts()
        let project = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71", now = Date()
        snapshot = Snapshot(tables: ["projects": [Record(["id": .string(project), "user_id": .string(userID), "name": .string("Studio"), "color": .string("#e31e4b")])]])
        for (index, title) in ["Finish a useful draft", "Review the launch checklist", "A task without urgency"].enumerated() {
            var task = Record.task(user: userID, project: project); task["id"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa7" + String(index + 2)); task["title"] = .string(title)
            if index == 1 { task["deadline_date"] = .string(TaskPlanner.dayKey(now)) }
            let change = Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields)
            snapshot.apply(change); TaskActivity.recordLocal(change, before: nil, after: task, snapshot: &snapshot, account: userID, now: now.addingTimeInterval(-2 * 86400))
        }
        for interval in [-3600.0, -1800.0, -900.0] {
            guard let task = snapshot.tables["tasks"]?.first else { continue }
            for change in TaskCompletion.toggle(task, tasks: tasks, at: now.addingTimeInterval(interval), account: userID) {
                snapshot.apply(change); TaskActivity.recordLocal(change, before: task, after: record("tasks", id: task.id), snapshot: &snapshot, account: userID, now: now.addingTimeInterval(interval))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--project-pulse-no-history") {
            snapshot.tables[TaskActivity.table] = []; snapshot.tables[TaskActivity.epochTable] = []
        }
        undoStack = []; redoStack = []; try? persist()
    }
    func seedFocusSessionFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--focus-session-seed") else { return }
        dailyBackupsEnabled = false; disableNotifications(); disableFocusAlerts(); focusSyncConflict = nil
        var task = Record.task(user: userID); task["id"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31"); task["title"] = .string("Focus on the next useful step")
        snapshot = Snapshot(tables: ["tasks": [task]]); undoStack = []; redoStack = []

        if ProcessInfo.processInfo.arguments.contains("--focus-catalog-seed") {
            let studio = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa81", home = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa82", section = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa83"
            snapshot.tables["projects"] = [Record(["id": .string(studio), "name": .string("Studio"), "user_id": .string(userID)]), Record(["id": .string(home), "name": .string("Home"), "user_id": .string(userID)])]
            snapshot.tables["sections"] = [Record(["id": .string(section), "project_id": .string(studio), "name": .string("Client launch")])]
            for index in 0..<250 {
                var candidate = Record.task(user: userID, project: index == 249 ? home : studio)
                candidate["id"] = .string(String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", index + 1000))
                candidate["title"] = .string(index >= 248 ? "Review the proposal" : String(format: "Catalogue task %03d", index))
                if index == 248 {
                    candidate["section_id"] = .string(section)
                    candidate["description"] = .string("Check the café launch details before sending the proposal to the client.")
                }
                if index == 249 { candidate["description"] = .string("Choose paint colours for the home renovation.") }
                snapshot.tables["tasks", default: []].append(candidate)
            }
            var done = Record.task(user: userID); done["title"] = .string("Completed proposal"); done["completed"] = .bool(true)
            snapshot.tables["tasks", default: []].append(done)
        }
        if ProcessInfo.processInfo.arguments.contains("--focus-session-unavailable"),
           let session = try? FocusSession(taskID: task.id, minutes: 25),
           let start = try? FocusSessionChange.make(session, current: nil, account: userID) {
            snapshot.apply(start); snapshot.tables["tasks"] = []
        }
        if ProcessInfo.processInfo.arguments.contains("--focus-session-finished"),
           let session = try? FocusSession(taskID: task.id, minutes: 1, now: Date().addingTimeInterval(-120)),
           let start = try? FocusSessionChange.make(session, current: nil, account: userID) { snapshot.apply(start) }
        if ProcessInfo.processInfo.arguments.contains("--focus-session-conflict") {
            let now = Date()
            if let session = try? FocusSession(taskID: task.id, minutes: 25, now: now.addingTimeInterval(-60)),
               let start = try? FocusSessionChange.make(session, current: nil, account: userID),
               let paused = try? session.paused(at: now),
               let pause = try? FocusSessionChange.make(paused, current: Record(start.fields), account: userID),
               let other = try? FocusSession(taskID: task.id, minutes: 45, now: now),
               let remote = try? FocusSessionChange.make(other, current: nil, account: userID) {
                snapshot.apply(start); snapshot.apply(pause); snapshot.pending = [start,pause]
                focusSyncConflict = FocusSyncConflict(mutation: start, remote: Record(remote.fields))
            }
        }
        try? persist()
        focusFixtureFailSave = ProcessInfo.processInfo.arguments.contains("--focus-session-fail-save")
    }
    func pinnedNotesFixtureProjection() -> String {
        _ = widgetPublicationRevision
        guard let data = try? widgetActionDisk().read().data, let payload = try? JSONDecoder().decode([String: JSON].self, from: data) else { return "Notes: unavailable" }
        let notes = payload["notes"]?.list ?? []
        return "Notes: \(notes.count) · Private: \(notes.contains { $0.object["taskID"] == .string("note-private") } ? "visible" : "hidden")"
    }
    func seedInboxReviewFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--inbox-review-seed") else { return }
        inboxFixtureFailSave = false; snapshot = Snapshot(); undoStack = []; redoStack = []
        dailyBackupsEnabled = false; disableNotifications()
        let project = Record(["id": .string("inbox-project"), "user_id": .string(userID), "name": .string("Studio"), "color": .string("purple")])
        let next = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        var first = Record.task(user: userID, date: next); first["id"] = .string("inbox-first"); first["title"] = .string("Inbox launch notes"); first["priority"] = .number(1)
        first["due_time"] = .string("10:30"); first["duration_minutes"] = .number(45); first["deadline_date"] = .string(Dates.day(Calendar.current.date(byAdding: .day, value: 3, to: Date())!))
        first["description"] = .string("Keep the planned time, estimate and deadline when organizing this thought.")
        var second = Record.task(user: userID); second["id"] = .string("inbox-second"); second["title"] = .string("Inbox studio sketch"); second["priority"] = .number(2)
        var third = Record.task(user: userID); third["id"] = .string("inbox-third"); third["title"] = .string("Inbox reference"); third["priority"] = .number(3)
        var assigned = Record.task(user: userID); assigned["id"] = .string("inbox-assigned"); assigned["title"] = .string("Already organized"); assigned["project_id"] = .string(project.id)
        var done = Record.task(user: userID); done["id"] = .string("inbox-done"); done["title"] = .string("Already finished"); done["completed"] = .bool(true)
        snapshot.tables["tasks"] = [first, second, third, assigned, done]; snapshot.tables["projects"] = [project]
        if ProcessInfo.processInfo.arguments.contains("--inbox-review-batches") {
            for index in 1...3 {
                var task = Record.task(user: userID); task["id"] = .string("inbox-next-\(index)"); task["title"] = .string("Inbox next \(index)")
                task["created_at"] = .string(String(format: "2026-01-01T00:00:%02dZ", 3 - index))
                snapshot.tables["tasks", default: []].append(task)
            }
        }
        try? persist()
    }
    func inboxWidgetFixtureCount() -> String {
        _ = widgetPublicationRevision
        guard let read = try? widgetActionDisk().read(), let data = read.data,
              let payload = try? JSONDecoder().decode([String: JSON].self, from: data) else { return "Inbox unavailable" }
        let count = payload["tasks"]?.list.filter { $0.object["projectID"]?.text == "" }.count ?? 0
        return "Inbox: \(count)"
    }
    func inboxFixturePlan() -> String {
        guard let row = record("tasks", id: "inbox-first") else { return "Plan unavailable" }
        return "\(row.string("due_date")) · \(row.string("due_time")) · \(row.durationMinutes ?? 0)m · \(row.string("deadline_date"))"
    }

    func seedCapacityWidgetFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--capacity-widget-seed") else { return }
        snapshot = Snapshot(); dailyBackupsEnabled = false; disableNotifications()
        let today = Date(), tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        var work = Record.task(user: userID, date: today); work["id"] = .string("capacity-today"); work["title"] = .string("Capacity focus draft"); work["duration_minutes"] = .number(90)
        var unknown = Record.task(user: userID, date: today); unknown["id"] = .string("capacity-unknown"); unknown["title"] = .string("Unestimated capacity review")
        var next = Record.task(user: userID, date: tomorrow); next["id"] = .string("capacity-tomorrow"); next["title"] = .string("Tomorrow capacity review"); next["duration_minutes"] = .number(30)
        snapshot.tables["tasks"] = [work, unknown, next]
        snapshot.tables["view_preferences"] = [Record(["id": .string("planner"), "user_id": .string(userID), "working_hours": WorkingHours(weekdays: Set(1...7)).document])]
        try? persist()
    }
    func capacityWidgetFixtureDay() -> String {
        _ = widgetPublicationRevision
        guard let read = try? widgetActionDisk().read(), let data = read.data,
              let payload = try? JSONDecoder().decode([String: JSON].self, from: data) else { return "Capacity unavailable" }
        let day = payload["capacity"]?.object["days"]?.object[TaskPlanner.dayKey(Date())]?.object ?? [:]
        let state = payload["capacity"]?.object["calendarState"]?.text ?? "missing"
        return "Work \(day["working"]?.integer ?? -1) · Tasks \(day["estimated"]?.integer ?? -1) · Unknown \(day["unknown"]?.integer ?? -1) · Calendar \(state)"
    }

    func seedCompletionCycleFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--completion-cycle-fixture") else { return }
        seedWidgetActionFixture()
        guard let root = tasks.first else { return }
        let changes = TaskCompletion.complete(root, tasks: tasks, account: userID)
        for change in changes { snapshot.apply(change); snapshot.pending.append(change) }
        if ProcessInfo.processInfo.arguments.contains("--edited-occurrence-fixture"), let creation = changes.last, creation.method == "POST" {
            let edit = Mutation(table: "tasks", recordID: creation.recordID, method: "PATCH", fields: ["title": .string("Saved occurrence draft")], baseline: ["title": creation.fields["title"] ?? .null])
            snapshot.apply(edit); snapshot.pending.append(edit)
        }
        var remote = root; remote["completion_version"] = .number(2); remote["description"] = .string("Updated on another device")
        if let change = changes.first { syncConflict = SyncConflict(mutation: change, remote: remote) }
        try? persist()
    }
    func queueWidgetActionFixture(_ request: WidgetCompletionRequest) throws {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--widget-action-testing") else { throw WidgetActionFailure("Use an isolated fixture") }
        _ = try widgetActionDisk().enqueue(request)
    }
    func widgetActionFixturePending() -> Int { ((try? widgetActionDisk().pending(account: userID)) ?? []).count }
}
#endif

extension Store {
    var locationHandoffAvailable: Bool { signedIn && !localMode && workspaceCacheReadable }
    func locationHandoffs(workspace: WorkspaceBinding) async throws -> [LocationHandoffRecord] {
        guard locationHandoffAvailable, workflowReady(workspace) else { throw LocationStorageFailure.changed }
        return try await LocationHandoffAPI(backend: backend).perform(.list(device: nil), account: workspace.account,
            isCurrent: { self.locationHandoffAvailable && self.workflowReady(workspace) }).records
    }
    /// Explicit confirmation uploads only this reviewed proposal, never the placebook.
    func sendLocationHandoff(_ proposal: LocationHandoffProposal, workspace: WorkspaceBinding) async throws -> LocationHandoffRecord {
        guard locationHandoffAvailable, workflowReady(workspace), let task = record("tasks", id: proposal.taskID),
              proposal.matches(task: task, account: workspace.account) else { throw LocationStorageFailure.changed }
        let response = try await LocationHandoffAPI(backend: backend).perform(.put(proposal), account: workspace.account,
            isCurrent: { self.locationHandoffAvailable && self.workflowReady(workspace) })
        guard let result = response.records.first else { throw LocationStorageFailure.changed }
        return result
    }
    func discardLocationHandoff(_ row: LocationHandoffRecord, workspace: WorkspaceBinding) async throws {
        guard locationHandoffAvailable, workflowReady(workspace), row.account == workspace.account, row.state == .pending else { throw LocationStorageFailure.changed }
        _ = try await LocationHandoffAPI(backend: backend).perform(.discard(id: row.id), account: workspace.account,
            isCurrent: { self.locationHandoffAvailable && self.workflowReady(workspace) })
    }
    func captureWorkflowTemplate(kind: WorkflowTemplate.Kind, sourceID: String, binding: WorkspaceBinding?) throws -> WorkflowTemplateCapture {
        guard workflowReady(binding), let binding else { throw WorkflowTemplateCapture.changed }
        return try WorkflowTemplateCapture(kind: kind, sourceID: sourceID, snapshot: presentationSnapshot, workspace: binding, session: backend.reminderSessionIncarnation, origin: try? backend.accountRemovalOrigin, teamCache: nativeConversationTeamCache)
    }
    func reviewWorkflowTemplateCapture(_ capture: WorkflowTemplateCapture) throws {
        guard workspaceCacheReadable, signedIn || localMode, !signingOut, !accountRemovalBlocked else { throw WorkflowTemplateCapture.changed }
        try capture.reviewed(snapshot: presentationSnapshot, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), session: backend.reminderSessionIncarnation, origin: try? backend.accountRemovalOrigin, teamCache: nativeConversationTeamCache)
    }
    func workflowReady(_ binding: WorkspaceBinding?) -> Bool {
        guard binding?.matches(account: userID, generation: workspaceGeneration) == true, workspaceCacheReadable, signedIn || localMode else {
            error = "Your workspace changed. Reopen this tool before saving."; return false
        }
        return true
    }
    @discardableResult func archiveProject(_ project: Record, archived: Bool) -> Bool {
        guard var current = record("projects", id: project.id), current.string("user_id") == userID else { error = "Only the project owner can archive or restore it."; return false }
        current["is_archived"] = .bool(archived)
        return save("projects", current)
    }
    func workflowDestinationsAvailable(_ lines: [MultiLineCapture.Line]) -> Bool {
        let active = Set(projects.map(\.id)), sections = rows("sections")
        return lines.allSatisfy { line in
            let task = line.task, project = task.string("project_id"), section = task.string("section_id")
            return (project.isEmpty || active.contains(project)) && (section.isEmpty || sections.contains { $0.id == section && $0.string("project_id") == project })
        }
    }
    func workflowChanges(_ lines: [MultiLineCapture.Line]) throws -> [Mutation] {
        guard !lines.isEmpty else { throw AppFailure(message: "Choose at least one task.") }
        guard workflowDestinationsAvailable(lines) else { throw AppFailure(message: "A project or section changed. Review the original text again before saving.") }
        var changes: [Mutation] = [], knownLabels = labels
        for line in lines {
            var task = line.task
            guard task.string("user_id") == userID, !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.string("project_id").isEmpty || projects.contains(where: { $0.id == task.string("project_id") }) else { throw AppFailure(message: "Every task needs a title and an available active project.") }
            var values: [JSON] = []
            for value in task["labels"].list {
                if let label = knownLabels.first(where: { $0.id == value.text || $0.name.lowercased() == value.text.lowercased() }) { values.append(.string(label.id)) }
                else {
                    let label = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(userID), "name": value, "color": .string("#8b5cf6")])
                    knownLabels.append(label); values.append(.string(label.id)); changes.append(Mutation(table: "labels", recordID: label.id, method: "POST", fields: label.fields))
                }
            }
            task["labels"] = .array(values)
            changes.append(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields))
        }
        let groups = Dictionary(grouping: changes.filter { $0.table == "tasks" }) { change in
            let row = Record(change.fields)
            return row.string("project_id").isEmpty ? "scope:inbox" : "group:" + row.string("project_id") + ":" + (row.string("section_id").isEmpty ? "none" : row.string("section_id"))
        }
        for key in groups.keys.sorted() {
            let existing = record("view_orders", id: key)
            let ids = (existing?["ids"].list ?? []) + groups[key]!.map { .string($0.recordID) }
            changes.append(Mutation(table: "view_orders", recordID: key, method: existing == nil ? "POST" : "PATCH", fields: ["id": .string(key), "user_id": .string(userID), "ids": .array(ids)]))
        }
        return changes
    }
}


#if DEBUG
extension Store {
    func seedWorkflowFixture() {
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--uitesting"), ProcessInfo.processInfo.arguments.contains("--workflow-fixture") else { return }
        dailyBackupsEnabled = false; disableNotifications(); undoStack = []; redoStack = []
        let parent = "f0742000-1111-4111-8111-000000000001", child = "f0742000-1111-4111-8111-000000000002"
        let projects = [(parent, "Launch lab", ""), (child, "Design studio", parent)].map { id, name, parent in
            Record(["id": .string(id), "user_id": .string(userID), "name": .string(name), "color": .string("#8b5cf6"), "parent_id": parent.isEmpty ? .null : .string(parent), "is_archived": .bool(false), "order_index": .number(parent.isEmpty ? 0 : 1)])
        }
        var task = Record.task(user: userID, project: child, date: Date()); task["title"] = .string("Prepare workflow brief"); task["description"] = .string("Keep the original notes.")
        if ProcessInfo.processInfo.arguments.contains("--task-heading-fixture"),
           Bundle.main.bundleIdentifier?.hasSuffix("workflowteststeameditbridge") == true {
            task["id"] = .string("f1810000-0000-4000-8000-000000000001")
        }
        if ProcessInfo.processInfo.arguments.contains("--print-output-fixture") {
            task["description"] = .string((1...8).map { index in
                "## Design section \(index)\nRésumé, København, 東京, العربية, 🙂. Review **contrast** and _spacing_, then read the [guide](https://example.com/guide).\n- Keep every instruction\n- Check the complete exported document\n```text\nLiteral **code** \(index)\n```"
            }.joined(separator: "\n\n") + "\nFINAL-NATIVE-PRINT-INSTRUCTION")
        }
        if ProcessInfo.processInfo.arguments.contains("--subtask-organizer-fixture") {
            func child(_ suffix: String, _ title: String, _ children: [JSON] = []) -> JSON {
                .object(["id": .string("f1710000-0000-4000-8000-" + suffix), "title": .string(title), "completed": .bool(false),
                         "description": .string("Keep these checklist notes."), "due_date": .string("2027-01-04"), "subtasks": .array(children)])
            }
            task["subtasks"] = .array([child("000000000001", "Planning", [child("000000000002", "Research", [child("000000000004", "Collect references")])]), child("000000000003", "Review")])
        }
        snapshot = Snapshot(tables: ["projects": projects, "tasks": [task]])
        if ProcessInfo.processInfo.arguments.contains("--sharing-filter-fixture"), Bundle.main.bundleIdentifier == "com.dbakp.taskfold.mac.workflowtestsnotes1" {
            task["title"] = .string("Review shared layout")
            var personal = Record.task(user: userID, project: parent, date: Date()); personal["title"] = .string("Prepare private draft")
            var inbox = Record.task(user: userID, date: Date()); inbox["title"] = .string("Capture personal idea")
            snapshot.tables["tasks"] = [task, personal, inbox]
            snapshot.tables["project_collaborators"] = [
                Record(["id": .string("f3910000-0000-4000-8000-000000000001"), "project_id": .string(child), "user_id": .string("f3910000-0000-4000-8000-000000000002"), "status": .string("accepted"), "role": .string("collaborator")]),
                Record(["id": .string("f3910000-0000-4000-8000-000000000003"), "project_id": .string(parent), "status": .string("pending"), "invited_email": .string("sharing-fixture@example.invalid"), "role": .string("collaborator")])]
        }
        if ProcessInfo.processInfo.arguments.contains("--assignment-history-fixture"), Bundle.main.bundleIdentifier == "com.dbakp.taskfold.mac.workflowtestsnotes1" {
            let member = "f4920000-0000-4000-8000-000000000001"
            func assigned(_ title: String, _ recipient: String) -> Record {
                var result = Record.task(user:userID,project:child,date:Date()); result["title"] = .string(title)
                result["task_generation"] = .string(UUID().uuidString.lowercased()); result["assigned_to"] = recipient.isEmpty ? .null : .string(recipient)
                return result
            }
            let mine = assigned("Plan the calm handoff",userID), legacy = assigned("Review earlier assignment",userID)
            let other = assigned("Follow the team handoff",member), unassigned = assigned("Capture the next idea","")
            snapshot.tables["tasks"] = [mine,legacy,other,unassigned]
            TaskAssignmentProvenance.recordLocal(Mutation(table:"tasks",recordID:mine.id,method:"POST",fields:mine.fields),before:nil,after:mine,snapshot:&snapshot,account:userID)
            snapshot.tables[TaskAssignmentProvenance.table,default:[]].append(Record(["id":.string(UUID().uuidString.lowercased()),"task_id":.string(other.id),"task_generation":other["task_generation"],"node_key":.string(""),"node_path":.array([]),"assignee_id":.string(member),"actor_id":.string(member),"event_id":.string(UUID().uuidString.lowercased()),"assigned_at":.string(TaskActivity.stamp(Date())),"origin":.string("recorded"),"active":.bool(true)]))
        }
        if ProcessInfo.processInfo.arguments.contains("--heading-portability-template-fixture"),
           Bundle.main.bundleIdentifier?.hasSuffix("workflowteststeameditbridge") == true {
            do {
                guard let current = record("tasks", id: "f1810000-0000-4000-8000-000000000001") else { throw AppFailure(message: "The heading fixture is unavailable.") }
                var heading = try TaskKind.setting(current, heading: true)
                heading["subtasks"] = SubtaskTree.changing(heading["subtasks"], id: "f1710000-0000-4000-8000-000000000002", fields: ["is_heading": .bool(true)])
                snapshot.tables["tasks"] = [heading]
                let definition = try WorkflowTemplate.capture(kind: .task, id: heading.id, snapshot: snapshot)
                let file = try WorkflowTemplateFile(name: "Reference workflow", document: definition.document)
                let decoded = try WorkflowTemplateFile(data: file.encoded())
                snapshot.tables[WorkflowTemplate.table] = [Record(["id": .string("f2810000-0000-4000-8000-000000000003"), "user_id": .string(userID), "name": .string(decoded.name), "document": decoded.template.document])]
            } catch { self.error = error.localizedDescription }
        }
        if ProcessInfo.processInfo.arguments.contains("--heading-progress-fixture"),
           Bundle.main.bundleIdentifier?.hasSuffix("workflowteststeameditbridge") == true {
            func item(_ suffix: String, _ title: String, heading: Bool = false, done: Bool = false, children: [JSON] = []) -> JSON {
                .object(["id": .string("f5810000-0000-4000-8000-" + suffix), "title": .string(title), "description": .string("Keep the work’s own notes."), "is_heading": .bool(heading), "completed": .bool(done), "subtasks": .array(children)])
            }
            var heading = try! TaskKind.setting(task, heading: true)
            heading["project_id"] = .string(parent); heading["title"] = .string("Launch context")
            heading["due_date"] = .string(Dates.day(Date()))
            var attention = item("000000000001", "Draft the launch note", children: [item("000000000005", "Checklist detail")]).object
            attention["deadline_date"] = .string("2026-01-01")
            heading["subtasks"] = .array([.object(attention), item("000000000002", "Choose the palette", done: true), item("000000000003", "Second phase", heading: true, children: [item("000000000004", "Check the layout")])])
            snapshot.tables["tasks"] = [heading]
        }
        if ProcessInfo.processInfo.arguments.contains("--heading-planner-fixture"),
           Bundle.main.bundleIdentifier?.hasSuffix("workflowteststeameditbridge") == true,
           var heading = record("tasks", id: "f1810000-0000-4000-8000-000000000001"), TaskKind(heading) == .heading {
            let today = Dates.day(Date())
            heading["duration_minutes"] = .number(999)
            heading["subtasks"] = SubtaskTree.changing(heading["subtasks"], id: "f5810000-0000-4000-8000-000000000001", fields: ["due_date": .string(today), "duration_minutes": .number(45)])
            heading["subtasks"] = SubtaskTree.changing(heading["subtasks"], id: "f5810000-0000-4000-8000-000000000004", fields: ["due_date": .string(today), "due_time": .string("09:00"), "duration_minutes": .number(30)])
            snapshot.tables["tasks"] = [heading]
        }
        if ProcessInfo.processInfo.arguments.contains("--heading-inbox-work-fixture"),
           Bundle.main.bundleIdentifier?.hasSuffix("workflowteststeameditbridge") == true,
           var heading = record("tasks", id: "f1810000-0000-4000-8000-000000000001"), TaskKind(heading) == .heading {
            heading["project_id"] = .null; heading["section_id"] = .null
            snapshot.tables["tasks"] = [heading]
        }
        if ProcessInfo.processInfo.arguments.contains("--heading-list-work-fixture"),
           Bundle.main.bundleIdentifier?.hasSuffix("workflowteststeameditbridge") == true,
           var heading = record("tasks", id: "f1810000-0000-4000-8000-000000000001"), TaskKind(heading) == .heading {
            let label = "f6820000-0000-4000-8000-000000000001", view = "f6820000-0000-4000-8000-000000000002"
            heading["priority"] = .number(3)
            heading["subtasks"] = SubtaskTree.changing(heading["subtasks"], id: "f5810000-0000-4000-8000-000000000001", fields: ["priority": .number(1), "labels": .array([.string(label)])])
            heading["subtasks"] = SubtaskTree.changing(heading["subtasks"], id: "f5810000-0000-4000-8000-000000000004", fields: ["priority": .number(2)])
            snapshot.tables["tasks"] = [heading]
            snapshot.tables["labels"] = [Record(["id": .string(label), "user_id": .string(userID), "name": .string("Design work"), "color": .string("#7c5cbf")])]
            snapshot.tables["saved_views"] = [Record(["id": .string(view), "user_id": .string(userID), "name": .string("Priority work"), "query_ast": FilterRule.predicate("priority", "1").document, "sort_by": .string("priority"), "grouping": .string("none")])]
        }
        do { try persist(); seedSharedCaptureFixture() } catch { self.error = error.localizedDescription }
    }
}
#endif


extension Store {
    /// Resolve the displayed incarnation before an action; selection captures its
    /// workspace and raw source so later Save cannot retarget another child.
    func hierarchySelection(for displayed: Record) throws -> TaskHierarchyIndex.Selection {
        guard let path = SubtaskTree.referencePath(displayed.id), let root = activeTasks.first(where: { $0.id == path[0] }) else {
            throw SubtaskTree.Failure(message: "This subtask is no longer accessible. Reopen its parent task.")
        }
        let index = try TaskHierarchyIndex(roots: [root], projects: projects, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration))
        guard let selection = index.selection(displayed.id), selection.item.record == displayed else {
            throw SubtaskTree.Failure(message: "This subtask changed. Reopen its current details before editing it.")
        }
        return selection
    }
    @discardableResult
    func commitHierarchy(_ edits: [TaskHierarchyIndex.Edit]) throws -> Bool {
        let changes = try TaskHierarchyIndex.changes(edits, accessibleRoots: activeTasks, projects: projects, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration))
        guard !changes.isEmpty else { return true }
        guard commit(changes) else { throw SubtaskTree.Failure(message: error ?? "The subtask could not be saved. Your draft is still open.") }
        return true
    }
}


extension Store {
    @discardableResult
    func commitSelection(_ tasks: [Record], action: (Record) -> TaskSelectionPlan.Action) throws -> Bool {
        let workspace = WorkspaceBinding(account: userID, generation: workspaceGeneration)
        let requests = tasks.map { TaskSelectionPlan.Request(task: $0, action: action($0), workspace: workspace) }
        let changes = try TaskSelectionPlan.changes(requests, accessibleRoots: activeTasks, projects: projects, workspace: workspace)
        guard !changes.isEmpty else { return true }
        guard commit(changes) else { throw SubtaskTree.Failure(message: error ?? "The selection could not be saved. Try again.") }
        return true
    }
    func selectionRecord(_ id: String) throws -> Record {
        guard let path = SubtaskTree.referencePath(id) else {
            guard let task = activeTasks.first(where: { $0.id == id }) else { throw SubtaskTree.Failure(message: "This task is no longer accessible.") }
            return task
        }
        guard let root = activeTasks.first(where: { $0.id == path[0] }) else { throw SubtaskTree.Failure(message: "This subtask is no longer accessible.") }
        let index = try TaskHierarchyIndex(roots: [root], projects: projects, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration))
        guard let task = index.item(id)?.record else { throw SubtaskTree.Failure(message: "This subtask moved. Select its current row again.") }
        return task
    }
}


extension Store {
    func hierarchyFilterError(_ rule: FilterRule) -> String? {
        guard rule.usesTaskHierarchy else { return nil }
        do { _ = try taskCache.hierarchyCandidates(for: rule, projects: filterContext.projectReferences, userID: userID); return nil }
        catch { return error.localizedDescription }
    }
}


extension Store {
    @discardableResult
    func duplicateSelection(_ tasks: [Record]) throws -> Bool {
        let changes = try TaskSelectionPlan.duplicateChanges(tasks, accessibleRoots: activeTasks, projects: projects, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration))
        guard !changes.isEmpty else { return true }
        guard commit(changes) else { throw SubtaskTree.Failure(message: error ?? "The copies could not be saved. Try again.") }
        return true
    }
}


extension Store {
    func previewFilterCount(_ rule: FilterRule, includeCompleted: Bool) -> Int {
        matching(TaskQuery(scope: .all, includeCompleted: includeCompleted || (!rule.hasQuerySections && rule.includesCompletion), filter: rule, now: calendarContext.minute, datePreferences: datePhrasePreferences, filterLabels: labels.map { FilterReference(id: $0.id, name: $0.name) }, filterProjects: filterContext.projectReferences, filterSections: rows("sections").map { FilterReference(id: $0.id, name: $0.name, projectID: $0.string("project_id").isEmpty ? nil : $0.string("project_id")) }, filterPeople: filterContext.personReferences, userID: userID)).count
    }
}


extension Store {
    /// The URL boundary checks account/readability before resolving a nested path.
    func widgetLinkedTask(_ url: URL) throws -> Record {
        guard allowsWidgetRecordLink(url), url.scheme == "taskfold", url.host == "task", focusAvailable else { throw WidgetActionFailure("This task widget is unavailable in your current workspace.") }
        return try WidgetRecordLink.task(url, roots: activeTasks, projects: projects, workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration))
    }
    private func widgetFeedbackIsCurrent(_ feedback: WidgetCompletionFeedback) -> Bool {
        guard let task = try? selectionRecord(feedback.taskID), task.completed else { return false }
        guard SubtaskTree.referencePath(feedback.taskID) != nil else { return true }
        guard let selection = try? hierarchySelection(for: task) else { return false }
        return WidgetCompletion.routeContext(selection.item) == feedback.routeContext
    }
}

extension Store {
    private var timeSnoozeEpochKey: String { "taskfold.timeSnoozeEpoch." + userID }
    private var timeSnoozeEpoch: String { UserDefaults.standard.string(forKey: timeSnoozeEpochKey) ?? "" }
    private var queuedTimeSnoozes: [ReminderRequest] {
        guard sharedCaptureAvailable, remindersEnabled else { return [] }
        let entries = (snapshot.timeSnoozes ?? [:]).values.filter { $0.phase == .queued }
        guard !entries.isEmpty else { return [] }
        let tasks = activeTasks, epoch = timeSnoozeEpoch, now = Date()
        return entries.compactMap { $0.request(account: userID, epoch: epoch, tasks: tasks, now: now) }
    }
    private func reconcileTimeSnoozes(generation: UUID) async {
        guard sharedCaptureAvailable, let original = snapshot.timeSnoozes, !original.isEmpty else { return }
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests().compactMap(SystemReminderCenter.decode)
        guard generation == accountGeneration, snapshot.timeSnoozes == original else { return }
        let next = TimeSnoozeOutbox.reconciling(original, account: userID, epoch: timeSnoozeEpoch, tasks: activeTasks,
            enabled: remindersEnabled, pending: pending)
        guard next != original else { return }
        snapshot.timeSnoozes = next
        do { try persist() } catch { snapshot.timeSnoozes = original; reminderStatus = "Snooze recovery could not be saved. It will retry when Taskfold opens." }
    }
    private func transitionTimeSnooze(_ request: ReminderRequest, transition: LocationSnoozeTransition, generation: UUID) async -> LocationSnoozeAcknowledgement {
        guard generation == accountGeneration, sharedCaptureAvailable, remindersEnabled else { return .obsolete }
        let tasks = activeTasks, epoch = timeSnoozeEpoch, now = Date()
        guard let entry = snapshot.timeSnoozes?.values.first(where: { entry in
            entry.phase != .closed && entry.request(account: userID, epoch: epoch, tasks: tasks, now: now)?.matchesSnooze(request) == true
        }) else { return .obsolete }
        let phase: TimeSnoozeIntent.Phase
        switch transition {
        case .reserve: guard entry.phase == .queued else { return .obsolete }; phase = .reserved
        case .installed: guard entry.phase == .reserved else { return .obsolete }; phase = .installed
        case .notSubmitted: guard entry.phase == .reserved else { return .obsolete }; phase = .queued
        case .failed: phase = .closed
        }
        snapshot.timeSnoozes?[entry.id] = entry.changing(to: phase)
        do { try persist(); return .saved }
        catch { snapshot.timeSnoozes?[entry.id] = entry; return .retry }
    }
    /// Save the explicit fire instant before admission. Native submission cannot
    /// begin until its reservation also reaches the durable cache.
    private func saveTimeSnooze(event: DueReminder, minutes: Int, generation: UUID) async {
        guard generation == accountGeneration, sharedCaptureAvailable, remindersEnabled, ReminderSnooze.validMinutes(minutes) else { return }
        if timeSnoozeEpoch.isEmpty { UserDefaults.standard.set(UUID().uuidString.lowercased(), forKey: timeSnoozeEpochKey) }
        let request = ReminderRequest.make(account: userID, event: event,
            fireAt: Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 + Double(minutes * 60))), snoozed: true)
        guard let intent = TimeSnoozeIntent(request: request, epoch: timeSnoozeEpoch) else { return }
        let old = snapshot
        let tasks = activeTasks, epoch = timeSnoozeEpoch, now = Date()
        // Another explicit snooze replaces this reminder's earlier waiting intent.
        for entry in (snapshot.timeSnoozes ?? [:]).values where entry.phase != .closed &&
            entry.request(account: userID, epoch: epoch, tasks: tasks, now: now)?.identifier == request.identifier {
            snapshot.timeSnoozes?[entry.id] = entry.changing(to: .closed)
        }
        if snapshot.timeSnoozes == nil { snapshot.timeSnoozes = [:] }
        snapshot.timeSnoozes?[intent.id] = intent
        do { try persist(acceptingTimeSnooze: intent) }
        catch { snapshot = old; reminderStatus = "The snooze could not be saved. Open the task to try again."; return }
        await reschedule()
        guard generation == accountGeneration, let saved = snapshot.timeSnoozes?[intent.id] else { return }
        switch saved.phase {
        case .installed: reminderStatus = "Snoozed for \(ReminderSnooze.label(minutes)) on this device."
        case .queued: reminderStatus = "Snooze saved for \(request.fireAt.formatted(date: .abbreviated, time: .shortened)). Waiting for notification space; Taskfold will retry when opened."
        case .reserved: reminderStatus = "Confirming your saved snooze. Taskfold will check it when opened."
        case .closed: reminderStatus = "This snooze could not be scheduled. Open the task to review its reminder."
        }
    }
}


extension Store {
    private func stagedTimeSnoozes(previous: Snapshot, proposed: Snapshot, newIntent: TimeSnoozeIntent?) throws -> [String: TimeSnoozeIntent]? {
        if let newIntent { guard newIntent.account == userID, newIntent.epoch == timeSnoozeEpoch else { throw AppFailure(message: "Your workspace changed before the snooze was saved.") } }
        var next = try TimeSnoozeOutbox.staging(previous: previous.timeSnoozes ?? [:], proposed: proposed.timeSnoozes ?? [:], newIntent: newIntent)
        guard !next.isEmpty else { return nil }
        let tasks = activeTasks, epoch = timeSnoozeEpoch, now = Date()
        for entry in next.values where entry.phase != .closed && (!remindersEnabled || entry.request(account: userID, epoch: epoch, tasks: tasks, now: now) == nil) {
            next[entry.id] = entry.changing(to: .closed)
        }
        return next.isEmpty ? nil : next
    }
}

#if DEBUG
extension Store {
    /// Command acceptance through the real Store/Backend, separate from UI input.
    func runLocationHandoffSenderProof() async {
        guard LocationHandoffNativeFixture.enabled else { return }
        var checks: [String] = []
        do {
            func require(_ value: Bool, _ label: String) throws { guard value else { throw AppFailure(message: label) }; checks.append(label) }
            let workspace = WorkspaceBinding(account: userID, generation: workspaceGeneration), before = snapshot
            let task = LocationHandoffNativeFixture.task()
            let place = LocationPrivatePlace.make(account: userID, name: "Sample design studio", latitude: 55.676098, longitude: 12.568337, radius: 250)!
            let proposal = LocationHandoffProposal.make(account: userID, task: task, place: place, transition: .leave, repeats: true, id: LocationHandoffNativeFixture.draftID)!
            do { _ = try await sendLocationHandoff(proposal, workspace: workspace); throw AppFailure(message: "Lost-response fixture did not interrupt") }
            catch { try require(error.localizedDescription.contains("interrupted"), "first put commits but response is lost") }
            let sent = try await sendLocationHandoff(proposal, workspace: workspace)
            try require(sent.id == proposal.id && sent.state == .pending, "retry confirms same immutable proposal")
            let rows = try await locationHandoffs(workspace: workspace)
            try require(rows.count == 1 && rows[0].proposal == proposal, "list recovers one pending proposal")
            let counter = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: LocationHandoffNativeFixture.root.appendingPathComponent("server.json"))).object
            try require(counter["putCalls"] == .number(2) && counter["records"]!.object.count == 1, "retry uploads one logical draft")
            let stale = WorkspaceBinding(account: userID, generation: UUID())
            do { _ = try await sendLocationHandoff(proposal, workspace: stale); throw AppFailure(message: "Stale workspace accepted") }
            catch { try require(error is LocationStorageFailure, "stale workspace refused before upload"); self.error = nil }
            try await discardLocationHandoff(sent, workspace: workspace)
            let terminal = try await locationHandoffs(workspace: workspace)
            try require(terminal.count == 1 && terminal[0].state == .discarded && terminal[0].proposal == nil, "discard removes geometry without task mutation")
            try require(snapshot == before, "send retry list discard leave task cache unchanged")
            let report: [String:JSON] = ["passed":.bool(true),"checks":.array(checks.map(JSON.string))]
            try JSONEncoder().encode(report).write(to: LocationHandoffNativeFixture.root.appendingPathComponent("sender-proof.json"), options: .atomic)
        } catch {
            let report: [String:JSON] = ["passed":.bool(false),"checks":.array(checks.map(JSON.string)),"error":.string(error.localizedDescription)]
            try? JSONEncoder().encode(report).write(to: LocationHandoffNativeFixture.root.appendingPathComponent("sender-proof.json"), options: .atomic)
        }
    }
}
#endif


struct AccountRemovalRecoveryBanner: View {
    @Environment(Store.self) private var store
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        if let status = store.accountRemovalStatus {
            let layout = textSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    Label(store.accountRemovalBusy ? "Finishing account removal…" : "Account removal paused", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.callout.weight(.semibold))
                    if !store.accountRemovalBusy {
                        Text("Remaining device copies stay saved.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status)
                .accessibilityIdentifier("accountRemovalStatus")
                Button("Retry") { Task { await store.resumeAccountRemovals() } }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(store.accountRemovalBusy)
                    .accessibilityIdentifier("retryAccountRemoval")
            }.padding().background(.regularMaterial)
        }
    }
}

#if DEBUG
extension Store {
    func runAccountRemovalNativeProof() async {
        guard AccountRemovalNativeFixture.enabled else { return }
        var checks: [String: Bool] = [:]
        func require(_ key: String, _ value: Bool) throws {
            checks[key] = value
            if !value { throw AppFailure(message: "Native removal proof failed: " + key) }
        }
        do {
            let account = AccountRemovalNativeFixture.owner, outside = AccountRemovalNativeFixture.other
            let io = CalendarKeychainIO(service: (Bundle.main.bundleIdentifier ?? "") + ".account-removal")
            let old = try await accountRemovalVault.pending()
            try require("reservedRecoveryOnly", old.allSatisfy { $0.account == account || $0.account == outside })
            try io.remove(key: "unfinished-removals-v1")
            var a = Record.task(user: account); a["title"] = .string("Synthetic owner work")
            snapshot = Snapshot(tables: ["tasks": [a]])
            localMode = false; signedIn = true; workspaceCacheReadable = true
            removalPendingAccounts = []; accountRemovalStatus = nil
            try persist()
            let aCache = cacheURL, before = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cacheURL))
            var b = Record.task(user: outside); b["title"] = .string("Keep outsider work")
            var bSnapshot = Snapshot(tables: ["tasks": [b]])
            bSnapshot.pending = [Mutation(table: "tasks", recordID: b.id, method: "POST", fields: b.fields)]
            let bCache = aCache.deletingLastPathComponent().appendingPathComponent(outside + ".json")
            try JSONEncoder().encode(bSnapshot).write(to: bCache, options: .atomic)
            var bBytes = try Data(contentsOf: bCache)
            let ownedVault = backupVault.directory
            let outsiderVault = ownedVault.deletingLastPathComponent().appendingPathComponent(WorkspaceBackup.stableID("vault", outside))
            let ownBackup = backupVault
            let ownEntry = try ownBackup.save(snapshot, kind: "Synthetic")
            let outsideBackup = BackupVault(directory: outsiderVault, account: outside, key: { try BackupVault.deviceKey(account: outside) })
            let outsideEntry = try outsideBackup.save(bSnapshot, kind: "Synthetic")
            let outsideCiphertext = try Data(contentsOf: outsideBackup.file(outsideEntry))
            try require("encryptedRecoveryRoundtrip", try ownBackup.load(ownEntry).snapshot == snapshot && outsideBackup.load(outsideEntry).snapshot == bSnapshot)
            try require("backupKeysExistBeforeRemoval", AccountRemovalNativeFixture.backupKeyStatus(account) == errSecSuccess && AccountRemovalNativeFixture.backupKeyStatus(outside) == errSecSuccess)
            let places = LocationPrivateStore(applicationSupport: LocationPrivateStore.applicationSupport)
            let pinA = LocationPrivatePlace.make(account: account, name: "Synthetic A", latitude: 55, longitude: 12, radius: 200)!
            let pinB = LocationPrivatePlace.make(account: outside, name: "Keep B", latitude: 56, longitude: 13, radius: 250)!
            _ = try await places.save(pinA); _ = try await places.save(pinB)
            let shares = try sharedCaptureDisk()
            let aWorkspace = SharedCaptureWorkspace(account: account, generation: workspaceGeneration, label: "Synthetic A")
            try shares.publish(aWorkspace); try shares.save(SharedCaptureDraft(workspace: aWorkspace, content: .init(title: "Synthetic A draft")))
            for invalid in [WorkspaceBinding(account: outside, generation: workspaceGeneration), WorkspaceBinding(account: account, generation: UUID())] {
                do { try await deleteAccount(expected: invalid); throw AppFailure(message: "Stale confirmation was accepted") }
                catch { try require("staleConfirmationRefused", AccountRemovalProofHTTP.count == 0 && !accountRemovalBlocked) }
            }
            if AccountRemovalNativeFixture.switching {
                let deleting = Task { try await self.deleteAccount(expected: WorkspaceBinding(account: account, generation: workspaceGeneration)) }
                for _ in 0..<300 {
                    if AccountRemovalProofHTTP.count > 0 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try require("heldOriginalRequest", AccountRemovalProofHTTP.count == 1)
                try await backend.accept(AccountRemovalNativeFixture.session(outside))
                await authenticated()
                bBytes = try Data(contentsOf: bCache)
                let active = snapshot
                let context = SharedCaptureWorkspace(account: outside, generation: workspaceGeneration, label: backend.session?.user.email ?? "Taskfold workspace")
                try shares.publish(context); let draft = try SharedCaptureDraft(workspace: context, content: .init(title: "Keep B draft")); try shares.save(draft)
                AccountRemovalProofHTTP.release(); try await deleting.value
                try require("otherSessionKept", backend.session?.user.id == outside && signedIn && userID == outside)
                try require("otherMemoryKept", snapshot == active)
                let activeWidget = try JSONDecoder().decode([String: JSON].self, from: widgetActionDisk().read().data!)
                try require("otherWidgetKept", activeWidget["account"] == .string(outside) && activeWidget["tasks"]?.list.contains(where: { $0.object["title"] == .string("Keep outsider work") }) == true)
                try require("otherShareKept", try shares.workspace() == context && shares.drafts(account: outside) == [draft])
            } else if AccountRemovalNativeFixture.expiring {
                try await deleteAccount(expected: WorkspaceBinding(account: account, generation: workspaceGeneration))
                try require("expiredAuthorizationRenewed", AccountRemovalProofHTTP.count == 2 && AccountRemovalProofHTTP.refreshCount == 1)
                try require("confirmedRemovalSignsOut", backend.session == nil && !signedIn)
            } else {
                do { try await deleteAccount(expected: WorkspaceBinding(account: account, generation: workspaceGeneration)); throw AppFailure(message: "Synthetic failure was accepted") }
                catch { try require("interruptedResultRefused", AccountRemovalProofHTTP.count == 1) }
                let diagnosticEncoder = JSONEncoder(); diagnosticEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                try diagnosticEncoder.encode(before).write(to: AccountRemovalNativeFixture.root.appendingPathComponent("before-cache.json"))
                let afterFailure = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: aCache))
                try diagnosticEncoder.encode(afterFailure).write(to: AccountRemovalNativeFixture.root.appendingPathComponent("after-cache.json"))
                try require("failedRequestKeepsCache", afterFailure == before)
                try require("failedRequestKeepsSession", backend.session?.user.id == account && signedIn)
                let pausedWidget = try JSONDecoder().decode([String: JSON].self, from: widgetActionDisk().read().data!)
                try require("pendingWidgetPrivate", pausedWidget["account"] == .string("") && pausedWidget["tasks"]?.list.isEmpty == true)
                let restarted = AccountRemovalVault(io: io), pending = try await restarted.pending()
                try require("originalAuthorizationDurable", pending.count == 1 && pending.first?.authorization == "synthetic-A" && pending.first?.confirmed == false)
                try require("pendingWorkspaceQuiescent", accountRemovalBlocked && !commit([Mutation(table: "tasks", recordID: a.id, method: "PATCH", fields: ["title": .string("Must not save")])]))
                await resumeAccountRemovals()
                try require("sameAuthorizationRetried", AccountRemovalProofHTTP.count == 2)
                try require("confirmedRemovalSignsOut", backend.session == nil && !signedIn)
            }
            try require("ownerCacheRemoved", !FileManager.default.fileExists(atPath: aCache.path))
            try require("outsiderCacheExact", try Data(contentsOf: bCache) == bBytes)
            try require("ownedRecoveryRemoved", !FileManager.default.fileExists(atPath: ownedVault.path))
            try require("outsiderRecoveryExact", try Data(contentsOf: outsideBackup.file(outsideEntry)) == outsideCiphertext && outsideBackup.load(outsideEntry).snapshot == bSnapshot)
            try require("ownedBackupKeyRemoved", AccountRemovalNativeFixture.backupKeyStatus(account) == errSecItemNotFound)
            try require("outsiderBackupKeyKept", AccountRemovalNativeFixture.backupKeyStatus(outside) == errSecSuccess)
            let archive = try await places.snapshot()
            try require("privatePlacesScoped", archive?.places(for: account).isEmpty == true && archive?.places(for: outside) == [pinB])
            let remaining = try await accountRemovalVault.pending()
            try require("recoveryCommandFinished", remaining.isEmpty && accountRemovalStatus == nil)
            try require("staleCacheWriteRefused", AccountRemovalDisk(directory: aCache.deletingLastPathComponent(), account: account).removed)
            if !AccountRemovalNativeFixture.switching {
                try await backend.accept(AccountRemovalNativeFixture.session(account))
                await authenticated()
                try require("lateRemovedAccountCannotReopen", backend.session == nil && !signedIn)
            }
            // Explicitly remove only the synthetic outsider's test key/session
            // after preservation is proved; do not leave credentials behind.
            try BackupVault.removeDeviceKey(account: outside)
            if backend.session?.user.id == outside { try await backend.clearSession() }
            let result: [String: Any] = ["status": "passed", "scenario": AccountRemovalNativeFixture.switching ? "late-account-switch" : AccountRemovalNativeFixture.expiring ? "expired-authorization" : "failed-reply-retry", "checks": checks, "scope": "Real native Store and file/Keychain cleanup with synthetic accounts and simulated endpoint replies. Fixture-owned sharing directory; not live Auth/Storage or normal App Group acceptance."]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: AccountRemovalNativeFixture.result, options: .atomic)
        } catch {
            let result: [String: Any] = ["status": "failed", "checks": checks, "error": error.localizedDescription]
            try? FileManager.default.createDirectory(at: AccountRemovalNativeFixture.root, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: AccountRemovalNativeFixture.result, options: .atomic)
        }
    }
}
#endif

#if DEBUG
/// Reserved isolated bundle only. Only the synthetic recipient lookup is answered;
/// this exercises native Store persistence, not a hosted service acceptance.
@MainActor enum TeamEditorNativeFixture {
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowteststeameditbridge", "com.dbakp.taskfold.mac.workflowteststeameditbridge"].contains(Bundle.main.bundleIdentifier ?? "") && ProcessInfo.processInfo.arguments.contains("--team-editor-testing")
    }
    static var historyRequest: EditHistoryRequest?
    static let account = "ec240000-0000-4000-8000-000000000001"
    static let taskID = "ec240000-0000-4000-8000-000000000002"
    static let childID = "ec240000-0000-4000-8000-000000000005"
    static let siblingID = "ec240000-0000-4000-8000-000000000006"
    static let recipientID = "ec240000-0000-4000-8000-000000000007"
    static func removeRecipient() { UserDefaults.standard.set(true, forKey: "teamEditorRecipientUnavailable") }
    static func recipientData() -> Data {
        var people: [[String: Any]] = [["user_id": account, "role": "editor", "display_name": NSNull()]]
        if !UserDefaults.standard.bool(forKey: "teamEditorRecipientUnavailable") {
            people.append(["user_id": recipientID, "role": "editor", "display_name": "Riley Chen"])
        }
        return try! JSONSerialization.data(withJSONObject: ["recipient_protocol": 1, "account": account, "team_id": teamID, "project_id": projectID, "access_token": String(repeating: "a", count: 64), "recipients": people])
    }
    static let projectID = "ec240000-0000-4000-8000-000000000003"
    static let teamID = "ec240000-0000-4000-8000-000000000004"
    static let personalPlanningProject = "ec240000-0000-4000-8000-000000000041"
    static func backend() -> Backend {
        if ProjectAdoptionNativeFixture.enabled { return ProjectAdoptionNativeFixture.backend() }
        if TeamTemplateNativeFixture.enabled { return TeamTemplateNativeFixture.backend() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamEditorNoNetwork.self]
        let session = try! JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration: ["URL": "https://synthetic.example", "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: session, persistSession: { _ in })
    }
    static func boundary(viewer: Bool = false) throws -> TeamWorkspaceBoundary {
        var rows: [JSON] = [.object(["id": .string(projectID), "team_id": .string(teamID), "role": .string(viewer ? "viewer" : "editor"), "archived": .bool(false), "can_send_tasks": .bool(!viewer)])]
        if ProcessInfo.processInfo.arguments.contains("--team-move-testing") {
            rows.append(.object(["id": .string(TeamTaskMoveNativePeer.destination), "team_id": .string(teamID), "role": .string(viewer ? "viewer" : "editor"), "archived": .bool(false), "can_send_tasks": .bool(!viewer)]))
            rows.append(.object(["id": .string(TeamTaskMoveNativePeer.viewerProject), "team_id": .string(teamID), "role": .string("viewer"), "archived": .bool(false), "can_send_tasks": .bool(false)]))
        }
        if ProcessInfo.processInfo.arguments.contains("--team-planning-personal-testing") {
            rows.append(.object(["id": .string(personalPlanningProject), "team_id": .null, "role": .string("owner"), "archived": .bool(false), "can_send_tasks": .bool(true)]))
            rows.sort { $0.object["id"]!.text < $1.object["id"]!.text }
        }
        return try TeamWorkspaceBoundary([
            "workspace_boundary_protocol": .number(1), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false),
            "task_types_protocol": .number(ProcessInfo.processInfo.arguments.contains("--team-heading-testing") && !viewer && !ProcessInfo.processInfo.arguments.contains("--team-heading-capability-off") && !UserDefaults.standard.bool(forKey: "teamHeadingCapabilityPaused") ? 1 : 0),
            "task_type_lifecycle_protocol": .number(ProcessInfo.processInfo.arguments.contains("--team-heading-testing") ? 1 : 0),
            "account": .string(account), "token": .string(String(repeating: viewer ? "b" : (ProcessInfo.processInfo.arguments.contains("--team-heading-testing") && UserDefaults.standard.bool(forKey: "teamHeadingCapabilityPaused") ? "c" : "a"), count: 64)),
            "teams": .array([.object(["id": .string(teamID), "state": .string("active"), "revision": .number(1), "access_revision": .number(viewer ? 2 : 1)])]),
            "projects": .array(rows)
        ], account: account, origin: "https://synthetic.example")
    }
}
private final class TeamEditorNoNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request
        Task { @MainActor in
            TeamRecoveryRaceNativeFixture.observe(request)
            if let data = TeamBatchRecoveryNativePeer.response(request), let url = request.url {
                let delivered: Data
                do { delivered = try await TeamRecoveryRaceNativeFixture.deliver(data, request: request) }
                catch { client?.urlProtocol(self, didFailWithError: error); return }

                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: delivered); client?.urlProtocolDidFinishLoading(self); return
            }
            guard TeamEditorNativeFixture.enabled,
                  request.url?.absoluteString == "https://synthetic.example/rest/v1/rpc/taskfold_team_task_recipients",
                  request.httpMethod == "POST" else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
            }
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable && data.count < 65536 {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
                }
                body = data
            }
            guard let body, let params = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  params == ["_team_id": TeamEditorNativeFixture.teamID, "_project_id": TeamEditorNativeFixture.projectID] else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: TeamEditorNativeFixture.recipientData())
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
extension Store {
    private func prepareTeamEditorNativeFixture() {
        guard TeamEditorNativeFixture.enabled else { return }
        if ProjectAdoptionNativeFixture.enabled { prepareProjectAdoptionNativeFixture(); return }
        dailyBackupsEnabled = false
        if ProcessInfo.processInfo.arguments.contains("--team-editor-reset") {
            UserDefaults.standard.removeObject(forKey: "teamHeadingCapabilityPaused")
            teamAccessMask = nil
            try? FileManager.default.removeItem(at: AccountRemovalDisk(directory: cacheURL.deletingLastPathComponent(), account: userID).teamAccessFence)
        }
        if TeamBatchRecoveryNativePeer.blockedSync { try? FileManager.default.removeItem(at: TeamBatchRecoveryNativePeer.traceFile) }
        if TeamBatchRecoveryNativePeer.recurring, ProcessInfo.processInfo.arguments.contains("--team-editor-reset") { try? FileManager.default.removeItem(at: TeamBatchRecoveryNativePeer.recurringProof) }
        let reset = ProcessInfo.processInfo.arguments.contains("--team-editor-reset")
        let preserveMissing = ProcessInfo.processInfo.arguments.contains("--team-recorded-draft-testing")
        guard reset || (!preserveMissing && record("tasks", id: TeamEditorNativeFixture.taskID) == nil) else { return }
        UserDefaults.standard.removeObject(forKey: "teamEditorRecipientUnavailable")
        do {
            var row = Record.task(user: "ec240000-0000-4000-8000-000000000099", project: TeamEditorNativeFixture.projectID)
            row["id"] = .string(TeamEditorNativeFixture.taskID); row["title"] = .string("Team editor proof"); row["description"] = .string("Original team notes")
            row["opaque_future"] = .object(["preserved": .bool(true)])
            row["subtasks"] = .array([
                .object(["id": .string(TeamEditorNativeFixture.childID), "title": .string("Review the layout"), "description": .string("Original child notes"), "completed": .bool(false), "priority": .number(4), "subtasks": .array([]), "opaque_child": .bool(true)]),
                .object(["id": .string(TeamEditorNativeFixture.siblingID), "title": .string("Keep the workshop notes"), "description": .string("Unchanged sibling notes"), "completed": .bool(false), "subtasks": .array([])])
            ])
            let project = Record(["id": .string(TeamEditorNativeFixture.projectID), "user_id": row["user_id"], "name": .string("Design workshop")])
            var tasks = [row], projects = [project], labels: [Record] = []
            if ProcessInfo.processInfo.arguments.contains("--team-label-testing") {
                row["labels"] = .array([.string("Design"), .string("ec240000-0000-4000-8000-000000000009")])
                row["subtasks"] = SubtaskTree.changing(row["subtasks"], id: TeamEditorNativeFixture.childID, fields: ["labels": .array([.string("Child design")])])
                row["subtasks"] = SubtaskTree.changing(row["subtasks"], id: TeamEditorNativeFixture.siblingID, fields: ["labels": .array([.string("Review")])])
                labels = [Record(["id": .string("ec240000-0000-4000-8000-000000000008"), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Design")]),
                          Record(["id": .string("ec240000-0000-4000-8000-000000000010"), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Personal only")])]
                let privateProject = Record(["id": .string("ec240000-0000-4000-8000-000000000012"), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Private test project")])
                var privateTask = Record.task(user: TeamEditorNativeFixture.account, project: privateProject.id)
                privateTask["title"] = .string("Private test work"); privateTask["labels"] = .array([.string("Private project label")])
                tasks = [row, privateTask]; projects.append(privateProject)
            }
            if ProcessInfo.processInfo.arguments.contains("--team-reminder-testing") {
                var local = ReminderSpec.relative(-5, id: "ec240000-0000-4000-8000-000000000021").raw
                local["future_row"] = .object(["keep": .bool(true)])
                var other = ReminderSpec.relative(-45, id: "ec240000-0000-4000-8000-000000000024").raw; other["channels"] = .array([.string("email")])
                row["reminder_specs"] = .array([.object(local),
                    .object(["id": .string("ec240000-0000-4000-8000-000000000022"), "version": .number(99), "kind": .string("future"), "hidden": .string("Hidden future instructions")]),
                    .object(["id": .string("ec240000-0000-4000-8000-000000000023"), "version": .number(77), "kind": .string("location"), "place_label": .string("Private studio"), "latitude_e6": .number(1), "longitude_e6": .number(2)]), .object(other)])
                row["reminders"] = .array([.string("legacy-time-cue")]); row["due_date"] = .string(Dates.day(Date().addingTimeInterval(86400))); row["due_time"] = .string("09:00"); row["time_zone"] = .string("UTC")
                let privateProject = Record(["id": .string("ec240000-0000-4000-8000-000000000026"), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Private reminder project")])
                var privateTask = Record.task(user: TeamEditorNativeFixture.account, project: privateProject.id)
                privateTask["id"] = .string("ec240000-0000-4000-8000-000000000025"); privateTask["title"] = .string("Personal reminder proof")
                privateTask["reminder_specs"] = .array([.object(ReminderSpec.relative(-15, id: "ec240000-0000-4000-8000-000000000027").raw)])
                tasks = [row, privateTask]; projects.append(privateProject)
            }
            if ProcessInfo.processInfo.arguments.contains("--team-repeat-testing") {
                row["due_date"] = .string("2026-10-25"); row["due_time"] = .string("09:00"); row["time_zone"] = .string("Europe/Copenhagen")
                row["is_recurring"] = .bool(false); row["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)])
                row["recurrence_end_date"] = .string("2027-10-25")
                if ProcessInfo.processInfo.arguments.contains("--team-repeat-future") { row["recurrence_pattern"] = .object(["type": .string("hourly"), "future": .bool(true)]) }
            }
            if TeamBatchRecoveryNativePeer.recurring {
                row["is_recurring"] = .bool(true); row["due_date"] = .string("2026-10-25"); row["due_time"] = .string("09:00"); row["time_zone"] = .string("Europe/Copenhagen")
                row["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)])
                row["recurrence_end_date"] = .string("2027-10-25")
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
                row["scheduled_at"] = .string(ISO8601DateFormatter().string(from: calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!))
                row["subtasks"] = SubtaskTree.changing(row["subtasks"], id: TeamEditorNativeFixture.childID, fields: ["completed": .bool(true)])
            }
            tasks[0] = row
            if ProcessInfo.processInfo.arguments.contains("--team-batch-testing") {
                var next = Record.task(user: row.string("user_id"), project: TeamEditorNativeFixture.projectID)
                next["id"] = .string("ec240000-0000-4000-8000-000000000031")
                next["title"] = .string("Next workshop review"); next["description"] = .string("Keep the selected occurrence notes")
                next["recurrence_parent_id"] = row["id"]
                var later = Record.task(user: row.string("user_id"), project: TeamEditorNativeFixture.projectID)
                later["id"] = .string("ec240000-0000-4000-8000-000000000032")
                later["title"] = .string("Later workshop review"); later["description"] = .string("Keep this unselected occurrence")
                later["recurrence_parent_id"] = row["id"]
                tasks += [next, later]
            }
            if ProcessInfo.processInfo.arguments.contains("--team-planning-input-testing") {
                for index in tasks.indices {
                    let offset = min(index, 2)
                    tasks[index]["deadline_date"] = .string("2026-11-\(10 + offset)")
                    tasks[index]["duration_minutes"] = .number(Double([25, 45, 60][offset]))
                    tasks[index]["due_date"] = .string(String(format: "2026-11-%02d", 5 + offset))
                    tasks[index]["due_time"] = .string("09:30"); tasks[index]["time_zone"] = .string("UTC")
                    tasks[index]["scheduled_at"] = .string(String(format: "2026-11-%02dT09:30:00.000Z", 5 + offset))
                }
                if ProcessInfo.processInfo.arguments.contains("--team-label-batch-testing") {
                    let labels: [[JSON]] = [[.string("Design"), .string("ec240000-0000-4000-8000-000000000009")], [.string("design"), .string("Keep")], [.string("Unselected")]]
                    for index in tasks.indices { tasks[index]["labels"] = .array(labels[min(index, 2)]) }
                }
                if ProcessInfo.processInfo.arguments.contains("--team-planning-personal-testing") {
                    projects.append(Record(["id": .string(TeamEditorNativeFixture.personalPlanningProject), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Personal planning studio")]))
                    for index in 0..<3 {
                        var task = Record.task(user: TeamEditorNativeFixture.account, project: TeamEditorNativeFixture.personalPlanningProject)
                        task["id"] = .string("ec240000-0000-4000-8000-00000000005\(index + 1)")
                        task["title"] = .string("Personal planning \(index + 1)"); task["description"] = .string("Keep personal notes \(index + 1)")
                        task["duration_minutes"] = .number(Double([25, 45, 60][index])); task["deadline_date"] = .string("2026-11-12")
                        tasks.append(task)
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--team-template-testing") {
                tasks[0]["labels"] = .array([.string("Launch shared")])
                tasks[0]["subtasks"] = SubtaskTree.changing(tasks[0]["subtasks"], id: TeamEditorNativeFixture.childID, fields: ["labels": .array([.string("Outline shared")])])
                labels = [Record(["id": .string("Launch shared"), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Private catalog name"), "color": .string("#112233")])]
            }
            snapshot = Snapshot(tables: ["tasks": tasks, "projects": projects, "labels": labels])
            if TeamTaskMoveNativePeer.enabled {
                row["section_id"] = .null
                row["assigned_to"] = .string(TeamEditorNativeFixture.recipientID)
                row["subtasks"] = SubtaskTree.changing(row["subtasks"], id: TeamEditorNativeFixture.childID, fields: ["assigned_to": .string(TeamEditorNativeFixture.recipientID)])
                tasks = [row]
                projects += [Record(["id": .string(TeamTaskMoveNativePeer.destination), "user_id": row["user_id"], "name": .string("Launch studio")]), Record(["id": .string(TeamTaskMoveNativePeer.viewerProject), "user_id": row["user_id"], "name": .string("Read-only studio")])]
                try TeamTaskMoveNativePeer.write(TeamTaskMoveNativePeer.State(tasks: tasks))
                UserDefaults.standard.removeObject(forKey: "teamMoveLoseReply")
                snapshot.tables["tasks"] = tasks; snapshot.tables["projects"] = projects
            }
            if TeamTemplateNativeFixture.enabled {
                try TeamTemplateNativeFixture.reset()
                snapshot.tables[WorkflowTemplate.table] = [TeamTemplateNativeFixture.personal]
                let workflows = backupVault.directory.appendingPathComponent("Shared workflow requests", isDirectory: true)
                if FileManager.default.fileExists(atPath: workflows.path) { try FileManager.default.removeItem(at: workflows) }
                let requests = backupVault.directory.appendingPathComponent("Team template requests", isDirectory: true)
                if FileManager.default.fileExists(atPath: requests.path) { try FileManager.default.removeItem(at: requests) }
            }
            snapshot.teamWorkspace = try TeamWorkspaceCache(boundary: TeamEditorNativeFixture.boundary(), previous: nil, pending: [], tasks: tasks)
            try persist()
            try seedTeamCompletionRecoveryFixture()
        } catch { self.error = error.localizedDescription }
    }
    func changeTeamLabelCatalogFixture() {
        guard TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-label-testing"),
              let original = record("labels", id: "ec240000-0000-4000-8000-000000000008") else { return }
        var renamed = original; renamed["name"] = .string("Private design")
        guard save("labels", renamed), save("labels", original) else { return }
        remove("labels", original.id)
    }
    func changeTeamEditorFixtureSibling() {
        guard TeamEditorNativeFixture.enabled,
              let index = snapshot.tables["tasks"]?.firstIndex(where: { $0.id == TeamEditorNativeFixture.taskID }) else { return }
        snapshot.tables["tasks"]![index]["subtasks"] = SubtaskTree.changing(snapshot.tables["tasks"]![index]["subtasks"], id: TeamEditorNativeFixture.siblingID, fields: ["title": .string("Sibling updated elsewhere")])
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func changeTeamDeletionFixtureSource() {
        guard TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-delete-testing"),
              let index = snapshot.tables["tasks"]?.firstIndex(where: { $0.id == TeamEditorNativeFixture.taskID }) else { return }
        snapshot.tables["tasks"]![index]["description"] = .string("A newer saved design decision")
        try? persist()
    }
    func failTeamCreationFixtureSave() {
        guard TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-create-testing") else { return }
        savedFilterFixtureFailNextPersist = true
    }
    func failTeamDeletionFixtureSave() {
        guard TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-delete-testing") else { return }
        savedFilterFixtureFailNextPersist = true
    }
    func pauseTeamHeadingCapabilityFixture() {
        guard TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-heading-testing") else { return }
        UserDefaults.standard.set(true, forKey: "teamHeadingCapabilityPaused")
        do {
            snapshot.teamWorkspace = try TeamWorkspaceCache(boundary: TeamEditorNativeFixture.boundary(), previous: snapshot.teamWorkspace, pending: snapshot.pending, tasks: snapshot.tables["tasks"] ?? [])
            try persist()
        } catch { self.error = error.localizedDescription }
    }
    func revokeTeamEditorNativeFixture() {
        guard TeamEditorNativeFixture.enabled else { return }
        do {
            snapshot.teamWorkspace = try TeamWorkspaceCache(boundary: TeamEditorNativeFixture.boundary(viewer: true), previous: snapshot.teamWorkspace, pending: snapshot.pending, tasks: snapshot.tables["tasks"] ?? [])
            try persist()
        } catch { self.error = error.localizedDescription }
    }
}
#endif

#if DEBUG
/// File-backed synthetic peer in the reserved native host. It never sends HTTP
/// or touches a real account. Actual PostgreSQL contracts have separate tests.
@MainActor final class TeamTaskMoveNativePeer: TeamTaskMoveService {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--team-move-testing") }
    static let destination = "ec240000-0000-4000-8000-000000000040"
    static let viewerProject = "ec240000-0000-4000-8000-000000000041"
    static let foreignProject = "ec240000-0000-4000-8000-000000000042"
    static var journalPrepared = false
    struct State: Codable { var tasks: [Record]; var before: [String: Record] = [:]; var commands: [String: TeamTaskMoveCommand] = [:]; var replies: [String: [String: JSON]] = [:] }
    private weak var store: Store?
    init(store: Store) { self.store = store }
    static var file: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldTeamMoveNative/server.json") }
    static func write(_ state: State) throws {
        guard enabled else { throw CancellationError() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
    static func read() throws -> State { guard enabled else { throw CancellationError() }; return try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
    static func proof(_ scope: TeamTaskMoveScope, _ task: Record, _ expires: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return CalendarOAuthConfiguration.digest(String(decoding: try encoder.encode(["scope": JSON.object(scope.body), "task": .object(task.fields), "expires": .string(expires)]), as: UTF8.self))
    }
    private func task(_ scope: TeamTaskMoveScope, state: State) throws -> Record {
        guard Self.enabled, let store, scope.account == TeamEditorNativeFixture.account, scope.origin == "https://synthetic.example", scope.team == TeamEditorNativeFixture.teamID,
              let token = store.nativeConversationTeamCache?.boundary.raw["token"]?.text, store.teamTaskMoveReviewCurrent(scope, token: token),
              let task = state.tasks.first(where: { $0.id == scope.task }), task.string("project_id") == scope.source, task.string("task_generation") == scope.generation else { throw TeamTaskMoveCommand.invalid }
        if let related = scope.undoes {
            guard let command = state.commands[related], command.scope.source == scope.destination, command.scope.destination == scope.source,
                  state.replies[related]?["task"] == .object(task.fields) else { throw TeamTaskMoveCommand.invalid }
        }
        return task
    }
    func teamTaskMoveReview(_ scope: TeamTaskMoveScope) async throws -> TeamTaskMoveReview {
        let state = try Self.read(), row = try task(scope, state: state)
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1800))
        let original = scope.undoes.flatMap { state.before[$0] }
        let currentCount = (row.string("assigned_to").isEmpty ? 0 : 1) + (try TeamChecklist.indexed(row["subtasks"])).values.filter { !($0["assigned_to"]?.text ?? "").isEmpty }.count
        let restoredCount = try original.map { value in (value.string("assigned_to").isEmpty ? 0 : 1) + (try TeamChecklist.indexed(value["subtasks"])).values.filter { !($0["assigned_to"]?.text ?? "").isEmpty }.count } ?? 0
        var raw = scope.body; raw.removeValue(forKey: "undoes")
        raw.merge(["move_review_protocol": .number(1), "account": .string(scope.account), "related_request": scope.undoes.map(JSON.string) ?? .null,
                   "review_token": .string(try Self.proof(scope, row, date)), "expires_at": .string(date), "task": .object(row.fields),
                   "source_name": .string(store?.record("projects", id: scope.source)?.name ?? "Shared project"), "destination_name": .string(store?.record("projects", id: scope.destination)?.name ?? "Shared project"), "destination_visibility": .string("team"),
                   "cleared_assignments": .number(scope.undoes == nil ? Double(currentCount) : 0), "restored_assignments": .number(Double(restoredCount)), "discussion_count": .number(1)]) { _, new in new }
        return try TeamTaskMoveReview(raw, scope: scope)
    }
    func teamTaskMove(_ command: TeamTaskMoveCommand) async throws -> TeamTaskMoveReceipt {
        guard Self.enabled else { throw CancellationError() }
        var state = try Self.read()
        if let saved = state.commands[command.id] {
            guard saved == command else { throw TeamTaskMoveCommand.invalid }
            var raw = state.replies[command.id]!; raw["replayed"] = .bool(true)
            raw["task"] = state.tasks.first(where: { $0.id == command.scope.task && $0.string("project_id") == command.scope.destination && $0.string("task_generation") == command.scope.generation }).map { .object($0.fields) } ?? .null
            return try command.confirmed(raw)
        }
        let before = try task(command.scope, state: state), expiry = try TeamOrganizationValue.date(command.body["expires_at"])
        guard expiry > Date(), command.body["review_token"] == .string(try Self.proof(command.scope, before, command.body["expires_at"]!.text)) else { throw TeamTaskMoveCommand.invalid }
        var after = before; after["project_id"] = .string(command.scope.destination)
        if let related = command.scope.undoes, let original = state.before[related] {
            for key in ["section_id", "assigned_to", "subtasks"] { after[key] = original[key] }
        } else {
            func clear(_ value: JSON) -> JSON {
                .array(value.list.map { child in var row = child.object; row.removeValue(forKey: "assigned_to"); if let nested = row["subtasks"] { row["subtasks"] = clear(nested) }; return .object(row) })
            }
            after["assigned_to"] = .null; after["section_id"] = .null; after["subtasks"] = clear(after["subtasks"])
        }
        var raw = command.scope.body; raw.removeValue(forKey: "undoes")
        raw.merge(["protocol": .number(1), "account": .string(command.account), "request_id": .string(command.id), "operation": .string(command.operation), "related_request": command.scope.undoes.map(JSON.string) ?? .null, "replayed": .bool(false), "task": .object(after.fields)]) { _, new in new }
        state.tasks[state.tasks.firstIndex(where: { $0.id == before.id })!] = after
        state.before[command.id] = before; state.commands[command.id] = command; state.replies[command.id] = raw; try Self.write(state)
        if UserDefaults.standard.bool(forKey: "teamMoveLoseReply") { UserDefaults.standard.removeObject(forKey: "teamMoveLoseReply"); throw URLError(.networkConnectionLost) }
        return try command.confirmed(raw)
    }
}
extension Store {
    func prepareTeamTaskMoveNativeJournal() async {
        guard TeamTaskMoveNativePeer.enabled, !TeamTaskMoveNativePeer.journalPrepared else { return }
        TeamTaskMoveNativePeer.journalPrepared = true
        if ProcessInfo.processInfo.arguments.contains("--team-editor-reset") {
            do { try await teamTaskMoveVault.removeAccount(TeamEditorNativeFixture.account, origin: "https://synthetic.example") } catch { self.error = error.localizedDescription }
        }
    }
    func applyTeamTaskMoveNativeReceipt(_ receipt: TeamTaskMoveReceipt) -> Bool {
        guard TeamTaskMoveNativePeer.enabled, receipt.command.account == userID, receipt.command.scope.task == TeamEditorNativeFixture.taskID,
              snapshot.pending.isEmpty, let state = try? TeamTaskMoveNativePeer.read() else { return false }
        let old = snapshot
        snapshot.tables["tasks"] = state.tasks
        do { try persist(); return true } catch { snapshot = old; self.error = error.localizedDescription; return false }
    }
    func changeTeamTaskMoveNativeSource() {
        guard TeamTaskMoveNativePeer.enabled, var state = try? TeamTaskMoveNativePeer.read(), let index = state.tasks.firstIndex(where: { $0.id == TeamEditorNativeFixture.taskID }) else { return }
        state.tasks[index]["description"] = .string("A newer shared note")
        do { try TeamTaskMoveNativePeer.write(state); snapshot.tables["tasks"] = state.tasks; try persist() } catch { self.error = error.localizedDescription }
    }
}
#endif

extension Store {
    var projectTransferRecoveryAvailable: Bool { signedIn && !localMode && !signingOut && !accountRemovalBlocked }
    var projectTransferAuthoringAvailable: Bool { projectTransferRecoveryAvailable && nativeTeamEditorEnabled && workspaceCacheReadable }
    func projectTransferContext(account: String, origin: String, workspace: WorkspaceBinding, session: UUID) -> Bool {
        projectTransferRecoveryAvailable && account == userID && origin == (try? backend.accountRemovalOrigin) && workspace.matches(account: userID, generation: workspaceGeneration) && session == backend.reminderSessionIncarnation
    }
    var personalTransferProjects: [Record] {
        guard projectTransferAuthoringAvailable, let boundary = nativeConversationTeamCache?.boundary else { return [] }
        return allProjects.filter { $0.string("user_id") == userID && boundary.projects[$0.id]?.team == nil && boundary.projects[$0.id]?.role == "owner" }.sorted { $0.string("name").localizedStandardCompare($1.string("name")) == .orderedAscending }
    }
    /// A new transfer requires synced work and closed affected task editors.
    /// Retries remain available independently, including after destination access loss.
    func projectTransferAuthorStamp(_ scope: TeamProjectAdoptionScope, projects ids: [String]) -> String? {
        guard projectTransferAuthoringAvailable, online, !syncing, snapshot.pending.isEmpty, syncConflict == nil, focusSyncConflict == nil,
              scope.account == userID, scope.origin == (try? backend.accountRemovalOrigin), let cache = nativeConversationTeamCache,
              cache.boundary.belongs(account: scope.account, origin: scope.origin), Set(scope.roots).isSubset(of: Set(ids)),
              ids.allSatisfy({ id in record("projects", id: id)?.string("user_id") == userID && cache.knownTeams[id] == nil && cache.boundary.projects[id]?.role == "owner" && cache.boundary.projects[id]?.team == nil }) else { return nil }
        for editor in editorSessions.values where !editor.closed && editor.account == userID {
            let root = SubtaskTree.referencePath(editor.original.id)?.first ?? editor.original.id
            let project = record("tasks", id: root)?.string("project_id") ?? editor.original.string("project_id")
            if ids.contains(project) { return nil }
        }
        return "\(workspaceReadRevision)|\(taskRevision)|\(cache.boundary.raw["token"]?.text ?? "")"
    }
    /// Receipts certify custody only. Ordinary boundary refresh handles drafts,
    /// recovery copies and visibility; no old response is projected into tasks.
    func refreshAfterProjectTransfer(_ receipt: TeamProjectAdoptionReceipt) async -> Bool {
        let c = receipt.command, workspace = WorkspaceBinding(account: userID, generation: workspaceGeneration), session = backend.reminderSessionIncarnation
        guard projectTransferContext(account: c.account, origin: c.origin, workspace: workspace, session: session), !syncing, online else { return false }
        let started = Date(); await sync()
        guard projectTransferContext(account: c.account, origin: c.origin, workspace: workspace, session: session), !syncing,
              (lastSync ?? .distantPast) >= started, let cache = nativeConversationTeamCache, cache.boundary.belongs(account: c.account, origin: c.origin) else { return false }
        // A refresh that preserved conflicting work is still useful, but it is
        // not a claim that every selected project has reloaded successfully.
        guard syncConflict == nil, focusSyncConflict == nil, snapshot.pending.isEmpty else { return false }
        return c.projects.allSatisfy { cache.boundary.projects[$0] == nil || cache.boundary.projects[$0]?.team == c.scope.team }
    }
}

#if DEBUG
extension Store {
    private func prepareProjectAdoptionNativeFixture() {
        dailyBackupsEnabled = false
        do {
            let resetting = ProcessInfo.processInfo.arguments.contains("--team-editor-reset")
            if resetting || !FileManager.default.fileExists(atPath: ProjectAdoptionNativeFixture.stateURL.path) { try ProjectAdoptionNativeFixture.reset() }
            if !resetting, snapshot.tables["projects"]?.contains(where: { $0.id == ProjectAdoptionNativeFixture.root }) == true { return }
            let state = try ProjectAdoptionNativeFixture.read(), rows = ProjectAdoptionNativeFixture.rows(state)
            let boundary = try TeamWorkspaceBoundary(ProjectAdoptionNativeFixture.boundary(state),account:ProjectAdoptionNativeFixture.account,origin:ProjectAdoptionNativeFixture.origin)
            snapshot = Snapshot(tables: rows); snapshot.teamWorkspace = try TeamWorkspaceCache(boundary:boundary,previous:nil,pending:[],tasks:rows["tasks"] ?? [])
            try persist()
        } catch { self.error = "Synthetic project-transfer workspace could not be prepared." }
    }
    func changeProjectAdoptionFixtureSource() {
        guard ProjectAdoptionNativeFixture.enabled,var rows=snapshot.tables["tasks"],!rows.isEmpty else{return}
        rows[0]["description"] = .string("Changed after review");snapshot.tables["tasks"]=rows;try? persist()
    }
}
#endif

#if DEBUG
extension Store {
    private var historyBindingFixtureEnabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--history-binding-testing") }
    func seedHistoryBindingFixture() {
        guard historyBindingFixtureEnabled else { return }
        do {
            undoStack = []; redoStack = []; TeamEditorNativeFixture.historyRequest = nil
            for index in 1...30 {
                let id = "ec240000-0000-4000-8000-000000000032"
                guard var row = record("tasks", id: id) else { throw TeamTaskBatch.invalid }
                let draft = try captureTeamTaskEditor(row)
                row["title"] = .string("History checkpoint \(index)")
                guard saveTeamTaskEditor(row, draft: draft) else { throw TeamTaskBatch.invalid }
            }
        } catch { self.error = error.localizedDescription }
    }
    func advanceHistoryBindingFixture() {
        guard historyBindingFixtureEnabled, let old = TeamEditorNativeFixture.historyRequest else { return }
        do {
            let oldDepth = undoStack.count, oldEntry = undoStack.last?.id
            guard var row = record("tasks", id: "ec240000-0000-4000-8000-000000000031") else { throw TeamTaskBatch.invalid }
            let draft = try captureTeamTaskEditor(row); row["description"] = .string("Newer history binding proof")
            guard saveTeamTaskEditor(row, draft: draft) else { throw TeamTaskBatch.invalid }
            let before = snapshot, beforeUndo = undoStack.map(\.id), beforeRedo = redoStack.map(\.id)
            let rejected = !undo(old)
            let unchanged = snapshot.tables == before.tables && snapshot.pending == before.pending && undoStack.map(\.id) == beforeUndo && redoStack.map(\.id) == beforeRedo
            let report: [String: JSON] = ["sameDepth": .bool(oldDepth == undoStack.count), "depth": .number(Double(undoStack.count)), "newEntry": .bool(oldEntry != undoStack.last?.id), "rejected": .bool(rejected), "snapshotAndStacksUnchanged": .bool(unchanged)]
            try JSONEncoder().encode(report).write(to: cacheURL.deletingLastPathComponent().appendingPathComponent("history-binding-proof.json"), options: .atomic)
            self.error = nil
        } catch { self.error = error.localizedDescription }
    }
}
#endif

#if DEBUG
/// A local, ordinary-root protocol peer only for the reserved acceptance host.
/// SQL behavior is verified separately; no request can reach a real service.
@MainActor private enum TeamBatchRecoveryNativePeer {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-testing") }
    static var readOnlyMode: String? { ["viewer", "archived", "paused"].first { ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-" + $0) } }
    private static var singleReviewCount = 0
    static var blockedSync: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-blocked-sync") }
    static var traceFile: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("taskfold-cold-discovery-trace.json") }
    static func trace(_ request: URLRequest) {
        guard blockedSync else { return }
        var entries = (try? JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: traceFile))) ?? []
        entries.append(["method": request.httpMethod ?? "", "path": request.url?.path ?? ""])
        try? FileManager.default.createDirectory(at: traceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(entries.suffix(128))).write(to: traceFile, options: .atomic)
    }
    static func readBoundary() throws -> TeamWorkspaceBoundary {
        guard enabled else { throw CancellationError() }
        let mode = readOnlyMode ?? "viewer"
        var raw = try TeamEditorNativeFixture.boundary(viewer: mode == "viewer").raw
        raw["setup_paused"] = .bool(mode == "paused"); raw["token"] = .string(String(repeating: "e", count: 64))
        raw["projects"] = .array(raw["projects"]!.list.map { value in var project = value.object; project["can_send_tasks"] = .bool(false); project["archived"] = .bool(mode == "archived"); return .object(project) })
        return try TeamWorkspaceBoundary(raw, account: TeamEditorNativeFixture.account, origin: "https://synthetic.example")
    }

    static var recurring: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-recurring") }
    static var recurringProof: URL { traceFile.deletingLastPathComponent().appendingPathComponent("taskfold-recurring-review-proof.json") }
    static func rememberRecurring(_ header: Mutation) throws {
        guard recurring else { return }
        let body: [String: JSON]
        if let group = header.teamTaskBatch { body = try group.body(for: header) }
        else if let command = header.teamCompletion { body = try command.body(for: header) }
        else { throw TeamCompletion.invalid }
        let value: [String: JSON] = ["_action": .string("complete"), "_body": .object(body)]
        if FileManager.default.fileExists(atPath: recurringProof.path) {
            guard try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: recurringProof)) == value else { throw TeamCompletion.invalid }
        } else { try JSONEncoder().encode(value).write(to: recurringProof, options: .atomic) }
    }
    /// A sealed first-completion observation, not an emulation of later writes.
    /// The domain forecast is already checked against independent SQL fixtures.
    static func recurringCommand(_ body: [String: JSON], operation: TeamCompletion.Operation) throws -> Mutation {
        let source = Record(body["record"]?.object ?? [:])
        guard let id = UUID(uuidString: body["request_id"]?.text ?? ""),
              let clock = TaskPlanning.instant(body["completed_at"]?.text ?? ""),
              source.string("project_id") == TeamEditorNativeFixture.projectID,
              body["series_id"] == .string(source.id) else { throw TeamCompletion.invalid }
        let scope = TeamTaskEditScope(account: TeamEditorNativeFixture.account, origin: "https://synthetic.example", team: TeamEditorNativeFixture.teamID, project: source.string("project_id"))
        let related = body[operation == .undo ? "undoes" : "redo_of"].flatMap { UUID(uuidString: $0.text) }
        guard operation != .undo || related != nil else { throw TeamCompletion.invalid }
        let forecast = try TeamCompletion.complete(source, tasks: [source], scope: scope, at: clock, zone: body["input_zone"]?.text ?? "", id: operation == .undo ? related! : id)
        var proposed = forecast.teamCompletion!.proposed
        proposed?["task_generation"] = body["next_generation"]!
        let command = TeamCompletion(scope: scope, operation: operation, source: source, completedAt: body["completed_at"]!.text, inputZone: body["input_zone"]!.text, seriesID: source.id,
                                     seriesGeneration: body["series_generation"]?.text ?? "", seriesProject: body["series_project_id"]?.text ?? "", nextGeneration: body["next_generation"]?.text ?? "", proposed: proposed, related: related)
        let header = TeamCompletion.header(command, id: id)
        guard try command.body(for: header) == body else { throw TeamCompletion.invalid }
        return header
    }
    static func recurringResponse(_ params: [String: JSON], single: Bool) throws -> Data {
        guard recurring, let operation = TeamCompletion.Operation(rawValue: params["_action"]?.text ?? ""),
              let body = params["_body"]?.object else { throw TeamCompletion.invalid }
        let proof = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: recurringProof))
        let original = proof["_body"]!.object
        let originalItems = original["items"]?.list ?? [.object(original)], items = single ? [.object(body)] : body["items"]?.list ?? []
        guard !items.isEmpty else { throw TeamCompletion.invalid }
        let sealed = proof == params, cancelled = ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-cancelled")
        let recorded = ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-recorded") && !cancelled
        let state = sealed ? (cancelled ? "cancelled" : recorded ? "recorded" : "unrecorded") : "unrecorded"
        var current: [String: (Record, Record?)] = [:]
        for item in originalItems {
            let header = try recurringCommand(item.object, operation: .complete), command = header.teamCompletion!
            let task = recorded ? TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": .string(command.completedAt)], to: command.source) : command.source
            guard current.index(forKey: task.id) == nil else { throw TeamCompletion.invalid }
            current[task.id] = (task, recorded ? command.proposed : nil)
        }
        var views: [JSON] = []
        let identityKeys = ["team_id", "project_id", "task_id", "task_generation", "request_id", "series_id", "series_generation", "series_project_id", "planned_next_id"]
        for item in items {
            let b = item.object
            let header = try recurringCommand(b, operation: operation)
            let command = header.teamCompletion!
            guard let (task, originalNext) = current[command.source.id] else { throw TeamCompletion.invalid }
            var next: Record? = originalNext?.id == command.proposed?.id ? originalNext : nil
            if ProcessInfo.processInfo.arguments.contains("--team-connected-provisional-testing"), var replacement = next {
                replacement["task_generation"] = .string(WorkspaceBackup.stableID("native-connected-replacement", replacement.id))
                replacement["title"] = .string("Existing shared occurrence")
                next = replacement
            }
            let nextValue: JSON = next.map { JSON.object($0.fields) } ?? .null
            let related: JSON = command.related.map { JSON.string($0.uuidString.lowercased()) } ?? .null
            var identity: [String: JSON] = [:]
            for key in identityKeys { identity[key] = b[key]! }
            var receipt = identity
            receipt["protocol"] = .number(1); receipt["account"] = .string(TeamEditorNativeFixture.account)
            receipt["operation"] = .string(operation.rawValue); receipt["related_request"] = related; receipt["replayed"] = .bool(true)
            receipt["source_revision"] = task["completion_version"]; receipt["created_successor"] = .bool(next != nil && (!ProcessInfo.processInfo.arguments.contains("--team-connected-provisional-testing") || next?["task_generation"] == command.proposed?["task_generation"])); receipt["removed_successor"] = .bool(false)
            receipt["successor_id"] = next.map { JSON.string($0.id) } ?? .null
            receipt["successor_generation"] = next?["task_generation"] ?? .null
            receipt["task"] = .object(task.fields); receipt["successor"] = nextValue
            var view = identity
            view["review_protocol"] = .number(1); view["account"] = .string(TeamEditorNativeFixture.account); view["operation"] = .string(operation.rawValue)
            view["state"] = .string(state); view["project_role"] = .string(readOnlyMode == "viewer" ? "viewer" : "editor")
            view["task"] = .object(task.fields); view["series"] = .object(task.fields); view["successor"] = nextValue
            view["receipt"] = state == "recorded" ? .object(receipt) : .null
            view["can_edit_current"] = .bool(readOnlyMode == nil); view["can_edit_series"] = .bool(readOnlyMode == nil)
            views.append(.object(view))
        }
        if single { return try JSONEncoder().encode(views[0]) }
        let receipt: JSON = state == "recorded" ? .object(["batch_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "team_id": body["team_id"]!, "request_id": body["request_id"]!, "operation": .string(operation.rawValue), "related_request": body["related_request"] ?? .null, "items": .array(views.map { $0.object["receipt"]! }), "replayed": .bool(true)]) : .null
        return try JSONEncoder().encode(["group_review_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "team_id": body["team_id"]!, "request_id": body["request_id"]!, "operation": .string(operation.rawValue), "related_request": body["related_request"] ?? .null, "state": .string(state), "items": .array(views), "receipt": receipt])
    }
    static func response(_ request: URLRequest) -> Data? {
        guard enabled, request.url?.host == "synthetic.example" else { return nil }
        trace(request)
        if blockedSync, request.httpMethod == "POST", request.url?.path == "/rest/v1/rpc/taskfold_workspace_boundary" { return try? JSONEncoder().encode(readBoundary().raw) }
        guard request.httpMethod == "POST",
              ["/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional"].contains(request.url?.path ?? "") else { return nil }
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var value = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable && value.count < 2_000_000 { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; value.append(contentsOf: bytes.prefix(count)) }; data = value
        }
        guard let data, let params = try? JSONDecoder().decode([String: JSON].self, from: data) else { return nil }
        if recurring, request.url?.path == "/rest/v1/rpc/taskfold_retire_team_provisional" {
            guard ProcessInfo.processInfo.arguments.contains("--team-connected-provisional-testing"), Set(params.keys) == ["_body"], let body = params["_body"]?.object,
                  let data = try? recurringResponse(["_action": .string("complete"), "_body": .object(body)], single: true),
                  let read = try? JSONDecoder().decode([String: JSON].self, from: data), read["state"] == .string("recorded") else { return nil }
            let response: [String: JSON] = ["draft_retirement_protocol": .number(1), "generation_unavailable": .bool(true), "account": .string(TeamEditorNativeFixture.account), "team_id": body["team_id"]!, "project_id": body["project_id"]!, "request_id": body["request_id"]!, "task_id": body["planned_next_id"]!, "task_generation": body["next_generation"]!, "review": .object(read), "current_proposed": read["successor"] ?? .null]
            let file = recurringProof.deletingLastPathComponent().appendingPathComponent("taskfold-connected-provisional-rpc-proof.json")
            var calls = (try? JSONDecoder().decode([JSON].self, from: Data(contentsOf: file))) ?? []
            calls.append(.object(["path": .string(request.url!.path), "body": .object(params), "response": .object(response)]))
            try? JSONEncoder().encode(Array(calls.suffix(16))).write(to: file, options: .atomic)
            return try? JSONEncoder().encode(response)
        }
        if recurring { return try? recurringResponse(params, single: ["/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion"].contains(request.url?.path ?? "")) }
        guard params["_action"] == .string("complete"),
              let body = params["_body"]?.object, body["team_id"] == .string(TeamEditorNativeFixture.teamID),
              let nonce = body["request_id"]?.text, TeamProjectValue.id(nonce) else { return nil }
        let single = ["/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion"].contains(request.url?.path ?? "")
        let items = single ? [JSON.object(body)] : body["items"]?.list ?? []
        guard (1...100).contains(items.count) else { return nil }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("taskfold-group-review-peer.json")
        var retired = (try? JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: file))) ?? [:]
        if let old = retired[nonce], old != .object(body) { return nil }
        let alreadyCancelled = ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-cancelled")
        let support = file.deletingLastPathComponent(), recordedFile = support.appendingPathComponent("taskfold-single-cancel-recorded-peer.json")
        var recordedActions = (try? JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: recordedFile))) ?? [:]
        if let old = recordedActions[nonce], old != .object(body) { return nil }
        let raceRecorded = ProcessInfo.processInfo.arguments.contains("--team-cancelled-draft-recorded-race") && request.url!.path.contains("cancel_")
        let recorded = (ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-recorded") && !alreadyCancelled) || recordedActions[nonce] != nil || raceRecorded
        if raceRecorded {
            recordedActions[nonce] = .object(body); try? JSONEncoder().encode(recordedActions).write(to: recordedFile, options: .atomic)
        }
        if ProcessInfo.processInfo.arguments.contains("--team-cancelled-draft-testing"), request.url!.path.contains("cancel_") {
            let trace = support.appendingPathComponent("taskfold-single-cancel-attempts.json")
            var attempts = (try? JSONDecoder().decode([JSON].self, from: Data(contentsOf: trace))) ?? []
            attempts.append(.object(["path": .string(request.url!.path), "request_id": .string(nonce), "body": .object(body)]))
            try? JSONEncoder().encode(Array(attempts.suffix(128))).write(to: trace, options: .atomic)
        }
        if request.url!.path.contains("cancel_"), !recorded {
            retired[nonce] = .object(body)
            do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(retired).write(to: file, options: .atomic) } catch { return nil }
        }
        let state = alreadyCancelled ? "cancelled" : recorded ? "recorded" : retired[nonce] != nil ? "cancelled" : "unrecorded"
        var views: [JSON] = [], receipts: [JSON] = []
        for item in items {
            let b = item.object; var task = Record(b["record"]?.object ?? [:])
            guard task.string("project_id") == TeamEditorNativeFixture.projectID, task["is_recurring"] != .bool(true), b["planned_next_id"] == .null,
                  b["series_id"] == .string(task.id), task["completed"] == .bool(false) else { return nil }
            if recorded { task = TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": b["completed_at"]!], to: task) }
            var receipt: [String: JSON] = Dictionary(uniqueKeysWithValues: ["team_id", "project_id", "task_id", "task_generation", "request_id", "series_id", "series_generation", "series_project_id", "planned_next_id"].map { ($0, b[$0]!) })
            receipt.merge(["protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "replayed": .bool(true), "operation": .string("complete"), "related_request": .null,
                "source_revision": task["completion_version"], "created_successor": .bool(false), "removed_successor": .bool(false), "successor_id": .null, "successor_generation": .null, "task": .object(task.fields), "successor": .null]) { _, new in new }
            var view: [String: JSON] = Dictionary(uniqueKeysWithValues: ["team_id", "project_id", "task_id", "task_generation", "request_id", "series_id", "series_generation", "series_project_id", "planned_next_id"].map { ($0, b[$0]!) })
            view.merge(["review_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "operation": .string("complete"), "state": .string(state), "project_role": .string(readOnlyMode == "viewer" ? "viewer" : "editor"),
                "task": .object(task.fields), "series": .object(task.fields), "successor": .null, "receipt": recorded ? .object(receipt) : .null, "can_edit_current": .bool(readOnlyMode == nil), "can_edit_series": .bool(readOnlyMode == nil)]) { _, new in new }
            if recorded, ProcessInfo.processInfo.arguments.contains("--team-recorded-draft-testing"), task.id == TeamEditorNativeFixture.taskID {
                receipt["task"] = .null; view["task"] = .null; view["series"] = .null; view["receipt"] = .object(receipt)
            }
            views.append(.object(view)); receipts.append(.object(receipt))
        }
        if single {
            if ProcessInfo.processInfo.arguments.contains("--team-single-recovery-refresh") {
                singleReviewCount += 1
                var view = views[0].object, receipt = view["receipt"]!.object, task = view["task"]!.object
                task["description"] = .string(singleReviewCount > 1 ? "Updated synced instructions" : "Initial synced instructions")
                view["task"] = .object(task); view["series"] = .object(task); receipt["task"] = .object(task); view["receipt"] = .object(receipt)
                return try? JSONEncoder().encode(view)
            }
            return try? JSONEncoder().encode(views[0])
        }
        let receipt: JSON = recorded ? .object(["batch_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "team_id": body["team_id"]!, "request_id": body["request_id"]!, "operation": .string("complete"), "related_request": .null, "items": .array(receipts), "replayed": .bool(true)]) : .null
        return try? JSONEncoder().encode(["group_review_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "team_id": body["team_id"]!, "request_id": body["request_id"]!, "operation": .string("complete"), "related_request": .null, "state": .string(state), "items": .array(views), "receipt": receipt])
    }
}
extension Store {
    func prepareTeamBatchRecoveryFixture() async {
        guard TeamBatchRecoveryNativePeer.enabled, var header = snapshot.pending.first, header.teamTaskBatch?.isCompletion == true || header.teamCompletion != nil else { return }
        do {
            if ProcessInfo.processInfo.arguments.contains("--team-single-recovery-testing"), let batch = header.teamTaskBatch, let first = batch.items.first {
                for other in batch.items.dropFirst() {
                    if let source = other.teamCompletion?.source, let index = snapshot.tables["tasks"]?.firstIndex(where: { $0.id == source.id }) { snapshot.tables["tasks"]![index] = source }
                }
                header = first; snapshot.pending[0] = first; undoStack = []; redoStack = []; try persist()
            }
            if ProcessInfo.processInfo.arguments.contains("--team-connected-provisional-testing"), TeamBatchRecoveryNativePeer.recurring,
               ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-dependent"), snapshot.pending.count == 1,
               let item = header.teamCompletion != nil ? header : header.teamTaskBatch?.items.first,
               let command = item.teamCompletion, let proposed = command.proposed,
               let row = snapshot.tables["tasks"]?.first(where: { $0.id == proposed.id && $0["task_generation"] == proposed["task_generation"] }) {
                let fields: [String: JSON] = ["title": .string("Connected recurring draft"), "description": .string("Keep the connected recurring instructions")]
                let edit = try command.scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row), teamTaskScope: command.scope), existing: row)
                snapshot.apply(edit); snapshot.pending.append(edit); try persist()
            }
            if TeamBatchRecoveryNativePeer.recurring, ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-dependent"), snapshot.pending.count == 3 {
                let last = snapshot.pending.last!
                guard let item = last.teamCompletion != nil ? last : last.teamTaskBatch?.items.first,
                      let command = item.teamCompletion, let proposed = command.proposed,
                      let row = snapshot.tables["tasks"]?.first(where: { $0.id == proposed.id && $0["task_generation"] == proposed["task_generation"] }) else { throw TeamCompletion.invalid }
                let fields: [String: JSON] = ["title": .string("Later recurring occurrence proof"), "description": .string("Keep these later recurring instructions")]
                let edit = try command.scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row), teamTaskScope: command.scope), existing: row)
                snapshot.apply(edit); snapshot.pending.append(edit); try persist()
            }
            if ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-dependent"), snapshot.pending.count == 1,
               let item = header.teamCompletion != nil ? header : header.teamTaskBatch?.items.first, let command = item.teamCompletion,
               let row = snapshot.tables["tasks"]?.first(where: { $0.id == item.recordID }) {
                let fields: [String: JSON] = ["title": .string("Later selection draft proof"), "description": .string("Keep these later workshop instructions")]
                let edit = try command.scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row), teamTaskScope: command.scope), existing: row)
                snapshot.apply(edit); snapshot.pending.append(edit); try persist()
            }
            if ProcessInfo.processInfo.arguments.contains("--team-connected-provisional-testing"), let previous = snapshot.teamWorkspace {
                snapshot.teamWorkspace = try TeamWorkspaceCache(boundary: previous.boundary, previous: previous, pending: snapshot.pending, tasks: snapshot.tables["tasks"] ?? [])
            }
            if ProcessInfo.processInfo.arguments.contains("--team-recorded-mention-testing"),
               (snapshot.tables[ConversationOutbox.table] ?? []).isEmpty,
               let item = header.teamCompletion != nil ? header : header.teamTaskBatch?.items.first,
               let task = snapshot.tables["tasks"]?.first(where: { $0.id == ((ProcessInfo.processInfo.arguments.contains("--team-connected-provisional-testing") ? item.teamCompletion?.proposed?.id : nil) ?? item.recordID) }) {
                let stamp = "2026-10-25T12:00:00Z", commentID = "ec240000-0000-4000-8000-000000000091", mentionID = "ec240000-0000-4000-8000-000000000092"
                let comment = Record(["id": .string(commentID), "task_id": .string(task.id), "task_generation": task["task_generation"], "project_id": task["project_id"], "author_id": .string(userID), "body": .string("Native connected mention recovery proof"), "mention_ids": .array([.string(userID)]), "revision": .number(2), "created_at": .string(stamp), "updated_at": .string(stamp), "deleted_at": .null])
                let marker = Record(["id": .string(mentionID), "comment_id": .string(commentID), "recipient_id": .string(userID), "revision": .number(3), "created_at": .string(stamp), "read_at": .null])
                guard let mention = SharedMention(marker) else { throw TeamCompletion.invalid }
                snapshot.tables[SharedComment.table] = [comment]; snapshot.tables[SharedMention.table] = [marker]
                let captured = ProcessInfo.processInfo.arguments.contains("--team-captured-mention-testing")
                try ConversationOutbox.enqueue(SharedMentionChange(mention: mention, account: userID, read: true).record, into: &snapshot, origin: captured ? (try? backend.accountRemovalOrigin) : nil)
                if captured {
                    guard snapshot.tables[ConversationOutbox.table]?.first?.fields[MentionRecoveryContext.field] != nil else { throw TeamCompletion.invalid }
                    snapshot.tables[SharedComment.table] = []; snapshot.tables[SharedMention.table] = []
                }
                try persist()
            }
            if ProcessInfo.processInfo.arguments.contains("--team-recorded-order-testing"),
               !snapshot.pending.contains(where: { $0.table == "view_orders" }),
               let item = header.teamCompletion != nil ? header : header.teamTaskBatch?.items.first,
               let task = snapshot.tables["tasks"]?.first(where: { $0.id == ((ProcessInfo.processInfo.arguments.contains("--team-connected-provisional-testing") ? item.teamCompletion?.proposed?.id : nil) ?? item.recordID) }),
               let other = snapshot.tables["tasks"]?.first(where: { $0.id != task.id }) {
                let stale = "ec240000-0000-4000-8000-000000000099"
                let order = Record(["id": .string("scope:today"), "user_id": .string(userID), "ids": .array([.string(other.id), .string(stale), .string(task.id)]), "updated_at": .string("2026-10-25T12:00:00Z")])
                let independent = Record(["id": .string("scope:inbox"), "user_id": .string(userID), "ids": .array([.string(other.id)])])
                snapshot.tables["view_orders"] = [order, independent]
                func applyChoice(_ raw: Mutation) throws -> Mutation {
                    let captured = capturingTaskOrderRecovery(raw)
                    guard captured.orderRecovery != nil else { throw TaskOrderRecovery.invalid }
                    snapshot.apply(captured); snapshot.pending.append(captured); return captured
                }
                _ = try applyChoice(Mutation(table: "view_orders", recordID: order.id, method: "POST", fields: ["id": order["id"], "user_id": .string(userID), "ids": .array([.string(task.id), .string(other.id), .string(stale)])]))
                let beforePin = snapshot
                guard let choice = PinnedNotes.change(taskID: task.id, enabled: true, pins: snapshot.tables["view_orders"] ?? [], account: userID) else { throw TaskOrderRecovery.invalid }
                let pin = try applyChoice(choice)
                let inverse = EditHistory(changes: [pin], snapshot: beforePin).undo
                for change in historyChanges(inverse) { _ = try applyChoice(change) }
                for change in historyChanges([pin]) { _ = try applyChoice(change) }
                try persist()
            }
            if let mode = TeamBatchRecoveryNativePeer.readOnlyMode {
                var raw = try TeamEditorNativeFixture.boundary(viewer: mode == "viewer").raw
                raw["setup_paused"] = .bool(mode == "paused"); raw["token"] = .string(String(repeating: "e", count: 64))
                raw["projects"] = .array(raw["projects"]!.list.map { value in var project = value.object; project["can_send_tasks"] = .bool(false); project["archived"] = .bool(mode == "archived"); return .object(project) })
                let boundary = try TeamWorkspaceBoundary(raw, account: userID, origin: backend.accountRemovalOrigin)
                // Model a newer access mask while disk still has the old writer
                // boundary. Successful acknowledgement must persist this mask.
                teamAccessMask = try TeamWorkspaceCache(boundary: boundary, previous: snapshot.teamWorkspace, pending: snapshot.pending, tasks: snapshot.tables["tasks"] ?? [])
                if mode == "archived" { for i in snapshot.tables["projects"]!.indices { snapshot.tables["projects"]![i]["is_archived"] = .bool(true) } }
                try persist()
            }
            try TeamBatchRecoveryNativePeer.rememberRecurring(header)
            if header.teamCompletion != nil {
                let review = try await backend.reviewTeamCompletion(header, expectedAccount: userID)
                syncConflict = SyncConflict(mutation: header, remote: review.task ?? header.teamCompletion!.source, completionReview: review)
            } else { installTeamCompletionBatchReview(try await backend.reviewTeamCompletionBatch(header, expectedAccount: userID)) }
        }
        catch { self.error = error.localizedDescription }
    }
}
#endif

#if DEBUG
extension Store {
    /// Seed only reserved Mac acceptance storage. Review, sync and persistence
    /// below still use their real Store implementations.
    private func seedTeamCompletionRecoveryFixture() throws {
        guard TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-testing"), snapshot.pending.isEmpty else { return }
        let tasks = snapshot.tables["tasks"] ?? []
        let scope = TeamTaskEditScope(account: userID, origin: try backend.accountRemovalOrigin, team: TeamEditorNativeFixture.teamID, project: TeamEditorNativeFixture.projectID)
        let chosen = tasks.filter { $0.id == TeamEditorNativeFixture.taskID || $0.id == "ec240000-0000-4000-8000-000000000031" }
        guard chosen.count == 2 else { throw TeamTaskBatch.invalid }
        let actions = try chosen.map { try TeamCompletion.complete($0, tasks: tasks, scope: scope, at: Date(timeIntervalSince1970: 1792944000), zone: "Europe/Copenhagen") }
        let header: Mutation
        if ProcessInfo.processInfo.arguments.contains("--team-single-recovery-testing") { header = actions[0] }
        else { header = TeamTaskBatch.header(TeamTaskBatch(account: userID, origin: scope.origin, team: scope.team, operation: .complete, restores: nil, items: actions)) }
        var next = snapshot; next.apply(header); next.pending = [header]
        next.teamWorkspace = try TeamWorkspaceCache(boundary: TeamEditorNativeFixture.boundary(), previous: snapshot.teamWorkspace, pending: next.pending, tasks: next.tables["tasks"] ?? [])
        snapshot = next; try persist()
    }
}
#endif


#if DEBUG
/// Real filesystem barriers inside the reserved app's own sandbox. No fault is
/// synthesized in the production writer, backup or encrypted-draft code.
@MainActor enum TeamRecoveryStorageNativeFixture {
    static var fault: String? {
        guard TeamEditorNativeFixture.enabled else { return nil }
        return ["cache", "draft", "backup", "connected-copy"].first { ProcessInfo.processInfo.arguments.contains("--team-recovery-storage=" + $0) }
    }
    private static var support: URL { URL.applicationSupportDirectory }
    private static var cache: URL { support.appendingPathComponent("Taskfold/" + TeamEditorNativeFixture.account + ".json") }
    private static var vault: URL { cache.deletingLastPathComponent().appendingPathComponent("Backups/d2be2d54-84e6-8f3d-8850-546d0835535a") }
    private static var prior: URL { vault.appendingPathExtension("storage-proof-prior") }
    private static var held: URL { cache.appendingPathExtension("storage-proof-held") }
    private static var journal: URL { support.appendingPathComponent("taskfold-storage-proof-journal.json") }
    private static func target(_ fault: String) -> URL {
        if fault == "cache" { return cache }
        if fault == "backup" { return vault.appendingPathComponent("index.json") }
        if fault == "connected-copy" { return vault.appendingPathComponent("Team drafts/1d019528-c5bc-8e72-8e2a-1305600e9a82/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee.taskfolddraft") }
        let name = ProcessInfo.processInfo.arguments.contains("--team-cancelled-draft-testing") ? "Cancelled recovery" : ProcessInfo.processInfo.arguments.contains("--team-recorded-draft-testing") ? "Recorded recovery" : "Selections"
        return vault.appendingPathComponent("Team drafts/1d019528-c5bc-8e72-8e2a-1305600e9a82/" + name)
    }
    static func block() throws {
        guard let fault else { throw TeamCompletion.invalid }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: journal.path), !fm.fileExists(atPath: prior.path), !fm.fileExists(atPath: held.path) else { throw TeamCompletion.invalid }
        let hadVault = fm.fileExists(atPath: vault.path)
        try JSONEncoder().encode(["fault": JSON.string(fault), "hadVault": .bool(hadVault)]).write(to: journal, options: .atomic)
        if hadVault { try fm.moveItem(at: vault, to: prior) }
        let destination = target(fault)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fault == "cache" {
            try fm.moveItem(at: cache, to: held)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        } else if fault == "backup" { try fm.createDirectory(at: destination, withIntermediateDirectories: false) }
        else { try Data("Reserved native storage barrier".utf8).write(to: destination) }
    }
    static func repair() throws {
        guard let fault else { throw TeamCompletion.invalid }
        let fm = FileManager.default
        try fm.removeItem(at: target(fault))
        if fault == "cache" { try fm.moveItem(at: held, to: cache) }
    }
    static func restoreIfRequested() throws {
        guard TeamEditorNativeFixture.enabled,
              ProcessInfo.processInfo.arguments.contains("--team-editor-reset") || ProcessInfo.processInfo.arguments.contains("--team-recovery-storage-cleanup") else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: journal.path) else { return }
        let proof = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: journal))
        guard ["cache", "draft", "backup", "connected-copy"].contains(proof["fault"]?.text ?? ""), let hadVault = proof["hadVault"]?.flag else { throw TeamCompletion.invalid }
        if fm.fileExists(atPath: held.path) {
            if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
            try fm.moveItem(at: held, to: cache)
        }
        if fm.fileExists(atPath: prior.path) {
            if fm.fileExists(atPath: vault.path) { try fm.removeItem(at: vault) }
            try fm.moveItem(at: prior, to: vault)
        } else if !hadVault, fm.fileExists(atPath: vault.path) { try fm.removeItem(at: vault) }
        try fm.removeItem(at: journal)
    }
}
#endif


#if DEBUG
/// Hold a validated local peer reply so a real Store transaction can be
/// interleaved with a new session, current read boundary or authored edit.
@MainActor enum TeamRecoveryRaceNativeFixture {
    static var mode: String? {
        guard TeamEditorNativeFixture.enabled else { return nil }
        return ["refresh-access", "refresh-access-error", "single-refresh-access-error", "cancel-account", "single-cancel-account", "refresh-account-return", "refresh-edit", "refresh-edit-error", "single-refresh-edit-error", "refresh-current", "refresh-current-error", "refresh-session", "cancel-access-error", "single-cancel-edit-error"].first { ProcessInfo.processInfo.arguments.contains("--team-recovery-race=" + $0) }
    }
    static var expected: Mutation?
    static var held = false
    static var validated = false
    static var path = ""
    static var attemptedPaths: [String] = []
    private static var armed = false
    private static var resume: CheckedContinuation<Void, Never>?
    static func arm(_ header: Mutation) { expected = header; held = false; validated = false; path = ""; attemptedPaths = []; armed = true }
    static func release() { armed = false; let pending = resume; resume = nil; pending?.resume() }
    static func observe(_ request: URLRequest) { if armed, mode != nil { attemptedPaths.append(request.url?.path ?? "") } }

    static func deliver(_ data: Data, request: URLRequest) async throws -> Data {
        guard armed, let mode, let expected,
              request.url?.path.contains(mode.contains("cancel") ? "cancel_team_completion" : "review_team_completion") == true else { return data }
        armed = false
        var raw = try JSONDecoder().decode([String: JSON].self, from: data)
        if !mode.contains("cancel") {
            func changed(_ member: [String: JSON]) -> [String: JSON] {
                var view = member, task = view["task"]!.object
                task["description"] = .string("Delayed response instructions")
                view["task"] = .object(task); view["series"] = .object(task)
                if case .object(var receipt) = view["receipt"] { receipt["task"] = .object(task); view["receipt"] = .object(receipt) }
                return view
            }
            if expected.teamCompletion != nil { raw = changed(raw) }
            else {
                raw["items"] = .array(raw["items"]!.list.map { .object(changed($0.object)) })
                if case .object(var receipt) = raw["receipt"] { receipt["items"] = .array(raw["items"]!.list.map { $0.object["receipt"]! }); raw["receipt"] = .object(receipt) }
            }
        }
        // Prove that rejecting the reply is a context decision, not malformed test data.
        if expected.teamCompletion != nil { _ = try TeamCompletion.Review(raw, for: expected) }
        else { _ = try TeamTaskBatch.Review(raw, for: expected) }
        validated = true; path = request.url!.path; held = true
        await withCheckedContinuation { resume = $0 }
        if mode.hasSuffix("error") { throw URLError(.timedOut) }
        return try JSONEncoder().encode(raw)
    }
    static func session(_ account: String) throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"synthetic-race-access\",\"refresh_token\":\"synthetic-race-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + account + "\"}}").utf8))
    }
}

extension Store {
    func runTeamRecoveryRaceFixture() async {
        guard let mode = TeamRecoveryRaceNativeFixture.mode, userID == TeamEditorNativeFixture.account,
              let conflict = syncConflict else { teamRecoveryRaceStatus = "Failed: original review unavailable"; return }
        teamRecoveryRaceStatus = "Running"
        let original = snapshot, originalGeneration = accountGeneration, originalAccess = nativeConversationTeamCache
        error = nil
        let presentation = teamCompletionReviewPresentation, originalSession = backend.reminderSessionIncarnation
        let owner = userID, outsider = "ec240000-0000-4000-8000-000000000098"
        let ownerFile = cacheURL, outsiderFile = cacheURL.deletingLastPathComponent().appendingPathComponent(outsider + ".json")
        let priorOutsider = try? Data(contentsOf: outsiderFile)
        var touchedOutsider = false
        var action: Task<Bool, Never>?
        var checks: [String: JSON] = [:], proof: [String: JSON] = [:]
        func require(_ name: String, _ condition: Bool) throws {
            checks[name] = .bool(condition)
            if !condition { throw AppFailure(message: "Race check failed: " + name) }
        }
        func encoded(_ value: Snapshot) throws -> JSON { try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value)) }
        do {
            proof["before"] = try encoded(original)
            if mode.contains("account") { try require("priorOtherWorkspaceReadable", !FileManager.default.fileExists(atPath: outsiderFile.path) || priorOutsider != nil) }
            TeamRecoveryRaceNativeFixture.arm(conflict.mutation)
            action = Task {
                if mode.contains("cancel") {
                    if let review = conflict.completionReview { return await self.cancelTeamCompletionReview(review) }
                    if let review = conflict.completionBatchReview { return await self.cancelTeamCompletionBatchReview(review) }
                } else {
                    if let review = conflict.completionReview { return await self.refreshTeamCompletionReview(review) }
                    if let review = conflict.completionBatchReview { return await self.refreshTeamCompletionBatchReview(review) }
                }
                return false
            }
            for _ in 0..<1000 { if TeamRecoveryRaceNativeFixture.held { break }; try await Task.sleep(for: .milliseconds(10)) }
            try require("actualReplyHeld", TeamRecoveryRaceNativeFixture.held && TeamRecoveryRaceNativeFixture.validated)
            if mode.contains("account") {
                var outside = Snapshot(); var task = Record.task(user: outsider)
                task["id"] = .string("ec240000-0000-4000-8000-000000000097"); task["title"] = .string("Other workspace untouched proof")
                outside.tables["tasks"] = [task]
                try JSONEncoder().encode(outside).write(to: outsiderFile, options: .atomic); touchedOutsider = true
                try await backend.accept(TeamRecoveryRaceNativeFixture.session(outsider)); await authenticated()
                if mode == "refresh-account-return" { try await backend.accept(TeamRecoveryRaceNativeFixture.session(owner)); await authenticated() }
                try require("realWorkspaceGenerationChanged", accountGeneration != originalGeneration)
            } else if mode.contains("access") {
                var raw = try TeamEditorNativeFixture.boundary(viewer: true).raw
                raw["token"] = .string(String(repeating: "f", count: 64))
                teamAccessMask = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: owner, origin: backend.accountRemovalOrigin), previous: snapshot.teamWorkspace, pending: snapshot.pending, tasks: snapshot.tables["tasks"] ?? [])
                try require("coarseGuardsStillMatch", accountGeneration == originalGeneration && snapshot == original && (conflict.completionReview.map { currentTeamCompletionReview($0) } ?? conflict.completionBatchReview.map { currentTeamCompletionBatchReview($0) } ?? false))
                try require("freshReadAccessChanged", nativeConversationTeamCache != originalAccess)
            } else if mode == "refresh-session" {
                try await backend.accept(TeamRecoveryRaceNativeFixture.session(owner))
                try require("sameWorkspaceNewSession", accountGeneration == originalGeneration && snapshot == original && backend.reminderSessionIncarnation != originalSession)
            } else if !mode.hasPrefix("refresh-current") {
                let item = conflict.mutation.teamCompletion != nil ? conflict.mutation : conflict.mutation.teamTaskBatch!.items[0]
                let command = item.teamCompletion!
                let row = snapshot.tables["tasks"]!.first { $0.id == item.recordID }!
                let fields: [String: JSON] = ["description": .string("New authored work while reviewing")]
                let edit = try command.scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row), teamTaskScope: command.scope), existing: row)
                snapshot.apply(edit); snapshot.pending.append(edit); try persist()
            }
            let interleaved = snapshot, currentAccess = nativeConversationTeamCache, currentRevision = workspaceReadRevision
            let changedBytes = try Data(contentsOf: cacheURL)
            if !mode.hasPrefix("refresh-current") { error = "Current workspace message" }
            proof["interleaved"] = try encoded(interleaved)
            TeamRecoveryRaceNativeFixture.release()
            let accepted = await action!.value
            try require(mode == "refresh-current" ? "currentResultAccepted" : "staleResultRefused", accepted == (mode == "refresh-current"))
            if mode == "refresh-current" { try require("currentInstructionsVisible", syncConflict?.completionBatchReview?.members.first?.task?.string("description") == "Delayed response instructions") }
            try require("currentSnapshotExact", snapshot == interleaved)
            try require("currentReadAccessExact", nativeConversationTeamCache == currentAccess && workspaceReadRevision == currentRevision)
            if mode == "refresh-current-error" {
                let message = takeTeamCompletionReviewFailure(presentation, fallback: "Missing current error")
                try require("currentFailurePresented", message == SyncStatus.failureMessage(URLError(.timedOut)) && error == nil)
                let earlier = teamCompletionReviewPresentation
                recordTeamCompletionReviewFailure("Earlier owned failure", origin: earlier)
                error = "Current workspace message"
                recordTeamCompletionReviewFailure("Late obsolete failure", origin: earlier)
                _ = takeTeamCompletionReviewFailure(earlier, fallback: "Old screen fallback")
                try require("newMessageCannotBePublishedOverOrConsumed", error == "Current workspace message")
                error = nil
            } else if mode != "refresh-current" {
                _ = takeTeamCompletionReviewFailure(presentation, fallback: "Stale screen callback")
                try require("stalePresentationKeptCurrentMessage", error == "Current workspace message")
            } else { try require("currentMessageKept", error == nil) }
            try require("currentWorkspaceFileExact", try Data(contentsOf: cacheURL) == changedBytes)
            proof["after"] = try encoded(snapshot)
            if mode.contains("account") {
                try require("originalQueueFileKept", try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: ownerFile)).pending == original.pending)
                try await backend.accept(TeamRecoveryRaceNativeFixture.session(owner)); await authenticated()
                try require("originalQueueReloads", snapshot == original)
                if mode == "cancel-account", let vault = teamSelectionDraftVault {
                    let entries = try await Task.detached(priority: .utility) { try vault.entries() }.value
                    try require("originalEncryptedDraftKept", entries.contains { $0.snapshot == original && $0.scope.account == owner })
                }
            }
            proof["restored"] = try encoded(snapshot)
            proof["status"] = .string("passed"); teamRecoveryRaceStatus = "Passed " + mode
        } catch {
            TeamRecoveryRaceNativeFixture.release()
            if let action { _ = await action.value }
            proof["status"] = .string("failed"); proof["failure"] = .string(error.localizedDescription); teamRecoveryRaceStatus = "Failed " + mode
            if userID != owner { try? await backend.accept(TeamRecoveryRaceNativeFixture.session(owner)); await authenticated() }
        }
        if touchedOutsider {
            do { if let priorOutsider { try priorOutsider.write(to: outsiderFile, options: .atomic) } else { try FileManager.default.removeItem(at: outsiderFile) } }
            catch { proof["status"] = .string("failed"); teamRecoveryRaceStatus = "Failed outsider cleanup" }
        }
        proof["mode"] = .string(mode); proof["checks"] = .object(checks); proof["heldPath"] = .string(TeamRecoveryRaceNativeFixture.path)
        proof["attemptedPaths"] = .array(TeamRecoveryRaceNativeFixture.attemptedPaths.map(JSON.string))
        if let error = self.error { proof["actionMessage"] = .string(error) }

        do { try JSONEncoder().encode(proof).write(to: URL.applicationSupportDirectory.appendingPathComponent("taskfold-completion-race-proof.json"), options: .atomic) }
        catch { teamRecoveryRaceStatus = "Failed proof persistence" }
        self.error = nil
    }
}
#endif

#if DEBUG
extension Store {
    /// Exercise the real entry point with an obsolete presentation while the
    /// same account, task and review remain current. No queue or file may change.
    func checkRecordedDraftAdmissionFixture() async {
        guard TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-recorded-draft-testing"), userID == TeamEditorNativeFixture.account else { return }
        let context = teamCompletionReviewPresentation, before = snapshot, oldError = error
        let file = cacheURL, bytes = try? Data(contentsOf: file)
        error = "Current workspace message"
        let accepted: Bool
        if ProcessInfo.processInfo.arguments.contains("--team-cancelled-draft-testing") { accepted = await preserveCancelledCompletionDraft(context) }
        else { accepted = await preserveRecordedCompletionDraft(context) }
        let protected = !accepted && before == snapshot && bytes != nil && (try? Data(contentsOf: file)) == bytes && error == "Current workspace message"
        if error == "Current workspace message" { error = oldError }
        recordedDraftAdmissionStatus = protected ? "Saved draft context protected" : "Saved draft context failed"
    }
}
#endif
