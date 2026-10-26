import Foundation

/// One durable intent and one RPC cover the complete selection. Member requests
/// remain frozen inside the envelope; a transport retry never rebuilds the group.
struct TeamTaskBatch: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case delete, restore, edit, complete
        case undoComplete = "undo_complete"
    }
    var completionOperation: TeamCompletion.Operation? { operation == .complete ? .complete : operation == .undoComplete ? .undo : nil }
    var isCompletion: Bool { completionOperation != nil }
    static let planningFields: Set<String> = ["priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes", "assigned_to", "labels"]
    static func dateFields(task: Record, day: String?) -> [String: JSON] {
        guard let day else { return ["due_date": .null, "due_time": .null, "time_zone": .null, "scheduled_at": .null] }
        guard Dates.parse(day) != nil else { return [:] }
        let fields = TaskPlanner.dayFields(task: task, day: day)
        // Already-correct members still participate in the complete source review.
        return fields.isEmpty ? ["due_date": .string(day)] : fields
    }
    let account: String
    let origin: String
    let team: String
    let operation: Operation
    let restores: UUID?
    var items: [Mutation]

    static var conflict: AppFailure { AppFailure(message:"This selection changed. Your saved changes remain on this device. Review the selected tasks before trying again.") }
    static var invalid: AppFailure { AppFailure(message: "This selection needs review. Your saved changes remain on this device.") }
    static func header(_ batch: Self, id: UUID = UUID()) -> Mutation {
        Mutation(id:id,table:"tasks",recordID:id.uuidString.lowercased(),method:"TEAM_BATCH",fields:[:],teamTaskBatch:batch)
    }
    func body(for header: Mutation) throws -> [String:JSON] {
        guard header.table == "tasks",header.method == "TEAM_BATCH",header.recordID == header.id.uuidString.lowercased(),
              header.teamTaskBatch == self,header.fields.isEmpty,header.baseline == nil,header.teamTaskScope == nil,header.teamCompletion == nil,header.organizationOrder == nil,header.orderRecovery == nil,
              [account,team].allSatisfy(TeamProjectValue.id),(1...100).contains(items.count),
              (isCompletion ? (operation != .undoComplete || restores != nil) : (operation == .restore) == (restores != nil)) else { throw Self.invalid }
        let ids=items.map(\.recordID),nonces=items.map(\.id)
        guard ids == ids.sorted(),Set(ids).count == items.count,Set(nonces).count == items.count,!nonces.contains(header.id), restores != header.id, restores.map({ !nonces.contains($0) }) ?? true else { throw Self.invalid }
        let values=try items.map { item -> JSON in
            if let action = completionOperation {
                guard item.teamTaskBatch == nil, let command = item.teamCompletion,
                      command.operation == action, command.scope.account == account, command.scope.origin == origin, command.scope.team == team,
                      (command.related != nil) == (restores != nil) else { throw Self.invalid }
                return .object(try command.body(for: item))
            }
            guard item.teamCompletion == nil, item.teamTaskBatch == nil, let scope=item.teamTaskScope,scope.account == account,scope.origin == origin,scope.team == team else { throw Self.invalid }
            if operation == .edit {
                // Absent nullable planning values mean null in saved task rows.
                // Normalize only validation; keep the frozen row byte-for-byte.
                var checked = item
                for key in item.fields.keys where checked.baseline?[key] == nil { checked.baseline?[key] = .null }
                let edit = try scope.body(for: checked)
                guard edit["checklist_restore_from"] == nil, let record = item.baseline, record["id"] == .string(item.recordID),
                      Set(item.fields.keys).isSubset(of: Self.planningFields) else { throw Self.invalid }
                return .object(edit.filter { $0.key != "base" }.merging(["record": .object(record)]) { _, new in new })
            }
            guard try scope.lifecycleAction(for:item) == operation.rawValue else { throw Self.invalid }
            return .object(try scope.lifecycleBody(for:item))
        }
        var body:[String:JSON]=["team_id":.string(team),"request_id":.string(header.id.uuidString.lowercased()),"items":.array(values)]
        if let restores { body[isCompletion ? "related_request" : "restores"] = .string(restores.uuidString.lowercased()) }
        guard try JSONEncoder().encode(body).count <= 1_500_000 else { throw AppFailure(message:"This selection is too large. Choose fewer tasks.") }
        return body
    }
    func confirm(_ reply:[String:JSON],for header:Mutation) throws {
        let request=try body(for:header)
        if isCompletion { _ = try completionReceipts(reply, for: header); return }
        let expected=request["items"]!.list.map { value -> JSON in
            let row=value.object
            return .object(Dictionary(uniqueKeysWithValues:["task_id","project_id","task_generation","request_id"].map{($0,row[$0]!)}))
        }
        guard reply["protocol"] == .number(1),reply["account"] == .string(account),reply["team_id"] == .string(team),
              reply["request_id"] == request["request_id"],reply["operation"] == .string(operation.rawValue),
              reply["restores"] == (request["restores"] ?? .null),reply["items"] == .array(expected),case .bool? = reply["replayed"] else { throw Self.invalid }
    }
    static func preparing(_ changes:[Mutation],snapshot:Snapshot) throws -> [Mutation] {
        if changes.contains(where:{$0.teamTaskBatch != nil || $0.method == "TEAM_BATCH"}) {
            guard changes.count == 1,let batch=changes[0].teamTaskBatch else { throw Self.invalid }
            _=try batch.body(for:changes[0]);return changes
        }
        if changes.count > 1 && changes.contains(where: { $0.teamCompletion != nil || $0.method == "TEAM_COMPLETE" }) { throw Self.invalid }
        if changes.count > 1 && changes.contains(where: { $0.teamTaskScope != nil && $0.method == "PATCH" }) { throw Self.invalid }
        let scoped=changes.filter{$0.teamTaskScope != nil && $0.method == "DELETE"}
        if !scoped.isEmpty && changes.count > 1 && scoped.count != changes.count { throw AppFailure(message:"Choose tasks from one workspace for this action.") }
        guard scoped.count > 1 else { return changes }
        guard scoped.count == changes.count,let first=scoped.first?.teamTaskScope else { throw AppFailure(message:"Choose tasks from one workspace for this action.") }
        let items=try scoped.map { raw -> Mutation in
            guard let scope=raw.teamTaskScope,scope.account == first.account,scope.origin == first.origin,scope.team == first.team,
                  let row=snapshot.tables["tasks"]?.first(where:{$0.id == raw.recordID}) else { throw Self.invalid }
            var item=raw;if item.baseline == nil { item.baseline=row.fields }
            return try scope.capturing(item,existing:row)
        }.sorted{$0.recordID<$1.recordID}
        let batch=Self(account:first.account,origin:first.origin,team:first.team,operation:.delete,restores:nil,items:items)
        let result=header(batch);_=try batch.body(for:result);return [result]
    }
    func inverse(of header:Mutation,snapshot:Snapshot) throws -> Mutation {
        _=try body(for:header)
        if isCompletion {
            let inverse = try items.map { item -> Mutation in
                guard let command = item.teamCompletion else { throw Self.invalid }
                return try command.inverse(of: item)
            }
            return Self.header(Self(account: account, origin: origin, team: team, operation: operation == .complete ? .undoComplete : .complete, restores: header.id, items: inverse))
        }
        let inverseItems=try items.map { item -> Mutation in
            guard var scope=item.teamTaskScope else { throw Self.invalid }
            if operation == .edit {
                guard let before = item.baseline else { throw Self.invalid }
                var expected = before
                for (key, value) in item.fields { expected[key] = value }
                let fields = Dictionary(uniqueKeysWithValues: item.fields.keys.map { ($0, before[$0] ?? .null) })
                return Mutation(table: "tasks", recordID: item.recordID, method: "PATCH", fields: fields, baseline: expected, teamTaskScope: scope)
            }
            if operation == .delete {
                guard let fields=item.baseline else { throw Self.invalid }
                let before=Record(fields)
                scope.restoreRequest=item.id
                let mutation=Mutation(table:"tasks",recordID:item.recordID,method:"POST",fields:before.fields,insertOnly:true,teamTaskScope:scope)
                return TaskGeneration.restoring(mutation,existing:nil)
            }
            scope.restoreRequest=nil
            return Mutation(table:"tasks",recordID:item.recordID,method:"DELETE",fields:[:],baseline:item.fields,teamTaskScope:scope)
        }
        let value=Self(account:account,origin:origin,team:team,operation:operation == .edit ? .edit : operation == .delete ? .restore:.delete,
                       restores:operation == .delete ? header.id:nil,items:inverseItems)
        return Self.header(value)
    }
    static func historyAction(_ original:Mutation, snapshot: Snapshot? = nil) -> Mutation {
        guard var batch=original.teamTaskBatch else { return TeamTaskEditScope.historyAction(original) }
        if batch.isCompletion {
            // A new action requires the current source revision and fresh member
            // nonces. A transport retry bypasses this method entirely.
            guard let snapshot else { return original }
            batch.items = batch.items.map { TeamCompletion.historyAction($0, snapshot: snapshot) }
            return header(batch)
        }
        batch.items=batch.items.map { old in
            var value=old;value.id=UUID()
            if batch.operation == .restore { value=TaskGeneration.restoring(value,existing:nil) }
            return value
        }
        return header(batch)
    }
    func apply(to snapshot:inout Snapshot,header:Mutation) -> Bool {
        if isCompletion {
            guard (try? body(for: header)) != nil else { return false }
            // Validate all sources before projecting any of the members.
            for item in items {
                guard let command = item.teamCompletion, let current = snapshot.tables["tasks"]?.first(where: { $0.id == item.recordID }),
                      command.operation != .complete || TeamCompletion.sameLocal(current, command.source) else { return false }
            }
            var result = snapshot
            for item in items { guard item.teamCompletion!.apply(to: &result, header: item) else { return false } }
            snapshot = result; return true
        }
        guard (try? body(for:header)) != nil,
              items.allSatisfy({ item in
                  guard let scope=item.teamTaskScope,snapshot.tables["projects"]?.contains(where:{$0.id == scope.project}) == true else { return false }
                  let current=snapshot.tables["tasks"]?.first(where:{$0.id == item.recordID})
                  if operation == .edit { return current != nil && current?.fields == item.baseline && TaskGeneration.permitsLocalAction(item, existing: current) }
                  if operation == .delete { return TaskGeneration.permitsLocalAction(item,existing:current) }
                  return current == nil || current?["task_generation"] == item.fields["task_generation"]
              }) else { return false }
        var result=snapshot
        for item in items {
            if operation == .delete, result.tables["tasks"]?.contains(where:{$0.id == item.recordID}) != true { continue }
            result.apply(item)
        }
        snapshot=result;return true
    }
}


