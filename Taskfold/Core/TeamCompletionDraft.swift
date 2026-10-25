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
    var copyAttempt: CopyCommand? = nil
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
        try copyAttempt?.validate(for:self)
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

    /// A confirmed copy keeps the same identities and choices across lost
    /// responses/relaunches. It is separate from the task mutation outbox.
    struct CopyCommand: Codable, Equatable, Sendable {
        let requestID: UUID
        let taskID: UUID
        let generation: UUID
        let assignments: Bool
        let reminders: Bool
        init(assignments:Bool=false,reminders:Bool=false,requestID:UUID=UUID(),taskID:UUID=UUID(),generation:UUID=UUID()) {
            self.requestID=requestID;self.taskID=taskID;self.generation=generation;self.assignments=assignments;self.reminders=reminders
        }
        func validate(for draft:TeamCompletionDraft) throws {
            guard let command=draft.original.teamCompletion,let proposed=command.proposed,
                  requestID != draft.original.id,taskID.uuidString.lowercased() != proposed.id,
                  taskID.uuidString.lowercased() != command.source.id,generation.uuidString.lowercased() != command.nextGeneration,
                  [requestID,taskID,generation].allSatisfy({TeamProjectValue.id($0.uuidString.lowercased())}) else {throw TeamCompletionDraft.invalid}
        }
        func body(for draft:TeamCompletionDraft) throws -> [String:JSON] {
            try draft.validate();try validate(for:draft)
            let result:[String:JSON]=["original":.object(try draft.original.teamCompletion!.body(for:draft.original)),"record":.object(draft.record.fields),
             "request_id":.string(requestID.uuidString.lowercased()),"task_id":.string(taskID.uuidString.lowercased()),"task_generation":.string(generation.uuidString.lowercased()),
             "copy_assignments":.bool(assignments),"copy_reminders":.bool(reminders)]
            guard try JSONEncoder().encode(result).count<=900000 else {throw AppFailure(message:"This saved draft is too large to copy. The full draft remains on this device.")}
            return result
        }
    }
    struct CopyReview: Equatable, Sendable {
        let command: CopyCommand
        let draftID: UUID
        let request: [String:JSON]
        let task: Record?
        let recorded: Bool
        let replayed: Bool
        let cancelled: Bool
        init(_ reply:[String:JSON],draft:TeamCompletionDraft,command:CopyCommand) throws {
            let request=try command.body(for:draft)
            guard reply["draft_copy_protocol"] == .number(1),reply["account"] == .string(draft.scope.account),
                  reply["team_id"] == .string(draft.scope.team),reply["project_id"] == .string(draft.scope.project),
                  reply["original_request_id"] == .string(draft.original.id.uuidString.lowercased()),
                  reply["request_id"] == .string(command.requestID.uuidString.lowercased()),reply["task_id"] == .string(command.taskID.uuidString.lowercased()),
                  reply["task_generation"] == .string(command.generation.uuidString.lowercased()),
                  reply["copy_assignments"] == .bool(command.assignments),reply["copy_reminders"] == .bool(command.reminders),
                  case .bool(let recorded)?=reply["recorded"],case .bool(let replayed)?=reply["replayed"],case .bool(let cancelled)?=reply["cancelled"],case .bool(let unavailable)?=reply["unavailable"],
                  !replayed || recorded || cancelled,!unavailable || recorded || cancelled,!cancelled || (!recorded && unavailable) else {throw TeamCompletionDraft.invalid}
            let task:Record?
            if unavailable {
                guard reply["task"] == .null else {throw TeamCompletionDraft.invalid};task=nil
            } else {
                guard case .object(let fields)?=reply["task"],fields["id"] == reply["task_id"],fields["task_generation"] == reply["task_generation"],
                      fields["project_id"] == .string(draft.scope.project),TeamProjectValue.id(fields["user_id"]?.text ?? ""),
                      case .string?=fields["title"],case .bool?=fields["completed"],case .number(let version)?=fields["completion_version"],
                      version.isFinite,version>=0,version<=9_007_199_254_740_991,version.rounded(.down)==version else {throw TeamCompletionDraft.invalid}
                if !replayed {
                    guard fields["user_id"] == .string(draft.scope.account),version == 0,fields["recurrence_parent_id"] == .null,
                          fields["notification_sent_at"] == .null,fields["comments"] == .array([]),
                          fields["source_metadata"]?.object["taskfold_draft_copy_v1"]?.object["request_id"] == reply["request_id"] else {throw TeamCompletionDraft.invalid}
                }
                let children=fields["subtasks"] ?? .array([])
                try TeamChecklist.validate(children)
                if !replayed {
                    var metadata=draft.record["source_metadata"].object
                    metadata.removeValue(forKey:"taskfold_recurrence_v1")
                    metadata["taskfold_draft_copy_v1"] = .object(["original_request":.string(draft.original.id.uuidString.lowercased()),"provisional_id":.string(draft.record.id),"provisional_generation":draft.record["task_generation"],"request_id":reply["request_id"]!])
                    guard fields["source_metadata"] == .object(metadata),fields["completed"] == draft.record["completed"],
                          fields["attachments"] == (draft.record.fields["attachments"] ?? .array([])) else {throw TeamCompletionDraft.invalid}
                    let rows=[fields]+Array(try TeamChecklist.indexed(children).values)
                    for row in rows {
                        if !command.assignments {guard row["assigned_to"] == nil || row["assigned_to"] == .null else {throw TeamCompletionDraft.invalid}}
                        if !command.reminders {
                            let off=JSON.array([.object(ReminderSpec.relative(0,id:ReminderSpec.plannedID,enabled:false).raw)])
                            guard row["reminder_specs"] == off,(row["reminders"] ?? .array([])) == .array([]) else {throw TeamCompletionDraft.invalid}
                        }
                    }
                    for (id,row) in try TeamChecklist.indexed(children) {
                        let epoch=TaskCompletion.successorID(parent:"team-checklist:"+command.requestID.uuidString.lowercased(),day:id)
                        guard row[TeamChecklist.key] == .object(["epoch":.string(epoch),"version":.number(0)]) else {throw TeamCompletionDraft.invalid}
                    }
                }
                task=Record(fields)
            }
            self.command=command;self.draftID=draft.id;self.request=request;self.task=task;self.recorded=recorded;self.replayed=replayed;self.cancelled=cancelled
        }
        func matches(_ draft:TeamCompletionDraft) -> Bool {draft.id == draftID && (try? command.body(for:draft)) == request}
        /// Never replace an already edited local copy with a retry's older row.
        /// The durable copy receipt remains recoverable from the encrypted draft.
        func installing(in snapshot:Snapshot) -> Snapshot? {
            guard recorded else {return nil}
            guard let task else {return snapshot}
            guard snapshot.tables["projects"]?.contains(where:{$0.id == task.string("project_id")}) == true else {return nil}
            if let current=snapshot.tables["tasks"]?.first(where:{$0.id == task.id}) {
                return TeamCompletion.sameLocal(current,task) ? snapshot:nil
            }
            let id=task.id.lowercased()
            func references(_ value:JSON) -> Bool {
                switch value {
                case .string(let s):return s.lowercased().contains(id)
                case .array(let values):return values.contains(where:references)
                case .object(let fields):return fields.values.contains(where:references)
                default:return false
                }
            }
            for change in snapshot.pending {
                guard let data=try? JSONEncoder().encode(change),let value=try? JSONDecoder().decode(JSON.self,from:data),!references(value) else {return nil}
            }
            guard !(snapshot.tables[ConversationOutbox.table] ?? []).contains(where:{references(.object($0.fields))}) else {return nil}
            var result=snapshot;result.tables["tasks",default:[]].append(task);return result
        }
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
    /// Confirm before writing to the server. Retrying cannot silently mint a
    /// second task or change options when the first response was lost.
    func prepareCopy(_ draft:TeamCompletionDraft,command:TeamCompletionDraft.CopyCommand) throws -> TeamCompletionDraft {
        if let removalGate {var free=self;free.removalGate=nil;return try removalGate.writable{try free.prepareCopy(draft,command:command)}}
        Self.lock.lock();defer{Self.lock.unlock()}
        var current=try load(draft.id)
        guard current.sameWork(as:draft) else {throw TeamCompletionDraft.invalid}
        if let existing=current.copyAttempt {
            guard existing == command else {throw AppFailure(message:"This draft already has a saved copy request. Check that request before trying again.")}
            return current
        }
        current.copyAttempt=command;try current.validate();_=try command.body(for:current)
        let data=try JSONEncoder().encode(current),sealed=try AES.GCM.seal(data,using:key(),authenticating:context)
        guard let bytes=sealed.combined else {throw TeamCompletionDraft.invalid}
        let oldSize=try Data(contentsOf:file(current.id)).count
        let total=try entries().reduce(0){try $0+Data(contentsOf:file($1.id)).count}
        guard total-oldSize+bytes.count<=64_000_000 else {throw AppFailure(message:"Saved drafts reached their storage limit. The copy has not been sent.")}
        try bytes.write(to:file(current.id),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        return current
    }
    func clearCopyAttempt(_ draft:TeamCompletionDraft,proof:TeamCompletionDraft.CopyReview) throws {
        if let removalGate {var free=self;free.removalGate=nil;return try removalGate.writable{try free.clearCopyAttempt(draft,proof:proof)}}
        Self.lock.lock();defer{Self.lock.unlock()}
        var current=try load(draft.id)
        guard proof.cancelled,proof.matches(current),current.sameWork(as:draft),current.copyAttempt == proof.command else {throw TeamCompletionDraft.invalid}
        current.copyAttempt=nil;try current.validate()
        let sealed=try AES.GCM.seal(JSONEncoder().encode(current),using:key(),authenticating:context)
        guard let bytes=sealed.combined else {throw TeamCompletionDraft.invalid}
        try bytes.write(to:file(current.id),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ id:UUID) throws {
        Self.lock.lock();defer{Self.lock.unlock()};_=try load(id);try FileManager.default.removeItem(at:file(id))
    }
    func file(_ id:UUID) -> URL {directory.appendingPathComponent(id.uuidString.lowercased()+".taskfolddraft")}
}

/// An explicit encrypted selection draft. It has no replay or retention-rotation
/// path: keeping synced tasks cannot silently throw away a connected local edit.
struct TeamCompletionBatchDraft: Codable, Equatable, Identifiable, Sendable {
    let version: Int
    let id: UUID
    let createdAt: Date
    let original: Mutation
    let review: [String: JSON]
    let snapshot: Snapshot
    static var invalid: AppFailure { AppFailure(message: "This saved selection needs review. Your queued changes are kept.") }
    init(review: TeamTaskBatch.Review, snapshot: Snapshot, now: Date = Date(), id: UUID = UUID()) throws {
        version = 1; self.id = id; createdAt = now; original = review.mutation; self.review = review.response; self.snapshot = snapshot
        try validate()
    }
    var scope: TeamTaskBatch { original.teamTaskBatch! }
    func validate() throws {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite, let batch = original.teamTaskBatch,
              snapshot.pending.first == original, Set(snapshot.pending.map(\.id)).count == snapshot.pending.count, snapshot.pending.count <= 1000,
              snapshot.tables.values.reduce(0, { $0 + $1.count }) <= 50000 else { throw Self.invalid }
        _ = try batch.body(for: original)
        let value = try TeamTaskBatch.Review(review, for: original)
        guard value.parkingPreview(snapshot) != nil, try JSONEncoder().encode(self).count <= 16_000_000 else { throw Self.invalid }
    }
    func sameWork(as other: Self) -> Bool { original == other.original && snapshot == other.snapshot }
    var parkedChanges: [Mutation] {
        guard let observation = try? TeamTaskBatch.Review(review, for: original), let kept = observation.parkingPreview(snapshot) else { return [] }
        let ids = Set(kept.pending.map(\.id)); return snapshot.pending.filter { !ids.contains($0.id) }
    }
    var parkedConversations: [Record] {
        guard let observation = try? TeamTaskBatch.Review(review, for: original), let kept = observation.parkingPreview(snapshot) else { return [] }
        let ids = Set((kept.tables[ConversationOutbox.table] ?? []).map(\.id))
        return (snapshot.tables[ConversationOutbox.table] ?? []).filter { !ids.contains($0.id) }
    }
    private var leaves: [Mutation] { parkedChanges.flatMap { $0.teamTaskBatch?.items ?? [$0] }.filter { $0.table == "tasks" } }
    var records: [Record] {
        var order = [String](), fallback = [String: Record]()
        for item in leaves {
            if !order.contains(item.recordID) { order.append(item.recordID) }
            if let command = item.teamCompletion {
                fallback[item.recordID] = command.source
                if let next = command.proposed {
                    if !order.contains(next.id) { order.append(next.id) }; fallback[next.id] = next
                }
            } else if item.method == "DELETE", let baseline = item.baseline { fallback[item.recordID] = Record(baseline) }
            else if item.method == "POST" { fallback[item.recordID] = Record(item.fields) }
        }
        return order.compactMap { id in snapshot.tables["tasks"]?.first(where: { $0.id == id }) ?? fallback[id] }
    }
    var text: String {
        var lines = ["Saved task selection", createdAt.formatted(date: .abbreviated, time: .shortened)]
        func checklist(_ values: [JSON], depth: Int) {
            guard depth < 24 else { return }
            for value in values { let item = Record(value.object); lines.append(String(repeating: "  ", count: depth) + (item.completed ? "☑ " : "☐ ") + item.title); checklist(item["subtasks"].list, depth: depth + 1) }
        }
        for row in records {
            lines.append(row.title); lines.append(row.completed ? "Completed" : "Open")
            if !(snapshot.tables["tasks"] ?? []).contains(where: { $0.id == row.id }) { lines.append("Removed in the saved selection") }
            for key in ["description", "due_date", "due_time", "deadline_date"] where !row.string(key).isEmpty { lines.append(row.string(key)) }
            checklist(row["subtasks"].list, depth: 0)
        }
        for item in leaves { for key in ["title", "description"] where !item.fields[key, default: .null].text.isEmpty { lines.append("Earlier saved text: " + item.fields[key]!.text) } }
        lines.append(contentsOf: TaskOrderRecovery.reviewText(parkedChanges, snapshot: snapshot, records: records))
        lines.append(contentsOf: ConversationRecoveryExport.text(parkedConversations, snapshot: snapshot))
        return lines.joined(separator: "\n\n")
    }
    /// A selection export contains only connected work, never the full private
    /// workspace snapshot, access cache, device receipts or unrelated outboxes.
    func data() throws -> Data {
        try validate()
        func json<T: Encodable>(_ value: T) throws -> JSON { try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value)) }
        var body: [String: JSON] = ["format": .string("com.taskfold.saved-selection"), "version": .number(1), "created_at": .string(ISO8601DateFormatter().string(from: createdAt)),
            "original": try json(original), "changes": try json(parkedChanges), "tasks": .array(records.map { .object($0.fields) }), "conversations": .array(parkedConversations.map { .object($0.fields) })]
        let context = ConversationRecoveryExport.context(parkedConversations, snapshot: snapshot)
        if !context.isEmpty { body["conversation_context"] = .array(context) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(body)
    }
}

struct TeamCompletionBatchDraftVault: Sendable {
    let directory: URL
    let account: String
    let origin: String
    let key: @Sendable () throws -> SymmetricKey
    var removalGate: AccountRemovalDisk? = nil
    private static let lock = NSRecursiveLock()
    private var context: Data { Data(("com.taskfold.selection-draft.v1|" + account + "|" + origin).utf8) }
    func entries() throws -> [TeamCompletionBatchDraft] {
        // All paths take the account disk fence before the in-process lock.
        // Reversing that order can deadlock a reader against a pending save.
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.entries() } }
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]).filter { $0.pathExtension == "taskfoldselection" }
        guard urls.count <= 20 else { throw TeamCompletionBatchDraft.invalid }
        return try urls.map { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw TeamCompletionBatchDraft.invalid }; return try load(id)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func load(_ id: UUID) throws -> TeamCompletionBatchDraft {
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.load(id) } }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = file(id), metadata = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isSymbolicLink != true, let size = metadata.fileSize, size <= 16_001_024 else { throw TeamCompletionBatchDraft.invalid }
        let data = try Data(contentsOf: url); guard data.count <= 16_001_024 else { throw TeamCompletionBatchDraft.invalid }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(), authenticating: context)
        let draft = try JSONDecoder().decode(TeamCompletionBatchDraft.self, from: plain); try draft.validate()
        guard draft.id == id, draft.scope.account == account, draft.scope.origin == origin else { throw TeamCompletionBatchDraft.invalid }
        return draft
    }
    @discardableResult func save(_ draft: TeamCompletionBatchDraft) throws -> TeamCompletionBatchDraft {
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.save(draft) } }
        Self.lock.lock(); defer { Self.lock.unlock() }
        try draft.validate(); guard draft.scope.account == account, draft.scope.origin == origin else { throw TeamCompletionBatchDraft.invalid }
        let old = try entries(); if let existing = old.first(where: { $0.sameWork(as: draft) }) { return existing }
        guard old.count < 20, !FileManager.default.fileExists(atPath: file(draft.id).path) else { throw AppFailure(message: "Your saved selections are full. Review or remove an older selection first. Your queued changes are kept.") }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(draft), using: key(), authenticating: context)
        guard let bytes = sealed.combined, try old.reduce(0, { try $0 + Data(contentsOf: file($1.id)).count }) + bytes.count <= 64_000_000 else { throw TeamCompletionBatchDraft.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file(draft.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // A successful save must also be readable before the caller can retire intent.
        return try load(draft.id)
    }
    func remove(_ id: UUID) throws {
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.remove(id) } }
        Self.lock.lock(); defer { Self.lock.unlock() }; _ = try load(id); try FileManager.default.removeItem(at: file(id))
    }
    func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".taskfoldselection") }
}


