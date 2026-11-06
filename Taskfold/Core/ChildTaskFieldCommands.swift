import Foundation
import CryptoKit
import Observation

/// Expanded list rows are contextual projections, never new backend records.
/// Keep existing flat hierarchy-filter results intact and preserve sibling order.
enum ChildTaskListOutline {
    static func rows(_ roots: [Record], expanded: Set<String>, projects: [Record], workspace: WorkspaceBinding, includeCompleted: Bool) throws -> [Record] {
        guard !roots.contains(where: { SubtaskTree.referencePath($0.id) != nil }) else { return roots }
        var result: [Record] = []
        for root in roots {
            result.append(root)
            guard expanded.contains(root.id), !root["subtasks"].list.isEmpty else { continue }
            let index = try TaskHierarchyIndex(roots: [root], projects: projects, workspace: workspace)
            for item in index.items where item.isSubtask {
                guard includeCompleted || !item.source.completed else { continue }
                var parent = root.id, visible = expanded.contains(parent)
                for key in item.path.dropLast() {
                    parent = SubtaskTree.reference(parent: parent, key: key)
                    if !expanded.contains(parent) || (!includeCompleted && index.item(parent)?.source.completed == true) { visible = false; break }
                }
                if visible { result.append(item.record) }
            }
        }
        return result
    }
}

/// A task-list opening is bound to the workspace and original parent identity.
/// The full authored path selects one fresh child; a missing/moved child never
/// falls through to the first row in the parent’s checklist.
struct ChildTaskFieldOpening: Equatable, Sendable {
    let workspace: WorkspaceBinding
    let root: Record
    let path: [String]
    var rootID: String { root.id }
    static var unavailable: AppFailure { AppFailure(message: "This subtask is no longer available here. Reopen it from the task list.") }
    init(reference: String, root: Record, workspace: WorkspaceBinding) throws {
        guard reference.utf8.count <= 32_768,
              let path = SubtaskTree.referencePath(reference), path.count <= 25,
              path.dropFirst().allSatisfy({ $0.utf8.count <= 128 }),
              path[0].utf8.elementsEqual(root.id.utf8), TeamProjectValue.id(root.id),
              TeamProjectValue.id(workspace.account) else { throw Self.unavailable }
        _ = try TeamProjectValue.optionalID(root.fields["task_generation"] ?? .null)
        _ = try TeamProjectValue.optionalID(root.fields["project_id"] ?? .null)
        self.workspace = workspace; self.root = root; self.path = Array(path.dropFirst())
    }
    func permits(account: String, generation: UUID, root current: Record?) -> Bool {
        guard workspace.matches(account: account, generation: generation), let current else { return false }
        return ["id", "user_id", "project_id", "task_generation"].allSatisfy {
            AuthoredValueComparison.exactJSON(root[$0], current[$0])
        }
    }
    func key(in read: ChildTaskRecordRead) throws -> String {
        guard permits(account: read.context.account, generation: read.context.workspace, root: read.context.root),
              let node = read.orderedNodes.first(where: { node in
                  node.path.count == path.count && zip(node.path, path).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
              }) else { throw Self.unavailable }
        return node.key
    }
}