/// Opening-time authority for one reviewed selection. It is deliberately not
/// Codable: durable retries carry the resulting command, never editor authority.
struct TeamTaskDeletionSelection: Equatable, Sendable {
    let drafts: [TeamTaskEditorDraft]
    let requestID: UUID
    private let memberRequests: [String: UUID]
    init(drafts: [TeamTaskEditorDraft], requestID: UUID = UUID()) throws {
        guard (2...100).contains(drafts.count), Set(drafts.map { $0.source.id }).count == drafts.count,
              let first = drafts.first,
              drafts.allSatisfy({ $0.kind == .existing && $0.workspace == first.workspace && $0.session == first.session &&
                  $0.scope.account == first.scope.account && $0.scope.origin == first.scope.origin && $0.scope.team == first.scope.team && $0.accessToken == first.accessToken }) else {
            throw AppFailure(message: "Choose between 2 and 100 tasks from one shared team. Nothing has been removed.")
        }
        let parents = Dictionary(uniqueKeysWithValues: drafts.map { ($0.source.id, $0.source.string("recurrence_parent_id")) })
        for id in parents.keys {
            var seen: Set<String> = [], cursor = id
            while let parent = parents[cursor] {
                guard seen.insert(cursor).inserted else { throw TeamTaskBatch.invalid }
                cursor = parent
            }
        }
        self.drafts = drafts.sorted { $0.source.id < $1.source.id }; self.requestID = requestID
        memberRequests = Dictionary(uniqueKeysWithValues: drafts.map { ($0.source.id, UUID()) })
    }
    func mutation(current: [String: Record], workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) throws -> Mutation {
        let items = try drafts.map { draft in
            try draft.deletion(current: current[draft.source.id], workspace: workspace, session: session, cache: cache, enabled: enabled, requestID: memberRequests[draft.source.id]!)
        }
        let first = drafts[0].scope
        let batch = TeamTaskBatch(account: first.account, origin: first.origin, team: first.team, operation: .delete, restores: nil, items: items)
        let header = TeamTaskBatch.header(batch, id: requestID)
        _ = try batch.body(for: header)
        return header
    }
}



/// Opening authority for a planning picker. Choices never reacquire source rows.
struct TeamTaskPlanningAdmission: Equatable, Sendable {
    let drafts: [TeamTaskEditorDraft]
    init(drafts: [TeamTaskEditorDraft]) throws {
        guard (1...100).contains(drafts.count), Set(drafts.map { $0.source.id }).count == drafts.count,
              let first = drafts.first,
              drafts.allSatisfy({ $0.kind == .existing && $0.workspace == first.workspace && $0.session == first.session && $0.scope.account == first.scope.account && $0.scope.origin == first.scope.origin && $0.scope.team == first.scope.team && $0.accessToken == first.accessToken }) else { throw TeamTaskBatch.invalid }
        self.drafts = drafts.sorted { $0.source.id < $1.source.id }
    }
    func permits(current: [String: Record], workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) -> Bool {
        drafts.allSatisfy { draft in
            current[draft.source.id] == draft.source && draft.permits(current: current[draft.source.id], workspace: workspace, session: session, cache: cache, enabled: enabled)
        }
    }
    func selecting(_ fields: [String: JSON]) throws -> TeamTaskPlanningSelection {
        try TeamTaskPlanningSelection(drafts: drafts, changes: Dictionary(uniqueKeysWithValues: drafts.map { ($0.source.id, fields) }))
    }
}

