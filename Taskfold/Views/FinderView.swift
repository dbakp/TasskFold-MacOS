import SwiftUI

/// Search and navigation are independent of the current list's filters and draft.
struct FinderView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool
    /// The last few searches, shared with iOS through the "recentSearches" key.
    @AppStorage("recentSearches") private var recentSearchesData = Data()
    private var recentSearches: [String] { (try? JSONDecoder().decode([String].self, from: recentSearchesData)) ?? [] }
    private func remember(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentSearchesData = (try? JSONEncoder().encode(Array(list.prefix(6)))) ?? Data()
    }

    private struct Result: Identifiable {
        enum Target { case task(String), destination(SidebarItem), command(String), search(String) }
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let target: Target
    }
    private var terms: [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }
    private func matches(_ text: String) -> Bool { terms.allSatisfy { text.localizedStandardContains($0) } }
    private var destinations: [Result] {
        let standard: [(SidebarItem, String)] = [(.today, "Today"), (.inbox, "Inbox"), (.upcoming, "Upcoming"), (.calendar, "Calendar"), (.all, "All Tasks"), (.completed, "Completed")]
        return standard.map { Result(id: "destination-\($0.0.key)", title: $0.1, detail: "Go to", symbol: $0.0.symbol, target: .destination($0.0)) }
            + store.projects.map { Result(id: "destination-project:\($0.id)", title: $0.name, detail: "Project", symbol: "folder", target: .destination(.project($0.id))) }
            + store.labels.map { Result(id: "destination-label:\($0.id)", title: $0.name, detail: "Label", symbol: "tag", target: .destination(.label($0.id))) }
    }
    private var results: [Result] {
        let commands = [
            Result(id: "command-new", title: "New Task", detail: "Command · ⌘N", symbol: "plus", target: .command("new")),
            Result(id: "command-project", title: "New Project", detail: "Command · ⇧⌘N", symbol: "folder.badge.plus", target: .command("project")),
            Result(id: "command-filter", title: "Filter Current List", detail: "Command · ⇧⌘F", symbol: "line.3.horizontal.decrease", target: .command("filter"))
        ].filter { $0.id != "command-filter" || workspace.section != .calendar }
        if terms.isEmpty {
            let searches = recentSearches.map { Result(id: "search-\($0)", title: $0, detail: "Recent search", symbol: "clock.arrow.circlepath", target: .search($0)) }
            let recent = workspace.recentDestinations.compactMap { item in destinations.first { $0.id == "destination-\(item.key)" } }
            let ids = Set(recent.map(\.id))
            return searches + recent.map { Result(id: $0.id, title: $0.title, detail: "Recent", symbol: $0.symbol, target: $0.target) }
                + destinations.filter { !ids.contains($0.id) }.prefix(12) + commands
        }
        let navigation = destinations.filter { matches($0.title + " " + $0.detail) }
        let projects = Dictionary(store.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let tasks = store.tasks.filter { task in
            matches(task.title + " " + task.string("description") + " " + (projects[task.string("project_id")] ?? "") + " " + task["labels"].list.map(\.text).joined(separator: " "))
        }.sorted { lhs, rhs in
            let leftPrefix = lhs.title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
            let rightPrefix = rhs.title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
            if leftPrefix != rightPrefix { return leftPrefix }
            if lhs.completed != rhs.completed { return !lhs.completed }
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }.prefix(80).map { task in
            Result(id: "task-\(task.id)", title: task.title,
                   detail: (task.completed ? "Completed" : "Task") + " · " + (projects[task.string("project_id")] ?? "Inbox"),
                   symbol: task.completed ? "checkmark.circle" : "circle", target: .task(task.id))
        }
        return navigation + tasks + commands.filter { matches($0.title) }
    }

    var body: some View {
        let entries = results
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks, projects, and commands", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .accessibilityIdentifier("finderSearch")
                    .onSubmit { activateSelection(entries) }
                    .onKeyPress(.downArrow) { step(1, in: entries); return .handled }
                    .onKeyPress(.upArrow) { step(-1, in: entries); return .handled }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Close search (Esc)").accessibilityLabel("Close search")
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(entries) { result in
                        HStack(spacing: 12) {
                            Image(systemName: result.symbol).frame(width: 22).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).lineLimit(1)
                                Text(result.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 5).contentShape(.rect)
                        .tag(result.id).id(result.id)
                        .accessibilityIdentifier("finder-\(result.id)")
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let result = entries.first(where: { $0.id == id }) { activate(result) }
                }
                .onChange(of: selection) { _, value in if let value { proxy.scrollTo(value) } }
                .onSubmit { activateSelection(entries) }
                .overlay {
                    if entries.isEmpty { ContentUnavailableView.search(text: query) }
                }
            }
            Divider()
            HStack {
                Text(terms.isEmpty ? (recentSearches.isEmpty ? "Recent destinations and commands" : "Recent searches, destinations, and commands") : "Searches all tasks, including completed · up to 80 task matches")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open") { activateSelection(entries) }.keyboardShortcut(.defaultAction).disabled(selection == nil)
            }.padding(14)
        }
        .frame(width: 640, height: 460)
        .onAppear { selection = entries.first?.id; searchFocused = true }
        .onChange(of: query) { _, _ in selection = results.first?.id }
        .onChange(of: entries.map(\.id)) { _, ids in if selection.map({ !ids.contains($0) }) ?? true { selection = ids.first } }
        .onExitCommand { dismiss() }
    }
    private func step(_ delta: Int, in entries: [Result]) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : entries.count)
        selection = entries[min(max(index + delta, 0), entries.count - 1)].id
    }
    private func activateSelection(_ entries: [Result]) {
        guard let result = entries.first(where: { $0.id == selection }) else { return }
        activate(result)
    }
    private func activate(_ result: Result) {
        switch result.target {
        case .search(let term): query = term
        case .task(let id): remember(query); workspace.openFromFinder(id)
        case .destination(let item): remember(query); workspace.section = item; dismiss()
        case .command(let command):
            workspace.pendingFinderCommand = command
            dismiss()
        }
    }
}
