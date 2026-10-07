import SwiftUI

private struct FilterCondition: Identifiable {
    var id = UUID(), field = "today", value = "", inverted = false
    var rule: FilterRule { inverted ? .not(.predicate(field, value)) : .predicate(field, value) }
}

struct SavedViewEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State var record: Record
    @State private var conditions = [FilterCondition()]
    @State private var matchAny = false
    @State private var advanced = false
    @State private var expression = ""
    @State private var loaded = false
    @State private var deleting = false
    @State private var baseline: Record?
    @State private var loadFailure: String?
    @FocusState private var focusedField: String?
    private static let choices: [(String, String)] = [
        ("all","All tasks"),("search","Keywords"),("created_on","Created on"),("created_before","Created before"),("created_after","Created after"),("recurring","Repeating tasks"),("no_time","No planned time"),("no_labels","No labels"),("planned_time_on","Time at"),("planned_time_before","Time before"),("planned_time_after","Time after"),("planned_on","Planned on"),("planned_before","Planned before"),("planned_after","Planned after"),("effective_due_on","Due on"),("effective_due_before","Due before"),("effective_due_after","Due after"),("deadline_on","Deadline on"),("deadline_before_day","Deadline before"),("deadline_after","Deadline after"),("today","Planned today"),("overdue","Overdue plan"),("next","Next days"),("no_date","No planned date"),("inbox","Inbox"),
        ("priority","Priority"),("project","Project"),("section","Section"),("label","Label"),("completed","Completion"),("assignee","Assigned to"),
        ("due","Planned on date"),("before","Planned before date"),("deadline_today","Deadline today"),("deadline_overdue","Past deadline"),("deadline_next","Deadline in next days"),("no_deadline","No deadline"),("deadline","Deadline on date"),("deadline_before","Deadline before date"),("duration_max","Estimate up to minutes"),("no_estimate","No estimate")]
    private var people: [Record] {
        var seen = Set<String>()
        return store.projects.flatMap { store.projectMembers($0.id) }.filter { $0.id != store.userID && seen.insert($0.id).inserted }.sorted { $0.string("display_name") < $1.string("display_name") }
    }
    private var parsed: Result<FilterRule, Error> {
        Result {
            if let loadFailure { throw FilterFailure(message: loadFailure) }
            if advanced { var parser = try FilterParser(expression, context: store.filterContext); return try parser.parse() }
            let root: FilterRule = matchAny ? .or(conditions.map(\.rule)) : .and(conditions.map(\.rule))
            let valid = try FilterRule(json: root.json); try valid.validate(in: store.filterContext); return valid
        }
    }
    private var nameFailure: String? {
        record.name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 120 ? "Keep the filter name within 120 characters." : nil
    }
    private var queryFailure: String? {
        if case .failure(let error) = parsed { return error.localizedDescription }
        return nil
    }
    private var failure: String? { nameFailure ?? queryFailure }
    private var previewCount: Int {
        guard case .success(let rule) = parsed else { return 0 }
        return store.tasks.filter { (record["include_completed"].flag || rule.includesCompletion || !$0.completed) && rule.matches($0, today: store.calendarContext.today, userID: store.userID, labels: store.labels.map { FilterReference(id: $0.id, name: $0.name) }, timeZone: store.calendarContext.timeZone) }.count
    }
    private func text(_ field: String, fallback: String = "") -> Binding<String> { Binding(get: { record.fields[field]?.text ?? fallback }, set: { record[field] = .string($0) }) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Filter name", text: text("name")).focused($focusedField, equals: "name").accessibilityIdentifier("savedViewName")
                    if let nameFailure { Label(nameFailure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("filterNameValidationError") }
                    Toggle("Edit expression", isOn: Binding(get: { advanced }, set: { value in
                        if value, case .success(let rule) = parsed { expression = rule.expression(in: store.filterContext) }
                        if !value, case .success(let rule) = parsed, let simple = simpleConditions(rule) { conditions = simple.0; matchAny = simple.1; advanced = false }
                        else if value { advanced = true }
                    })).disabled(loadFailure != nil).accessibilityIdentifier("advancedFilter")
                }
                if advanced {
                    Section("Expression") {
                        HStack(alignment: .top) {
                            TextField(loadFailure == nil ? "today OR overdue" : "Query preserved", text: $expression, axis: .vertical).disabled(loadFailure != nil).focused($focusedField, equals: "expression").lineLimit(2...8).accessibilityValue(expression).accessibilityIdentifier("filterExpression")
                            if !expression.isEmpty && loadFailure == nil { Button { expression = ""; focusedField = "expression" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless).accessibilityLabel("Clear expression").accessibilityIdentifier("clearFilterExpression") }
                        }
                        if let queryFailure { validationFeedback(queryFailure) }
                        DisclosureGroup("Syntax examples") {
                            Text("Use AND, OR, NOT and parentheses. Examples: #Work & %waiting, search:\"send email\" & no time, recurring & no labels, deadline:next7, duration<=25, assignee:me. Each search word can appear in the title or description. Quote words such as AND and OR to search for them.").font(.caption).foregroundStyle(.secondary)
                            Text("Date examples: date:tomorrow, date before:\"next Monday\", effective-due:today, deadline after:yesterday. Effective due uses the planned date, falling back to the deadline only when there is no plan. Legacy due:YYYY-MM-DD and Today keep using the plan. Add a time: date before:\"today at 2pm\". Date-and-time conditions exclude tasks without a planned time.").font(.caption).foregroundStyle(.secondary)
                            Text("Creation examples: created:today, created before:-30 days, created after:yesterday. Uses the recorded creation date in your current time zone. Before and after exclude the chosen day. Plans and deadlines do not change when a task was created.").font(.caption).foregroundStyle(.secondary)
                            Text("Time examples: today & time before:14:00, time after:6pm. Time-only conditions compare the planned clock on any day in your current time zone. Combine with a date to choose a day.").font(.caption).foregroundStyle(.secondary)
                        }.font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("filterSyntaxExamples")
                        Text("Nested expressions stay in expression mode so switching views cannot discard conditions.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Conditions") {
                        Picker("Match", selection: $matchAny) { Text("All").tag(false); Text("Any").tag(true) }
                        if let queryFailure { validationFeedback(queryFailure) }
                        ForEach($conditions) { $condition in
                            VStack(alignment: .leading, spacing: 8) {
                                conditionControl($condition)
                                    .onChange(of: condition.field) { _, field in condition.value = defaultValue(field) }
                                valueControl($condition)
                                HStack {
                                    Toggle("Exclude matches", isOn: $condition.inverted)
                                    Button(role: .destructive) { conditions.removeAll { $0.id == condition.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).disabled(conditions.count == 1).accessibilityLabel("Remove condition")
                                }
                            }.padding(.vertical, 4)
                        }
                        Button("Add condition", systemImage: "plus") { conditions.append(FilterCondition()) }.disabled(conditions.count >= 20).accessibilityIdentifier("addFilterCondition")
                    }
                }
                Section("View") {
                    Picker("Layout", selection: text("layout", fallback: "list")) { Text("List").tag("list"); Text("Board").tag("board") }.accessibilityIdentifier("savedViewLayout")
                    Picker("Group by", selection: text("grouping", fallback: "none")) { Text("None").tag("none"); Text("Project").tag("project"); Text("Priority").tag("priority"); Text("Planned date").tag("date"); Text("Deadline").tag("deadline") }.accessibilityIdentifier("savedViewGrouping")
                    Picker("Sort", selection: text("sort_by", fallback: "manual")) { Text("Priority and your order").tag("manual"); Text("Planned date").tag("date"); Text("Deadline").tag("deadline"); Text("Estimate").tag("duration"); Text("Title").tag("title") }
                    Toggle("Include completed", isOn: Binding(get: { record["include_completed"].flag }, set: { record["include_completed"] = .bool($0) }))
                }
                Section {
                    if failure == nil { LabeledContent("Matching tasks", value: "\(previewCount)").accessibilityElement(children: .combine).accessibilityValue("\(previewCount)").accessibilityIdentifier("filterPreviewCount") }
                    Text(store.localMode ? "This filter and its view settings are saved on this device. Sign in to keep them available across devices." : "This filter and its view settings sync with your account. Renaming projects or labels keeps the filter intact.").font(.caption).foregroundStyle(.secondary)
                }
                if store.record("saved_views", id: record.id) != nil { Section { Button("Delete filter", role: .destructive) { deleting = true } } }
            }
            .accessibilityIdentifier("savedViewForm")
            .scrollDismissesKeyboard(.interactively)
            #if DEBUG
            .modifier(CalendarContextFixtureControls(editor: true))
            #endif
            .navigationTitle(store.record("saved_views", id: record.id) == nil ? "New filter" : "Edit filter")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // Keep the keyboard dismissal control in the sheet's measured safe area.
            // A keyboard ToolbarItem emits invalid-frame warnings as this Form gains focus.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focusedField != nil {
                    HStack {
                        Spacer()
                        Button { focusedField = nil } label: {
                            Text("Done").font(.body.weight(.medium)).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                        }.accessibilityIdentifier("dismissFilterKeyboard")
                    }.padding(.horizontal, 16).background(.bar)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #else
            .formStyle(.grouped).frame(minWidth: 450, idealWidth: 500, minHeight: 600, idealHeight: 720)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || failure != nil).accessibilityIdentifier("saveSavedView") }
            }
            .onAppear(perform: load)
            .task(id: conditions.contains { $0.field == "assignee" }) {
                guard !store.localMode, conditions.contains(where: { $0.field == "assignee" }) else { return }
                for project in store.projects { _ = try? await store.refreshProjectMembers(project.id) }
            }
            .confirmationDialog("Delete this filter?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete", role: .destructive) { store.remove("saved_views", record.id); dismiss() } } message: { Text("Your tasks stay in place.") }
        }
        .tint(Color.taskfold)
    }
    private func validationFeedback(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).labelStyle(WrappingMetadataLabelStyle(wraps: textSize.isAccessibilitySize))
            .foregroundStyle(.red)
            .accessibilityElement(children: .ignore).accessibilityLabel(message)
            .accessibilityIdentifier("filterValidationError")
    }
    @ViewBuilder private func conditionControl(_ condition: Binding<FilterCondition>) -> some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text("Condition").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Picker("Condition", selection: condition.field) {
                        ForEach(Self.choices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.choices.first { $0.0 == condition.wrappedValue.field }?.1 ?? "Condition")
                            .multilineTextAlignment(.leading).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
                    }.frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("Condition")
                .accessibilityValue(Self.choices.first { $0.0 == condition.wrappedValue.field }?.1 ?? "Condition")
                .accessibilityIdentifier("filterCondition-" + condition.wrappedValue.id.uuidString)
            }
        } else {
            Picker("Condition", selection: condition.field) { ForEach(Self.choices, id: \.0) { Text($0.1).tag($0.0) } }
                .accessibilityIdentifier("filterCondition-" + condition.wrappedValue.id.uuidString)
        }
    }
    @ViewBuilder private func valueControl(_ condition: Binding<FilterCondition>) -> some View {
        let field = condition.wrappedValue.field
        if ["project", "section", "label"].contains(field) {
            let rows = field == "project" ? store.projects : field == "section" ? store.rows("sections") : store.labels
            Picker("Target", selection: condition.value) {
                Text("Choose…").tag("")
                if !condition.wrappedValue.value.isEmpty && !rows.contains(where: { $0.id == condition.wrappedValue.value }) { Text("Unavailable target").tag(condition.wrappedValue.value) }
                ForEach(rows) { row in Text(row.name + (field == "section" ? " · " + (store.record("projects", id: row.string("project_id"))?.name ?? "") : "")).tag(row.id) }
            }
        } else if field == "priority" { Picker("Priority", selection: condition.value) { ForEach(1...4, id: \.self) { Text("Priority \($0)").tag(String($0)) } } }
        else if field == "completed" { Picker("State", selection: condition.value) { Text("Open").tag("false"); Text("Completed").tag("true") } }
        else if field == "assignee" {
            Picker("Person", selection: condition.value) {
                Text("Me").tag("me"); Text("Unassigned").tag("unassigned")
                if !["me", "unassigned"].contains(condition.wrappedValue.value) && !people.contains(where: { $0.id == condition.wrappedValue.value }) { Text("Unavailable collaborator").tag(condition.wrappedValue.value) }
                ForEach(people) { person in Text(person.string("display_name")).tag(person.id) }
            }
        }
        else if FilterCreationReference.expressions[field] != nil {
            TextField("Creation date or phrase", text: condition.value).focused($focusedField, equals: condition.wrappedValue.id.uuidString).accessibilityIdentifier("filterConditionValue-" + condition.wrappedValue.id.uuidString)
            Text("Try today, yesterday or -30 days. Uses the recorded creation date in your current time zone. Before and after exclude the chosen day. Tasks without a recorded creation date do not match.").font(.caption).foregroundStyle(.secondary)
        }
        else if FilterTimeReference.expressions[field] != nil {
            TextField("Time, such as 14:00", text: condition.value).focused($focusedField, equals: condition.wrappedValue.id.uuidString).accessibilityIdentifier("filterConditionValue-" + condition.wrappedValue.id.uuidString)
            Text("Uses your current time zone, on any day. Add a date condition to choose a day. Before and after exclude the chosen minute.").font(.caption).foregroundStyle(.secondary)
        }
        else if FilterDateReference.expressions[field] != nil {
            TextField("Date or phrase", text: condition.value).focused($focusedField, equals: condition.wrappedValue.id.uuidString).accessibilityIdentifier("filterConditionValue-" + condition.wrappedValue.id.uuidString)
            Text("Try today, tomorrow or in 7 days. Relative dates stay relative. Before and after exclude the chosen day or minute.").font(.caption).foregroundStyle(.secondary)
            if !field.hasPrefix("deadline") { Text("Add a time: today at 14:00. Uses your current time zone; timed conditions exclude tasks without a time.").font(.caption).foregroundStyle(.secondary) }
            if field.hasPrefix("effective_due_") { Text(FilterTimeReference.split(condition.wrappedValue.value) == nil ? "Uses the planned date. If there is no plan, uses the deadline." : "Timed conditions require a planned date and time.").font(.caption).foregroundStyle(.secondary) }
        }
        else if field == "search" {
            TextField("Words in title or description", text: condition.value).focused($focusedField, equals: condition.wrappedValue.id.uuidString).accessibilityIdentifier("filterConditionValue-" + condition.wrappedValue.id.uuidString)
            Text("Matches every word, in any order. Letter case and accents do not matter.").font(.caption).foregroundStyle(.secondary)
        }
        else if ["next", "deadline_next", "duration_max"].contains(field) { TextField(field == "duration_max" ? "Minutes" : "Days", text: condition.value).focused($focusedField, equals: condition.wrappedValue.id.uuidString).accessibilityIdentifier("filterConditionValue-" + condition.wrappedValue.id.uuidString) }
        else if ["due", "before", "deadline", "deadline_before"].contains(field) { DatePicker("Date", selection: Binding(get: { Dates.parse(condition.wrappedValue.value) ?? Date() }, set: { condition.wrappedValue.value = Dates.day($0) }), displayedComponents: .date) }
    }
    private func defaultValue(_ field: String) -> String {
        if FilterDateReference.expressions[field] != nil || FilterCreationReference.expressions[field] != nil { return "today" }
        if FilterTimeReference.expressions[field] != nil { return "14:00" }
        switch field { case "priority": return "1"; case "next", "deadline_next": return "7"; case "duration_max": return "25"; case "completed": return "false"; case "assignee": return "me"; case "due", "before", "deadline", "deadline_before": return store.calendarContext.today; default: return "" }
    }
    private func simpleConditions(_ rule: FilterRule) -> ([FilterCondition], Bool)? {
        let rules: [FilterRule], any: Bool
        switch rule { case .and(let r): rules = r; any = false; case .or(let r): rules = r; any = true; default: rules = [rule]; any = false }
        var conditions: [FilterCondition] = []
        for rule in rules {
            switch rule {
            case .predicate(let field, let value): conditions.append(FilterCondition(field: field, value: value))
            case .not(.predicate(let field, let value)): conditions.append(FilterCondition(field: field, value: value, inverted: true))
            default: return nil
            }
        }
        return (conditions, any)
    }
    private func load() {
        guard !loaded else { return }
        loaded = true; baseline = store.record("saved_views", id: record.id)
        do {
            let rule = try FilterRule(document: record["query_ast"])
            expression = rule.expression(in: store.filterContext)
            if let simple = simpleConditions(rule) { conditions = simple.0; matchAny = simple.1 } else { advanced = true }
        } catch {
            advanced = true
            loadFailure = "This saved query is unsupported. Update Taskfold to edit it; your query is preserved."
        }
    }
    private func save() {
        guard case .success(let rule) = parsed else { return }
        record["name"] = .string(record.name.trimmingCharacters(in: .whitespacesAndNewlines)); record["query_ast"] = rule.document
        if store.save("saved_views", record, baseline: baseline) { dismiss() }
    }
}

