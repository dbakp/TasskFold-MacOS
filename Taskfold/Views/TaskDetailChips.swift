import SwiftUI

/// The popovers the task detail's property chips open. Each edits the same `draft` record the inspector saves,
/// so the existing autosave, conflict and recovery path is untouched. See specs/TASK_DETAIL.md.
enum DetailChip: Hashable {
    case date, deadline, priority, reminders, estimate, destination
    case label(String)
}

/// The visual of one property chip. Set properties are tinted at 12% of their role colour; unset core properties are
/// quiet outlined chips. Text wraps (never truncates mid-word) at accessibility sizes.
struct ChipLabel: View {
    let icon: String
    var text: String? = nil
    var tint: Color? = nil
    var trailingIcon: String? = nil
    /// Room kept at the trailing edge for controls a container draws over the chip, such as Quick Add's decline "×".
    var trailingInset: CGFloat = 0
    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon).font(DS.Font.chip).accessibilityHidden(true)
            if let text { Text(text).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) }
            if let trailingIcon { Image(systemName: trailingIcon).font(DS.Font.badge).accessibilityHidden(true) }
        }
        .font(DS.Font.chip)
        .padding(.leading, DS.Space.s).padding(.trailing, DS.Space.s + trailingInset).padding(.vertical, DS.Space.xs + DS.Space.xxs)
        .foregroundStyle(tint ?? DS.Palette.textSecondary)
        .background(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).fill((tint ?? .clear).opacity(0.12)))
        .overlay { if tint == nil { RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 1) } }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
    }
}

struct PropertyChip: View {
    let icon: String
    var text: String? = nil
    var tint: Color? = nil
    var trailingIcon: String? = nil
    var trailingInset: CGFloat = 0
    let accessibility: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { ChipLabel(icon: icon, text: text, tint: tint, trailingIcon: trailingIcon, trailingInset: trailingInset) }
            .buttonStyle(.plain).pointerStyle(.link)
            .accessibilityLabel(accessibility)
            .accessibilityIdentifier(identifier)
    }
}

enum TaskDetailFormat {
    static func relativeDay(_ day: Date, completed: Bool = false) -> (text: String, tint: Color) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: day)
        let delta = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        let absolute = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if completed { return (absolute, DS.Palette.dateLater) }
        if delta < 0 { return (absolute, DS.Palette.dateOverdue) }
        switch delta {
        case 0: return ("Today", DS.Palette.dateToday)
        case 1: return ("Tomorrow", DS.Palette.dateTomorrow)
        case 2...6: return (day.formatted(.dateTime.weekday(.wide)), DS.Palette.dateThisWeek)
        default: return (absolute, DS.Palette.dateLater)
        }
    }
    static func clock(_ value: String) -> String {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) else { return value }
        return date.formatted(date: .omitted, time: .shortened)
    }
    static func estimate(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
    static func weekday(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated)) }
    static func day(_ weekday: Int, after reference: Date = Date(), includingToday: Bool) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: reference)
        if includingToday, calendar.component(.weekday, from: start) == weekday { return start }
        return calendar.nextDate(after: start, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? start
    }
}

