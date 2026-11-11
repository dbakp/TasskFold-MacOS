import SwiftUI
import AppKit

/// The Quick Add composer. Top to bottom: priority checkbox and title field (recognised words are highlighted in place),
/// property chips (date, priority, labels, reminders, "+"), the declinable chips for parsed values that have no property
/// chip of their own, warnings and previews, and a footer with the destination and Add Task. See specs/QUICK_ADD.md.
///
/// Values the parser recognised are shown as tinted chips whose "×" declines the token (the words stay in the title).
/// Values chosen by hand live in `Workspace.quickAddManual` and win over parsed tokens: choosing a value for a field the
/// parser also fills treats the matching token group as declined, so the typed words stay as plain text.
struct TaskCapturePanel: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceBinding: WorkspaceBinding?
    @Binding var text: String
    @Binding var declined: Set<String>
    @Binding var choices: [String: String]
    @State private var titleSelection: TextSelection?
    @State private var openChip: DetailChip?
    @State private var repeatExpanded = false
    let prompt: String
    let context: QuickEntryContext
    var task = Record()
    let submit: () -> Void
    /// Closes the composer where `dismiss` has nothing to dismiss (the global floating panel). Defaults to `dismiss`.
    var onClose: (() -> Void)?
    /// Where hand-chosen properties live. The in-app composer shares `Workspace.quickAddManual`; the global panel keeps its own.
    var manualChoices: Binding<[String: JSON]>?
    /// A quiet line of key hints under the footer (the global panel only).
    var hint: String?
    @FocusState private var focused: Bool
    @FocusState private var focusedChip: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fields the composer lets the user set by hand. Everything else comes from the capture defaults or the parser.
    static let manualFields = ["due_date", "due_time", "time_zone", "priority", "labels", "project_id", "section_id", "deadline_date",
                               "duration_minutes", "is_recurring", "recurrence_pattern", "recurrence_end_date", "reminder_specs"]
    /// The parser group that a manual choice for a field replaces.
    private static let supersedes: [String: String] = ["due_date": "due_date", "due_time": "due_time", "priority": "priority", "project_id": "project_id",
                                                       "section_id": "section_id", "deadline_date": "deadline_date", "duration_minutes": "duration_minutes",
                                                       "is_recurring": "recurrence", "recurrence_pattern": "recurrence"]
    /// Parser groups that a set of manual choices has taken over. Shared with `Workspace.add` so the saved task matches the preview.
    static func supersededGroups(_ manual: [String: JSON]) -> Set<String> { Set(manual.keys.compactMap { supersedes[$0] }) }

    // MARK: State

    private var manual: [String: JSON] { manualChoices?.wrappedValue ?? workspace.quickAddManual }
    private func setManual(_ value: [String: JSON]) { if let manualChoices { manualChoices.wrappedValue = value } else { workspace.quickAddManual = value } }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private var baseTask: Record { var base = task; for (field, value) in manual { base[field] = value }; return base }
    private var parseContext: QuickEntryContext {
        var c = context.choosingReferences(choices)
        if let project = manual["project_id"] { c.currentProject = project.text }
        return c
    }
    private var disabledGroups: Set<String> { declined.union(Self.supersededGroups(manual)) }
    private var parsedNow: QuickEntry { QuickEntry(text, disabled: disabledGroups, context: parseContext, task: baseTask) }
    private var effectiveNow: Record { parsedNow.fieldPreview(to: baseTask) }

    /// Editors see the effective task (manual choices over parsed tokens over defaults). A change is stored as a manual choice.
    private var effectiveBinding: Binding<Record> { Binding(get: { effectiveNow }, set: { applyEdit($0, from: effectiveNow) }) }
    /// Editors for list-like values (labels, reminders) see only defaults and manual choices; parsed tokens merge on top and keep their own chips.
    private var manualBinding: Binding<Record> { Binding(get: { baseTask }, set: { applyEdit($0, from: baseTask) }) }
    private func applyEdit(_ new: Record, from old: Record) {
        var m = manual
        for field in Self.manualFields where new[field] != old[field] { m[field] = new[field] }
        setManual(m)
    }
    private func clearManual(_ fields: [String]) {
        var m = manual
        for field in fields { m.removeValue(forKey: field) }
        setManual(m)
    }
    private func chipOpen(_ chip: DetailChip) -> Binding<Bool> {
        Binding(get: { openChip == chip }, set: { if $0 { openChip = chip } else if openChip == chip { openChip = nil } })
    }

    // MARK: Body

    var body: some View {
        let parsed = parsedNow
        let effective = parsed.fieldPreview(to: baseTask)
        let dateTint = effective.due.map { TaskDetailFormat.relativeDay($0).tint } ?? DS.Palette.accent
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack {
                Text("New Task").font(DS.Font.screenTitle)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(DS.Font.taskTitle.weight(.medium)) }
                    .buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close task entry")
            }
            titleField(parsed, effective: effective, dateTint: dateTint)
            if text.isEmpty {
                Text("Try “Call Sam tomorrow at 4pm !30mb p1”").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            }
            propertyChips(parsed, effective: effective)
            let rowTokens = parsed.tokens.filter { !Self.propertyGroups.contains($0.group) }
            if !rowTokens.isEmpty {
                QuickEntryChips(tokens: rowTokens, compact: true, decline: { token in _ = declined.insert(token.group) }, returnFocus: resumeDraftFromChip)
            }
            if let rule = parsed.updates["recurrence_pattern"] {
                Text("Repeat: " + Recurrence.summary(Record(rule.object))).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("quickRepeatSummary")
            }
            ReminderAutomaticPreview(task: effective, showDeliveryGuidance: parsed.updates["reminder_specs"] == nil)
            ForEach(parsed.warnings, id: \.self) { warning in Text(warning).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("quickEntryWarning") }
            if parsed.updates["reminder_specs"] != nil && !store.remindersEnabled {
                Text("Reminders are off on this device. Enable delivery in the task’s Reminders after saving.").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("quickReminderDeliveryOff")
            }
            footer(effective, canAdd: !parsed.title.isEmpty)
            if let hint { Text(hint).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).frame(maxWidth: .infinity).accessibilityIdentifier("quickAddHint") }
        }
        .padding(DS.Space.xxl).frame(width: 540)
        .onAppear { workspaceBinding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); focused = true }
        .task(id: parsed.updates["project_id"]?.text ?? manual["project_id"]?.text ?? context.currentProject) { _ = try? await store.refreshProjectMembers(parsed.updates["project_id"]?.text ?? manual["project_id"]?.text ?? context.currentProject) }
        .onExitCommand { close() }
        .onChange(of: text) { _, value in if value.isEmpty { declined = [] } }
        .onDisappear { if text.isEmpty { setManual([:]) } }
    }

    /// Groups a property chip shows. Their tokens are declined from the chip, not from the row below.
    private static let propertyGroups: Set<String> = ["due_date", "due_time", "recurrence", "priority", "labels"]

    // MARK: Title

    private func titleField(_ parsed: QuickEntry, effective: Record, dateTint: Color) -> some View {
        let priority = effective.priority
        let ring = priority < 4 ? DS.Palette.priority(priority) : DS.Palette.textSecondary
        let spans = QuickAddHighlight.spans(in: text, tokens: parsed.tokens) { QuickEntryChips.tint(for: $0, date: dateTint) }
        return HStack(alignment: .top, spacing: DS.Space.m) {
            Circle().strokeBorder(ring, lineWidth: 1.5).background(ring.opacity(priority < 4 ? 0.15 : 0), in: .circle)
                .frame(width: DS.Size.checkbox, height: DS.Size.checkbox).padding(.top, DS.Space.xs)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, selection: $titleSelection, axis: .vertical)
                .font(.title3 /* capture field is larger than body by design */).lineLimit(2...6).textFieldStyle(.plain)
                .focused($focused).accessibilityIdentifier("quickAdd")
                .overlay { QuickAddHighlightOverlay(text: text, spans: spans).allowsHitTesting(false).accessibilityHidden(true) }
        }
        .padding(DS.Space.l)
        .background(DS.Palette.surface, in: .rect(cornerRadius: DS.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.accent.opacity(focused ? 0.6 : 0.2), lineWidth: 1))
        .referenceCompletions(text: $text, selection: $titleSelection, choices: $choices, declined: $declined, context: parseContext, focused: focused, task: baseTask, onChoose: { focused = true }, submit: submitInWorkspace, submitsFromKeyboard: true)
    }

    // MARK: Property chips

    private struct ChipDecline: Identifiable {
        let id: String
        let help: String
        let action: () -> Void
    }
    private static let declineSize: CGFloat = 14 // matches the declinable row's glyph circle

    private func propertyChips(_ parsed: QuickEntry, effective: Record) -> some View {
        QuickEntryChipLayout(spacing: DS.Space.s) {
            dateChip(parsed, effective)
            priorityChip(parsed, effective)
            labelChips(parsed)
            remindersChip(effective)
            deadlineChip(effective)
            estimateChip(effective)
            moreMenu(effective)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("quickPropertyChips")
    }

    /// One property chip with an optional "×" per parsed token it shows (or one that clears a manual value).
    /// Parsed chips are keyboard reachable like the declinable row: Space or Delete declines, Escape returns to the text.
    private func quickChip(icon: String, text: String?, tint: Color?, trailingIcon: String? = nil, accessibility: String, identifier: String,
                           declines: [ChipDecline] = [], parsedTokens: [QuickEntry.Token] = [], action: @escaping () -> Void) -> some View {
        let focusedHere = focusedChip == identifier
        let tokens = parsedTokens
        return ZStack(alignment: .trailing) {
            PropertyChip(icon: icon, text: text, tint: tint, trailingIcon: trailingIcon, trailingInset: CGFloat(declines.count) * (Self.declineSize + DS.Space.xxs),
                         accessibility: accessibility, identifier: identifier, action: action)
            if !declines.isEmpty {
                HStack(spacing: DS.Space.xxs) {
                    ForEach(declines) { item in
                        Button(action: item.action) {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: Self.declineSize, height: Self.declineSize) // exact optical size for the glyph
                                .background((tint ?? DS.Palette.textSecondary).opacity(0.14), in: .circle)
                        }
                        .buttonStyle(.plain).pointerStyle(.link).foregroundStyle(tint ?? DS.Palette.textSecondary)
                        .help(item.help).accessibilityLabel(item.help).accessibilityIdentifier(item.id)
                    }
                }.padding(.trailing, DS.Space.xs)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder((tint ?? DS.Palette.accent).opacity(focusedHere ? 0.9 : 0), lineWidth: 1.5))
        .focusable(!tokens.isEmpty)
        .focused($focusedChip, equals: identifier)
        .focusEffectDisabled()
        .onKeyPress(.space) { guard !tokens.isEmpty else { return .ignored }; declineAll(tokens); return .handled }
        .onKeyPress(.delete) { guard !tokens.isEmpty else { return .ignored }; declineAll(tokens); return .handled }
        .onKeyPress(.deleteForward) { guard !tokens.isEmpty else { return .ignored }; declineAll(tokens); return .handled }
        .onKeyPress(.return) { guard !tokens.isEmpty else { return .ignored }; action(); return .handled }
        .onKeyPress(.escape) { guard !tokens.isEmpty else { return .ignored }; resumeDraftFromChip(); return .handled }
        .accessibilityElement(children: .contain)
    }
    private func declineAll(_ tokens: [QuickEntry.Token]) {
        for token in tokens { declined.insert(token.group) }
        resumeDraftFromChip()
    }
    private func parsedDecline(_ token: QuickEntry.Token) -> ChipDecline {
        ChipDecline(id: "decline-\(token.group)", help: "Keep “\(token.text)” in the title") { declined.insert(token.group) }
    }

    private func dateChip(_ parsed: QuickEntry, _ effective: Record) -> some View {
        let tokens = parsed.tokens.filter { ["due_date", "due_time", "recurrence"].contains($0.group) }
        let manualFields = ["due_date", "due_time", "time_zone", "is_recurring", "recurrence_pattern", "recurrence_end_date"].filter { manual[$0] != nil }
        // One "×" for the whole date: "tomorrow at 4pm" is one idea, so it is kept in the title together.
        var declines = tokens.first.map { first in
            [ChipDecline(id: "decline-\(first.group)", help: "Keep “\(tokens.map(\.text).joined(separator: " "))” in the title") {
                for token in tokens { declined.insert(token.group) }
            }]
        } ?? []
        if !manualFields.isEmpty { declines.append(ChipDecline(id: "quickClearDate", help: "Clear the chosen date") { clearManual(manualFields) }) }
        let set = effective.due.map { day -> (text: String, tint: Color) in
            let relative = TaskDetailFormat.relativeDay(day)
            let clock = effective.string("due_time").isEmpty ? "" : TaskDetailFormat.clock(effective.string("due_time"))
            return ([relative.text, clock].filter { !$0.isEmpty }.joined(separator: " "), relative.tint)
        }
        let repeats = effective["is_recurring"].flag
        return quickChip(icon: "calendar", text: set?.text ?? "Date", tint: set?.tint, trailingIcon: repeats ? "repeat" : nil,
                         accessibility: set.map { "Date, \($0.text)" + (repeats ? ", repeats" : "") } ?? "Add date", identifier: "quickChipDate",
                         declines: declines, parsedTokens: tokens) { openChip = .date }
            .popover(isPresented: chipOpen(.date), arrowEdge: .bottom) {
                TaskDateEditor(draft: effectiveBinding, repeatExpanded: $repeatExpanded, canRepeat: true, isTeamTask: false, openTeamRepeat: {}, close: { openChip = nil })
            }
    }

    private func priorityChip(_ parsed: QuickEntry, _ effective: Record) -> some View {
        let value = effective.priority
        let set = value < 4
        let tokens = parsed.tokens.filter { $0.group == "priority" }
        var declines = tokens.map(parsedDecline)
        if manual["priority"] != nil, set { declines.append(ChipDecline(id: "quickClearPriority", help: "Clear the chosen priority") { clearManual(["priority"]) }) }
        return quickChip(icon: set ? "flag.fill" : "flag", text: set ? "P\(value)" : "Priority", tint: set ? DS.Palette.priority(value) : nil,
                         accessibility: set ? "Priority, P\(value)" : "Add priority", identifier: "quickChipPriority", declines: declines, parsedTokens: tokens) { openChip = .priority }
            .popover(isPresented: chipOpen(.priority), arrowEdge: .bottom) { TaskPriorityEditor(draft: effectiveBinding, close: { openChip = nil }) }
    }

    private struct LabelEntry {
        var name: String?
        var tint: Color?
        var token: QuickEntry.Token?
        var label: Record?
    }
    @ViewBuilder private func labelChips(_ parsed: QuickEntry) -> some View {
        let tokens = parsed.tokens.filter { $0.group == "labels" }
        let chosen = TaskLabels.normalized(baseTask["labels"].list, labels: store.labels).compactMap { value in store.labels.first { .string($0.id) == value } }
        let entries = tokens.map { LabelEntry(name: $0.label, tint: DS.Palette.label, token: $0) }
            + chosen.map { LabelEntry(name: $0.name, tint: Color.project($0.string("color")), label: $0) }
        // Positional identity keeps the first chip, and the popover anchored to it, alive while labels are toggled.
        ForEach(Array((entries.isEmpty ? [LabelEntry()] : entries).enumerated()), id: \.offset) { index, entry in
            let chip = quickChip(icon: entry.name == nil ? "tag" : "tag.fill", text: entry.name ?? "Labels", tint: entry.tint,
                                 accessibility: entry.name.map { "Label, \($0)" } ?? "Add labels", identifier: index == 0 ? "quickChipLabels" : "quickChipLabels-\(index)",
                                 declines: labelDeclines(entry), parsedTokens: entry.token.map { [$0] } ?? []) { openChip = .label("") }
            if index == 0 { chip.popover(isPresented: chipOpen(.label("")), arrowEdge: .bottom) { TaskLabelsEditor(draft: manualBinding) } }
            else { chip }
        }
    }
    private func labelDeclines(_ entry: LabelEntry) -> [ChipDecline] {
        if let token = entry.token { return [parsedDecline(token)] }
        guard manual["labels"] != nil, let label = entry.label else { return [] }
        return [ChipDecline(id: "quickClearLabel-" + label.id, help: "Remove label “\(label.name)”") {
            var base = baseTask
            base["labels"] = .array(TaskLabels.normalized(base["labels"].list, labels: store.labels).filter { $0 != .string(label.id) })
            applyEdit(base, from: baseTask)
        }]
    }

    private func remindersChip(_ effective: Record) -> some View {
        let count = ReminderSpec.rows(effective).compactMap { ReminderSpec(row: $0) }.filter(\.enabled).count
        return quickChip(icon: count > 0 ? "bell.fill" : "bell", text: count > 0 ? "\(count)" : "Reminders", tint: count > 0 ? DS.Palette.accent : nil,
                         accessibility: count > 0 ? "Reminders, \(count)" : "Add reminders", identifier: "quickChipReminders") { openChip = .reminders }
            .popover(isPresented: chipOpen(.reminders), arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    TaskReminderEditor(task: manualBinding)
                    Divider()
                    HStack { Spacer(); Button("Done") { openChip = nil }.keyboardShortcut(.defaultAction) }.padding(DS.Space.m)
                }.frame(width: 520, height: 600)
            }
    }

    /// A chosen deadline or estimate. A parsed one stays in the declinable row below.
    @ViewBuilder private func deadlineChip(_ effective: Record) -> some View {
        if manual["deadline_date"] != nil, let day = effective.deadline {
            let past = Calendar.current.startOfDay(for: day) < Calendar.current.startOfDay(for: Date())
            quickChip(icon: "flag.checkered", text: "Deadline " + TaskDetailFormat.relativeDay(day, completed: true).text, tint: past ? DS.Palette.danger : DS.Palette.dateTomorrow,
                      accessibility: "Deadline, " + TaskDetailFormat.relativeDay(day).text, identifier: "quickChipDeadline",
                      declines: [ChipDecline(id: "quickClearDeadline", help: "Clear the chosen deadline") { clearManual(["deadline_date"]) }]) { openChip = .deadline }
                .popover(isPresented: chipOpen(.deadline), arrowEdge: .bottom) { TaskDeadlineEditor(draft: effectiveBinding, close: { openChip = nil }) }
        }
    }
    @ViewBuilder private func estimateChip(_ effective: Record) -> some View {
        if manual["duration_minutes"] != nil, let minutes = effective.durationMinutes {
            quickChip(icon: "hourglass", text: TaskDetailFormat.estimate(minutes), tint: DS.Palette.textSecondary, accessibility: "Estimate, \(TaskDetailFormat.estimate(minutes))", identifier: "quickChipEstimate",
                      declines: [ChipDecline(id: "quickClearEstimate", help: "Clear the chosen estimate") { clearManual(["duration_minutes"]) }]) { openChip = .estimate }
                .popover(isPresented: chipOpen(.estimate), arrowEdge: .bottom) { TaskEstimateEditor(draft: effectiveBinding, close: { openChip = nil }) }
        }
    }

    @ViewBuilder private func moreMenu(_ effective: Record) -> some View {
        let canDeadline = effective.deadline == nil, canEstimate = effective.durationMinutes == nil, canRepeat = !effective["is_recurring"].flag
        if canDeadline || canEstimate || canRepeat {
            Menu {
                if canDeadline { Button("Deadline", systemImage: "flag.checkered") { setField("deadline_date", .string(Dates.day(Date()))); DispatchQueue.main.async { openChip = .deadline } } }
                if canEstimate { Button("Estimate", systemImage: "hourglass") { setField("duration_minutes", .number(30)); DispatchQueue.main.async { openChip = .estimate } } }
                if canRepeat { Button("Repeat", systemImage: "repeat") { repeatExpanded = true; openChip = .date } }
            } label: { ChipLabel(icon: "plus") }
            // The button menu style keeps the outlined chip label; borderless would strip it to a bare glyph.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Add property").accessibilityLabel("Add property").accessibilityIdentifier("quickChipMore")
        }
    }
    private func setField(_ field: String, _ value: JSON) {
        var record = effectiveNow
        record[field] = value
        applyEdit(record, from: effectiveNow)
    }

    // MARK: Footer

    private func destinationText(_ effective: Record) -> String {
        guard let project = store.record("projects", id: effective.string("project_id")) else { return "Inbox" }
        let section = effective.string("section_id").isEmpty ? nil : store.record("sections", id: effective.string("section_id"))?.name
        return [project.name, section].compactMap { $0 }.joined(separator: " / ")
    }

    private func footer(_ effective: Record, canAdd: Bool) -> some View {
        let name = destinationText(effective)
        return HStack {
            Button { openChip = .destination } label: {
                Label { Text("# " + name).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) } icon: { Image(systemName: effective.string("project_id").isEmpty ? "tray" : "folder").accessibilityHidden(true) }
                    .font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).contentShape(.rect)
            }
            .buttonStyle(.plain).pointerStyle(.link).help("Choose project and section")
            .accessibilityLabel("Destination, \(name)").accessibilityIdentifier("quickDestination")
            .popover(isPresented: chipOpen(.destination), arrowEdge: .bottom) {
                TaskDestinationEditor(draft: effectiveBinding, projectLocked: false, changeProject: { id in
                    var record = effectiveNow
                    record["project_id"] = id.isEmpty ? .null : .string(id)
                    record["section_id"] = .null
                    applyEdit(record, from: effectiveNow)
                })
            }
            Spacer()
            Button("Add Task", action: submitInWorkspace).buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction).disabled(!canAdd)
        }
    }

    private func resumeDraftFromChip() {
        let draft = text
        focused = true
        // AppKit selects the entire field when it becomes first responder again.
        // Restore an insertion point after that update so typing keeps the draft.
        DispatchQueue.main.async {
            guard focused, text == draft else { return }
            titleSelection = TextSelection(insertionPoint: text.endIndex)
        }
    }

    private func submitInWorkspace() {
        guard workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true else { store.error = "The workspace changed. Close this capture and open it in the current workspace."; return }
        submit()
    }
}

#if DEBUG
/// Hosts the composer pre-filled with `text` for the offscreen `--capture-quick-add` debug option.
struct QuickAddCaptureHost: View {
    @Environment(Workspace.self) private var workspace
    @State var text: String
    @State private var declined = Set<String>()
    @State private var choices = [String: String]()
    var body: some View {
        TaskCapturePanel(text: $text, declined: $declined, choices: $choices, prompt: "Add a task for today — try “Call Sam at 4pm p1 #calls”",
                         context: workspace.quickEntryContext(), task: workspace.captureTask(date: Date()), submit: {})
    }
}
#endif