/// A planning review freezes every source row and member request before presentation.
/// Durable retries use the resulting batch; this opening authority is never encoded.
struct TeamTaskPlanningSelection: Equatable, Sendable {
    let drafts: [TeamTaskEditorDraft]
    let changes: [String: [String: JSON]]
    let requestID: UUID
    private let memberRequests: [String: UUID]
    init(drafts: [TeamTaskEditorDraft], changes: [String: [String: JSON]], requestID: UUID = UUID()) throws {
        let admission = try TeamTaskPlanningAdmission(drafts: drafts)
        guard Set(changes.keys) == Set(drafts.map { $0.source.id }), changes.values.allSatisfy({ !$0.isEmpty && Set($0.keys).isSubset(of: TeamTaskBatch.planningFields) }) else { throw TeamTaskBatch.invalid }
        self.drafts = admission.drafts; self.changes = changes; self.requestID = requestID
        memberRequests = Dictionary(uniqueKeysWithValues: drafts.map { ($0.source.id, UUID()) })
    }
    func mutation(current: [String: Record], workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) throws -> Mutation {
        let items = try drafts.map { draft -> Mutation in
            guard current[draft.source.id] == draft.source,
                  draft.permits(current: current[draft.source.id], workspace: workspace, session: session, cache: cache, enabled: enabled) else { throw TeamTaskBatch.conflict }
            let item = Mutation(id: memberRequests[draft.source.id]!, table: "tasks", recordID: draft.source.id, method: "PATCH", fields: changes[draft.source.id]!, baseline: draft.source.fields, teamTaskScope: draft.scope)
            // The draft admission above attests current identity and access. The
            // complete planning body validates every field without padding its source.
            return item
        }
        let first = drafts[0].scope
        let batch = TeamTaskBatch(account: first.account, origin: first.origin, team: first.team, operation: .edit, restores: nil, items: items)
        let header = TeamTaskBatch.header(batch, id: requestID); _ = try batch.body(for: header); return header
    }
}


extension TeamTaskBatch {
    /// Verify every member before accepting any part of a group response.
    func completionReceipts(_ reply: [String: JSON], for header: Mutation) throws -> [TeamCompletion.Receipt] {
        let request = try body(for: header)
        guard let action = completionOperation,
              Set(reply.keys) == ["batch_protocol", "account", "team_id", "request_id", "operation", "related_request", "items", "replayed"],
              reply["batch_protocol"] == .number(1), reply["account"] == .string(account), reply["team_id"] == .string(team),
              reply["request_id"] == request["request_id"], reply["operation"] == .string(action.rawValue),
              reply["related_request"] == (request["related_request"] ?? .null), case .bool? = reply["replayed"],
              case .array(let replies)? = reply["items"], replies.count == items.count,
              try JSONEncoder().encode(reply).count <= 4_300_000 else { throw Self.invalid }
        return try zip(items, replies).map { item, value in
            guard case .object(let raw) = value, raw["replayed"] == reply["replayed"], let command = item.teamCompletion else { throw Self.invalid }
            return try command.receipt(raw, for: item)
        }
    }
    /// All receipts publish together. Reconstruct touching cohorts completely;
    /// conflicting or unsupported saved intent stays durable as one unit.
    func acknowledgeCompletion(_ saved: Record?, header: Mutation, snapshot: inout Snapshot) -> Bool {
        guard isCompletion, snapshot.pending.first == header, let saved,
              case .object(let raw) = saved["team_completion_batch_reply"],
              let receipts = try? completionReceipts(raw, for: header) else { return false }
        if let access = snapshot.teamWorkspace {
            guard access.boundary.belongs(account: account, origin: origin), access.canSend(header, in: snapshot) else { return false }
        }
        var ids = Set(items.map(\.recordID)), projects = Set<String>()
        for (item, receipt) in zip(items, receipts) {
            guard let command = item.teamCompletion else { return false }
            if let proposed = command.proposed { ids.insert(proposed.id) }
            if let successor = receipt.successor { ids.insert(successor.id) }
            projects.formUnion([command.scope.project, command.seriesProject])
        }
        guard projects.allSatisfy({ p in snapshot.tables["projects"]?.contains(where: { $0.id == p && !$0["is_archived"].flag && !$0["ancestor_archived"].flag }) == true }) else { return false }
        let later = Array(snapshot.pending.dropFirst())
        func touches(_ change: Mutation) -> Bool {
            if change.table == "projects", projects.contains(change.recordID) { return true }
            if change.table == "tasks", ids.contains(change.recordID) { return true }
            if let batch = change.teamTaskBatch { return batch.items.contains(where: touches) }
            if let command = change.teamCompletion { return ids.contains(command.source.id) || command.proposed.map { ids.contains($0.id) } == true }
            if change.table == "view_orders" { return TaskOrderRecovery.references(change, tasks: ids) }
            return false
        }
        if later.contains(where: touches) {
            guard let rebuilt = try? CompletionBatchReconciliation(batch: self, header: header, original: snapshot, raw: raw, receipts: receipts).confirmed() else { return false }
            snapshot = rebuilt; return true
        }
        var result = snapshot
        let replies = raw["items"]!.list
        for (index, item) in items.enumerated() {
            // Other members of this same atomic action are not later drafts.
            result.pending = [item] + later
            guard item.teamCompletion!.acknowledge(Record(["id": .string(item.recordID), "team_completion_reply": replies[index]]), header: item, snapshot: &result) else { return false }
        }
        result.pending = later; snapshot = result; return true
    }
}


/// Reconstruct a complete optimistic cohort before replacing it with confirmed
/// rows. Every remaining command and nonce stays frozen; only its local projection
/// is replayed. Failure leaves the caller's entire snapshot untouched.
/// Read authority is bound to a fully validated terminal review, never a write
/// receipt alone. It permits only local recovery of that exact envelope.
private struct CompletionBatchReadAccess {
    let review: TeamTaskBatch.Review
    let cache: TeamWorkspaceCache
    let unrecordedPreview: Bool
    init?(review: TeamTaskBatch.Review, cache: TeamWorkspaceCache, snapshot: Snapshot, unrecordedPreview: Bool = false) {
        guard review.isRecorded || review.isCancelled || unrecordedPreview, let batch = review.mutation.teamTaskBatch,
              batch.canReviewCompletion(review.mutation, readable: cache) else { return nil }
        if let old = snapshot.teamWorkspace {
            guard old.boundary.belongs(account: batch.account, origin: batch.origin),
                  old.knownTasks.isSubset(of: cache.knownTasks), old.knownTeams.allSatisfy({ cache.knownTeams[$0.key] == $0.value }) else { return nil }
        }
        self.review = review; self.cache = cache; self.unrecordedPreview = unrecordedPreview
        guard permits(review.mutation) else { return nil }
    }
    func permits(_ mutation: Mutation) -> Bool {
        let batch = review.mutation.teamTaskBatch!
        func scope(_ value: TeamTaskEditScope, series: String? = nil) -> Bool {
            guard value.account == batch.account, value.origin == batch.origin, value.team == batch.team else { return false }
            return [value.project, series].compactMap { $0 }.allSatisfy { cache.boundary.projects[$0]?.team == batch.team }
        }
        if let group = mutation.teamTaskBatch {
            return group.account == batch.account && group.origin == batch.origin && group.team == batch.team && !group.items.isEmpty && group.items.allSatisfy(permits)
        }
        if let command = mutation.teamCompletion { return scope(command.scope, series: command.seriesProject) }
        if mutation.table == "tasks", let value = mutation.teamTaskScope { return scope(value) }
        return false
    }
}