/// A saved field intent is not a task snapshot and carries no mutation authority.
struct ChildTaskFieldCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix="child-field-command-v1."
    static let maximumStoredBytes=140_000
    static var invalid:AppFailure {AppFailure(message:"Review this saved child change before sending it. Your saved work is unchanged.")}
    static let fields:Set<String>=["title","description","priority","due_date","due_time","deadline_date","duration_minutes","time_zone","scheduled_at","assigned_to","labels","reminder_specs"]
    let account:String,origin:String
    let body:[String:JSON]
    var id:String {body["request_id"]!.text}
    var description:String {"Private child field request"}
    var debugDescription:String {description}
    var removedFields: Set<String> { Set(body["remove_fields"]?.list.map(\.text) ?? []) }
    var touchedFields: Set<String> { Set(body["changes"]!.object.keys).union(removedFields) }
    var after: ChildTaskFieldBaseline { .init(fields: touchedFields, values: body["changes"]!.object) }
    init(read:ChildTaskRecordRead,key:String,changes:[String:JSON],removing:Set<String>=[],revision:Double?=nil,requestID:UUID=UUID()) throws {
        var validation = changes
        for field in removing { validation[field] = field == "priority" ? .number(4) : ["labels", "reminder_specs"].contains(field) ? .array([]) : .null }
        guard let node=read.nodes[key],TaskKind(Record(node.fields)) != .unsupported,
              revision == nil || (revision! >= 1 && revision! <= node.revision),
              TaskKind.permits(Mutation(table:"tasks",recordID:node.fields["id"]!.text,method:"PATCH",fields:validation),existing:Record(node.fields)) else {throw Self.invalid}
        var body:[String:JSON] = ["protocol":.number(removing.isEmpty ? 1 : 2),"account":.string(read.context.account),"request_id":.string(requestID.uuidString.lowercased()),"task_id":.string(read.context.root.id),"task_generation":read.context.root["task_generation"],"project_id":read.context.root["project_id"],"node_key":.string(node.key),"incarnation":.string(node.incarnation),"revision":.number(revision ?? node.revision),"changes":.object(changes)]
        if !removing.isEmpty { body["remove_fields"] = .array(removing.sorted().map(JSON.string)) }
        try self.init(account:read.context.account,origin:read.context.origin,body:body)
    }
    init(account:String,origin:String,body:[String:JSON]) throws {
        try TeamOrganizationValue.scope(account:account,origin:origin)
        let keys:Set<String> = ["protocol","account","request_id","task_id","task_generation","project_id","node_key","incarnation","revision","changes"]
        let v2 = body["protocol"] == .number(2)
        guard origin.utf8.count<=2048,Set(body.keys)==(v2 ? keys.union(["remove_fields"]) : keys),v2 || body["protocol"] == .number(1),body["account"] == .string(account) else {throw Self.invalid}
        for key in ["request_id","task_id","incarnation"] {_=try TeamOrganizationValue.id(body[key])}
        _=try TeamProjectValue.optionalID(body["task_generation"]);_=try TeamProjectValue.optionalID(body["project_id"])
        let rev=try TeamProjectValue.revision(body["revision"])
        var removed:Set<String> = []
        if v2 {
            guard case .array(let rows)? = body["remove_fields"], rows.count <= 11 else { throw Self.invalid }
            for row in rows {
                guard case .string(let key) = row, key != "title", Self.fields.contains(key), removed.insert(key).inserted else { throw Self.invalid }
            }
        }
        guard rev<9_007_199_254_740_991,case .string(let key)?=body["node_key"],!key.isEmpty,key.utf8.count<=128,key.utf8.elementsEqual(key.precomposedStringWithCanonicalMapping.utf8),
              case .object(let changes)?=body["changes"],!changes.isEmpty || !removed.isEmpty,Set(changes.keys).isSubset(of:Self.fields),removed.isDisjoint(with:changes.keys) else {throw Self.invalid}
        for (key,value) in changes {try Self.validate(key,value)}
        let encoder=TaskfoldJSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        guard try encoder.encode(body).count<=128_000 else {throw Self.invalid}
        self.account=account;self.origin=origin;self.body=body
    }
    static func ==(a:Self,b:Self)->Bool {
        a.account.utf8.elementsEqual(b.account.utf8) && a.origin.utf8.elementsEqual(b.origin.utf8)
        && AuthoredValueComparison.exactJSON(.object(a.body),.object(b.body))
    }
    func sameTarget(_ other:Self)->Bool {
        account==other.account && origin==other.origin && ["task_id","task_generation","project_id","node_key","incarnation"].allSatisfy{body[$0]==other.body[$0]}
    }
    private enum CodingKeys:String,CodingKey {case account,origin,body}
    init(from decoder:Decoder) throws {let c=try decoder.container(keyedBy:CodingKeys.self);try self.init(account:c.decode(String.self,forKey:.account),origin:c.decode(String.self,forKey:.origin),body:c.decode([String:JSON].self,forKey:.body))}
    func confirmed(_ raw:[String:JSON]) throws -> ChildTaskFieldReceipt {
        guard Set(raw.keys)==["protocol","account","request_id","task_id","task_generation","project_id","node_key","incarnation","revision","replayed"],raw["protocol"] == body["protocol"],raw["account"] == .string(account),
              ["request_id","task_id","task_generation","project_id","node_key","incarnation"].allSatisfy({raw[$0]==body[$0]}),case .bool?=raw["replayed"],
              try TeamProjectValue.revision(raw["revision"])>=TeamProjectValue.revision(body["revision"]) else {throw Self.invalid}
        return ChildTaskFieldReceipt(raw:raw)
    }
    static func validate(_ key:String,_ value:JSON) throws {
        switch key {
        case "title":guard case .string(let text)=value,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=10000 else {throw invalid}
        case "description":if value != .null {guard case .string(let text)=value,text.count<=100000 else {throw invalid}}
        case "priority":guard case .number(let n)=value,n.isFinite,n.rounded()==n,(1...4).contains(n) else {throw invalid}
        case "duration_minutes":if value != .null {guard case .number(let n)=value,n.isFinite,n.rounded()==n,(1...10080).contains(n) else {throw invalid}}
        case "due_date","deadline_date":if value != .null {guard case .string(let text)=value,text.count==10,let date=Dates.parse(text),Dates.day(date)==text else {throw invalid}}
        case "due_time":if value != .null {
            guard case .string(let text)=value else {throw invalid};let parts=text.split(separator:":",omittingEmptySubsequences:false)
            guard (2...3).contains(parts.count),parts.allSatisfy({$0.count==2 && Int($0) != nil}),let h=Int(parts[0]),let m=Int(parts[1]),(0...23).contains(h),(0...59).contains(m),parts.count==2 || (0...59).contains(Int(parts[2])!) else {throw invalid}
        }
        case "time_zone":if value != .null {guard case .string(let zone)=value,TimeZone(identifier:zone) != nil else {throw invalid}}
        case "scheduled_at":if value != .null {guard case .string(let text)=value,TaskPlanning.instant(text) != nil else {throw invalid}}
        case "assigned_to":_=try TeamProjectValue.optionalID(value)
        case "labels":guard TeamTaskLabelsDraft(value).supported else {throw invalid}
        case "reminder_specs":guard TeamTaskRemindersDraft(value).supported else {throw invalid}
        default:throw invalid
        }
        var stack=[(value,0)]
        while let (item,depth)=stack.popLast() {
            guard depth<=128 else {throw invalid}
            switch item {
            case .number(let n):guard n.isFinite,abs(n)<=9_007_199_254_740_991 else {throw invalid}
            case .array(let rows):stack.append(contentsOf:rows.map{($0,depth+1)})
            case .object(let fields):stack.append(contentsOf:fields.values.map{($0,depth+1)})
            default:break
            }
        }
    }
}
/// Private inverse metadata records only touched fields. A missing key remains
/// distinct from an explicit null; neither a task snapshot nor a network payload.
struct ChildTaskFieldBaseline: Codable, Sendable, Equatable {
    let fields: Set<String>
    let values: [String: JSON]
    static func ==(a: Self, b: Self) -> Bool {
        a.fields == b.fields && AuthoredValueComparison.exactJSON(.object(a.values), .object(b.values))
    }
    func validate(for command: ChildTaskFieldCommand) throws {
        guard fields == command.touchedFields, Set(values.keys).isSubset(of: fields),
              !fields.contains("title") || values["title"] != nil else { throw ChildTaskFieldCommand.invalid }
        for (key, value) in values { try ChildTaskFieldCommand.validate(key, value) }
        guard try TaskfoldJSONEncoder().encode(self).count <= 140_000 else { throw ChildTaskFieldCommand.invalid }
    }
    init(fields: Set<String>, values: [String: JSON]) { self.fields = fields; self.values = values }
    init(read: ChildTaskRecordRead, command: ChildTaskFieldCommand) throws {
        guard command.account == read.context.account, command.origin == read.context.origin,
              command.body["task_id"] == .string(read.context.root.id), command.body["task_generation"] == read.context.root["task_generation"],
              command.body["project_id"] == read.context.root["project_id"], let node = read.nodes[command.body["node_key"]!.text],
              command.body["incarnation"] == .string(node.incarnation), command.body["revision"] == .number(node.revision) else { throw ChildTaskFieldCommand.invalid }
        self.init(fields: command.touchedFields, values: node.fields.filter { command.touchedFields.contains($0.key) })
        try validate(for: command)
    }
    func inverse(of entry: ChildTaskFieldJournalState.Entry, read: ChildTaskRecordRead, requestID: UUID = UUID()) throws -> ChildTaskFieldCommand {
        let c = entry.command, context = read.context
        try validate(for: c)
        guard entry.phase == .confirmed, let receipt = entry.receipt, try c.confirmed(receipt.raw) == receipt,
              entry.before == self, self != c.after, c.account == context.account, c.origin == context.origin,
              c.body["task_id"] == .string(context.root.id), c.body["task_generation"] == context.root["task_generation"], c.body["project_id"] == context.root["project_id"],
              let node = read.nodes[c.body["node_key"]!.text], c.body["incarnation"] == .string(node.incarnation),
              node.revision >= Double(receipt.raw["revision"]!.integer),
              AuthoredValueComparison.exactJSON(.object(node.fields.filter { fields.contains($0.key) }), .object(c.after.values)), requestID.uuidString.lowercased() != c.id else { throw ChildTaskFieldCommand.invalid }
        return try .init(read: read, key: node.key, changes: values, removing: fields.subtracting(values.keys), revision: Double(receipt.raw["revision"]!.integer), requestID: requestID)
    }
}
struct ChildTaskFieldReceipt:Equatable,Sendable,Codable {let raw:[String:JSON]}
/// A terminal decision acknowledges the exact original identity. Closing never
/// changes task content; an already-applied request returns its existing receipt.
struct ChildTaskFieldResolution: Equatable, Sendable, Codable {
    let raw: [String: JSON]
    let receipt: ChildTaskFieldReceipt?
    var closed: Bool { receipt == nil }
    init(command: ChildTaskFieldCommand, raw: [String: JSON]) throws {
        let identities = ["protocol", "account", "request_id", "task_id", "task_generation", "project_id", "node_key", "incarnation"]
        guard Set(raw.keys) == Set(identities + ["outcome", "receipt"]),
              identities.allSatisfy({ AuthoredValueComparison.exactJSON(raw[$0] ?? .null, command.body[$0] ?? .null) }) else { throw ChildTaskFieldCommand.invalid }
        switch raw["outcome"] {
        case .string("closed"):
            guard raw["receipt"] == .null else { throw ChildTaskFieldCommand.invalid }; receipt = nil
        case .string("applied"):
            guard case .object(let proof)? = raw["receipt"] else { throw ChildTaskFieldCommand.invalid }
            receipt = try command.confirmed(proof)
        default: throw ChildTaskFieldCommand.invalid
        }
        self.raw = raw
    }
    private enum CodingKeys: String, CodingKey { case raw }
    init(from decoder: Decoder) throws {
        // A persisted proof is always revalidated against its owning command by
        // the journal. Decoding alone cannot authorize a replacement.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        raw = try c.decode([String: JSON].self, forKey: .raw)
        if case .object(let proof)? = raw["receipt"] { receipt = ChildTaskFieldReceipt(raw: proof) } else { receipt = nil }
    }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(raw, forKey: .raw) }
}
struct ChildTaskFieldJournalState:ReviewedTeamFileCommand,CustomStringConvertible,CustomDebugStringConvertible {
    enum Phase:String,Codable,Sendable {case queued,attempted,confirmed,closed}
    struct Entry:Codable,Sendable {let command:ChildTaskFieldCommand;var phase:Phase;var receipt:ChildTaskFieldReceipt?;var resolution:ChildTaskFieldResolution? = nil;var before:ChildTaskFieldBaseline? = nil;var historyOf:String? = nil}
    static let storagePrefix="child-field-journal-v1."
    static let fileName="requests.taskfoldchildfields"
    static let encryptionContext="com.taskfold.child-field-journal.v1"
    static let maximumStoredBytes=8_400_000
    static var invalid:AppFailure {ChildTaskFieldCommand.invalid}
    let account:String,origin:String
    var entries:[Entry]
    var description:String {"Private child field journal"}
    var debugDescription:String {description}
    init(account:String,origin:String,entries:[Entry]=[]) throws {
        try TeamOrganizationValue.scope(account:account,origin:origin)
        guard origin.utf8.count<=2048,entries.count<=64 else {throw Self.invalid};var ids:Set<String>=[]
        var prior: [String: Entry] = [:], activeParents: Set<String> = []
        for row in entries {
            try row.before?.validate(for: row.command)
            if let parentID = row.historyOf {
                guard let parent = prior[parentID], parent.phase == .confirmed, let before = parent.before, let proof = parent.receipt,
                      row.command.sameTarget(parent.command), row.command.body["revision"] == proof.raw["revision"], row.before == parent.command.after,
                      row.command.after == before, row.phase == .closed || activeParents.insert(parentID).inserted else { throw Self.invalid }
            }
            prior[row.command.id] = row
            guard row.command.account==account,row.command.origin==origin,ids.insert(row.command.id).inserted else {throw Self.invalid}
            if row.phase == .confirmed {guard let receipt=row.receipt,try row.command.confirmed(receipt.raw)==receipt,row.resolution==nil else {throw Self.invalid}}
            else if row.phase == .closed {guard row.receipt==nil,let proof=row.resolution,try ChildTaskFieldResolution(command:row.command,raw:proof.raw)==proof,proof.closed else {throw Self.invalid}}
            else {guard row.receipt==nil,row.resolution==nil else {throw Self.invalid}}
        }
        self.account=account;self.origin=origin;self.entries=entries
    }
    static func ==(a:Self,b:Self)->Bool {
        a.account==b.account && a.origin==b.origin && a.entries.count==b.entries.count && zip(a.entries,b.entries).allSatisfy{$0.command==$1.command && $0.phase==$1.phase && $0.receipt==$1.receipt && $0.resolution==$1.resolution && $0.before==$1.before && $0.historyOf==$1.historyOf}
    }
    private enum CodingKeys:String,CodingKey {case version,account,origin,entries}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self), version=try c.decode(Int.self,forKey:.version)
        guard [1,2].contains(version) else {throw Self.invalid}
        let entries=try c.decode([Entry].self,forKey:.entries)
        guard version == 2 || entries.allSatisfy({ $0.before == nil && $0.historyOf == nil && $0.command.body["protocol"] == .number(1) }) else { throw Self.invalid }
        try self.init(account:c.decode(String.self,forKey:.account),origin:c.decode(String.self,forKey:.origin),entries:entries)
    }
    func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(entries.contains { $0.before != nil || $0.historyOf != nil || $0.command.body["protocol"] == .number(2) } ? 2 : 1,forKey:.version);try c.encode(account,forKey:.account);try c.encode(origin,forKey:.origin);try c.encode(entries,forKey:.entries)}
}
/// Derive the physical path from account/origin as well as binding ciphertext AAD.
/// A cleanup for another origin cannot unlink this scope's file without a key.
struct ChildTaskFieldJournalFileIO:CalendarSecureItemIO {
    let base:ReviewedTeamCommandFileIO<ChildTaskFieldJournalState>
    init(directory:URL,account:String,origin:String,encryptionKey:@escaping @Sendable() throws -> SymmetricKey) throws {
        try TeamOrganizationValue.scope(account:account,origin:origin)
        base = .init(directory:directory.appendingPathComponent(account).appendingPathComponent(CalendarOAuthConfiguration.digest(origin)),account:account,origin:origin,encryptionKey:encryptionKey)
    }
    var file:URL {base.file}
    func read(key:String) throws -> Data? {try base.read(key:key)}
    func write(_ data:Data,key:String) throws {try base.write(data,key:key)}
    func remove(key:String) throws {try base.remove(key:key)}
}
actor ChildTaskFieldJournal {
    private let admit: @Sendable (Set<String>) throws -> Void
    private let io:any CalendarSecureItemIO
    private let lock:AutomationEnrollmentProcessLock
    private let removalDirectory:URL
    let account:String,origin:String
    private var key:String {ChildTaskFieldJournalState.storagePrefix+account+"."+CalendarOAuthConfiguration.digest(origin)}
    init(account:String,origin:String,io:any CalendarSecureItemIO,coordinationDirectory:URL,removalDirectory:URL, admit: @escaping @Sendable (Set<String>) throws -> Void = { _ in }) throws {
        self.admit = admit;
        try TeamOrganizationValue.scope(account:account,origin:origin)
        self.account=account;self.origin=origin;self.io=io;lock = .init(directory:coordinationDirectory);self.removalDirectory=removalDirectory
    }
    private func guarded<T>(lease:CalendarReadLease?,_ action:() throws -> T) throws -> T {
        try lock.withExclusive(account:account,check:{try lease?.check()}) {
            try AccountRemovalDisk(directory:removalDirectory,account:account).writable {try lease?.check();return try action()}
        }
    }
    private func read() throws -> ChildTaskFieldJournalState {
        guard let data=try io.read(key:key) else {return try .init(account:account,origin:origin)}
        guard data.count<=ChildTaskFieldJournalState.maximumStoredBytes else {throw ChildTaskFieldCommand.invalid}
        let state=try TaskfoldJSONDecoder().decode(ChildTaskFieldJournalState.self,from:data)
        guard state.account==account,state.origin==origin else {throw ChildTaskFieldCommand.invalid};return state
    }
    private func write(_ state:ChildTaskFieldJournalState,lease:CalendarReadLease) throws {
        _=try ChildTaskFieldJournalState(account:account,origin:origin,entries:state.entries)
        let data=try TaskfoldJSONEncoder().encode(state);guard data.count<=ChildTaskFieldJournalState.maximumStoredBytes else {throw ChildTaskFieldCommand.invalid}
        try lease.check();try io.write(data,key:key)
    }
    func load() throws -> ChildTaskFieldJournalState {try guarded(lease:nil){try read()}}
    /// Coalesce only provably unsent intents for the same captured revision.
    /// Once attempted, both body and request identity remain immutable.
    func enqueue(_ command:ChildTaskFieldCommand,before:ChildTaskFieldBaseline?=nil,lease:CalendarReadLease) throws -> ChildTaskFieldCommand {
        try guarded(lease:lease) {
            try before?.validate(for: command)
            try admit([command.body["task_id"]!.text])
            guard command.account==account,command.origin==origin else {throw ChildTaskFieldCommand.invalid};var state=try read()
            if let old=state.entries.first(where:{$0.command.id==command.id}) {guard old.command==command,old.before==before else {throw ChildTaskFieldCommand.invalid};return old.command}
            if let index=state.entries.lastIndex(where:{$0.phase == .queued && $0.historyOf == nil && $0.command.sameTarget(command) && $0.command.body["revision"]==command.body["revision"]}) {
                let oldEntry = state.entries[index], old = oldEntry.command
                var body = old.body, values = old.body["changes"]!.object, removed = old.removedFields
                for field in command.touchedFields { values[field] = command.body["changes"]!.object[field]; removed.remove(field) }
                removed.formUnion(command.removedFields)
                body["changes"] = .object(values); body["protocol"] = .number(removed.isEmpty ? 1 : 2)
                body["remove_fields"] = removed.isEmpty ? nil : .array(removed.sorted().map(JSON.string))
                let merged=try ChildTaskFieldCommand(account:account,origin:origin,body:body)
                var baseline: ChildTaskFieldBaseline?
                if let a = oldEntry.before, let b = before {
                    let overlap = a.fields.intersection(b.fields)
                    guard AuthoredValueComparison.exactJSON(.object(a.values.filter { overlap.contains($0.key) }), .object(b.values.filter { overlap.contains($0.key) })) else { throw ChildTaskFieldCommand.invalid }
                    baseline = .init(fields: a.fields.union(b.fields), values: a.values.merging(b.values) { old, _ in old })
                }
                state.entries[index] = .init(command:merged,phase:.queued,receipt:nil,before:baseline)
                try write(state,lease:lease);return merged
            }
            guard state.entries.count<64 else {throw ChildTaskFieldCommand.invalid}
            state.entries.append(.init(command:command,phase:.queued,receipt:nil,before:before));try write(state,lease:lease);return command
        }
    }
    /// Under the same process/account lock, two windows share one inverse ID.
    func enqueueInverse(of reviewed: ChildTaskFieldJournalState.Entry, read fresh: ChildTaskRecordRead, lease: CalendarReadLease) throws -> ChildTaskFieldCommand {
        try guarded(lease: lease) {
            var state = try read()
            guard let parent = state.entries.first(where: { $0.command.id == reviewed.command.id }), parent.command == reviewed.command,
                  parent.receipt == reviewed.receipt, parent.before == reviewed.before, parent.historyOf == reviewed.historyOf,
                  parent.phase == .confirmed, let before = parent.before else { throw ChildTaskFieldCommand.invalid }
            try admit([parent.command.body["task_id"]!.text])
            // The existing exact inverse remains retryable after a lost reply,
            // even if its own application has changed the fresh field values.
            if let existing = state.entries.first(where: { $0.historyOf == parent.command.id && $0.phase != .closed }) { return existing.command }
            let command = try before.inverse(of: parent, read: fresh)
            guard state.entries.count < 64 else { throw ChildTaskFieldCommand.invalid }
            state.entries.append(.init(command: command, phase: .queued, receipt: nil, before: parent.command.after, historyOf: parent.command.id))
            try write(state, lease: lease); return command
        }
    }
    func attempt(_ reviewed:ChildTaskFieldCommand,lease:CalendarReadLease) throws -> ChildTaskFieldJournalState.Entry {
        try guarded(lease:lease) {
            try admit([reviewed.body["task_id"]!.text])
            var state=try read();guard let index=state.entries.firstIndex(where:{$0.command.id==reviewed.id}),state.entries[index].command==reviewed else {throw ChildTaskFieldCommand.invalid}
            guard !state.entries[..<index].contains(where:{$0.phase != .confirmed && $0.phase != .closed && $0.command.sameTarget(reviewed)}) else {throw ChildTaskFieldCommand.invalid}
            guard state.entries[index].phase != .closed else {throw ChildTaskFieldWriteFailure(reason:.closed)}
            if state.entries[index].phase == .queued {state.entries[index].phase = .attempted;try write(state,lease:lease)}
            return state.entries[index]
        }
    }
    func confirm(_ command:ChildTaskFieldCommand,receipt:ChildTaskFieldReceipt,lease:CalendarReadLease) throws {
        try guarded(lease:lease) {
            guard try command.confirmed(receipt.raw)==receipt else {throw ChildTaskFieldCommand.invalid};var state=try read()
            guard let index=state.entries.firstIndex(where:{$0.command.id==command.id}),state.entries[index].command==command,state.entries[index].phase != .queued,state.entries[index].phase != .closed else {throw ChildTaskFieldCommand.invalid}
            if let old=state.entries[index].receipt {
                guard AuthoredValueComparison.exactJSON(.object(old.raw.filter{$0.key != "replayed"}),.object(receipt.raw.filter{$0.key != "replayed"})) else {throw ChildTaskFieldCommand.invalid};return
            }
            state.entries[index].phase = .confirmed;state.entries[index].receipt=receipt;try write(state,lease:lease)
        }
    }
    /// Persist the terminal service decision before exposing any replacement.
    /// An unknown close result remains attempted and must use this same identity.
    func resolve(_ reviewed: ChildTaskFieldCommand, result: ChildTaskFieldResolution, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            guard try ChildTaskFieldResolution(command: reviewed, raw: result.raw) == result else { throw ChildTaskFieldCommand.invalid }
            var state = try read()
            guard let index = state.entries.firstIndex(where: { $0.command.id == reviewed.id }), state.entries[index].command == reviewed else { throw ChildTaskFieldCommand.invalid }
            if state.entries[index].phase == .closed {
                guard state.entries[index].resolution == result else { throw ChildTaskFieldCommand.invalid }; return
            }
            if state.entries[index].phase == .confirmed {
                guard let receipt = result.receipt, let existing = state.entries[index].receipt,
                      AuthoredValueComparison.exactJSON(.object(receipt.raw.filter { $0.key != "replayed" }), .object(existing.raw.filter { $0.key != "replayed" })) else { throw ChildTaskFieldCommand.invalid }; return
            }
            if let receipt = result.receipt {
                state.entries[index].phase = .confirmed; state.entries[index].receipt = receipt
            } else {
                state.entries[index].phase = .closed; state.entries[index].resolution = result
            }
            try write(state, lease: lease)
        }
    }
    /// A replacement has a fresh identity and preserves the original terminal
    /// proof. It cannot silently coalesce with another window's saved intent.
    func replaceClosed(_ original: ChildTaskFieldCommand, with replacement: ChildTaskFieldCommand, before: ChildTaskFieldBaseline? = nil, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            try before?.validate(for: replacement)
            try admit([replacement.body["task_id"]!.text])
            var state = try read()
            guard let old = state.entries.first(where: { $0.command.id == original.id }), old.command == original,
                  old.phase == .closed, old.resolution?.closed == true,
                  original.sameTarget(replacement), replacement.id != original.id,
                  replacement.body["revision"]!.integer >= original.body["revision"]!.integer,
                  replacement.touchedFields.isSubset(of: original.touchedFields),
                  !state.entries.contains(where: { $0.command.id == replacement.id || ($0.phase != .closed && $0.phase != .confirmed && $0.command.sameTarget(replacement)) }),
                  state.entries.count < 64 else { throw ChildTaskFieldCommand.invalid }
            state.entries.append(.init(command: replacement, phase: .queued, receipt: nil, before: before)); try write(state, lease: lease)
        }
    }
    /// Explicitly discarding an uncertain request never cancels service work.
    func discard(_ reviewed:ChildTaskFieldCommand,allowUnconfirmed:Bool=false,lease:CalendarReadLease) throws {
        try guarded(lease:lease) {
            var state=try read();guard let index=state.entries.firstIndex(where:{$0.command.id==reviewed.id}),state.entries[index].command==reviewed else {throw ChildTaskFieldCommand.invalid}
            guard state.entries[index].phase != .attempted || allowUnconfirmed else {throw ChildTaskFieldCommand.invalid}
            guard !state.entries.contains(where: { $0.historyOf == reviewed.id }) else { throw AppFailure(message: "Remove the newer saved Undo or Redo requests first. Their recovery still needs this receipt.") }
            state.entries.remove(at:index);try write(state,lease:lease)
        }
    }
    func removeAccount() throws {try lock.withExclusive(account:account){try io.remove(key:key)}}
}
struct ChildTaskFieldClientScope:Hashable,Sendable {
    let account:String,origin:String
    let workspace:UUID,session:UUID,access:UUID
    init(_ context:ChildTaskRecordContext) {self.init(account:context.account,origin:context.origin,workspace:context.workspace,session:context.session,access:context.access)}
    init(account:String,origin:String,workspace:UUID,session:UUID,access:UUID) {self.account=account;self.origin=origin;self.workspace=workspace;self.session=session;self.access=access}
}
struct ChildTaskFieldWriteFailure:LocalizedError {
    enum Reason {case unavailable,review,busy,limit,unconfirmed,closed}
    let reason:Reason
    var errorDescription:String? {
        switch reason {
        case .closed:return "This original request is closed. Review current values before saving another change."
        case .unavailable:return "Child editing is unavailable or access changed. Your saved request is kept."
        case .review:return "This child change needs review. Your original saved request is kept."
        case .busy:return "Another change is finishing. Retry the same saved request shortly."
        case .limit:return "This change has reached a service limit. Your saved request is kept."
        case .unconfirmed:return "The result couldn’t be confirmed. Your original saved request is kept."
        }
    }
}
@MainActor protocol ChildTaskFieldCommandService:AnyObject {
    func childTaskFieldCommand(_ command:ChildTaskFieldCommand,session:UUID) async throws -> ChildTaskFieldReceipt
    func closeChildTaskFieldCommand(_ command:ChildTaskFieldCommand,session:UUID) async throws -> ChildTaskFieldResolution
}
extension ChildTaskFieldCommandService {
    func closeChildTaskFieldCommand(_ command:ChildTaskFieldCommand,session:UUID) async throws -> ChildTaskFieldResolution { throw ChildTaskFieldWriteFailure(reason:.unavailable) }
}
extension Backend:ChildTaskFieldCommandService {}
/// Sending never deletes recovery or writes a task cache. Confirmation is durable
/// before the caller receives success; the UI must refresh current task data.
@MainActor final class ChildTaskFieldSender {
    private let scope:ChildTaskFieldClientScope
    private let current:()->ChildTaskFieldClientScope?
    private let canSend:(ChildTaskFieldCommand)->Bool
    private let journal:ChildTaskFieldJournal
    private let service:any ChildTaskFieldCommandService
    private let lease=CalendarReadLease()
    private var closed=false
    init(scope:ChildTaskFieldClientScope,journal:ChildTaskFieldJournal,service:any ChildTaskFieldCommandService,current:@escaping()->ChildTaskFieldClientScope?,canSend:@escaping(ChildTaskFieldCommand)->Bool) {
        self.scope=scope;self.journal=journal;self.service=service;self.current=current;self.canSend=canSend
    }
    func close() {closed=true;lease.cancel()}
    /// Metadata-only terminal resolution works after task access/gates are lost.
    /// It cannot send task edits and never invents a replacement request.
    func resolve(_ reviewed: ChildTaskFieldCommand) async throws -> ChildTaskFieldResolution {
        do {
            try check(); guard reviewed.account == scope.account, reviewed.origin == scope.origin else { throw CancellationError() }
            let state = try await journal.load(); try check()
            guard let entry = state.entries.first(where: { $0.command.id == reviewed.id }), entry.command == reviewed else { throw ChildTaskFieldCommand.invalid }
            if let proof = entry.resolution { return try ChildTaskFieldResolution(command: reviewed, raw: proof.raw) }
            // Preserve attempted state before a potentially lost close reply.
            // A prior unsettled request is resolved first, like ordinary Send.
            _ = try await journal.attempt(reviewed, lease: lease); try check()
            let result: ChildTaskFieldResolution
            do { result = try await service.closeChildTaskFieldCommand(reviewed, session: scope.session) }
            catch is CancellationError { throw CancellationError() }
            catch let error as ChildTaskFieldWriteFailure { throw error }
            catch { throw ChildTaskFieldWriteFailure(reason: .unconfirmed) }
            try check(); _ = try ChildTaskFieldResolution(command: reviewed, raw: result.raw)
            try await journal.resolve(reviewed, result: result, lease: lease); try check(); return result
        } catch { try check(); throw error }
    }
    private func check() throws {try lease.check();guard !closed,current()==scope else {throw CancellationError()}}
    func send(_ reviewed:ChildTaskFieldCommand) async throws -> ChildTaskFieldReceipt {
        do {
            try check();guard reviewed.account==scope.account,reviewed.origin==scope.origin else {throw CancellationError()}
            let saved=try await journal.load();try check()
            guard let entry=saved.entries.first(where:{$0.command.id==reviewed.id}),entry.command==reviewed else {throw ChildTaskFieldCommand.invalid}
            if let proof=entry.receipt {return try reviewed.confirmed(proof.raw)}
            guard canSend(reviewed) else {throw ChildTaskFieldWriteFailure(reason:.unavailable)}
            _=try await journal.attempt(reviewed,lease:lease);try check()
            guard canSend(reviewed) else {throw ChildTaskFieldWriteFailure(reason:.unavailable)}
            let result: ChildTaskFieldReceipt
            do { result = try await service.childTaskFieldCommand(reviewed, session: scope.session) }
            catch is CancellationError { throw CancellationError() }
            catch let refusal as ChildTaskFieldWriteFailure { throw refusal }
            catch { throw ChildTaskFieldWriteFailure(reason: .unconfirmed) }
            try check()
            guard try reviewed.confirmed(result.raw)==result else {throw ChildTaskFieldCommand.invalid}
            try await journal.confirm(reviewed,receipt:result,lease:lease);try check();return result
        } catch {try check();throw error}
    }
}

