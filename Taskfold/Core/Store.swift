import SwiftUI
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
    var snapshot = Snapshot() {
        didSet {
            if taskCache.update(snapshot.tables["tasks"] ?? []) { taskRevision += 1 }
        }
    }
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
    private var reminderPreferenceRevision = 0
    @ObservationIgnored private var reminderDeviceLifecycle: ReminderDeviceLifecycle?
    @ObservationIgnored private lazy var reminderAppIdentity = ReminderAppIdentity.signed()
    var remoteReminderStatus = "Remote reminders are not available yet. Reminders stay on this device."
    var remoteReminderBusy = false
    private var reminderAuthority: ReminderDeliveryAuthority?
    private var reminderAuthorityRead = false
    private var reminderAuthorityUnreadable = false
    var remoteReminderAvailable = false
    @ObservationIgnored private var reminderAvailability: (account: String, session: UUID, value: Bool, checked: Date)?
    var remoteReminderSelected: Bool { reminderAuthority?.account == reminderAuthorityAccount && reminderAuthority?.wantsRemote == true }
    var remoteReminderNeedsConfirmation: Bool { remoteReminderHoldingOriginals }
    private var remoteReminderHoldingOriginals: Bool { reminderAuthorityUnreadable || reminderAuthority?.account == reminderAuthorityAccount && reminderAuthority?.phase != .local }
    var reminderStatus = "Choose whether this device delivers reminders."
    var focusAlertStatus = "Finish alerts are off on this device."
    private var focusPermissionDenied = false
    var requestingFocusAlerts = false
    var requestingNotifications = false
    var signedIn = false
    var localMode = false
    var syncing = false
    var online = true
    var error: String?
    var notice: String?
    var widgetActionStatus: String?
    var syncConflict: SyncConflict?
    var focusSyncConflict: FocusSyncConflict?
    var lastSync: Date?
    var undoStack: [EditHistory] = []
    var redoStack: [EditHistory] = []
    let backend = Backend()
    private let monitor = NWPathMonitor()
    private var accountGeneration = UUID()
    @ObservationIgnored private var consumingWidgetActions = false
    @ObservationIgnored private var widgetCalendarWindow: CalendarCapacityWindow?
    @ObservationIgnored private var widgetCalendarRevision = -1
    @ObservationIgnored private var capacityRequest: (UUID, String)?
    private(set) var widgetPublicationRevision = 0
    @ObservationIgnored private var workspaceCacheReadable = true
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
        return BackupVault(directory: folder, account: account, key: { try BackupVault.deviceKey(account: account) })
    }
    func makeRecoveryBackup(kind: String = "Manual") async throws -> RecoveryEntry {
        guard signedIn || localMode, !userID.isEmpty else { throw BackupFailure(message: "Open a workspace before backing it up.") }
        let vault = backupVault, before = snapshot, generation = accountGeneration
        let entry = try await Task.detached(priority: .utility) { try vault.save(before, kind: kind) }.value
        guard generation == accountGeneration else { throw BackupFailure(message: "The workspace changed. The backup belongs to the previous workspace.") }
        backupWarning = nil
        return entry
    }
    private func scheduleDailyBackup() {
        guard (signedIn || localMode), !userID.isEmpty, dailyBackupsEnabled, !dailyBackupRunning else { return }
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
    func restore(_ backup: WorkspaceBackup, policy: RestorePolicy, reviewed: Snapshot, generation: UUID) async throws -> RestorePlan {
        guard generation == accountGeneration, snapshot == reviewed, signedIn || localMode else { throw BackupFailure(message: "Your workspace changed. Refresh the restore preview before continuing.") }
        guard !syncing else { throw BackupFailure(message: "Wait for sync to finish, then refresh the restore preview.") }
        let plan = try backup.plan(current: reviewed, account: userID, policy: policy)
        guard plan.total > 0 else { return plan }
        _ = try await makeRecoveryBackup(kind: "Before restore")
        guard generation == accountGeneration, snapshot == reviewed, !syncing else { throw BackupFailure(message: "Your workspace changed while the recovery copy was saved. Refresh the preview before continuing.") }
        guard commit(plan.changes, remember: false) else {
            let message = error ?? "The restore could not be saved. Your workspace was not changed."
            error = nil
            throw BackupFailure(message: message)
        }
        undoStack = []; redoStack = []
        return plan
    }
    var userID: String {
        if localMode {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting") { return "ui-testing" }
            if ProcessInfo.processInfo.arguments.contains("--preview") { return "preview" }
            #endif
            return "local"
        }
        return backend.session?.user.id ?? ""
    }
    var email: String { backend.session?.user.email ?? "On this iPhone" }
    var tasks: [Record] { _ = taskRevision; return taskCache.tasks }
    var filterContext: FilterContext { FilterContext(projects: projects, sections: rows("sections"), labels: labels, userID: userID, people: projects.flatMap { project in projectMembers(project.id).map { person in var scoped = person; scoped["project_id"] = .string(project.id); return scoped } }, datePreferences: datePhrasePreferences) }
    var savedViews: [Record] { rows("saved_views").sorted { $0["order_index"].integer == $1["order_index"].integer ? $0.id < $1.id : $0["order_index"].integer < $1["order_index"].integer } }
    var favorites: [Record] { rows("favorites").sorted { $0["order_index"].integer == $1["order_index"].integer ? $0.id < $1.id : $0["order_index"].integer < $1["order_index"].integer } }
    var workingHours: WorkingHours? { workingHoursDocument == .null ? WorkingHours() : try? WorkingHours(document: workingHoursDocument) }
    var workingHoursDocument: JSON { record("view_preferences", id: "planner")?["working_hours"] ?? .null }
    var workingHoursEditable: Bool { workspaceCacheReadable && (signedIn || localMode) && WorkingHours.editable(workingHoursDocument) }
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
    var focusAvailable: Bool { workspaceCacheReadable && (signedIn || localMode) }
    var focusSession: FocusSession? { FocusSessionChange.session(in: focusRecord, account: userID) }
    @discardableResult func changeFocus(_ session: FocusSession?, expected: Record?, workspace: WorkspaceBinding) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), workspaceCacheReadable, signedIn || localMode,
              focusSyncConflict == nil, FocusSessionChange.baseline(focusRecord) == FocusSessionChange.baseline(expected) else {
            error = "This Focus session changed. Review its current state before continuing."; return false
        }
        if let session, session.status == .running || session.id != focusSession?.id {
            guard tasks.contains(where: { $0.id.lowercased() == session.taskID && !$0.completed }) else {
                error = "This task is no longer open in your workspace."; return false
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
            query.filterProjects = projects.map { FilterReference(id: $0.id, name: $0.name) }; query.filterSections = rows("sections").map { FilterReference(id: $0.id, name: $0.name, projectID: $0.string("project_id").isEmpty ? nil : $0.string("project_id")) }
            query.filterPeople = filterContext.personReferences
            query.filter = rule; query.datePreferences = datePhrasePreferences; query.now = rule.usesClockWindow ? calendarContext.minute : nil; query.filterLabels = labels.map { FilterReference(id: $0.id, name: $0.name) }; query.userID = userID
            query.includeCompleted = query.includeCompleted || view["include_completed"].flag || (!rule.hasQuerySections && rule.includesCompletion)
        }
        return taskCache.matching(query)
    }
    func filterGroups(_ scope: TaskScope, tasks: [Record], includeCompleted: Bool = false) -> [TaskGrouping.Group] {
        let view: Record? = { if case .saved(let id) = scope { return record("saved_views", id: id) }; return nil }()
        let rule = view.flatMap { try? FilterRule(document: $0["query_ast"]) }
        return TaskGrouping.queryGroups(tasks, rule: rule, by: viewValue(scope, field: "grouping", fallback: .string("none")).text, context: filterContext, today: calendarContext.today, timeZone: calendarContext.timeZone, includeCompleted: includeCompleted || view?["include_completed"].flag == true, now: calendarContext.minute)
    }
    func captureDefaults(_ scope: TaskScope) -> [String: JSON] {
        guard case .saved(let id) = scope, let view = record("saved_views", id: id), let rule = try? FilterRule(document: view["query_ast"]), (try? rule.validate(in: filterContext)) != nil else { return [:] }
        return rule.captureDefaults(in: filterContext, today: calendarContext.today, timeZone: calendarContext.timeZone)
    }
    func filterError(_ scope: TaskScope) -> String? {
        guard case .saved(let id) = scope else { return nil }
        guard let view = record("saved_views", id: id) else { return "This saved filter was deleted or is unavailable on this account." }
        do { let rule = try FilterRule(document: view["query_ast"]); try rule.validate(in: filterContext); return nil }
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
    func reorderFavorites(_ keys: [String]) {
        let changes = keys.enumerated().compactMap { index, id -> Mutation? in
            guard record("favorites", id: id) != nil else { return nil }
            return Mutation(table: "favorites", recordID: id, method: "PATCH", fields: ["order_index": .number(Double(index))])
        }
        _ = commit(changes)
    }
    var projects: [Record] { rows("projects").sorted { $0["order_index"].integer < $1["order_index"].integer } }
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
    var pendingCount: Int { snapshot.pending.count }
    var cacheURL: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Taskfold", directoryHint: .isDirectory)
        return folder.appending(path: "\(userID.isEmpty ? "signed-out" : userID).json")
    }
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--live-auth-ui-test") {
            try? backend.clearSession()
            UserDefaults.standard.set(false, forKey: "localMode")
        }
        #endif
        localMode = UserDefaults.standard.bool(forKey: "localMode")
        googleAvatarURL = backend.session?.user.googleAvatarURL
        signedIn = backend.session != nil || localMode
        if signedIn { load() } else { publishWidgetSnapshot() }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.online = path.status == .satisfied
                if path.status == .satisfied { await self?.refreshRemoteReminderRegistration(); await self?.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "taskfold.connectivity"))
        Task { await refreshRemoteReminderRegistration() }
    }
    func rows(_ table: String) -> [Record] { snapshot.tables[table] ?? [] }
    func record(_ table: String, id: String) -> Record? { rows(table).first { $0.id == id } }
    func projectMembers(_ projectID: String) -> [Record] {
        guard let project = record("projects", id: projectID) else { return [] }
        let key = "project_members:" + projectID
        let people = snapshot.tables[key] ?? rows("project_collaborators").filter { $0.string("project_id") == projectID }
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
        let generation = accountGeneration
        let data = try await backend.request("/rest/v1/rpc/taskfold_project_members", method: "POST", body: ["_project_id": .string(projectID)])
        let people = try JSONDecoder().decode([Record].self, from: data).map { person in
            var member = person; member["status"] = .string("accepted"); return member
        }
        guard generation == accountGeneration else { throw CancellationError() }
        snapshot.tables["project_members:" + projectID] = people
        try persist()
        return projectMembers(projectID)
    }
    func load() {
        workspaceCacheReadable = false
        defer {
            if localMode, workspaceCacheReadable { migrateOrganization() }
            if workspaceCacheReadable {
                do { try persist(); consumeWidgetCompletions() }
                catch { self.error = "Could not prepare widget actions: " + error.localizedDescription }
            }
        }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { snapshot = Snapshot(); workspaceCacheReadable = true; return }
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cacheURL))
            workspaceCacheReadable = true
            if snapshot.tables[DayPlacement.table] == nil, let legacy = snapshot.tables["_local_day_order"] {
                snapshot.tables[DayPlacement.table] = legacy.map { row in var row = row; row["user_id"] = .string(userID); return row }
            }
        }
        catch { self.error = "Could not read saved tasks: \(error.localizedDescription)"; if let disk = try? widgetActionDisk() { try? disk.clearProjection() } }
    }
    func persist() throws {
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
        try JSONEncoder().encode(snapshot).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        publishWidgetSnapshot()
        scheduleDailyBackup()
    }
    func makeInboxReview(batch: InboxReviewBatch = .five, excluding: Set<String> = []) -> InboxReviewRequest? {
        guard signedIn || localMode, workspaceCacheReadable else { error = "Open a readable workspace before reviewing Inbox."; return nil }
        let order = record(DayPlacement.table, id: "scope:inbox")?["ids"].list.map(\.text) ?? []
        return InboxReviewRequest(workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), tasks: tasks, batch: batch, order: order, excluding: excluding)
    }

    static let appGroup = "group.com.dbakp.taskfold"
    /// The private cache is saved before its actionable projection is published.
    private func publishWidgetSnapshot(scheduleCapacityRefresh: Bool = true) {
        guard let disk = try? widgetActionDisk() else { return }
        let account = signedIn || localMode ? userID : ""
        let busy = CalendarBusyStore.shared; busy.bind(account: account)
        let current = widgetCalendarWindow.flatMap { value -> CalendarCapacityWindow? in
            value.account == account && value.timeZone == TimeZone.current.identifier && busy.revision == widgetCalendarRevision && Date() < value.updated.addingTimeInterval(3600) ? value : nil
        }
        let fallback = busy.connected ? (busy.selected.isEmpty ? "choose" : "refresh") : "off"
        let payload = WidgetProjection.payload(tasks: tasks, projects: projects, account: account, labels: labels, sections: rows("sections"), savedViews: savedViews, completionTokens: WidgetCompletion.tokens(snapshot), pendingSync: pendingCount, workingHours: workingHours, calendarWindow: current, calendarFallback: fallback, notePins: rows("view_orders"), focusRecord: focusRecord, focusConflict: focusSyncConflict != nil, focusReadable: workspaceCacheReadable, pulseActivity: rows(TaskActivity.table), pulseEpoch: rows(TaskActivity.epochTable), datePreferences: datePhrasePreferences, people: filterContext.people)
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
        let account = signedIn || localMode ? userID : ""
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
        if calendarContextFixtureEnabled || clockWindowFixtureEnabled || datePhraseFixtureEnabled || assigneePatternFixtureEnabled {
            return WidgetActionDisk(directory: cacheURL.deletingLastPathComponent().appending(path: "CalendarContextTests", directoryHint: .isDirectory))
        }
        if ProcessInfo.processInfo.arguments.contains("--widget-action-testing") {
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
            guard commit(changes, widgetReceipt: request) else {
                throw WidgetActionFailure(error ?? "Your widget completion could not be saved. Open Taskfold to retry.")
            }
            return true
        }
    }
    /// Startup, foreground refresh and connectivity retry the same credential-free handoff.
    func consumeWidgetCompletions() {
        guard !consumingWidgetActions, workspaceCacheReadable, signedIn || localMode,
              let disk = try? widgetActionDisk() else { return }
        consumingWidgetActions = true; defer { consumingWidgetActions = false }
        widgetActionStatus = nil
        do {
            for request in try disk.pending(account: userID) {
                let applied = try applyWidgetCompletion(request)
                if !applied { widgetActionStatus = "A widget completion became out of date. Refresh the widget before trying again."; notice = widgetActionStatus }
                try disk.acknowledge(request)
            }
        } catch { widgetActionStatus = "A widget completion is waiting: " + error.localizedDescription; notice = widgetActionStatus }
    }
    func startLocal() {
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
        guard backend.session != nil else { return }
        googleAvatarURL = backend.session?.user.googleAvatarURL; avatarMetadataLoaded = false
        accountGeneration = UUID(); localMode = false; signedIn = true; syncConflict = nil; focusSyncConflict = nil
        CalendarBusyStore.shared.bind(account: userID)
        UserDefaults.standard.set(false, forKey: "localMode")
        snapshot = Snapshot(); undoStack = []; redoStack = []; load(); Task { await refreshRemoteReminderRegistration(); await sync() }
    }
    func signOut() {
        // The account-specific cache and unsent queue stay on disk for the next sign-in.
        do { try persist(); try prepareReminderDeviceRetirement(); try backend.clearSession() } catch { self.error = error.localizedDescription; return }
        googleAvatarURL = nil; avatarMetadataLoaded = false
        accountGeneration = UUID(); backend.session = nil; signedIn = false; localMode = false
        UserDefaults.standard.set(false, forKey: "localMode")
        snapshot = Snapshot(); undoStack = []; redoStack = []; lastSync = nil; syncConflict = nil; focusSyncConflict = nil
        CalendarBusyStore.shared.bind(account: "")
        publishWidgetSnapshot()
        clearScheduledReminders()
    }
    @discardableResult
    func commit(_ changes: [Mutation], remember: Bool = true, widgetReceipt: WidgetCompletionRequest? = nil) -> Bool {
        guard changes.allSatisfy({ $0.table != TaskActivity.table && $0.table != TaskActivity.epochTable }) else { error = "Activity history is read-only."; return false }
        guard changes.filter({ $0.table == FocusSessionChange.table }).allSatisfy({ FocusSessionChange.valid($0, account: userID) }) else {
            error = "This Focus command needs a valid workspace and revision."; return false
        }
        let old = snapshot
        let changes = changes.flatMap { TaskAssignment.mutations($0, existing: record($0.table, id: $0.recordID)) }.map { change in
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
                if case .array(let values)? = change.fields["labels"] { change.fields["labels"] = .array(TaskLabels.normalized(values, labels: labels)) }
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
                change.baseline = Dictionary(uniqueKeysWithValues: change.fields.keys.map { ($0, existing[$0]) })
            }
            if change.table == "tasks", change.method == "DELETE", change.baseline == nil, let existing = record("tasks", id: change.recordID) {
                change.baseline = existing.fields
            }
            change = TaskCompletionRevision.capturing(change, existing: record(change.table, id: change.recordID))
            guard TaskGeneration.permitsLocalAction(change, existing: record(change.table, id: change.recordID)) else {
                snapshot = old
                error = "This task was deleted and restored while you were editing. Reopen its current copy before applying this change."
                return false
            }
            committedChanges.append(change)
            let before = change.table == "tasks" ? record("tasks", id: change.recordID) : nil
            snapshot.apply(change)
            if localMode { TaskActivity.recordLocal(change, before: before, after: record("tasks", id: change.recordID), snapshot: &snapshot, account: userID) }
            if !localMode { snapshot.pending.append(change) }
        }
        if let widgetReceipt { snapshot.widgetCompletion.record(widgetReceipt) }
        do { try persist() } catch { snapshot = old; self.error = "Your change could not be saved: \(error.localizedDescription)"; return false }
        let historyChanges = committedChanges.filter { $0.table != FocusSessionChange.table }
        if remember, !historyChanges.isEmpty { undoStack.append(EditHistory(changes: historyChanges, snapshot: old)); if undoStack.count > 30 { undoStack.removeFirst() }; redoStack = [] }
        Task { await reschedule(); await sync() }
        return true
    }
    @discardableResult
    func save(_ table: String, _ record: Record, baseline: Record? = nil, applyReminderDefaults: Bool = true) -> Bool {
        let existing = self.record(table, id: record.id)
        let record = table == "tasks" && applyReminderDefaults ? applyingReminderDefault(record, previous: baseline ?? existing) : record
        let editable = record.fields.filter { table != "tasks" || $0.key != "completion_version" && (existing == nil || $0.key != "task_generation") }
        let changed = (baseline ?? existing).map { old in editable.filter { old.fields[$0.key] != $0.value } } ?? editable
        guard !changed.isEmpty else { return true }
        var changes = [Mutation(table: table, recordID: record.id, method: existing == nil ? "POST" : "PATCH", fields: changed, baseline: baseline.map { old in
            table == "tasks" ? TaskCompletionRevision.editBaseline(for: changed, from: old) : Dictionary(uniqueKeysWithValues: changed.keys.map { ($0, old[$0]) })
        })]
        if table == "labels", let existing, existing.name != record.name {
            for task in tasks {
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
            for task in tasks {
                let values = TaskLabels.normalized(task["labels"].list, labels: labels)
                if values.contains(.string(label.id)) {
                    changes.append(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["labels": .array(values.filter { $0 != .string(id) })]))
                }
            }
        }
        if table == "projects" {
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
    func toggle(_ task: Record) { commit(toggleChanges(task)) }
    /// Completes or reopens several tasks as one undoable change.
    func toggleAll(_ tasks: [Record]) { let changes = tasks.flatMap(toggleChanges); if !changes.isEmpty { commit(changes) } }
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
    func toggleChanges(_ task: Record) -> [Mutation] { TaskCompletion.toggle(task, tasks: tasks) }
    private func historyChanges(_ changes: [Mutation]) -> [Mutation] {
        changes.map { change in
            if change.table == "tasks", change.method == "POST" {
                return TaskGeneration.restoring(change, existing: record("tasks", id: change.recordID))
            }
            guard change.table == "tasks", change.method == "PATCH", let base = change.baseline,
                  let current = record("tasks", id: change.recordID) else { return change }
            var next = change
            next.fields = Dictionary(uniqueKeysWithValues: change.fields.map { key, value in
                (key, TaskEdit.keepingLocal(base: base[key] ?? .null, desired: value, remote: current[key]))
            })
            next.baseline = nil // commit captures the actual state before applying the rebased inverse.
            return next
        }
    }
    func undo() {
        guard let entry = undoStack.popLast() else { return }
        let changes = historyChanges(entry.undo), applied = EditHistory(changes: changes, snapshot: snapshot)
        if commit(changes, remember: false) { redoStack.append(applied.reversed) } else { undoStack.append(entry) }
    }
    func redo() {
        guard let entry = redoStack.popLast() else { return }
        let changes = historyChanges(entry.redo), applied = EditHistory(changes: changes, snapshot: snapshot)
        if commit(changes, remember: false) { undoStack.append(applied) } else { redoStack.append(entry) }
    }
    func sync() async {
        consumeWidgetCompletions()
        guard signedIn, !localMode, online, !syncing, syncConflict == nil, focusSyncConflict == nil else { return }
        syncing = true; let generation = accountGeneration, account = userID
        var sending: Mutation?
        defer { syncing = false }
        do {
            while let mutation = snapshot.pending.first {
                sending = mutation
                let saved = try await backend.send(mutation, expectedAccount: account)
                guard generation == accountGeneration else { return }
                snapshot.acknowledge(mutation, saved: saved); try persist()
            }
            var remote: [String: [Record]] = [:]
            for table in ["projects", "sections", "labels", "tasks", "profiles", "project_collaborators", "saved_views", "favorites", "view_preferences", "view_orders", ReminderSnooze.table, "focus_sessions", "task_activity_epoch", "task_activity"] {
                remote[table] = try await backend.rows(table)
                guard generation == accountGeneration else { return }
            }
            snapshot.mergeRemote(remote); try persist(); lastSync = Date(); migrateOrganization()
            if !avatarMetadataLoaded {
                do { try await backend.refreshUser(); if generation == accountGeneration { avatarMetadataLoaded = true } }
                catch { /* Optional avatar refresh must not interrupt task synchronization. */ }
            }
            guard generation == accountGeneration else { return }
            googleAvatarURL = backend.session?.user.googleAvatarURL
            await reschedule()
        } catch {
            if generation == accountGeneration {
                notice = SyncStatus.failureMessage(error)
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
        notice = widgetActionStatus
        // Edits made while fetching are still queued; flush after this sync releases its lock.
        if !snapshot.pending.isEmpty { Task { await self.sync() } }
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
            remoteReminderStatus = "Remote reminders are not available in this workspace. Reminders stay on this device."; return
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
                remoteReminderStatus = localMode || !signedIn ? "Sign in to prepare remote reminders. Current reminders stay on this device." :
                    eligible && reminderAppIdentity == nil ? "Remote setup is unavailable in this build. Reminders continue on this device." :
                    "Remote reminders are not available yet. Reminders stay on this device."
            }
        } catch {
            remoteReminderStatus = remoteReminderHoldingOriginals ? "Task reminders are waiting for confirmed delivery. Check remote setup to retry." : "Device registration could not be saved securely. Reminders continue on this device."; remoteReminderBusy = false
        }
    }
    func receivedRemoteReminderToken(_ token: Data) async {
        guard !isolatedReminderDeviceFixture else { return }
        await refreshRemoteReminderRegistration()
        do { try reminderDeviceLifecycle?.receivedToken(token) }
        catch { remoteReminderStatus = remoteReminderHoldingOriginals ? "Task reminders are waiting for confirmed delivery. Check remote setup to retry." : "Device registration could not be saved securely. Reminders continue on this device."; remoteReminderBusy = false }
    }
    func failedRemoteReminderToken() {
        guard !isolatedReminderDeviceFixture else { return }
        reminderDeviceLifecycle?.failedToken()
    }

    private var reminderPreferenceKey: String { ReminderPreferences.key(userID) }
    var remindersEnabled: Bool {
        _ = reminderPreferenceRevision
        guard signedIn || localMode, !userID.isEmpty else { return false }
        return ReminderPreferences.enabled(account: userID, fixture: userID == "ui-testing" || userID == "preview")
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
        reminderRevision += 1
        var events = remindersEnabled ? DueReminder.events(tasks: tasks) : []
        if focusAlertsEnabled, let event = focusFinishEvent { events.append(event) }
        return ReminderState(revision: reminderRevision, account: remindersEnabled || focusAlertsEnabled ? userID : "", events: events, validationTasks: remindersEnabled ? tasks : [], deliveryAuthority: reminderAuthority, deliveryAuthorityUnreadable: reminderAuthorityUnreadable, deliveryAuthorityAccount: remoteReminderTestWorkspace ? reminderAuthorityAccount : nil)
    }
    func reschedule() async {
        ReminderCategory.register(minutes: reminderSnoozeMinutes)
        refreshCalendarContext()
        await refreshRemoteReminderRegistration()
        let state = reminderState(), generation = accountGeneration
        let report = await reminderScheduler.update(state)
        guard generation == accountGeneration, state.revision == reminderRevision, report.revision == state.revision else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard generation == accountGeneration, state.revision == reminderRevision else { return }
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
        return DueReminder.validated(tasks: tasks, taskID: task, specID: spec, signature: signature, originalAt: (info["originalAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
    func reminderTask(for route: ReminderTaskRoute) -> Record? {
        let valid = workspaceCacheReadable && (signedIn || localMode) && remindersEnabled &&
            route.workspace.matches(account: userID, generation: workspaceGeneration) &&
            DueReminder.validated(tasks: tasks, taskID: route.taskID, specID: route.specID, signature: route.signature, originalAt: route.originalAt) != nil
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
            if let due = TaskPlanner.dayDate(task), let next = Calendar.current.date(byAdding: .day, value: 1, to: max(due, Calendar.current.startOfDay(for: Date()))) {
                _ = commit([Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: TaskPlanner.dayFields(task: task, day: TaskPlanner.dayKey(next)))])
            }
        case let action where ReminderSnooze.minutes(action: action) != nil:
            guard let minutes = ReminderSnooze.minutes(action: action) else { return nil }
            let generation = accountGeneration, account = userID
            await reschedule()
            guard generation == accountGeneration, validReminder(info) != nil else { return nil }
            if let report = await reminderScheduler.snooze(account: account, taskID: event.taskID, specID: event.specID, signature: event.signature, minutes: minutes, originalAt: event.date), generation == accountGeneration {
                if report.failures > 0 { reminderStatus = "The snooze could not be scheduled. Open the task to try again." }
                else if report.deferred > 0 { reminderStatus = "The nearest 60 reminders are scheduled. This snooze may be deferred until Taskfold refreshes." }
            }
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
        guard userID == "ui-testing", ProcessInfo.processInfo.arguments.contains("--reminder-route-testing"), let event = DueReminder.events(tasks: tasks).first else { return nil }
        return ReminderTaskRoute(workspace: WorkspaceBinding(account: userID, generation: workspaceGeneration), taskID: event.taskID, specID: event.specID, signature: event.signature)
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
            for change in TaskCompletion.toggle(task, tasks: tasks, at: now.addingTimeInterval(interval)) {
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
        let changes = TaskCompletion.complete(root, tasks: tasks)
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
