import Foundation

struct TeamWorkspaceUnavailable: LocalizedError {var errorDescription:String? {"This workspace needs a supported service to refresh team access. Your saved work is unchanged."}}
struct TeamWorkspaceServiceIncomplete:LocalizedError {var errorDescription:String? {"The team service needs its access-refresh update. Your saved work is unchanged."}}
struct TeamWorkspaceChanged: LocalizedError {
    var errorDescription:String? {"Project access changed during refresh. Your saved work is unchanged. Try again."}
}

/// The boundary certifies access, not a single content revision. Ordinary task
/// editing remains concurrent and every write retains its existing row guards.
struct TeamWorkspaceBoundary: Equatable, Sendable, Codable {
    struct Project: Equatable, Sendable {
        let id:String
        let team:String?
        let role:String
        let archived:Bool
        let canSend:Bool
    }
    let raw:[String:JSON]
    let account:String
    let origin:String
    let projects:[String:Project]
    var teamProjects:[String:String] {projects.compactMapValues(\.team)}
    init(_ raw:[String:JSON],account:String,origin:String) throws {
        guard TeamProjectValue.id(account),raw["workspace_boundary_protocol"] == .number(1),raw["account"] == .string(account),
              case .bool(let reads)?=raw["native_team_reads_enabled"],case .bool(let paused)?=raw["setup_paused"],
              case .array(let projectRows)?=raw["projects"],projectRows.count<=10000,case .array(let teams)?=raw["teams"],teams.count<=1000,
              let token=raw["token"]?.text,token.count==64,token.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
              let url=URL(string:origin),url.scheme=="https",url.host != nil,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,
              url.path.isEmpty || url.path=="/",!origin.hasSuffix("/") else {throw TeamProjectValue.invalid}
        var teamIDs:Set<String>=[],lastTeam=""
        for value in teams {
            guard case .object(let row)=value,let id=row["id"]?.text,TeamProjectValue.id(id),id>lastTeam,reads,
                  ["active","archived"].contains(row["state"]?.text ?? "") else {throw TeamProjectValue.invalid}
            _=try TeamProjectValue.revision(row["revision"]);_=try TeamProjectValue.revision(row["access_revision"])
            teamIDs.insert(id);lastTeam=id
        }
        var projects:[String:Project]=[:],lastProject=""
        for value in projectRows {
            guard case .object(let row)=value,let id=row["id"]?.text,TeamProjectValue.id(id),id>lastProject,
                  case .string(let role)?=row["role"],case .bool(let archived)?=row["archived"],case .bool(let send)?=row["can_send_tasks"] else {throw TeamProjectValue.invalid}
            let team=try TeamProjectValue.optionalID(row["team_id"])
            if let team {
                guard reads,teamIDs.contains(team),["manager","editor","viewer"].contains(role),!send || (!paused && !archived && role != "viewer") else {throw TeamProjectValue.invalid}
            } else {guard ["owner","collaborator"].contains(role),send else {throw TeamProjectValue.invalid}}
            projects[id]=Project(id:id,team:team,role:role,archived:archived,canSend:send);lastProject=id
        }
        self.raw=raw;self.account=account;self.origin=origin;self.projects=projects
    }
    private enum CodingKeys:String,CodingKey {case raw,origin}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self),raw=try c.decode([String:JSON].self,forKey:.raw)
        try self.init(raw,account:raw["account"]?.text ?? "",origin:c.decode(String.self,forKey:.origin))
    }
    func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(raw,forKey:.raw);try c.encode(origin,forKey:.origin)}
    func belongs(account:String,origin:String)->Bool {self.account==account && self.origin==origin}
}