/// One presentation owns one account lease. Closing hides private draft text;
/// disk recovery survives until an exact, explicitly reviewed discard.
@MainActor @Observable final class ChildTaskFieldRecoveryModel {
    private(set) var entries: [ChildTaskFieldJournalState.Entry] = []
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var message: String?
    private let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskFieldJournal
    private let sender: ChildTaskFieldSender
    private let current: () -> ChildTaskFieldClientScope?
    private let canQueue: (ChildTaskFieldCommand) -> Bool
    private let refresh: () async -> Void
    private let didApply: (ChildTaskFieldJournalState.Entry, ChildTaskFieldClientScope) -> Void
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskFieldJournal, service: any ChildTaskFieldCommandService,
         current: @escaping () -> ChildTaskFieldClientScope?, canQueue: @escaping (ChildTaskFieldCommand) -> Bool,
         canSend: @escaping (ChildTaskFieldCommand) -> Bool, refresh: @escaping () async -> Void, didApply: @escaping (ChildTaskFieldJournalState.Entry, ChildTaskFieldClientScope) -> Void = { _, _ in }) {
        self.scope = scope; self.journal = journal; self.current = current; self.canQueue = canQueue; self.refresh = refresh; self.didApply = didApply
        sender = ChildTaskFieldSender(scope: scope, journal: journal, service: service, current: current, canSend: canSend)
    }
    func close() {
        closed = true; lease.cancel(); sender.close(); entries = []; loaded = false; message = nil
    }
    private func check() throws {
        try lease.check(); guard !closed, current() == scope else { close(); throw CancellationError() }
    }
    private func update() async throws {
        let value = try await journal.load(); try check(); entries = value.entries; loaded = true
    }
    private func failure(_ error: Error) {
        guard (try? check()) != nil else { return }
        message = error is CancellationError ? nil : error.localizedDescription
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await update(); message = nil } catch { failure(error) }
    }
    /// Durable staging only: saving never performs network I/O or an optimistic
    /// cache write. Sending requires a separate call from an explicit Save/Send
    /// intent; opening or restoring a draft never sends it.
    @discardableResult func save(_ command: ChildTaskFieldCommand, before: ChildTaskFieldBaseline? = nil) async -> ChildTaskFieldCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin, canQueue(command) else { throw ChildTaskFieldWriteFailure(reason: .unavailable) }
            let saved = try await journal.enqueue(command, before: before, lease: lease); try check(); try await update()
            message = "Saved on this device. Review the request when you’re ready to send."; return saved
        } catch { failure(error); return nil }
    }
    @discardableResult func send(_ reviewed: ChildTaskFieldCommand) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do {
            try check(); let wasConfirmed = entries.contains { $0.command == reviewed && $0.phase == .confirmed }
            _ = try await sender.send(reviewed); try check(); try await update()
            if !wasConfirmed, let entry = entries.first(where: { $0.command == reviewed && $0.phase == .confirmed }), let before = entry.before, before != reviewed.after { didApply(entry, scope) }
            message = "Change confirmed. Refreshing current tasks…"
            await refresh(); try check()
            message = "Change confirmed. The saved request is kept until you remove it."; return true
        } catch {
            // A failed response/save may have left durable attempted state.
            // Re-read before offering controls; never show the old queued phase.
            do { try check(); try await update() } catch { loaded = false; entries = [] }
            failure(error); return false
        }
    }
    @discardableResult func saveReplacement(_ comparison: ChildTaskFieldComparison, choosing groups: Set<String>) async -> ChildTaskFieldCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check()
            guard let replacement = try comparison.replacement(choosing: groups), canQueue(replacement) else { throw ChildTaskFieldWriteFailure(reason: .review) }
            try await journal.replaceClosed(comparison.original, with: replacement, before: try ChildTaskFieldBaseline(read: comparison.read, command: replacement), lease: lease)
            try check(); try await update(); message = "Reviewed changes saved on this device. Review the new request before sending."; return replacement
        } catch { failure(error); return nil }
    }
    func closeOriginal(_ reviewed: ChildTaskFieldCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try check(); let wasConfirmed = entries.contains { $0.command == reviewed && $0.phase == .confirmed }
            let result = try await sender.resolve(reviewed); try check(); try await update()
            if !wasConfirmed, let entry = entries.first(where: { $0.command == reviewed && $0.phase == .confirmed }), let before = entry.before, before != reviewed.after { didApply(entry, scope) }
            if result.closed { message = "Original request closed. Your task was not changed by closing it." }
            else { await refresh(); try check(); message = "The original change had already applied. Its confirmation is saved." }
        } catch {
            do { try check(); try await update() } catch { loaded = false; entries = [] }
            failure(error)
        }
    }
    func canReverse(_ entry: ChildTaskFieldJournalState.Entry) -> Bool {
        entry.phase == .confirmed && entry.before != nil && entry.before != entry.command.after && !entries.contains { $0.historyOf == entry.command.id && $0.phase != .closed }
    }
    func isRedo(_ entry: ChildTaskFieldJournalState.Entry) -> Bool {
        var depth = 0, current = entry
        while let parent = current.historyOf, let row = entries.first(where: { $0.command.id == parent }) { depth += 1; current = row }
        return depth % 2 == 1
    }
    func showHistoryNotice(_ notice: ChildTaskHistoryNotice) {
        guard notice.scope == scope, notice.kind == .fields, (try? check()) != nil else { return }
        message = notice.message
    }
    @discardableResult func queueInverse(_ entry: ChildTaskFieldJournalState.Entry, read: ChildTaskRecordRead) async -> ChildTaskFieldCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check(); guard ChildTaskFieldClientScope(read.context) == scope, canQueue(entry.command) else { throw CancellationError() }
            let saved = try await journal.enqueueInverse(of: entry, read: read, lease: lease)
            try check(); try await update(); message = "Saved on this device. The original confirmation is kept."; return saved
        } catch { failure(error); return nil }
    }
    func discard(_ reviewed: ChildTaskFieldCommand, uncertainConfirmed: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try check(); try await journal.discard(reviewed, allowUnconfirmed: uncertainConfirmed, lease: lease)
            try check(); try await update(); message = "Saved request removed. This does not undo a server change."
        } catch {
            // Another window may have sent or replaced the reviewed request.
            // Show its durable phase/body before offering a new confirmation.
            do { try check(); try await update() } catch { loaded = false; entries = [] }
            failure(error)
        }
    }
}

