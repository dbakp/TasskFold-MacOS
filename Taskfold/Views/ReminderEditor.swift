import SwiftUI
import MapKit

struct TaskReminderEditor: View {
    @Environment(Store.self) private var store
    @Binding var task: Record
    @State private var editing: ReminderDraft?
    @State private var sendingPlace: LocationHandoffSendRequest?
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
                            Label(location.repeats ? (location.transition == .arrive ? "Every arrival until completed" : "Every departure until completed") : (location.transition == .arrive ? "Arrival reminder" : "Departure reminder"), systemImage: "mappin.and.ellipse")
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
                if store.locationHandoffAvailable, store.record("tasks", id: task.id) != nil {
                    Button("Send a place reminder…", systemImage: "iphone.and.arrow.forward") {
                        sendingPlace = .init(taskID: task.id, workspace: .init(account: store.userID, generation: store.workspaceGeneration))
                    }.disabled(task.completed).accessibilityIdentifier("reminderSendPlace")
                    Text("Review a pin here, then save the reminder on your iPhone or iPad.").font(.footnote).foregroundStyle(.secondary)
                } else { Text("Sign in and open a saved task to send a private place draft to iPhone or iPad.").font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Place reminders") }
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
        .onChange(of: store.workspaceGeneration) { _, _ in editing = nil; sendingPlace = nil }
        .alert("Reminder not changed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .sheet(item: $sendingPlace) { request in LocationHandoffSendView(request: request) }
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
struct ReminderSpecEditingContext {
    let current: () -> Bool
    let capture: (JSON) -> Void
    let closed: () -> Void
    let preserve: () -> Void
    let status: () -> String
    var revokeFixture: (() -> Void)? = nil
}
struct ReminderSpecEditor: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.dismiss) private var dismiss
    let draft: ReminderDraft
    let context: ReminderSpecEditingContext?
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
    init(draft: ReminderDraft, context: ReminderSpecEditingContext? = nil, save: @escaping (ReminderSpec) -> String?) {
        self.draft = draft; self.save = save; self.context = context
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
    private var available: Bool { context?.current() ?? true }
    private var checkpointState: JSON {
        guard context != nil else { return .null }
        return .object(["kind": .string(kind), "minutes": .number(Double(minutes)), "before": .bool(before), "date": .number(date.timeIntervalSince1970), "enabled": .bool(enabled), "time_sensitive": .bool(timeSensitive), "repeat_clock": .number(repeatClock.timeIntervalSince1970), "repeat_text": .string(repeatText), "time_zone": .string(sourceZone), "holiday_policy": holidayPolicy.map { .object($0.raw) } ?? .null, "interval_text": .string(intervalText), "limited_count": .bool(limitedCount), "count_text": .string(countText), "limited_end": .bool(limitedEnd), "end": .number(end.timeIntervalSince1970)])
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
                #if DEBUG
                if let revoke = context?.revokeFixture {
                    Section { Button("Change test role to viewer", action: revoke).accessibilityIdentifier("revokeTeamReminderSettingsFixture") }
                }
                #endif
            }.navigationDestination(isPresented: $choosingHolidays) {
                HolidayCalendarReview(policy: holidayPolicy, year: holidayReviewYear) { if available { holidayPolicy = $0 } }
            }
            .opacity(available ? 1 : 0).accessibilityHidden(!available).disabled(!available)
            .overlay(alignment: .topLeading) {
                if !available {
                    ScrollView { VStack(alignment: .leading, spacing: 16) {
                        Label("Reminder editing paused", systemImage: "lock.shield").font(.title2)
                        Text("Project access changed. Close these settings before reopening the task.")
                        Text(context?.status() ?? "Your settings are kept in this editor.").accessibilityIdentifier("teamReminderSettingsRecoveryStatus")
                        Button("Retry preserving edit") { context?.capture(checkpointState); context?.preserve() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24) }.background(.background).accessibilityIdentifier("teamReminderSettingsPaused")
                }
            }
            .formStyle(.grouped).accessibilityIdentifier("reminderSpecForm").navigationTitle(draft.index == nil ? "Add reminder" : "Edit reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(available ? "Cancel" : "Close") { dismiss() }.accessibilityIdentifier("reminderCancel") }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply() }.disabled(!available || (kind == "absolute" && enabled && date <= Date()) || (kind == "recurring" && (recurringSchedule == nil || (enabled && calendarDates(after: Date(), limit: 1).isEmpty))) || (kind == "interval" && (intervalSchedule == nil || (enabled && intervalSchedule?.dates(after: previewNow, limit: 1).isEmpty == true)))).accessibilityIdentifier("reminderSave") }
            }
        }
        .onChange(of: checkpointState) { _, value in context?.capture(value) }
        .onChange(of: available) { _, value in
            if !value { context?.capture(checkpointState); context?.preserve(); choosingHolidays = false; choosingTimeZone = false; repeatFocused = false; intervalFocused = nil }
        }
        .onDisappear { if available { context?.closed() } else { context?.preserve() } }
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
        guard available else { return "Project access changed. Your draft is kept privately." }
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
        guard available else { context?.capture(checkpointState); context?.preserve(); return }
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

#if os(macOS)
struct LocationHandoffSendRequest: Identifiable {
    let id = UUID()
    let taskID: String
    let workspace: WorkspaceBinding
}

struct LocationHandoffSendView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: LocationHandoffSendRequest
    @State private var name = ""
    @State private var query = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var viewport: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(.init(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 140, longitudeDelta: 340)))
    @State private var radius = 250.0
    @State private var transition = LocationReminderSettings.Transition.arrive
    @State private var repeats = false
    @State private var search: MKLocalSearch?
    @State private var searchTimeout: Task<Void,Never>?
    @State private var searchToken = UUID()
    @State private var searching = false
    @State private var results: [SearchResult] = []
    @State private var prepared: LocationHandoffProposal?
    @State private var sent: LocationHandoffRecord?
    @State private var records: [LocationHandoffRecord] = []
    @State private var working = false
    @State private var confirmSend = false
    @State private var discarding: LocationHandoffRecord?
    @State private var message: String?
    init(request: LocationHandoffSendRequest, initialPlace: LocationPrivatePlace? = nil) {
        self.request = request
        if let place = initialPlace, place.account == request.workspace.account {
            let pin = CLLocationCoordinate2D(latitude: Double(place.latitudeE6)/1_000_000, longitude: Double(place.longitudeE6)/1_000_000)
            _name = State(initialValue: place.name); _coordinate = State(initialValue: pin); _radius = State(initialValue: Double(place.radius))
            _camera = State(initialValue: .region(.init(center: pin, latitudinalMeters: 3000, longitudinalMeters: 3000)))
        }
    }
    private struct SearchResult: Identifiable { let id: Int; let name: String; let detail: String; let coordinate: CLLocationCoordinate2D }
    private var current: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) && store.locationHandoffAvailable }
    private var place: LocationPrivatePlace? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let coordinate, !title.isEmpty, title.unicodeScalars.count <= 120, title.utf8.count <= 480,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return .make(account: request.workspace.account, name: title, latitude: coordinate.latitude, longitude: coordinate.longitude, radius: Int(radius))
    }
    private func status(_ row: LocationHandoffRecord) -> String {
        switch row.state {
        case .pending: return row.available ? "Ready to review on iPhone or iPad" : "Task changed or unavailable"
        case .claimed: return row.available ? "Review started on a device" : "Task changed or unavailable"
        case .imported: return "Saved on a device"
        case .discarded: return "Discarded"
        case .expired: return "Expired"
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(store.record("tasks", id: request.taskID)?.title ?? "Task unavailable").font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("Choose a place here. Review and save it on the iPhone or iPad that will deliver the reminder.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let sent {
                    Section {
                        Label(status(sent), systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.tint).accessibilityIdentifier("handoffSendSuccess")
                        Text("Open Notifications → Place reminders → Place drafts from Mac on your device. No alert has been enabled by sending this draft.").fixedSize(horizontal: false, vertical: true)
                        Button("Prepare another draft") { self.sent = nil; prepared = nil }.accessibilityIdentifier("handoffAnotherDraft")
                    }
                } else {
                    Section {
                        TextField("Address or place", text: $query).onSubmit { runSearch() }.accessibilityIdentifier("handoffSearchQuery")
                        Button(searching ? "Searching…" : "Search Apple Maps") { runSearch() }.disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.count > 500).accessibilityIdentifier("handoffSearch")
                        ForEach(results) { result in
                            Button { choose(result.coordinate); if name.isEmpty { name = String(result.name.prefix(120)) }; results = [] } label: {
                                VStack(alignment: .leading, spacing: 3) { Text(result.name); Text(result.detail).font(.caption).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                            }.buttonStyle(.borderless).accessibilityIdentifier("handoffSearchResult-\(result.id)")
                        }
                    } header: { Text("Find your place") } footer: { Text("Search sends your query and selected map area to Apple. You can also choose a pin directly on the map. No location permission is requested on this Mac.") }
                    Section {
                        MapReader { proxy in
                            Map(position: $camera) {
                                if let coordinate {
                                    MapCircle(center: coordinate, radius: radius).foregroundStyle(.tint.opacity(0.16)).stroke(.tint, lineWidth: 2)
                                    Annotation("Draft pin", coordinate: coordinate) { Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.tint) }
                                }
                            }.mapControls { MapCompass(); MapScaleView() }
                                .onMapCameraChange(frequency: .onEnd) { viewport = $0.region.center }
                                .onTapGesture(coordinateSpace: .local) { point in if let pin = proxy.convert(point, from: .local) { choose(pin, moveCamera: false) } }
                                .accessibilityLabel("Draft place map").accessibilityHint("Search for a place or move the map and choose Use map center.")
                        }.frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("handoffSendMap")
                        Button("Use map center") { if let viewport { choose(viewport, moveCamera: false) } }.disabled(viewport == nil).accessibilityIdentifier("handoffMapCenter")
                        if coordinate != nil { Label("Pin selected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("handoffPinSelected") }
                        TextField("Place name", text: $name).accessibilityIdentifier("handoffPlaceName")
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 120 { Text("Choose a name with no more than 120 characters.").foregroundStyle(.red) }
                        Slider(value: $radius, in: 100...5000, step: 50) { Text("Area around the pin") }
                            .accessibilityValue("\(Int(radius)) metres").accessibilityIdentifier("handoffRadius")
                        Text("\(Int(radius)) metres around the pin").font(.caption).foregroundStyle(.secondary)
                        Picker("Boundary", selection: $transition) { Text("Arrive").tag(LocationReminderSettings.Transition.arrive); Text("Leave").tag(LocationReminderSettings.Transition.leave) }.pickerStyle(.segmented).accessibilityIdentifier("handoffTransition")
                        Toggle("Every matching visit until completed", isOn: $repeats).accessibilityIdentifier("handoffRepeats")
                    } header: { Text("Review the pin and boundary") }
                    Section {
                        Text("Sending uploads this place’s name, pin, area and reminder choices to your private Taskfold account. Drafts are available for up to seven days. Collaborators cannot read the draft. Taskfold’s service administrators can access stored drafts.").fixedSize(horizontal: false, vertical: true)
                        Text("Your existing saved places stay on their devices. Sending does not create a reminder or turn on alerts. Your device must review and save this draft.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } header: { Text("Private to your account") }
                }
                if !records.isEmpty {
                    Section {
                        ForEach(records, id: \.id) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.proposal?.raw["place_name"]?.text ?? "Place draft").font(.headline)
                                Text(status(row)).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("handoffSentStatus-" + row.id)
                                if row.state == .pending {
                                    Button("Discard pending draft", role: .destructive) { discarding = row }.accessibilityIdentifier("handoffSendDiscard-" + row.id)
                                }
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    } header: { Text("Drafts for this task") }
                }
                Section { Button("Refresh draft status") { Task { await reload() } }.accessibilityIdentifier("handoffSendRefresh") }
                if working { ProgressView("Updating your place draft…") }
            }.formStyle(.grouped).navigationTitle("Send a place reminder").accessibilityIdentifier("handoffSendForm")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(sent == nil ? "Cancel" : "Done") { dismiss() }.disabled(working).accessibilityIdentifier("handoffSendClose") }
                    ToolbarItem(placement: .confirmationAction) {
                        if sent == nil { Button(prepared == nil ? "Review and send…" : "Retry sending…") { confirmSend = true }.disabled(working || !current || place == nil).keyboardShortcut(.defaultAction).accessibilityIdentifier("handoffSend") }
                    }
                }.disabled(working).interactiveDismissDisabled(working)
                .task { await reload() }.onDisappear { cancelSearch() }
                .onChange(of: name) { _, _ in prepared = nil }.onChange(of: radius) { _, _ in prepared = nil }
                .onChange(of: transition) { _, _ in prepared = nil }.onChange(of: repeats) { _, _ in prepared = nil }
                .onChange(of: store.workspaceGeneration) { _, _ in cancelSearch(); dismiss() }
                .alert("Send this place draft?", isPresented: $confirmSend) {
                    Button("Send draft") { Task { await send() } }.accessibilityIdentifier("handoffConfirmSend")
                    Button("Keep editing", role: .cancel) {}
                } message: { Text("Upload this reviewed place to your private Taskfold account? Open Place drafts from Mac on your iPhone or iPad to review it before saving a reminder.") }
                .alert("Place draft", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
                .confirmationDialog("Discard this pending draft?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
                    Button("Discard draft", role: .destructive) { if let row = discarding { Task { await discard(row) } } }
                } message: { Text("Your task is kept. A review that has already started must be finished or discarded on that device.") }
        }.frame(minWidth: 560, idealWidth: 640, minHeight: 650, idealHeight: 820)
    }
    private func choose(_ pin: CLLocationCoordinate2D, moveCamera: Bool = true) {
        guard CLLocationCoordinate2DIsValid(pin) else { return }; cancelSearch(); coordinate = pin; prepared = nil
        if moveCamera { camera = .region(.init(center: pin, latitudinalMeters: 3000, longitudinalMeters: 3000)) }
    }
    private func cancelSearch() { searchToken = UUID(); search?.cancel(); searchTimeout?.cancel(); searchTimeout = nil; searching = false }
    private func runSearch() {
        guard current else { return }; let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 500 else { return }; cancelSearch(); results = []; searching = true
        #if DEBUG
        if LocationHandoffNativeFixture.enabled {
            results = [.init(id: 0, name: "Sample design studio", detail: "Synthetic address for isolated acceptance", coordinate: .init(latitude: 55.676098, longitude: 12.568337))]; searching = false; return
        }
        #endif
        let token = UUID(); searchToken = token
        let parameters = MKLocalSearch.Request(); parameters.naturalLanguageQuery = term
        if let coordinate { parameters.region = .init(center: coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000) }
        let operation = MKLocalSearch(request: parameters); search = operation
        searchTimeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(20)); guard token == searchToken else { return }; cancelSearch(); message = "Search took too long. Try again or choose a pin on the map." } catch {}
        }
        Task { @MainActor in
            do {
                let response = try await operation.start(); guard current, token == searchToken else { return }
                searchTimeout?.cancel(); searchTimeout = nil; searching = false
                results = response.mapItems.prefix(12).enumerated().map { .init(id: $0.offset, name: $0.element.name ?? "Place", detail: $0.element.placemark.title ?? "", coordinate: $0.element.placemark.coordinate) }
                if results.isEmpty { message = "No places found. Try another address or choose a pin on the map." }
            } catch { guard current, token == searchToken else { return }; cancelSearch(); message = "Places could not be found. Try again or choose a pin on the map." }
        }
    }
    @MainActor private func send() async {
        guard current, !working else { return }; working = true; defer { working = false }
        do {
            if prepared == nil {
                guard let task = store.record("tasks", id: request.taskID), let place,
                      let proposal = LocationHandoffProposal.make(account: request.workspace.account, task: task, place: place, transition: transition, repeats: repeats) else { throw LocationStorageFailure.changed }
                prepared = proposal
            }
            sent = try await store.sendLocationHandoff(prepared!, workspace: request.workspace)
            if current { await loadRows() }
        } catch is CancellationError {} catch { if current { message = error.localizedDescription } }
    }
    @MainActor private func loadRows() async {
        do { let rows = try await store.locationHandoffs(workspace: request.workspace); if current { records = rows.filter { $0.raw["task_id"] == .string(request.taskID) } } }
        catch is CancellationError {} catch { if current { message = error.localizedDescription } }
    }
    @MainActor private func reload() async { guard current, !working else { return }; working = true; defer { working = false }; await loadRows() }
    @MainActor private func discard(_ row: LocationHandoffRecord) async {
        guard current, !working else { return }; working = true; defer { working = false; discarding = nil }
        do { try await store.discardLocationHandoff(row, workspace: request.workspace); if current { await loadRows() } }
        catch is CancellationError {} catch { if current { message = error.localizedDescription } }
    }
}
#endif
