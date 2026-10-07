import SwiftUI

struct TaskReminderEditor: View {
    @Environment(Store.self) private var store
    @Binding var task: Record
    @State private var editing: ReminderDraft?
    @State private var message: String?
    private var rows: [JSON] { ReminderSpec.rows(task) }
    private var plannedEditable: Bool {
        guard let row = rows.first(where: { $0.object["id"]?.text.lowercased() == ReminderSpec.plannedID }) else { return rows.count < ReminderSpec.maximum }
        return ReminderSpec(row: row)?.locallyEditable == true
    }
    var body: some View {
        Form {
            Section {
                Toggle("At planned time", isOn: Binding(get: { ReminderSpec.plannedEnabled(task) }, set: { if !ReminderSpec.setPlanned($0, task: &task) { message = "Another reminder is already enabled at planned time. Turn it off or delete it first." } }))
                    .disabled(!plannedEditable).accessibilityIdentifier("reminderPlanned")
            } footer: {
                Text(task.due == nil ? "Choose a planned date to activate reminders relative to the task. Fixed-date and repeating reminders work without one." : task.string("due_time").isEmpty ? "With a date but no time, the planned reminder is at 8:00 AM." : "Before and after reminders move with the task’s planned time.")
            }
            Section("Custom reminders") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, value in
                    if let spec = ReminderSpec(row: value), spec.id != ReminderSpec.plannedID {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button { editing = ReminderDraft(spec: spec, index: index) } label: {
                                    Label { Text(spec.label).multilineTextAlignment(.leading).lineLimit(nil).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: spec.kind == "absolute" ? "calendar.badge.clock" : "bell") }
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.borderless).disabled(!spec.locallyEditable)
                                    .accessibilityIdentifier("reminderEdit-\(index)")
                                Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                                    .buttonStyle(.borderless).accessibilityLabel("Delete " + spec.label).accessibilityIdentifier("reminderDelete-\(index)")
                            }
                            Text(status(spec)).font(.footnote).foregroundStyle(.secondary)
                            if !spec.locallyEditable { Text("This reminder uses another delivery channel. Its settings are preserved; this app delivers only local notifications.").font(.footnote).foregroundStyle(.secondary) }
                        }
                    } else if ReminderSpec(row: value) == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Unsupported reminder", systemImage: "lock.shield")
                            Text("Its original settings are preserved when you save this task.").font(.footnote).foregroundStyle(.secondary)
                            Button("Delete unsupported reminder", role: .destructive) { remove(index) }.frame(minHeight: 44)
                        }
                    }
                }
                Button { editing = ReminderDraft(spec: .relative(-10), index: nil) } label: { Label("Add reminder", systemImage: "plus.circle").frame(minHeight: 44) }
                    .disabled(rows.count >= ReminderSpec.maximum).accessibilityIdentifier("reminderAdd")
                if rows.count >= ReminderSpec.maximum { Text("This task has the maximum of 20 reminder settings.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Toggle("Deliver reminders", isOn: Binding(get: { store.remindersEnabled }, set: { value in
                    if value { Task { await store.enableNotifications() } } else { store.disableNotifications() }
                })).disabled(store.requestingNotifications || store.requestingFocusAlerts).accessibilityIdentifier("reminderDelivery")
                if store.requestingNotifications { ProgressView("Requesting permission…") }
                Text(store.reminderStatus).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("reminderStatus")
                ReminderSystemSettingsButton()
                RemoteReminderRegistrationView()
            } header: { Text("This device") } footer: {
                Text("Reminder choices sync with the task. Enable delivery separately on each device. Up to 60 notifications are scheduled, including one enabled Focus finish alert. Later reminders refresh while Taskfold is open.")
            }
            Section {
                #if os(macOS)
                Text("Changes save automatically with this task.").font(.footnote).foregroundStyle(.secondary)
                #else
                Text("Save the task to keep your reminder changes. Cancel the task editor to discard them.").font(.footnote).foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped).navigationTitle("Reminders")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await store.reschedule() }
        .alert("Reminder not changed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .sheet(item: $editing) { draft in
            ReminderSpecEditor(draft: draft) { spec in
                let current = rows.isEmpty ? [.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID).raw)] : rows
                if ReminderSpec.duplicates(spec, in: current, excluding: draft.index == nil ? nil : spec.id) { return "A reminder is already enabled for this time. Choose another time or turn the existing reminder off." }
                if let index = draft.index, rows.indices.contains(index), rows[index].object["id"]?.text.lowercased() == spec.id {
                    var values = rows; values[index] = .object(spec.raw); task["reminder_specs"] = .array(values)
                } else if draft.index == nil {
                    guard ReminderSpec.append(spec, task: &task) else { return "This task has reached its reminder limit. Delete a reminder before adding another." }
                } else { return "This reminder changed. Cancel and reopen it to refresh the settings." }
                return nil
            }
        }
    }
    private func remove(_ index: Int) {
        var values = rows; values.remove(at: index)
        if values.isEmpty { values = [.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID, enabled: false).raw)] }
        task["reminder_specs"] = .array(values)
    }
    private func status(_ spec: ReminderSpec) -> String {
        if !spec.enabled { return "Off" }
        guard let date = spec.date(task: task, calendar: .current) else { return spec.kind == "recurring" ? "This schedule has ended" : "Waiting for a planned date" }
        if date <= Date() { return "This reminder time has passed" }
        let time = date.formatted(date: .abbreviated, time: .shortened)
        if let schedule = spec.schedule { return "Next · \(schedule.formatted(date)) · \(schedule.timeZone)" }
        return spec.kind == "absolute" ? "Fixed instant · \(time) · shown in your current time zone" : "Next · \(time)"
    }
}