/// Planning intent for the independently addressed child editor. Keep the complete
/// authored source; only explicit planning actions may normalize its schedule.
struct ChildTaskPlanningDraft: Sendable {
    static let keys: Set<String> = ["due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes"]
    let original: Record
    private(set) var value: Record
    init(original: Record, restored: Record? = nil) { self.original = original; value = restored ?? original }
    var changes: [String: JSON] {
        var result: [String: JSON] = [:]
        for key in Self.keys {
            let before = original.fields[key].map { JSON.object([key: $0]) } ?? .object([:])
            let after = value.fields[key].map { JSON.object([key: $0]) } ?? .object([:])
            if !AuthoredValueComparison.exactJSON(before, after) { result[key] = value.fields[key] ?? .null }
        }
        return result
    }
    func applying(to record: Record) -> Record {
        var result = record
        for key in Self.keys { result.fields[key] = value.fields[key] }
        return result
    }
    mutating func plannedDay(_ day: String?, calendar: Calendar = .current) throws {
        if let day {
            try ChildTaskFieldCommand.validate("due_date", .string(day))
            try update(["due_date": .string(day)], calendar: calendar)
        } else {
            try update(["due_date": .null, "due_time": .null, "time_zone": .null, "scheduled_at": .null], calendar: calendar)
        }
    }
    mutating func clock(_ time: String?, calendar: Calendar = .current) throws {
        guard time == nil || value.due != nil else { throw PlannerFailure(message: "Choose a planned date before adding a time.") }
        var fields: [String: JSON] = ["due_time": time.map(JSON.string) ?? .null]
        if time == nil { fields["time_zone"] = .null; fields["scheduled_at"] = .null }
        try update(fields, calendar: calendar)
    }
    mutating func zone(_ identifier: String?, calendar: Calendar = .current) throws {
        guard value.due != nil, !value.string("due_time").isEmpty else { throw PlannerFailure(message: "Choose a planned date and time first.") }
        try update(["time_zone": identifier.map(JSON.string) ?? .null], calendar: calendar)
    }
    mutating func deadline(_ day: String?) throws { try update(TaskDeadlines.fields(day: day)) }
    mutating func estimate(_ minutes: Int?) throws { try update(["duration_minutes": minutes.map { .number(Double($0)) } ?? .null]) }
    private mutating func update(_ proposed: [String: JSON], calendar: Calendar = .current) throws {
        guard proposed.contains(where: { key, field in
            !AuthoredValueComparison.exactJSON(value.fields[key].map { .object([key: $0]) } ?? .object([:]), .object([key: field]))
        }) else { return }
        for (key, field) in proposed { try ChildTaskFieldCommand.validate(key, field) }
        var fields = TaskPlanning.fields(proposed, existing: value, calendar: calendar)
        var next = value; next.fields.merge(fields) { _, new in new }
        let zone = next.string("time_zone")
        if !TaskPlanning.keys.isDisjoint(with: proposed.keys), next.due != nil,
           !next.string("due_time").isEmpty, zone.isEmpty || TimeZone(identifier: zone) != nil {
            guard let start = TaskPlanning.start(next, calendar: calendar) else {
                throw PlannerFailure(message: "This date and time aren’t available in the selected time zone. Choose another time.")
            }
            var source = Calendar(identifier: .gregorian); source.timeZone = TimeZone(identifier: zone) ?? calendar.timeZone
            let parts = source.dateComponents([.hour, .minute], from: start)
            let resolved = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            // A nonexistent DST wall minute resolves forward. Show the actual
            // minute instead of retaining a clock that disagrees with the plan.
            if String(next.string("due_time").prefix(5)) != resolved {
                fields["due_time"] = .string(resolved); next["due_time"] = .string(resolved)
            }
        }
        for (key, field) in fields { try ChildTaskFieldCommand.validate(key, field) }
        value = next
    }
}