/// Comment IDs form the missing edge between a task and a saved mention read
/// marker. Resolve only validated, account-owned intent; never infer permission
/// from free text or retarget a marker to a newer task incarnation.
enum CompletionRecoveryConversations {
    static func parked(in snapshot: Snapshot, account: String, origin: String, affected: Set<String>, tasks: [Record]) throws -> Set<String> {
        let snapshot = try MentionRecoveryContext.resolving(snapshot, account: account, origin: origin, affected: affected, tasks: tasks)
        func references(_ value: JSON, _ ids: Set<String>) -> Bool {
            switch value {
            case .string(let text): return ids.contains { text.lowercased().contains($0.lowercased()) }
            case .object(let fields): return fields.values.contains { references($0, ids) }
            case .array(let values): return values.contains { references($0, ids) }
            default: return false
            }
        }
        func matches(_ task: String, _ generation: String, _ project: String) -> Bool {
            tasks.contains { $0.id == task && $0.string("task_generation") == generation && $0.string("project_id") == project }
        }
        var comments: [String: [String]] = [:]
        func bind(_ id: String, task: String, generation: String, project: String) throws {
            let identity = [task, generation, project]
            guard affected.contains(task), matches(task, generation, project), comments[id].map({ $0 == identity }) ?? true else { throw TeamTaskBatch.conflict }
            comments[id] = identity
        }
        let cachedComments = snapshot.tables[SharedComment.table] ?? []
        var seenComments = Set<String>()
        for row in cachedComments where references(.object(row.fields), affected) {
            guard let comment = SharedComment(row), seenComments.insert(comment.id).inserted else { throw TeamTaskBatch.conflict }
            try bind(comment.id, task: comment.taskID, generation: comment.taskGeneration, project: comment.projectID)
        }
        let outbox = snapshot.tables[ConversationOutbox.table] ?? []
        guard Set(outbox.map(\.id)).count == outbox.count else { throw TeamTaskBatch.conflict }
        for row in outbox where references(.object(row.fields), affected) {
            guard ConversationOutbox.valid(row), let comment = ConversationOutbox.comment(row), comment.account == account else { throw TeamTaskBatch.conflict }
            try bind(comment.commentID, task: comment.taskID, generation: comment.taskGeneration, project: comment.projectID)
        }
        let commentIDs = Set(comments.keys)
        // Duplicated or conflicting cache identities cannot prove a safe edge.
        for id in commentIDs {
            let rows = cachedComments.filter { $0.id.lowercased() == id }
            guard rows.count <= 1 else { throw TeamTaskBatch.conflict }
            if let row = rows.first {
                guard let comment = SharedComment(row), comments[id] == [comment.taskID, comment.taskGeneration, comment.projectID] else { throw TeamTaskBatch.conflict }
            }
        }
        var mentions: [String: SharedMention] = [:]
        for row in snapshot.tables[SharedMention.table] ?? [] where references(.object(row.fields), commentIDs) {
            guard let mention = SharedMention(row), commentIDs.contains(mention.commentID), mentions.updateValue(mention, forKey: mention.id) == nil else { throw TeamTaskBatch.conflict }
        }
        let related = affected.union(commentIDs).union(mentions.keys)
        var parked = Set<String>()
        for row in outbox where references(.object(row.fields), related) {
            guard ConversationOutbox.valid(row), row.string("account") == account else { throw TeamTaskBatch.conflict }
            if let comment = ConversationOutbox.comment(row) {
                guard comments[comment.commentID] == [comment.taskID, comment.taskGeneration, comment.projectID] else { throw TeamTaskBatch.conflict }
            } else if let change = ConversationOutbox.mention(row) {
                guard change.account == account, let mention = mentions[change.mentionID], mention.recipientID == account,
                      mention.commentID == change.commentID, commentIDs.contains(change.commentID), mention.revision >= change.expectedRevision,
                      (snapshot.tables[SharedMention.table] ?? []).filter({ $0.id.lowercased() == change.mentionID }).count == 1 else { throw TeamTaskBatch.conflict }
            } else { throw TeamTaskBatch.conflict }
            parked.insert(row.id)
        }
        return parked
    }
}

