#if DEBUG
import Foundation
import CryptoKit

/// Synthetic, file-backed native-control peer. It does not prove SQL custody,
/// authorization or HTTP serialization; those have independent acceptance.
@MainActor enum ChildRepairNativePeer {
    static var enabled: Bool { ChildAdoptionNativePeer.enabled && ProcessInfo.processInfo.arguments.contains("--child-adoption-repair") }
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
        var tree = root["subtasks"], steps: [JSON] = []
        for (offset,change) in changes.enumerated() {
            var before = "null", after = "null"
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
                    case .assignReference: guard case .object(var row) = value else { throw ChildFieldNativeRefusal(code:"PT409") }; row["id"] = change.raw["reference"]; value = .object(row)
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
        var reply = body; reply["protocol"] = .number(1);reply["repair_digest"] = .string(try ChildAdoptionNativePeer.hash(.object(["body":.object(body),"proposed":tree])))
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
            let original: [String:JSON] = ["protocol":.number(1),"root":state["root"]!,"subtasks_sql_null":.bool(false),"projection":.null,"records":.array([]),"authority":.null,"child_history":.array([]),"review_digest":raw["review_digest"]!,"repair_digest":raw["repair_digest"]!]
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
