import Foundation
import CryptoKit

/// Device-private recovery, never a server task or an automatically replayed queue.
struct TeamCompletionDraft: Codable, Equatable, Identifiable, Sendable {
    let version: Int
    let id: UUID
    let createdAt: Date
    let original: Mutation
    let record: Record
    let markedForDeletion: Bool
    let edits: [Mutation]
    let conversations: [Record]
    var scope: TeamTaskEditScope { original.teamCompletion!.scope }
    static var invalid: AppFailure {AppFailure(message:"This saved draft needs review. Your queued work is unchanged.")}
    func validate() throws {
        guard version == 1,createdAt.timeIntervalSince1970.isFinite,let command=original.teamCompletion,command.operation == .complete,
              let proposed=command.proposed,record.id == proposed.id,record["task_generation"] == proposed["task_generation"],
              record["project_id"] == .string(command.scope.project),record["user_id"] == .string(command.scope.account),
              edits.count<=100,conversations.count<=1000,Set(edits.map(\.id)).count == edits.count,!edits.contains(where:{$0.id == original.id}) else {throw Self.invalid}
        _=try command.body(for:original)
        for edit in edits {
            guard edit.table == "tasks",edit.recordID == proposed.id,edit.teamCompletion == nil,edit.teamTaskBatch == nil,
                  let scope=edit.teamTaskScope,scope.account == command.scope.account,scope.origin == command.scope.origin,
                  scope.team == command.scope.team,scope.project == command.scope.project,edit.baseline?["task_generation"] == proposed["task_generation"] else {throw Self.invalid}
            if edit.method == "PATCH" {_=try scope.body(for:edit)}
            else if edit.method == "DELETE" {_=try scope.lifecycleBody(for:edit)}
            else {throw Self.invalid}
        }
        for row in conversations {
            guard ConversationOutbox.valid(row),let change=ConversationOutbox.comment(row),change.account == command.scope.account,
                  change.projectID == command.scope.project,change.taskID == proposed.id,change.taskGeneration == proposed.string("task_generation") else {throw Self.invalid}
        }
        guard try JSONEncoder().encode(self).count<=16_000_000 else {throw Self.invalid}
    }
    func sameWork(as other:Self) -> Bool {
        version == other.version && original == other.original && record == other.record && markedForDeletion == other.markedForDeletion && edits == other.edits && conversations == other.conversations
    }
    var text: String {
        var lines=[record.title]
        if !record.string("description").isEmpty {lines.append(record.string("description"))}
        func checklist(_ rows:[JSON],depth:Int) {
            guard depth<24 else {return}
            for value in rows {let item=Record(value.object);lines.append(String(repeating:"  ",count:depth)+(item.completed ? "☑ ":"☐ ")+item.title);checklist(item["subtasks"].list,depth:depth+1)}
        }
        checklist(record["subtasks"].list,depth:0)
        if markedForDeletion {lines.append("Marked for deletion in the saved draft.")}
        var order:[String]=[],latest:[String:SharedCommentChange]=[:]
        for row in conversations {if let change=ConversationOutbox.comment(row) {if latest[change.commentID] == nil {order.append(change.commentID)};latest[change.commentID]=change}}
        for id in order {if let change=latest[id] {lines.append(change.deleting ? "Comment marked for deletion.":"Comment draft: "+change.body)}}
        return lines.joined(separator:"\n\n")
    }

    var historyText:String {
        var lines:[String]=[]
        for edit in edits {for key in ["title","description"] {if case .string(let text)?=edit.fields[key],!text.isEmpty {lines.append("Saved "+(key == "title" ? "title":"notes")+": "+text)}}}
        for row in conversations {if let change=ConversationOutbox.comment(row),!change.body.isEmpty {lines.append("Saved comment: "+change.body)}}
        return lines.joined(separator:"\n\n")
    }