private struct CompletionBatchReconciliation {
    let batch: TeamTaskBatch
    let header: Mutation
    let original: Snapshot
    let raw: [String: JSON]
    let receipts: [TeamCompletion.Receipt]
    var cancellation: TeamTaskBatch.Review? = nil
    var readAccess: CompletionBatchReadAccess? = nil
    var parkRecorded = false
    private var later: [Mutation] { Array(original.pending.dropFirst()) }
    private func members(_ change: Mutation) -> [Mutation] { change.teamTaskBatch?.items ?? [change] }
    private func taskIDs(_ change: Mutation) -> Set<String> {
        if let group = change.teamTaskBatch { return group.items.reduce(into: Set<String>()) { $0.formUnion(taskIDs($1)) } }
        guard change.table == "tasks" else { return [] }
        var ids: Set<String> = [change.recordID]
        if let command = change.teamCompletion, let proposed = command.proposed { ids.insert(proposed.id) }
        return ids
    }
    private func checkedMembers(_ change: Mutation) throws -> [Mutation] {
        if let group = change.teamTaskBatch {
            guard group.account == batch.account, group.origin == batch.origin, group.team == batch.team else { throw TeamTaskBatch.conflict }
            _ = try group.body(for: change)
        }
        let values = members(change)
        for value in values {
            if let command = value.teamCompletion {
                guard command.scope.account == batch.account, command.scope.origin == batch.origin, command.scope.team == batch.team else { throw TeamTaskBatch.conflict }
                _ = try command.body(for: value)
            } else {
                guard let scope = value.teamTaskScope, scope.account == batch.account, scope.origin == batch.origin, scope.team == batch.team else { throw TeamTaskBatch.conflict }
                if value.method == "PATCH" { _ = try scope.body(for: value) }
                else { _ = try scope.lifecycleBody(for: value) }
            }
        }
        return values
    }
    private func before(_ value: Mutation) -> [String: JSON]? {
        guard let command = value.teamCompletion else { return value.baseline }
        if command.operation == .complete { return command.source.fields }
        return TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": .string(command.completedAt)], to: command.source).fields
    }
    private func same(_ a: JSON, _ b: JSON, key: String) -> Bool { TeamCompletion.sameLocal(Record([key: a]), Record([key: b])) }
    private func replay(_ change: Mutation, into snapshot: inout Snapshot) throws {
        _ = try checkedMembers(change)
        if var group = change.teamTaskBatch {
            if group.operation == .edit || group.operation == .delete {
                // Typed timestamp/null aliases may differ in a server receipt.
                // Normalize the temporary projection only, never the queued body.
                for i in group.items.indices {
                    guard let baseline = group.items[i].baseline, let current = snapshot.tables["tasks"]?.first(where: { $0.id == group.items[i].recordID }),
                          TeamCompletion.sameLocal(Record(baseline), current) else { throw TeamTaskBatch.conflict }
                    group.items[i].baseline = current.fields
                }
            }
            if group.operation == .restore {
                for item in group.items {
                    if let current = snapshot.tables["tasks"]?.first(where: { $0.id == item.recordID }), !TeamCompletion.sameLocal(current, Record(item.fields)) { throw TeamTaskBatch.conflict }
                }
            }
            let projection = TeamTaskBatch.header(group, id: change.id)
            guard group.apply(to: &snapshot, header: projection) else { throw TeamTaskBatch.conflict }
            return
        }
        if let command = change.teamCompletion {
            if command.operation == .complete {
                guard let current = snapshot.tables["tasks"]?.first(where: { $0.id == change.recordID }), TeamCompletion.sameLocal(current, command.source) else { throw TeamTaskBatch.conflict }
            }
            guard command.apply(to: &snapshot, header: change) else { throw TeamTaskBatch.conflict }; return
        }
        let current = snapshot.tables["tasks"]?.first(where: { $0.id == change.recordID })
        let scope = change.teamTaskScope!
        if change.method == "POST" {
            guard current == nil else { throw TeamTaskBatch.conflict }
        } else {
            guard let current, let base = change.baseline, current["project_id"] == .string(scope.project), current["task_generation"] == base["task_generation"] else { throw TeamTaskBatch.conflict }
            if change.method == "DELETE" {
                guard TeamCompletion.sameLocal(current, Record(base)) else { throw TeamTaskBatch.conflict }
            } else {
                guard change.method == "PATCH", change.fields.allSatisfy({ same(current[$0.key], base[$0.key] ?? .null, key: $0.key) }) else { throw TeamTaskBatch.conflict }
                if TaskCompletionRevision.touches(change.fields), current["completion_version"] != base["completion_version"] { throw TeamTaskBatch.conflict }
                _ = try scope.capturing(change, existing: current)
            }
        }
        snapshot.apply(change)
    }
    func confirmed() throws -> Snapshot {
        guard Set((original.tables["tasks"] ?? []).map(\.id)).count == (original.tables["tasks"] ?? []).count, original.pending.first == header else { throw TeamTaskBatch.conflict }
        let changes = later, identities = changes.map(taskIDs)
        var affected = Set(batch.items.map(\.recordID)), adjacency: [String: [Int]] = [:]
        for item in batch.items { if let row = item.teamCompletion?.proposed { affected.insert(row.id) } }
        for receipt in receipts { if let row = receipt.successor { affected.insert(row.id) } }
        for i in changes.indices { for id in identities[i] { adjacency[id, default: []].append(i) } }
        var selected = Set<Int>(), queue = Array(affected), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for i in adjacency[id] ?? [] where selected.insert(i).inserted {
                for next in identities[i] where affected.insert(next).inserted { queue.append(next) }
            }
        }
        let indices = selected.sorted(), leaves = try indices.flatMap { try checkedMembers(changes[$0]) }
        if let readAccess {
            guard readAccess.review.mutation == header, readAccess.permits(header),
                  indices.allSatisfy({ readAccess.permits(changes[$0]) }) else { throw TeamTaskBatch.conflict }
            if let cancellation {
                guard cancellation.isCancelled || readAccess.unrecordedPreview, readAccess.review == cancellation else { throw TeamTaskBatch.conflict }
            } else { guard readAccess.review.isRecorded, readAccess.review.recorded == raw else { throw TeamTaskBatch.conflict } }
        } else if cancellation == nil, !parkRecorded, let access = original.teamWorkspace {
            guard indices.allSatisfy({ access.canSend(changes[$0], in: original) }) else { throw TeamTaskBatch.conflict }
        }
        var projects = Set<String>()
        for item in batch.items + leaves {
            if let command = item.teamCompletion { projects.formUnion([command.scope.project, command.seriesProject]) }
            else if let scope = item.teamTaskScope { projects.insert(scope.project) }
        }
        guard projects.allSatisfy({ p in original.tables["projects"]?.contains(where: { $0.id == p && (cancellation != nil || parkRecorded || readAccess != nil || (!$0["is_archived"].flag && !$0["ancestor_archived"].flag)) }) == true }),
              !changes.contains(where: { $0.table == "projects" && projects.contains($0.recordID) }) else { throw TeamTaskBatch.conflict }
        var current: [String: Record] = [:]
        for row in original.tables["tasks"] ?? [] where affected.contains(row.id) {
            guard current.updateValue(row, forKey: row.id) == nil else { throw TeamTaskBatch.conflict }
        }
        let all = batch.items + leaves
        var created: [String: Set<String>] = [:]
        for item in all {
            if let command = item.teamCompletion, command.operation == .complete, let row = command.proposed { created[row.id, default: []].insert(row.string("task_generation")) }
            if item.method == "POST" { created[item.recordID, default: []].insert(item.fields["task_generation"]?.text ?? "") }
        }
        var earliest: [String: [String: JSON]] = [:], seen: [String: Set<String>] = [:]
        for item in leaves {
            for (key, value) in before(item) ?? [:] where seen[item.recordID, default: []].insert(key).inserted { earliest[item.recordID, default: [:]][key] = value }
        }
        var seed = original; seed.pending = []
        seed.tables["tasks"] = (seed.tables["tasks"] ?? []).filter { row in
            !affected.contains(row.id) || created[row.id]?.contains(row.string("task_generation")) != true
        }
        func put(_ row: Record, in value: inout Snapshot) {
            if let i = value.tables["tasks"]?.firstIndex(where: { $0.id == row.id }) { value.tables["tasks"]![i] = row }
            else { value.tables["tasks", default: []].append(row) }
        }
        var known = Set(batch.items.map(\.recordID)), born: [String: Set<String>] = [:]
        for item in batch.items {
            let command = item.teamCompletion!
            var row = command.source
            if command.operation == .undo {
                if let local = current[row.id], local["task_generation"] == row["task_generation"], local["project_id"] == row["project_id"] { row = local }
                for (key, value) in earliest[row.id] ?? [:] where !["completed", "completed_at", "completion_version"].contains(key) { row[key] = value }
                row["completed"] = .bool(true); row["completed_at"] = .string(command.completedAt)
                row["completion_version"] = .number(Double(command.source["completion_version"].integer + 1))
            }
            put(row, in: &seed)
            if command.operation == .complete, let proposed = command.proposed { born[proposed.id, default: []].insert(proposed.string("task_generation")) }
        }
        for item in leaves {
            if known.insert(item.recordID).inserted {
                let baseline = earliest[item.recordID] ?? [:], generation = baseline["task_generation"]?.text ?? ""
                if item.method != "POST", born[item.recordID]?.contains(generation) != true {
                    var row = current[item.recordID] ?? Record(baseline)
                    for (key, value) in baseline { row[key] = value }
                    guard row.id == item.recordID, TeamProjectValue.id(row.string("task_generation")) else { throw TeamTaskBatch.conflict }
                    put(row, in: &seed)
                }
            }
            if item.method == "POST" { born[item.recordID, default: []].insert(item.fields["task_generation"]?.text ?? "") }
            if let command = item.teamCompletion, command.operation == .complete, let row = command.proposed { born[row.id, default: []].insert(row.string("task_generation")) }
        }
        var expected = seed
        guard batch.apply(to: &expected, header: header) else { throw TeamTaskBatch.conflict }
        let initial = expected
        for i in indices { try replay(changes[i], into: &expected) }
        var authoritative: [String: Record] = [:]
        for receipt in receipts { for row in [receipt.task, receipt.successor].compactMap({ $0 }) { authoritative[row.id] = row } }
        var projection: [String: Record] = [:]
        for row in expected.tables["tasks"] ?? [] where affected.contains(row.id) {
            guard projection.updateValue(row, forKey: row.id) == nil else { throw TeamTaskBatch.conflict }
        }
        guard Set(current.keys) == Set(projection.keys) else { throw TeamTaskBatch.conflict }
        for (id, row) in current {
            let predicted = projection[id]!
            for key in Set(row.fields.keys).union(predicted.fields.keys) where !same(row[key], predicted[key], key: key) {
                guard cancellation == nil, let confirmed = authoritative[id], same(row[key], confirmed[key], key: key) else { throw TeamTaskBatch.conflict }
            }
        }
        if cancellation != nil || parkRecorded {
            if let cancellation { guard !cancellation.isRecorded, cancellation.mutation == header else { throw TeamTaskBatch.conflict } }
            else { guard !receipts.isEmpty, cancellation == nil else { throw TeamTaskBatch.conflict } }
            func references(_ value: JSON) -> Bool {
                switch value {
                case .string(let text): return affected.contains { text.lowercased().contains($0.lowercased()) }
                case .object(let fields): return fields.values.contains(where: references)
                case .array(let values): return values.contains(where: references)
                default: return false
                }
            }
            // Frozen typed rows also prove identity after a queued deletion.
            let archivedRows = all.flatMap { item -> [Record] in
                if let command = item.teamCompletion { return [command.source] + [command.proposed].compactMap { $0 } }
                return [item.baseline.map(Record.init), item.method == "POST" ? Record(item.fields) : nil].compactMap { $0 }
            }
            let taskRows = (expected.tables["tasks"] ?? []) + Array(current.values) + archivedRows
            let orders = try TaskOrderRecovery.parking(changes, snapshot: original, affected: affected, taskRows: taskRows, account: batch.account, origin: batch.origin)
            let parkedComments = try CompletionRecoveryConversations.parked(in: original, account: batch.account, origin: batch.origin, affected: affected,
                tasks: taskRows)
            for i in changes.indices where !selected.contains(i) && !orders.indices.contains(i) {
                let value = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(changes[i]))
                guard !references(value) else { throw TeamTaskBatch.conflict }
            }
            var result = seed
            if let cancellation {
                let owned = Set(batch.items.flatMap { [$0.recordID, $0.teamCompletion?.proposed?.id].compactMap { $0 } })
                result.tables["tasks"]?.removeAll { owned.contains($0.id) }
                for row in cancellation.members.flatMap({ [$0.task, $0.successor].compactMap { $0 } }) where owned.contains(row.id) { put(row, in: &result) }
            } else {
                result = initial
                result.tables[ConversationOutbox.table]?.removeAll { parkedComments.contains($0.id) }
                let replies = raw["items"]!.list
                for (i, item) in batch.items.enumerated() {
                    result.pending = [item]
                    guard item.teamCompletion!.acknowledge(Record(["id": .string(item.recordID), "team_completion_reply": replies[i]]), header: item, snapshot: &result) else { throw TeamTaskBatch.conflict }
                }
            }
            result.pending = changes.enumerated().filter { !selected.contains($0.offset) && !orders.indices.contains($0.offset) }.map(\.element)
            let orderKeys = orders.removed.union(orders.restored.keys)
            result.tables["view_orders"]?.removeAll { orderKeys.contains($0.id) }
            if !orders.restored.isEmpty { result.tables["view_orders", default: []].append(contentsOf: orders.restored.keys.sorted().compactMap { orders.restored[$0] }) }
            result.tables[ConversationOutbox.table]?.removeAll { parkedComments.contains($0.id) }
            return result
        }
        do {
            let owned = Set(batch.items.flatMap { [$0.recordID, $0.teamCompletion?.proposed?.id].compactMap { $0 } })
            let displaced = Set(current.values.filter { owned.contains($0.id) && authoritative[$0.id]?["task_generation"] != $0["task_generation"] }.map(\.id))
            func references(_ value: JSON) -> Bool {
                switch value {
                case .string(let text): return displaced.contains { text.lowercased().contains($0.lowercased()) }
                case .object(let fields): return fields.values.contains(where: references)
                case .array(let values): return values.contains(where: references)
                default: return false
                }
            }
            guard try CompletionRecoveryConversations.parked(in: original, account: batch.account, origin: batch.origin, affected: displaced,
                tasks: (expected.tables["tasks"] ?? []) + Array(current.values)).isEmpty else { throw TeamTaskBatch.conflict }
            for i in changes.indices where !selected.contains(i) {
                let value = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(changes[i]))
                guard !references(value) else { throw TeamTaskBatch.conflict }
            }
        }
        var result = initial
        let replies = raw["items"]!.list
        for (i, item) in batch.items.enumerated() {
            result.pending = [item]
            guard item.teamCompletion!.acknowledge(Record(["id": .string(item.recordID), "team_completion_reply": replies[i]]), header: item, snapshot: &result) else { throw TeamTaskBatch.conflict }
        }
        for i in indices { try replay(changes[i], into: &result) }
        result.pending = changes
        return result
    }
}