/// UUID-only historical custody prevents an old team edit from later being
/// mistaken for an ordinary personal edit. It never grants read or write access.
struct TeamWorkspaceCache: Equatable, Sendable, Codable {
    let boundary:TeamWorkspaceBoundary
    let knownTeams:[String:String]
    let knownTasks:Set<String>
    private(set) var quarantined:Set<UUID>=[]
    init(boundary:TeamWorkspaceBoundary,previous:Self?,pending:[Mutation],tasks:[Record]=[]) throws {
        var known=previous?.boundary.belongs(account:boundary.account,origin:boundary.origin) == true ? previous!.knownTeams:[:]
        for (project,team) in boundary.teamProjects {
            guard known[project]==nil || known[project]==team else {throw TeamProjectValue.invalid}
            known[project]=team
        }
        func scope(_ change:Mutation) {
            if let s=change.teamTaskScope,s.account==boundary.account,s.origin==boundary.origin {if known[s.project]==nil {known[s.project]=s.team}}
            if let c=change.teamCompletion,c.scope.account==boundary.account,c.scope.origin==boundary.origin {if known[c.scope.project]==nil {known[c.scope.project]=c.scope.team};if known[c.seriesProject]==nil {known[c.seriesProject]=c.scope.team}}
            for item in change.teamTaskBatch?.items ?? [] {scope(item)}
        }
        for change in pending {scope(change)}
        var taskIDs=previous?.boundary.belongs(account:boundary.account,origin:boundary.origin)==true ? previous!.knownTasks:[]
        for task in tasks where known[task.string("project_id")] != nil && TeamProjectValue.id(task.id) {taskIDs.insert(task.id)}
        func remember(_ change:Mutation) {
            if let c=change.teamCompletion,c.scope.account==boundary.account,c.scope.origin==boundary.origin {taskIDs.insert(c.source.id);if let p=c.proposed {taskIDs.insert(p.id)}}
            if let s=change.teamTaskScope,s.account==boundary.account,s.origin==boundary.origin,change.table=="tasks",TeamProjectValue.id(change.recordID) {taskIDs.insert(change.recordID)}
            for item in change.teamTaskBatch?.items ?? [] {remember(item)}
        }
        for change in pending {remember(change)}
        guard taskIDs.count<=200000,known.count<=20000,known.allSatisfy({TeamProjectValue.id($0.key)&&TeamProjectValue.id($0.value)}) else {throw TeamProjectValue.invalid}
        self.boundary=boundary;knownTeams=known;knownTasks=taskIDs
        if previous?.boundary==boundary {quarantined=previous!.quarantined}
    }
    private enum CodingKeys:String,CodingKey {case boundary,knownTeams,knownTasks,quarantined}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        boundary=try c.decode(TeamWorkspaceBoundary.self,forKey:.boundary);knownTeams=try c.decode([String:String].self,forKey:.knownTeams)
        knownTasks=try c.decodeIfPresent(Set<String>.self,forKey:.knownTasks) ?? []
        quarantined=try c.decodeIfPresent(Set<UUID>.self,forKey:.quarantined) ?? []
        guard quarantined.count<=200000, knownTasks.count<=200000,knownTasks.allSatisfy(TeamProjectValue.id),knownTeams.count<=20000,knownTeams.allSatisfy({TeamProjectValue.id($0.key)&&TeamProjectValue.id($0.value)}),boundary.teamProjects.allSatisfy({knownTeams[$0.key]==$0.value}) else {throw TeamProjectValue.invalid}
    }
    func canSend(_ change:Mutation,in snapshot:Snapshot,cached:[String:[String:Record]]?=nil)->Bool {
        func allowed(_ scope:TeamTaskEditScope)->Bool {
            guard scope.account==boundary.account,scope.origin==boundary.origin,let p=boundary.projects[scope.project] else {return false}
            return p.team==scope.team && p.canSend
        }
        if let c=change.teamCompletion {
            guard allowed(c.scope) else {return false}
            return c.seriesID==c.source.id || allowed(TeamTaskEditScope(account:c.scope.account,origin:c.scope.origin,team:c.scope.team,project:c.seriesProject))
        }
        if let batch=change.teamTaskBatch {return !batch.items.isEmpty && batch.account==boundary.account && batch.origin==boundary.origin && batch.items.allSatisfy{canSend($0,in:snapshot,cached:cached)}}
        if let scope=change.teamTaskScope {return allowed(scope)}
        if change.table=="tasks",knownTasks.contains(change.recordID) {return false}
        guard ["projects","tasks","sections","project_collaborators"].contains(change.table) else {return true}
        let existing=cached?[change.table]?[change.recordID] ?? (cached == nil ? snapshot.tables[change.table]?.first{$0.id==change.recordID}:nil)
        let projects=change.table=="projects" ? [change.recordID]:[change.fields["project_id"]?.text,change.baseline?["project_id"]?.text,existing?.string("project_id")].compactMap{$0}
        return !projects.contains{knownTeams[$0] != nil}
    }
    func blocked(_ snapshot:Snapshot)->Set<UUID> {
        let cached=Dictionary(uniqueKeysWithValues:["tasks","projects","sections","project_collaborators"].map {table in
            (table,Dictionary((snapshot.tables[table] ?? []).map{($0.id,$0)},uniquingKeysWith:{first,_ in first}))
        })
        var blocked=Set(snapshot.pending.filter{!canSend($0,in:snapshot,cached:cached)}.map(\.id))
        guard !blocked.isEmpty else {return []}
        var produced:[UUID:Set<String>]=[:],dependents:[String:Set<UUID>]=[:]
        func identities(_ change:Mutation)->Set<String> {
            var ids:Set<String>=[]
            if change.table=="tasks" {ids.insert(change.recordID.lowercased())}
            if let c=change.teamCompletion {ids.insert(c.source.id.lowercased());if let p=c.proposed {ids.insert(p.id.lowercased())}}
            for item in change.teamTaskBatch?.items ?? [] {ids.formUnion(identities(item))}
            return ids
        }
        let uuid=try! NSRegularExpression(pattern:"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",options:.caseInsensitive)
        func references(_ value:JSON)->Set<String> {
            switch value {
            case .string(let text):return Set(uuid.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap {match in Range(match.range,in:text).map{String(text[$0]).lowercased()}})
            case .array(let rows):return rows.reduce(into:Set<String>()){$0.formUnion(references($1))}
            case .object(let fields):return fields.reduce(into:Set<String>()){result,item in
                guard !["title","description","body","text","name","labels","taskfold_draft_copy_v1"].contains(item.key) else {return}
                result.formUnion(references(item.value))
            }
            default:return []
            }
        }
        for change in snapshot.pending {
            produced[change.id]=identities(change)
            guard let data=try? JSONEncoder().encode(change),let value=try? JSONDecoder().decode(JSON.self,from:data) else {blocked.insert(change.id);continue}
            for id in references(value) {dependents[id,default:[]].insert(change.id)}
        }
        var queue=Array(blocked),index=0,visited=Set<String>()
        while index<queue.count {
            let request=queue[index];index+=1
            for id in produced[request] ?? [] where visited.insert(id).inserted {
                for dependent in dependents[id] ?? [] where blocked.insert(dependent).inserted {queue.append(dependent)}
            }
        }
        return blocked
    }
    /// Team discussion commands stay unavailable until the organization UI and
    /// scoped discussion adapter are accepted. A creator UUID grants no shortcut.
    func nativeConversationWritable(project:String) -> Bool {knownTeams[project] == nil}
    func filtering(_ tables:[String:[Record]],localProjects:Set<String>=[]) -> [String:[Record]] {
        var result=tables
        let allowed=Set(boundary.projects.keys).union(localProjects)
        result["projects"]=tables["projects"]?.filter{allowed.contains($0.id)}
        result["tasks"]=tables["tasks"]?.filter{row in let p=row.string("project_id");return p.isEmpty ? row.string("user_id")==boundary.account && !knownTasks.contains(row.id):allowed.contains(p) && (!knownTasks.contains(row.id) || boundary.projects[p]?.team != nil)}
        for table in ["sections","project_collaborators"] {result[table]=tables[table]?.filter{allowed.contains($0.string("project_id"))}}
        let tasks=Set((result["tasks"] ?? []).map(\.id))
        result[TaskActivity.table]=tables[TaskActivity.table]?.filter {row in
            let scopes=[row["before_state"].object["project_id"]?.text,row["after_state"].object["project_id"]?.text].compactMap{$0}.filter{!$0.isEmpty}
            return scopes.allSatisfy{allowed.contains($0)} && (!scopes.isEmpty || tasks.contains(row.string("task_id")) || (row.string("user_id")==boundary.account && !knownTasks.contains(row.string("task_id"))))
        }
        result[TaskAssignmentProvenance.table]=tables[TaskAssignmentProvenance.table]?.filter{tasks.contains($0.string("task_id"))}
        for table in [SharedComment.table,SharedMention.table] {result[table]=tables[table]?.filter{row in
            if table==SharedComment.table {return tasks.contains(row.string("task_id"))}
            return true
        }}
        for key in result.keys where key.hasPrefix("project_members:") && !allowed.contains(String(key.dropFirst("project_members:".count))) {result.removeValue(forKey:key)}
        var people:Set<String>=[boundary.account]
        for table in ["projects","tasks","project_collaborators",TaskActivity.table] {for row in result[table] ?? [] {for key in ["user_id","assigned_to","actor_id"] where !row.string(key).isEmpty {people.insert(row.string(key))}}}
        result["profiles"]=tables["profiles"]?.filter{people.contains($0.string("user_id").isEmpty ? $0.id:$0.string("user_id"))}
        result[ConversationOutbox.viewsTable]=tables[ConversationOutbox.viewsTable]?.filter{$0["access_token"] == boundary.raw["token"]}
        var visible=Snapshot(tables:result)
        ConversationCache.prune(&visible)
        return visible.tables
    }
    /// Presentation can be masked before an encrypted Recovery write finishes.
    /// The original snapshot/queue is retained unchanged until durable protection.
    func presentation(_ snapshot:Snapshot)->[String:[Record]] {
        let local=Set(snapshot.pending.filter{$0.table=="projects" && $0.method=="POST" && knownTeams[$0.recordID]==nil && $0.fields["user_id"] == .string(boundary.account)}.map(\.recordID))
        var visible=Snapshot(tables:filtering(snapshot.tables))
        // A local project intent does not authorize old cached server children
        // at the same UUID. Reconstruct only its authored local work.
        for change in snapshot.pending where change.teamTaskScope==nil && change.teamCompletion==nil && change.teamTaskBatch==nil {
            if change.table=="projects",local.contains(change.recordID) {visible.apply(change)}
            else if change.table=="tasks",!knownTasks.contains(change.recordID) {
                let existing=visible.tables["tasks"]?.first{$0.id==change.recordID}
                let project=change.fields["project_id"]?.text ?? existing?.string("project_id") ?? ""
                if local.contains(project),(existing != nil || change.fields["user_id"] == .string(boundary.account)) {visible.apply(change)}
            }
        }
        let present=Set((visible.tables["projects"] ?? []).map(\.id)).intersection(local)
        return filtering(visible.tables,localProjects:present)
    }
    func widgetTokens(_ snapshot:Snapshot)->[String:String] {
        let tasks=Dictionary((snapshot.tables["tasks"] ?? []).map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        return WidgetCompletion.tokens(snapshot).filter {key,_ in
            let root=SubtaskTree.referencePath(key)?.first ?? key
            guard let task=tasks[root] else {return false}
            return !knownTasks.contains(root) && knownTeams[task.string("project_id")]==nil
        }
    }
    func requiresRecovery(_ snapshot:Snapshot)->Bool {
        if !blocked(snapshot).subtracting(quarantined).isEmpty {return true}
        let visible=presentation(snapshot)
        let projects=Dictionary((visible["projects"] ?? []).map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        let tasks=Dictionary((visible["tasks"] ?? []).map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        return (snapshot.tables["projects"] ?? []).contains{boundary.projects[$0.id]==nil && projects[$0.id] != $0}
          || (snapshot.tables["tasks"] ?? []).contains{!$0.string("project_id").isEmpty && boundary.projects[$0.string("project_id")]==nil && tasks[$0.id] != $0}
    }
    func merging(_ remote:[String:[Record]],into snapshot:Snapshot)->Snapshot {
        var result=snapshot
        result.tables.merge(filtering(remote)){_,new in new}
        let blocked=blocked(snapshot)
        let localProjects=Set(snapshot.pending.filter{$0.table=="projects" && $0.method=="POST" && !blocked.contains($0.id) && knownTeams[$0.recordID]==nil}.map(\.recordID))
        for change in snapshot.pending where !blocked.contains(change.id) {result.apply(change)}
        result.tables=filtering(result.tables,localProjects:localProjects)
        var committed=self;committed.quarantined=blocked
        result.teamWorkspace=committed
        ConversationCache.prune(&result)
        return result
    }
}


/// A small account/backend-bound privacy fence survives restart even when the
/// larger encrypted Recovery write cannot finish. It contains no task text.
struct TeamAccessFenceDisk:Sendable {
    let disk:AccountRemovalDisk
    let origin:String
    func save(_ boundary:TeamWorkspaceBoundary) throws {
        guard boundary.belongs(account:disk.account,origin:origin) else {throw TeamProjectValue.invalid}
        let data=try JSONEncoder().encode(boundary)
        guard data.count<=4000000 else {throw TeamProjectValue.invalid}
        try disk.writable {try data.write(to:disk.teamAccessFence,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    }
    func load() throws -> TeamWorkspaceBoundary? {
        guard !disk.removed else {throw CancellationError()}
        guard FileManager.default.fileExists(atPath:disk.teamAccessFence.path) else {return nil}
        guard try disk.teamAccessFence.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else {throw TeamProjectValue.invalid}
        let handle=try FileHandle(forReadingFrom:disk.teamAccessFence);defer{try? handle.close()}
        let data=try handle.read(upToCount:4000001) ?? Data()
        guard data.count<=4000000 else {throw TeamProjectValue.invalid}
        let value=try JSONDecoder().decode(TeamWorkspaceBoundary.self,from:data)
        guard value.belongs(account:disk.account,origin:origin) else {throw CancellationError()}
        return value
    }
    /// Only a fresh authorized workspace read can repair damaged metadata.
    /// A valid fence for another backend/account is never removed here.
    func clear(after boundary:TeamWorkspaceBoundary) throws {
        guard boundary.belongs(account:disk.account,origin:origin) else {throw CancellationError()}
        try disk.writable {
            guard FileManager.default.fileExists(atPath:disk.teamAccessFence.path) else {return}
            do {_=try load()} catch is CancellationError {throw CancellationError()} catch { /* Fresh verified access replaces damaged metadata only. */ }
            try FileManager.default.removeItem(at:disk.teamAccessFence)
        }
    }
    func clear() throws {
        try disk.writable {
            guard FileManager.default.fileExists(atPath:disk.teamAccessFence.path) else {return}
            _=try load()
            try FileManager.default.removeItem(at:disk.teamAccessFence)
        }
    }
}

struct TeamWorkspaceRead: Sendable {let tables:[String:[Record]];let boundary:TeamWorkspaceBoundary?}

@MainActor extension Backend {
    static let workspaceTables=["projects","sections","labels","tasks","profiles","project_collaborators","saved_views","favorites","view_preferences","view_orders",WorkflowTemplate.table,ReminderSnooze.table,FocusSessionChange.table,TaskActivity.epochTable,TaskActivity.table]
    func workspaceBoundary(account:String) async throws -> TeamWorkspaceBoundary {
        guard session?.user.id==account else {throw CancellationError()}
        let origin=try accountRemovalOrigin
        let data:Data
        do {data=try await request("/rest/v1/rpc/taskfold_workspace_boundary",method:"POST",body:[:],expectedAccount:account)}
        catch is TeamWorkspaceUnavailable {
            // Only a genuinely legacy service may use legacy sync. A partially
            // installed team service must not lose its role boundary silently.
            do {_=try await request("/rest/v1/rpc/taskfold_teams",method:"POST",body:["_action":.string("list"),"_body":.object([:])],expectedAccount:account)}
            catch is TeamWorkspaceUnavailable {throw TeamWorkspaceUnavailable()}
            throw TeamWorkspaceServiceIncomplete()
        }
        return try TeamWorkspaceBoundary(JSONDecoder().decode([String:JSON].self,from:data),account:account,origin:origin)
    }
    func workspaceRead(account:String,initial:TeamWorkspaceBoundary?,allowLegacy:Bool) async throws -> TeamWorkspaceRead {
        if let initial {guard initial.belongs(account:account,origin:try accountRemovalOrigin) else {throw CancellationError()}}
        var before=initial
        for _ in 0..<3 {
            if before==nil {
                do {before=try await workspaceBoundary(account:account)}
                catch is TeamWorkspaceUnavailable {guard allowLegacy else {throw TeamWorkspaceUnavailable()}}
            }
            var remote:[String:[Record]]=[:]
            for table in Self.workspaceTables {remote[table]=try await rows(table,expectedAccount:account,maximumRows:100000)}
            remote[TaskAssignmentProvenance.table]=await assignmentProvenanceRows()
            guard session?.user.id==account else {throw CancellationError()}
            guard let expected=before else {return TeamWorkspaceRead(tables:remote,boundary:nil)}
            let after=try await workspaceBoundary(account:account)
            if expected==after {
                return TeamWorkspaceRead(tables:try TeamWorkspaceCache(boundary:after,previous:nil,pending:[]).filtering(remote),boundary:after)
            }
            // Discard the entire partial read and restart under the new access
            // boundary. Ordinary content edits do not change this boundary.
            before=after
        }
        throw TeamWorkspaceChanged()
    }
}


/// Opening-time authority for a team-task editor or an insert-only creation. This value is
/// intentionally not Codable: a backup or cached draft cannot restore authority.
struct TeamTaskEditorDraft: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case existing, creation }
    let kind: Kind
    let source: Record
    let workspace: WorkspaceBinding
    let session: UUID
    let scope: TeamTaskEditScope
    let accessToken: String
    let role: TeamProjectRole
    static let editableFields = TeamTaskEditScope.fields.subtracting(["completed", "completed_at"])
    static var unavailable: AppFailure { AppFailure(message: "Project access changed. Your draft is still here; reopen the task before saving.") }
    init(source: Record, workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) throws {
        try self.init(source: source, kind: .existing, workspace: workspace, session: session, cache: cache, enabled: enabled)
    }
    init(creating source: Record, workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) throws {
        // New work has no inherited creator, completion, provenance or private
        // content. Authored fields remain intact; unsupported input is refused.
        let fixed: Set<String> = ["id", "user_id", "project_id", "task_generation", "created_at", "completed", "completion_version", "comments", "attachments", "reminders"]
        guard Set(source.fields.keys).isSubset(of: fixed.union(Self.editableFields)),
              source.string("user_id") == workspace.account, source["completed"] == .bool(false),
              source["completion_version"] == .number(0),
              ["comments", "attachments", "reminders"].allSatisfy({ source[$0] == .null || source[$0] == .array([]) }),
              !cache.knownTasks.contains(source.id) else { throw Self.unavailable }
        try self.init(source: source, kind: .creation, workspace: workspace, session: session, cache: cache, enabled: enabled)
    }
    private init(source: Record, kind: Kind, workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) throws {
        let boundary = cache.boundary, project = source.string("project_id")
        guard enabled, workspace.account == boundary.account,
              let permission = boundary.projects[project], let team = permission.team,
              permission.canSend, !permission.archived, ["manager", "editor"].contains(permission.role),
              cache.knownTeams[project] == team,
              boundary.raw["teams"]?.list.contains(where: { $0.object["id"] == .string(team) && $0.object["state"] == .string("active") }) == true,
              [source.id, source.string("user_id"), source.string("task_generation")].allSatisfy(TeamProjectValue.id),
              case .string? = source.fields["title"], case .bool? = source.fields["completed"],
              let token = boundary.raw["token"]?.text else { throw Self.unavailable }
        self.kind = kind; self.source = source; self.workspace = workspace; self.session = session
        scope = TeamTaskEditScope(account: boundary.account, origin: boundary.origin, team: team, project: project)
        accessToken = token; role = TeamProjectRole(rawValue: permission.role)!
    }
    func permits(current: Record?, workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool) -> Bool {
        guard enabled, self.workspace == workspace, self.session == session,
              cache.boundary.belongs(account: scope.account, origin: scope.origin), cache.boundary.raw["token"] == .string(accessToken),
              cache.knownTeams[scope.project] == scope.team,
              cache.boundary.raw["teams"]?.list.contains(where: { $0.object["id"] == .string(scope.team) && $0.object["state"] == .string("active") }) == true,
              let permission = cache.boundary.projects[scope.project], permission.team == scope.team,
              permission.canSend, !permission.archived, ["manager", "editor"].contains(permission.role) else { return false }
        if kind == .creation { return current == nil && !cache.knownTasks.contains(source.id) }
        guard let current else { return false }
        return ["id", "user_id", "project_id", "task_generation"].allSatisfy({ current.fields[$0] == source.fields[$0] })
    }
    /// Preserve authored baselines; never merge another person's new value into
    /// our intent or silently discard unsupported changes from a broad editor.
    func mutation(desired: Record, current: Record?, workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool, requestID: UUID = UUID()) throws -> Mutation? {
        guard permits(current: current, workspace: workspace, session: session, cache: cache, enabled: enabled) else { throw Self.unavailable }
        let keys = Set(source.fields.keys).union(desired.fields.keys)
        let changed = Set(keys.filter { key in
            Self.editableFields.contains(key) ? source[key] != desired[key] : source.fields[key] != desired.fields[key]
        })
        guard changed.isSubset(of: Self.editableFields) else { throw AppFailure(message: "This change needs its own team action. Your draft is still here; no fields have been saved.") }
        if kind == .creation {
            guard !desired.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure(message: "Include a task name before saving.") }
            guard TeamTaskRecurrence.supported(desired) else { throw TeamTaskRecurrence.invalid }
            let change = Mutation(id: requestID, table: "tasks", recordID: source.id, method: "POST", fields: desired.fields, insertOnly: true, teamTaskScope: scope)
            return try scope.capturing(change, existing: nil)
        }
        guard let current else { throw Self.unavailable }
        var fields: [String: JSON] = [:]
        for key in changed {
            if current[key] == desired[key] { continue }
            fields[key] = desired[key]
        }
        guard !fields.isEmpty else { return nil }
        if let title = fields["title"] {
            guard case .string(let text) = title, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure(message: "Include a task name before saving.") }
        }
        let mutation = Mutation(id: requestID, table: "tasks", recordID: source.id, method: "PATCH", fields: fields,
                                baseline: TaskCompletionRevision.editBaseline(for: fields, from: source), teamTaskScope: scope)
        return try scope.capturing(mutation, existing: current)
    }
}