struct ReminderDraft: Identifiable {
    var spec: ReminderSpec
    var index: Int?
    var id: String { spec.id }
}
struct ReminderSpecEditor: View {
    @Environment(\.dismiss) private var dismiss
    let draft: ReminderDraft
    let save: (ReminderSpec) -> String?
    @State private var kind: String
    @State private var minutes: Int
    @State private var before: Bool
    @State private var date: Date
    @State private var enabled: Bool
    @State private var repeatClock: Date
    @State private var repeatText: String
    @FocusState private var repeatFocused: Bool
    @State private var sourceZone: String
    @State private var message: String?
    init(draft: ReminderDraft, save: @escaping (ReminderSpec) -> String?) {
        self.draft = draft; self.save = save
        _kind = State(initialValue: draft.spec.kind)
        _minutes = State(initialValue: abs(draft.spec.offset ?? -10))
        _before = State(initialValue: (draft.spec.offset ?? -10) <= 0)
        _date = State(initialValue: draft.spec.schedule.flatMap { Dates.parse($0.startDay, calendar: $0.calendar) } ?? draft.spec.absolute ?? Date().addingTimeInterval(3600))
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let source = draft.spec.schedule?.calendar ?? Calendar.current
        let initial = draft.spec.absolute ?? Date().addingTimeInterval(3600)
        let hour = draft.spec.schedule.flatMap { Int($0.time.prefix(2)) } ?? source.component(.hour, from: initial)
        let minute = draft.spec.schedule.flatMap { Int($0.time.suffix(2)) } ?? source.component(.minute, from: initial)
        _repeatClock = State(initialValue: utc.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute))!)
        _repeatText = State(initialValue: draft.spec.schedule?.expression ?? "every week")
        _sourceZone = State(initialValue: draft.spec.schedule?.timeZone ?? TimeZone.current.identifier)
        _enabled = State(initialValue: draft.spec.enabled)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("When", selection: $kind) { Text("From plan").tag("relative"); Text("Fixed time").tag("absolute"); Text("Repeats").tag("recurring") }
                        .accessibilityIdentifier("reminderKind")
                    Toggle("Enabled", isOn: $enabled).accessibilityIdentifier("reminderEnabled")
                }
                if kind == "relative" {
                    Section {
                        Picker("Direction", selection: $before) { Text("Before").tag(true); Text("After").tag(false) }.pickerStyle(.segmented)
                        Picker("Offset", selection: $minutes) {
                            ForEach(Array(Set([0, 5, 10, 15, 30, 60, 120, 1440, 10080, minutes])).sorted(), id: \.self) { value in
                                Text(value == 0 ? "At planned time" : value < 60 ? "\(value) minutes" : value % 1440 == 0 ? "\(value / 1440) day(s)" : value % 60 == 0 ? "\(value / 60) hour(s)" : "\(value) minutes").tag(value)
                            }
                        }.accessibilityIdentifier("reminderOffset")
                        Stepper("\(minutes) minutes", value: $minutes, in: 0...10080).accessibilityIdentifier("reminderMinutes")
                    } footer: { Text("Uses elapsed minutes before or after the task’s planned time. A date without a time uses 8:00 AM.") }
                } else if kind == "recurring" {
                    Section {
                        DatePicker("Starts", selection: $date, displayedComponents: [.date])
                            .environment(\.timeZone, TimeZone(identifier: sourceZone) ?? .current).accessibilityIdentifier("reminderRepeatStart")
                        DatePicker("At", selection: $repeatClock, displayedComponents: [.hourAndMinute])
                            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!).accessibilityIdentifier("reminderRepeatTime")
                        HStack {
                            TextField("Repeat rule", text: $repeatText, prompt: Text("every Saturday"))
                                .focused($repeatFocused).onSubmit { repeatFocused = false }.submitLabel(.done)
                                .accessibilityIdentifier("reminderRepeatRule")
                            if !repeatText.isEmpty {
                                Button { repeatText = ""; repeatFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44) }
                                    .buttonStyle(.borderless).accessibilityLabel("Clear repeat rule").accessibilityIdentifier("clearReminderRepeatRule")
                            }
                        }
                        Menu("Repeat suggestions") {
                            ForEach(["every day", "every weekdays", "every saturday", "every month on last friday", "every year on january 1"], id: \.self) { phrase in
                                Button(phrase.capitalized) { repeatText = phrase }
                            }
                        }.frame(minHeight: 44).accessibilityIdentifier("reminderRepeatSuggestions")
                        Text(sourceZone).font(.footnote).foregroundStyle(.secondary)
                        if sourceZone != TimeZone.current.identifier {
                            Button("Use current time zone") {
                                let c = recurringCalendar
                                let parts = c.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                                sourceZone = TimeZone.current.identifier
                                if let moved = recurringCalendar.date(from: parts) { date = moved }
                            }.frame(minHeight: 44)
                        }
                        if let schedule = recurringSchedule, let next = schedule.dates(after: Date(), limit: 1).first {
                            Text(schedule.summary).font(.footnote).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("reminderRepeatSummary")
                            Text("Next · " + schedule.formatted(next) + " · " + schedule.timeZone)
                                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("reminderRepeatPreview")
                        } else if recurringSchedule != nil && !enabled {
                            Text("This schedule has ended. Its settings will be saved with delivery off.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Enter a calendar rule with a future occurrence. Try every Saturday, every 2 weeks on Monday and Friday, or every month on last Friday. Add until YYYY-MM-DD or for 5 occurrences if needed.")
                                .font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("reminderRepeatError")
                        }
                    } header: { Text("Schedule") } footer: {
                        Text("Repeats at this clock time in its time zone, independently of the task’s plan. The task must remain open. Completing the task cancels its remaining alerts. Completion-based rules (every!) belong to the task’s repeat setting.")
                    }
                } else {
                    Section {
                        DatePicker("Remind me", selection: $date, displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("reminderDate")
                        Text("\(TimeZone.current.identifier). This reminder stays at the same instant when the task moves or you travel.").font(.footnote).foregroundStyle(.secondary)
                        if enabled && date <= Date() { Text("Choose a future time, or turn this reminder off.").foregroundStyle(.red) }
                    }
                }
            }.formStyle(.grouped).accessibilityIdentifier("reminderSpecForm").navigationTitle(draft.index == nil ? "Add reminder" : "Edit reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply() }.disabled((kind == "absolute" && enabled && date <= Date()) || (kind == "recurring" && (recurringSchedule == nil || (enabled && recurringSchedule?.dates(after: Date(), limit: 1).isEmpty == true)))).accessibilityIdentifier("reminderSave") }
            }
        }
        .alert("Reminder not saved", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 530)
        #endif
    }
    private var recurringCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: sourceZone) ?? .current; return c
    }
    private var recurringSchedule: ReminderCalendarSchedule? {
        let c = recurringCalendar
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return ReminderCalendarSchedule.make(repeatText, time: String(format: "%02d:%02d", utc.component(.hour, from: repeatClock), utc.component(.minute, from: repeatClock)), start: TaskPlanner.dayKey(date, calendar: c), zone: sourceZone)
    }
    private func apply() {
        // The sheet may have stayed open past its chosen time since the button rendered.
        guard kind != "absolute" || !enabled || date > Date() else { message = "Choose a future time, or turn this reminder off."; return }
        let changed: ReminderSpec
        if kind == "recurring" {
            guard let schedule = recurringSchedule, !enabled || !schedule.dates(after: Date(), limit: 1).isEmpty else { message = "Choose a valid calendar rule with a future occurrence."; return }
            changed = .recurring(schedule, id: draft.spec.id, enabled: enabled)
        } else { changed = kind == "absolute" ? .absolute(date, id: draft.spec.id) : .relative(before ? -minutes : minutes, id: draft.spec.id, enabled: enabled) }
        var spec = draft.spec.mergingSettings(from: changed)
        spec.raw["enabled"] = .bool(enabled)
        if let error = save(spec) { message = error; return }
        dismiss()
    }
}
struct ReminderSystemSettingsButton: View {
    var body: some View {
        #if os(iOS)
        Button("Open Notification Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.frame(minHeight: 44)
        #else
        Button("Open Notification Settings…") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
        #endif
    }
}

/// Distinguish successful inactive registration from actual reminder delivery. No activation
/// control is exposed before the provider/authority/device rollout gates are accepted.
struct RemoteReminderRegistrationView: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote reminders are not available yet. Scheduled reminders continue on this device.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("remoteReminderAvailability")
            if store.signedIn && !store.localMode {
                Text(store.remoteReminderStatus).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("remoteReminderStatus")
                Button { Task { await store.refreshRemoteReminderRegistration(force: true) } } label: {
                    Label(store.remoteReminderBusy ? "Checking setup…" : "Check remote setup", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }.disabled(store.remoteReminderBusy).accessibilityIdentifier("remoteReminderRetry")
            } else {
                Text("Sign in to connect this device to your account.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}


/// One synchronized workspace preference; notification permission remains per device.
struct ReminderSnoozePreferencesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var workspace: WorkspaceBinding?
    private var editable: Bool {
        workspace?.matches(account: store.userID, generation: store.workspaceGeneration) == true && store.reminderSnoozeEditable
    }
    private var choices: [Int] { Array(Set(ReminderSnooze.presets + [store.reminderSnoozeMinutes])).sorted() }
    private var selection: Binding<Int> {
        Binding(get: { store.reminderSnoozeMinutes }, set: { value in
            guard let workspace else { return }
            _ = store.setReminderSnooze(value, workspace: workspace)
        })
    }
    private var picker: some View {
        Picker("Snooze for", selection: selection) {
            ForEach(choices, id: \.self) { Text(ReminderSnooze.label($0)).tag($0) }
        }
    }
    var body: some View {
        Group {
            Menu { picker } label: {
                HStack {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Snooze for").font(.caption).foregroundStyle(Color.secondary)
                            Text(ReminderSnooze.label(store.reminderSnoozeMinutes)).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    } else {
                        Text("Snooze for").foregroundStyle(Color.primary); Spacer()
                        Text(ReminderSnooze.label(store.reminderSnoozeMinutes)).fontWeight(.medium).foregroundStyle(Color.primary)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tint)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier(typeSize.isAccessibilitySize ? "reminderSnoozeMenu" : "reminderSnooze")
                .accessibilityLabel("Snooze for").accessibilityValue(ReminderSnooze.label(store.reminderSnoozeMinutes))
                .disabled(!editable)
            Text(editable ? "Snooze waits this amount of time from your tap. " + (store.localMode ? "This choice is saved in this workspace" : "This choice syncs with your workspace") + "; existing snoozes keep their scheduled time." : "This snooze preference is unavailable or needs a newer app. Its settings are preserved. Reopen Notifications after changing workspaces.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if workspace == nil { workspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) } }
    }
}

struct ReminderAutomaticPreferencesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var workspace: WorkspaceBinding?
    private var editable: Bool {
        workspace?.matches(account: store.userID, generation: store.workspaceGeneration) == true && store.reminderSnoozeEditable
    }
    private var choices: [Int] { Array(Set(ReminderAutomatic.presets + [store.reminderAutomaticMinutes])).sorted() }
    var body: some View {
        Group {
            Menu {
                Picker("Timed task default", selection: Binding(get: { store.reminderAutomaticMinutes }, set: { value in
                    guard let workspace else { return }
                    _ = store.setReminderAutomatic(value, workspace: workspace)
                })) {
                    ForEach(choices, id: \.self) { Text(ReminderAutomatic.label($0)).tag($0) }
                }
            } label: {
                HStack {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Timed task default").font(.caption).foregroundStyle(Color.secondary)
                            Text(ReminderAutomatic.label(store.reminderAutomaticMinutes)).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    } else {
                        Text("Timed task default").foregroundStyle(Color.primary); Spacer()
                        Text(ReminderAutomatic.label(store.reminderAutomaticMinutes)).fontWeight(.medium).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tint)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("reminderAutomatic")
                .accessibilityLabel("Timed task default").accessibilityValue(ReminderAutomatic.label(store.reminderAutomaticMinutes)).disabled(!editable)
            Text(editable ? "Applied when a task first gets a date and time. Existing reminder choices stay as they are. " + (store.localMode ? "Saved in this workspace." : "Syncs with your workspace.") + " Date-only tasks keep their 8 AM planned reminder." : "This preference is unavailable or needs a newer app. Its settings are preserved. Reopen Notifications after changing workspaces.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.onAppear { if workspace == nil { workspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) } }
    }
}

/// Preview uses the same materialization policy as Save and never writes the Store.
struct ReminderAutomaticPreview: View {
    @Environment(Store.self) private var store
    let task: Record
    var previous: Record? = nil
    var body: some View {
        let resolved = store.applyingReminderDefault(task, previous: previous)
        if resolved["reminder_specs"] != task["reminder_specs"] {
            Text("Default reminder: " + ReminderAutomatic.label(store.reminderAutomaticMinutes))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("automaticReminderPreview")
            if store.reminderAutomaticMinutes != -1 && !store.remindersEnabled {
                Text("Delivery is off on this device. Enable it in Reminders.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
