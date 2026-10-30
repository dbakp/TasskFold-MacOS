import SwiftUI
import CryptoKit

#if DEBUG
/// No production bundle/account can opt into this peer or its synthetic key.
enum ChildFieldNativeIdentity {
    static let account = "ec990000-0000-4000-8000-000000000001"
    static let other = "ec990000-0000-4000-8000-000000000009"
    static let rootID = "ec990000-0000-4000-8000-000000000002"
    static let generation = "ec990000-0000-4000-8000-000000000003"
    static let origin = "https://synthetic.example"
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowteststeameditbridge", "com.dbakp.taskfold.mac.workflowteststeameditbridge"].contains(Bundle.main.bundleIdentifier ?? "") &&
        ProcessInfo.processInfo.arguments.contains("--team-editor-testing") && ProcessInfo.processInfo.arguments.contains("--child-fields-native")
    }
    static func recordPresentationClose(_ id: UUID, reason: String) {
        guard enabled else { return }
        let url = URL.cachesDirectory.appendingPathComponent("child-reminder-presentations.json")
        var rows = ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([[String: String]].self, from: $0) }) ?? []
        rows.append(["presentation": id.uuidString, "reason": reason])
        if let data = try? JSONEncoder().encode(Array(rows.suffix(64))) { try? data.write(to: url, options: .atomic) }
    }
    static func key(_ account: String) throws -> SymmetricKey {
        guard enabled, [Self.account, other].contains(account) else { throw CancellationError() }
        return SymmetricKey(data: Data(repeating: account == Self.account ? 88 : 89, count: 32))
    }
}

struct ChildFieldNativeRefusal: Error { let code: String }

