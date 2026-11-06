import Foundation
import Darwin
import CryptoKit
@testable import TaskfoldCore

@main struct InterruptedCopyProcessProof {
    static func main() throws {
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2])
        let owner = try AudioCommentOwner("local-interrupted-copy-proof"), vault = AudioCommentVault(applicationSupport: root, owner: owner)
        let originalID = UUID(uuidString: "b3281000-0000-4000-8000-000000000001")!, stageID = UUID(uuidString: "b3281000-0000-4000-8000-000000000002")!
        let stage = vault.directory.appendingPathComponent(".write-" + stageID.uuidString.lowercased()), authorization = root.appendingPathComponent("copy-authorization.bin")
        let original = try AudioCommentSavedDraft(owner: owner, target: .init(task: UUID(uuidString: "b3281000-0000-4000-8000-000000000003")!, generation: UUID(uuidString: "b3281000-0000-4000-8000-000000000004")!, project: nil), caption: "Latest process recording", clip: .init(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))), id: originalID, revision: UUID(uuidString: "b3281000-0000-4000-8000-000000000005")!)
        if mode == "prepare" {
            try vault.save(original)
            try Data(contentsOf: vault.directory.appendingPathComponent("draft-" + originalID.uuidString.lowercased() + ".bin")).write(to: root.appendingPathComponent("original-proof.bin"))
            let earlier = try original.replacing(caption: "Earlier cafe\u{301} process recording", clip: original.clip)
            try earlier.encoded().write(to: stage)
            let write = try vault.interruptedWrites().first!
            let copy = try AudioCommentSavedDraft(owner: owner, target: original.target, caption: earlier.caption, clip: earlier.clip)
            let intent = try AudioCommentSaveIntent(next: copy, base: nil, reviews: [], stage: .init(write))
            try intent.encoded().write(to: authorization)
            try vault.prepareSave(intent, fence: vault.departureFence())
            guard try vault.drafts() == [original], try vault.saves() == [intent] else { throw AudioCommentStorageFailure.unreadable }
        }
        let intent = try AudioCommentSaveIntent(encoded: Data(contentsOf: authorization), owner: owner)
        if mode == "lost-commit" {
            var failing = vault; failing.fault = { if $0 == .afterDraftCommit { throw AudioCommentStorageFailure.unreadable } }
            do { _ = try failing.commitSave(intent, existingOnly: true); throw AudioCommentFailure.invalid }
            catch let error as AudioCommentStorageFailure { guard error == .unconfirmedSave else { throw error } }
            guard try vault.drafts().count == 2, try vault.saves() == [intent], FileManager.default.fileExists(atPath: stage.path) else { throw AudioCommentStorageFailure.unreadable }
        } else if mode == "finish" {
            guard try vault.commitSave(intent, existingOnly: true) == intent.next else { throw AudioCommentStorageFailure.unreadable }
        }
        let drafts = try vault.drafts(), pending = try vault.saves()
        guard drafts.contains(original), try Data(contentsOf: vault.directory.appendingPathComponent("draft-" + originalID.uuidString.lowercased() + ".bin")) == Data(contentsOf: root.appendingPathComponent("original-proof.bin")) else { throw AudioCommentStorageFailure.unreadable }
        if mode == "finish" || mode == "verify" {
            guard drafts.count == 2, drafts.contains(intent.next), pending.isEmpty, !FileManager.default.fileExists(atPath: stage.path) else { throw AudioCommentStorageFailure.unreadable }
            guard case .settled = try vault.saveState(intent) else { throw AudioCommentStorageFailure.unreadable }
        }
        let result: [String: Any] = ["mode": mode, "pid": getpid(), "drafts": drafts.count, "pending": pending.count, "stagePresent": FileManager.default.fileExists(atPath: stage.path), "copyID": intent.next.id.uuidString.lowercased(), "operationID": intent.id.uuidString.lowercased(), "originalSHA256": SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent("original-proof.bin"))).map { String(format: "%02x", $0) }.joined(), "status": "verified"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
