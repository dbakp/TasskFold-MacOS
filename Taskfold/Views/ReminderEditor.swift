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
                Text(task.due == nil ? "Choose a planned date to activate reminders relative to the task. Fixed-date and repeating reminders work without one." : task.string("due_time").isEmpty ? "With a date but no time, the planned reminder is at 8:00 AM in this device’s time zone." : "Before and after reminders move with the task’s planned time.")
            }
            Section("Custom reminders") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, value in
                    if let spec = ReminderSpec(row: value), spec.id != ReminderSpec.plannedID {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button { beginEditing(spec, index: index) } label: {
                                    Label { Text(spec.label).multilineTextAlignment(.leading).lineLimit(nil).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: spec.kind == "absolute" ? "calendar.badge.clock" : "bell") }
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.buttonStyle(.borderless).disabled(!spec.locallyEditable)
                                    .accessibilityIdentifier("reminderEdit-\(index)")
                                Button(role: .destructive) { remove(index) } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                                    .buttonStyle(.borderless).accessibilityLabel("Delete " + spec.label).accessibilityIdentifier("reminderDelete-\(index)")
                            }
                            Text(status(spec) + (spec.timeSensitive ? " · Time Sensitive" : "")).font(.footnote).foregroundStyle(.secondary)
                            if !spec.locallyEditable { Text("This reminder uses another delivery channel. Its settings are preserved; this app delivers only local notifications.").font(.footnote).foregroundStyle(.secondary) }
                        }
                    } else if let location = LocationReminderSettings(raw: value.object) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(location.transition == .arrive ? "Arrival reminder" : "Departure reminder", systemImage: "mappin.and.ellipse")
                            Text("Uses a private place on its originating iPhone or iPad. Review the place and delivery there.").font(.footnote).foregroundStyle(.secondary)
                            Button("Delete location reminder", role: .destructive) { remove(index) }.buttonStyle(.borderless).frame(minHeight: 44)
                        }
                    } else if ReminderSpec(row: value) == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Unsupported reminder", systemImage: "lock.shield")
                            Text("Its original settings are preserved when you save this task.").font(.footnote).foregroundStyle(.secondary)
                            Button("Delete unsupported reminder", role: .destructive) { remove(index) }.frame(minHeight: 44)
                        }
                    }
                }
                Button { beginEditing(.relative(-10), index: nil) } label: { Label("Add reminder", systemImage: "plus.circle").frame(minHeight: 44) }
                    .disabled(rows.count >= ReminderSpec.maximum).accessibilityIdentifier("reminderAdd")
                if rows.count >= ReminderSpec.maximum { Text("This task has the maximum of 20 reminder settings.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Toggle("Deliver reminders", isOn: Binding(get: { store.remindersEnabled }, set: { value in
                    if value { Task { await store.enableNotifications() } } else { store.disableNotifications() }
                })).disabled(store.requestingNotifications || store.requestingFocusAlerts).accessibilityIdentifier("reminderDelivery")
                if store.requestingNotifications { ProgressView("Requesting permission…") }
                Text(store.reminderStatus).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("reminderStatus")
                Toggle("Allow Time Sensitive reminders", isOn: Binding(get: { store.timeSensitiveRemindersEnabled }, set: { store.setTimeSensitiveReminders($0) }))
                    .accessibilityIdentifier("reminderTimeSensitiveDevice")
                Text("Off by default on each device and workspace. When allowed, only reminders marked Time Sensitive request immediate attention. Focus and system notification settings still control delivery.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(store.timeSensitiveReminderStatus).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("reminderTimeSensitiveStatus")
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
        .onChange(of: store.workspaceGeneration) { _, _ in editing = nil }
        .alert("Reminder not changed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .sheet(item: $editing) { draft in
            ReminderSpecEditor(draft: draft) { spec in
                guard store.workflowReady(draft.workspace), task.id == draft.taskID, task["task_generation"] == draft.taskGeneration, rows == draft.originalRows else { return "This task or its reminder settings changed. Cancel and reopen the reminder." }
                if draft.wasPersisted {
                    guard let current = store.record("tasks", id: draft.taskID), current["task_generation"] == draft.taskGeneration else { return "This task was removed or replaced. Close its editor before changing reminders." }
                }
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
    private func beginEditing(_ spec: ReminderSpec, index: Int?) {
        let workspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)
        guard store.workflowReady(workspace) else { message = store.error; return }
        editing = ReminderDraft(spec: spec, index: index, workspace: workspace, taskID: task.id, taskGeneration: task["task_generation"], wasPersisted: store.record("tasks", id: task.id) != nil, originalRows: rows)
    }
    private func remove(_ index: Int) {
        var values = rows; values.remove(at: index)
        if values.isEmpty { values = [.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID, enabled: false).raw)] }
        task["reminder_specs"] = .array(values)
    }
    private func status(_ spec: ReminderSpec) -> String {
        if !spec.enabled { return "Off" }
        if let holiday = spec.holidaySchedule, !holiday.base.dates(after: Date(), limit: 1).isEmpty, ReminderCivilDay.current(Date(), zone: holiday.base.calendar.timeZone).map({ $0 > holiday.policy.lastDay }) == true { return "Review holiday dates to continue beyond " + String(holiday.policy.year) }
        guard let date = spec.date(task: task, calendar: .current) else { return ["recurring", "interval"].contains(spec.kind) ? "This schedule has ended" : "Waiting for a planned date" }
        if date <= Date() { return "This reminder time has passed" }
        let time = date.formatted(date: .abbreviated, time: .shortened)
        if spec.intervalSchedule != nil { return "Next · \(time) · elapsed time" }
        if let schedule = spec.schedule { return "Next · \(schedule.formatted(date)) · \(schedule.timeZone)" }
        return spec.kind == "absolute" ? "Fixed instant · \(time) · shown in your current time zone" : "Next · \(time)"
    }
}

