import SwiftUI
import Network
import UserNotifications
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
    @ObservationIgnored private let reminderScheduler = ReminderScheduler()
    @ObservationIgnored private var reminderRevision = 0
    private var reminderPreferenceRevision = 0
    var reminderStatus = "Choose whether this device delivers reminders."
    var requestingNotifications = false
    var signedIn = false
    var localMode = false
    var syncing = false
    var online = true
    var error: String?
    var notice: String?
    var syncConflict: SyncConflict?
    var lastSync: Date?
    var undoStack: [EditHistory] = []
    var redoStack: [EditHistory] = []
    let backend = Backend()
    private let monitor = NWPathMonitor()
    private var accountGeneration = UUID()
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
    var filterContext: FilterContext { FilterContext(projects: projects, sections: rows("sections"), labels: labels, userID: userID) }
    var savedViews: [Record] { rows("saved_views").sorted { $0["order_index"].integer == $1["order_index"].integer ? $0.id < $1.id : $0["order_index"].integer < $1["order_index"].integer } }
    var favorites: [Record] { rows("favorites").sorted { $0["order_index"].integer == $1["order_index"].integer ? $0.id < $1.id : $0["order_index"].integer < $1["order_index"].integer } }
    var workingHours: WorkingHours { (try? WorkingHours(document: record("view_preferences", id: "planner")?["working_hours"] ?? .null)) ?? WorkingHours() }
    @discardableResult func setWorkingHours(_ hours: WorkingHours) -> Bool {
        guard (try? WorkingHours(document: hours.document)) != nil else { error = "Choose valid working hours."; return false }
        var row = record("view_preferences", id: "planner") ?? Record(["id": .string("planner"), "user_id": .string(userID)])
        row["working_hours"] = hours.document
        return save("view_preferences", row)
    }
    func matching(_ query: TaskQuery) -> [Record] {
        _ = taskRevision
        var query = query
        if case .saved(let id) = query.scope {
            guard let view = record("saved_views", id: id), let rule = try? FilterRule(document: view["query_ast"]), (try? rule.validate(in: filterContext)) != nil else { return [] }
            query.filter = rule; query.filterLabels = labels.map { FilterReference(id: $0.id, name: $0.name) }; query.userID = userID
            query.includeCompleted = query.includeCompleted || view["include_completed"].flag || rule.includesCompletion
        }
        return taskCache.matching(query)
    }
    func captureDefaults(_ scope: TaskScope) -> [String: JSON] {
        guard case .saved(let id) = scope, let view = record("saved_views", id: id), let rule = try? FilterRule(document: view["query_ast"]), (try? rule.validate(in: filterContext)) != nil else { return [:] }
        return rule.captureDefaults(in: filterContext, today: Dates.day(Date()))
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
            currentProject: project, currentUser: userID)
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
                if path.status == .satisfied { await self?.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "taskfold.connectivity"))
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
        defer { if localMode { migrateOrganization() }; publishWidgetSnapshot() }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { snapshot = Snapshot(); return }
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cacheURL))
            if snapshot.tables[DayPlacement.table] == nil, let legacy = snapshot.tables["_local_day_order"] {
                snapshot.tables[DayPlacement.table] = legacy.map { row in var row = row; row["user_id"] = .string(userID); return row }
            }
        }
        catch { self.error = "Could not read saved tasks: \(error.localizedDescription)" }
    }
    func persist() throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        publishWidgetSnapshot()
        scheduleDailyBackup()
    }
    static let appGroup = "group.com.dbakp.taskfold"
    /// Widgets read a compact copy of open tasks from the shared App Group container.
    private func publishWidgetSnapshot() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
        let payload = WidgetProjection.payload(tasks: tasks, projects: projects, account: signedIn || localMode ? userID : "", labels: labels, sections: rows("sections"), savedViews: savedViews)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: container.appending(path: "widget.json"), options: .atomic)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }
    func startLocal() {
        let firstRun = !FileManager.default.fileExists(atPath: URL.applicationSupportDirectory.appending(path: "Taskfold/local.json").path)
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
        accountGeneration = UUID(); localMode = false; signedIn = true; syncConflict = nil
        CalendarBusyStore.shared.bind(account: userID)
        UserDefaults.standard.set(false, forKey: "localMode")
        snapshot = Snapshot(); undoStack = []; redoStack = []; load(); Task { await sync() }
    }
    func signOut() {
        // The account-specific cache and unsent queue stay on disk for the next sign-in.
        do { try persist(); try backend.clearSession() } catch { self.error = error.localizedDescription; return }
        googleAvatarURL = nil; avatarMetadataLoaded = false
        accountGeneration = UUID(); backend.session = nil; signedIn = false; localMode = false
        UserDefaults.standard.set(false, forKey: "localMode")
        snapshot = Snapshot(); undoStack = []; redoStack = []; lastSync = nil; syncConflict = nil
        CalendarBusyStore.shared.bind(account: "")
        publishWidgetSnapshot()
        clearScheduledReminders()
    }
    @discardableResult
    func commit(_ changes: [Mutation], remember: Bool = true) -> Bool {
        let old = snapshot
        let changes = changes.flatMap { TaskAssignment.mutations($0, existing: record($0.table, id: $0.recordID)) }.map { change in
            var change = change
            if change.table == "tasks", change.method != "DELETE" {
                change.fields = TaskPlanning.fields(change.fields, existing: record("tasks", id: change.recordID))
                if case .array(let values)? = change.fields["labels"] { change.fields["labels"] = .array(TaskLabels.normalized(values, labels: labels)) }
            }
            if change.table == DayPlacement.table, change.method != "DELETE" {
                change.method = "POST" // Stable composite upsert also handles pre-sync legacy rows.
                change.fields["id"] = .string(change.recordID); change.fields["user_id"] = .string(userID)
            }
            return change
        }
        for var change in changes {
            if change.table == "tasks", change.method == "PATCH", change.baseline == nil, let existing = record("tasks", id: change.recordID) {
                change.baseline = Dictionary(uniqueKeysWithValues: change.fields.keys.map { ($0, existing[$0]) })
            }
            if change.table == "tasks", change.method == "DELETE", change.baseline == nil, let existing = record("tasks", id: change.recordID) {
                change.baseline = existing.fields
            }
            snapshot.apply(change)
            if !localMode { snapshot.pending.append(change) }
        }
        do { try persist() } catch { snapshot = old; self.error = "Your change could not be saved: \(error.localizedDescription)"; return false }
        if remember { undoStack.append(EditHistory(changes: changes, snapshot: old)); if undoStack.count > 30 { undoStack.removeFirst() }; redoStack = [] }
        Task { await reschedule(); await sync() }
        return true
    }
    @discardableResult
    func save(_ table: String, _ record: Record, baseline: Record? = nil) -> Bool {
        let existing = self.record(table, id: record.id)
        let changed = (baseline ?? existing).map { old in record.fields.filter { old.fields[$0.key] != $0.value } } ?? record.fields
        guard !changed.isEmpty else { return true }
        var changes = [Mutation(table: table, recordID: record.id, method: existing == nil ? "POST" : "PATCH", fields: changed, baseline: baseline.map { old in Dictionary(uniqueKeysWithValues: changed.keys.map { ($0, old[$0]) }) })]
        if table == "labels", let existing, existing.name != record.name {
            for task in tasks {
                let values = TaskLabels.normalized(task["labels"].list, labels: labels)
                // Bind legacy names before the rename; IDs belonging to another label survive.
                if values != task["labels"].list && values.contains(.string(existing.id)) {
                    changes.append(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["labels": .array(values)]))
                }
            }
        }
        return commit(changes)
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
        if commit(historyChanges(entry.undo), remember: false) { redoStack.append(entry) } else { undoStack.append(entry) }
    }
    func redo() {
        guard let entry = redoStack.popLast() else { return }
        if commit(historyChanges(entry.redo), remember: false) { undoStack.append(entry) } else { redoStack.append(entry) }
    }
    func sync() async {
        guard signedIn, !localMode, online, !syncing, syncConflict == nil else { return }
        syncing = true; let generation = accountGeneration
        var sending: Mutation?
        defer { syncing = false }
        do {
            while let mutation = snapshot.pending.first {
                sending = mutation
                try await backend.send(mutation)
                guard generation == accountGeneration else { return }
                snapshot.pending.removeAll { $0.id == mutation.id }; try persist()
            }
            var remote: [String: [Record]] = [:]
            for table in ["projects", "sections", "labels", "tasks", "profiles", "project_collaborators", "saved_views", "favorites", "view_preferences", "view_orders"] {
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
                notice = "Sync paused: \(error.localizedDescription)"
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
        notice = nil
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

    private var reminderPreferenceKey: String { ReminderPreferences.key(userID) }
    var remindersEnabled: Bool {
        _ = reminderPreferenceRevision
        guard signedIn || localMode, !userID.isEmpty else { return false }
        return ReminderPreferences.enabled(account: userID, fixture: userID == "ui-testing" || userID == "preview")
    }
    func enableNotifications() async {
        guard !requestingNotifications, signedIn || localMode else { return }
        let generation = accountGeneration, account = userID, key = reminderPreferenceKey
        requestingNotifications = true
        defer { requestingNotifications = false }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard generation == accountGeneration, account == userID else { return }
            UserDefaults.standard.set(allowed, forKey: key); reminderPreferenceRevision += 1
            if allowed { await reschedule() }
            else { reminderStatus = "Permission is off. Allow Taskfold notifications in system settings." }
        } catch { if generation == accountGeneration { reminderStatus = "Notifications could not be enabled: " + error.localizedDescription } }
    }
    private func reminderState() -> ReminderState {
        reminderRevision += 1
        let enabled = remindersEnabled
        return ReminderState(revision: reminderRevision, account: enabled ? userID : "", events: enabled ? DueReminder.events(tasks: tasks) : [])
    }
    func reschedule() async {
        let state = reminderState(), generation = accountGeneration
        let report = await reminderScheduler.update(state)
        guard generation == accountGeneration, state.revision == reminderRevision, report.revision == state.revision else { return }
        guard remindersEnabled else { reminderStatus = "Reminders are off for this workspace on this device."; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard generation == accountGeneration, state.revision == reminderRevision else { return }
        var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        #if os(iOS)
        allowed = allowed || settings.authorizationStatus == .ephemeral
        #endif
        guard allowed else {
            reminderStatus = "Permission is off. Allow Taskfold notifications in system settings."; return
        }
        if report.failures > 0 { reminderStatus = "\(report.failures) \(report.failures == 1 ? "reminder" : "reminders") could not be scheduled. Taskfold will retry when opened." }
        else if report.deferred > 0 { reminderStatus = "\(report.scheduled) upcoming reminders scheduled; \(report.deferred) later ones will be refreshed while Taskfold is open." }
        else { reminderStatus = "\(report.scheduled) upcoming \(report.scheduled == 1 ? "reminder" : "reminders") scheduled on this device." }
    }
    func disableNotifications() {
        UserDefaults.standard.set(false, forKey: reminderPreferenceKey); reminderPreferenceRevision += 1
        clearScheduledReminders()
    }
    private func clearScheduledReminders() {
        reminderRevision += 1
        let state = ReminderState(revision: reminderRevision, account: "", events: [])
        reminderStatus = "Reminders are off for this workspace on this device."
        Task { _ = await reminderScheduler.update(state) }
    }
    func validReminder(_ info: [AnyHashable: Any]) -> DueReminder? {
        guard remindersEnabled, let account = info["accountID"] as? String, account == userID,
              let task = info["taskID"] as? String, let spec = info["specID"] as? String,
              let signature = info["signature"] as? String else { return nil }
        return DueReminder.events(tasks: tasks).first { $0.taskID == task && $0.specID == spec && $0.signature == signature }
    }
    /// Actions are scoped to the receiving workspace and the current task/reminder version.
    func handleReminder(_ info: [AnyHashable: Any], action: String) async -> String? {
        guard let event = validReminder(info), let task = record("tasks", id: event.taskID) else { return nil }
        switch action {
        case ReminderCategory.complete: toggle(task)
        case ReminderCategory.tomorrow:
            if let due = TaskPlanner.dayDate(task), let next = Calendar.current.date(byAdding: .day, value: 1, to: max(due, Calendar.current.startOfDay(for: Date()))) {
                _ = commit([Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: TaskPlanner.dayFields(task: task, day: TaskPlanner.dayKey(next)))])
            }
        case ReminderCategory.snoozeHour:
            let generation = accountGeneration, account = userID
            await reschedule()
            guard generation == accountGeneration, validReminder(info) != nil else { return nil }
            if let report = await reminderScheduler.snooze(account: account, taskID: event.taskID, specID: event.specID, signature: event.signature), generation == accountGeneration {
                if report.failures > 0 { reminderStatus = "The snooze could not be scheduled. Open the task to try again." }
                else if report.deferred > 0 { reminderStatus = "The nearest 60 reminders are scheduled. This snooze may be deferred until Taskfold refreshes." }
            }
        default: return task.id
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
    static func register() {
        let category = UNNotificationCategory(identifier: identifier, actions: [
            UNNotificationAction(identifier: complete, title: "Complete", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")),
            UNNotificationAction(identifier: snoozeHour, title: "Remind me in 1 hour", options: [], icon: UNNotificationActionIcon(systemImageName: "clock")),
            UNNotificationAction(identifier: tomorrow, title: "Move to tomorrow", options: [], icon: UNNotificationActionIcon(systemImageName: "sunrise")),
        ], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
