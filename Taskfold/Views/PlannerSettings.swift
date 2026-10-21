import SwiftUI

struct PlannerSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let busy: CalendarBusyStore
    @State private var start = 540
    @State private var end = 1020
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var loaded = false
    @State private var workspace: WorkspaceBinding?
    private var editable: Bool { store.workingHoursEditable && workspace?.matches(account: store.userID, generation: store.workspaceGeneration) == true }
    @State private var connecting = false
    private func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Working hours") {
                    if !WorkingHours.editable(store.workingHoursDocument) {
                        Text("These working hours are unsupported. Update Taskfold before changing them.")
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("workingHoursUnsupported")
                    } else {
                        Picker("Start", selection: $start) { ForEach(Array(Set(stride(from: 0, to: 1440, by: 15)).union([start])).sorted(), id: \.self) { Text(time($0)).tag($0) } }
                        Picker("End", selection: $end) { ForEach(Array(Set(stride(from: 15, through: 1440, by: 15)).union([end])).sorted(), id: \.self) { Text(time($0)).tag($0) } }
                        ForEach(1...7, id: \.self) { weekday in
                            Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: Binding(get: { weekdays.contains(weekday) }, set: { if $0 { weekdays.insert(weekday) } else { weekdays.remove(weekday) } }))
                        }
                        Text("Working hours sync across devices and use each device’s local clock. Estimates are workload, including all-day tasks; overlapping tasks still count separately.").font(.caption).foregroundStyle(.secondary)
                        if start >= end { Text("End must be later than start.").foregroundStyle(.red) }
                    }
                }
                .disabled(!editable)
                Section("Device calendars") {
                    Text(busy.deviceStatus).foregroundStyle(.secondary)
                    Text("Taskfold only reads the calendars you select here. Calendar choices apply immediately and stay on this device; connect calendars separately on your other devices.").font(.caption).foregroundStyle(.secondary)
                    if busy.connected {
                        ForEach(busy.calendars) { calendar in
                            Toggle(isOn: Binding(get: { busy.selected.contains(calendar.id) }, set: { value in var ids = busy.selected; if value { ids.insert(calendar.id) } else { ids.remove(calendar.id) }; busy.select(ids) })) {
                                VStack(alignment: .leading) { Text(calendar.title); Text(calendar.source).font(.caption).foregroundStyle(.secondary) }
                            }
                            .accessibilityLabel(Text("\(calendar.title), \(calendar.source)"))
                        }
                        if !busy.selected.isSubset(of: Set(busy.calendars.map(\.id))) {
                            Button("Remove unavailable calendar selections") { busy.select(busy.selected.intersection(busy.calendars.map(\.id))) }
                        }
                        Button("Disconnect device calendars", role: .destructive) { busy.disconnect() }.accessibilityIdentifier("plannerDisconnectCalendars")
                    } else {
                        Button(connecting ? "Connecting…" : "Connect device calendars") {
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
                if let links=busy.links,!links.configured.isEmpty || links.active {
                    LinkedCalendarSettingsSection(links:links)
                }
                if busy.anyConnected {
                    Section("Event privacy") {
                        Toggle("Show event titles",isOn:Binding(get:{busy.showTitles},set:{busy.setTitles($0)}))
                            .accessibilityIdentifier("plannerShowEventTitles")
                        Text("Titles are hidden as “Busy” by default. Private events stay private. Calendar events are read only and are never copied into tasks. Select each calendar once across your connections.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
            .accessibilityIdentifier("plannerSettingsForm")
            .formStyle(.grouped)
            #if os(macOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Planner settings").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 24).padding(.vertical, 16)
                    Divider()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            #else
            .navigationTitle("Planner settings")
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    if let workspace, store.setWorkingHours(WorkingHours(start: start, end: end, weekdays: weekdays), workspace: workspace) { dismiss() }
                }.disabled(start >= end || !editable).accessibilityIdentifier("plannerSaveSettings") }
            }
            .onAppear { guard !loaded else { return }; loaded = true; workspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); let hours = store.workingHours ?? WorkingHours(); start = hours.start; end = hours.end; weekdays = hours.weekdays }
        }
        .onChange(of:store.workspaceGeneration) { _,_ in dismiss() }
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

/// Direct providers have their own consent and account identity, independently of EventKit.
private struct LinkedCalendarSettingsSection:View {
    @Environment(\.dynamicTypeSize) private var textSize
    let links:CalendarLinksStore
    private var actionLayout:AnyLayout {textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment:.leading,spacing:12)):AnyLayout(HStackLayout())}
    private var replacing:Binding<Bool> {Binding(get:{links.replacement != nil},set:{if !$0 {links.cancelReplacement()}})}
    var body:some View {
        Section {
            Text("Read busy time directly from your account. Calendar choices apply immediately and stay in this Taskfold workspace on this device. Disconnect removes this device’s connection; manage global consent with your calendar provider.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if links.restoring {ProgressView("Restoring calendar connections…")}
            ForEach(CalendarService.allCases) { service in
                if links.configured.contains(service) || links.links[service] != nil || links.restorationFailures.contains(service) {
                    VStack(alignment:.leading,spacing:12) {
                        Label(service.title,systemImage:"calendar").font(.headline)
                        if let profile=links.links[service] {
                            Text(profile.identity.label).font(.subheadline).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                            if profile.needsReconnect {
                                Label("Reconnect to refresh busy time",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(profile.calendars) { calendar in
                                    Toggle(calendar.title,isOn:Binding(get:{links.links[service]?.selected.contains(calendar.remoteID)==true},set:{links.select(service,id:calendar.remoteID,enabled:$0)}))
                                        .accessibilityLabel("\(calendar.title), \(service.title)")
                                        .accessibilityIdentifier("calendarChoice-"+calendar.id).frame(minHeight:44)
                                }
                                if profile.calendars.isEmpty {Text("Refresh to choose calendars.").font(.caption).foregroundStyle(.secondary)}
                                else if profile.selected.isEmpty {Text("Choose at least one calendar to include its busy time.").font(.caption).foregroundStyle(.secondary)}
                                if !profile.selected.isSubset(of:Set(profile.calendars.map(\.remoteID))) {
                                    Button("Remove unavailable selections") {links.removeUnavailable(service)}
                                }
                            }
                            if let notice=profile.notice {Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                            if !profile.needsReconnect {Button(links.refreshing.contains(service) ? "Refreshing…":"Refresh calendars") {Task {await links.refreshCalendars(service)}}.disabled(links.disconnecting.contains(service) || links.refreshing.contains(service)).accessibilityIdentifier("calendarRefresh-"+service.rawValue).frame(minHeight:44)}
                        } else if links.restorationFailures.contains(service) {
                            Text("This connection could not be restored. Reconnect, or remove it from this device.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        if links.connecting==service {
                            VStack(alignment:.leading,spacing:12) {HStack {ProgressView();Text("Connecting…")};Button("Cancel") {links.cancelConnection()}.frame(minHeight:44)}
                        } else {
                            actionLayout {
                                Button(links.links[service] == nil && !links.restorationFailures.contains(service) ? "Connect":"Reconnect") {Task {await links.connect(service)}}
                                    .disabled(!links.configured.contains(service) || links.connecting != nil || links.restoring || links.disconnecting.contains(service) || links.replacement != nil)
                                    .accessibilityLabel("\(links.links[service] == nil && !links.restorationFailures.contains(service) ? "Connect":"Reconnect") \(service.title)")
                                    .accessibilityIdentifier("calendarConnect-"+service.rawValue).frame(minHeight:44)
                                if links.links[service] != nil || links.restorationFailures.contains(service) {
                                    if !textSize.isAccessibilitySize {Spacer()}
                                    Button(links.disconnecting.contains(service) ? "Disconnecting…":"Disconnect",role:.destructive) {Task {await links.disconnect(service)}}
                                        .disabled(links.disconnecting.contains(service)).accessibilityLabel("Disconnect \(service.title)")
                                        .accessibilityIdentifier("calendarDisconnect-"+service.rawValue).frame(minHeight:44)
                                }
                            }
                        }
                    }
                    .padding(.vertical,8)
                    .buttonStyle(.borderless)
                    .accessibilityElement(children:.contain)
                }
            }
        } header:{Text("Connected accounts")}
        .confirmationDialog("Use a different calendar account?",isPresented:replacing,titleVisibility:.visible) {
            Button("Use this account") {Task {await links.confirmReplacement()}}
            Button("Keep current account",role:.cancel) {links.cancelReplacement()}
        } message:{Text("Replace this device’s connection with \(links.replacement?.catalog.accountLabel ?? "the selected account")? You’ll choose its calendars again. Your Taskfold tasks and the earlier calendar account stay unchanged.")}
        .alert("Calendar connection",isPresented:Binding(get:{links.message != nil},set:{if !$0 {links.clearMessage()}})) {
            Button("OK") {links.clearMessage()}
        } message:{Text(links.message ?? "")}
    }
}
