import Foundation

/// One durable intent and one RPC cover the complete selection. Member requests
/// remain frozen inside the envelope; a transport retry never rebuilds the group.
struct TeamTaskBatch: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case delete, restore, edit }
    static let planningFields: Set<String> = ["priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes"]
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
              header.teamTaskBatch == self,header.fields.isEmpty,header.baseline == nil,header.teamTaskScope == nil,header.organizationOrder == nil,
              [account,team].allSatisfy(TeamProjectValue.id),(1...100).contains(items.count),
              (operation == .restore) == (restores != nil) else { throw Self.invalid }
        let ids=items.map(\.recordID),nonces=items.map(\.id)
        guard ids == ids.sorted(),Set(ids).count == items.count,Set(nonces).count == items.count,!nonces.contains(header.id) else { throw Self.invalid }
        let values=try items.map { item -> JSON in
            guard item.teamTaskBatch == nil, let scope=item.teamTaskScope,scope.account == account,scope.origin == origin,scope.team == team else { throw Self.invalid }
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
        if let restores { body["restores"] = .string(restores.uuidString.lowercased()) }
        guard try JSONEncoder().encode(body).count <= 1_500_000 else { throw AppFailure(message:"This selection is too large. Choose fewer tasks.") }
        return body
    }
    func confirm(_ reply:[String:JSON],for header:Mutation) throws {
        let request=try body(for:header)
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
    static func historyAction(_ original:Mutation) -> Mutation {
        guard var batch=original.teamTaskBatch else { return TeamTaskEditScope.historyAction(original) }
        batch.items=batch.items.map { old in
            var value=old;value.id=UUID()
            if batch.operation == .restore { value=TaskGeneration.restoring(value,existing:nil) }
            return value
        }
        return header(batch)
    }
    func apply(to snapshot:inout Snapshot,header:Mutation) -> Bool {
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
