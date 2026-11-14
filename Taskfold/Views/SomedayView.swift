import SwiftUI
import AppKit

private struct SomedayMutedKey: EnvironmentKey { static let defaultValue: Set<String> = [] }
extension EnvironmentValues {
    /// Ids of Someday tasks, set only by lists that keep them visible (projects, labels, All, filters).
    var somedayMuted: Set<String> {
        get { self[SomedayMutedKey.self] }
        set { self[SomedayMutedKey.self] = newValue }
    }
}

/// Someday work stays in its project's list, quieter than scheduled work.
struct SomedayMute: ViewModifier {
    @Environment(\.somedayMuted) private var muted
    let task: Record
    func body(content: Content) -> some View {
        content.opacity(muted.contains(task.id) && !task.completed && task.string("due_date").isEmpty ? 0.62 : 1)
    }
}

/// Someday: ideas without a date, out of Today, Upcoming and Inbox until you want them.
struct SomedayView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Seconds since 1970 of the last review or snooze; kept on this device, never synced.
    @AppStorage("mac.somedayLastReview") private var lastReview = 0.0
    @State private var reviewing = false
    @State private var idea = ""
    @State private var pickerDate = Date()
    @State private var picking = false
    @FocusState private var ideaFocused: Bool

    private var all: [Record] { store.somedayTasks }
    private var prompt: Planning.Review? { Planning.review(all, now: Date(), lastReviewed: lastReview > 0 ? Date(timeIntervalSince1970: lastReview) : nil) }
    private var shown: [Record] {
        var rows = all
        if reviewing, let prompt { let stale = Set(prompt.staleIDs); rows = rows.filter { stale.contains($0.id) } }
        let text = workspace.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { rows = rows.filter { ($0.title + " " + $0.string("description")).localizedStandardContains(text) } }
        return rows
    }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    private var subtitle: String { all.count == 1 ? "1 idea" : "\(all.count) ideas" }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "plus.circle").foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
                TextField("Add an idea for someday", text: $idea)
                    .textFieldStyle(.plain).focused($ideaFocused)
                    .onSubmit(addIdea)
                    .accessibilityIdentifier("somedayAdd")
                Spacer(minLength: 0)
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
                TextField("Filter", text: $workspace.search).textFieldStyle(.plain).frame(maxWidth: 140).accessibilityIdentifier("listFilter")
            }
            .padding(DS.Space.s).background(.quaternary, in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
            .frame(maxWidth: ReadingColumn.width).frame(maxWidth: .infinity)
            if let prompt { reviewCard(prompt).frame(maxWidth: ReadingColumn.width).frame(maxWidth: .infinity).padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.s).transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)) }
            if all.isEmpty { empty }
            else {
                List(selection: Binding(get: { workspace.section == .someday ? workspace.selection : [] }, set: { value in
                    guard workspace.section == .someday else { return }
                    workspace.selection = value
                })) {
                    Section {
                        ForEach(shown) { task in
                            TaskRowView(task: task).tag(task.id).listRowSeparator(.hidden).id(task.id)
                                .accessibilityAction(named: "Schedule for tomorrow") { schedule([task.id], offset: 1, label: "tomorrow") }
                        }
                    } header: {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "moon.zzz").font(DS.Font.chip).foregroundStyle(DS.Palette.accentSecondary)
                            Text("Ideas").font(DS.Font.sectionHeader)
                            Spacer()
                            Text("\(shown.count)").font(DS.Font.badge).foregroundStyle(DS.Palette.textTertiary).contentTransition(.numericText())
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Someday, \(shown.count) \(shown.count == 1 ? "task" : "tasks")")
                    }
                }
                .environment(\.taskRowScope, .all)
                .accessibilityIdentifier("somedayList")
                .listStyle(.inset).scrollContentBackground(.hidden)
                .frame(maxWidth: DS.Size.contentMaxWidth).frame(maxWidth: .infinity)
                .contextMenu(forSelectionType: String.self) { ids in menu(ids) } primaryAction: { ids in if let id = ids.first, ids.count == 1 { workspace.open(id) } }
                .onDeleteCommand { workspace.delete(workspace.selection) }
                .animation(layout, value: shown.map(\.id))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom) { if let confirmation = workspace.confirmation { ConfirmationBar(confirmation: confirmation) } }
        .animation(Transitions.Ease.smoothOut, value: workspace.confirmation)
        .animation(layout, value: prompt)
        .onAppear { if workspace.section == .someday { workspace.navigationSubtitle = subtitle } }
        .onChange(of: subtitle) { _, value in if workspace.section == .someday { workspace.navigationSubtitle = value } }
        .onChange(of: workspace.searchPresented) { _, requested in if requested && workspace.section == .someday { ideaFocused = false; workspace.searchPresented = false } }
        .sheet(isPresented: $picking) {
            DatePickSheet(date: $pickerDate, count: workspace.selection.count, verb: "Schedule") {
                workspace.scheduleFromSomeday(workspace.selection, to: Dates.day(pickerDate), label: pickerDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            }
        }
        .accessibilityIdentifier("somedayView")
    }

    private func reviewCard(_ prompt: Planning.Review) -> some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: "moon.zzz").font(.title3).foregroundStyle(DS.Palette.accentSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Review Someday").font(DS.Font.sectionHeader)
                Text(reviewing ? "Schedule what’s ready, delete what isn’t. Nothing is urgent." : prompt.message + " A quick look can keep the list light.")
                    .font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            if reviewing {
                Button("Done reviewing") { snooze() }.buttonStyle(.borderedProminent).accessibilityIdentifier("somedayReviewDone")
            } else {
                Button("Not now") { snooze() }.buttonStyle(.borderless).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("somedayReviewSnooze")
                Button("Review") { withAnimation(layout) { reviewing = true } }.buttonStyle(.borderedProminent).accessibilityIdentifier("somedayReviewStart")
            }
        }
        .padding(DS.Space.m)
        .background(DS.Palette.accentSecondary.opacity(0.10), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.accentSecondary.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("somedayReviewCard")
    }

    private var empty: some View {
        ContentUnavailableView {
            Label { Text("Someday is empty") } icon: { Image(systemName: "moon.zzz").foregroundStyle(DS.Palette.accentSecondary.opacity(0.75)) }
        } description: { Text("Park ideas here until they’re ready.") }
        .modifier(EmptyStateAppear()).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("emptyState")
    }

    @ViewBuilder private func menu(_ ids: Set<String>) -> some View {
        let targets = ids.isEmpty ? workspace.selection : ids
        let tasks = targets.compactMap { workspace.taskRecord($0) }
        if tasks.isEmpty { Button("New Idea") { ideaFocused = true } } else {
            if tasks.count == 1, let task = tasks.first { Button("Edit “\(task.title)”") { workspace.open(task.id) } }
            Button(tasks.allSatisfy(\.completed) ? "Reopen" : "Complete") { workspace.toggle(targets) }.disabled(!tasks.allSatisfy(TaskKind.mayComplete))
            Divider()
            Menu("Schedule") {
                Button("Today", systemImage: "sun.max") { schedule(targets, offset: 0, label: "today") }
                Button("Tomorrow", systemImage: "sunrise") { schedule(targets, offset: 1, label: "tomorrow") }
                Button("Next Week", systemImage: "calendar.badge.clock") { if let day = store.datePhraseDay("next week") { workspace.scheduleFromSomeday(targets, to: Dates.day(day), label: "next week") } }.disabled(store.datePhrasePreferences == nil)
                Button("Pick a Date…", systemImage: "calendar") { workspace.selection = targets; pickerDate = Date(); picking = true }
            }
            .accessibilityIdentifier("somedaySchedule")
            Menu("Move to") {
                Button("Inbox", systemImage: "tray") { workspace.move(targets, toProject: "") }
                ForEach(store.projects) { project in Button(project.name, systemImage: "folder") { workspace.move(targets, toProject: project.id) } }
            }
            Menu("Priority") { ForEach(1...4, id: \.self) { n in Button(n == 4 ? "None" : "Priority \(n)", systemImage: "flag") { workspace.setPriority(targets, n) } } }
            Divider()
            Button(tasks.count == 1 ? "Delete" : "Delete \(tasks.count) Tasks", systemImage: "trash", role: .destructive) { workspace.delete(targets) }
        }
    }

    private func schedule(_ ids: Set<String>, offset: Int, label: String) {
        guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { return }
        workspace.scheduleFromSomeday(ids, to: Dates.day(date), label: label)
    }
    private func schedule(_ ids: [String], offset: Int, label: String) { schedule(Set(ids), offset: offset, label: label) }
    private func snooze() { withAnimation(layout) { lastReview = Date().timeIntervalSince1970; reviewing = false } }
    private func addIdea() {
        let text = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if workspace.add(text, project: "", date: nil, scope: .inbox, planning: .someday) != nil { idea = "" }
    }
}
