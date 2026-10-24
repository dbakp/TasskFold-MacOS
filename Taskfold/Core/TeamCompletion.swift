import Foundation

/// Completion and its optional successor are one persisted command and one RPC.
struct TeamCompletion: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case complete, undo }
    let scope: TeamTaskEditScope
    let operation: Operation
    let source: Record
    let completedAt: String
    let inputZone: String
    let seriesID: String
    let seriesGeneration: String
    let seriesProject: String
    let nextGeneration: String
    let proposed: Record?
    let related: UUID?

    static var invalid: AppFailure { AppFailure(message:"This saved completion needs review. Your task and changes remain on this device.") }
    static var conflict: AppFailure { AppFailure(message:"This task changed. Your saved completion remains on this device. Review it before syncing.") }
    static func header(_ value: Self, id: UUID = UUID()) -> Mutation {
        Mutation(id:id,table:"tasks",recordID:value.source.id,method:"TEAM_COMPLETE",fields:[:],baseline:value.source.fields,teamCompletion:value)
    }
    static func complete(_ task: Record, tasks: [Record], scope: TeamTaskEditScope, at: Date, zone: String, id: UUID = UUID(), redoOf: UUID? = nil) throws -> Mutation {
        guard !task.completed, let timeZone=TimeZone(identifier:zone) else { throw invalid }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        if task["is_recurring"].flag, (!Recurrence.valid(Record(task["recurrence_pattern"].object)) || Dates.parse(task.string("due_date"),calendar:TaskCompletion.calendar(for:task,input:calendar)) == nil) { throw conflict }
        let ordinary=TaskCompletion.complete(task,tasks:[],at:at,calendar:calendar,account:scope.account)
        guard !ordinary.isEmpty else { throw invalid }
        let nextGeneration=ordinary.count>1 ? ordinary[1].fields["task_generation"]!.text : UUID().uuidString.lowercased()
        var proposed:Record?
        if ordinary.count>1 {
            var next=ordinary[1];next.id=id;next.teamTaskScope=scope
            var metadata=next.fields["source_metadata"]!.object
            metadata["taskfold_recurrence_v1"] = .object(["action_id":.string(id.uuidString.lowercased())]);next.fields["source_metadata"] = .object(metadata)
            next=try TeamChecklist.preparing(next);proposed=Record(next.fields)
        }
        let series=proposed == nil ? task.id : (task.string("recurrence_parent_id").isEmpty ? task.id : task.string("recurrence_parent_id"))
        let parent=series == task.id ? task : tasks.first{$0.id == series}
        guard let parent, TeamProjectValue.id(parent.string("task_generation")),TeamProjectValue.id(parent.string("project_id")) else { throw invalid }
        let value=Self(scope:scope,operation:.complete,source:task,completedAt:ISO8601DateFormatter().string(from:at),inputZone:zone,seriesID:series,seriesGeneration:parent.string("task_generation"),seriesProject:parent.string("project_id"),nextGeneration:nextGeneration,proposed:proposed,related:redoOf)
        let result=header(value,id:id);_=try value.body(for:result);return result
    }
    func body(for header: Mutation) throws -> [String:JSON] {
        guard header.teamCompletion == self,header.table == "tasks",header.method == "TEAM_COMPLETE",header.recordID == source.id,header.fields.isEmpty,header.baseline == source.fields,
              header.teamTaskScope == nil,header.teamTaskBatch == nil,header.organizationOrder == nil,
              [scope.account,scope.team,scope.project,source.id,source.string("user_id"),source.string("task_generation"),seriesID,seriesGeneration,seriesProject,nextGeneration].allSatisfy(TeamProjectValue.id),
              scope.restoreRequest == nil,scope.checklistRestoreRequest == nil,
              source["project_id"] == .string(scope.project),source["completed"] == .bool(false),
              case .number(let version)=source["completion_version"],version.isFinite,version>=0,version<9_007_199_254_740_991,version.rounded(.down)==version,
              TimeZone(identifier:inputZone) != nil,TaskPlanning.instant(completedAt) != nil,
              operation != .undo || related != nil else { throw Self.invalid }
        if let proposed {
            let owner=(operation == .complete ? header.id:related!).uuidString.lowercased()
            guard TeamProjectValue.id(proposed.id),proposed["task_generation"] == .string(nextGeneration),proposed["project_id"] == .string(scope.project),proposed["user_id"] == .string(scope.account),
                  proposed["recurrence_parent_id"] == .string(seriesID),proposed["completed"] == .bool(false),proposed["completion_version"] == .number(0),
                  proposed["source_metadata"].object["taskfold_recurrence_v1"]?.object["action_id"] == .string(owner) else { throw Self.invalid }
            try TeamChecklist.validate(proposed["subtasks"])
        }
        var result:[String:JSON] = ["team_id":.string(scope.team),"project_id":.string(scope.project),"task_id":.string(source.id),"task_generation":source["task_generation"],"request_id":.string(header.id.uuidString.lowercased()),"record":.object(source.fields),"completed_at":.string(completedAt),"input_zone":.string(inputZone),"next_generation":.string(nextGeneration),"planned_next_id":proposed.map{.string($0.id)} ?? .null,"series_id":.string(seriesID),"series_generation":.string(seriesGeneration),"series_project_id":.string(seriesProject)]
        if let related { result[operation == .undo ? "undoes":"redo_of"] = .string(related.uuidString.lowercased()) }
        guard try JSONEncoder().encode(result).count<=128000 else { throw Self.invalid }
        return result
    }
    func inverse(of header:Mutation) throws -> Mutation {
        _=try body(for:header)
        return Self.header(Self(scope:scope,operation:operation == .complete ? .undo:.complete,source:source,completedAt:completedAt,inputZone:inputZone,seriesID:seriesID,seriesGeneration:seriesGeneration,seriesProject:seriesProject,nextGeneration:nextGeneration,proposed:proposed,related:header.id))
    }
    static func historyAction(_ header:Mutation,snapshot:Snapshot) -> Mutation {
        guard let command=header.teamCompletion else { return TeamTaskBatch.historyAction(header) }
        if command.operation == .complete,
           let task=snapshot.tables["tasks"]?.first(where:{$0.id == command.source.id}),task["task_generation"] == command.source["task_generation"],task["project_id"] == .string(command.scope.project),
           let clock=TaskPlanning.instant(command.completedAt),
           let renewed=try? complete(task,tasks:snapshot.tables["tasks"] ?? [],scope:command.scope,at:clock,zone:command.inputZone,redoOf:command.related) { return renewed }
        if command.operation == .undo { return Self.header(command) }
        return header // Preflight rejects a stale incarnation without discarding history.
    }
    static func sameLocal(_ a:Record,_ b:Record) -> Bool {
        func normalized(_ row:Record)->[String:JSON] {
            var fields=row.fields.filter{$0.value != .null}
            for key in ["created_at","completed_at","scheduled_at"] {
                if let value=fields[key],let date=TaskPlanning.instant(value.text) {fields[key] = .number(date.timeIntervalSince1970)}
            }
            if let clock=fields["due_time"]?.text,clock.count == 8,clock.hasSuffix(":00") {fields["due_time"] = .string(String(clock.prefix(5)))}
            return fields
        }
        return normalized(a)==normalized(b)
    }
    @discardableResult func apply(to snapshot:inout Snapshot,header:Mutation) -> Bool {
        guard (try? body(for:header)) != nil,
              snapshot.tables["projects"]?.contains(where:{$0.id == scope.project}) == true,
              let current=snapshot.tables["tasks"]?.first(where:{$0.id == source.id}),current["task_generation"] == source["task_generation"],current["project_id"] == .string(scope.project),
              current.completed == (operation == .undo),current["completion_version"].integer == source["completion_version"].integer+(operation == .undo ? 1:0) else { return false }
        let fields:[String:JSON] = ["completed":.bool(operation == .complete),"completed_at":operation == .complete ? .string(completedAt):.null]
        var result=snapshot
        result.apply(Mutation(table:"tasks",recordID:source.id,method:"PATCH",fields:fields,baseline:TaskCompletionRevision.editBaseline(for:fields,from:current)))
        if let proposed {
            if operation == .complete {
                if !(result.tables["tasks"] ?? []).contains(where:{$0.id == proposed.id || ($0.string("recurrence_parent_id") == seriesID && $0["due_date"] == proposed["due_date"])}) {
                    result.apply(Mutation(table:"tasks",recordID:proposed.id,method:"POST",fields:proposed.fields,insertOnly:true))
                }
            } else if let row=result.tables["tasks"]?.first(where:{$0.id == proposed.id}),Self.sameLocal(row,proposed) {
                result.tables["tasks"]?.removeAll{$0.id == proposed.id && $0["task_generation"] == proposed["task_generation"]}
            }
        }
        snapshot=result;return true
    }
    struct Receipt {
        let raw:[String:JSON]
        let task:Record?
        let successor:Record?
        let created:Bool
        let removed:Bool
    }
    func receipt(_ reply:[String:JSON],for header:Mutation) throws -> Receipt {
        let request=try body(for:header)
        for key in ["team_id","project_id","task_id","task_generation","request_id","series_id","series_generation","series_project_id"] {
            guard reply[key] == request[key] else { throw Self.invalid }
        }
        guard reply["protocol"] == .number(1),reply["account"] == .string(scope.account),reply["operation"] == .string(operation.rawValue),
              reply["related_request"] == (related.map{.string($0.uuidString.lowercased())} ?? .null),reply["planned_next_id"] == request["planned_next_id"],
              case .bool(let replayed)?=reply["replayed"],case .bool(let created)?=reply["created_successor"],case .bool(let removed)?=reply["removed_successor"],
              case .number(let version)?=reply["source_revision"],version.isFinite,version>=1,version<=9_007_199_254_740_991,version.rounded(.down)==version,
              !removed || (created && operation == .undo) else { throw Self.invalid }
        func optionalID(_ value:JSON?) throws -> String? { try TeamProjectValue.optionalID(value) }
        let nextID=try optionalID(reply["successor_id"]),nextGen=try optionalID(reply["successor_generation"])
        guard proposed != nil || (nextID == nil && nextGen == nil && !created && !removed), nextGen == nil || nextID != nil,
              !created || (nextID == proposed?.id && nextGen == nextGeneration) else { throw Self.invalid }
        func row(_ key:String,id:String?,generation:String?) throws -> Record? {
            guard let value=reply[key] else { throw Self.invalid };if value == .null { return nil }
            guard let id,let generation,case .object(let fields)=value,fields["id"] == .string(id),fields["task_generation"] == .string(generation),fields["project_id"] == .string(scope.project),
                  case .string(let creator)?=fields["user_id"],TeamProjectValue.id(creator),case .string?=fields["title"],case .bool?=fields["completed"],
                  case .number(let version)?=fields["completion_version"],version.isFinite,version>=0,version<=9_007_199_254_740_991,version.rounded(.down)==version else { throw Self.invalid }
            return Record(fields)
        }
        let task=try row("task",id:source.id,generation:source.string("task_generation")),successor=try row("successor",id:nextID,generation:nextGen)
        guard task != nil || replayed, operation != .complete || !created || replayed || successor != nil else { throw Self.invalid }
        return Receipt(raw:reply,task:task,successor:successor,created:created,removed:removed)
    }
    /// Refuse acknowledgement if another server generation would displace a local
    /// provisional task that the user has already edited. The full command stays durable.
    func acknowledge(_ saved:Record?,header:Mutation,snapshot:inout Snapshot) -> Bool {
        guard let saved,case .object(let raw)=saved["team_completion_reply"],let receipt=try? receipt(raw,for:header) else { return false }
        var result=snapshot
        let later=result.pending.filter{$0.id != header.id}
        func hasDraft(_ id:String)->Bool {later.contains{$0.table == "tasks" && $0.recordID == id}}
        // Offline completion → Undo → Redo may already project a later provisional
        // generation. It can be reconstructed from the complete durable queue.
        func isLaterProjection(_ row:Record)->Bool {
            guard let index=later.firstIndex(where:{
                guard let command=$0.teamCompletion,command.operation == .complete,let proposed=command.proposed else { return false }
                return proposed.id == row.id && proposed["task_generation"] == row["task_generation"]
            }),let command=later[index].teamCompletion,let proposed=command.proposed else { return false }
            var projection=Snapshot(tables:["tasks":[proposed],"projects":snapshot.tables["projects"] ?? []])
            for next in later.dropFirst(index+1) {projection.apply(next)}
            return projection.tables["tasks"]?.first(where:{$0.id == row.id}).map{Self.sameLocal($0,row)} == true
        }
        if let task=receipt.task,later.contains(where:{$0.teamCompletion?.source.id == source.id}),task["completion_version"] != raw["source_revision"] { return false }

        if let proposed,let local=result.tables["tasks"]?.first(where:{$0.id == proposed.id}),local["task_generation"] == proposed["task_generation"],
           receipt.successor?.id != local.id || receipt.successor?["task_generation"] != local["task_generation"] {
            guard !hasDraft(local.id),Self.sameLocal(local,proposed) else { return false }
            result.tables["tasks"]?.removeAll{$0.id == local.id && $0["task_generation"] == local["task_generation"]}
        }
        if receipt.task == nil,let local=result.tables["tasks"]?.first(where:{$0.id == source.id}),local["task_generation"] == source["task_generation"] {
            let fields:[String:JSON] = ["completed":.bool(operation == .complete),"completed_at":operation == .complete ? .string(completedAt):.null]
            var expected=TaskCompletionRevision.applying(fields,to:source)
            if operation == .undo { expected["completion_version"] = .number(Double(source["completion_version"].integer+2)) }
            guard !hasDraft(source.id),Self.sameLocal(local,expected) else { return false }
            result.tables["tasks"]?.removeAll{$0.id == source.id && $0["task_generation"] == source["task_generation"]}
        }
        for row in [receipt.task,receipt.successor].compactMap({$0}) {
            var rows=result.tables["tasks"] ?? []
            if let i=rows.firstIndex(where:{$0.id == row.id}) {
                let current=rows[i]
                guard current["task_generation"] == row["task_generation"] || isLaterProjection(current) else { return false }
                rows[i]=row
            } else {rows.append(row)}
            result.tables["tasks"]=rows
        }
        result.pending.removeAll{$0.id == header.id}
        for change in later where change.table == "tasks" {result.apply(change)}
        snapshot=result;return true
    }
}

