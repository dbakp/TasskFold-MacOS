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
                Text(task.due == nil ? "Choose a planned date to activate reminders relative to the task. Fixed-date reminders work without one." : task.string("due_time").isEmpty ? "With a date but no time, the planned reminder is at 8:00 AM." : "Before and after reminders move with the task’s planned time.")
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
                })).disabled(store.requestingNotifications).accessibilityIdentifier("reminderDelivery")
                if store.requestingNotifications { ProgressView("Requesting permission…") }
                Text(store.reminderStatus).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("reminderStatus")
                ReminderSystemSettingsButton()
            } header: { Text("This device") } footer: {
                Text("Reminder choices sync with the task. Enable delivery separately on each device. The nearest 60 notifications are scheduled; later ones refresh while Taskfold is open.")
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
        guard let date = spec.date(task: task, calendar: .current) else { return "Waiting for a planned date" }
        if date <= Date() { return "This reminder time has passed" }
        let time = date.formatted(date: .abbreviated, time: .shortened)
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
    @State private var message: String?
    init(draft: ReminderDraft, save: @escaping (ReminderSpec) -> String?) {
        self.draft = draft; self.save = save
        _kind = State(initialValue: draft.spec.kind)
        _minutes = State(initialValue: abs(draft.spec.offset ?? -10))
        _before = State(initialValue: (draft.spec.offset ?? -10) <= 0)
        _date = State(initialValue: draft.spec.absolute ?? Date().addingTimeInterval(3600))
        _enabled = State(initialValue: draft.spec.enabled)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("When", selection: $kind) { Text("Before or after plan").tag("relative"); Text("A fixed date and time").tag("absolute") }
                        .accessibilityIdentifier("reminderKind")
                    Toggle("Enabled", isOn: $enabled)
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
                } else {
                    Section {
                        DatePicker("Remind me", selection: $date, displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("reminderDate")
                        Text("\(TimeZone.current.identifier). This reminder stays at the same instant when the task moves or you travel.").font(.footnote).foregroundStyle(.secondary)
                        if enabled && date <= Date() { Text("Choose a future time, or turn this reminder off.").foregroundStyle(.red) }
                    }
                }
            }.formStyle(.grouped).navigationTitle(draft.index == nil ? "Add reminder" : "Edit reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply() }.disabled(kind == "absolute" && enabled && date <= Date()).accessibilityIdentifier("reminderSave") }
            }
        }
        .alert("Reminder not saved", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 530)
        #endif
    }
    private func apply() {
        // The sheet may have stayed open past its chosen time since the button rendered.
        guard kind != "absolute" || !enabled || date > Date() else { message = "Choose a future time, or turn this reminder off."; return }
        let changed = kind == "absolute" ? ReminderSpec.absolute(date, id: draft.spec.id) : ReminderSpec.relative(before ? -minutes : minutes, id: draft.spec.id, enabled: enabled)
        var spec = draft.spec
        // Merge known fields, retaining extensions of this version.
        for (key, value) in changed.raw { spec.raw[key] = value }
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