/// Ephemeral opening authority, with a frozen durable command and repeat preview.
/// Re-reading a review must never generate new nonces or acquire fresh baselines.
struct TeamTaskCompletionSelection: Equatable, Sendable {
    static var stale: AppFailure { AppFailure(message: "These tasks or their repeat occurrences changed. Close this review and select them again. Nothing was completed.") }
    let drafts: [TeamTaskEditorDraft]
    let command: Mutation
    private let lifecycleRows: [Record]
    private let series: Set<String>
    var requestID: UUID { command.id }
    var completingCount: Int { command.teamTaskBatch!.items.count }
    var successors: [Record] {
        command.teamTaskBatch!.items.compactMap { item in
            guard let value = item.teamCompletion, let proposed = value.proposed else { return nil }
            return lifecycleRows.first { $0.id == proposed.id || ($0.string("recurrence_parent_id") == value.seriesID && $0["due_date"] == proposed["due_date"]) } ?? proposed
        }
    }
    init(drafts: [TeamTaskEditorDraft], tasks: [Record], at: Date = Date(), zone: String = TimeZone.current.identifier) throws {
        let admission = try TeamTaskPlanningAdmission(drafts: drafts)
        guard admission.drafts.contains(where: { !$0.source.completed }),
              Set(tasks.map(\.id)).count == tasks.count,
              admission.drafts.allSatisfy({ draft in tasks.first(where: { $0.id == draft.source.id }) == draft.source }) else { throw Self.stale }
        let items = try admission.drafts.filter { !$0.source.completed }.map { draft -> Mutation in
            guard draft.source["is_recurring"] != .bool(true) || TeamTaskRecurrence.supported(draft.source) else { throw TeamTaskRecurrence.invalid }
            return try TeamCompletion.complete(draft.source, tasks: tasks, scope: draft.scope, at: at, zone: zone)
        }
        let first = admission.drafts[0].scope
        let batch = TeamTaskBatch(account: first.account, origin: first.origin, team: first.team, operation: .complete, restores: nil, items: items)
        command = TeamTaskBatch.header(batch)
        _ = try batch.body(for: command)
        self.drafts = admission.drafts
        let capturedSeries = Set(items.map { $0.teamCompletion!.seriesID }).union(admission.drafts.map { $0.source.id })
        series = capturedSeries
        lifecycleRows = tasks.filter { capturedSeries.contains($0.id) || capturedSeries.contains($0.string("recurrence_parent_id")) }.sorted { $0.id < $1.id }
    }
    func mutation(tasks: [Record], workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) throws -> Mutation {
        guard Set(tasks.map(\.id)).count == tasks.count else { throw Self.stale }
        let current = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        guard permits(current: current, workspace: workspace, session: session, cache: cache, enabled: enabled),
              tasks.filter({ series.contains($0.id) || series.contains($0.string("recurrence_parent_id")) }).sorted(by: { $0.id < $1.id }) == lifecycleRows else { throw Self.stale }
        return command
    }
    private func permits(current: [String: Record], workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) -> Bool {
        drafts.allSatisfy { draft in current[draft.source.id] == draft.source && draft.permits(current: current[draft.source.id], workspace: workspace, session: session, cache: cache, enabled: enabled) }
    }
}

