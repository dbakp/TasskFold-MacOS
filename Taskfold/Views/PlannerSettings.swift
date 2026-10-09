import SwiftUI

struct PlannerSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let busy: CalendarBusyStore
    @State private var start = 540
    @State private var end = 1020
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var loaded = false
    @State private var connecting = false
    private func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Working hours") {
                    Picker("Start", selection: $start) { ForEach(Array(Set(stride(from: 0, to: 1440, by: 15)).union([start])).sorted(), id: \.self) { Text(time($0)).tag($0) } }
                    Picker("End", selection: $end) { ForEach(Array(Set(stride(from: 15, through: 1440, by: 15)).union([end])).sorted(), id: \.self) { Text(time($0)).tag($0) } }
                    ForEach(1...7, id: \.self) { weekday in
                        Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: Binding(get: { weekdays.contains(weekday) }, set: { if $0 { weekdays.insert(weekday) } else { weekdays.remove(weekday) } }))
                    }
                    Text("Working hours sync across devices and use each device’s local clock. Estimates are workload, including all-day tasks; overlapping tasks still count separately.").font(.caption).foregroundStyle(.secondary)
                    if start >= end { Text("End must be later than start.").foregroundStyle(.red) }
                }
                Section("Calendar busy time") {
                    Text(busy.status).foregroundStyle(.secondary)
                    Text("Taskfold only reads the calendars you select here. Calendar choices apply immediately and stay on this device; connect calendars separately on your other devices.").font(.caption).foregroundStyle(.secondary)
                    if busy.connected {
                        ForEach(busy.calendars) { calendar in
                            Toggle(isOn: Binding(get: { busy.selected.contains(calendar.id) }, set: { value in var ids = busy.selected; if value { ids.insert(calendar.id) } else { ids.remove(calendar.id) }; busy.select(ids) })) {
                                VStack(alignment: .leading) { Text(calendar.title); Text(calendar.source).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if !busy.selected.isSubset(of: Set(busy.calendars.map(\.id))) {
                            Button("Remove unavailable calendar selections") { busy.select(busy.selected.intersection(busy.calendars.map(\.id))) }
                        }
                        Toggle("Show event titles", isOn: Binding(get: { busy.showTitles }, set: { busy.setTitles($0) }))
                        Text("Titles are hidden as “Busy” by default. Free and declined events do not count. Events without an availability setting are treated as busy.").font(.caption).foregroundStyle(.secondary)
                        Button("Disconnect calendars", role: .destructive) { busy.disconnect() }.accessibilityIdentifier("plannerDisconnectCalendars")
                    } else {
                        Button(connecting ? "Connecting…" : "Connect calendars") {
                            connecting = true
                            Task { await busy.connect(); connecting = false }
                        }.disabled(connecting).accessibilityIdentifier("plannerConnectCalendars")
                    }
                    #if os(iOS)
                    Text("In Settings, open Apps → Taskfold → Calendars and allow Full Access. Then return here and connect again.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings", systemImage: "arrow.up.right.square") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .frame(minHeight: 44).accessibilityIdentifier("plannerSystemSettings")
                    .accessibilityHint("Manage Taskfold's calendar permission in Settings")
                    #elseif os(macOS)
                    Text("In System Settings, open Privacy & Security → Calendars and allow Taskfold access. Then return here and connect again.").font(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings…", systemImage: "arrow.up.right.square") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") { NSWorkspace.shared.open(url) }
                    }
                    .frame(minHeight: 44).accessibilityIdentifier("plannerSystemSettings")
                    .accessibilityHint("Manage calendar access under Privacy and Security, Calendars")
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Planner settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    if store.setWorkingHours(WorkingHours(start: start, end: end, weekdays: weekdays)) { dismiss() }
                }.disabled(start >= end).accessibilityIdentifier("plannerSaveSettings") }
            }
            .onAppear { guard !loaded else { return }; loaded = true; let hours = store.workingHours; start = hours.start; end = hours.end; weekdays = hours.weekdays }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
    }
}

/// Immediate account-owned date choices, separate from device calendar permissions.
struct DatePhrasePreferencesView: View {
    @Environment(Store.self) private var store
    @State private var workspace: WorkspaceBinding?
    private func selection(_ field: String) -> Binding<Int> {
        Binding(get: { field == "next_week" ? store.datePhrasePreferences?.nextWeek ?? 2 : store.datePhrasePreferences?.weekend ?? 7 }, set: { day in
            guard let workspace else { return }
            _ = store.setDatePhraseWeekday(day, field: field, workspace: workspace)
        })
    }
    private var editable: Bool { store.datePhraseEditable && workspace?.matches(account: store.userID, generation: store.workspaceGeneration) == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.datePhrasePreferences != nil {
                Picker("Next week means", selection: selection("next_week")) {
                    ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                }.accessibilityIdentifier("datePhraseNextWeek").disabled(!editable)
                Picker("Weekend starts", selection: selection("weekend")) {
                    ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                }.accessibilityIdentifier("datePhraseWeekend").disabled(!editable)
            } else {
                Text("These date preferences are unsupported. Update Taskfold before changing them.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Next week chooses the next future occurrence. This weekend includes today if it is your chosen day; next weekend skips one occurrence. These choices apply to quick entry, rescheduling and relative filters. Existing task dates stay fixed.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(store.localMode ? "Saved in this local workspace." : "Saved to your account and synced across devices.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if workspace == nil { workspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) } }
    }
}
