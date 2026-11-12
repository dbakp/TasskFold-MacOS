import SwiftUI
import AppKit

/// Habits: a calm card per tracked series, below Someday in the sidebar. A check-in is the ordinary task completion
/// (same Store path, the recurrence advances, Undo works). Space checks in the selected habit.
struct HabitsView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: String?
    @State private var detail: String?
    @FocusState private var focused: Bool

    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }

    var body: some View {
        let readings = store.habitReadings()
        let calendar = store.habitCalendar
        VStack(spacing: 0) {
            if let id = detail, let reading = readings.first(where: { $0.habitID == id }) {
                detailView(reading, calendar: calendar)
            } else if readings.isEmpty {
                HabitsEmptyState()
            } else {
                list(readings, calendar: calendar)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom) { if let confirmation = workspace.confirmation { ConfirmationBar(confirmation: confirmation) } }
        .animation(Transitions.Ease.smoothOut, value: workspace.confirmation)
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--habit-detail"), detail == nil { detail = readings.first?.habitID }
            #endif
            if workspace.section == .habits { workspace.navigationSubtitle = subtitle(readings.count); focused = true; if selected == nil { selected = readings.first?.habitID } }
        }
        .onChange(of: readings.count) { _, count in if workspace.section == .habits { workspace.navigationSubtitle = subtitle(count) } }
        .onChange(of: detail) { _, _ in focused = true }
        .accessibilityIdentifier("habitsView")
    }
    private func subtitle(_ count: Int) -> String { count == 1 ? "1 habit" : "\(count) habits" }

    private func list(_ readings: [HabitReading], calendar: Calendar) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DS.Space.m) {
                    ForEach(readings) { reading in
                        HabitCard(reading: reading, calendar: calendar, selected: selected == reading.habitID,
                                  checkIn: { selected = reading.habitID; checkIn(reading) }, open: { selected = reading.habitID; withAnimation(layout) { detail = reading.habitID } })
                            .id(reading.habitID)
                            .contextMenu { menu(reading, readings: readings) }
                    }
                }
                .frame(maxWidth: 680).frame(maxWidth: .infinity).padding(DS.Space.xl)
            }
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.space) { guard let id = selected, let reading = readings.first(where: { $0.habitID == id }) else { return .ignored }; checkIn(reading); return .handled }
            .onKeyPress(.return) { guard let id = selected else { return .ignored }; withAnimation(layout) { detail = id }; return .handled }
            .onKeyPress(.downArrow) { move(1, in: readings, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: readings, proxy: proxy); return .handled }
            .accessibilityIdentifier("habitList")
        }
    }
    private func move(_ delta: Int, in readings: [HabitReading], proxy: ScrollViewProxy) {
        guard !readings.isEmpty else { return }
        let index = readings.firstIndex { $0.habitID == selected } ?? (delta > 0 ? -1 : readings.count)
        let next = readings[min(max(index + delta, 0), readings.count - 1)].habitID
        selected = next; withAnimation(layout) { proxy.scrollTo(next) }
    }

    private func detailView(_ reading: HabitReading, calendar: Calendar) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Button { withAnimation(layout) { detail = nil } } label: { Label("Habits", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(.escape, modifiers: []).accessibilityIdentifier("habitBack")
                HabitDetailContent(reading: reading, calendar: calendar, checkIn: { checkIn(reading) },
                                   openTask: reading.occurrenceID.map { id in { workspace.open(id) } },
                                   stopTracking: { stop(reading) })
            }
            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity).padding(DS.Space.xl)
        }
        .accessibilityIdentifier("habitDetail")
    }

    @ViewBuilder private func menu(_ reading: HabitReading, readings: [HabitReading]) -> some View {
        Button("Check In", systemImage: "checkmark.circle") { checkIn(reading) }.disabled(!reading.canCheckIn)
        Button("Show History", systemImage: "chart.bar.xaxis") { withAnimation(layout) { detail = reading.habitID } }
        if let id = reading.occurrenceID { Button("Open Task", systemImage: "arrow.up.forward.square") { workspace.open(id) } }
        if let index = readings.firstIndex(where: { $0.habitID == reading.habitID }) {
            Divider()
            Button("Move Up", systemImage: "arrow.up") { reorder(readings, from: index, by: -1) }.disabled(index == 0)
            Button("Move Down", systemImage: "arrow.down") { reorder(readings, from: index, by: 1) }.disabled(index == readings.count - 1)
        }
        Divider()
        Button("Stop Tracking", systemImage: "minus.circle", role: .destructive) { stop(reading) }
    }

    private func checkIn(_ reading: HabitReading) {
        guard reading.canCheckIn, let task = store.habitOccurrence(reading.habitID) else { return }
        workspace.complete(task)
    }
    private func stop(_ reading: HabitReading) {
        guard let task = store.habitOccurrence(reading.habitID) ?? store.tasks.first(where: { Habits.root(of: $0) == reading.habitID }) else { return }
        workspace.run("Stop Tracking Habit") { _ = store.setHabit(task, tracked: false) }
        if detail == reading.habitID { detail = nil }
    }
    private func reorder(_ readings: [HabitReading], from index: Int, by delta: Int) {
        var ids = readings.map(\.habitID); ids.move(fromOffsets: IndexSet(integer: index), toOffset: delta > 0 ? index + 2 : index - 1)
        workspace.run("Reorder Habits") { _ = store.moveHabits(ids) }
    }
}
