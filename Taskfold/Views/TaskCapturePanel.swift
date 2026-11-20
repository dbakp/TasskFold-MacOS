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
    /// Place names this account asked for before, read once when the composer opens.
    @State private var placeNames: [String] = []
    @FocusState private var focused: Bool
    /// The text this composer opened with when it came back from an unsent draft; nil once edited or cleared.
    @State private var restoredDraft: String?
    @State private var selectAllMonitor: Any?
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
    /// "at Home" asks the iPhone for its place called Home (D3). Only the name and direction sync; the Mac has no places.
    private func typedPlace(_ parsed: QuickEntry) -> QuickPlaceRequest? {
        guard !declined.contains("place") else { return nil }
        return QuickPlaceRequest.find(in: parsed.title, known: placeNames)
    }
    private func placeTokens(_ parsed: QuickEntry) -> [QuickEntry.Token] {
        guard let found = typedPlace(parsed), found.applies(accepted: choices[QuickPlaceRequest.acceptKey]), !found.title.isEmpty else { return [] }
        return [QuickEntry.Token(group: "place", text: found.raw, label: found.label + " · on iPhone")]
    }

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
        // One panel, Things-style Quick Entry (design review mac-r1): the field is the title, one quiet row shows what will
        // be saved, and the footer holds the destination and Add. Esc closes.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                titleField(parsed, effective: effective, dateTint: dateTint)
                tokenRow(parsed, effective: effective).padding(.leading, DS.Size.checkbox + DS.Space.m)
                placeOffer(parsed).padding(.leading, DS.Size.checkbox + DS.Space.m)
                if restoredDraft != nil { draftNotice.padding(.leading, DS.Size.checkbox + DS.Space.m) }
                ForEach(parsed.warnings, id: \.self) { warning in
                    Text(warning).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).padding(.leading, DS.Size.checkbox + DS.Space.m).accessibilityIdentifier("quickEntryWarning")
                }
            }
            .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.xl).padding(.bottom, DS.Space.l)
            Divider()
            footer(effective, canAdd: !parsed.title.isEmpty)
                .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
        }
        .frame(width: 560)
        .background {
            // ⇧⌘B turns the draft into a Brain dump (also File ▸ Brain Dump…).
            if onClose == nil {
                Button("Brain dump") { brainDump(effective) }.keyboardShortcut("b", modifiers: [.command, .shift]).hidden().accessibilityHidden(true)
            }
        }
        .onAppear {
            workspaceBinding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); focused = true; placeNames = LocationPlaceRequest.knownNames(in: store.rows("tasks"))
            if QuickAddDraftNotice.isRestored(openingText: text) { restoredDraft = text }
            installSelectAll()
        }
        .task(id: parsed.updates["project_id"]?.text ?? manual["project_id"]?.text ?? context.currentProject) { _ = try? await store.refreshProjectMembers(parsed.updates["project_id"]?.text ?? manual["project_id"]?.text ?? context.currentProject) }
        .onExitCommand { close() }
        .onChange(of: text) { _, value in
            if value.isEmpty { declined = [] }
            if value != restoredDraft { restoredDraft = nil }
        }
        .onDisappear {
            if text.isEmpty { setManual([:]) }
            if let selectAllMonitor { NSEvent.removeMonitor(selectAllMonitor) }; selectAllMonitor = nil
        }
    }
    /// "Draft restored · Clear": an unsent draft from an earlier session is shown as such, and one click discards it.
    private var draftNotice: some View {
        HStack(spacing: DS.Space.xs) {
            Text("Draft restored ·").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            Button("Clear") {
                text = ""; declined = []; choices = [:]; setManual([:]); restoredDraft = nil; focused = true
            }.buttonStyle(.plain).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.accent).pointerStyle(.link).accessibilityIdentifier("quickAddClearDraft")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("quickAddDraftRestored")
    }
    /// ⌘A selects the title text while the field editor is active. Without this the Select All menu item can go to the
    /// window's list instead of the field, so the field handles `selectAll:` first.
    private func installSelectAll() {
        guard selectAllMonitor == nil else { return }
        selectAllMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "a",
                  let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor || editor.isEditable else { return event }
            editor.selectAll(nil)
            return nil
        }
    }
    private func brainDump(_ effective: Record) {
        // The composer closes first, so the Brain dump sheet is presented by the window itself.
        let draft = text, project = effective.string("project_id")
        close()
        DispatchQueue.main.async { workspace.openBrainDump(project: project, text: draft) }
    }

    /// "at the gym" with a name this account never used: offered, not taken, so "Look at Bob" keeps its words.
    @ViewBuilder private func placeOffer(_ parsed: QuickEntry) -> some View {
        if let found = typedPlace(parsed), !found.applies(accepted: choices[QuickPlaceRequest.acceptKey]), !found.title.isEmpty {
            Button { choices[QuickPlaceRequest.acceptKey] = found.raw; resumeDraftFromChip() } label: {
                Label("Remind me at “" + found.name + "” on iPhone", systemImage: "plus").font(DS.Font.chip)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(DS.Palette.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain).pointerStyle(.link).foregroundStyle(DS.Palette.textSecondary)
            .help("Your iPhone reminds you at its place called " + found.name + ". Only the name syncs.")
            .accessibilityLabel("Remind me at " + found.name + " on iPhone").accessibilityIdentifier("quickPlaceOffer")
        }
    }

    /// Groups a property chip shows. Their tokens are declined from the chip, not from the row below.
    private static let propertyGroups: Set<String> = ["due_date", "due_time", "recurrence", "priority", "labels"]

    // MARK: Title

    private func titleField(_ parsed: QuickEntry, effective: Record, dateTint: Color) -> some View {
        let priority = effective.priority
        let ring = priority < 4 ? DS.Palette.priority(priority) : DS.Palette.textSecondary
        let spans = QuickAddHighlight.spans(in: text, tokens: parsed.tokens + placeTokens(parsed)) { QuickEntryChips.tint(for: $0, date: dateTint) }
        return HStack(alignment: .top, spacing: DS.Space.m) {
            Circle().strokeBorder(ring, lineWidth: 1.5).background(ring.opacity(priority < 4 ? 0.15 : 0), in: .circle)
                .frame(width: DS.Size.checkbox, height: DS.Size.checkbox).padding(.top, 2)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, selection: $titleSelection, axis: .vertical)
                .font(.system(size: 17) /* the capture field is the title: 17 pt by design */).lineLimit(1...6).textFieldStyle(.plain)
                .focused($focused).accessibilityIdentifier("quickAdd")
                .overlay { QuickAddHighlightOverlay(text: text, spans: spans).allowsHitTesting(false).accessibilityHidden(true) }
        }
        .referenceCompletions(text: $text, selection: $titleSelection, choices: $choices, declined: $declined, context: parseContext, focused: focused, task: baseTask, onChoose: { focused = true }, submit: submitInWorkspace, submitsFromKeyboard: true)
    }

    // MARK: Property chips

    private struct ChipDecline: Identifiable {
        let id: String
        let help: String
        let action: () -> Void
    }
    private static let declineSize: CGFloat = 14 // matches the declinable row's glyph circle

    /// What will be saved, once: set properties and recognised words as quiet chips (click to edit, × keeps the words), then
    /// "+" for anything not set yet. The project is in the footer, so it is not repeated here.
    private func tokenRow(_ parsed: QuickEntry, effective: Record) -> some View {
        let others = parsed.tokens.filter { !Self.propertyGroups.contains($0.group) && !["project_id", "section_id"].contains($0.group) } + placeTokens(parsed)
        let manualReminders = ReminderSpec.rows(baseTask).compactMap { ReminderSpec(row: $0) }.filter(\.enabled).count
        let hasReminder = manualReminders > 0 || others.contains { $0.group.hasPrefix("reminder_specs") }
        return QuickEntryChipLayout(spacing: DS.Space.s) {
            if effective.due != nil || effective["is_recurring"].flag { dateChip(parsed, effective) }
            if effective.priority < 4 { priorityChip(parsed, effective) }
            labelChips(parsed)
            if manualReminders > 0 { remindersChip(effective) }
            deadlineChip(effective)
            estimateChip(effective)
            ForEach(others) { token in
                quickChip(icon: QuickEntryChips.symbol(for: token.group), text: Self.display(token), tint: DS.Palette.textPrimary,
                          accessibility: "\(QuickEntryChips.name(for: token.group).capitalized) \(Self.display(token)), from “\(token.text)”", identifier: "chip-\(token.group)",
                          declines: [ChipDecline(id: "decline-\(token.group)", help: "Keep “\(token.text)” in the title") {
                              declined.insert(token.group)
                              if token.group == "place" { choices[QuickPlaceRequest.acceptKey] = nil }
                          }], parsedTokens: [token]) { if token.group.hasPrefix("reminder_specs") { openChip = .reminders } }
            }
            if let rule = parsed.updates["recurrence_pattern"] {
                ChipLabel(icon: "repeat", text: Recurrence.summary(Record(rule.object)), tint: DS.Palette.textPrimary)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Repeat, " + Recurrence.summary(Record(rule.object)))
                    .accessibilityValue(Recurrence.summary(Record(rule.object)))
                    .accessibilityIdentifier("quickRepeatSummary")
            }
            if hasReminder && !store.remindersEnabled {
                Image(systemName: "bell.slash").font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary).frame(minHeight: 22)
                    .help("Reminders are off on this Mac. Turn on delivery in Settings ▸ General.")
                    .accessibilityLabel("Reminder delivery is off on this Mac").accessibilityIdentifier("quickReminderDeliveryOff")
            }
            moreMenu(effective)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("quickPropertyChips")
        .popover(isPresented: chipOpen(.date), arrowEdge: .bottom) {
            TaskDateEditor(draft: effectiveBinding, repeatExpanded: $repeatExpanded, canRepeat: true, isTeamTask: false, openTeamRepeat: {}, close: { openChip = nil })
        }
        .popover(isPresented: chipOpen(.priority), arrowEdge: .bottom) { TaskPriorityEditor(draft: effectiveBinding, close: { openChip = nil }) }
        .popover(isPresented: chipOpen(.label("")), arrowEdge: .bottom) { TaskLabelsEditor(draft: manualBinding) }
        .popover(isPresented: chipOpen(.reminders), arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TaskReminderEditor(task: manualBinding)
                Divider()
                HStack { Spacer(); Button("Done") { openChip = nil }.keyboardShortcut(.defaultAction) }.padding(DS.Space.m)
            }.frame(width: 520, height: 600)
        }
        .popover(isPresented: chipOpen(.deadline), arrowEdge: .bottom) { TaskDeadlineEditor(draft: effectiveBinding, close: { openChip = nil }) }
        .popover(isPresented: chipOpen(.estimate), arrowEdge: .bottom) { TaskEstimateEditor(draft: effectiveBinding, close: { openChip = nil }) }
    }
    /// "Remind 19 Nov 2026 at 18.45" reads as "Remind me 18.45 today".
    static func display(_ token: QuickEntry.Token) -> String {
        guard token.group.hasPrefix("reminder_specs"), token.label.hasPrefix("Remind ") else { return token.label }
        let rest = String(token.label.dropFirst("Remind ".count))
        guard let date = try? Date(rest, strategy: Date.FormatStyle(date: .abbreviated, time: .shortened)) else { return "Remind me " + rest }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = calendar.isDateInToday(date) ? "today" : calendar.isDateInTomorrow(date) ? "tomorrow" : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "Remind me \(time) \(day)"
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
    }

    private func priorityChip(_ parsed: QuickEntry, _ effective: Record) -> some View {
        let value = effective.priority
        let set = value < 4
        let tokens = parsed.tokens.filter { $0.group == "priority" }
        var declines = tokens.map(parsedDecline)
        if manual["priority"] != nil, set { declines.append(ChipDecline(id: "quickClearPriority", help: "Clear the chosen priority") { clearManual(["priority"]) }) }
        return quickChip(icon: set ? "flag.fill" : "flag", text: set ? "P\(value)" : "Priority", tint: set ? DS.Palette.priority(value) : nil,
                         accessibility: set ? "Priority, P\(value)" : "Add priority", identifier: "quickChipPriority", declines: declines, parsedTokens: tokens) { openChip = .priority }
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
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
            let chip = quickChip(icon: entry.name == nil ? "tag" : "tag.fill", text: entry.name ?? "Labels", tint: entry.tint,
                                 accessibility: entry.name.map { "Label, \($0)" } ?? "Add labels", identifier: index == 0 ? "quickChipLabels" : "quickChipLabels-\(index)",
                                 declines: labelDeclines(entry), parsedTokens: entry.token.map { [$0] } ?? []) { openChip = .label("") }
            chip
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
        let count = ReminderSpec.rows(baseTask).compactMap { ReminderSpec(row: $0) }.filter(\.enabled).count
        return quickChip(icon: count > 0 ? "bell.fill" : "bell", text: count == 1 ? "1 reminder" : "\(count) reminders", tint: DS.Palette.textPrimary,
                         accessibility: count > 0 ? "Reminders, \(count)" : "Add reminders", identifier: "quickChipReminders") { openChip = .reminders }
    }

    /// A chosen deadline or estimate. A parsed one stays in the declinable row below.
    @ViewBuilder private func deadlineChip(_ effective: Record) -> some View {
        if manual["deadline_date"] != nil, let day = effective.deadline {
            let past = Calendar.current.startOfDay(for: day) < Calendar.current.startOfDay(for: Date())
            quickChip(icon: "flag.checkered", text: "Deadline " + TaskDetailFormat.relativeDay(day, completed: true).text, tint: past ? DS.Palette.danger : DS.Palette.dateTomorrow,
                      accessibility: "Deadline, " + TaskDetailFormat.relativeDay(day).text, identifier: "quickChipDeadline",
                      declines: [ChipDecline(id: "quickClearDeadline", help: "Clear the chosen deadline") { clearManual(["deadline_date"]) }]) { openChip = .deadline }
        }
    }
    @ViewBuilder private func estimateChip(_ effective: Record) -> some View {
        if manual["duration_minutes"] != nil, let minutes = effective.durationMinutes {
            quickChip(icon: "hourglass", text: TaskDetailFormat.estimate(minutes), tint: DS.Palette.textSecondary, accessibility: "Estimate, \(TaskDetailFormat.estimate(minutes))", identifier: "quickChipEstimate",
                      declines: [ChipDecline(id: "quickClearEstimate", help: "Clear the chosen estimate") { clearManual(["duration_minutes"]) }]) { openChip = .estimate }
        }
    }

    private func moreMenu(_ effective: Record) -> some View {
        Menu {
            if effective.due == nil { Button("Date", systemImage: "calendar") { openChip = .date } }
            if effective.priority == 4 { Button("Priority", systemImage: "flag") { openChip = .priority } }
            Button("Labels", systemImage: "tag") { openChip = .label("") }
            Button("Reminder", systemImage: "bell") { openChip = .reminders }
            if effective.deadline == nil { Button("Deadline", systemImage: "flag.checkered") { setField("deadline_date", .string(Dates.day(Date()))); DispatchQueue.main.async { openChip = .deadline } } }
            if effective.durationMinutes == nil { Button("Estimate", systemImage: "hourglass") { setField("duration_minutes", .number(30)); DispatchQueue.main.async { openChip = .estimate } } }
            if !effective["is_recurring"].flag { Button("Repeat", systemImage: "repeat") { repeatExpanded = true; openChip = .date } }
        } label: {
            Image(systemName: "plus").font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary).frame(width: 22, height: 22).contentShape(.rect)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(DS.Palette.textSecondary)
        .help("Add a date, priority, labels, a reminder…").accessibilityLabel("Add property").accessibilityIdentifier("quickChipMore")
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
        let project = store.record("projects", id: effective.string("project_id"))
        return HStack(spacing: DS.Space.m) {
            Button { openChip = .destination } label: {
                HStack(spacing: DS.Space.s) {
                    if let project { Circle().fill(DS.Palette.project(project).color).frame(width: 7, height: 7) }
                    else { Image(systemName: "tray").font(DS.Font.chip) }
                    Text(name).lineLimit(1)
                    Image(systemName: "chevron.down").font(DS.Font.badge).foregroundStyle(DS.Palette.textTertiary)
                }
                .font(DS.Font.taskTitle).foregroundStyle(DS.Palette.textPrimary).contentShape(.rect)
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
            Text(hint ?? "⏎ Add · ⌘⏎ Add another").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textTertiary).lineLimit(1).accessibilityIdentifier("quickAddHint")
            Button("Add", action: submitInWorkspace).buttonStyle(.borderedProminent).tint(Color(brand: Brand.crimsonFill))
                .keyboardShortcut(.defaultAction).disabled(!canAdd).accessibilityIdentifier("quickAddSubmit")
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
    // --quick-add-place="at Home" shows a new place name as accepted, as after clicking its offer.
    @State private var choices = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--quick-add-place=") }
        .map { [QuickPlaceRequest.acceptKey: String($0.dropFirst("--quick-add-place=".count))] } ?? [:]
    var body: some View {
        TaskCapturePanel(text: $text, declined: $declined, choices: $choices, prompt: "Add a task for today — try “Call Sam at 4pm p1 #calls”",
                         context: workspace.quickEntryContext(), task: workspace.captureTask(date: Date()), submit: {})
    }
}
#endif
