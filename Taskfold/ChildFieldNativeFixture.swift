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
    static func key(_ account: String) throws -> SymmetricKey {
        guard enabled, [Self.account, other].contains(account) else { throw CancellationError() }
        return SymmetricKey(data: Data(repeating: account == Self.account ? 88 : 89, count: 32))
    }
}

/// A synthetic file-backed HTTP peer, not a substitute for the PostgreSQL suite.
@MainActor enum ChildFieldNativePeer {
    static var folder: URL { URL.applicationSupportDirectory.appendingPathComponent("Child field native peer", isDirectory: true) }
    static var file: URL { folder.appendingPathComponent("server.json") }
    static var root: Record {
        get throws { Record(try state()["root"]!.object) }
    }
    static func initial() -> [String: JSON] {
        let child: (String, String) -> JSON = { id, title in .object(["id": .string(id), "title": .string(title), "description": .string("Original saved notes"), "priority": .number(4), "completed": .bool(false), "future": .object(["keep": .bool(true)])]) }
        return ["root": .object(["id": .string(ChildFieldNativeIdentity.rootID), "user_id": .string(ChildFieldNativeIdentity.account), "task_generation": .string(ChildFieldNativeIdentity.generation), "project_id": .null, "title": .string("Native child workspace"), "subtasks": .array([child("concept", "Prepare the review"), child("review", "Publish the summary")])]), "receipts": .object([:]), "versions": .object(["concept": .number(1), "review": .number(1)]), "writes": .number(0), "requests": .number(0), "lost": .bool(false)]
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
        if request.url?.path == "/rest/v1/rpc/taskfold_read_child_tasks" {
            guard body["_id"] == .string(root.id), body["_generation"] == root["task_generation"], Store.shared.userID == ChildFieldNativeIdentity.account else { throw CancellationError() }
            let records = root["subtasks"].list.enumerated().map { i, value -> JSON in
                let key = value.object["id"]!.text
                return .object(["node_key": .string(key), "incarnation": .string(i == 0 ? "ec990000-0000-4000-8000-000000000005" : "ec990000-0000-4000-8000-000000000006"), "revision": state["versions"]!.object[key]!, "parent_key": .null, "sibling_order": .number(Double(i)), "identity_path": .array([.string(key)]), "fields": value, "children_kind": .string("absent")])
            }
            return (try JSONEncoder().encode(["protocol": JSON.number(1), "account": .string(ChildFieldNativeIdentity.account), "task_id": .string(root.id), "task_generation": root["task_generation"], "project_id": .null, "projection_revision": .number(Double(state["writes"]!.integer + 1)), "root_kind": .string("array"), "records": .array(records)]), false)
        }
        guard request.url?.path == "/rest/v1/rpc/taskfold_edit_child_task", Set(body.keys) == ["_body"] else { throw URLError(.unsupportedURL) }
        let command = try ChildTaskFieldCommand(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin, body: body["_body"]!.object)
        guard command.body["task_id"] == .string(root.id), command.body["task_generation"] == root["task_generation"], command.body["project_id"] == .null, Store.shared.userID == command.account else { throw CancellationError() }
        var receipts = state["receipts"]!.object
        state["requests"] = .number(Double(state["requests"]!.integer + 1))
        if let old = receipts[command.id]?.object {
            guard AuthoredValueComparison.exactJSON(old["body"]!, .object(command.body)) else { throw CancellationError() }
            var proof = old["receipt"]!.object; proof["replayed"] = .bool(true); try save(state)
            return (try JSONEncoder().encode(proof), false)
        }
        let key = command.body["node_key"]!.text
        guard let index = root["subtasks"].list.firstIndex(where: { $0.object["id"] == .string(key) }),
              command.body["incarnation"] == .string(index == 0 ? "ec990000-0000-4000-8000-000000000005" : "ec990000-0000-4000-8000-000000000006") else { throw CancellationError() }
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
    var body: some View {
        NavigationStack {
            List {
                Text("Synthetic child field acceptance").font(.headline)
                if let problem { Text(problem).accessibilityIdentifier("childNativeProblem") }
                if ready {
                    Button("Open subtask editor") { opening = "editor" }.accessibilityIdentifier("childNativeEditor")
                    Button("Open saved changes") { opening = "recovery" }.accessibilityIdentifier("childNativeRecovery")
                    Button(store.online ? "Go offline" : "Go online") { store.online.toggle() }.accessibilityIdentifier("childNativeConnection")
                    Text(probe).accessibilityIdentifier("childNativeProbe")
                    if !privateTitle.isEmpty { Text(privateTitle).accessibilityIdentifier("childNativePrivateTitle") }
                } else { ProgressView("Preparing synthetic workspace…") }
            }.navigationTitle("Subtask acceptance")
        }
        .task {
            guard ChildFieldNativeIdentity.enabled else { return }
            do {
                try await store.childFieldNativeStart(); ready = true
                while !Task.isCancelled { await inspect(); try await Task.sleep(nanoseconds: 400_000_000) }
            } catch is CancellationError { } catch { problem = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { opening != nil }, set: { if !$0 { opening = nil } })) {
            WorkflowShell(title: opening == "editor" ? "Subtask changes" : "Saved subtask changes") {
                if opening == "editor" { ChildTaskFieldEditorView(rootID: ChildFieldNativeIdentity.rootID) }
                else { ChildTaskFieldRecoveryView() }
            }
        }
    }
    private func inspect() async {
        do {
            guard ChildFieldNativeIdentity.enabled else { return }
            let state = try ChildFieldNativePeer.state()
            let journal = try store.childTaskFieldJournal(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin)
            let entries = try await journal.load().entries
            let counts = ["queued", "attempted", "confirmed"].map { name in "\(name)=\(entries.filter { $0.phase.rawValue == name }.count)" }.joined(separator: " ")
            let current = store.record("tasks", id: ChildFieldNativeIdentity.rootID)?["subtasks"].list.first?.object["title"]?.text ?? "hidden"
            let drafts = try store.backupVault.editorEntries().compactMap { entry -> TaskEditorRecovery? in
                guard let value = try? store.backupVault.editorDraft(entry.id, origin: ChildFieldNativeIdentity.origin), value.extras["independent_child_fields"]?.object["root"] == .string(ChildFieldNativeIdentity.rootID) else { return nil }; return value
            }
            privateTitle = drafts.first?.draft.title ?? ""
            let child = store.record("tasks", id: ChildFieldNativeIdentity.rootID)?["subtasks"].list.first?.object ?? [:]
            let labelValues = child["labels"]?.list.map(\.text).joined(separator: ",") ?? ""
            let pendingLabel = drafts.first?.extras["unsubmitted_child_label"]?.text ?? ""
            probe = "\(counts) writes=\(state["writes"]!.integer) requests=\(state["requests"]!.integer) current=\(current) account=\(store.userID == ChildFieldNativeIdentity.account ? "A" : "B") private=\(drafts.count) minutes=\(store.record("tasks", id: ChildFieldNativeIdentity.rootID)?["subtasks"].list.first?.object["duration_minutes"]?.integer ?? 0) labels=\(labelValues) pendingLabel=\(pendingLabel) assigned=\(child["assigned_to"]?.text ?? "")"
        } catch { problem = error.localizedDescription }
    }
}
#endif
