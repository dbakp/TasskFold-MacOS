import Foundation
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The Store-facing half of system integration: the Core Spotlight index, the Focus filter's
/// scope, and Control Center requests. Decisions are made in the pure Core files
/// (`SpotlightIndexing`, `FocusFilter`, `IntentLogic`); this file only applies them.
enum SpotlightAttributes {
    static func make(_ document: SpotlightDocument) -> CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: document.kind == .project ? .folder : .text)
        set.title = document.title
        set.displayName = document.title
        set.textContent = document.textContent.isEmpty ? nil : document.textContent
        set.contentDescription = document.contentDescription
        set.keywords = document.keywords.isEmpty ? nil : document.keywords
        // The due day reads once, in contentDescription; a separate dueDate would add a second, time-stamped line.
        set.containerTitle = document.projectName
        return set
    }
}

extension Store {
    /// Project and label display names, for describing a task without the whole workspace.
    var spotlightNames: (projects: [String: String], labels: [String: String]) {
        (Dictionary(allProjects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
         Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    // MARK: Focus filter

    /// The scope currently narrowing this workspace's lists, or nil when nothing is narrowed
    /// (no filter, another account's filter, or "Show all" chosen for this activation).
    var focusScope: FocusFilterScope? {
        guard signedIn || localMode,
              let scope = FocusFilterScope.resolve(focusFilterState, account: userID, projects: projects) else { return nil }
        return focusFilterShownAllActivation == scope.activation ? nil : scope
    }
    /// A filter that is on but set aside with "Show all", so the banner can offer to resume it.
    var focusScopePaused: FocusFilterScope? {
        guard signedIn || localMode,
              let scope = FocusFilterScope.resolve(focusFilterState, account: userID, projects: projects),
              focusFilterShownAllActivation == scope.activation else { return nil }
        return scope
    }
    /// Adds the view-only project scope to a query for the lists a Focus filter narrows.
    func focusScoped(_ query: TaskQuery) -> TaskQuery {
        var query = query
        if query.scope.focusFilterApplies, let scope = focusScope { query.focusProjects = scope.projectIDs }
        return query
    }
    /// Project IDs left out of navigation counts when the filter hides other badges.
    var focusBadgeExclusions: Set<String> {
        guard let scope = focusScope, scope.hideOtherBadges else { return [] }
        return scope.excludedProjectIDs(allProjects: allProjects)
    }
    /// Projects the sidebar and Browse should list.
    func focusVisibleProjects<S: Sequence>(_ projects: S) -> [S.Element] where S.Element == Record {
        guard let scope = focusScope else { return Array(projects) }
        return projects.filter { scope.allows(project: $0.id) }
    }
    var focusFilterIsFixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--focus-filter-fixture")
        #else
        return false
        #endif
    }
    /// Stores the filter the system just applied (or cleared) and refreshes every surface.
    /// A fixture run keeps it in memory only, so it never writes the real App Group defaults.
    func applyFocusFilter(_ state: FocusFilterState?) {
        if !focusFilterIsFixture { FocusFilterStore.save(state, to: FocusFilterStore.defaults()) }
        focusFilterState = state
        focusFilterShownAllActivation = nil
        republishSystemSurfaces()
    }
    /// Picks up a change made while the app was not running.
    func reloadFocusFilter() {
        guard !focusFilterIsFixture else { return }
        let loaded = FocusFilterStore.load(FocusFilterStore.defaults())
        guard loaded != focusFilterState else { return }
        focusFilterState = loaded; focusFilterShownAllActivation = nil
        republishSystemSurfaces()
    }
    /// "Show all" lasts for this activation of the Focus only.
    func setFocusFilterShowAll(_ showAll: Bool) {
        focusFilterShownAllActivation = showAll ? focusFilterState?.activation : nil
        republishSystemSurfaces()
    }

    // MARK: Control Center

    /// Applies a Focus timer control tap through the normal Focus session path.
    func consumeFocusControlRequest() {
        guard focusAvailable, let disk = FocusControlDisk.system(), let request = disk.read() else { return }
        let binding = WorkspaceBinding(account: userID, generation: workspaceGeneration)
        switch FocusControlPlan.resolve(request, current: focusSession, tasks: activeTasks, today: Dates.day(Date())) {
        case .start(let taskID):
            if let session = try? FocusSession(taskID: taskID, minutes: 25) { changeFocus(session, expected: focusRecord, workspace: binding) }
        case .stop:
            if let current = focusSession, let stopped = try? current.stopped(at: Date()) { changeFocus(stopped, expected: focusRecord, workspace: binding) }
        case .ignore: break
        }
        disk.clear()
    }
    func reloadSystemControls() {
        #if canImport(WidgetKit) && os(iOS)
        ControlCenter.shared.reloadAllControls()
        #endif
    }

    // MARK: Spotlight

    func scheduleSpotlightIndex() { spotlight.schedule(self) }
    /// A selected Spotlight result becomes the existing task or project route.
    func spotlightURL(for activity: NSUserActivity) -> URL? {
        var route: SpotlightRoute?
        if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { route = SpotlightRoute(identifier: identifier) }
        else if #available(iOS 18.2, macOS 15.2, *), let entity = activity.appEntityIdentifier {
            if entity.entityType == TaskEntity.self { route = .task(entity.identifier) }
            else if entity.entityType == ProjectEntity.self { route = .project(entity.identifier) }
        }
        return route?.url(account: userID)
    }
}

/// Keeps the system Spotlight index equal to the open tasks and projects of the signed-in
/// workspace. Changes are debounced, diffed against what was indexed, and applied in batches.
/// The index is cleared at sign-out, and rebuilt on first launch after install or upgrade.
@MainActor final class SpotlightIndexer {
    private var debouncer = SpotlightDebouncer()
    private var timer: Task<Void, Never>?
    private var state: SpotlightIndexState?
    private var stateLoaded = false
    private var running = false
    private var again = false
    private var clearing = false
    /// DEBUG evidence: the identifiers a debug query found in the system index.
    private(set) var debugIdentifiers: [String] = []