/// Labels retain authored order and unknown legacy values. Catalog resolution is
/// explicit for personal tasks; shared labels never consult a personal catalog.
struct ChildTaskLabelsDraft {
    enum Kind { case personal, shared }
    let original: Record
    let kind: Kind
    private var draft: TeamTaskLabelsDraft
    init(original: Record, restored: Record? = nil, kind: Kind) {
        self.original = original; self.kind = kind
        draft = TeamTaskLabelsDraft((restored ?? original)["labels"])
    }
    var supported: Bool { draft.supported }
    var entries: [TeamTaskLabelsDraft.Entry] { draft.entries }
    var value: JSON {
        // An untouched null stays null, but authored strings must be compared
        // by exact bytes: replacing a canonically equivalent label is an edit.
        draft.original == .null && draft.entries.isEmpty ? .null : draft.value
    }
    var changes: [String: JSON] {
        guard supported, !AuthoredValueComparison.exactJSON(original["labels"], value) else { return [:] }
        return ["labels": value]
    }
    func applying(to record: Record) -> Record {
        var result = record
        // Do not materialize a missing field merely by opening the editor.
        if !changes.isEmpty || original.fields["labels"] != nil { result["labels"] = value }
        return result
    }
    func name(_ entry: TeamTaskLabelsDraft.Entry, catalog: [Record]) -> String {
        if kind == .personal, let label = catalog.first(where: { $0.id == entry.value }), !label.name.isEmpty { return label.name }
        return entry.name ?? "Saved label"
    }
    mutating func addName(_ input: String, catalog: [Record]) throws {
        let name = try TeamTaskLabelsDraft.name(input)
        if kind == .personal {
            let matches = catalog.filter { $0.name == name }
            guard matches.count <= 1 else { throw AppFailure(message: "Several labels have this name. Choose one from Your labels.") }
            if let label = matches.first { try addCatalog(label.id, catalog: catalog); return }
        }
        try draft.add(name)
    }
    mutating func addCatalog(_ id: String, catalog: [Record]) throws {
        guard kind == .personal, supported, let label = catalog.first(where: { $0.id == id }),
              !label.id.isEmpty, label.id.utf8.count <= 1024 else { throw ChildTaskFieldCommand.invalid }
        let uniqueName = catalog.filter { $0.name == label.name }.count == 1
        guard !entries.contains(where: { $0.value == id || uniqueName && $0.value == label.name }) else { throw AppFailure(message: "That label is already on this task.") }
        guard entries.count < 256 else { throw AppFailure(message: "A task can have up to 256 labels. Remove one before adding another.") }
        // Use the same portable storage validation, without passing IDs through
        // the shared-label name validator or normalizing other saved entries.
        draft = TeamTaskLabelsDraft(.array(entries.map { .string($0.value) } + [.string(id)]))
    }
    mutating func remove(_ id: Int) { draft.remove(id) }
}