/// Used only after a completion-review transaction has preserved its original queue.
enum TeamCompletionRecoveryFailure {
    static func message(_ error: Error) -> String {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain {
            if failure.code == CocoaError.fileWriteOutOfSpace.rawValue {
                return "There isn’t enough storage to finish this review. Your queued work is unchanged. Free some space, then try again."
            }
            let fileErrors: Set<Int> = [CocoaError.fileReadUnknown.rawValue, CocoaError.fileReadNoPermission.rawValue, CocoaError.fileReadCorruptFile.rawValue, CocoaError.fileWriteUnknown.rawValue, CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteFileExists.rawValue, CocoaError.fileWriteInvalidFileName.rawValue, CocoaError.fileLocking.rawValue]
            if fileErrors.contains(failure.code) {
                return "Taskfold couldn’t finish saving this review. Your queued work is unchanged. Check storage access and try again."
            }
        }
        return SyncStatus.failureMessage(error)
    }
}

/// A recorded result may outlive the task incarnation its later edits targeted.
/// This separate format never changes the meaning of existing selection drafts.
struct TeamCompletionRecoveryDraft: Codable, Equatable, Identifiable, Sendable {
    let version: Int
    let id: UUID
    let createdAt: Date
    let original: Mutation
    let review: [String: JSON]
    let snapshot: Snapshot
    var account: String { original.teamCompletion?.scope.account ?? original.teamTaskBatch?.account ?? "" }
    var origin: String { original.teamCompletion?.scope.origin ?? original.teamTaskBatch?.origin ?? "" }
    static var invalid: AppFailure { AppFailure(message: "These saved edits need review. Your queued work is kept.") }
    init(single: TeamCompletion.Review, snapshot: Snapshot, now: Date = Date(), id: UUID = UUID()) throws {
        version = 1; self.id = id; createdAt = now; original = single.mutation; review = single.response; self.snapshot = snapshot
        try validate()
    }
    init(group: TeamTaskBatch.Review, snapshot: Snapshot, now: Date = Date(), id: UUID = UUID()) throws {
        version = 1; self.id = id; createdAt = now; original = group.mutation; review = group.response; self.snapshot = snapshot
        try validate()
    }
    /// The one-member collection below is private local analysis. Its synthetic
    /// header is never persisted, exported, queued or sent to a service. The
    /// archive retains the actual single command and its actual server response.
    private func observation() throws -> (TeamTaskBatch.Review, Snapshot) {
        if original.teamTaskBatch != nil { return (try TeamTaskBatch.Review(review, for: original), snapshot) }
        let single = try TeamCompletion.Review(review, for: original)
        guard single.isRecorded, let command = original.teamCompletion, let receipt = single.recorded,
              let analysisID = UUID(uuidString: WorkspaceBackup.stableID("recorded-recovery-analysis", original.id.uuidString)),
              !snapshot.pending.contains(where: { $0.id == analysisID || $0.teamTaskBatch?.items.contains(where: { $0.id == analysisID }) == true }) else { throw Self.invalid }
        let batch = TeamTaskBatch(account: command.scope.account, origin: command.scope.origin, team: command.scope.team,
                                  operation: command.operation == .complete ? .complete : .undoComplete, restores: command.related, items: [original])
        let header = TeamTaskBatch.header(batch, id: analysisID), body = try batch.body(for: header)
        let keys: Set<String> = ["review_protocol", "account", "team_id", "project_id", "task_id", "task_generation", "request_id", "operation", "series_id", "series_generation", "series_project_id", "planned_next_id", "state", "project_role", "task", "series", "successor", "receipt", "can_edit_current", "can_edit_series"]
        var member = review.filter { keys.contains($0.key) }
        member["can_edit_current"] = .bool(single.canEditCurrent); member["can_edit_series"] = .bool(single.canEditSeries)
        let receiptBody: [String: JSON] = ["batch_protocol": .number(1), "account": .string(account), "team_id": .string(batch.team), "request_id": body["request_id"]!, "operation": .string(command.operation.rawValue), "related_request": body["related_request"] ?? .null, "items": .array([.object(receipt)]), "replayed": .bool(true)]
        let response: [String: JSON] = ["group_review_protocol": .number(1), "account": .string(account), "team_id": .string(batch.team), "request_id": body["request_id"]!, "operation": .string(command.operation.rawValue), "related_request": body["related_request"] ?? .null, "state": .string("recorded"), "items": .array([.object(member)]), "receipt": .object(receiptBody)]
        var local = snapshot; local.pending[0] = header
        return (try TeamTaskBatch.Review(response, for: header), local)
    }
    private func preview() -> Snapshot? {
        guard snapshot.pending.first == original, let (value, local) = try? observation() else { return nil }
        return value.recordedDraftPreview(local)
    }
    func validate() throws {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite, snapshot.pending.first == original,
              Set(snapshot.pending.map(\.id)).count == snapshot.pending.count, snapshot.pending.count <= 1000, snapshot.tables.values.reduce(0, { $0 + $1.count }) <= 50000,
              preview() != nil, parkedChanges.count > 1 || !parkedConversations.isEmpty,
              try JSONEncoder().encode(self).count <= 16_000_000 else { throw Self.invalid }
    }
    func preserving(readable cache: TeamWorkspaceCache) -> Snapshot? {
        guard (try? validate()) != nil, let (value, local) = try? observation() else { return nil }
        return value.preservingRecordedDraft(local, readable: cache)
    }
    func sameWork(as other: Self) -> Bool { original == other.original && review == other.review && snapshot == other.snapshot }
    var parkedChanges: [Mutation] {
        guard let kept = preview() else { return [] }
        let ids = Set(kept.pending.map(\.id)); return snapshot.pending.filter { !ids.contains($0.id) }
    }
    var parkedConversations: [Record] {
        guard let kept = preview() else { return [] }
        let ids = Set((kept.tables[ConversationOutbox.table] ?? []).map(\.id))
        return (snapshot.tables[ConversationOutbox.table] ?? []).filter { !ids.contains($0.id) }
    }
    private var leaves: [Mutation] { parkedChanges.flatMap { $0.teamTaskBatch?.items ?? [$0] }.filter { $0.table == "tasks" } }
    var records: [Record] {
        var order = [String](), fallback = [String: Record]()
        for item in leaves {
            if !order.contains(item.recordID) { order.append(item.recordID) }
            if let command = item.teamCompletion {
                fallback[item.recordID] = command.source
                if let next = command.proposed {
                    if !order.contains(next.id) { order.append(next.id) }; fallback[next.id] = next
                }
            } else if let baseline = item.baseline {
                var row = Record(baseline)
                if item.method == "PATCH" { for (key, value) in item.fields { row[key] = value } }
                fallback[item.recordID] = row
            } else if item.method == "POST" { fallback[item.recordID] = Record(item.fields) }
        }
        return order.compactMap { id in snapshot.tables["tasks"]?.first(where: { $0.id == id }) ?? fallback[id] }
    }
    // Listing a draft must not replay its full saved queue on the UI thread.
    var title: String { original.teamCompletion?.source.title ?? original.teamTaskBatch?.items.first?.teamCompletion?.source.title ?? "Saved edits" }
    var text: String {
        var lines = ["Saved edits", createdAt.formatted(date: .abbreviated, time: .shortened)]
        func checklist(_ values: [JSON], depth: Int) {
            guard depth < 24 else { return }
            for value in values { let item = Record(value.object); lines.append(String(repeating: "  ", count: depth) + (item.completed ? "☑ " : "☐ ") + item.title); checklist(item["subtasks"].list, depth: depth + 1) }
        }
        for row in records {
            lines.append(row.title); lines.append(row.completed ? "Completed" : "Open")
            if !(snapshot.tables["tasks"] ?? []).contains(where: { $0.id == row.id }) { lines.append("Removed in the saved edits") }
            for key in ["description", "due_date", "due_time", "deadline_date"] where !row.string(key).isEmpty { lines.append(row.string(key)) }
            checklist(row["subtasks"].list, depth: 0)
        }
        for item in leaves { for key in ["title", "description"] where !item.fields[key, default: .null].text.isEmpty { lines.append("Earlier saved text: " + item.fields[key]!.text) } }
        lines.append(contentsOf: TaskOrderRecovery.reviewText(parkedChanges, snapshot: snapshot, records: records))
        lines.append(contentsOf: ConversationRecoveryExport.text(parkedConversations, snapshot: snapshot))
        return lines.joined(separator: "\n\n")
    }
    /// No full snapshot, permission cache, unrelated outbox or analysis envelope
    /// crosses the explicit export boundary.
    func data() throws -> Data {
        try validate()
        func json<T: Encodable>(_ value: T) throws -> JSON { try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value)) }
        var body: [String: JSON] = ["format": .string("com.taskfold.saved-edits"), "version": .number(1), "created_at": .string(ISO8601DateFormatter().string(from: createdAt)), "original": try json(original), "changes": try json(parkedChanges), "tasks": .array(records.map { .object($0.fields) }), "conversations": .array(parkedConversations.map { .object($0.fields) })]
        let context = ConversationRecoveryExport.context(parkedConversations, snapshot: snapshot)
        if !context.isEmpty { body["conversation_context"] = .array(context) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(body)
    }
}