extension TeamTaskEditorDraft {
    /// Deletion reviews the complete saved task, unlike a field-level edit. A
    /// newer observed row must never silently become the deletion baseline.
    func deletion(current: Record?, workspace: WorkspaceBinding, session: UUID, cache: TeamWorkspaceCache, enabled: Bool, requestID: UUID) throws -> Mutation {
        guard kind == .existing, permits(current: current, workspace: workspace, session: session, cache: cache, enabled: enabled),
              let current else { throw Self.unavailable }
        guard TeamCompletion.sameLocal(source, current) else {
            throw AppFailure(message: "This task changed before deletion. Close this review and reopen its current details; nothing has been removed.")
        }
        let change = Mutation(id: requestID, table: "tasks", recordID: source.id, method: "DELETE", fields: [:], baseline: source.fields, teamTaskScope: scope)
        return try scope.capturing(change, existing: current)
    }
}

/// Personal capture never inherits team custody. Historical team identity remains
/// authoritative even after the account loses access and the project row vanishes.
enum PersonalConnectionDestination: Equatable {
    case inbox, personal, team, unavailable
    var supported: Bool { self == .inbox || self == .personal }
    var explanation: String? {
        switch self {
        case .team: "This project belongs to a team. Personal email addresses and task connections cannot send into team projects. You can keep this connection paused or revoke it."
        case .unavailable: "This project’s personal access could not be confirmed. Refresh your workspace before resuming or replacing this connection. You can still pause or revoke it."
        default: nil
        }
    }
    static func resolve(project: String?, projects: [Record], cache: TeamWorkspaceCache?, account: String, origin: String?) -> Self {
        guard let project else { return .inbox }
        if let cache {
            guard let origin, cache.boundary.belongs(account: account, origin: origin) else { return .unavailable }
            if cache.knownTeams[project] != nil { return .team }
            guard let access = cache.boundary.projects[project], access.team == nil, access.canSend else { return .unavailable }
        }
        guard let record = projects.first(where: { $0.id == project }) else { return .unavailable }
        // Keep pre-team services compatible while rejecting any explicit team marker.
        if record["team_id"] != .null { return .team }
        return .personal
    }
}
