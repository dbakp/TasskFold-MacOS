import Foundation
import Darwin
@testable import TaskfoldCore

@main struct AudioCommentPublicationProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let input = try JSONDecoder().decode(Record.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let account = UUID(uuidString: input.string("account"))!, root = URL(fileURLWithPath: args[1]), mode = args[4]
        let clip = try AudioCommentClip(data: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let source = try AudioCommentSavedDraft(owner: .init(account.uuidString.lowercased()), target: .init(task: UUID(uuidString: input.string("task"))!, generation: UUID(uuidString: input.string("generation"))!, project: nil), caption: input.string("caption"), clip: clip, id: UUID(uuidString: input.string("source"))!, revision: UUID(uuidString: input.string("revision"))!)
        var disk = try AudioCommentPublicationDisk(root: root, account: account, origin: input.string("origin"))
        if mode == "crash-before" { disk.fault = { if case .beforeRename = $0 { exit(76) } } }
        if mode == "crash-after" { disk.fault = { if case .afterRename = $0 { exit(77) } } }
        if mode == "hold" { disk.fault = { if case .beforeRename = $0 { print("LOCKED"); fflush(stdout); usleep(400000) } } }
        do {
            var journal: AudioCommentPublicationJournal
            if mode == "show" { guard let current = try disk.journals().first else { print("{}"); return }; journal = current }
            else { journal = try disk.prepare(source) }
            if mode == "confirm" || mode == "confirm-crash" {
                var fields = journal.publication.record.fields; fields.removeValue(forKey: "version")
                fields["protocol"] = .number(1); fields["author_id"] = .string(account.uuidString.lowercased()); fields["state"] = .string("published")
                fields["reserved_at"] = .string("2026-10-28T15:00:00Z"); fields["expires_at"] = .string("2026-10-29T15:00:00Z"); fields["published_at"] = .string("2026-10-28T15:00:01Z")
                if mode == "confirm-crash" { disk.fault = { if case .afterRename = $0 { exit(77) } } }
                journal = try disk.confirm(journal, receipt: .init(record: Record(fields), publication: journal.publication))
            }
            var fields = journal.publication.record.fields; fields["published"] = .bool(journal.receipt != nil); fields["has_audio"] = .bool(journal.clip != nil)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; print(String(decoding: try encoder.encode(Record(fields)), as: UTF8.self))
        } catch let error as AudioCommentStorageFailure where error == .busy { exit(75) }
    }
}