struct ReminderDraft: Identifiable {
    var spec: ReminderSpec
    var index: Int?
    let workspace: WorkspaceBinding
    let taskID: String
    let taskGeneration: JSON
    let wasPersisted: Bool
    let originalRows: [JSON]
    var id: String { spec.id }
}
struct ReminderSpecEditor: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.dismiss) private var dismiss
    let draft: ReminderDraft
    let save: (ReminderSpec) -> String?
    @State private var kind: String
    @State private var minutes: Int
    @State private var before: Bool
    @State private var date: Date
    @State private var enabled: Bool
    @State private var timeSensitive: Bool
    @State private var repeatClock: Date
    @State private var repeatText: String
    @FocusState private var repeatFocused: Bool
    @State private var choosingTimeZone = false
    @State private var holidayPolicy: ReminderHolidayPolicy?
    @State private var choosingHolidays = false
    @State private var sourceZone: String
    @State private var message: String?
    @State private var intervalText: String
    @State private var limitedCount: Bool
    @State private var countText: String
    @State private var limitedEnd: Bool
    @State private var end: Date
    @State private var previewNow = Date()
    private enum IntervalField: Hashable { case minutes, count }
    @FocusState private var intervalFocused: IntervalField?
    init(draft: ReminderDraft, save: @escaping (ReminderSpec) -> String?) {
        self.draft = draft; self.save = save
        _kind = State(initialValue: draft.spec.kind)
        _minutes = State(initialValue: abs(draft.spec.offset ?? -10))
        _before = State(initialValue: (draft.spec.offset ?? -10) <= 0)
        _date = State(initialValue: draft.spec.schedule.flatMap { Dates.parse($0.startDay, calendar: $0.calendar) } ?? draft.spec.intervalSchedule?.start ?? draft.spec.absolute ?? Date().addingTimeInterval(3600))
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let initialZone = draft.spec.schedule?.timeZone ?? ReminderTimeZones.sourceIdentifier(for: .current)
        var source = draft.spec.schedule?.calendar ?? Calendar(identifier: .gregorian)
        source.timeZone = TimeZone(identifier: initialZone)!
        let initial = draft.spec.absolute ?? Date().addingTimeInterval(3600)
        let hour = draft.spec.schedule.flatMap { Int($0.time.prefix(2)) } ?? source.component(.hour, from: initial)
        let minute = draft.spec.schedule.flatMap { Int($0.time.suffix(2)) } ?? source.component(.minute, from: initial)
        _repeatClock = State(initialValue: utc.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute))!)
        _repeatText = State(initialValue: draft.spec.schedule?.expression ?? "every week")
        _holidayPolicy = State(initialValue: draft.spec.holidaySchedule?.policy)
        _sourceZone = State(initialValue: initialZone)
        _timeSensitive = State(initialValue: draft.spec.timeSensitive)
        _enabled = State(initialValue: draft.spec.enabled)
        _intervalText = State(initialValue: String(draft.spec.intervalSchedule?.intervalMinutes ?? 30))
        _limitedCount = State(initialValue: draft.spec.intervalSchedule?.count != nil)
        _countText = State(initialValue: String(draft.spec.intervalSchedule?.count ?? 5))
        _limitedEnd = State(initialValue: draft.spec.intervalSchedule?.until != nil)
        _end = State(initialValue: draft.spec.intervalSchedule?.until ?? (draft.spec.intervalSchedule?.start ?? Date().addingTimeInterval(3600)).addingTimeInterval(86400))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("When", selection: $kind) { Text("From plan").tag("relative"); Text("Fixed time").tag("absolute"); Text("Repeats").tag("recurring"); Text("Interval").tag("interval") }
                        .accessibilityIdentifier("reminderKind")
                    Toggle("Enabled", isOn: $enabled).accessibilityIdentifier("reminderEnabled")
                }
                Section {
                    Toggle("Time Sensitive", isOn: $timeSensitive).accessibilityIdentifier("reminderTimeSensitive")
                } header: { Text("Presentation") } footer: {
                    Text("For a task that needs your attention at this time. Requires Allow Time Sensitive reminders on this device. May interrupt Focus when permitted by system settings; does not override Silent mode or guarantee delivery.")
                        .fixedSize(horizontal: false, vertical: true)
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
                    } footer: { Text("Uses elapsed minutes before or after the task’s planned time. A date without a time uses 8:00 AM in this device’s time zone.") }
                } else if kind == "interval" {
                    intervalControls
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
                        Button { repeatFocused = false; choosingTimeZone = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Time zone").foregroundStyle(.primary)
                                Text(sourceZone.replacingOccurrences(of: "_", with: " ")).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.borderless).accessibilityLabel("Reminder time zone").accessibilityValue(sourceZone.replacingOccurrences(of: "_", with: " ")).accessibilityIdentifier("reminderChooseTimeZone")
                        if sourceZone != TimeZone.current.identifier && ReminderTimeZones.valid(TimeZone.current.identifier) {
                            Button("Use current time zone") {
                                if let error = selectTimeZone(TimeZone.current.identifier) { message = error }
                            }.frame(minHeight: 44).accessibilityIdentifier("reminderUseCurrentZone")
                        }
                        Button { repeatFocused = false; choosingHolidays = true } label: {
                            Label(holidayPolicy.map { "Holiday dates · " + String($0.year) } ?? "Add holiday policy", systemImage: "calendar.badge.minus").frame(minHeight: 44)
                        }.accessibilityIdentifier("reminderHolidayDates")
                        if let policy = holidayPolicy {
                            Text(policy.source + " · " + policy.region).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(policy.mode == .skip ? "Skip excluded dates" : "Move to next available day").font(.footnote)
                            Text("Alerts stop at the end of this reviewed year. Review new dates to continue.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let schedule = recurringSchedule, !calendarDates(after: previewNow, limit: 1).isEmpty {
                            Text(schedule.summary).font(.footnote).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("reminderRepeatSummary")
                            Text("Upcoming alerts").font(.headline)
                            let rows = ReminderClockPreview.rows(schedule, after: previewNow, displayZone: .current, dates: calendarDates(after: previewNow, limit: 5))
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text((index == 0 ? "Next · " : "") + row.sourceText + " · " + sourceZone.replacingOccurrences(of: "_", with: " "))
                                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(index == 0 ? "reminderRepeatPreview" : "reminderRepeatPreview-\(index)")
                                    if let device = row.deviceText {
                                        Text("On this device · " + device + " · " + TimeZone.current.identifier.replacingOccurrences(of: "_", with: " "))
                                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("reminderDevicePreview-\(index)")
                                    }
                                }
                            }
                            if ReminderClockPreview.clocksChange(rows) {
                                Text("Clocks change during these dates. The saved time zone still controls each alert.").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("reminderClockChange")
                            }
                        } else if recurringSchedule != nil && !enabled {
                            Text("This schedule has ended. Its settings will be saved with delivery off.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Enter a calendar rule with a future occurrence. Try every Saturday, every 2 weeks on Monday and Friday, or every month on last Friday. Add until YYYY-MM-DD or for 5 occurrences if needed.")
                                .font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("reminderRepeatError")
                        }
                    } header: { Text("Schedule") } footer: {
                        Text("Keeps this clock time in the saved time zone when you travel, independently of the task’s plan. The task must remain open. Completing the task cancels its remaining alerts. Completion-based rules (every!) belong to the task’s repeat setting.")
                    }
                } else {
                    Section {
                        DatePicker("Remind me", selection: $date, displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("reminderDate")
                        Text("\(TimeZone.current.identifier). This reminder stays at the same instant when the task moves or you travel.").font(.footnote).foregroundStyle(.secondary)
                        if enabled && date <= Date() { Text("Choose a future time, or turn this reminder off.").foregroundStyle(.red) }
                    }
                }
            }.navigationDestination(isPresented: $choosingHolidays) {
                HolidayCalendarReview(policy: holidayPolicy, year: holidayReviewYear) { holidayPolicy = $0 }
            }.formStyle(.grouped).accessibilityIdentifier("reminderSpecForm").navigationTitle(draft.index == nil ? "Add reminder" : "Edit reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("reminderCancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply() }.disabled((kind == "absolute" && enabled && date <= Date()) || (kind == "recurring" && (recurringSchedule == nil || (enabled && calendarDates(after: Date(), limit: 1).isEmpty))) || (kind == "interval" && (intervalSchedule == nil || (enabled && intervalSchedule?.dates(after: previewNow, limit: 1).isEmpty == true)))).accessibilityIdentifier("reminderSave") }
            }
        }
        .task {
            while !Task.isCancelled {
                previewNow = Date()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            if intervalFocused != nil { HStack { Spacer(); Button("Hide keyboard") { intervalFocused = nil }.accessibilityIdentifier("reminderIntervalHideKeyboard") }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar) }
        }
        #endif
        .sheet(isPresented: $choosingTimeZone) {
            ReminderTimeZonePicker(selection: sourceZone, choose: selectTimeZone)
        }
        .alert("Reminder not saved", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 530)
        #endif
    }
    @ViewBuilder private var intervalControls: some View {
        Section {
            DatePicker("First alert", selection: $date, displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("reminderIntervalStart")
            intervalInput("Minutes", text: $intervalText, field: .minutes, identifier: "reminderIntervalMinutes")
            Menu("Interval suggestions") {
                ForEach([15, 30, 60, 120, 1440], id: \.self) { value in Button(ReminderIntervalSchedule.intervalDescription(value)) { intervalText = String(value); intervalFocused = nil } }
            }.frame(minHeight: 44).accessibilityIdentifier("reminderIntervalSuggestions")
            Text("5 to 10,080 minutes. Alerts stay this far apart when clocks change or you travel.").font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Interval") }
        Section {
            Toggle("Limit number of alerts", isOn: $limitedCount).accessibilityIdentifier("reminderIntervalCountEnabled")
            if limitedCount {
                intervalInput("Total alerts", text: $countText, field: .count, identifier: "reminderIntervalCount")
                Text("1 to 999 alerts, including the first. Missed alerts still count.").font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("End at a date and time", isOn: $limitedEnd).accessibilityIdentifier("reminderIntervalEndEnabled")
            if limitedEnd { DatePicker("Last allowed alert", selection: $end, displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("reminderIntervalEnd") }
        } header: { Text("Stop") } footer: { Text("When both limits are set, the earlier limit wins.") }
        Section {
            if let schedule = intervalSchedule {
                Text(schedule.summary).font(.callout).accessibilityIdentifier("reminderIntervalSummary")
                let next = schedule.dates(after: previewNow, limit: 5)
                if next.isEmpty {
                    Text(enabled ? "This schedule has ended. Choose a future alert or turn it off." : "This schedule has ended. It will be saved with delivery off.")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("reminderIntervalEnded")
                } else {
                    ForEach(Array(next.enumerated()), id: \.offset) { index, value in
                        Text(value.formatted(date: .abbreviated, time: .shortened)).accessibilityIdentifier("reminderIntervalPreview-\(index)")
                    }
                }
                Text("Shown in " + TimeZone.current.identifier).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Choose an interval from 5 to 10,080 whole minutes, 1 to 999 alerts if limited, and an end at or after the first alert.")
                    .font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("reminderIntervalError")
            }
        } header: { Text("Upcoming alerts") } footer: {
            Text("Uses elapsed time, independently of the task’s plan. Completing this task cancels its remaining alerts. A repeating task carries the same schedule to its next task, without restarting the count. Missed alerts do not arrive in a burst; later alerts refresh while Taskfold is open.")
        }
    }
    @ViewBuilder private func intervalInput(_ label: String, text: Binding<String>, field: IntervalField, identifier: String) -> some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                intervalValue(label, text: text, field: field, identifier: identifier)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Text(label).fixedSize(horizontal: false, vertical: true)
                intervalValue(label, text: text, field: field, identifier: identifier)
            }
        }
    }
    private func intervalValue(_ label: String, text: Binding<String>, field: IntervalField, identifier: String) -> some View {
        HStack {
            TextField(label, text: text).labelsHidden().multilineTextAlignment(textSize.isAccessibilitySize ? .leading : .trailing).focused($intervalFocused, equals: field)
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = ""; intervalFocused = field } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.borderless).accessibilityLabel("Clear " + label).accessibilityIdentifier(identifier + "Clear")
            }
        }
    }
    private var intervalSchedule: ReminderIntervalSchedule? {
        guard let minutes = Int(intervalText.trimmingCharacters(in: .whitespacesAndNewlines)),
              !limitedCount || Int(countText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return nil }
        return ReminderIntervalSchedule(start: date, everyMinutes: minutes, count: limitedCount ? Int(countText.trimmingCharacters(in: .whitespacesAndNewlines)) : nil, until: limitedEnd ? end : nil)
    }
    private func selectTimeZone(_ zone: String) -> String? {
        do {
            let moved = try ReminderTimeZones.movingCivilDay(date, from: sourceZone, to: zone)
            date = moved; sourceZone = zone; return nil
        } catch { return error.localizedDescription }
    }
    private var recurringCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: sourceZone) ?? .current; return c
    }
    private var recurringSchedule: ReminderCalendarSchedule? {
        let c = recurringCalendar
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return ReminderCalendarSchedule.make(repeatText, time: String(format: "%02d:%02d", utc.component(.hour, from: repeatClock), utc.component(.minute, from: repeatClock)), start: TaskPlanner.dayKey(date, calendar: c), zone: sourceZone)
    }
    private var holidayReviewYear: Int {
        guard let schedule = recurringSchedule, let next = schedule.dates(after: Date(), limit: 1).first else { return recurringCalendar.component(.year, from: Date()) }
        return schedule.calendar.component(.year, from: next)
    }
    private func calendarDates(after now: Date, limit: Int) -> [Date] {
        guard let schedule = recurringSchedule else { return [] }
        if let policy = holidayPolicy {
            var fields = schedule.raw; fields["holiday_policy"] = .object(policy.raw)
            return ReminderHolidaySchedule(raw: fields)?.dates(after: now, limit: limit) ?? []
        }
        return schedule.dates(after: now, limit: limit)
    }
    private func apply() {
        // The sheet may have stayed open past its chosen time since the button rendered.
        guard kind != "absolute" || !enabled || date > Date() else { message = "Choose a future time, or turn this reminder off."; return }
        let changed: ReminderSpec
        if kind == "interval" {
            guard let schedule = intervalSchedule, !enabled || !schedule.dates(after: Date(), limit: 1).isEmpty else { message = "Choose a valid interval with a future alert, or turn delivery off."; return }
            changed = .interval(schedule, id: draft.spec.id, enabled: enabled)
        } else if kind == "recurring" {
            guard let schedule = recurringSchedule, !enabled || !calendarDates(after: Date(), limit: 1).isEmpty else { message = "Choose a valid calendar rule with a future occurrence."; return }
            changed = .recurring(schedule, id: draft.spec.id, enabled: enabled)
        } else { changed = kind == "absolute" ? .absolute(date, id: draft.spec.id) : .relative(before ? -minutes : minutes, id: draft.spec.id, enabled: enabled) }
        var spec = draft.spec.mergingSettings(from: changed)
        spec.raw["enabled"] = .bool(enabled)
        guard let calendarSpec = spec.settingHolidayPolicy(kind == "recurring" ? holidayPolicy : nil), let presented = calendarSpec.settingTimeSensitive(timeSensitive) else { message = "This reminder cannot use the selected presentation. Cancel and reopen its settings."; return }
        if let error = save(presented) { message = error; return }
        dismiss()
    }
}
private struct ReminderTimeZonePicker: View {
    @Environment(\.dismiss) private var dismiss
    let selection: String
    let choose: (String) -> String?
    @State private var query = ""
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                ForEach(ReminderTimeZones.choices(including: selection, query: query), id: \.self) { zone in
                    Button {
                        if let message = choose(zone) { failure = message } else { dismiss() }
                    } label: {
                        HStack {
                            Text(zone.replacingOccurrences(of: "_", with: " ")).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if zone == selection { Image(systemName: "checkmark") }
                        }.frame(minHeight: 44)
                    }.accessibilityLabel(zone.replacingOccurrences(of: "_", with: " ") + (zone == selection ? ", selected" : "")).accessibilityIdentifier("reminderZone-" + zone)
                }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or time zone")
            #else
            .searchable(text: $query, prompt: "City or time zone")
            #endif
            .navigationTitle("Time zone")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("reminderZoneCancel") } }
        }
        .alert("Time zone not changed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 560, idealHeight: 600)
        #endif
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

/// A device-owned opt-in appears only for an eligible rollout or an existing
/// choice that still needs a confirmed handoff. Pending delivery remains explicit.
struct RemoteReminderRegistrationView: View {
    @Environment(Store.self) private var store
    private var offersRemoteChoice: Bool { store.remoteReminderAvailable || store.remoteReminderSelected || store.remoteReminderNeedsConfirmation }
    private var hasRemoteAccount: Bool { store.signedIn && (!store.localMode || store.remoteReminderTestWorkspace) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if offersRemoteChoice {
                Toggle("Remote delivery", isOn: Binding(get: { store.remoteReminderSelected }, set: { store.chooseRemoteReminders($0) }))
                    .frame(minHeight: 44).accessibilityLabel("Remote task reminders on this device").accessibilityIdentifier("remoteReminderDelivery")
            }
            Text(offersRemoteChoice ? "For this device. Focus and snoozes stay local. Switching back waits for confirmation." : hasRemoteAccount ? store.remoteReminderStatus : "Sign in to prepare remote reminders.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("remoteReminderAvailability")
            if hasRemoteAccount {
                if offersRemoteChoice {
                    Text(store.remoteReminderStatus).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("remoteReminderStatus")
                }
                Button { Task { await store.refreshRemoteReminderRegistration(force: true) } } label: {
                    Label(store.remoteReminderBusy ? "Checking setup…" : "Check remote setup", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }.disabled(store.remoteReminderBusy).accessibilityIdentifier("remoteReminderRetry")
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
    var showDeliveryGuidance = true
    var body: some View {
        let resolved = store.applyingReminderDefault(task, previous: previous)
        if resolved["reminder_specs"] != task["reminder_specs"] {
            Text("Default reminder: " + ReminderAutomatic.label(store.reminderAutomaticMinutes))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("automaticReminderPreview")
            if showDeliveryGuidance && store.reminderAutomaticMinutes != -1 && !store.remindersEnabled {
                Text("Delivery is off on this device. Enable it in Reminders.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
