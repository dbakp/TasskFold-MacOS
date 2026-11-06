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
    if ["write-expired-review", "discard-expired-review", "verify-expired-review"].contains(mode) || mode.hasPrefix("reject-expired-review:") {
        let review = try AudioCommentSavedDraft(owner:owner,target:target,caption:"Discard just this cafe\u{301} review",clip:clip,id:UUID(uuidString:"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,revision:revision)
        let next = try AudioCommentSavedDraft(owner:owner,target:target,caption:review.caption,clip:clip,id:UUID(uuidString:"dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,revision:revision)
        let intent = try AudioCommentSaveIntent(next:next,base:nil,reviews:[.init(review)],id:UUID(uuidString:"ffffffff-ffff-4fff-8fff-ffffffffffff")!)
        var captured = ""
        if mode == "write-expired-review" {
            try vault.save(review,recovery:true)
            let token = try vault.departureFence(); captured = token.uuidString.lowercased(); try vault.prepareSave(intent,fence:token)
            // Synthetic external loss of only the journal; keep the exact review.
            try FileManager.default.removeItem(at:vault.directory.appendingPathComponent("save-" + intent.id.uuidString.lowercased() + ".bin"))
        }
        if mode == "discard-expired-review" { try vault.discardExpiredReview(intent) }
        if mode.hasPrefix("reject-expired-review:") {
            guard let token = UUID(uuidString:String(mode.dropFirst("reject-expired-review:".count))) else { throw AudioCommentStorageFailure.unreadable }
            do { try vault.prepareSave(intent,fence:token); throw AudioCommentFailure.invalid }
            catch let error as AudioCommentStorageFailure where error == .conflict { }
        }
        let reviews = try vault.drafts(recovery:true), drafts = try vault.drafts(), journals = try vault.saves()
        guard mode == "write-expired-review" ? reviews == [review] : reviews.isEmpty,
              drafts.count == 2, drafts.contains(draft), !drafts.contains(where:{$0.id == next.id}), journals.isEmpty,
              try localVault.drafts() == [localDraft] else { throw AudioCommentStorageFailure.conflict }
        return ["status":"verified","pid":ProcessInfo.processInfo.processIdentifier,"fence":captured]
    }
    if mode == "prepare-revoked" || mode == "discard-revoked" || mode == "verify-revoked" || mode.hasPrefix("reject-revoked:") {
        let next = try AudioCommentSavedDraft(owner:owner,target:target,caption:"Discarded operation must stay discarded",clip:clip,id:UUID(uuidString:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,revision:revision)
        let intent = try AudioCommentSaveIntent(next:next,base:nil,reviews:[],id:UUID(uuidString:"cccccccc-cccc-4ccc-8ccc-cccccccccccc")!)
        var captured = ""
        if mode == "prepare-revoked" { let token = try vault.departureFence(); captured = token.uuidString.lowercased(); try vault.prepareSave(intent,fence:token) }
        if mode == "discard-revoked" { try vault.discardSave(intent) }
        if mode.hasPrefix("reject-revoked:") {
            guard let token = UUID(uuidString:String(mode.dropFirst("reject-revoked:".count))) else { throw AudioCommentStorageFailure.unreadable }
            do { try vault.prepareSave(intent,fence:token); throw AudioCommentFailure.invalid }
            catch let error as AudioCommentStorageFailure where error == .conflict { }
        }
        let journals = try vault.saves(), drafts = try vault.drafts()
        guard mode == "prepare-revoked" ? journals == [intent] : journals.isEmpty,
              drafts.count == 2, !drafts.contains(where:{$0.id == next.id}) else { throw AudioCommentStorageFailure.conflict }
        return ["status":"verified", "pid":ProcessInfo.processInfo.processIdentifier,"fence":captured]
    }
    if ["prepare-departure", "verify-departure", "finish-departure", "verify-finished"].contains(mode) {
        let next = try AudioCommentSavedDraft(owner:owner,target:target,caption:"Frozen cafe\u{301} before process exit",clip:clip,id:UUID(uuidString:"99999999-9999-4999-8999-999999999999")!,revision:revision)
        let intent = try AudioCommentSaveIntent(next:next,base:nil,reviews:[],id:UUID(uuidString:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
        if mode == "prepare-departure" { try vault.prepareSave(intent, fence: vault.departureFence()) }
        if mode == "finish-departure" { try vault.commitSave(intent,existingOnly:true) }
        let saved = try vault.drafts(), journals = try vault.saves()
        if mode == "prepare-departure" || mode == "verify-departure" {
            guard journals == [intent], saved == [draft] else { throw AudioCommentStorageFailure.conflict }
        } else {
            guard journals.isEmpty, saved.count == 2, saved.contains(draft), saved.contains(next) else { throw AudioCommentStorageFailure.conflict }
        }
        return ["status":"verified", "pid":ProcessInfo.processInfo.processIdentifier, "operation":intent.id.uuidString.lowercased(), "draft":next.id.uuidString.lowercased(), "digest":clip.descriptor.sha256]
    }
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