/// A synthetic file-backed HTTP peer, not a substitute for the PostgreSQL suite.
@MainActor enum ChildFieldNativePeer {
    static var folder: URL { URL.applicationSupportDirectory.appendingPathComponent("Child field native peer", isDirectory: true) }
    static var file: URL { folder.appendingPathComponent("server.json") }
    static var root: Record {
        get throws { Record(try state()["root"]!.object) }
    }
    static func initial() -> [String: JSON] {
        let child: (String, String) -> JSON = { id, title in
            var fields: [String: JSON] = ["id": .string(id), "title": .string(title), "description": .string("Original saved notes"), "priority": .number(4), "completed": .bool(false), "future": .object(["keep": .bool(true)])]
            if id == "concept", ProcessInfo.processInfo.arguments.contains("--child-fields-native-heading") { fields["is_heading"] = .bool(true) }
            return .object(fields)
        }
        var initialChildren = [child("concept", "Prepare the review"), child("review", "Publish the summary")]
        if ProcessInfo.processInfo.arguments.contains("--child-structure-nested") || ChildTransferNativePeer.enabled {
            var first = initialChildren[0].object
            first["subtasks"] = .array([.object(["id": .string("nested"), "title": .string("Collect supporting notes"), "description": .string("Keep these nested instructions"), "future": .object(["keep": .bool(true)])])])
            initialChildren[0] = .object(first)
        }
        return ["root": .object(["id": .string(ChildFieldNativeIdentity.rootID), "user_id": .string(ChildFieldNativeIdentity.account), "task_generation": .string(ChildFieldNativeIdentity.generation), "project_id": .null, "title": .string("Native child workspace"), "subtasks": .array(initialChildren)]), "receipts": .object([:]), "versions": .object(["concept": .number(1), "review": .number(1)]), "writes": .number(0), "requests": .number(0), "lost": .bool(false)]
    }
    static func save(_ state: [String: JSON]) throws {
        guard ChildFieldNativeIdentity.enabled else { throw CancellationError() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
    static func state() throws -> [String: JSON] {
        guard ChildFieldNativeIdentity.enabled else { throw CancellationError() }
        if !FileManager.default.fileExists(atPath: file.path) { try save(initial()) }
        let bytes = try Data(contentsOf: file); guard bytes.count < 1_000_000 else { throw CancellationError() }
        return try JSONDecoder().decode([String: JSON].self, from: bytes)
    }
    static func completionResponse(_ body: [String: JSON], closing: Bool, state: inout [String: JSON]) throws -> (Data, Bool) {
        guard Set(body.keys) == ["_body"], Store.shared.userID == ChildFieldNativeIdentity.account else { throw CancellationError() }
        let raw = body["_body"]!.object
        var receipts = state["completionReceipts"]?.object ?? [:]
        let original: ChildTaskCompletionCommand.Original?
        if raw["action"] == .string("undo") {
            guard let saved = receipts[raw["undo_of"]?.text ?? ""]?.object else { throw ChildFieldNativeRefusal(code: "PT409") }
            original = .init(body: saved["body"]!.object, receipt: saved["receipt"]!.object)
        } else { original = nil }
        let command = try ChildTaskCompletionCommand(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin, body: raw, original: original)
        if closing {
            var result = raw.filter { !["baseline", "revision"].contains($0.key) }; result["undo_of"] = raw["undo_of"] ?? .null
            state["completionCloses"] = .number(Double((state["completionCloses"]?.integer ?? 0) + 1))
            if let old = receipts[command.id]?.object {
                guard AuthoredValueComparison.exactJSON(old["body"]!, .object(raw)) else { throw ChildFieldNativeRefusal(code: "PT409") }
                var proof = old["receipt"]!.object; proof["replayed"] = .bool(true)
                result["outcome"] = .string("applied"); result["receipt"] = .object(proof)
            } else {
                var closed = state["completionClosures"]?.object ?? [:]
                if let old = closed[command.id], !AuthoredValueComparison.exactJSON(old, .object(raw)) { throw ChildFieldNativeRefusal(code: "PT409") }
                closed[command.id] = .object(raw); state["completionClosures"] = .object(closed)
                result["outcome"] = .string("closed"); result["receipt"] = .null
            }
            _ = try ChildTaskCompletionResolution(command: command, raw: result); try save(state)
            return (try JSONEncoder().encode(result), false)
        }
        state["completionRequests"] = .number(Double((state["completionRequests"]?.integer ?? 0) + 1))
        if state["completionClosures"]?.object[command.id] != nil { try save(state); throw ChildFieldNativeRefusal(code: "PT410") }
        if let saved = receipts[command.id]?.object {
            guard AuthoredValueComparison.exactJSON(saved["body"]!, .object(raw)) else { throw ChildFieldNativeRefusal(code: "PT409") }
            var proof = saved["receipt"]!.object; proof["replayed"] = .bool(true); try save(state)
            return (try JSONEncoder().encode(proof), false)
        }
        var root = Record(state["root"]!.object), rows = root["subtasks"].list
        let key = raw["node_key"]!.text
        guard raw["task_id"] == .string(root.id), raw["task_generation"] == root["task_generation"], raw["project_id"] == root["project_id"],
              let index = rows.firstIndex(where: { $0.object["id"] == .string(key) }),
              raw["incarnation"] == .string(index == 0 ? "ec990000-0000-4000-8000-000000000005" : "ec990000-0000-4000-8000-000000000006") else { throw ChildFieldNativeRefusal(code: "PT409") }
        var fields = rows[index].object, versions = state["versions"]!.object
        let before = fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) }
        let expected = original?.receipt["after"] ?? raw["baseline"]!
        guard AuthoredValueComparison.exactJSON(.object(before), expected), raw["revision"]!.integer <= versions[key]!.integer,
              before[TeamChecklist.key] != nil || raw["revision"] == versions[key] else { try save(state); throw ChildFieldNativeRefusal(code: "PT409") }
        var after = original?.receipt["before"]?.object ?? before
        let token = TeamChecklist.token(before[TeamChecklist.key])
        after[TeamChecklist.key] = .object(["epoch": .string(token?.epoch ?? "ec990000-0000-4000-8000-000000000010"), "version": .number((token?.version ?? 0) + 1)])
        if original == nil {
            let complete = raw["action"] == .string("complete")
            after["completed"] = .bool(complete); after["completed_at"] = complete ? .string(ISO8601DateFormatter().string(from: Date())) : .null
        }
        for field in ChildTaskCompletionDraft.cohort { fields.removeValue(forKey: field) }
        fields.merge(after) { _, new in new }; rows[index] = .object(fields); root["subtasks"] = .array(rows)
        versions[key] = .number(Double(versions[key]!.integer + 1))
        var proof = raw.filter { !["baseline", "undo_of"].contains($0.key) }
        proof["undo_of"] = raw["undo_of"] ?? .null; proof["revision"] = versions[key]
        proof["before"] = .object(before); proof["after"] = .object(after); proof["replayed"] = .bool(false)
        _ = try command.confirmed(proof)
        receipts[command.id] = .object(["body": .object(raw), "receipt": .object(proof)])
        state["root"] = .object(root.fields); state["versions"] = .object(versions); state["completionReceipts"] = .object(receipts)
        state["completionWrites"] = .number(Double((state["completionWrites"]?.integer ?? 0) + 1)); state["writes"] = .number(Double(state["writes"]!.integer + 1))
        let lose = ProcessInfo.processInfo.arguments.contains("--child-completion-lose-reply") && state["completionLost"]?.flag != true
        if lose { state["completionLost"] = .bool(true) }; try save(state)
        return (try JSONEncoder().encode(proof), lose)
    }
    static func response(_ request: URLRequest) async throws -> (Data, Bool) {
        guard ChildFieldNativeIdentity.enabled, request.url?.host == "synthetic.example", request.httpMethod == "POST" else { throw URLError(.unsupportedURL) }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }
                guard data.count + count <= 140_000 else { throw CancellationError() }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try JSONDecoder().decode([String: JSON].self, from: data)
        var state = try state(); let root = Record(state["root"]!.object)
        if ChildTransferNativePeer.enabled, ChildTransferNativePeer.paths.contains(request.url?.path ?? "") {
            return try ChildTransferNativePeer.response(path: request.url!.path, body: body, state: &state)
        }
        if ChildStructureNativePeer.enabled, ChildStructureNativePeer.paths.contains(request.url?.path ?? "") {
            return try ChildStructureNativePeer.response(path: request.url!.path, body: body, state: &state)
        }
        if request.url?.path == "/rest/v1/rpc/taskfold_read_child_tasks" {
            guard body["_id"] == .string(root.id), body["_generation"] == root["task_generation"], Store.shared.userID == ChildFieldNativeIdentity.account else { throw CancellationError() }
            state["childReads"] = .number(Double((state["childReads"]?.integer ?? 0) + 1)); try save(state)
            let records = root["subtasks"].list.enumerated().map { i, value -> JSON in
                let key = value.object["id"]!.text
                return .object(["node_key": .string(key), "incarnation": .string(i == 0 ? "ec990000-0000-4000-8000-000000000005" : "ec990000-0000-4000-8000-000000000006"), "revision": state["versions"]!.object[key]!, "parent_key": .null, "sibling_order": .number(Double(i)), "identity_path": .array([.string(key)]), "fields": value, "children_kind": .string("absent")])
            }
            return (try JSONEncoder().encode(["protocol": JSON.number(1), "account": .string(ChildFieldNativeIdentity.account), "task_id": .string(root.id), "task_generation": root["task_generation"], "project_id": .null, "projection_revision": .number(Double(state["writes"]!.integer + 1)), "root_kind": .string("array"), "records": .array(records)]), false)
        }
        if ["/rest/v1/rpc/taskfold_complete_child_task", "/rest/v1/rpc/taskfold_close_child_completion"].contains(request.url?.path ?? "") {
            return try completionResponse(body, closing: request.url?.path == "/rest/v1/rpc/taskfold_close_child_completion", state: &state)
        }
        let closing = request.url?.path == "/rest/v1/rpc/taskfold_close_child_task_edit"
        guard closing || request.url?.path == "/rest/v1/rpc/taskfold_edit_child_task", Set(body.keys) == ["_body"] else { throw URLError(.unsupportedURL) }
        let command = try ChildTaskFieldCommand(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin, body: body["_body"]!.object)
        guard command.body["task_id"] == .string(root.id), command.body["task_generation"] == root["task_generation"], command.body["project_id"] == .null, Store.shared.userID == command.account else { throw CancellationError() }
        var receipts = state["receipts"]!.object
        if closing {
            var result = command.body.filter { !["changes", "revision"].contains($0.key) }
            state["closeRequests"] = .number(Double((state["closeRequests"]?.integer ?? 0) + 1))
            if let prior = receipts[command.id]?.object {
                guard AuthoredValueComparison.exactJSON(prior["body"]!, .object(command.body)) else { throw ChildFieldNativeRefusal(code: "PT409") }
                var proof = prior["receipt"]!.object; proof["replayed"] = .bool(true)
                result["outcome"] = .string("applied"); result["receipt"] = .object(proof)
            } else {
                var closed = state["closures"]?.object ?? [:]
                if let prior = closed[command.id], !AuthoredValueComparison.exactJSON(prior, .object(command.body)) { throw ChildFieldNativeRefusal(code: "PT409") }
                closed[command.id] = .object(command.body); state["closures"] = .object(closed)
                result["outcome"] = .string("closed"); result["receipt"] = .null
            }
            let lose = ProcessInfo.processInfo.arguments.contains("--child-fields-lose-close-reply") && state["lostClose"]?.flag != true
            if lose { state["lostClose"] = .bool(true) }; try save(state)
            return (try JSONEncoder().encode(result), lose)
        }
        state["requests"] = .number(Double(state["requests"]!.integer + 1))
        if state["closures"]?.object[command.id] != nil { try save(state); throw ChildFieldNativeRefusal(code: "PT410") }
        if let old = receipts[command.id]?.object {
            guard AuthoredValueComparison.exactJSON(old["body"]!, .object(command.body)) else { throw CancellationError() }
            var proof = old["receipt"]!.object; proof["replayed"] = .bool(true); try save(state)
            return (try JSONEncoder().encode(proof), false)
        }
        let key = command.body["node_key"]!.text
        guard let index = root["subtasks"].list.firstIndex(where: { $0.object["id"] == .string(key) }),
              command.body["incarnation"] == .string(index == 0 ? "ec990000-0000-4000-8000-000000000005" : "ec990000-0000-4000-8000-000000000006") else { throw CancellationError() }
        if command.body["revision"]!.integer < state["versions"]!.object[key]!.integer { try save(state); throw ChildFieldNativeRefusal(code: "PT409") }
        var changed = root, rows = root["subtasks"].list, fields = rows[index].object
        fields.merge(command.body["changes"]!.object) { _, new in new }; rows[index] = .object(fields); changed["subtasks"] = .array(rows)
        var versions = state["versions"]!.object; versions[key] = .number(Double(versions[key]!.integer + 1))
        var proof = command.body.filter { $0.key != "changes" }; proof["revision"] = versions[key]; proof["replayed"] = .bool(false)
        _ = try command.confirmed(proof)
        receipts[command.id] = .object(["body": .object(command.body), "receipt": .object(proof)])
        state["root"] = .object(changed.fields); state["versions"] = .object(versions); state["receipts"] = .object(receipts); state["writes"] = .number(Double(state["writes"]!.integer + 1))
        let lose = ProcessInfo.processInfo.arguments.contains("--child-fields-lose-reply") && !state["lost"]!.flag
        if lose { state["lost"] = .bool(true) }; try save(state)
        if ProcessInfo.processInfo.arguments.contains("--child-fields-switch-on-send") { try await Store.shared.childFieldNativeSwitchAccount() }
        return (try JSONEncoder().encode(proof), lose)
    }
}