extension TeamTaskBatch {
    /// One versioned observation belongs to the entire immutable saved envelope.
    struct Review: Equatable, Sendable {
        let mutation: Mutation
        let members: [TeamCompletion.Review]
        let state: String
        let recorded: [String: JSON]?
        let response: [String: JSON]
        var isRecorded: Bool { state == "recorded" }
        var isCancelled: Bool { state == "cancelled" }
        static var invalid: AppFailure { AppFailure(message: "The selection’s sync status could not be verified. Your saved tasks and changes are kept. Check again to continue.") }
        init(_ reply: [String: JSON], for mutation: Mutation) throws {
            guard let batch = mutation.teamTaskBatch, let action = batch.completionOperation else { throw Self.invalid }
            let body = try batch.body(for: mutation)
            guard Set(reply.keys) == Set(["group_review_protocol", "account", "team_id", "request_id", "operation", "related_request", "state", "items", "receipt"]),
                  reply["group_review_protocol"] == .number(1), reply["account"] == .string(batch.account),
                  reply["team_id"] == .string(batch.team), reply["request_id"] == body["request_id"],
                  reply["operation"] == .string(action.rawValue), reply["related_request"] == (body["related_request"] ?? .null),
                  let state = reply["state"]?.text, ["unrecorded", "recorded", "cancelled"].contains(state),
                  case .array(let values)? = reply["items"], values.count == batch.items.count,
                  try JSONEncoder().encode(reply).count <= 8_500_000 else { throw Self.invalid }
            let keys: Set<String> = ["review_protocol", "account", "team_id", "project_id", "task_id", "task_generation", "request_id", "operation", "series_id", "series_generation", "series_project_id", "planned_next_id", "state", "project_role", "task", "series", "successor", "receipt", "can_edit_current", "can_edit_series"]
            let members = try zip(values, batch.items).map { value, item -> TeamCompletion.Review in
                guard case .object(let raw) = value, Set(raw.keys) == keys, raw["state"] == .string(state),
                      case .bool? = raw["can_edit_current"], case .bool? = raw["can_edit_series"] else { throw Self.invalid }
                return try TeamCompletion.Review(raw, for: item)
            }
            if state == "recorded" {
                guard case .object(let receipt)? = reply["receipt"], receipt["replayed"] == .bool(true) else { throw Self.invalid }
                _ = try batch.completionReceipts(receipt, for: mutation)
                guard receipt["items"] == .array(members.map { .object($0.recorded!) }) else { throw Self.invalid }
                recorded = receipt
            } else {
                guard reply["receipt"] == .null else { throw Self.invalid }; recorded = nil
            }
            // A shared identity cannot have two different observations in one
            // supposedly coherent group response, including a series parent.
            var rows: [String: Record] = [:]
            for row in members.flatMap({ [$0.task, $0.series, $0.successor].compactMap { $0 } }) {
                if let previous = rows[row.id], !TeamCompletion.sameLocal(previous, row) { throw Self.invalid }
                rows[row.id] = row
            }
            self.mutation = mutation; self.members = members; self.state = state; self.response = reply
        }
        func acknowledging(_ snapshot: Snapshot) -> Snapshot? {
            guard snapshot.pending.first == mutation, let recorded, let batch = mutation.teamTaskBatch else { return nil }
            var next = snapshot
            let saved = Record(["id": .string(mutation.recordID), "team_completion_batch_reply": .object(recorded)])
            guard batch.acknowledgeCompletion(saved, header: mutation, snapshot: &next) else { return nil }
            return next
        }
        /// An explicit recorded review may acknowledge local state with current
        /// read access. It does not make any later queued command sendable.
        func acknowledging(_ snapshot: Snapshot, readable cache: TeamWorkspaceCache) -> Snapshot? {
            guard snapshot.pending.first == mutation, Set(snapshot.pending.map(\.id)).count == snapshot.pending.count,
                  let access = CompletionBatchReadAccess(review: self, cache: cache, snapshot: snapshot),
                  let batch = mutation.teamTaskBatch, let recorded,
                  let receipts = try? batch.completionReceipts(recorded, for: mutation),
                  var next = try? CompletionBatchReconciliation(batch: batch, header: mutation, original: snapshot, raw: recorded, receipts: receipts, readAccess: access).confirmed(),
                  let refreshed = try? TeamWorkspaceCache(boundary: cache.boundary, previous: cache, pending: next.pending, tasks: next.tables["tasks"] ?? []) else { return nil }
            next.teamWorkspace = refreshed
            return next
        }
        /// Produces a complete rollback only with a separately retained encrypted
        /// draft. This method alone never authorizes deleting pending work.
        func parkingCancellation(_ snapshot: Snapshot) -> Snapshot? { isCancelled ? parkingPreview(snapshot) : nil }
        func parkingPreview(_ snapshot: Snapshot) -> Snapshot? {
            guard !isRecorded, Set(snapshot.pending.map(\.id)).count == snapshot.pending.count, let batch = mutation.teamTaskBatch, (try? batch.body(for: mutation)) != nil else { return nil }
            return try? CompletionBatchReconciliation(batch: batch, header: mutation, original: snapshot, raw: [:], receipts: [], cancellation: self).confirmed()
        }
        func canRequestCancellation(_ snapshot: Snapshot) -> Bool { !isRecorded && cancellationProjection(snapshot) != nil }
        func cancelling(_ snapshot: Snapshot) -> Snapshot? { isCancelled ? cancellationProjection(snapshot) : nil }
        private func cancellationProjection(_ snapshot: Snapshot) -> Snapshot? {
            guard !isRecorded, snapshot.pending.first == mutation, let batch = mutation.teamTaskBatch,
                  Set((snapshot.tables["tasks"] ?? []).map(\.id)).count == (snapshot.tables["tasks"] ?? []).count else { return nil }
            let commands = batch.items.compactMap(\.teamCompletion)
            let ids = Set(commands.flatMap { [$0.source.id, $0.seriesID, $0.proposed?.id].compactMap { $0 } } + members.compactMap { $0.successor?.id })
            func references(_ value: JSON) -> Bool {
                switch value {
                case .string(let text): return ids.contains { text.lowercased().contains($0.lowercased()) }
                case .object(let fields): return fields.values.contains(where: references)
                case .array(let values): return values.contains(where: references)
                default: return false
                }
            }
            // The recorded path supports connected cohorts. Retiring unrecorded
            // intent needs a separate draft-preservation plan for dependent work;
            // until then the whole queue stays saved and this action is withheld.
            for later in snapshot.pending.dropFirst() {
                guard !["projects", "sections"].contains(later.table),
                      let encoded = try? JSONEncoder().encode(later), let value = try? JSONDecoder().decode(JSON.self, from: encoded), !references(value) else { return nil }
            }
            guard let conversations = try? CompletionRecoveryConversations.parked(in: snapshot, account: batch.account, origin: batch.origin, affected: ids,
                tasks: (snapshot.tables["tasks"] ?? []) + commands.flatMap { [$0.source] + [$0.proposed].compactMap { $0 } }), conversations.isEmpty else { return nil }
            var rows = snapshot.tables["tasks"] ?? []
            for command in commands {
                guard let local = rows.first(where: { $0.id == command.source.id }) else { return nil }
                var expected = TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": .string(command.completedAt)], to: command.source)
                if command.operation == .undo { expected = TaskCompletionRevision.applying(["completed": .bool(false), "completed_at": .null], to: expected) }
                guard TeamCompletion.sameLocal(local, expected) else { return nil }
                if let proposed = command.proposed, let local = rows.first(where: { $0.id == proposed.id }), !TeamCompletion.sameLocal(local, proposed) { return nil }
            }
            let owned = Set(commands.flatMap { [$0.source.id, $0.proposed?.id].compactMap { $0 } })
            rows.removeAll { owned.contains($0.id) }
            // Separate series parents were never changed by this completion.
            // Refresh only owned rows; an observation is not authority to
            // replace an unrelated local parent or its unexplained edits.
            let observed = members.flatMap { [$0.task, $0.series, $0.successor].compactMap { $0 } }.filter { owned.contains($0.id) }
            for row in observed { rows.removeAll { $0.id == row.id }; rows.append(row) }
            var next = snapshot; next.tables["tasks"] = rows; next.pending.removeFirst()
            return next
        }
    }
}