struct TeamCompletionRecoveryDraftVault: Sendable {
    let directory: URL
    let account: String
    let origin: String
    let key: @Sendable () throws -> SymmetricKey
    var removalGate: AccountRemovalDisk? = nil
    private static let lock = NSRecursiveLock()
    private var context: Data { Data(("com.taskfold.recorded-recovery.v1|" + account + "|" + origin).utf8) }
    private func checkDirectory() throws {
        let meta = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard meta.isSymbolicLink != true, meta.isDirectory == true else { throw TeamCompletionRecoveryDraft.invalid }
    }
    func entries() throws -> [TeamCompletionRecoveryDraft] {
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.entries() } }
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }; try checkDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "taskfoldrecovery" }
        guard urls.count <= 20 else { throw TeamCompletionRecoveryDraft.invalid }
        _ = try urls.reduce(0) { total, url in
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size >= 0, size <= 16_001_024, total <= 64_000_000 - size else { throw TeamCompletionRecoveryDraft.invalid }
            return total + size
        }
        return try urls.map { url in guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw TeamCompletionRecoveryDraft.invalid }; return try load(id) }.sorted { $0.createdAt > $1.createdAt }
    }
    func load(_ id: UUID) throws -> TeamCompletionRecoveryDraft {
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.load(id) } }
        Self.lock.lock(); defer { Self.lock.unlock() }; try checkDirectory()
        let url = file(id), meta = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard meta.isSymbolicLink != true, let size = meta.fileSize, size <= 16_001_024 else { throw TeamCompletionRecoveryDraft.invalid }
        let data = try Data(contentsOf: url); guard data.count <= 16_001_024 else { throw TeamCompletionRecoveryDraft.invalid }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(), authenticating: context)
        let draft = try JSONDecoder().decode(TeamCompletionRecoveryDraft.self, from: plain); try draft.validate()
        guard draft.id == id, draft.account == account, draft.origin == origin else { throw TeamCompletionRecoveryDraft.invalid }; return draft
    }
    @discardableResult func save(_ draft: TeamCompletionRecoveryDraft) throws -> TeamCompletionRecoveryDraft {
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.save(draft) } }
        Self.lock.lock(); defer { Self.lock.unlock() }
        try draft.validate(); guard draft.account == account, draft.origin == origin else { throw TeamCompletionRecoveryDraft.invalid }
        let old = try entries(); if let existing = old.first(where: { $0.sameWork(as: draft) }) { return existing }
        guard old.count < 20, !FileManager.default.fileExists(atPath: file(draft.id).path) else { throw AppFailure(message: "Your saved edits are full. Review or remove an older draft first. Your queued work is kept.") }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(draft), using: key(), authenticating: context)
        guard let bytes = sealed.combined, try old.reduce(0, { try $0 + Data(contentsOf: file($1.id)).count }) + bytes.count <= 64_000_000 else { throw TeamCompletionRecoveryDraft.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try checkDirectory()
        try bytes.write(to: file(draft.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return try load(draft.id)
    }
    func remove(_ id: UUID) throws {
        if let removalGate { var free = self; free.removalGate = nil; return try removalGate.writable { try free.remove(id) } }
        Self.lock.lock(); defer { Self.lock.unlock() }; _ = try load(id); try FileManager.default.removeItem(at: file(id))
    }
    func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".taskfoldrecovery") }
}
