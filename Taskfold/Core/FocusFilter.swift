import Foundation

/// A Focus filter narrows what Taskfold shows. It is a view-only scope: it never edits,
/// hides or withholds data from sync, and it never rewrites a saved filter's stored query.
/// The active filter lives in the App Group defaults so the app, its intents and the widgets
/// agree without a second data path.
struct FocusFilterState: Codable, Equatable, Sendable {
    static let version = 1
    var version = FocusFilterState.version
    /// The workspace the project IDs belong to. A filter from another account is ignored.
    /// Empty when the system applied the filter before the app had opened a workspace; project IDs are unique per account.
    var account: String
    /// Optional label shown in the banner ("Work"). The system does not tell filters the Focus name.
    var name: String
    var projectIDs: [String]
    var hideOtherBadges: Bool
    /// New on every activation, so "Show all" lasts for one activation only.
    var activation = UUID()

    var isActive: Bool { !projectIDs.isEmpty }
}

enum FocusFilterStore {
    static let key = "taskfold.focusFilter.v1"
    static let group = "group.com.dbakp.taskfold"

    static func defaults(_ suite: String = group) -> UserDefaults? { UserDefaults(suiteName: suite) }

    static func load(_ defaults: UserDefaults?) -> FocusFilterState? {
        guard let data = defaults?.data(forKey: key),
              let state = try? JSONDecoder().decode(FocusFilterState.self, from: data),
              state.version == FocusFilterState.version, state.isActive else { return nil }
        return state
    }
    static func save(_ state: FocusFilterState?, to defaults: UserDefaults?) {
        guard let defaults else { return }
        guard let state, state.isActive, let data = try? JSONEncoder().encode(state) else { defaults.removeObject(forKey: key); return }
        defaults.set(data, forKey: key)
    }
}

/// The projects a Focus filter currently allows, resolved against the readable workspace.
struct FocusFilterScope: Equatable, Sendable {
    /// Chosen projects plus every subproject below them.
    var projectIDs: Set<String>
    var chosenCount: Int
    var name: String
    var hideOtherBadges: Bool
    var activation: UUID

    /// `nil` means "no scope": no filter, a filter for another account, or one whose
    /// projects no longer exist. Never an empty scope that would hide everything.
    static func resolve(_ state: FocusFilterState?, account: String, projects: [Record]) -> FocusFilterScope? {
        guard let state, state.isActive, !account.isEmpty, state.account.isEmpty || state.account == account else { return nil }
        let known = Set(projects.map(\.id))
        let chosen = state.projectIDs.filter { known.contains($0) }
        guard !chosen.isEmpty else { return nil }
        var ids = Set<String>()
        for id in chosen { ids.formUnion(ProjectOrganization.descendants(id, in: projects)) }
        return FocusFilterScope(projectIDs: ids, chosenCount: Set(chosen).count, name: state.name,
                                hideOtherBadges: state.hideOtherBadges, activation: state.activation)
    }

    func allows(project id: String) -> Bool { projectIDs.contains(id) }
    /// Inbox work belongs to no project, so a project scope leaves it out.
    func allows(task: Record) -> Bool { projectIDs.contains(task.string("project_id")) }
    func apply(to tasks: [Record]) -> [Record] { tasks.filter(allows(task:)) }
    func apply(toProjects projects: [Record]) -> [Record] { projects.filter { allows(project: $0.id) } }

    /// Project IDs to leave out of navigation counts. The empty ID stands for Inbox work.
    func excludedProjectIDs(allProjects: [Record]) -> Set<String> {
        Set(allProjects.map(\.id)).subtracting(projectIDs).union([""])
    }

    var bannerText: String {
        let count = chosenCount == 1 ? "1 project" : "\(chosenCount) projects"
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label.isEmpty ? "Focus filter" : "Focus: " + label) + " · showing " + count
    }
    var bannerAccessibilityLabel: String {
        let count = chosenCount == 1 ? "1 project" : "\(chosenCount) projects"
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label.isEmpty ? "Focus filter is on" : "Focus \(label) is on") + ", showing " + count + ". Tasks in other projects are hidden from view, not changed."
    }
}

extension TaskScope {
    /// Lists a Focus filter narrows. A project opened on purpose is shown as it is.
    var focusFilterApplies: Bool {
        switch self {
        case .today, .upcoming, .inbox, .all, .label, .saved: return true
        case .completed, .project: return false
        }
    }
}