/// Date scheduler: quick picks, a graphical calendar, an optional time and the existing repeat editor.
struct TaskDateEditor: View {
    @Binding var draft: Record
    @Binding var repeatExpanded: Bool
    let canRepeat: Bool
    let isTeamTask: Bool
    let openTeamRepeat: () -> Void
    let close: () -> Void
    private var recurrenceSummary: String { draft["is_recurring"].flag ? Recurrence.summary(Recurrence.effective(draft)) : "Never" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                let weekend = TaskDetailFormat.day(7, includingToday: true)
                let nextWeek = TaskDetailFormat.day(2, includingToday: false)
                quickPick("Today", "calendar", Date())
                quickPick("Tomorrow", "sun.max", tomorrow)
                quickPick("This weekend", "sofa", weekend)
                quickPick("Next week", "arrow.uturn.forward", nextWeek)
                Button { draft["due_date"] = .null; draft["due_time"] = .null; close() } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "nosign").frame(width: DS.Space.xl).foregroundStyle(DS.Palette.textSecondary)
                        Text("No date")
                        Spacer(minLength: 0)
                    }.padding(.vertical, DS.Space.xs).contentShape(.rect)
                }.buttonStyle(.plain).disabled(draft.due == nil).accessibilityIdentifier("taskNoDate")
                Divider()
                DatePicker("Date", selection: Binding(get: { draft.due ?? Date() }, set: { draft["due_date"] = .string(Dates.day($0)) }), displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().accessibilityIdentifier("taskDatePicker")
                Divider()
                Toggle("Time", isOn: Binding(get: { !draft.string("due_time").isEmpty }, set: { on in
                    if on, draft.due == nil { draft["due_date"] = .string(Dates.day(Date())) }
                    draft["due_time"] = on ? .string("09:00") : .null
                })).toggleStyle(.switch).accessibilityIdentifier("taskTimeToggle")
                if !draft.string("due_time").isEmpty {
                    DatePicker("Time", selection: Binding(get: {
                        let parts = draft.string("due_time").split(separator: ":").compactMap { Int($0) }
                        return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
                    }, set: { let parts = Calendar.current.dateComponents([.hour, .minute], from: $0); draft["due_time"] = .string(String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)) }), displayedComponents: .hourAndMinute)
                    Picker("Time zone", selection: Binding(get: { draft.string("time_zone") }, set: { draft["time_zone"] = $0.isEmpty ? .null : .string($0) })) {
                        Text("Local time · wherever I am").tag("")
                        Text("Fixed · " + TimeZone.current.identifier).tag(TimeZone.current.identifier)
                        if !draft.string("time_zone").isEmpty && draft.string("time_zone") != TimeZone.current.identifier {
                            Text("Fixed · " + draft.string("time_zone")).tag(draft.string("time_zone"))
                        }
                    }.accessibilityIdentifier("taskTimeZone")
                    if !draft.string("time_zone").isEmpty { Text("Date and time are shown in " + draft.string("time_zone") + ".").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary) }
                }
                if canRepeat {
                    Divider()
                    if isTeamTask {
                        Button { close(); openTeamRepeat() } label: { repeatRow(chevron: "chevron.right") }.buttonStyle(.plain).accessibilityIdentifier("taskRepeat")
                    } else {
                        Button { repeatExpanded.toggle() } label: { repeatRow(chevron: repeatExpanded ? "chevron.down" : "chevron.right") }
                            .buttonStyle(.plain).accessibilityIdentifier("taskRepeat")
                            .accessibilityLabel("Repeat").accessibilityValue((repeatExpanded ? "Expanded. " : "Collapsed. ") + recurrenceSummary)
                        if repeatExpanded { RecurrenceFields(task: $draft) }
                    }
                }
            }.padding(DS.Space.l)
        }.frame(width: 340).frame(maxHeight: 620)
    }
    private func repeatRow(chevron: String) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "repeat").frame(width: DS.Space.xl).foregroundStyle(DS.Palette.textSecondary)
            Text("Repeat")
            Spacer(minLength: 0)
            Text(recurrenceSummary).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            Image(systemName: chevron).font(DS.Font.chip).foregroundStyle(DS.Palette.textTertiary)
        }.padding(.vertical, DS.Space.xs).contentShape(.rect)
    }
    private func quickPick(_ title: String, _ icon: String, _ date: Date) -> some View {
        Button { draft["due_date"] = .string(Dates.day(date)); close() } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: icon).frame(width: DS.Space.xl).foregroundStyle(DS.Palette.textSecondary)
                Text(title)
                Spacer(minLength: 0)
                Text(TaskDetailFormat.weekday(date)).foregroundStyle(DS.Palette.textSecondary)
            }.padding(.vertical, DS.Space.xs).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("taskQuickDate-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

struct TaskDeadlineEditor: View {
    @Binding var draft: Record
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Must be done by").font(DS.Font.sectionHeader)
            DatePicker("Must be done by", selection: Binding(get: { draft.deadline ?? Date() }, set: { draft["deadline_date"] = .string(Dates.day($0)) }), displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().accessibilityIdentifier("taskDeadlinePicker")
            Text("Rescheduling the plan leaves this deadline in place.").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Remove deadline", role: .destructive) { draft["deadline_date"] = .null; close() }.accessibilityIdentifier("taskRemoveDeadline")
        }.padding(DS.Space.l).frame(width: 300)
    }
}

