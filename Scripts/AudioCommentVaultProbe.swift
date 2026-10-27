import Foundation
@testable import TaskfoldCore

let account = "11111111-1111-4111-8111-111111111111"
func run() throws -> [String: Any] {
    let args = CommandLine.arguments
    guard args.count == 4 else { throw AudioCommentStorageFailure.unreadable }
    let mode = args[1], root = URL(fileURLWithPath: args[2], isDirectory: true)
    guard root.lastPathComponent == "store", root.deletingLastPathComponent().lastPathComponent.hasPrefix("taskfold-audio-vault-process-") else { throw AudioCommentStorageFailure.unreadable }
    let owner = try AudioCommentOwner(account), local = try AudioCommentOwner("local")
    let vault = AudioCommentVault(applicationSupport: root, owner: owner), localVault = AudioCommentVault(applicationSupport: root, owner: local)
    if mode == "busy" {
        do { _ = try vault.drafts() }
        catch let error as AudioCommentStorageFailure where error.message == AudioCommentStorageFailure.busy.message { return ["status": "busy", "pid": ProcessInfo.processInfo.processIdentifier] }
        throw AudioCommentStorageFailure.conflict
    }
    let clip = try AudioCommentClip(data: Data(contentsOf: URL(fileURLWithPath: args[3])))
    let target = try AudioCommentTarget(task: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, generation: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, project: nil)
    let caption = "Exact cafe\u{301}\nReviewed synthetic recording 🪴"
    let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, revision = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let draft = try AudioCommentSavedDraft(owner: owner, target: target, caption: caption, clip: clip, id: id, revision: revision)
    let localDraft = try AudioCommentSavedDraft(owner: local, target: target, caption: caption, clip: clip, id: id, revision: revision)
    let publication = try AudioCommentPublication(account: UUID(uuidString: account)!, target: target, caption: caption, descriptor: clip.descriptor, operation: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!, comment: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!, asset: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!)
    if mode == "write" { try vault.save(draft); try vault.store(.init(publication: publication, clip: clip)); try localVault.save(localDraft) }
    else if mode != "verify" { throw AudioCommentStorageFailure.unreadable }
    let drafts = try vault.drafts(), pending = try vault.pending(), locals = try localVault.drafts()
    guard drafts == [draft], locals == [localDraft], pending.count == 1,
          pending[0].publication.sameIntent(as: publication), pending[0].clip.data == clip.data else { throw AudioCommentStorageFailure.conflict }
    return ["status": "verified", "pid": ProcessInfo.processInfo.processIdentifier, "drafts": drafts.count, "localDrafts": locals.count, "pending": pending.count, "digest": clip.descriptor.sha256, "operation": publication.operation.uuidString.lowercased()]
}
do {
    let data = try JSONSerialization.data(withJSONObject: run(), options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch { fputs("Synthetic audio vault process check failed: \(error.localizedDescription)\n", stderr); exit(1) }
