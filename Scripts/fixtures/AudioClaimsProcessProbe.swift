import Foundation
import Darwin
@testable import TaskfoldCore

@main struct AudioClaimsProcessProbe {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 4 else { throw AudioCommentStorageFailure.unreadable }
            let root = URL(fileURLWithPath: args[2], isDirectory: true), parent = root.deletingLastPathComponent()
            guard root.lastPathComponent == "store", parent.lastPathComponent.hasPrefix("taskfold-audio-claims-process-") else { throw AudioCommentStorageFailure.unreadable }
            let owner = try AudioCommentOwner("local-process-claims")
            let vault = AudioCommentVault(applicationSupport: root, owner: owner)
            let clip = try AudioCommentClip(data: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let target = try AudioCommentTarget(task: UUID(uuidString: "b3280000-0000-4000-8000-000000000001")!, generation: UUID(uuidString: "b3280000-0000-4000-8000-000000000002")!, project: nil)
            let review = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Shared cafe\u{301}\nProcess proof", clip: clip, id: UUID(uuidString: "b3280000-0000-4000-8000-000000000003")!, revision: UUID(uuidString: "b3280000-0000-4000-8000-000000000004")!)
            var status: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]
            if args[1] == "seed" {
                try vault.save(review, recovery: true); status["status"] = "seeded"
            } else if args[1].hasPrefix("worker-") {
                let index = String(args[1].suffix(1)); guard index == "1" || index == "2" else { throw AudioCommentStorageFailure.unreadable }
                // Both processes establish the exact source snapshot before the
                // parent releases them; no process-global coordinator is shared.
                guard try vault.drafts(recovery: true).contains(review) || parent.appendingPathComponent("go").path.withCString({ access($0, F_OK) == 0 }) else { throw AudioCommentStorageFailure.conflict }
                try Data().write(to: parent.appendingPathComponent("ready-" + index))
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: parent.appendingPathComponent("go").path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                guard FileManager.default.fileExists(atPath: parent.appendingPathComponent("go").path) else { throw AudioCommentStorageFailure.busy }
                let next = try AudioCommentSavedDraft(owner: owner, target: target, caption: review.caption, clip: clip, id: UUID(uuidString: "b3280000-0000-4000-8000-00000000001" + index)!, revision: UUID(uuidString: "b3280000-0000-4000-8000-00000000002" + index)!, origin: .init(review))
                let intent = try AudioCommentSaveIntent(next: next, base: nil, reviews: [.init(review)], id: UUID(uuidString: "b3280000-0000-4000-8000-00000000003" + index)!)
                let saved: AudioCommentSavedDraft
                do { saved = try vault.commitSave(intent) }
                catch let redirect as AudioCommentSaveRedirect { saved = try vault.commitSave(redirect.intent, existingOnly: true) }
                status["status"] = "saved"; status["savedID"] = saved.id.uuidString.lowercased(); status["digest"] = saved.clip.descriptor.sha256
            } else if args[1] == "verify" {
                let items = try vault.drafts()
                guard items.count == 1, items[0].origin == AudioCommentReviewReference(review), items[0].sameContent(as: review), try vault.saves().isEmpty, try vault.drafts(recovery: true).isEmpty else { throw AudioCommentStorageFailure.conflict }
                status["status"] = "verified"; status["savedID"] = items[0].id.uuidString.lowercased(); status["drafts"] = items.count
            } else { throw AudioCommentStorageFailure.unreadable }
            print(String(decoding: try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]), as: UTF8.self))
        } catch let error as AudioCommentStorageFailure where error == .busy {
            print("{\"status\":\"busy\",\"pid\":\(ProcessInfo.processInfo.processIdentifier)}"); exit(75)
        } catch { fputs("Synthetic audio claim process failed: \(error)\n", stderr); exit(1) }
    }
}
