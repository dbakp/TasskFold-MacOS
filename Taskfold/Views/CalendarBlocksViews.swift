import SwiftUI
import EventKit
import Combine

/// Settings for the opt-in "Show time blocks in Calendar". Identical in the iOS and Mac repositories.
struct CalendarBlocksSettingsSection: View {
    @State private var controller = CalendarBlocksController.shared
    @State private var confirmingOff = false
    @State private var asking = false
    private var chosen: Binding<String> {
        Binding(get: { controller.chosenCalendarID ?? "" }, set: { value in Task { await controller.chooseCalendar(value.isEmpty ? nil : value) } })
    }
    var body: some View {
        Section("Time blocks in Calendar") {
            Toggle("Show time blocks in Calendar", isOn: Binding(get: { controller.active || asking }, set: { value in
                if value { asking = true; Task { await controller.enable(); asking = false } } else { confirmingOff = true }
            }))
            .disabled(controller.account.isEmpty)
            .accessibilityIdentifier("calendarBlocksToggle")
            Text("Off by default. When on, each task you have planned with a start time and a duration is added as an event to a calendar named “Taskfold” (or another calendar you choose) for today and the next 13 days, so it shows in your other calendar apps and devices. The event title is the task title; task notes are never copied. Events sync like any event in that calendar, through its account (iCloud, Google or Exchange). Taskfold asks for full calendar access when you switch this on, because it reads back its own events to update and remove them, and it changes only events it created. Use the same Taskfold account on every device.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.active {
                Picker("Calendar", selection: chosen) {
                    Text("Taskfold (created for you)").tag("")
                    ForEach(controller.calendars) { calendar in Text("\(calendar.title), \(calendar.source)").tag(calendar.id) }
                }
                .accessibilityIdentifier("calendarBlocksCalendar")
                Text(controller.busy ? "Updating Calendar…" : controller.lastSynced.map { "Last updated " + $0.formatted(date: .omitted, time: .shortened) + " in “\(controller.calendarName)”." } ?? "Waiting for the first update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.status.isEmpty {
                Text(controller.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendarBlocksStatus")
            }
        }
        .task { await controller.refreshCalendars() }
        .confirmationDialog("Remove Taskfold events from Calendar?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Remove events", role: .destructive) { Task { await controller.disable(removeEvents: true) } }
            Button("Keep events") { Task { await controller.disable(removeEvents: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Time blocks stop updating either way. Removing deletes only the events Taskfold created.")
        }
    }
}

/// Keeps the calendar in step with the plan while the app is active. Does nothing unless the user turned it on.
struct CalendarBlocksSync: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var controller = CalendarBlocksController.shared
    private var account: String { store.signedIn || store.localMode ? store.userID : "" }
    private func run() async {
        guard phase == .active, !account.isEmpty, controller.active else { return }
        await controller.sync(tasks: store.tasks)
    }
    func body(content: Content) -> some View {
        content
            .task(id: account) { controller.bind(account: account) }
            .task(id: "blocks-\(account)-\(store.workspaceGeneration)-\(store.taskRevision)-\(controller.active)-\(phase == .active)") {
                guard controller.active else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await run()
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).debounce(for: .seconds(3), scheduler: DispatchQueue.main)) { _ in Task { await run() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in Task { await run() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in Task { await run() } }
    }
}
