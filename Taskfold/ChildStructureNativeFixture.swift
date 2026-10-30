#if DEBUG
import Foundation
import CryptoKit

/// File-backed isolated native peer only. PostgreSQL remains the authority for
/// the real transaction/permission/custody contract; this exercises actual UI,
/// Store, transport, encrypted journals and cold application presentation.
@MainActor enum ChildStructureNativePeer {
    static var enabled: Bool { ChildFieldNativeIdentity.enabled && ProcessInfo.processInfo.arguments.contains("--child-structure-native") }
    /// Opt-in fault injection for the isolated native test only. A second journal
    /// owner changes the same draft while the real SwiftUI alert stays open.
    static func refreshDraftDuringDiscardForNativeTest(_ reviewed: ChildTaskStructureDraft, model: ChildTaskStructurePresentation) {
        guard enabled, ProcessInfo.processInfo.arguments.contains("--child-structure-discard-refresh"), reviewed.pendingCommand == nil else { return }
        Task {
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                let store = Store.shared
                guard store.childTaskFieldRecoveryScope == model.scope else { throw CancellationError() }
                let writer = try store.childTaskStructureDraftJournal(account: reviewed.account, origin: reviewed.origin)
                let updated = try reviewed.editing(title: "Updated while confirmation is open", parent: reviewed.body["parent_key"] == .null ? nil : reviewed.body["parent_key"]!.text, index: reviewed.body["index"]!.integer)
                try await writer.save(updated, replacing: reviewed.token, lease: CalendarReadLease())
                await model.load()
            } catch { /* The test requires the updated row; a failed injection cannot pass. */ }
        }
    }
    static func seedDuplicateDraftForNativeTest() async throws {
        guard enabled, ProcessInfo.processInfo.arguments.contains("--child-structure-duplicate-draft"),
              ProcessInfo.processInfo.arguments.contains("--child-fields-native-reset") else { return }
        let store = Store.shared, read = try await store.readCurrentChildTaskStructure(ChildFieldNativeIdentity.rootID)
        let draft = try ChildTaskStructureDraft(read: read).editing(title: "Keep the original saved action", parent: nil, index: 0).preparing(read)
        let journal = try store.childTaskStructureDraftJournal(account: draft.account, origin: draft.origin)
        try await journal.save(draft, replacing: nil, lease: CalendarReadLease())
        let model = try store.childTaskStructurePresentation(); defer { model.close() }
        guard await model.queueDraftAction(draft.pendingCommand!, read: read) else { throw ChildTaskStructureDraft.invalid }
        var state = try ChildFieldNativePeer.state(); state["structureReadUnavailable"] = .bool(true); try ChildFieldNativePeer.save(state)
    }
    static let paths = ["/rest/v1/rpc/taskfold_read_child_tasks", "/rest/v1/rpc/taskfold_read_child_structure", "/rest/v1/rpc/taskfold_edit_child_structure", "/rest/v1/rpc/taskfold_close_child_structure", "/rest/v1/rpc/taskfold_child_structure_undo_archives", "/rest/v1/rpc/taskfold_forget_child_structure_undo"]
    static func records(_ root: Record, state: inout [String: JSON]) -> [JSON] {
        var result: [JSON] = [], incarnations = state["structureIncarnations"]?.object ?? ["concept": .string("ec990000-0000-4000-8000-000000000005"), "review": .string("ec990000-0000-4000-8000-000000000006")], versions = state["versions"]!.object
        func visit(_ rows: [JSON], parent: String?, path: [String]) {
            for (index, row) in rows.enumerated() {
                var fields = row.object; let raw = fields["id"]!.text, key = raw.precomposedStringWithCanonicalMapping
                if incarnations[key] == nil { incarnations[key] = .string(UUID().uuidString.lowercased()) }
                if versions[key] == nil { versions[key] = .number(1) }
                let children = fields.removeValue(forKey: "subtasks"), kind = children == nil ? "absent" : children == .null ? "null" : "array"
                result.append(.object(["node_key": .string(key), "incarnation": incarnations[key]!, "revision": versions[key]!, "parent_key": parent.map(JSON.string) ?? .null, "sibling_order": .number(Double(index)), "identity_path": .array((path + [raw]).map(JSON.string)), "fields": .object(fields), "children_kind": .string(kind)]))
                visit(children?.list ?? [], parent: key, path: path + [raw])
            }
        }
        visit(root["subtasks"].list, parent: nil, path: []); state["structureIncarnations"] = .object(incarnations); state["versions"] = .object(versions); return result
    }
    private static func node(_ rows: JSON, _ key: String) -> JSON? {
        for row in rows.list { if row.object["id"]!.text.precomposedStringWithCanonicalMapping == key { return row }; if let value = node(row.object["subtasks"] ?? .null, key) { return value } }; return nil
    }
    private static func removing(_ rows: JSON, key: String) -> JSON {
        .array(rows.list.compactMap { row in
            var fields = row.object; if fields["id"]!.text.precomposedStringWithCanonicalMapping == key { return nil }
            if case .array? = fields["subtasks"] { fields["subtasks"] = removing(fields["subtasks"]!, key: key) }; return .object(fields)
        })
    }
    private static func inserting(_ rows: JSON, node value: JSON, parent: String?, index: Int) throws -> JSON {
        if parent == nil { var list = rows.list; guard (0...list.count).contains(index) else { throw ChildFieldNativeRefusal(code: "PT409") }; list.insert(value, at: index); return .array(list) }
        return .array(try rows.list.map { row in
            var fields = row.object
            if fields["id"]!.text.precomposedStringWithCanonicalMapping == parent { fields["subtasks"] = try inserting(fields["subtasks"] ?? .null, node: value, parent: nil, index: index) }
            else if case .array? = fields["subtasks"] { fields["subtasks"] = try inserting(fields["subtasks"]!, node: value, parent: parent, index: index) }
            return .object(fields)
        })
    }
    private static func restoreContainer(_ rows: JSON, parent: String?, kind: String) -> JSON {
        guard kind != "array" else { return rows }
        if parent == nil { return rows.list.isEmpty ? .null : rows }
        return .array(rows.list.map { row in
            var fields = row.object
            if fields["id"]!.text.precomposedStringWithCanonicalMapping == parent, fields["subtasks"] == .array([]) { if kind == "absent" { fields.removeValue(forKey: "subtasks") } else { fields["subtasks"] = .null } }
            else if case .array? = fields["subtasks"] { fields["subtasks"] = restoreContainer(fields["subtasks"]!, parent: parent, kind: kind) }
            return .object(fields)
        })
    }
    private static func fresh(_ value: JSON, restoring: Bool) -> JSON {
        var fields = value.object
        if !restoring { fields["completed"] = .bool(false); fields["completed_at"] = .null }
        fields[TeamChecklist.key] = .object(["epoch": .string(UUID().uuidString.lowercased()), "version": .number(0)])
        if case .array(let children)? = fields["subtasks"] { fields["subtasks"] = .array(children.map { fresh($0, restoring: restoring) }) }; return .object(fields)
    }
    private static func digest(_ value: JSON) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined() }
    static func response(path: String, body: [String: JSON], state: inout [String: JSON]) throws -> (Data, Bool) {
        guard enabled else { throw CancellationError() }
        let account = Store.shared.userID, isOwner = account == ChildFieldNativeIdentity.account
        var receipts = state["structureReceipts"]?.object ?? [:], archives = state["structureArchives"]?.object ?? [:]
        var root = Record(state["root"]!.object)
        let rows = records(root, state: &state), revision = Double(state["structureRevision"]?.integer ?? 1)
        func encoded(_ raw: [String: JSON]) throws -> (Data, Bool) { (try JSONEncoder().encode(raw), false) }
        if path.hasSuffix("taskfold_child_structure_undo_archives") {
            let entries = isOwner ? archives.keys.sorted().compactMap { id -> JSON? in guard var raw = receipts[id]?.object["receipt"]?.object else { return nil }; raw["replayed"] = .bool(true); return .object(raw) } : []
            try ChildFieldNativePeer.save(state); return try encoded(["protocol": .number(1), "account": .string(account), "entries": .array(entries)])
        }
        guard isOwner else { throw ChildFieldNativeRefusal(code: "42501") }
        if path.hasSuffix("taskfold_forget_child_structure_undo") {
            let id = body["_request_id"]?.text ?? ""
            guard receipts[id]?.object["receipt"]?.object["action"] == .string("delete") else { throw ChildFieldNativeRefusal(code: "PT409") }
            archives.removeValue(forKey: id); state["structureArchives"] = .object(archives); state["structureDisposals"] = .number(Double((state["structureDisposals"]?.integer ?? 0) + 1)); try ChildFieldNativePeer.save(state)
            return try encoded(["protocol": .number(1), "account": .string(account), "request_id": .string(id), "outcome": .string("forgotten")])
        }
        if path.hasSuffix("taskfold_read_child_structure") || path.hasSuffix("taskfold_read_child_tasks") {
            if state["structureReadUnavailable"]?.flag == true { throw ChildFieldNativeRefusal(code: "PT409") }
            guard body["_id"] == .string(root.id), body["_generation"] == root["task_generation"] else { throw ChildFieldNativeRefusal(code: "PT409") }
            try ChildFieldNativePeer.save(state)
            var reply: [String: JSON] = ["protocol": .number(1), "account": .string(account), "task_id": .string(root.id), "task_generation": root["task_generation"], "project_id": root["project_id"], "projection_revision": .number(Double(state["writes"]!.integer + (state["structureWrites"]?.integer ?? 0) + 1)), "root_kind": .string(root["subtasks"] == .null ? "null" : "array"), "records": .array(rows)]
            if path.hasSuffix("taskfold_read_child_structure") { reply["protocol"] = .number(2); reply["structure_revision"] = .number(revision) }
            return try encoded(reply)
        }
        let raw = body["_body"]!.object, request = raw["request_id"]!.text
        let original: ChildTaskStructureCommand.Original?
        if raw["action"] == .string("undo"), let source = receipts[raw["undo_of"]!.text]?.object { original = .init(body: source["body"]!.object, receipt: source["receipt"]!.object) } else { original = nil }
        let command = try ChildTaskStructureCommand(account: account, origin: ChildFieldNativeIdentity.origin, body: raw, original: original)
        if path.hasSuffix("taskfold_close_child_structure") {
            let result: [String: JSON]
            if let source = receipts[request]?.object {
                guard AuthoredValueComparison.exactJSON(source["body"]!, .object(raw)) else { throw ChildFieldNativeRefusal(code: "PT409") }
                var proof = source["receipt"]!.object; proof["replayed"] = .bool(true)
                result = ["protocol": .number(1), "account": .string(account), "request_id": .string(request), "outcome": .string("applied"), "receipt": .object(proof)]
            } else {
                var closed = state["structureClosed"]?.object ?? [:]
                guard closed[request] == nil || AuthoredValueComparison.exactJSON(closed[request]!, .object(raw)) else { throw ChildFieldNativeRefusal(code: "PT409") }
                closed[request] = .object(raw); state["structureClosed"] = .object(closed)
                result = ["protocol": .number(1), "account": .string(account), "request_id": .string(request), "outcome": .string("closed"), "receipt": .null]
            }
            try ChildFieldNativePeer.save(state); return try encoded(result)
        }
        state["structureRequests"] = .number(Double((state["structureRequests"]?.integer ?? 0) + 1))
        if state["structureClosed"]?.object[request] != nil { try ChildFieldNativePeer.save(state); throw ChildFieldNativeRefusal(code: "PT410") }
        if let source = receipts[request]?.object {
            guard AuthoredValueComparison.exactJSON(source["body"]!, .object(raw)) else { throw ChildFieldNativeRefusal(code: "PT409") }
            var proof = source["receipt"]!.object; proof["replayed"] = .bool(true); try ChildFieldNativePeer.save(state); return try encoded(proof)
        }
        guard raw["task_id"] == .string(root.id), raw["task_generation"] == root["task_generation"], raw["project_id"] == root["project_id"], raw["structure_revision"] == .number(revision) else { throw ChildFieldNativeRefusal(code: "PT409") }
        let parent = raw["parent_key"] == .null ? nil : raw["parent_key"]?.text
        let nodeKey = raw["node_key"]?.text ?? raw["node"]?.object["id"]?.text.precomposedStringWithCanonicalMapping ?? original!.receipt["node_key"]!.text
        let sourceRow = rows.first { $0.object["node_key"] == .string(nodeKey) }?.object
        var tree = root["subtasks"], inverse: [String: JSON] = [:]
        if command.action == .move || command.action == .delete {
            guard sourceRow?["incarnation"] == raw["incarnation"] else { throw ChildFieldNativeRefusal(code: "PT409") }
        }
        if command.action == .insert || command.action == .move {
            let parentRow = parent.flatMap { key in rows.first { $0.object["node_key"] == .string(key) }?.object }
            guard parent == nil || parentRow != nil else { throw ChildFieldNativeRefusal(code: "PT409") }
            inverse["destination_parent"] = parent.map(JSON.string) ?? .null
            inverse["destination_kind"] = parentRow?["children_kind"] ?? .string(tree == .null ? "null" : "array")
        }
        switch command.action {
        case .insert:
            let new = fresh(raw["node"]!, restoring: false); tree = try inserting(tree, node: new, parent: parent, index: raw["index"]!.integer); inverse["digest"] = .string(try digest(new))
        case .move:
            guard let sourceRow, let value = node(tree, nodeKey) else { throw ChildFieldNativeRefusal(code: "PT409") }
            inverse["parent"] = sourceRow["parent_key"]; inverse["index"] = sourceRow["sibling_order"]
            tree = try inserting(removing(tree, key: nodeKey), node: value, parent: parent, index: raw["index"]!.integer)
        case .delete:
            guard let sourceRow, let value = node(tree, nodeKey) else { throw ChildFieldNativeRefusal(code: "PT409") }
            let path = sourceRow["identity_path"]!.list
            let versions = Dictionary(uniqueKeysWithValues: rows.filter { $0.object["identity_path"]!.list.starts(with: path) }.map { ($0.object["node_key"]!.text, JSON.object(["incarnation": $0.object["incarnation"]!, "revision": $0.object["revision"]!])) })
            guard AuthoredValueComparison.exactJSON(.object(versions), raw["subtree_versions"]!) else { throw ChildFieldNativeRefusal(code: "PT409") }
            inverse["parent"] = sourceRow["parent_key"]; inverse["index"] = sourceRow["sibling_order"]; archives[request] = value; tree = removing(tree, key: nodeKey)
        case .undo:
            let sourceID = raw["undo_of"]!.text
            guard let source = receipts[sourceID]?.object, source["reversed"] != .bool(true), source["receipt"]!.object["after_revision"] == .number(revision) else { throw ChildFieldNativeRefusal(code: "PT409") }
            let prior = source["inverse"]!.object, originalAction = source["body"]!.object["action"]!
            if originalAction == .string("insert") {
                guard let value = node(tree, nodeKey), prior["digest"] == .string(try digest(value)) else { throw ChildFieldNativeRefusal(code: "PT409") }
                tree = restoreContainer(removing(tree, key: nodeKey), parent: prior["destination_parent"]?.text.isEmpty == false ? prior["destination_parent"]!.text : nil, kind: prior["destination_kind"]!.text)
            } else if originalAction == .string("move") {
                guard let value = node(tree, nodeKey) else { throw ChildFieldNativeRefusal(code: "PT409") }
                tree = try inserting(removing(tree, key: nodeKey), node: value, parent: prior["parent"]?.text.isEmpty == false ? prior["parent"]!.text : nil, index: prior["index"]!.integer)
                tree = restoreContainer(tree, parent: prior["destination_parent"]?.text.isEmpty == false ? prior["destination_parent"]!.text : nil, kind: prior["destination_kind"]!.text)
            } else {
                guard let value = archives[sourceID] else { throw ChildFieldNativeRefusal(code: "PT409") }
                tree = try inserting(tree, node: fresh(value, restoring: true), parent: prior["parent"]?.text.isEmpty == false ? prior["parent"]!.text : nil, index: prior["index"]!.integer); archives.removeValue(forKey: sourceID)
            }
            var changed = source; changed["reversed"] = .bool(true); receipts[sourceID] = .object(changed)
        }
        let surviving = Set(flatKeys(tree)), removed = Set(rows.map { $0.object["node_key"]!.text }).subtracting(surviving)
        var incarnations = state["structureIncarnations"]!.object, versions = state["versions"]!.object
        for key in removed { incarnations.removeValue(forKey: key); versions.removeValue(forKey: key) }
        state["structureIncarnations"] = .object(incarnations); state["versions"] = .object(versions)
        root["subtasks"] = tree; let updatedRows = records(root, state: &state)
        var proof = raw.filter { ChildTaskStructureCommand.scopeKeys.contains($0.key) || ["request_id", "action"].contains($0.key) }
        proof["undo_of"] = raw["undo_of"] ?? .null; proof["before_revision"] = .number(revision); proof["after_revision"] = .number(revision + 1); proof["node_key"] = .string(nodeKey); proof["incarnation"] = updatedRows.first { $0.object["node_key"] == .string(nodeKey) }?.object["incarnation"] ?? .null; proof["replayed"] = .bool(false)
        _ = try command.confirmed(proof)
        receipts[request] = .object(["body": .object(raw), "receipt": .object(proof), "inverse": .object(inverse)])
        state["root"] = .object(root.fields); state["structureRevision"] = .number(revision + 1); state["structureReceipts"] = .object(receipts); state["structureArchives"] = .object(archives); state["structureWrites"] = .number(Double((state["structureWrites"]?.integer ?? 0) + 1))
        let lost = ProcessInfo.processInfo.arguments.contains("--child-structure-lose-reply") && state["structureLost"] != .bool(true)
        if lost { state["structureLost"] = .bool(true) }; try ChildFieldNativePeer.save(state)
        return (try JSONEncoder().encode(proof), lost)
    }
    static func flatKeys(_ rows: JSON) -> [String] { rows.list.flatMap { [$0.object["id"]!.text.precomposedStringWithCanonicalMapping] + flatKeys($0.object["subtasks"] ?? .null) } }
}
#endif