struct TaskEstimateEditor: View {
    @Binding var draft: Record
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Time estimate").font(DS.Font.sectionHeader)
            HStack(spacing: DS.Space.s) {
                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                    Button(TaskDetailFormat.estimate(minutes)) { draft["duration_minutes"] = .number(Double(minutes)) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Stepper("Estimate · \(draft.durationMinutes ?? 30) min", value: Binding(get: { draft.durationMinutes ?? 30 }, set: { draft["duration_minutes"] = .number(Double($0)) }), in: 1...10080)
                .accessibilityIdentifier("taskDuration")
                .accessibilityLabel("Time estimate in minutes")
                .accessibilityValue("\(draft.durationMinutes ?? 30)")
            Button("Remove estimate", role: .destructive) { draft["duration_minutes"] = .null; close() }.accessibilityIdentifier("taskRemoveEstimate")
        }.padding(DS.Space.l).frame(width: 300)
    }
}

struct TaskPriorityEditor: View {
    @Binding var draft: Record
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(1...4, id: \.self) { n in
                Button { draft["priority"] = .number(Double(n)); close() } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: n == 4 ? "flag" : "flag.fill").foregroundStyle(n == 4 ? DS.Palette.textSecondary : DS.Palette.priority(n)).frame(width: DS.Space.xl)
                        Text(n == 4 ? "No priority" : "Priority \(n)")
                        Spacer(minLength: DS.Space.l)
                        if draft.priority == n { Image(systemName: "checkmark").foregroundStyle(DS.Palette.accent) }
                    }.padding(.vertical, DS.Space.xs).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("taskPriority-\(n)")
            }
        }.padding(DS.Space.l).frame(width: 220)
    }
}

struct TaskLabelsEditor: View {
    @Environment(Store.self) private var store
    @Binding var draft: Record
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if store.labels.isEmpty { Text("Create labels from the sidebar.").foregroundStyle(DS.Palette.textSecondary) }
                ForEach(store.labels) { label in
                    Toggle(isOn: Binding(get: { TaskLabels.normalized(draft["labels"].list, labels: store.labels).contains(.string(label.id)) }, set: { enabled in
                        var labels = TaskLabels.normalized(draft["labels"].list, labels: store.labels).filter { $0 != .string(label.id) }
                        if enabled { labels.append(.string(label.id)) }
                        draft["labels"] = .array(labels)
                    })) { Label(label.name, systemImage: "tag.fill").foregroundStyle(Color.project(label.string("color"))) }
                        .accessibilityIdentifier("taskLabel-" + label.id)
                }
                if !draft["labels"].list.isEmpty {
                    Divider()
                    Button("Remove all labels", role: .destructive) { draft["labels"] = .array([]) }.accessibilityIdentifier("taskRemoveLabels")
                }
            }.padding(DS.Space.l)
        }.frame(width: 260).frame(maxHeight: 360)
    }
}

struct TaskDestinationEditor: View {
    @Environment(Store.self) private var store
    @Binding var draft: Record
    let projectLocked: Bool
    let changeProject: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Picker("Project", selection: Binding(get: { draft.string("project_id") }, set: changeProject)) {
                Text("Inbox").tag("")
                ForEach(store.projects) { Text($0.name).tag($0.id) }
            }.disabled(projectLocked).accessibilityIdentifier("taskProjectPicker")
            if !draft.string("project_id").isEmpty {
                Picker("Section", selection: Binding(get: { draft.string("section_id") }, set: { draft["section_id"] = $0.isEmpty ? .null : .string($0) })) {
                    Text("No section").tag("")
                    ForEach(store.rows("sections").filter { $0.string("project_id") == draft.string("project_id") }) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("taskSectionPicker")
            }
        }.padding(DS.Space.l).frame(width: 300)
    }
}