/// A read-only discovery request owns the exact cold-start queue and live access
/// observation. A positive result opens review; it never acknowledges or sends it.
struct TeamCompletionBatchDiscovery: Equatable, Sendable {
    let snapshot: Snapshot
    let access: TeamWorkspaceCache
    let mutation: Mutation
    init?(snapshot: Snapshot, access: TeamWorkspaceCache) {
        guard let head = snapshot.pending.first, let batch = head.teamTaskBatch,
              Set(snapshot.pending.map(\.id)).count == snapshot.pending.count,
              batch.canReviewCompletion(head, readable: access), access.blocked(snapshot).contains(head.id) else { return nil }
        self.snapshot = snapshot; self.access = access; mutation = head
    }
    func terminal(_ review: TeamTaskBatch.Review, current: Snapshot, readable: TeamWorkspaceCache) -> TeamTaskBatch.Review? {
        guard current == snapshot, readable == access, review.mutation == mutation, (review.isRecorded || review.isCancelled) else { return nil }
        return review
    }
}

extension TeamTaskBatch {
    /// Read eligibility does not imply mutation eligibility. In particular,
    /// viewers, archived projects and write pauses may still inspect a receipt.
    func canReviewCompletion(_ header: Mutation, readable cache: TeamWorkspaceCache) -> Bool {
        guard isCompletion, header.teamTaskBatch == self, (try? body(for: header)) != nil,
              cache.boundary.belongs(account: account, origin: origin),
              cache.boundary.raw["native_team_reads_enabled"] == .bool(true),
              cache.boundary.raw["teams"]?.list.contains(where: { $0.object["id"] == .string(team) && $0.object["state"] == .string("active") }) == true else { return false }
        return items.allSatisfy { item in
            guard let command = item.teamCompletion else { return false }
            return [command.scope.project, command.seriesProject].allSatisfy { cache.boundary.projects[$0]?.team == team }
        }
    }
}


extension TeamTaskBatch.Review {
    func cancelling(_ snapshot: Snapshot, readable cache: TeamWorkspaceCache) -> Snapshot? {
        guard isCancelled, CompletionBatchReadAccess(review: self, cache: cache, snapshot: snapshot) != nil,
              let next = cancelling(snapshot) else { return nil }
        return cache.retainingRecoveryAccess(in: next, from: snapshot)
    }
    /// The caller must first retain and verify the encrypted full draft. This
    /// read-bound projection gives no independent authority to discard intent.
    func parkingCancellation(_ snapshot: Snapshot, readable cache: TeamWorkspaceCache) -> Snapshot? {
        guard isCancelled, Set(snapshot.pending.map(\.id)).count == snapshot.pending.count,
              let batch = mutation.teamTaskBatch, (try? batch.body(for: mutation)) != nil,
              let access = CompletionBatchReadAccess(review: self, cache: cache, snapshot: snapshot),
              let next = try? CompletionBatchReconciliation(batch: batch, header: mutation, original: snapshot, raw: [:], receipts: [], cancellation: self, readAccess: access).confirmed() else { return nil }
        return cache.retainingRecoveryAccess(in: next, from: snapshot)
    }
}


extension TeamTaskBatch.Review {
    /// Preview only. Retiring any of this work also requires a verified permanent
    /// encrypted draft and current read authority in the Store transaction.
    func recordedDraftPreview(_ snapshot: Snapshot) -> Snapshot? {
        guard isRecorded, let batch = mutation.teamTaskBatch, let recorded,
              members.contains(where: { member in
                  guard let command = member.mutation.teamCompletion else { return false }
                  return member.task == nil || command.proposed.map { member.successor?.id != $0.id || member.successor?["task_generation"] != $0["task_generation"] } == true
              }),
              let receipts = try? batch.completionReceipts(recorded, for: mutation) else { return nil }
        return try? CompletionBatchReconciliation(batch: batch, header: mutation, original: snapshot, raw: recorded, receipts: receipts, parkRecorded: true).confirmed()
    }
    func preservingRecordedDraft(_ snapshot: Snapshot, readable cache: TeamWorkspaceCache) -> Snapshot? {
        guard recordedDraftPreview(snapshot) != nil, let batch = mutation.teamTaskBatch, let recorded,
              let access = CompletionBatchReadAccess(review: self, cache: cache, snapshot: snapshot),
              let receipts = try? batch.completionReceipts(recorded, for: mutation),
              let next = try? CompletionBatchReconciliation(batch: batch, header: mutation, original: snapshot, raw: recorded, receipts: receipts, readAccess: access, parkRecorded: true).confirmed() else { return nil }
        return cache.retainingRecoveryAccess(in: next, from: snapshot)
    }
}


extension TeamTaskBatch.Review {
    /// Pure admission only. An unrecorded observation never retires a command;
    /// Store must save a draft and a verified cancellation before persistence.
    func cancellationDraftPreview(_ snapshot: Snapshot, readable cache: TeamWorkspaceCache) -> Snapshot? {
        guard !isRecorded, let batch = mutation.teamTaskBatch,
              let access = CompletionBatchReadAccess(review: self, cache: cache, snapshot: snapshot, unrecordedPreview: true),
              let next = try? CompletionBatchReconciliation(batch: batch, header: mutation, original: snapshot, raw: [:], receipts: [], cancellation: self, readAccess: access).confirmed() else { return nil }
        return cache.retainingRecoveryAccess(in: next, from: snapshot)
    }
}