struct ChildFieldNativeFixtureView: View {
    @Environment(Store.self) private var store
    @State private var ready = false
    @State private var opening: String?
    @State private var problem: String?
    @State private var probe = "Preparing"
    @State private var privateTitle = ""
    @State private var queueingCompletion = false
    @State private var historyProgress = 0
    private var structureProbe: String {
        guard let start = probe.range(of: " structureDrafts=") else { return "Reading current hierarchy diagnostics…" }
        return String(probe[probe.index(after: start.lowerBound)...])
    }
    var body: some View {
        NavigationStack {
            List {
                Text("Synthetic child field acceptance").font(.headline)
                if let problem { Text(problem).accessibilityIdentifier("childNativeProblem") }
                if ready {
                    if ChildStructureNativePeer.enabled {
                        Button("Open saved hierarchy") { opening = "structure" }.accessibilityIdentifier("childNativeStructure")
                        Button("Open hierarchy actions") { opening = "structureRecovery" }.accessibilityIdentifier("childNativeStructureRecovery")
                        if ChildTransferNativePeer.enabled { Button("Open saved subtask moves") { opening = "transfers" }.accessibilityIdentifier("childNativeTransfers") }
                        Text(structureProbe).accessibilityIdentifier("childNativeStructureProbe")
                        Button("Forget only the local hierarchy test journal") {
                            Task { do { try await store.childTaskStructureJournal(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin).removeAccount(); await inspect() } catch { problem = error.localizedDescription } }
                        }.accessibilityIdentifier("childNativeLoseStructureJournal")
                    }
                    Button("Open subtask editor") { opening = "editor" }.accessibilityIdentifier("childNativeEditor")
                    Button("Open saved actions") { opening = "completion" }.accessibilityIdentifier("childNativeCompletionRecovery")
                    Button("Save an offline test completion") { Task { await queueCompletion() } }
                        .disabled(queueingCompletion || !store.online).accessibilityIdentifier("childNativeQueueCompletion")
                    Button("Exercise completion history") { Task { await exerciseHistory() } }
                        .disabled(queueingCompletion || !store.online).accessibilityIdentifier("childNativeExerciseHistory")
                    if queueingCompletion { Text("Preparing synthetic history: \(historyProgress)").accessibilityIdentifier("childNativeHistoryProgress") }
                    Button("Open saved changes") { opening = "recovery" }.accessibilityIdentifier("childNativeRecovery")
                    Button("Change test title on server") {
                        do {
                            var state = try ChildFieldNativePeer.state(), root = Record(state["root"]!.object), rows = root["subtasks"].list, first = rows[0].object
                            first["title"] = .string("Updated on another device"); rows[0] = .object(first); root["subtasks"] = .array(rows)
                            var versions = state["versions"]!.object; versions["concept"] = .number(Double(versions["concept"]!.integer + 1))
                            state["root"] = .object(root.fields); state["versions"] = .object(versions); try ChildFieldNativePeer.save(state)
                        } catch { problem = error.localizedDescription }
                    }.accessibilityIdentifier("childNativeForeignEdit")
                    Button(store.online ? "Go offline" : "Go online") { store.online.toggle() }.accessibilityIdentifier("childNativeConnection")
                    Text(probe).accessibilityIdentifier("childNativeProbe")
                    if !privateTitle.isEmpty { Text(privateTitle).accessibilityIdentifier("childNativePrivateTitle") }
                } else { ProgressView("Preparing synthetic workspace…") }
            }.navigationTitle("Subtask acceptance")
        }
        .task {
            guard ChildFieldNativeIdentity.enabled else { return }
            do {
                try await store.childFieldNativeStart(); try await ChildStructureNativePeer.seedDuplicateDraftForNativeTest(); await inspect(); ready = true
                while !Task.isCancelled { try await Task.sleep(nanoseconds: 400_000_000); await inspect() }
            } catch is CancellationError { } catch { problem = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { opening != nil }, set: { if !$0 { opening = nil } })) {
            WorkflowShell(title: opening == "editor" ? "Subtask changes" : opening == "completion" ? "Saved subtask actions" : opening == "structure" ? "Organize subtasks" : opening == "structureRecovery" ? "Saved hierarchy actions" : opening == "transfers" ? "Saved subtask moves" : "Saved subtask changes") {
                if opening == "editor" { ChildTaskFieldEditorView(rootID: ChildFieldNativeIdentity.rootID) }
                else if opening == "structure" { ChildTaskStructureView(rootID: ChildFieldNativeIdentity.rootID) }
                else if opening == "structureRecovery" { ChildTaskStructureRecoveryView() }
                else if opening == "transfers" { ChildTaskTransferRecoveryView() }
                else if opening == "completion" { ChildTaskCompletionRecoveryView() }
                else { ChildTaskFieldRecoveryView() }
            }
        }
    }
    private func exerciseHistory() async {
        guard ChildFieldNativeIdentity.enabled, store.online, let scope = store.childTaskFieldRecoveryScope else { return }
        queueingCompletion = true; historyProgress = 0; defer { queueingCompletion = false }
        do {
            let model = try store.childTaskCompletionRecoveryModel(); defer { model.close() }
            for index in 0..<70 {
                guard store.childTaskFieldRecoveryScope == scope else { throw CancellationError() }
                let read = try await store.readChildTaskRecords(ChildFieldNativeIdentity.rootID)
                guard await model.perform(read: read, key: "concept", action: index.isMultiple(of: 2) ? .complete : .reopen) != nil else {
                    throw AppFailure(message: "Synthetic completion history could not be confirmed.")
                }
                historyProgress = index + 1
            }
        } catch { problem = error.localizedDescription }
    }
    private func queueCompletion() async {
        guard ChildFieldNativeIdentity.enabled, store.online, let scope = store.childTaskFieldRecoveryScope else { return }
        queueingCompletion = true; defer { queueingCompletion = false }
        do {
            let read = try await store.readChildTaskRecords(ChildFieldNativeIdentity.rootID)
            guard store.childTaskFieldRecoveryScope == scope else { return }
            let model = try store.childTaskCompletionRecoveryModel()
            store.online = false
            defer { model.close(); if store.childTaskFieldRecoveryScope == scope { store.online = true } }
            guard await model.perform(read: read, key: "concept", action: .complete) != nil else {
                throw AppFailure(message: "The synthetic offline action could not be saved.")
            }
        } catch { problem = error.localizedDescription }
    }
    private func inspect() async {
        do {
            guard ChildFieldNativeIdentity.enabled else { return }
            let captured = store.childTaskFieldRecoveryScope
            let state = try ChildFieldNativePeer.state()
            let journal = try store.childTaskFieldJournal(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin)
            let entries = try await journal.load().entries
            let counts = ["queued", "attempted", "confirmed"].map { name in "\(name)=\(entries.filter { $0.phase.rawValue == name }.count)" }.joined(separator: " ")
            let current = store.record("tasks", id: ChildFieldNativeIdentity.rootID)?["subtasks"].list.first?.object["title"]?.text ?? "hidden"
            let drafts = try store.backupVault.editorEntries().compactMap { entry -> TaskEditorRecovery? in
                guard let value = try? store.backupVault.editorDraft(entry.id, origin: ChildFieldNativeIdentity.origin), value.extras["independent_child_fields"]?.object["root"] == .string(ChildFieldNativeIdentity.rootID) else { return nil }; return value
            }
            let nextTitle = drafts.first?.draft.title ?? ""
            let child = store.record("tasks", id: ChildFieldNativeIdentity.rootID)?["subtasks"].list.first?.object ?? [:]
            let labelValues = child["labels"]?.list.map(\.text).joined(separator: ",") ?? ""
            let pendingLabel = drafts.first?.extras["unsubmitted_child_label"]?.text ?? ""
            let reminderDrafts = drafts.filter { $0.extras["unsubmitted_reminder_settings"].map { $0 != .null } == true }.count
            let schedules = child["reminder_specs"]?.list ?? []
            let localSpecs = schedules.compactMap { ReminderSpec(row: $0) }
            let enabledSchedules = localSpecs.filter(\.enabled).count
            let beforeTen = localSpecs.filter { $0.enabled && $0.kind == "relative" && $0.offset == -10 }.count
            var nextProbe = "\(counts) writes=\(state["writes"]!.integer) requests=\(state["requests"]!.integer) current=\(current) account=\(store.userID == ChildFieldNativeIdentity.account ? "A" : "B") private=\(drafts.count) minutes=\(store.record("tasks", id: ChildFieldNativeIdentity.rootID)?["subtasks"].list.first?.object["duration_minutes"]?.integer ?? 0) schedules=\(schedules.count) enabled=\(enabledSchedules) before10=\(beforeTen) reminderDraft=\(reminderDrafts) kind=\(TaskKind(Record(child)) == .heading ? "heading" : "task") closed=\(entries.filter { $0.phase == .closed }.count) closes=\(state["closeRequests"]?.integer ?? 0) labels=\(labelValues) pendingLabel=\(pendingLabel) assigned=\(child["assigned_to"]?.text ?? "")"
            if store.userID == ChildFieldNativeIdentity.account {
                let completionEntries = try await store.childTaskCompletionJournal(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin).load().entries
                nextProbe += " completionQueued=\(completionEntries.filter { $0.phase == .queued }.count) completionAttempted=\(completionEntries.filter { $0.phase == .attempted }.count) completionConfirmed=\(completionEntries.filter { $0.phase == .confirmed }.count) completionClosed=\(completionEntries.filter { $0.phase == .closed }.count) completionWrites=\(state["completionWrites"]?.integer ?? 0) completionRequests=\(state["completionRequests"]?.integer ?? 0) done=\(child["completed"]?.flag == true) notes=\(child["description"]?.text ?? "")"
                nextProbe += " completionCloses=\(state["completionCloses"]?.integer ?? 0) childReads=\(state["childReads"]?.integer ?? 0) history=\(historyProgress) stamp=\(child["completed_at"]?.text.isEmpty == false ? child["completed_at"]!.text : "none")"
            }
            if ChildTransferNativePeer.enabled, store.userID == ChildFieldNativeIdentity.account {
                let transfers = try await store.childTaskTransferJournal(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin).load()
                nextProbe += " transferQueued=\(transfers.entries.filter { $0.phase == .queued }.count) transferAttempted=\(transfers.entries.filter { $0.phase == .attempted }.count) transferApplied=\(transfers.entries.filter { $0.phase == .applied }.count) transferClosed=\(transfers.entries.filter { $0.phase == .closed }.count) transferWrites=\(state["transferWrites"]?.integer ?? 0) transferRequests=\(state["transferRequests"]?.integer ?? 0) transferSource=\(ChildStructureNativePeer.flatKeys(Record(state["root"]!.object)["subtasks"]).joined(separator: ">")) transferDestination=\(ChildStructureNativePeer.flatKeys(Record(state["transferDestination"]?.object ?? [:])["subtasks"]).joined(separator: ">"))"
            }
            if ChildStructureNativePeer.enabled, store.userID == ChildFieldNativeIdentity.account {
                let structural = try await store.childTaskStructureJournal(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin).load()
                let organizerDrafts = try await store.childTaskStructureDraftJournal(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin).load().entries
                nextProbe += " structureDrafts=\(organizerDrafts.count) structureDraftPending=\(organizerDrafts.filter { $0.pendingCommand != nil }.count)"
                nextProbe += " structureQueued=\(structural.entries.filter { $0.phase == .queued }.count) structureAttempted=\(structural.entries.filter { $0.phase == .attempted }.count) structureConfirmed=\(structural.entries.filter { $0.phase == .confirmed }.count) structureClosed=\(structural.entries.filter { $0.phase == .closed }.count) structureWrites=\(state["structureWrites"]?.integer ?? 0) structureRequests=\(state["structureRequests"]?.integer ?? 0) structureArchives=\(state["structureArchives"]?.object.count ?? 0) structureOrder=\(ChildStructureNativePeer.flatKeys(Record(state["root"]!.object)["subtasks"]).joined(separator: ">")) structureDisposals=\(structural.disposals.filter { $0.phase == .confirmed }.count)"
                nextProbe += " structureReadUnavailable=\(state["structureReadUnavailable"]?.flag == true)"
            }
            // Publish one complete snapshot. A partial label across the journal
            // await can make accessibility reads observe missing count fields.
            guard captured == store.childTaskFieldRecoveryScope, !Task.isCancelled else { return }
            if privateTitle != nextTitle { privateTitle = nextTitle }
            if probe != nextProbe { probe = nextProbe }
        } catch { problem = error.localizedDescription }
    }
}
#endif
