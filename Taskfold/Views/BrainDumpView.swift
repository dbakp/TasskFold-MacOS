import SwiftUI

/// Brain dump: a messy paragraph becomes a reviewed list of tasks. One file for both apps.
/// Text is sorted on this device (the system model when available, simple rules otherwise), every phrase is read by
/// the ordinary Quick Add parser, and nothing is saved until "Add N tasks", which is one undo group.
/// All rules live in Core/BrainDump.swift.

/// A small badge that says nothing leaves the device. Shown wherever an AI-assisted action appears (Brain dump,
/// Suggest steps, Smart reschedule, Suggest a filter); its words come from PrivacyFacts so every screen matches.
struct OnDeviceBadge: View {
    var body: some View {
        Label(PrivacyFacts.badgeLabel, systemImage: "lock.fill")
            .font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            .background(DS.Palette.surfaceSunken, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PrivacyFacts.badgeAccessibilityLabel)
            .accessibilityIdentifier(PrivacyFacts.badgeIdentifier)
    }
}

/// The sheet frame both reviews share. On iOS a navigation bar carries Cancel and the primary action; on the Mac a
/// title row and a footer do, like the other dialogs, so the whole sheet is one view.
struct OnDeviceSheetShell<Content: View>: View {
    let title: String
    let cancelIdentifier: String
    var primaryTitle: String?
    var primaryIdentifier = ""
    var primaryEnabled = true
    var primaryValue = ""
    var primaryHint = ""
    let cancel: () -> Void
    var primary: () -> Void = {}
    @ViewBuilder let content: Content
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack { Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader); Spacer() }
                .padding(.horizontal, DS.Space.xxl).padding(.top, DS.Space.xl).padding(.bottom, DS.Space.s)
            content
            Divider()
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier(cancelIdentifier)
                Spacer()
                if let primaryTitle {
                    Button(primaryTitle, action: primary).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(DS.Palette.accentFill)
                        .disabled(!primaryEnabled).accessibilityValue(primaryValue).accessibilityHint(primaryHint).accessibilityIdentifier(primaryIdentifier)
                }
            }.padding(.horizontal, DS.Space.xxl).padding(.vertical, DS.Space.m)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        NavigationStack {
            content
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).accessibilityIdentifier(cancelIdentifier) }
                    ToolbarItem(placement: .confirmationAction) {
                        if let primaryTitle {
                            Button(primaryTitle, action: primary).tint(DS.Palette.accentFill).disabled(!primaryEnabled).accessibilityValue(primaryValue).accessibilityHint(primaryHint).accessibilityIdentifier(primaryIdentifier)
                        }
                    }
                }
        }
        #endif
    }
}

struct BrainDumpView: View {
    let request: BrainDumpRequest
    /// Called with the number of tasks added, after the commit succeeded.
    var onAdded: (Int) -> Void = { _ in }
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @FocusState private var editing: Bool
    @State private var generation: BrainDumpSession
    @State private var text = ""
    @State private var rows: [BrainDumpReview.Row] = []
    @State private var reviewing = false
    @State private var work: Task<Void, Never>?
    @State private var busy = false
    @State private var note: String?
    @State private var omitted = 0
    @State private var error: String?
    @State private var applied = false
    @State private var voiceRequest: VoiceDraftRequest?
    @State private var started = false

