#if DEBUG
import Foundation

/// Reserved, local synthetic peer for genuine app controls and durable recovery.
/// Database authorization/atomicity remains proved by the independent SQL suite.
@MainActor enum ChildTransferNativePeer {
    static let destinationID = "ec990000-0000-4000-8000-000000000020"
    static var enabled: Bool { ChildFieldNativeIdentity.enabled && (ProcessInfo.processInfo.arguments.contains("--child-transfer-native") || ProcessInfo.processInfo.arguments.contains("--child-transfer-lose-reply")) }
    static var paths: Set<String> { ["/rest/v1/rpc/taskfold_transfer_child", "/rest/v1/rpc/taskfold_read_child_structure", "/rest/v1/rpc/taskfold_read_child_tasks"] }
    static func destination(_ state: inout [String: JSON]) -> Record {
        if let value = state["transferDestination"] { return Record(value.object) }
        let root = Record(["id": .string(destinationID), "user_id": .string(ChildFieldNativeIdentity.account), "task_generation": .string("ec990000-0000-4000-8000-000000000021"), "project_id": .null, "title": .string("Transfer destination"), "is_heading": .bool(true), "completed": .bool(false), "subtasks": .array([])])
        state["transferDestination"] = .object(root.fields); return root
    }
    static func revision(_ root: Record, _ state: [String: JSON]) -> Int { state[root.id == destinationID ? "transferDestinationRevision" : "structureRevision"]?.integer ?? 1 }
    static func wire(_ root: Record, state: inout [String: JSON], structure: Bool = true) -> [String: JSON] {
        var raw: [String: JSON] = ["protocol": .number(structure ? 2 : 1), "account": .string(ChildFieldNativeIdentity.account), "task_id": .string(root.id), "task_generation": root["task_generation"], "project_id": root["project_id"], "projection_revision": .number(Double((state["writes"]?.integer ?? 0) + (state["structureWrites"]?.integer ?? 0) + (state["transferWrites"]?.integer ?? 0) + 1)), "root_kind": .string(root["subtasks"] == .null ? "null" : "array"), "records": .array(ChildStructureNativePeer.records(root, state: &state))]
        if structure { raw["structure_revision"] = .number(Double(revision(root, state))) }; return raw
    }
    static func read(_ root: Record, state: inout [String: JSON]) throws -> ChildTaskStructureRead {
        guard let scope = Store.shared.childTaskFieldRecoveryScope else { throw CancellationError() }
        let context = try ChildTaskRecordContext(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: scope.session, access: scope.access, snapshot: Store.shared.snapshotRevision, root: root)
        return try .init(data: TaskfoldJSONEncoder().encode(wire(root, state: &state)), context: context)
    }
    static func response(path: String, body: [String: JSON], state: inout [String: JSON]) throws -> (Data, Bool) {
        guard enabled, Store.shared.userID == ChildFieldNativeIdentity.account else { throw ChildFieldNativeRefusal(code: "42501") }
        let dest = destination(&state), original = Record(state["root"]!.object)
        let roots = [original.id: original, dest.id: dest]
        if path != "/rest/v1/rpc/taskfold_transfer_child" {
            guard let root = roots[body["_id"]?.text ?? ""], root["task_generation"] == body["_generation"] else { throw ChildFieldNativeRefusal(code: "PT409") }
            let raw = wire(root, state: &state, structure: path.hasSuffix("taskfold_read_child_structure")); try ChildFieldNativePeer.save(state); return (try TaskfoldJSONEncoder().encode(raw), false)
        }
        guard let operation = ChildTaskTransferOperation(rawValue: body["_operation"]?.text ?? "") else { throw ChildFieldNativeRefusal(code: "22023") }
        let command = try ChildTaskTransferCommand(account: ChildFieldNativeIdentity.account, origin: ChildFieldNativeIdentity.origin, body: body["_body"]!.object)
        var receipts = state["transferReceipts"]?.object ?? [:]
        state["transferRequests"] = .number(Double((state["transferRequests"]?.integer ?? 0) + 1))
        if let old = receipts[command.id]?.object {
            guard ChildTaskStructureCommand.exact(old["body"], .object(command.body)) else { throw ChildFieldNativeRefusal(code: "PT409") }
            var proof = old["result"]!.object; proof["replayed"] = .bool(true); _ = try command.result(proof); try ChildFieldNativePeer.save(state); return (try TaskfoldJSONEncoder().encode(proof), false)
        }
        if operation == .check {
            try ChildFieldNativePeer.save(state); return (try TaskfoldJSONEncoder().encode(["protocol": JSON.number(1), "account": .string(command.account), "request_id": .string(command.id), "state": .string("unknown")]), false)
        }
        var proof: [String: JSON] = ["protocol": .number(1), "account": .string(command.account), "request_id": .string(command.id), "state": .string(operation == .close ? "closed" : "applied"), "replayed": .bool(false), "action": command.body["action"]!, "undo_of": command.body["undo_of"] ?? .null, "node_key": command.body["node_key"]!, "incarnation": command.body["incarnation"]!, "moved_count": .number(0), "return_parent": .null, "return_index": .null]
        for name in ["source", "destination"] {
            let endpoint = command.body[name]!.object
            for (field, wire) in [("task_id", "id"), ("task_generation", "generation"), ("project_id", "project"), ("structure_revision", "revision")] { proof[name + "_" + wire] = endpoint[field] }
        }
        if operation == .send {
            guard var from = roots[command.body["source"]!.object["task_id"]!.text], var to = roots[command.body["destination"]!.object["task_id"]!.text] else { throw ChildFieldNativeRefusal(code: "PT409") }
            let source = try read(from, state: &state), destinationRead = try read(to, state: &state)
            try command.review(source: source, destination: destinationRead)
            var originalReceipt: [String: JSON]?
            if command.undoing {
                guard let saved = receipts[command.family]?.object, saved["reversed"] != .bool(true) else { throw ChildFieldNativeRefusal(code: "PT409") }
                let first = try ChildTaskTransferCommand(account: command.account, origin: command.origin, body: saved["body"]!.object), result = try first.result(saved["result"]!.object)
                try command.validateUndo(original: first, receipt: result); originalReceipt = saved
            }
            let nodeKey = command.body["node_key"]!.text, placement = command.body["destination"]!.object, parent = placement["parent_key"] == .null ? nil : placement["parent_key"]!.text
            guard let node = source.records.nodes[nodeKey], let branch = ChildStructureNativePeer.node(from["subtasks"], nodeKey) else { throw ChildFieldNativeRefusal(code: "PT409") }
            proof["return_parent"] = node.parent.map(JSON.string) ?? .null; proof["return_index"] = .number(Double(node.position)); proof["moved_count"] = .number(Double(command.body["subtree_versions"]!.object.count))
            let oldKind = parent.flatMap { destinationRead.records.nodes[$0]?.childrenKind } ?? (to["subtasks"] == .null ? "null" : "array")
            from["subtasks"] = ChildStructureNativePeer.removing(from["subtasks"], key: nodeKey)
            if let prior = originalReceipt {
                let inverse = prior["inverse"]!.object
                from["subtasks"] = ChildStructureNativePeer.restoreContainer(from["subtasks"], parent: inverse["parent"] == .null ? nil : inverse["parent"]?.text, kind: inverse["kind"]!.text)
                var updated = prior; updated["reversed"] = .bool(true); receipts[command.family] = .object(updated)
            }
            to["subtasks"] = try ChildStructureNativePeer.inserting(to["subtasks"], node: branch, parent: parent, index: placement["index"]!.integer)
            var versions = state["versions"]!.object
            for key in command.body["subtree_versions"]!.object.keys { versions[key] = .number(Double((versions[key]?.integer ?? 1) + 1)) }; state["versions"] = .object(versions)
            state[from.id == destinationID ? "transferDestination" : "root"] = .object(from.fields); state[to.id == destinationID ? "transferDestination" : "root"] = .object(to.fields)
            state[from.id == destinationID ? "transferDestinationRevision" : "structureRevision"] = .number(Double(source.structureRevision + 1))
            state[to.id == destinationID ? "transferDestinationRevision" : "structureRevision"] = .number(Double(destinationRead.structureRevision + 1))
            state["transferWrites"] = .number(Double((state["transferWrites"]?.integer ?? 0) + 1))
            receipts[command.id] = .object(["body": .object(command.body), "result": .object(proof), "inverse": .object(["parent": parent.map(JSON.string) ?? .null, "kind": .string(oldKind)])])
        } else { receipts[command.id] = .object(["body": .object(command.body), "result": .object(proof)]) }
        _ = try command.result(proof); state["transferReceipts"] = .object(receipts); try ChildFieldNativePeer.save(state)
        if operation == .send, ProcessInfo.processInfo.arguments.contains("--child-transfer-lose-reply"), state["transferReplyLost"] != .bool(true) {
            state["transferReplyLost"] = .bool(true); try ChildFieldNativePeer.save(state); return (try TaskfoldJSONEncoder().encode(proof), true)
        }
        return (try TaskfoldJSONEncoder().encode(proof), false)
    }
}
#endif