struct SavedFilterBoard: View {
    @Environment(Store.self) private var store
    let scope: TaskScope
    let tasks: [Record]
    let open: (Record) -> Void
    let toggle: (Record) -> Void
    var body: some View {
        let grouping = store.viewValue(scope, field: "grouping", fallback: .string("none")).text
        GeometryReader { geometry in
            // Short windows need wider cards so large text leaves room for actions.
            let columnWidth = geometry.size.height < 320 ? min(440, max(280, geometry.size.width - 32)) : 280
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(TaskGrouping.groups(tasks, by: grouping, projects: store.projects, timeZone: store.calendarContext.timeZone)) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(group.name).font(.headline); Spacer(); Text("\(group.tasks.count)").foregroundStyle(.secondary).monospacedDigit() }
                            let orderKey = "scope:" + scope.preferenceKey + ":group:" + group.id
                            let ordered = store.viewValue(scope, field: "sort_by", fallback: .string("manual")).text == "manual" ? DayPlacement.arranged(group.tasks, ids: store.record(DayPlacement.table, id: orderKey)?["ids"].list.map(\.text) ?? []) : group.tasks
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(ordered) { task in
                                        HStack(alignment: .top, spacing: 10) {
                                            Button { toggle(task) } label: {
                                                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(Color.taskfold)
                                                #if os(iOS)
                                                    .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                                                #endif
                                            }.buttonStyle(.borderless).accessibilityLabel((task.completed ? "Reopen " : "Complete ") + task.title)
                                            Button { open(task) } label: {
                                                VStack(alignment: .leading, spacing: 6) { Text(task.title).foregroundStyle(.primary).strikethrough(task.completed).multilineTextAlignment(.leading); if let deadline = task.deadline { Label(deadline.formatted(.dateTime.month(.abbreviated).day()), systemImage: "flag.checkered").font(.caption).foregroundStyle(.secondary) }; if let minutes = task.durationMinutes { Label("\(minutes) min", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) } }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }.buttonStyle(.plain).accessibilityIdentifier("savedFilterOpen-" + task.id)
                                        }.padding(12).background(.background, in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                                    }
                                }.padding(.bottom, 4)
                            }.accessibilityIdentifier("savedFilterColumn-" + group.id)
                        }.padding(16).frame(width: columnWidth).background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 18))
                    }
                }.padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }.accessibilityIdentifier("savedFilterBoard")
    }
}