    struct Retirement: Equatable, Sendable {
        let review: TeamCompletion.Review
        let currentProposed: Record?
        init(_ reply:[String:JSON],for mutation:Mutation) throws {
            guard let command=mutation.teamCompletion,command.operation == .complete,let proposed=command.proposed,
                  reply["draft_retirement_protocol"] == .number(1),reply["generation_unavailable"] == .bool(true),
                  reply["account"] == .string(command.scope.account),reply["team_id"] == .string(command.scope.team),
                  reply["project_id"] == .string(command.scope.project),reply["request_id"] == .string(mutation.id.uuidString.lowercased()),
                  reply["task_id"] == .string(proposed.id),reply["task_generation"] == proposed["task_generation"],
                  case .object(let raw)?=reply["review"] else {throw TeamCompletionDraft.invalid}
            let review=try TeamCompletion.Review(raw,for:mutation)
            guard review.isRecorded else {throw TeamCompletionDraft.invalid}
            let current:Record?
            if reply["current_proposed"] == .null {current=nil}
            else {
                guard case .object(let fields)?=reply["current_proposed"],fields["id"] == .string(proposed.id),
                      fields["project_id"] == .string(command.scope.project),TeamProjectValue.id(fields["task_generation"]?.text ?? ""),
                      fields["task_generation"] != proposed["task_generation"],TeamProjectValue.id(fields["user_id"]?.text ?? ""),
                      case .string?=fields["title"],case .bool?=fields["completed"],case .number(let v)?=fields["completion_version"],v.isFinite,v>=0,v<=9_007_199_254_740_991,v.rounded(.down)==v else {throw TeamCompletionDraft.invalid}
                current=Record(fields)
            }
            self.review=review;self.currentProposed=current
        }
    }
    struct Candidate: Equatable, Sendable {
        let draft: TeamCompletionDraft
        init?(review:TeamCompletion.Review,snapshot:Snapshot,now:Date=Date()) {
            guard review.isRecorded,snapshot.pending.first == review.mutation,let command=review.mutation.teamCompletion,
                  command.operation == .complete,let proposed=command.proposed,
                  review.successor?["task_generation"] != proposed["task_generation"] else {return nil}
            func references(_ value:JSON,_ ids:[String]) -> Bool {
                switch value {
                case .string(let text):return ids.contains(where:{text.lowercased().contains($0.lowercased())})
                case .array(let values):return values.contains{references($0,ids)}
                case .object(let fields):return fields.values.contains{references($0,ids)}
                default:return false
                }
            }
            if let root=snapshot.tables["tasks"]?.first(where:{$0.id == command.source.id}) {
                let expected=TaskCompletionRevision.applying(["completed":.bool(true),"completed_at":.string(command.completedAt)],to:command.source)
                guard root["task_generation"] == command.source["task_generation"],TeamCompletion.sameLocal(root,expected) || review.task.map({TeamCompletion.sameLocal(root,$0)}) == true else {return nil}
            }
            var edits:[Mutation]=[],comments:[Record]=[]
            for change in snapshot.pending.dropFirst() {
                if change.table == "tasks",change.recordID == proposed.id,change.baseline?["task_generation"] == proposed["task_generation"] {edits.append(change)}
                else {
                    guard let data=try? JSONEncoder().encode(change),let value=try? JSONDecoder().decode(JSON.self,from:data),!references(value,[command.source.id,proposed.id]) else {return nil}
                }
            }
            for row in snapshot.tables[ConversationOutbox.table] ?? [] {
                if let comment=ConversationOutbox.comment(row),comment.taskID == proposed.id,comment.taskGeneration == proposed.string("task_generation") {comments.append(row)}
                else if references(.object(row.fields),[proposed.id]) {return nil}
            }
            // Reconstruct the last local row even when a queued deletion removed
            // it from the visible list. Every raw edit remains in the archive.
            var projection=Snapshot(tables:["projects":[Record(["id":.string(command.scope.project)])],"tasks":[proposed]])
            var last=proposed
            for edit in edits {
                if let row=projection.tables["tasks"]?.first {last=row}
                projection.apply(edit)
                if let row=projection.tables["tasks"]?.first {last=row}
            }
            let removed=projection.tables["tasks"]?.isEmpty == true
            let local=snapshot.tables["tasks"]?.first{$0.id == proposed.id && $0["task_generation"] == proposed["task_generation"]}
            if let local {last=local}
            guard !edits.isEmpty || !comments.isEmpty || !TeamCompletion.sameLocal(last,proposed) else {return nil}
            let draft=TeamCompletionDraft(version:1,id:UUID(),createdAt:now,original:review.mutation,record:last,markedForDeletion:removed,edits:edits,conversations:comments)
            guard (try? draft.validate()) != nil else {return nil}
            self.draft=draft
        }
        func parking(_ snapshot:Snapshot,proof:Retirement) -> Snapshot? {
            guard proof.review.mutation == draft.original,let current=Candidate(review:proof.review,snapshot:snapshot),current.draft.sameWork(as:draft),let command=draft.original.teamCompletion,let proposed=command.proposed else {return nil}
            var result=snapshot
            let ids=Set(draft.edits.map(\.id)),commentIDs=Set(draft.conversations.map(\.id))
            result.pending.removeAll{ids.contains($0.id)}
            result.tables[ConversationOutbox.table]?.removeAll{commentIDs.contains($0.id)}
            result.tables["tasks"]?.removeAll{$0.id == proposed.id && $0["task_generation"] == proposed["task_generation"]}
            guard let acknowledged=proof.review.acknowledging(result) else {return nil}
            result=acknowledged
            if let row=proof.currentProposed {
                if let old=result.tables["tasks"]?.first(where:{$0.id == row.id}),old["task_generation"] != row["task_generation"] {return nil}
                result.tables["tasks"]?.removeAll{$0.id == row.id};result.tables["tasks",default:[]].append(row)
            }
            let oldComments=Set((result.tables[SharedComment.table] ?? []).filter{$0.string("task_id") == proposed.id && $0["task_generation"] == proposed["task_generation"]}.map(\.id))
            result.tables[SharedComment.table]?.removeAll{oldComments.contains($0.id)}
            result.tables[SharedMention.table]?.removeAll{oldComments.contains($0.string("comment_id"))}
            return result
        }
    }
}