struct ChildTaskAssignmentDraft {
    let original: Record
    private(set) var value: Record
    init(original: Record, restored: Record? = nil) { self.original = original; value = restored ?? original }
    var selected: String { value.string("assigned_to") }
    var changes: [String: JSON] {
        AuthoredValueComparison.exactJSON(original["assigned_to"], value["assigned_to"]) ? [:] : ["assigned_to": value["assigned_to"]]
    }
    mutating func choose(_ id: String?) throws {
        let value = id.map(JSON.string) ?? .null
        try ChildTaskFieldCommand.validate("assigned_to", value)
        self.value["assigned_to"] = value
    }
    func applying(to record: Record) -> Record {
        var result = record
        if !changes.isEmpty || original.fields["assigned_to"] != nil { result["assigned_to"] = value["assigned_to"] }
        return result
    }
}

/// Personal-project directories are transient presentation. Every other-person
/// selection rechecks the same captured project; no names enter a field command.
@MainActor @Observable final class ChildTaskPersonalRecipientPicker {
    struct Person: Identifiable { let id: String; let name: String }
    private(set) var people: [Person] = []
    private(set) var busy = false
    private(set) var message: String?
    private var attempt = UUID()
    private let account: String
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let read: () async throws -> [Record]
    @ObservationIgnored private let apply: (String?) -> String?
    init(account: String, current: @escaping () -> Bool, read: @escaping () async throws -> [Record], apply: @escaping (String?) -> String?) {
        self.account = account; self.current = current; self.read = read; self.apply = apply
    }
    func invalidate() { attempt = UUID(); people = []; busy = false; message = nil }
    private func directory(_ rows: [Record]) throws -> [Person] {
        guard rows.count <= 500, rows.allSatisfy({ TeamProjectValue.id($0.id) }), Set(rows.map(\.id)).count == rows.count else { throw ChildTaskFieldCommand.invalid }
        return rows.map { Person(id: $0.id, name: TeamOrganizationDetail.Member.identity($0["display_name"]) ?? "Project member") }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func refresh() async {
        invalidate(); guard current(), !Task.isCancelled else { return }; let id = attempt; busy = true
        defer { if id == attempt { busy = false } }
        do {
            let rows = try directory(await read())
            guard id == attempt else { return }; guard current(), !Task.isCancelled else { invalidate(); return }; people = rows
        } catch {
            guard id == attempt else { return }; people = []; message = current() ? "Couldn’t refresh assignment choices. Try again." : nil
        }
    }
    private func accept(_ user: String?) -> Bool { if let error = apply(user) { message = error; return false }; return true }
    func choose(_ user: String?) async -> Bool {
        guard current(), !Task.isCancelled else { invalidate(); return false }
        if user == nil || user == account { invalidate(); return accept(user) }
        guard !busy else { return false }
        guard let known = people.first(where: { $0.id == user }) else { return false }
        let id = attempt; busy = true; message = nil
        defer { if id == attempt { busy = false } }
        do {
            let fresh = try directory(await read())
            guard id == attempt else { return false }; guard current(), !Task.isCancelled else { invalidate(); return false }; people = fresh
            guard fresh.contains(where: { $0.id == known.id }) else { message = "That person is no longer in this project. Choose someone from the updated list."; return false }
            return accept(known.id)
        } catch {
            guard id == attempt else { return false }; guard current(), !Task.isCancelled else { invalidate(); return false }
            if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) { return accept(known.id) }
            people = []; message = "Couldn’t check this assignment. Refresh the choices and try again."; return false
        }
    }
}

