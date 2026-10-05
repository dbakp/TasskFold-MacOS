import SwiftUI

private struct FilterCondition: Identifiable {
    var id = UUID(), field = "today", value = "", inverted = false
    var rule: FilterRule { inverted ? .not(.predicate(field, value)) : .predicate(field, value) }
}

struct SavedViewEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var record: Record
    @State private var conditions = [FilterCondition()]
    @State private var matchAny = false
    @State private var advanced = false
    @State private var expression = ""
    @State private var loaded = false
    @State private var deleting = false
    @State private var baseline: Record?
    @FocusState private var focusedField: String?
    private static let choices: [(String, String)] = [
        ("all","All tasks"),("today","Planned today"),("overdue","Overdue plan"),("next","Next days"),("no_date","No planned date"),("inbox","Inbox"),
        ("priority","Priority"),("project","Project"),("section","Section"),("label","Label"),("completed","Completion"),("assignee","Assigned to"),
        ("due","Planned on date"),("before","Planned before date"),("deadline_today","Deadline today"),("deadline_overdue","Past deadline"),("deadline_next","Deadline in next days"),("no_deadline","No deadline"),("deadline","Deadline on date"),("deadline_before","Deadline before date"),("duration_max","Estimate up to minutes"),("no_estimate","No estimate")]
    private var people: [Record] {
        var seen = Set<String>()
        return store.projects.flatMap { store.projectMembers($0.id) }.filter { $0.id != store.userID && seen.insert($0.id).inserted }.sorted { $0.string("display_name") < $1.string("display_name") }
    }
    private var parsed: Result<FilterRule, Error> {
        Result {
            if advanced { var parser = try FilterParser(expression, context: store.filterContext); return try parser.parse() }
            let root: FilterRule = matchAny ? .or(conditions.map(\.rule)) : .and(conditions.map(\.rule))
            let valid = try FilterRule(json: root.json); try valid.validate(in: store.filterContext); return valid
        }
    }
    private var failure: String? {
        if record.name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 120 { return "Keep the filter name within 120 characters." }
        if case .failure(let error) = parsed { return error.localizedDescription }
        return nil
    }
    private var previewCount: Int {
        guard case .success(let rule) = parsed else { return 0 }
        return store.tasks.filter { (record["include_completed"].flag || rule.includesCompletion || !$0.completed) && rule.matches($0, today: Dates.day(Date()), userID: store.userID, labels: store.labels.map { FilterReference(id: $0.id, name: $0.name) }, timeZone: TimeZone.current.identifier) }.count
    }
    private func text(_ field: String, fallback: String = "") -> Binding<String> { Binding(get: { record.fields[field]?.text ?? fallback }, set: { record[field] = .string($0) }) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Filter name", text: text("name")).focused($focusedField, equals: "name").accessibilityIdentifier("savedViewName")
                    Toggle("Edit expression", isOn: Binding(get: { advanced }, set: { value in
                        if value, case .success(let rule) = parsed { expression = rule.expression(in: store.filterContext) }
                        if !value, case .success(let rule) = parsed, let simple = simpleConditions(rule) { conditions = simple.0; matchAny = simple.1; advanced = false }
                        else if value { advanced = true }
                    })).accessibilityIdentifier("advancedFilter")
                }
                if advanced {
                    Section("Expression") {
                        HStack(alignment: .top) {
                            TextField("today OR overdue", text: $expression, axis: .vertical).focused($focusedField, equals: "expression").lineLimit(2...8).accessibilityValue(expression).accessibilityIdentifier("filterExpression")
                            if !expression.isEmpty { Button { expression = ""; focusedField = "expression" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless).accessibilityLabel("Clear expression").accessibilityIdentifier("clearFilterExpression") }
                        }
                        Text("Use AND, OR, NOT and parentheses. Targets can be quoted: project:\"Work\" AND p1. Other examples: no date AND NOT label:\"waiting\", deadline:next7, duration<=25, assignee:me.").font(.caption).foregroundStyle(.secondary)
                        Text("Nested expressions stay in expression mode so switching views cannot discard conditions.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Conditions") {
                        Picker("Match", selection: $matchAny) { Text("All conditions").tag(false); Text("Any condition").tag(true) }
                        ForEach($conditions) { $condition in
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Condition", selection: $condition.field) { ForEach(Self.choices, id: \.0) { Text($0.1).tag($0.0) } }
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
                    if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("filterValidationError") }
                    else { LabeledContent("Matching tasks", value: "\(previewCount)").accessibilityIdentifier("filterPreviewCount") }
                    Text(store.localMode ? "This filter and its view settings are saved on this device. Sign in to keep them available across devices." : "This filter and its view settings sync with your account. Renaming projects or labels keeps the filter intact.").font(.caption).foregroundStyle(.secondary)
                }
                if store.record("saved_views", id: record.id) != nil { Section { Button("Delete filter", role: .destructive) { deleting = true } } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(store.record("saved_views", id: record.id) == nil ? "New filter" : "Edit filter")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #else
            .formStyle(.grouped).frame(minWidth: 450, idealWidth: 500, minHeight: 600, idealHeight: 720)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil }.accessibilityIdentifier("dismissFilterKeyboard") }
                #endif
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || failure != nil).accessibilityIdentifier("saveSavedView") }
            }
            .onAppear { guard !loaded else { return }; loaded = true; baseline = store.record("saved_views", id: record.id); if let rule = try? FilterRule(document: record["query_ast"]) { expression = rule.expression(in: store.filterContext); if let simple = simpleConditions(rule) { conditions = simple.0; matchAny = simple.1 } else { advanced = true } } }
            .task(id: conditions.contains { $0.field == "assignee" }) {
                guard !store.localMode, conditions.contains(where: { $0.field == "assignee" }) else { return }
                for project in store.projects { _ = try? await store.refreshProjectMembers(project.id) }
            }
            .confirmationDialog("Delete this filter?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete", role: .destructive) { store.remove("saved_views", record.id); dismiss() } } message: { Text("Your tasks stay in place.") }
        }.tint(Color.taskfold)
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
        else if ["next", "deadline_next", "duration_max"].contains(field) { TextField(field == "duration_max" ? "Minutes" : "Days", text: condition.value) }
        else if ["due", "before", "deadline", "deadline_before"].contains(field) { DatePicker("Date", selection: Binding(get: { Dates.parse(condition.wrappedValue.value) ?? Date() }, set: { condition.wrappedValue.value = Dates.day($0) }), displayedComponents: .date) }
    }
    private func defaultValue(_ field: String) -> String {
        switch field { case "priority": return "1"; case "next", "deadline_next": return "7"; case "duration_max": return "25"; case "completed": return "false"; case "assignee": return "me"; case "due", "before", "deadline", "deadline_before": return Dates.day(Date()); default: return "" }
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
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(TaskGrouping.groups(tasks, by: grouping, projects: store.projects)) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(group.name).font(.headline); Spacer(); Text("\(group.tasks.count)").foregroundStyle(.secondary).monospacedDigit() }
                        let orderKey = "scope:" + scope.preferenceKey + ":group:" + group.id
                        let ordered = store.viewValue(scope, field: "sort_by", fallback: .string("manual")).text == "manual" ? DayPlacement.arranged(group.tasks, ids: store.record(DayPlacement.table, id: orderKey)?["ids"].list.map(\.text) ?? []) : group.tasks
                        ForEach(ordered) { task in
                            HStack(alignment: .top, spacing: 10) {
                                Button { toggle(task) } label: { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(Color.taskfold) }.buttonStyle(.borderless).accessibilityLabel((task.completed ? "Reopen " : "Complete ") + task.title)
                                Button { open(task) } label: {
                                    VStack(alignment: .leading, spacing: 6) { Text(task.title).foregroundStyle(.primary).strikethrough(task.completed).multilineTextAlignment(.leading); if let deadline = task.deadline { Label(deadline.formatted(.dateTime.month(.abbreviated).day()), systemImage: "flag.checkered").font(.caption).foregroundStyle(.secondary) }; if let minutes = task.durationMinutes { Label("\(minutes) min", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) } }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }.padding(12).background(.background, in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        }
                    }.padding(16).frame(width: 280).background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 18))
                }
            }.padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
        }.accessibilityIdentifier("savedFilterBoard")
    }
}