    init(request: BrainDumpRequest, onAdded: @escaping (Int) -> Void = { _ in }) {
        self.request = request; self.onAdded = onAdded
        _generation = State(initialValue: BrainDumpSession(request: request))
    }
    private var session: UUID { store.backend.reminderSessionIncarnation }
    private var workspaceBinding: WorkspaceBinding { .init(account: store.userID, generation: store.workspaceGeneration) }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    private var inputProblem: String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try BrainDump.input(text); return nil } catch { return error.localizedDescription }
    }
    private var readyToSort: Bool { !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inputProblem == nil }
    private func parsed(_ text: String) -> BrainDump.Parsed {
        BrainDump.parse(text, account: store.userID, project: request.project, context: store.quickEntryContext(project: request.project))
    }
    private var addable: Int { BrainDumpReview.items(rows, parsed: parsed).count }
    private var destination: String { store.record("projects", id: request.project)?.name ?? "Inbox" }

    var body: some View {
        OnDeviceSheetShell(title: "Brain dump", cancelIdentifier: "brainDumpCancel",
                           primaryTitle: reviewing ? BrainDump.summary(count: addable) : nil, primaryIdentifier: "brainDumpAdd",
                           primaryEnabled: !(busy || applied || addable == 0), cancel: { close(); dismiss() }, primary: { add() }) {
            Form {
                if reviewing { reviewSections } else { inputSections }
                if let error { Section { Text(error).foregroundStyle(DS.Palette.danger).accessibilityIdentifier("brainDumpError") } }
            }
            .scrollDismissesKeyboard(.interactively)
            .formStyle(.grouped)
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 440, idealHeight: 640)
        #endif
        .task {
            guard !started else { return }
            started = true
            if text.isEmpty { text = request.initialText }
            #if DEBUG
            // Fixture launches open straight onto the review with the deterministic splitter, never running inference.
            if BrainDumpFixture.review { text = BrainDumpFixture.text; sort() }
            #endif
        }
        .sheet(item: $voiceRequest) { request in
            VoiceDraftView(request: request) { proposed in
                guard store.workflowReady(request.workspace), request.matchesOriginal(text) else { return false }
                text = proposed; return true
            }
        }
        .onChange(of: store.workspaceGeneration) { _, _ in close(); voiceRequest = nil; dismiss() }
        .onChange(of: phase) { _, value in if value == .background { stop() } }
        .onChange(of: text) { _, _ in if error != nil { error = nil } }
        .onChange(of: error) { _, value in if let value { AccessibilityNotification.Announcement(value).post() } }
        .onDisappear { close() }
    }

    // MARK: Input

    @ViewBuilder private var inputSections: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                OnDeviceBadge()
                Text("Speak or paste a messy paragraph. It’s sorted into separate tasks on this device, and you review every one before anything is added.")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            Button("Dictate", systemImage: "mic") {
                guard store.workflowReady(request.workspace) else { error = store.error; return }
                #if os(iOS)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
                voiceRequest = VoiceDraftRequest(workspace: request.workspace, original: text)
            }.disabled(busy).accessibilityIdentifier("brainDumpDictate")
            TextEditor(text: $text).frame(minHeight: 170).focused($editing).disabled(busy)
                .accessibilityLabel("Brain dump text").accessibilityIdentifier("brainDumpText")
            HStack {
                if let inputProblem { Text(inputProblem).foregroundStyle(DS.Palette.danger).font(.caption).accessibilityIdentifier("brainDumpInputWarning") }
                Spacer()
                Text("\(text.count) of \(BrainDump.maximumInputCharacters)").font(.caption).monospacedDigit()
                    .foregroundStyle(text.count > BrainDump.maximumInputCharacters ? DS.Palette.danger : DS.Palette.textSecondary)
                    .accessibilityLabel("\(text.count) of \(BrainDump.maximumInputCharacters) characters")
            }
        }
        Section {
            if let reason = BrainDumpEngine.unavailableReason {
                Label { Text("Sorted with simple rules on this device. " + reason) } icon: { Image(systemName: "lock.fill") }
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("brainDumpUnavailable")
            }
            if busy {
                ProgressView("Sorting into tasks…").accessibilityIdentifier("brainDumpProgress")
                Button("Stop") { stop() }.accessibilityIdentifier("brainDumpStop")
            } else {
                Button("Sort into tasks", systemImage: "sparkles") { sort() }
                    .disabled(!readyToSort).accessibilityIdentifier("brainDumpSort")
            }
        }
    }

    // MARK: Review

    @ViewBuilder private var reviewSections: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                OnDeviceBadge()
                Text("Edit a task, switch it off or move it. Dates, priorities and projects are read from each line the way Quick Add reads them.")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            if let note { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("brainDumpNote") }
        }
        Section {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in reviewRow(row, position: index + 1) }
        } header: {
            Text("\(rows.count) proposed \(rows.count == 1 ? "task" : "tasks") · adds to \(destination)").textCase(nil)
        } footer: {
            if omitted > 0 { Text("\(omitted) more \(omitted == 1 ? "item was" : "items were") left out to keep the list to \(BrainDump.maximumTasks).").accessibilityIdentifier("brainDumpOmitted") }
        }
        Section {
            Button("Edit original text") { stop(); withAnimation(layout) { reviewing = false; rows = []; note = nil; omitted = 0 } }
                .accessibilityIdentifier("brainDumpEditOriginal")
        }
    }

    private func rowBinding<Value>(_ row: BrainDumpReview.Row, _ path: WritableKeyPath<BrainDumpReview.Row, Value>) -> Binding<Value> {
        Binding(get: { rows.first { $0.id == row.id }?[keyPath: path] ?? row[keyPath: path] }, set: { value in
            guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
            rows[index][keyPath: path] = value
        })
    }
    private func reviewRow(_ row: BrainDumpReview.Row, position: Int) -> some View {
        let item = parsed(row.text)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                Toggle("Include task \(position)", isOn: rowBinding(row, \.included)).labelsHidden()
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #else
                    .toggleStyle(RoundCheckToggleStyle())
                    #endif
                    .accessibilityLabel("Include task \(position)").accessibilityIdentifier("brainDumpInclude-\(position)")
                TextField("Task", text: rowBinding(row, \.text), axis: .vertical).lineLimit(1...4).fixedSize(horizontal: false, vertical: true).focused($editing).labelsHidden()
                    .strikethrough(!row.included).foregroundStyle(row.included ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                    .accessibilityLabel("Task \(position)").accessibilityIdentifier("brainDumpRowText-\(position)")
                Menu {
                    Button("Move up", systemImage: "arrow.up") { move(row, by: -1) }.disabled(position == 1).accessibilityIdentifier("brainDumpMoveUp-\(position)")
                    Button("Move down", systemImage: "arrow.down") { move(row, by: 1) }.disabled(position == rows.count).accessibilityIdentifier("brainDumpMoveDown-\(position)")
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) { withAnimation(layout) { rows.removeAll { $0.id == row.id } } }
                        .accessibilityIdentifier("brainDumpRemove-\(position)")
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                .buttonStyle(.borderless).accessibilityLabel("Options for task \(position)").accessibilityIdentifier("brainDumpOptions-\(position)")
            }
            if row.included {
                if !item.chips.isEmpty || !item.isValid {
                    QuickEntryChipLayout(spacing: DS.Space.xs) {
                        ForEach(item.chips) { chip in BrainDumpChip(chip: chip) }
                        if !item.isValid { Text("Add a title").font(DS.Font.chip).foregroundStyle(DS.Palette.danger) }
                    }
                }
                ForEach(item.warnings, id: \.self) { Text($0).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary) }
            } else {
                Text("Won’t be added").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrainDump.accessibilityLabel(position: position, count: rows.count, title: item.task.title, chips: item.chips) + (row.included ? "" : ", not included"))
        .accessibilityIdentifier("brainDumpRow-\(position)")
    }
    private func move(_ row: BrainDumpReview.Row, by offset: Int) {
        guard !busy, !applied, let position = BrainDumpReview.move(row.id, by: offset, in: &rows) else { return }
        AccessibilityNotification.Announcement("Moved to position \(position + 1) of \(rows.count)").post()
    }

    // MARK: Sorting

    private func sort() {
        error = nil
        let source: String
        do { source = try BrainDump.input(text) } catch { self.error = error.localizedDescription; return }
        guard store.workflowReady(request.workspace), let token = generation.begin(workspace: workspaceBinding, session: session) else {
            error = store.error ?? "The workspace changed. Reopen Brain dump."; return
        }
        busy = true
        if let reason = BrainDumpEngine.unavailableReason { finishWithRules(source, token: token, note: "Sorted with simple rules on this device. " + reason); return }
        work = Task {
            do {
                let phrases = try await BrainDumpEngine.generate(source)
                guard !Task.isCancelled, let checked = try generation.receive(phrases, token: token, workspace: workspaceBinding, session: session) else { return }
                show(checked, note: nil)
            } catch {
                guard !Task.isCancelled, generation.token == token else { return }
                finishWithRules(source, token: token, note: "The on-device model couldn’t sort this text, so simple rules were used instead.")
            }
        }
    }
    private func finishWithRules(_ source: String, token: UUID, note: String) {
        let split = BrainDump.split(source)
        do {
            guard let checked = try generation.receive(split.phrases, token: token, workspace: workspaceBinding, session: session) else { return }
            show(BrainDump.Phrases(phrases: checked.phrases, omitted: split.omitted), note: note)
        } catch {
            generation.stop(); busy = false; work = nil; self.error = error.localizedDescription
        }
    }
    private func show(_ phrases: BrainDump.Phrases, note: String?) {
        rows = phrases.phrases.map { BrainDumpReview.Row(text: $0) }
        omitted = phrases.omitted; self.note = note; busy = false; work = nil
        withAnimation(layout) { reviewing = true }
        AccessibilityNotification.Announcement("\(rows.count) tasks ready to review").post()
    }
    private func stop() { work?.cancel(); work = nil; generation.stop(); busy = false }
    private func close() { stop(); generation.close() }

    private func add() {
        guard !busy, !applied, store.workflowReady(request.workspace) else { error = store.error; return }
        let items = BrainDumpReview.items(rows, parsed: parsed)
        guard !items.isEmpty else { return }
        do {
            let changes = try store.brainDumpChanges(items)
            var saved = false
            #if os(macOS)
            workspace.run("Brain Dump") { saved = store.commit(changes) }
            #else
            saved = store.commit(changes)
            #endif
            guard saved else { error = store.error; return }
            store.error = nil; applied = true; close(); onAdded(items.count); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

#if os(iOS)
/// A round check instead of a wide switch, so a task's text keeps its width. It is still a toggle for VoiceOver.
private struct RoundCheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle").font(.title3)
                .foregroundStyle(configuration.isOn ? DS.Palette.accent : DS.Palette.textSecondary)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
#endif

private struct BrainDumpChip: View {
    let chip: BrainDump.Chip
    private var symbol: String {
        switch chip.group {
        case "priority": "flag.fill"; case "project_id": "folder"; case "section_id": "rectangle.stack"; case "labels": "tag.fill"
        case "due_time": "clock"; case "recurrence": "repeat"; case "deadline_date": "flag.checkered"; case "duration_minutes": "hourglass"
        case "assigned_to": "person.crop.circle"; case "planning": "moon.fill"; case "reminder_specs": "bell"; default: "calendar"
        }
    }
    private var tint: Color {
        switch chip.group {
        case "priority": DS.Palette.priority(Int(chip.label.filter(\.isNumber)) ?? 4)
        case "project_id", "section_id", "planning": DS.Palette.accentSecondary
        case "due_date", "due_time", "recurrence": DS.Palette.dateToday
        default: DS.Palette.textSecondary
        }
    }
    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
            Text(chip.label).lineLimit(1)
        }
        .font(DS.Font.chip).foregroundStyle(tint).fixedSize()
        .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

#if DEBUG
/// Screenshot and UI-test fixtures. `--braindump-review` opens the sheet on the review, sorted by the deterministic splitter.
enum BrainDumpFixture {
    static var review: Bool { ProcessInfo.processInfo.arguments.contains("--braindump-review") }
    static var text: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--braindump-text=") }.map { String($0.dropFirst("--braindump-text=".count)).replacingOccurrences(of: "\\n", with: "\n") } ?? """
        Call Anna tomorrow p1 #Home
        - Send the invoice to the Acme team friday
        - Book the dentist; buy flowers for mum
        3. Plan the offsite agenda and then email the venue
        Water the plants every monday
        Pick up the parcel
        """
    }
}
#endif
