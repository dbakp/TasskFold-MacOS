import Foundation
import CryptoKit
import Observation

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
    init(read:ChildTaskRecordRead,key:String,changes:[String:JSON],requestID:UUID=UUID()) throws {
        guard let node=read.nodes[key],TaskKind(Record(node.fields)) != .unsupported,
              TaskKind.permits(Mutation(table:"tasks",recordID:node.fields["id"]!.text,method:"PATCH",fields:changes),existing:Record(node.fields)) else {throw Self.invalid}
        try self.init(account:read.context.account,origin:read.context.origin,body:["protocol":.number(1),"account":.string(read.context.account),"request_id":.string(requestID.uuidString.lowercased()),"task_id":.string(read.context.root.id),"task_generation":read.context.root["task_generation"],"project_id":read.context.root["project_id"],"node_key":.string(node.key),"incarnation":.string(node.incarnation),"revision":.number(node.revision),"changes":.object(changes)])
    }
    init(account:String,origin:String,body:[String:JSON]) throws {
        try TeamOrganizationValue.scope(account:account,origin:origin)
        guard origin.utf8.count<=2048,Set(body.keys)==["protocol","account","request_id","task_id","task_generation","project_id","node_key","incarnation","revision","changes"],body["protocol"] == .number(1),body["account"] == .string(account) else {throw Self.invalid}
        for key in ["request_id","task_id","incarnation"] {_=try TeamOrganizationValue.id(body[key])}
        _=try TeamProjectValue.optionalID(body["task_generation"]);_=try TeamProjectValue.optionalID(body["project_id"])
        let rev=try TeamProjectValue.revision(body["revision"])
        guard rev<9_007_199_254_740_991,case .string(let key)?=body["node_key"],!key.isEmpty,key.utf8.count<=128,key.utf8.elementsEqual(key.precomposedStringWithCanonicalMapping.utf8),
              case .object(let changes)?=body["changes"],!changes.isEmpty,Set(changes.keys).isSubset(of:Self.fields) else {throw Self.invalid}
        for (key,value) in changes {try Self.validate(key,value)}
        // Pretty output is conservative relative to PostgreSQL's spaced JSONB
        // envelope and avoids compact-JSON boundary surprises.
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
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
        guard Set(raw.keys)==["protocol","account","request_id","task_id","task_generation","project_id","node_key","incarnation","revision","replayed"],raw["protocol"] == .number(1),raw["account"] == .string(account),
              ["request_id","task_id","task_generation","project_id","node_key","incarnation"].allSatisfy({raw[$0]==body[$0]}),case .bool?=raw["replayed"],
              try TeamProjectValue.revision(raw["revision"])>=TeamProjectValue.revision(body["revision"]) else {throw Self.invalid}
        return ChildTaskFieldReceipt(raw:raw)
    }
    fileprivate static func validate(_ key:String,_ value:JSON) throws {
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
struct ChildTaskFieldReceipt:Equatable,Sendable,Codable {let raw:[String:JSON]}
struct ChildTaskFieldJournalState:ReviewedTeamFileCommand,CustomStringConvertible,CustomDebugStringConvertible {
    enum Phase:String,Codable,Sendable {case queued,attempted,confirmed}
    struct Entry:Codable,Sendable {let command:ChildTaskFieldCommand;var phase:Phase;var receipt:ChildTaskFieldReceipt?}
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
        for row in entries {
            guard row.command.account==account,row.command.origin==origin,ids.insert(row.command.id).inserted else {throw Self.invalid}
            if row.phase == .confirmed {guard let receipt=row.receipt,try row.command.confirmed(receipt.raw)==receipt else {throw Self.invalid}}
            else {guard row.receipt==nil else {throw Self.invalid}}
        }
        self.account=account;self.origin=origin;self.entries=entries
    }
    static func ==(a:Self,b:Self)->Bool {
        a.account==b.account && a.origin==b.origin && a.entries.count==b.entries.count && zip(a.entries,b.entries).allSatisfy{$0.command==$1.command && $0.phase==$1.phase && $0.receipt==$1.receipt}
    }
    private enum CodingKeys:String,CodingKey {case version,account,origin,entries}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self);guard try c.decode(Int.self,forKey:.version)==1 else {throw Self.invalid}
        try self.init(account:c.decode(String.self,forKey:.account),origin:c.decode(String.self,forKey:.origin),entries:c.decode([Entry].self,forKey:.entries))
    }
    func encode(to encoder:Encoder) throws {var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(1,forKey:.version);try c.encode(account,forKey:.account);try c.encode(origin,forKey:.origin);try c.encode(entries,forKey:.entries)}
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
    private let io:any CalendarSecureItemIO
    private let lock:AutomationEnrollmentProcessLock
    private let removalDirectory:URL
    let account:String,origin:String
    private var key:String {ChildTaskFieldJournalState.storagePrefix+account+"."+CalendarOAuthConfiguration.digest(origin)}
    init(account:String,origin:String,io:any CalendarSecureItemIO,coordinationDirectory:URL,removalDirectory:URL) throws {
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
        let state=try JSONDecoder().decode(ChildTaskFieldJournalState.self,from:data)
        guard state.account==account,state.origin==origin else {throw ChildTaskFieldCommand.invalid};return state
    }
    private func write(_ state:ChildTaskFieldJournalState,lease:CalendarReadLease) throws {
        _=try ChildTaskFieldJournalState(account:account,origin:origin,entries:state.entries)
        let data=try JSONEncoder().encode(state);guard data.count<=ChildTaskFieldJournalState.maximumStoredBytes else {throw ChildTaskFieldCommand.invalid}
        try lease.check();try io.write(data,key:key)
    }
    func load() throws -> ChildTaskFieldJournalState {try guarded(lease:nil){try read()}}
    /// Coalesce only provably unsent intents for the same captured revision.
    /// Once attempted, both body and request identity remain immutable.
    func enqueue(_ command:ChildTaskFieldCommand,lease:CalendarReadLease) throws -> ChildTaskFieldCommand {
        try guarded(lease:lease) {
            guard command.account==account,command.origin==origin else {throw ChildTaskFieldCommand.invalid};var state=try read()
            if let old=state.entries.first(where:{$0.command.id==command.id}) {guard old.command==command else {throw ChildTaskFieldCommand.invalid};return old.command}
            if let index=state.entries.lastIndex(where:{$0.phase == .queued && $0.command.sameTarget(command) && $0.command.body["revision"]==command.body["revision"]}) {
                let old=state.entries[index].command;var body=old.body;body["changes"] = .object(old.body["changes"]!.object.merging(command.body["changes"]!.object){_,new in new})
                let merged=try ChildTaskFieldCommand(account:account,origin:origin,body:body);state.entries[index] = .init(command:merged,phase:.queued,receipt:nil)
                try write(state,lease:lease);return merged
            }
            guard state.entries.count<64 else {throw ChildTaskFieldCommand.invalid}
            state.entries.append(.init(command:command,phase:.queued,receipt:nil));try write(state,lease:lease);return command
        }
    }
    func attempt(_ reviewed:ChildTaskFieldCommand,lease:CalendarReadLease) throws -> ChildTaskFieldJournalState.Entry {
        try guarded(lease:lease) {
            var state=try read();guard let index=state.entries.firstIndex(where:{$0.command.id==reviewed.id}),state.entries[index].command==reviewed else {throw ChildTaskFieldCommand.invalid}
            guard !state.entries[..<index].contains(where:{$0.phase != .confirmed && $0.command.sameTarget(reviewed)}) else {throw ChildTaskFieldCommand.invalid}
            if state.entries[index].phase == .queued {state.entries[index].phase = .attempted;try write(state,lease:lease)}
            return state.entries[index]
        }
    }
    func confirm(_ command:ChildTaskFieldCommand,receipt:ChildTaskFieldReceipt,lease:CalendarReadLease) throws {
        try guarded(lease:lease) {
            guard try command.confirmed(receipt.raw)==receipt else {throw ChildTaskFieldCommand.invalid};var state=try read()
            guard let index=state.entries.firstIndex(where:{$0.command.id==command.id}),state.entries[index].command==command,state.entries[index].phase != .queued else {throw ChildTaskFieldCommand.invalid}
            if let old=state.entries[index].receipt {
                guard AuthoredValueComparison.exactJSON(.object(old.raw.filter{$0.key != "replayed"}),.object(receipt.raw.filter{$0.key != "replayed"})) else {throw ChildTaskFieldCommand.invalid};return
            }
            state.entries[index].phase = .confirmed;state.entries[index].receipt=receipt;try write(state,lease:lease)
        }
    }
    /// Explicitly discarding an uncertain request never cancels service work.
    func discard(_ reviewed:ChildTaskFieldCommand,allowUnconfirmed:Bool=false,lease:CalendarReadLease) throws {
        try guarded(lease:lease) {
            var state=try read();guard let index=state.entries.firstIndex(where:{$0.command.id==reviewed.id}),state.entries[index].command==reviewed else {throw ChildTaskFieldCommand.invalid}
            guard state.entries[index].phase != .attempted || allowUnconfirmed else {throw ChildTaskFieldCommand.invalid}
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
    enum Reason {case unavailable,review,busy,limit,unconfirmed}
    let reason:Reason
    var errorDescription:String? {
        switch reason {
        case .unavailable:return "Child editing is unavailable or access changed. Your saved request is kept."
        case .review:return "This child change needs review. Your original saved request is kept."
        case .busy:return "Another change is finishing. Retry the same saved request shortly."
        case .limit:return "This change has reached a service limit. Your saved request is kept."
        case .unconfirmed:return "The result couldn’t be confirmed. Your original saved request is kept."
        }
    }
}
@MainActor protocol ChildTaskFieldCommandService:AnyObject {func childTaskFieldCommand(_ command:ChildTaskFieldCommand,session:UUID) async throws -> ChildTaskFieldReceipt}
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
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskFieldJournal, service: any ChildTaskFieldCommandService,
         current: @escaping () -> ChildTaskFieldClientScope?, canQueue: @escaping (ChildTaskFieldCommand) -> Bool,
         canSend: @escaping (ChildTaskFieldCommand) -> Bool, refresh: @escaping () async -> Void) {
        self.scope = scope; self.journal = journal; self.current = current; self.canQueue = canQueue; self.refresh = refresh
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
    /// Save first, send only through a separate explicit action. Offline edits
    /// therefore do not become transient optimistic task-cache writes.
    @discardableResult func save(_ command: ChildTaskFieldCommand) async -> ChildTaskFieldCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin, canQueue(command) else { throw ChildTaskFieldWriteFailure(reason: .unavailable) }
            let saved = try await journal.enqueue(command, lease: lease); try check(); try await update()
            message = "Saved on this device. Review the request when you’re ready to send."; return saved
        } catch { failure(error); return nil }
    }
    func send(_ reviewed: ChildTaskFieldCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try check(); _ = try await sender.send(reviewed); try check(); try await update()
            message = "Change confirmed. Refreshing current tasks…"
            await refresh(); try check()
            message = "Change confirmed. The saved request is kept until you remove it."
        } catch {
            // A failed response/save may have left durable attempted state.
            // Re-read before offering controls; never show the old queued phase.
            do { try check(); try await update() } catch { loaded = false; entries = [] }
            failure(error)
        }
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