/// A reminder field intent preserves complete source data and opaque rows. The
/// existing portable composer handles mutations; only its explicit Apply enters
/// this parent draft, never a partially edited nested schedule.
struct ChildTaskRemindersDraft {
    let original: Record
    private(set) var value: Record
    init(original: Record, restored: Record? = nil) { self.original = original; value = restored ?? original }
    var changes: [String: JSON] {
        AuthoredValueComparison.exactJSON(original["reminder_specs"], value["reminder_specs"]) ? [:] : ["reminder_specs": value["reminder_specs"]]
    }
    mutating func apply(_ settings: JSON) throws {
        try ChildTaskFieldCommand.validate("reminder_specs", settings)
        value["reminder_specs"] = settings
    }
    func applying(to record: Record) -> Record {
        var result = record
        if !changes.isEmpty || original.fields["reminder_specs"] != nil { result["reminder_specs"] = value["reminder_specs"] }
        return result
    }
    static func summary(_ value: JSON) -> String {
        let draft = TeamTaskRemindersDraft(value)
        guard draft.supported else { return "Saved reminder settings · kept unchanged" }
        if draft.rows.isEmpty { return "At planned time" }
        return draft.rows.map { row in
            guard let spec = ReminderSpec(row: row), spec.locallyEditable else { return "Saved reminder · kept unchanged" }
            let name = spec.id == ReminderSpec.plannedID ? "At planned time" : spec.label
            return name + (spec.enabled ? (spec.timeSensitive ? " · Time Sensitive" : " · Enabled") : " · Off")
        }.joined(separator: "\n")
    }
}