    private static let batchSize = 100
    private var arguments: [String] {
        #if DEBUG
        return ProcessInfo.processInfo.arguments
        #else
        return []
        #endif
    }
    private var debugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    static var build: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "0") + "." + (info?["CFBundleVersion"] as? String ?? "0")
    }
    private var stateURL: URL { URL.applicationSupportDirectory.appending(path: "Taskfold/spotlight-index.json") }
    private var debugURL: URL { URL.applicationSupportDirectory.appending(path: "Taskfold/spotlight-debug.json") }

    /// Account boundary: drop any pending work bound to the old workspace.
    func suspend() { timer?.cancel(); timer = nil; debouncer.cancel() }

    func schedule(_ store: Store) {
        switch SpotlightIndexPolicy.decide(account: store.userID, arguments: arguments, signedIn: store.signedIn, debugBuild: debugBuild) {
        case .leaveAlone: return
        case .clear: Task { await clearAll() }
        case .index:
            guard store.sharedCaptureAvailable else { return }
            debouncer.request(at: Date())
            arm(store)
        }
    }

    private func arm(_ store: Store) {
        timer?.cancel()
        guard let fire = debouncer.fireDate else { return }
        let account = store.userID, generation = store.workspaceGeneration
        timer = Task { [weak self, weak store] in
            try? await Task.sleep(for: .seconds(max(0, fire.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let store else { return }
            guard store.userID == account, store.workspaceGeneration == generation else { return }
            if self.debouncer.isDue(at: Date()) { self.debouncer.fired(); await self.run(store) } else { self.arm(store) }
        }
    }

    func clearAll() async {
        guard !clearing else { return }
        clearing = true; defer { clearing = false }
        suspend()
        loadState()
        let hadIndex = state != nil || FileManager.default.fileExists(atPath: stateURL.path)
        state = nil; stateLoaded = true
        try? FileManager.default.removeItem(at: stateURL)
        if hadIndex { try? await CSSearchableIndex.default().deleteAllSearchableItems() }
    }

    private func loadState() {
        guard !stateLoaded else { return }
        stateLoaded = true
        guard let data = try? Data(contentsOf: stateURL) else { return }
        state = try? JSONDecoder().decode(SpotlightIndexState.self, from: data)
    }
    private func persist(_ value: SpotlightIndexState) {
        state = value
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func run(_ store: Store) async {
        guard !running else { again = true; return }
        running = true
        defer { running = false; if again { again = false; schedule(store) } }
        guard SpotlightIndexPolicy.decide(account: store.userID, arguments: arguments, signedIn: store.signedIn, debugBuild: debugBuild) == .index,
              store.sharedCaptureAvailable else { return }
        let account = store.userID, generation = store.workspaceGeneration
        let key = SpotlightDigest.hex(account)
        let documents = SpotlightMapper.documents(tasks: store.activeTasks, projects: store.projects, labels: store.labels)
        loadState()
        var current = state ?? .empty(build: Self.build, account: key)
        let index = CSSearchableIndex.default()
        if current.requiresFullReindex(build: Self.build, account: key) {
            do { try await index.deleteAllSearchableItems() } catch { return }
            current = .empty(build: Self.build, account: key)
            persist(current)
        }
        let plan = SpotlightIndexPlan.diff(indexed: current.fingerprints, current: documents)
        for batch in plan.batches(size: Self.batchSize) {
            // A sign-out or account switch while indexing abandons the rest.
            guard store.userID == account, store.workspaceGeneration == generation else { return }
            do {
                if !batch.removals.isEmpty { try await index.deleteSearchableItems(withIdentifiers: batch.removals) }
                if !batch.upserts.isEmpty { try await index.indexSearchableItems(batch.upserts.map { item($0, store) }) }
            } catch { return }
            current.fingerprints = SpotlightIndexPlan(upserts: batch.upserts, removals: batch.removals).applying(to: current.fingerprints)
            persist(current)
        }
        if debugBuild, arguments.contains(SpotlightIndexPolicy.fixtureFlag) { await writeDebugReport() }
    }

    private func item(_ document: SpotlightDocument, _ store: Store) -> CSSearchableItem {
        let item = CSSearchableItem(uniqueIdentifier: document.identifier, domainIdentifier: document.domain, attributeSet: SpotlightAttributes.make(document))
        // Share the entity with Spotlight and Siri, keeping the identifiers the app routes on.
        switch document.kind {
        case .task: if let record = store.record("tasks", id: document.recordID) { item.associateAppEntity(TaskEntity(record)) }
        case .project: if let record = store.record("projects", id: document.recordID) { item.associateAppEntity(ProjectEntity(record)) }
        }
        return item
    }

    /// DEBUG only: asks the system index what it holds and writes the identifiers to a file.
    private func writeDebugReport() async {
        let found: [String] = await withCheckedContinuation { continuation in
            var identifiers: [String] = []
            let query = CSSearchQuery(queryString: "domainIdentifier == \"\(SpotlightKind.task.domain)\" || domainIdentifier == \"\(SpotlightKind.project.domain)\"", attributes: nil)
            query.foundItemsHandler = { items in identifiers += items.map(\.uniqueIdentifier) }
            query.completionHandler = { _ in continuation.resume(returning: identifiers.sorted()) }
            query.start()
        }
        debugIdentifiers = found
        let report: [String: Any] = ["build": Self.build, "count": found.count, "identifiers": found, "tracked": state?.fingerprints.keys.sorted() ?? []]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: debugURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: debugURL, options: .atomic)
        }
        NSLog("TaskfoldSpotlightDebug count=%d ids=%@", found.count, found.joined(separator: ","))
    }
}

#if DEBUG
extension Store {
    /// `--focus-filter-fixture` (with `--preview`): a fixture workspace of five projects with a Focus
    /// filter on three of them. The filter is held in memory only, never written to the shared defaults.
    func installFocusFilterFixture() {
        guard ProcessInfo.processInfo.arguments.contains("--focus-filter-fixture"), localMode, userID == "preview" else { return }
        let user = userID
        func project(_ id: String, _ name: String, _ color: String, order: Double, parent: String = "") -> Record {
            Record(["id": .string(id), "user_id": .string(user), "name": .string(name), "color": .string(color), "order_index": .number(order),
                    "parent_id": parent.isEmpty ? .null : .string(parent)])
        }
        func task(_ title: String, project: String, priority: Int = 4) -> Record {
            var row = Record.task(user: user, project: project, date: Date())
            row["title"] = .string(title); row["priority"] = .number(Double(priority)); return row
        }
        snapshot.tables["projects"] = [
            project("fx-work", "Work", "#3b82f6", order: 1), project("fx-reports", "Reports", "#3b82f6", order: 2, parent: "fx-work"),
            project("fx-client", "Client", "#e31e4b", order: 3), project("fx-admin", "Admin", "#22c55e", order: 4),
            project("fx-home", "Home", "#f59e0b", order: 5), project("fx-personal", "Personal", "#a855f7", order: 6)]
        snapshot.tables["tasks"] = [
            task("Send the revised proposal", project: "fx-work", priority: 1), task("Draft the quarterly report", project: "fx-reports", priority: 2),
            task("Prepare the client workshop", project: "fx-client", priority: 2), task("File the expense claim", project: "fx-admin", priority: 3),
            task("Book the dentist", project: "fx-home"), task("Water the plants", project: "fx-home"), task("Plan the weekend trip", project: "fx-personal", priority: 3),
            task("Read that article about slow productivity", project: "")]
        try? persist()
        focusFilterState = FocusFilterState(account: user, name: "Work", projectIDs: ["fx-work", "fx-client", "fx-admin"], hideOtherBadges: true)
        focusFilterShownAllActivation = nil
    }
}
#endif