extension TeamCompletion {
    /// Read-only observation, never a certificate that an unrecorded command can
    /// be discarded: another request can still be in flight after the read.
    struct Review: Equatable, Sendable {
        let mutation: Mutation
        let role: TeamProjectRole
        let task: Record?
        let series: Record?
        let successor: Record?
        let recorded: [String:JSON]?
        var isRecorded: Bool { recorded != nil }
        init(_ reply:[String:JSON],for mutation:Mutation) throws {
            guard let command=mutation.teamCompletion else { throw TeamCompletion.invalid }
            let body=try command.body(for:mutation)
            for key in ["team_id","project_id","task_id","task_generation","request_id","series_id","series_generation","series_project_id","planned_next_id"] {
                guard reply[key] == body[key] else { throw TeamCompletion.invalid }
            }
            guard reply["review_protocol"] == .number(1),reply["account"] == .string(command.scope.account),
                  reply["operation"] == .string(command.operation.rawValue),let role=TeamProjectRole(rawValue:reply["project_role"]?.text ?? ""),
                  ["recorded","unrecorded"].contains(reply["state"]?.text ?? "") else { throw TeamCompletion.invalid }
            func row(_ key:String,id:String?,generation:String?,project:String) throws -> Record? {
                guard let value=reply[key] else { throw TeamCompletion.invalid }
                if value == .null { return nil }
                guard let id,case .object(let fields)=value,fields["id"] == .string(id),fields["project_id"] == .string(project),
                      TeamProjectValue.id(fields["task_generation"]?.text ?? ""),generation == nil || fields["task_generation"] == .string(generation!),
                      TeamProjectValue.id(fields["user_id"]?.text ?? ""),case .string?=fields["title"],case .bool?=fields["completed"],
                      case .number(let v)?=fields["completion_version"],v.isFinite,v>=0,v<=9_007_199_254_740_991,v.rounded(.down)==v else {throw TeamCompletion.invalid}
                return Record(fields)
            }
            let task=try row("task",id:command.source.id,generation:command.source.string("task_generation"),project:command.scope.project)
            let series=try row("series",id:command.seriesID,generation:command.seriesGeneration,project:command.seriesProject)
            let recorded:[String:JSON]?
            let successor:Record?
            if reply["state"] == .string("recorded") {
                guard case .object(let receipt)?=reply["receipt"],receipt["replayed"] == .bool(true) else {throw TeamCompletion.invalid}
                let parsed=try command.receipt(receipt,for:mutation)
                guard receipt["task"] == reply["task"],receipt["successor"] == reply["successor"] else {throw TeamCompletion.invalid}
                recorded=receipt;successor=parsed.successor
            } else {
                guard reply["receipt"] == .null else {throw TeamCompletion.invalid}
                recorded=nil;successor=try row("successor",id:command.proposed?.id,generation:nil,project:command.scope.project)
            }
            self.mutation=mutation;self.role=role;self.task=task;self.series=series;self.successor=successor;self.recorded=recorded
        }
        func acknowledging(_ snapshot:Snapshot) -> Snapshot? {
            guard snapshot.pending.first == mutation,let recorded,let command=mutation.teamCompletion else {return nil}
            var result=snapshot
            let saved=Record(["id":.string(mutation.recordID),"team_completion_reply":.object(recorded)])
            guard command.acknowledge(saved,header:mutation,snapshot:&result) else {return nil}
            return result
        }
    }
}