/// Compare a saved intent with a fresh, strictly verified own-node read. There is
/// no implicit overwrite: every differing group starts with the current value.
/// Related planning fields stay one choice so a fixed instant cannot be mixed
/// accidentally with another saved date/time/zone.
struct ChildTaskFieldComparison: Sendable {
    struct Group: Sendable {
        let id: String
        let fields: [String]
        let differs: Bool
        let warning: String?
    }
    static let planning: Set<String> = ["due_date", "due_time", "time_zone", "scheduled_at"]
    let original: ChildTaskFieldCommand
    let read: ChildTaskRecordRead
    let current: Record
    let groups: [Group]
    init(original: ChildTaskFieldCommand, read: ChildTaskRecordRead) throws {
        let c = read.context
        guard original.account == c.account, original.origin == c.origin,
              original.body["task_id"] == .string(c.root.id), original.body["task_generation"] == c.root["task_generation"], original.body["project_id"] == c.root["project_id"],
              let node = read.nodes[original.body["node_key"]!.text], original.body["incarnation"] == .string(node.incarnation), node.revision >= Double(original.body["revision"]!.integer) else { throw ChildTaskFieldCommand.invalid }
        let current = Record(node.fields), changes = original.body["changes"]!.object
        var groups: [Group] = []
        for id in ["title", "description", "priority", "plan", "deadline_date", "duration_minutes", "assigned_to", "labels", "reminder_specs"] {
            let fields = original.touchedFields.filter { id == "plan" ? Self.planning.contains($0) : $0 == id }.sorted()
            guard !fields.isEmpty else { continue }
            let warning: String?
            if id == "reminder_specs", !Self.remindersMayReplace(current[id], with: changes[id] ?? .array([])) {
                warning = "Reminder data changed that this review cannot safely replace. Reopen the current task’s reminders to edit them."
            } else if id == "labels", !TeamTaskLabelsDraft(current[id]).supported {
                warning = "These current labels need their original app or a newer version before editing."
            } else { warning = nil }
            groups.append(.init(id: id, fields: fields, differs: fields.contains { field in !AuthoredValueComparison.exactJSON(.object(current.fields.filter { $0.key == field }), .object(changes.filter { $0.key == field })) }, warning: warning))
        }
        self.original = original; self.read = read; self.current = current; self.groups = groups
    }
    /// A saved whole-array edit may change known local choices, but cannot
    /// replace newer opaque rows or extensions, including nested future data.
    private static func remindersMayReplace(_ current: JSON, with desired: JSON) -> Bool {
        let before = TeamTaskRemindersDraft(current), after = TeamTaskRemindersDraft(desired)
        guard before.supported, after.supported else { return false }
        func protected(_ rows: [JSON]) -> JSON {
            .array(rows.compactMap { row in
                guard let spec = ReminderSpec(row: row), spec.locallyEditable else { return row }
                var known: Set<String> = ["version", "id", "kind", "enabled", "channels", "presentation", "schedule_version", ReminderAutomatic.placeholder]
                switch spec.kind {
                case "relative": known.formUnion(["anchor", "offset_minutes"])
                case "absolute": known.formUnion(["at", "time_zone"])
                case "recurring": known.formUnion(["start_day", "time", "time_zone", "recurrence", "holiday_policy"])
                case "interval": known.insert("interval_schedule")
                default: return row
                }
                var extras = spec.raw.filter { !known.contains($0.key) }
                func retain(_ key: String, known: Set<String>) {
                    guard let value = spec.raw[key] else { return }
                    guard case .object(let fields) = value else { extras[key] = value; return }
                    let nested = fields.filter { !known.contains($0.key) }
                    if !nested.isEmpty { extras[key] = .object(nested) }
                }
                if spec.kind == "recurring" {
                    retain("recurrence", known: ["type", "interval", "daysOfWeek", "dayOfMonth", "daysOfMonth", "monthOfYear", "weekday", "weekdayOrdinal", "count", "endDate", "fromCompletion"])
                    retain("holiday_policy", known: ["version", "year", "dates", "source", "region", "digest", "mode", "avoid_weekends", "origin"])
                    if let origin = spec.raw["holiday_policy"]?.object["origin"] {
                        let unknown: JSON?
                        if case .object(let fields) = origin {
                            let fields = fields.filter { !["provider", "country", "subdivision"].contains($0.key) }
                            unknown = fields.isEmpty ? nil : .object(fields)
                        } else { unknown = origin }
                        if let unknown {
                            var policy = extras["holiday_policy"]?.object ?? [:]
                            policy["origin"] = unknown; extras["holiday_policy"] = .object(policy)
                        }
                    }
                }
                if spec.kind == "interval" { retain("interval_schedule", known: ["start_ms", "every_minutes", "count", "until_ms"]) }
                guard !extras.isEmpty else { return nil }
                return .object(["id": spec.raw["id"]!, "extensions": .object(extras)])
            })
        }
        return AuthoredValueComparison.exactJSON(protected(before.rows), protected(after.rows))
    }
    func replacement(choosing selected: Set<String>, requestID: UUID = UUID()) throws -> ChildTaskFieldCommand? {
        guard selected.isSubset(of: Set(groups.filter { $0.differs && $0.warning == nil }.map(\.id))), requestID.uuidString.lowercased() != original.id else { throw ChildTaskFieldCommand.invalid }
        var changes: [String: JSON] = [:]
        for group in groups where selected.contains(group.id) {
            for field in group.fields { changes[field] = original.body["changes"]!.object[field] }
        }
        let removing = Set(groups.filter { selected.contains($0.id) }.flatMap(\.fields)).intersection(original.removedFields)
        guard !changes.isEmpty || !removing.isEmpty else { return nil }
        return try ChildTaskFieldCommand(read: read, key: original.body["node_key"]!.text, changes: changes, removing: removing, requestID: requestID)
    }
}
