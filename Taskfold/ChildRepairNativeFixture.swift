#if DEBUG
import Foundation
import CryptoKit

/// Synthetic, file-backed native-control peer. It does not prove SQL custody,
/// authorization or HTTP serialization; those have independent acceptance.
@MainActor enum ChildRepairNativePeer {
    static var enabled: Bool { ChildAdoptionNativePeer.enabled && (ProcessInfo.processInfo.arguments.contains("--child-adoption-repair") || duplicateTesting) }
    static var duplicateTesting: Bool { ProcessInfo.processInfo.arguments.contains("--child-adoption-duplicate-history") }
    static func seedDuplicateHistory(_ state: inout [String: JSON]) {
        guard duplicateTesting else { return }
        var root = Record(state["root"]!.object)
        root["is_heading"] = .bool(true)
        let child: [String: JSON] = ["id": .string("review"), "title": .string("Review the layout"), "completed": .bool(false), "completion_version": .number(0), "subtasks": .array([]), "future": .object(["keep": .bool(true)])]
        root["subtasks"] = .array([.object(child)])
        var history = Snapshot(), completed = root, finished = child
        let began = TaskPlanning.instant("2026-10-20T09:00:00Z")!, ended = TaskPlanning.instant("2026-10-20T09:10:00Z")!
        TaskNodeActivity.recordLocal(Mutation(table: "tasks", recordID: root.id, method: "POST", fields: root.fields), before: nil, after: root, snapshot: &history, account: ChildFieldNativeIdentity.account, now: began)
        finished["completed"] = .bool(true); finished["completed_at"] = .string("2026-10-20T09:10:00Z"); finished["completion_version"] = .number(1)
        completed["subtasks"] = .array([.object(finished)])
        TaskNodeActivity.recordLocal(Mutation(table: "tasks", recordID: root.id, method: "PATCH", fields: ["subtasks": completed["subtasks"]]), before: root, after: completed, snapshot: &history, account: ChildFieldNativeIdentity.account, now: ended)
        var duplicate = child; duplicate["title"] = .string("Prepare the handoff")
        var older = completed; older["subtasks"] = .array([.object(finished), .object(duplicate)])
        TaskNodeActivity.recordLocal(Mutation(table: "tasks", recordID: root.id, method: "PATCH", fields: ["subtasks": older["subtasks"]]), before: completed, after: older, snapshot: &history, account: ChildFieldNativeIdentity.account, now: ended.addingTimeInterval(60))
        state["root"] = .object(older.fields)
        state["repairHistory"] = .array((history.tables[TaskNodeActivity.table] ?? []).map { .object($0.fields) })
    }
    static func extract(_ tree: JSON, key: String) -> JSON? {
        for node in tree.list {
            if node.object["id"]?.text.precomposedStringWithCanonicalMapping == key { return node }
            if let found = extract(node.object["subtasks"] ?? .null, key: key) { return found }
        }
        return nil
    }
    static let paths: Set<String> = ["/rest/v1/rpc/taskfold_preview_child_repair", "/rest/v1/rpc/taskfold_repair_children"]
    static func bytes(_ value: [String: JSON]) throws -> Data { let e = TaskfoldJSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    static func kind(_ value: JSON) -> String { switch value { case .object: return "object"; case .array: return "array"; case .string: return "string"; case .number: return "number"; case .bool: return "boolean"; case .null: return "null"; case .preserved(let value): return value.kind == .number ? "number":"object" } }
    static func edit(_ tree: inout JSON, path: [Int], action: (inout JSON) throws -> Void) throws {
        guard let index = path.first else { try action(&tree); return }
        guard case .array(var rows) = tree, rows.indices.contains(index) else { throw ChildFieldNativeRefusal(code: "PT409") }
        if path.count == 1 { try action(&rows[index]) }
        else { guard case .object(var row) = rows[index], var nested = row["subtasks"] else { throw ChildFieldNativeRefusal(code: "PT409") }; try edit(&nested,path:Array(path.dropFirst()),action:action); row["subtasks"] = nested; rows[index] = .object(row) }
        tree = .array(rows)
    }
    static func preview(_ body: [String: JSON], state: [String: JSON]) throws -> [String: JSON] {
        let review = try ChildAdoptionNativePeer.review(state), root = Record(state["root"]!.object)
        guard body["review_digest"] == review["review_digest"], body["task_id"] == .string(root.id), body["account"] == review["account"], body["task_generation"] == root["task_generation"], body["project_id"] == root["project_id"], body["workspace_id"] == .null else { throw ChildFieldNativeRefusal(code:"PT409") }
        let changes = try body["changes"]!.list.map { try ChildTaskRepairChange(raw:$0.object) }; try ChildTaskRepairChange.validate(changes)
        var tree = root["subtasks"], steps: [JSON] = [], retention: [JSON] = []
        var keepers: [(String, JSON)] = []
        for (offset,change) in changes.enumerated() {
            var before = "null", after = "null"
            if change.kind == .separateDuplicate {
                var source: JSON = .null, keeper: JSON = .null
                try edit(&tree, path: change.path) { source = $0 }
                try edit(&tree, path: try ChildTaskRepairChange.positions(change.raw["keep_path"], empty: false)) { keeper = $0 }
                let key = keeper.object["id"]?.text.precomposedStringWithCanonicalMapping ?? ""
                guard !key.isEmpty, source.object["id"]?.text.precomposedStringWithCanonicalMapping == key,
                      change.raw["reference"]?.text.precomposedStringWithCanonicalMapping != key else { throw ChildFieldNativeRefusal(code: "22023") }
                let events = (state["repairHistory"] ?? .array([])).list.filter { $0.object["node_key"]?.text.precomposedStringWithCanonicalMapping == key }
                guard !(state["repairHistory"] ?? .array([])).list.contains(where: { $0.object["node_key"] == change.raw["reference"] }) else { throw ChildFieldNativeRefusal(code: "PT409") }
                keepers.append((key, keeper))
                retention.append(.object(["ordinal": .number(Double(offset + 1)), "node_key": .string(key), "keep_path": change.raw["keep_path"]!, "event_count": .number(Double(events.count)), "completed_count": .number(Double(events.filter { $0.object["kinds"]!.list.contains(.string("completed")) }.count)), "digest": .string(try ChildAdoptionNativePeer.hash(.array(events)))]))
            }

            if change.kind == .moveItem {
                var held: JSON = .null
                let sourceParent = Array(change.path.dropLast()), index = change.path.last!
                try edit(&tree,path:sourceParent) { list in guard case .array(var rows) = list, rows.indices.contains(index) else { throw ChildFieldNativeRefusal(code:"PT409") }; held = rows.remove(at:index); list = .array(rows) }
                try edit(&tree,path:try ChildTaskRepairChange.positions(change.raw["parent"])) { list in guard case .array(var rows) = list, let destination = change.raw["index"]?.integer, destination <= rows.count else { throw ChildFieldNativeRefusal(code:"PT409") }; rows.insert(held,at:destination);list = .array(rows) }
                before = kind(held); after = before
            } else {
                try edit(&tree,path:change.path) { value in
                    before = kind(value)
                    switch change.kind {
                    case .makeRootList: value = .array([value])
                    case .assignReference, .separateDuplicate: guard case .object(var row) = value else { throw ChildFieldNativeRefusal(code:"PT409") }; row["id"] = change.raw["reference"]; value = .object(row)
                    case .makeChildrenList: guard case .object(var row) = value, let children = row["subtasks"] else { throw ChildFieldNativeRefusal(code:"PT409") }; row["subtasks"] = .array([children]); value = .object(row)
                    case .wrapItem: value = .object(["id":change.raw["reference"]!,"title":change.raw["title"]!,"legacy_original":value])
                    case .moveItem: throw CancellationError()
                    }
                    after = kind(value)
                }
            }
            steps.append(.object(["ordinal":.number(Double(offset+1)),"kind":change.raw["kind"]!,"path":change.raw["path"]!,"before_kind":.string(before),"after_kind":.string(after)]))
        }
        let metrics = ChildAdoptionNativePeer.stats(tree)
        if metrics != nil {
            for (key, keeper) in keepers {
                guard ChildTaskStructureCommand.exact(extract(tree, key: key), keeper) else { throw ChildFieldNativeRefusal(code: "22023") }
            }
        }

        var reply = body; reply["protocol"] = .number(1);reply["repair_digest"] = .string(try ChildAdoptionNativePeer.hash(.object(["body":.object(body),"proposed":tree])))
        if !retention.isEmpty {
            reply["history_retention"] = .array(retention)
            reply["repair_digest"] = .string(try ChildAdoptionNativePeer.hash(.object(["base": reply["repair_digest"]!, "history_retention": .array(retention)])))
        }
        reply["original_tree"] = root["subtasks"];reply["original_sql_null"] = .bool(false);reply["proposed_tree"] = tree;reply["steps"] = .array(steps)
        reply["proposal_valid"] = .bool(metrics != nil);reply["node_count"] = metrics.map { .number(Double($0.count)) } ?? .null;reply["remaining_issue"] = metrics == nil ? .string("identity"):.null;reply["custody_blocker"] = .null;reply["mutation_available"] = .bool(metrics != nil && state["adoptionApplied"] != .bool(true)); return reply
    }
    static func response(path: String, body: [String: JSON], state: inout [String: JSON]) throws -> (Data,Bool) {
        guard enabled, Store.shared.userID == ChildFieldNativeIdentity.account else { throw ChildFieldNativeRefusal(code:"42501") }
        if path.hasSuffix("taskfold_preview_child_repair") { guard case .object(let request)? = body["_body"] else { throw CancellationError() }; return (try bytes(preview(request,state:state)),false) }
        if body["_operation"] == .string("original") {
            guard let id = body["_body"]?.object["request_id"]?.text, let old = state["repairReceipts"]?.object[id]?.object, let original = old["original"]?.text else { throw ChildFieldNativeRefusal(code:"42501") }
            let result = old["result"]!.object
            var envelope: [String:JSON] = ["protocol":.number(1),"account":.string(ChildFieldNativeIdentity.account),"request_id":.string(id),"archive_id":result["archive_id"]!,"archive_digest":result["archive_digest"]!,"original":.null]
            envelope["original"] = .null; var data = try bytes(envelope);guard let range = data.range(of:Data("\"original\":null".utf8)) else { throw CancellationError() };data.replaceSubrange(range,with:Data("\"original\":".utf8)+Data(original.utf8));return(data,false)
        }
        guard let operation = ChildTaskRepairOperation(rawValue:body["_operation"]?.text ?? ""), case .object(let raw)? = body["_body"] else { throw CancellationError() }
        let id = try TeamOrganizationValue.id(raw["request_id"]); var receipts = state["repairReceipts"]?.object ?? [:]
        if let old = receipts[id]?.object { guard ChildTaskStructureCommand.exact(old["body"],.object(raw)) else { throw ChildFieldNativeRefusal(code:"PT409") };var result = old["result"]!.object;result["replayed"] = .bool(true);return(try bytes(result),false) }
        if operation == .check { return(try bytes(["protocol":.number(1),"account":.string(ChildFieldNativeIdentity.account),"request_id":.string(id),"state":.string("unknown")]),false) }
        var result = raw.filter { $0.key != "changes" };result["state"] = .string(operation == .send ? "applied":"closed");result["replayed"] = .bool(false)
        for key in ["archive_id","archive_digest","archive_bytes","node_count"] {result[key] = .null}
        var originalText = ""
        if operation == .send {
            let previewBody = raw.filter { ChildTaskRepairPreview.keys.contains($0.key) && $0.key != "repair_digest" }
            let proposed = try preview(previewBody,state:state)
            guard proposed["mutation_available"] == .bool(true), proposed["repair_digest"] == raw["repair_digest"] else { throw ChildFieldNativeRefusal(code:"PT409") }
            if ProcessInfo.processInfo.arguments.contains("--child-repair-unapplied") { throw URLError(.networkConnectionLost) }
            let original: [String:JSON] = ["protocol":.number(1),"root":state["root"]!,"subtasks_sql_null":.bool(false),"projection":.null,"records":.array([]),"authority":.null,"child_history":state["repairHistory"] ?? .array([]),"review_digest":raw["review_digest"]!,"repair_digest":raw["repair_digest"]!]
            let data = try bytes(original);originalText = String(decoding:data,as:UTF8.self)
            result["archive_id"] = .string(UUID().uuidString.lowercased());result["archive_digest"] = .string(SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined());result["archive_bytes"] = .number(Double(data.count));result["node_count"] = proposed["node_count"]
            var root = state["root"]!.object;root["subtasks"] = proposed["proposed_tree"];state["root"] = .object(root);state["adoptionApplied"] = .bool(true);state["repairWrites"] = .number(Double((state["repairWrites"]?.integer ?? 0)+1))
        }
        receipts[id] = .object(["body":.object(raw),"result":.object(result),"original":.string(originalText)]);state["repairReceipts"] = .object(receipts)
        let lose = operation == .send && ProcessInfo.processInfo.arguments.contains("--child-repair-lose-reply") && state["repairLost"] != .bool(true)
        if lose {state["repairLost"] = .bool(true)}; try ChildFieldNativePeer.save(state);return(try bytes(result),lose)
    }
}
#endif