/// Explicit saved drafts have no automatic retention eviction. Ordinary recovery
/// rotation cannot delete this nested directory; account removal still removes it.
struct TeamCompletionDraftVault: Sendable {
    let directory: URL
    let account: String
    let origin: String
    let key: @Sendable () throws -> SymmetricKey
    var removalGate: AccountRemovalDisk? = nil
    private static let lock=NSRecursiveLock()
    private var context:Data {Data(("com.taskfold.review-draft.v1|"+account+"|"+origin).utf8)}
    func entries() throws -> [TeamCompletionDraft] {
        Self.lock.lock();defer{Self.lock.unlock()}
        guard FileManager.default.fileExists(atPath:directory.path) else {return []}
        let urls=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey]).filter{$0.pathExtension == "taskfolddraft"}
        guard urls.count<=20 else {throw TeamCompletionDraft.invalid}
        return try urls.map {url in
            guard let id=UUID(uuidString:url.deletingPathExtension().lastPathComponent),try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else {throw TeamCompletionDraft.invalid}
            return try load(id)
        }.sorted{$0.createdAt>$1.createdAt}
    }
    func load(_ id:UUID) throws -> TeamCompletionDraft {
        Self.lock.lock();defer{Self.lock.unlock()}
        let data=try Data(contentsOf:file(id));guard data.count<=16_001_024 else {throw TeamCompletionDraft.invalid}
        let plain=try AES.GCM.open(AES.GCM.SealedBox(combined:data),using:key(),authenticating:context)
        let value=try JSONDecoder().decode(TeamCompletionDraft.self,from:plain);try value.validate()
        guard value.id == id,value.scope.account == account,value.scope.origin == origin else {throw TeamCompletionDraft.invalid}
        return value
    }
    @discardableResult func save(_ draft:TeamCompletionDraft) throws -> TeamCompletionDraft {
        if let removalGate {var free=self;free.removalGate=nil;return try removalGate.writable{try free.save(draft)}}
        Self.lock.lock();defer{Self.lock.unlock()}
        try draft.validate();guard draft.scope.account == account,draft.scope.origin == origin else {throw TeamCompletionDraft.invalid}
        let old=try entries();if let existing=old.first(where:{$0.sameWork(as:draft)}) {return existing}
        guard old.count<20,!FileManager.default.fileExists(atPath:file(draft.id).path) else {throw AppFailure(message:"Your saved drafts are full. Review or remove an older draft before parking more work.")}
        let data=try JSONEncoder().encode(draft)
        let size=try old.reduce(0){try $0+Data(contentsOf:file($1.id)).count}
        let sealed=try AES.GCM.seal(data,using:key(),authenticating:context)
        guard let bytes=sealed.combined else {throw TeamCompletionDraft.invalid}
        guard size+bytes.count<=64_000_000 else {throw AppFailure(message:"Saved drafts reached their storage limit. Review or remove an older draft first.")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try bytes.write(to:file(draft.id),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        return draft
    }
    func remove(_ id:UUID) throws {
        Self.lock.lock();defer{Self.lock.unlock()};_=try load(id);try FileManager.default.removeItem(at:file(id))
    }
    func file(_ id:UUID) -> URL {directory.appendingPathComponent(id.uuidString.lowercased()+".taskfolddraft")}
}
