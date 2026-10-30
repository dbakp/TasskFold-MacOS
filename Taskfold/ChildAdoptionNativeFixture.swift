#if DEBUG
import Foundation
import CryptoKit

/// File-backed synthetic peer for native controls and recovery. It is available
/// only in the reserved app namespace; SQL authorization/atomicity is separate.
@MainActor enum ChildAdoptionNativePeer {
    static let privateID = UUID(uuidString: "ec990000-0000-4000-8000-000000000030")!
    static var enabled: Bool { ChildFieldNativeIdentity.enabled && ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--child-adoption-") }) }
    static var exportTesting: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--child-adoption-export") }
    static let exportFilename = "Taskfold-original-subtasks-proof"
    /// Raw RPC content deliberately includes values the legacy Double-backed
    /// cache cannot represent. The expected file is independent of the client
    /// parser and FileDocument; its exact bytes are placed into the RPC reply.
    static var exportSource: Data { Data(#"""
[
  "Keep this older text unchanged",
  {"id":"review","title":"Review café 🪴","opaque":{"integer":9007199254740993,"exponent":1e1000,"é":"composed","é":"decomposed","ordered":[null,false,{"untouched":"Line\\nkept"}]}}
]
"""#.utf8) }
    static var exportExpectedFile: URL { ChildFieldNativePeer.folder.appendingPathComponent("adoption-export-original.json") }
    static var exportReceiptFile: URL { ChildFieldNativePeer.folder.appendingPathComponent("adoption-export-receipt.json") }
    static func prepareExport(reset: Bool) throws {
        guard exportTesting else { return }
        try FileManager.default.createDirectory(at: ChildFieldNativePeer.folder, withIntermediateDirectories: true)
        let documents = URL.documentsDirectory
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let destination = documents.appendingPathComponent(exportFilename + ".json")
        if reset {
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == exportSource else { throw AppFailure(message: "Reserved export destination contains unfamiliar data.") }
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: exportReceiptFile.path) { try FileManager.default.removeItem(at: exportReceiptFile) }
        }
        let marker = documents.appendingPathComponent("Taskfold-originals-destination")
        let markerBytes = Data("Synthetic Taskfold original-content export destination".utf8)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard try Data(contentsOf: marker) == markerBytes else { throw AppFailure(message: "Reserved export marker contains unfamiliar data.") }
        } else { try markerBytes.write(to: marker, options: .atomic) }
        if FileManager.default.fileExists(atPath: exportExpectedFile.path) {
            guard try Data(contentsOf: exportExpectedFile) == exportSource else { throw AppFailure(message: "Reserved original-content fixture changed.") }
        } else { try exportSource.write(to: exportExpectedFile, options: .atomic) }
    }
    static func recordExport(_ url: URL) {
        guard exportTesting, url.isFileURL else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["url":url.absoluteString,"request":UUID().uuidString.lowercased(),"account":ChildFieldNativeIdentity.account,"root":ChildFieldNativeIdentity.rootID], options: [.sortedKeys])
            try data.write(to: exportReceiptFile, options: .atomic)
        } catch { assertionFailure("Synthetic original-content export receipt could not be saved") }
    }
    static func exportReview(_ state: [String: JSON]) throws -> Data {
        var metadata = try review(state)
        metadata["source_tree"] = .null; metadata["source_bytes"] = .number(Double(exportSource.count))
        metadata["state"] = .string("review"); metadata["issue"] = .string("identity")
        metadata["node_count"] = .null; metadata["max_depth"] = .null; metadata["can_adopt"] = .bool(false)
        metadata["review_digest"] = .string(SHA256.hash(data: exportSource + Data(try hash(state["root"]!).utf8)).map { String(format:"%02x",$0) }.joined())
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var result = try encoder.encode(metadata)
        let marker = Data("\"source_tree\":null".utf8)
        guard let range = result.range(of: marker) else { throw CancellationError() }
        result.replaceSubrange(range, with: Data("\"source_tree\":".utf8) + exportSource)
        return result
    }
    static let paths: Set<String> = ["/rest/v1/rpc/taskfold_child_adoption_targets", "/rest/v1/rpc/taskfold_review_child_adoption", "/rest/v1/rpc/taskfold_adopt_child_records"]
    static func hash(_ value: JSON) throws -> String {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func stats(_ value: JSON, depth: Int = 1) -> (count: Int, depth: Int)? {
        if value == .null { return (0,0) }
        guard case .array(let rows) = value else { return nil }
        var count = 0, deepest = 0
        for row in rows {
            guard case .object(let fields) = row, case .string? = fields["id"], depth <= 24 else { return nil }
            count += 1; deepest = max(deepest, depth)
            if let children = fields["subtasks"], children != .null {
                guard let nested = stats(children, depth: depth + 1) else { return nil }; count += nested.count; deepest = max(deepest, nested.depth)
            }
        }
        return (count,deepest)
    }
    static func review(_ state: [String: JSON]) throws -> [String: JSON] {
        let root = Record(state["root"]!.object), tree = root["subtasks"], metrics = stats(tree)
        let applied = state["adoptionApplied"] == .bool(true)
        return ["protocol":.number(1),"account":.string(ChildFieldNativeIdentity.account),"task_id":.string(root.id),"task_generation":root["task_generation"],"project_id":root["project_id"],"workspace_id":.null,
                "review_digest":.string(try hash(.object(["root":.object(root.fields),"applied":.bool(applied)]))),"state":.string(metrics == nil ? "review" : applied ? "records" : "ready"),"issue":metrics == nil ? .string("identity") : .null,
                "node_count":metrics.map{.number(Double($0.count))} ?? .null,"max_depth":metrics.map{.number(Double($0.depth))} ?? .null,"source_bytes":.number(Double(try TaskfoldJSONEncoder().encode(tree).count)),
                "root_kind":.string(tree == .null ? "null":"array"),"source_included":.bool(true),"source_tree":tree,"projection_revision":applied ? .number(1):.null,"structure_revision":applied ? .number(1):.null,"can_adopt":.bool(metrics != nil && !applied)]
    }
    static func response(path: String, body: [String: JSON], state: inout [String: JSON]) throws -> (Data,Bool) {
        guard enabled, Store.shared.userID == ChildFieldNativeIdentity.account else { throw ChildFieldNativeRefusal(code:"42501") }
        let root = Record(state["root"]!.object)
        if path.hasSuffix("taskfold_child_adoption_targets") {
            guard Set(body.keys) == ["_after", "_limit", "_id"] else { throw ChildFieldNativeRefusal(code:"22023") }
            let item: [String: JSON] = ["task_id": .string(root.id), "task_generation": root["task_generation"], "project_id": root["project_id"], "title": .string(root.title), "title_truncated": .bool(false)]
            let included = (body["_id"] == .null || body["_id"] == .string(root.id)) && (body["_after"] == .null || body["_after"]!.text < root.id)
            return (try TaskfoldJSONEncoder().encode(["protocol": JSON.number(1), "account": .string(ChildFieldNativeIdentity.account), "items": .array(included ? [.object(item)] : []), "next_after": .null]), false)
        }
        if path.hasSuffix("taskfold_review_child_adoption") {
            guard body["_id"] == .string(root.id), body["_generation"] == root["task_generation"] else { throw ChildFieldNativeRefusal(code:"PT409") }
            if exportTesting { return (try exportReview(state),false) }
            return (ChildRepairNativePeer.enabled ? try ChildRepairNativePeer.bytes(review(state)) : try TaskfoldJSONEncoder().encode(review(state)),false)
        }
        guard Set(body.keys) == ["_operation","_body"], let operation=ChildTaskAdoptionOperation(rawValue:body["_operation"]?.text ?? ""), case .object(let raw)?=body["_body"] else { throw ChildFieldNativeRefusal(code:"22023") }
        let id=try TeamOrganizationValue.id(raw["request_id"])
        var receipts=state["adoptionReceipts"]?.object ?? [:]
        let old=receipts[id]?.object
        let command=try ChildTaskAdoptionCommand(account:ChildFieldNativeIdentity.account,origin:ChildFieldNativeIdentity.origin,body:raw,nodeCount:old?["result"]?.object["node_count"]?.integer ?? stats(root["subtasks"])?.count ?? 0)
        state["adoptionRequests"] = .number(Double((state["adoptionRequests"]?.integer ?? 0)+1))
        if let old {
            guard ChildTaskStructureCommand.exact(old["body"],.object(raw)) else {throw ChildFieldNativeRefusal(code:"PT409")}
            var result=old["result"]!.object;result["replayed"] = .bool(true);try ChildFieldNativePeer.save(state);return (try TaskfoldJSONEncoder().encode(result),false)
        }
        if operation == .check {
            try ChildFieldNativePeer.save(state);return (try TaskfoldJSONEncoder().encode(["protocol":JSON.number(1),"account":.string(command.account),"request_id":.string(command.id),"state":.string("unknown")]),false)
        }
        var result=raw;result["state"] = .string(operation == .send ? "applied":"closed");result["replayed"] = .bool(false);result["node_count"] = operation == .send ? .number(Double(command.nodeCount)):.null
        if operation == .send {
            let current=try review(state)
            guard current["can_adopt"] == .bool(true), raw["review_digest"] == current["review_digest"], raw["task_id"] == .string(root.id), raw["task_generation"] == root["task_generation"], raw["project_id"] == root["project_id"],raw["workspace_id"] == .null else {throw ChildFieldNativeRefusal(code:"PT409")}
            if ProcessInfo.processInfo.arguments.contains("--child-adoption-unapplied") {try ChildFieldNativePeer.save(state);throw URLError(.networkConnectionLost)}
            state["adoptionApplied"] = .bool(true);state["adoptionWrites"] = .number(Double((state["adoptionWrites"]?.integer ?? 0)+1))
        }
        _ = try command.result(result)
        receipts[id] = .object(["body":.object(raw),"result":.object(result)]);state["adoptionReceipts"] = .object(receipts)
        let lose=operation == .send && ProcessInfo.processInfo.arguments.contains("--child-adoption-lose-reply") && state["adoptionLost"] != .bool(true)
        if lose {state["adoptionLost"] = .bool(true)}
        try ChildFieldNativePeer.save(state);return (try TaskfoldJSONEncoder().encode(result),lose)
    }
}
#endif
