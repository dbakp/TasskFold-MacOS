import Foundation
import CryptoKit

/// A place is private to this installation/account. Never put its raw data in a task,
/// widget payload, share capture, template, portable backup or notification content.
struct LocationPrivatePlace: Equatable, Sendable {
    let raw: [String: JSON]
    var id: String { raw["id"]!.text }
    var revision: String { raw["revision"]!.text }
    var account: String { raw["account"]!.text }
    var name: String { raw["name"]!.text }
    var latitudeE6: Int { raw["latitude_e6"]!.integer }
    var longitudeE6: Int { raw["longitude_e6"]!.integer }
    var radius: Int { raw["radius_m"]!.integer }
    var geometry: [Int] { [latitudeE6, longitudeE6, radius] }
    init?(raw: [String: JSON]) {
        guard raw["version"] == .number(1), LocationReminderIdentity.uuid(raw["id"]), LocationReminderIdentity.uuid(raw["revision"]),
              LocationReminderIdentity.account(raw["account"]?.text ?? ""),
              case .string(let name)? = raw["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              Recurrence.number(raw["latitude_e6"] ?? .null, in: -90_000_000...90_000_000) != nil,
              Recurrence.number(raw["longitude_e6"] ?? .null, in: -180_000_000...180_000_000) != nil,
              Recurrence.number(raw["radius_m"] ?? .null, in: 100...5000) != nil else { return nil }
        self.raw = raw
    }
    static func make(account: String, name: String, latitude: Double, longitude: Double, radius: Int,
                     id: String = UUID().uuidString.lowercased(), revision: String = UUID().uuidString.lowercased()) -> Self? {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return Self(raw: ["version": .number(1), "id": .string(id), "revision": .string(revision), "account": .string(account),
                          "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "latitude_e6": .number((latitude * 1_000_000).rounded()),
                          "longitude_e6": .number((longitude * 1_000_000).rounded()), "radius_m": .number(Double(radius))])
    }
    /// A rename does not change a boundary. Moving/resizing a place invalidates existing
    /// references until the user reviews and arms each affected reminder again.
    func editing(name: String, latitude: Double, longitude: Double, radius: Int, revision proposedRevision: String = UUID().uuidString.lowercased()) -> Self? {
        guard let proposed = Self.make(account: account, name: name, latitude: latitude, longitude: longitude, radius: radius, id: id, revision: proposedRevision) else { return nil }
        var fields = raw
        for (key, value) in proposed.raw { fields[key] = value }
        if proposed.geometry == geometry { fields["revision"] = .string(revision) }
        return Self(raw: fields)
    }
}

/// Proposed version 6 is deliberately NOT exposed through ReminderSpec yet. The native
/// adapter, device consent, durable private storage and save/action routing must land
/// before any app can persist or schedule these rows.
struct LocationReminderSettings: Equatable, Sendable {
    enum Transition: String, Sendable { case arrive, leave }
    let raw: [String: JSON]
    var id: String { raw["id"]!.text }
    var enabled: Bool { raw["enabled"] == .bool(true) }
    var reference: [String: JSON] { raw["location_reference"]!.object }
    var device: String { reference["device"]!.text }
    var taskID: String { reference["task_id"]!.text }
    var taskGeneration: String { reference["task_generation"]!.text }
    var placeID: String { reference["place_id"]!.text }
    var placeRevision: String { reference["place_revision"]!.text }
    var arm: String { reference["arm"]!.text }
    var transition: Transition { Transition(rawValue: reference["transition"]!.text)! }
    var semanticFields: [String] { [device, taskID, taskGeneration, placeID, placeRevision, transition.rawValue] }
    /// A fresh arm cannot create a duplicate reminder for the same boundary/transition.
    var duplicateKey: String { LocationReminderIdentity.digest(semanticFields) }
    init?(raw: [String: JSON]) {
        guard raw["version"] == .number(6), raw["kind"] == .string("location"),
              LocationReminderIdentity.uuid(raw["id"]), raw["id"] != .string(ReminderSpec.plannedID),
              raw["channels"] == .array([.string("local")]), case .bool? = raw["enabled"],
              case .object(let reference)? = raw["location_reference"], reference["version"] == .number(1),
              ["device", "task_id", "task_generation", "place_id", "place_revision", "arm"].allSatisfy({ LocationReminderIdentity.uuid(reference[$0]) }),
              Transition(rawValue: reference["transition"]?.text ?? "") != nil,
              reference["repeats"] == .bool(false) else { return nil }
        self.raw = raw
    }
    static func make(device: String, taskID: String, taskGeneration: String, place: LocationPrivatePlace,
                     transition: Transition, id: String = UUID().uuidString.lowercased(), arm: String = UUID().uuidString.lowercased(), enabled: Bool = true) -> Self? {
        Self(raw: ["version": .number(6), "id": .string(id), "kind": .string("location"), "channels": .array([.string("local")]), "enabled": .bool(enabled),
                   "location_reference": .object(["version": .number(1), "device": .string(device), "task_id": .string(taskID), "task_generation": .string(taskGeneration),
                                                  "place_id": .string(place.id), "place_revision": .string(place.revision), "arm": .string(arm), "transition": .string(transition.rawValue), "repeats": .bool(false)])])
    }
    func settingEnabled(_ enabled: Bool) -> Self {
        var fields = raw; fields["enabled"] = .bool(enabled); return Self(raw: fields)!
    }
}

enum LocationReminderIdentity {
    static func uuid(_ value: JSON?) -> Bool {
        guard case .string(let text)? = value else { return false }
        return UUID(uuidString: text)?.uuidString.lowercased() == text
    }
    static func account(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func digest(_ fields: [String]) -> String {
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct LocationReminderTicket: Codable, Equatable, Sendable {
    static let namespace = "taskfold.location."
    static let prefix = namespace + "v1."
    let account: String
    let device: String
    let taskID: String
    let generation: String
    let completionVersion: Int
    let specID: String
    let placeID: String
    let placeRevision: String
    let arm: String
    let transition: String
    var valid: Bool {
        LocationReminderIdentity.account(account) && [device, taskID, generation, specID, placeID, placeRevision, arm].allSatisfy { LocationReminderIdentity.uuid(.string($0)) } &&
        specID != ReminderSpec.plannedID && (0...9_007_199_254_740_991).contains(completionVersion) && LocationReminderSettings.Transition(rawValue: transition) != nil
    }
    var signature: String { "r9:" + LocationReminderIdentity.digest([account, device, taskID, generation, String(completionVersion), specID, placeID, placeRevision, arm, transition]) }
    var identifier: String { Self.prefix + String(signature.dropFirst(3)) }
}

struct LocationReminderCandidate: Equatable, Sendable {
    let ticket: LocationReminderTicket
    let place: LocationPrivatePlace
    let title: String
    let priority: Int
    init?(account: String, device: String, task: Record, settings: LocationReminderSettings, place: LocationPrivatePlace) {
        guard LocationReminderIdentity.account(account), settings.enabled, !task.completed,
              task.id == settings.taskID, task.string("task_generation") == settings.taskGeneration,
              device == settings.device, place.account == account, place.id == settings.placeID, place.revision == settings.placeRevision else { return nil }
        let completion: Int
        if task["completion_version"] == .null { completion = 0 }
        else { guard let value = Recurrence.number(task["completion_version"], in: 0...9_007_199_254_740_991) else { return nil }; completion = value }
        let ticket = LocationReminderTicket(account: account, device: device, taskID: task.id, generation: settings.taskGeneration, completionVersion: completion,
                                            specID: settings.id, placeID: place.id, placeRevision: place.revision, arm: settings.arm, transition: settings.transition.rawValue)
        guard ticket.valid else { return nil }
        self.ticket = ticket; self.place = place; title = task.title; priority = task.priority
    }
    /// Coordinates and a private place's label never enter notification content/receipts.
    var receipt: Data? { try? JSONEncoder().encode(ticket) }
    /// Local-only comparison also catches two differently named saved pins at the
    /// same boundary. This geometry-derived key is never serialized into a receipt.
    var boundaryKey: String { LocationReminderIdentity.digest([ticket.device, ticket.taskID, ticket.generation, ticket.transition] + place.geometry.map(String.init)) }
    func matches(_ observed: LocationReminderCandidate) -> Bool { ticket == observed.ticket && place.geometry == observed.place.geometry }
}

struct LocationReminderPlan: Sendable {
    static let maximumRegions = 20 // App limit, not a promise of OS acceptance.
    let eligible: [LocationReminderCandidate]
    let capacity: Int
    let allowSubmissions: Bool
    var candidates: [LocationReminderCandidate] { Array(eligible.prefix(capacity)) }
    var deferred: Int { max(0, eligible.count - capacity) }
    static var empty: Self { Self(eligible: [], capacity: 0, allowSubmissions: false) }
    private init(eligible: [LocationReminderCandidate], capacity: Int, allowSubmissions: Bool) {
        self.eligible = eligible; self.capacity = capacity; self.allowSubmissions = allowSubmissions
    }
    func scoped(to account: String) -> Self {
        guard LocationReminderIdentity.account(account) else { return .empty }
        return Self(eligible: eligible.filter { $0.ticket.account == account }, capacity: capacity, allowSubmissions: allowSubmissions)
    }
    func limited(to slots: Int, submissions: Bool) -> Self {
        Self(eligible: eligible, capacity: min(capacity, max(0, slots)), allowSubmissions: allowSubmissions && submissions)
    }
    init(account: String, device: String, tasks: [Record], places: [LocationPrivatePlace], availableNotificationSlots: Int, allowed: Bool, allowSubmissions: Bool = true) {
        self.allowSubmissions = allowSubmissions
        guard allowed, LocationReminderIdentity.account(account), LocationReminderIdentity.uuid(.string(device)) else { eligible = []; capacity = 0; return }
        let duplicateTasks = Set(Dictionary(grouping: tasks, by: { $0.id.lowercased() }).filter { $0.value.count != 1 }.keys)
        let duplicatePlaces = Set(Dictionary(grouping: places.filter { $0.account == account }, by: \.id).filter { $0.value.count != 1 }.keys)
        var result: [LocationReminderCandidate] = []
        for task in tasks where !duplicateTasks.contains(task.id.lowercased()) {
            let rows = ReminderSpec.rows(task)
            guard rows.count <= ReminderSpec.maximum else { continue }
            let duplicated = Set(Dictionary(grouping: rows, by: { $0.object["id"]?.text.lowercased() ?? "" }).filter { $0.value.count != 1 }.keys)
            var semantics = Set<String>()
            for row in rows {
                guard let settings = LocationReminderSettings(raw: row.object), !duplicated.contains(settings.id),
                      !duplicatePlaces.contains(settings.placeID), let place = places.first(where: { $0.account == account && $0.id == settings.placeID }),
                      let candidate = LocationReminderCandidate(account: account, device: device, task: task, settings: settings, place: place),
                      semantics.insert(candidate.boundaryKey).inserted else { continue }
                result.append(candidate)
            }
        }
        result.sort { $0.priority == $1.priority ? $0.ticket.identifier < $1.ticket.identifier : $0.priority < $1.priority }
        let cap = min(Self.maximumRegions, max(0, availableNotificationSlots))
        eligible = result; capacity = cap
    }
}

struct LocationReminderJournal: Codable, Equatable, Sendable {
    static let maximumEntries = 2048
    enum Phase: String, Codable, Sendable { case prepared, reserved, installed, closed }
    enum Closure: String, Codable, Sendable { case noLongerPending, delivered, cancelled, failed, ambiguous, untracked }
    struct Entry: Codable, Equatable, Sendable {
        let ticket: LocationReminderTicket
        var phase: Phase
        var reason: Closure?
        var valid: Bool { ticket.valid && ((phase == .closed) == (reason != nil)) }
    }
    var version = 1
    let device: String
    var entries: [String: Entry] = [:]
    /// Explicit retirement revokes even an already-delivered receipt without
    /// rewriting its immutable closed entry. No visit timestamps are collected.
    var revoked: [String]? = nil
    var valid: Bool {
        (version == 1 && revoked == nil || version == 2 && revoked != nil) &&
        (revoked.map { $0.count <= Self.maximumEntries && Set($0).count == $0.count && $0.allSatisfy { entries[$0]?.phase == .closed } } ?? true) &&
        LocationReminderIdentity.uuid(.string(device)) && entries.count <= Self.maximumEntries &&
        entries.allSatisfy { $0.key == $0.value.ticket.identifier && $0.value.ticket.device == device && $0.value.valid }
    }
    /// Only an explicit setup action may create a fresh arm intent. Merely receiving
    /// a synced/backup row must never create one, even on an otherwise matching device.
    mutating func prepare(_ ticket: LocationReminderTicket) -> Bool {
        guard valid, ticket.valid, ticket.device == device, entries[ticket.identifier] == nil,
              entries.count < Self.maximumEntries else { return false }
        entries[ticket.identifier] = .init(ticket: ticket, phase: .prepared, reason: nil)
        return true
    }
    /// This validates a genuine OS response against current accessible task/place state.
    /// Native response routing still has to prove its origin and fence async actions.
    func permitsResponse(_ ticket: LocationReminderTicket, eligible: [LocationReminderCandidate]) -> Bool {
        guard valid, ticket.device == device, revoked?.contains(ticket.identifier) != true, let entry = entries[ticket.identifier], entry.ticket == ticket,
              eligible.contains(where: { $0.ticket == ticket }) else { return false }
        guard entry.phase != .prepared else { return false }
        return entry.phase != .closed || [.delivered, .noLongerPending, .ambiguous].contains(entry.reason)
    }
}

struct LocationReminderObservation: Sendable {
    var pending: [LocationReminderCandidate]
    var delivered: Set<String> = []
    var unrecognized: Set<String> = []
}
protocol LocationReminderCenter: Sendable {
    func observe() async throws -> LocationReminderObservation
    func remove(_ identifiers: [String]) async
    /// Must remove only this feature's versioned namespace, including undecodable entries.
    func removeAllOwned() async
    func add(_ candidate: LocationReminderCandidate) async throws
}
struct LocationReminderReport: Equatable, Sendable {
    var installed = 0
    var closed = 0
    var failed = 0
    var deferred = 0
    var unreadable = false
}

/// Reserve durably BEFORE touching the OS. A missing request after submission is never
/// silently recreated: dismissal, crash, permission loss and delivery can look alike.
/// A deliberate new arm nonce is the only way to create another one-shot opportunity.
actor LocationReminderEngine {
    nonisolated let deviceIdentity: String?
    private let center: any LocationReminderCenter
    private let persist: @Sendable (LocationReminderJournal) async throws -> Void
    private var journal: LocationReminderJournal?
    private var desired: [LocationReminderCandidate] = []
    private var capacity = 0
    private var hasDesired = false
    private var allowSubmissions = false
    private var permitsSubmission: @Sendable (LocationReminderCandidate) async -> Bool = { _ in true }
    private var preparations: [(LocationReminderTicket, CheckedContinuation<Bool, Never>)] = []
    private var retirements: [([LocationReminderTicket], CheckedContinuation<Bool, Never>)] = []
    private var blockedTickets = Set<String>()
    private var sequence: UInt64 = 0
    private var running = false
    private var waiters: [CheckedContinuation<LocationReminderReport, Never>] = []
    init(journal: LocationReminderJournal?, center: any LocationReminderCenter, persist: @escaping @Sendable (LocationReminderJournal) async throws -> Void) {
        self.journal = journal?.valid == true ? journal : nil; deviceIdentity = self.journal?.device; self.center = center; self.persist = persist
    }
    func snapshot() -> LocationReminderJournal? { journal }
    func intentRevision() -> UInt64 { sequence }
    func prepare(_ ticket: LocationReminderTicket) async -> Bool {
        guard preparations.count < 50, !blockedTickets.contains(ticket.identifier) else { return false }
        return await withCheckedContinuation { continuation in
            preparations.append((ticket, continuation))
            if !running { running = true; Task { await self.drain() } }
        }
    }
    /// Serialized with reservations/acknowledgements, including never-submitted
    /// preparations. Undo/removal must not leave an intent that Redo can rearm.
    func retire(_ tickets: [LocationReminderTicket]) async -> Bool {
        guard tickets.count <= LocationReminderJournal.maximumEntries, retirements.count < 50 else { return false }
        let owned = tickets.filter { $0.valid && $0.device == deviceIdentity }
        let blocked = blockedTickets.union(owned.map(\.identifier))
        guard blocked.count <= LocationReminderJournal.maximumEntries else { return false }
        blockedTickets = blocked; sequence &+= 1
        return await withCheckedContinuation { continuation in
            retirements.append((tickets, continuation))
            if !running { running = true; Task { await self.drain() } }
        }
    }
    func reservations(for plan: LocationReminderPlan) -> [LocationReminderCandidate] {
        Array(plan.eligible.filter { candidate in
            guard let entry = journal?.entries[candidate.ticket.identifier], entry.ticket == candidate.ticket else { return false }
            return entry.phase != .closed && !blockedTickets.contains(candidate.ticket.identifier)
        }.prefix(plan.capacity))
    }
    func update(_ plan: LocationReminderPlan, permitsSubmission: @escaping @Sendable (LocationReminderCandidate) async -> Bool = { _ in true }) async -> LocationReminderReport {
        self.permitsSubmission = permitsSubmission
        hasDesired = true; desired = plan.eligible; capacity = plan.capacity; allowSubmissions = plan.allowSubmissions; sequence &+= 1
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if !running { running = true; Task { await self.drain() } }
        }
    }
    private func maySubmit(_ candidate: LocationReminderCandidate, token: UInt64) async -> Bool {
        guard token == sequence else { return false }
        let validator = permitsSubmission
        let allowed = await validator(candidate)
        return token == sequence && allowed
    }
    private func save(_ changed: LocationReminderJournal) async -> Bool {
        guard changed.valid else { return false }
        do { try await persist(changed); journal = changed; return true } catch { return false }
    }
    private func close(_ identifier: String, reason: LocationReminderJournal.Closure) async -> Bool {
        guard var state = journal, var entry = state.entries[identifier] else { return false }
        entry.phase = .closed; entry.reason = reason; state.entries[identifier] = entry
        return await save(state)
    }
    private func drain() async {
        while true {
            if !retirements.isEmpty {
                let requests = retirements; retirements = []
                for (tickets, continuation) in requests {
                    guard var state = journal else { continuation.resume(returning: false); continue }
                    var changed = false
                    let matching = tickets.filter { $0.valid && $0.device == state.device && (state.entries[$0.identifier] == nil || state.entries[$0.identifier]?.ticket == $0) }
                    let missing = Dictionary(grouping: matching.filter { state.entries[$0.identifier] == nil }, by: \.identifier)
                    guard state.entries.count + missing.count <= LocationReminderJournal.maximumEntries else { continuation.resume(returning: false); continue }
                    // Retire before prepare is a real race. Persist a cancelled tombstone
                    // even if the reviewed save has not reached journal preparation yet.
                    for ticket in matching where state.entries[ticket.identifier] == nil {
                        state.entries[ticket.identifier] = .init(ticket: ticket, phase: .closed, reason: .cancelled); changed = true
                    }
                    var revoked = Set(state.revoked ?? [])
                    for ticket in matching {
                        if revoked.insert(ticket.identifier).inserted { changed = true }
                        if state.entries[ticket.identifier]?.phase != .closed {
                            state.entries[ticket.identifier]?.phase = .closed; state.entries[ticket.identifier]?.reason = .cancelled; changed = true
                        }
                    }
                    if changed { state.version = 2; state.revoked = revoked.sorted() }
                    let saved = changed ? await save(state) : true
                    if saved { blockedTickets.subtract(matching.map(\.identifier)) }
                    await center.remove(matching.map(\.identifier))
                    continuation.resume(returning: saved)
                }
                continue
            }
            if !preparations.isEmpty {
                let requests = preparations; preparations = []
                for (ticket, continuation) in requests {
                    guard !blockedTickets.contains(ticket.identifier), var state = journal, state.prepare(ticket) else { continuation.resume(returning: false); continue }
                    let saved = await save(state); continuation.resume(returning: saved)
                }
                continue
            }
            if !hasDesired {
                if finish(LocationReminderReport()) { return }; continue
            }
            let token = sequence
            let available = desired.filter { candidate in
                guard let entry = journal?.entries[candidate.ticket.identifier], entry.ticket == candidate.ticket else { return false }
                return entry.phase != .closed && !blockedTickets.contains(candidate.ticket.identifier)
            }
            let targets = Array(available.prefix(capacity))
            var report = LocationReminderReport(failed: journal.map { state in desired.filter { state.entries[$0.ticket.identifier]?.ticket != $0.ticket }.count } ?? 0, deferred: max(0, available.count - targets.count))
            guard let state = journal else {
                await center.removeAllOwned()
                guard token == sequence else { continue }
                report.unreadable = true; if finish(report) { return }; continue
            }
            let observation: LocationReminderObservation
            do { observation = try await center.observe() }
            catch {
                await center.removeAllOwned()
                // Journal entries stay reserved/installed, so later absence closes them;
                // a recovery must not create another opportunity with the same nonce.
                guard token == sequence else { continue }
                report.failed = max(1, targets.count); if finish(report) { return }; continue
            }
            guard token == sequence else { continue }
            let targetIDs = Set(targets.map { $0.ticket.identifier })
            let unexpected = observation.pending.filter { !targetIDs.contains($0.ticket.identifier) }.map { $0.ticket.identifier } + observation.unrecognized.filter { $0.hasPrefix(LocationReminderTicket.namespace) }
            await center.remove(unexpected)
            guard token == sequence else { continue }
            for (identifier, entry) in state.entries where entry.phase != .closed && entry.phase != .prepared && !targetIDs.contains(identifier) {
                if await close(identifier, reason: .cancelled) { report.closed += 1 } else { report.failed += 1 }
                if token != sequence { break }
            }
            guard token == sequence else { continue }
            for candidate in targets {
                let id = candidate.ticket.identifier
                guard candidate.ticket.device == journal?.device else { report.failed += 1; continue }
                let matches = observation.pending.filter { $0.ticket.identifier == id }
                if let entry = journal?.entries[id], entry.phase != .prepared {
                    if entry.phase == .closed {
                        await center.remove([id]); report.closed += 1
                    } else if matches.count == 1, candidate.matches(matches[0]), !observation.delivered.contains(id) {
                        if entry.phase == .reserved {
                            var next = journal!; next.entries[id]?.phase = .installed
                            if !(await save(next)) { report.failed += 1 }
                        }
                        report.installed += 1
                    } else {
                        await center.remove([id])
                        let reason: LocationReminderJournal.Closure = observation.delivered.contains(id) ? .delivered : (matches.isEmpty ? (entry.phase == .reserved ? .ambiguous : .noLongerPending) : .failed)
                        if await close(id, reason: reason) { report.closed += 1 } else { report.failed += 1 }
                    }
                } else if journal?.entries[id] == nil {
                    // No durable explicit intent: a restored/synced row cannot arm itself.
                    await center.remove([id]); report.failed += 1
                } else if !matches.isEmpty || observation.delivered.contains(id) {
                    // A prepared intent has never been submitted. Do not trust a request
                    // that somehow appeared without the durable submission reservation.
                    await center.remove([id]); _ = await close(id, reason: .untracked); report.failed += 1
                } else {
                    guard allowSubmissions else { report.deferred += 1; continue }
                    guard await maySubmit(candidate, token: token) else {
                        if token != sequence { break }; report.deferred += 1; continue
                    }
                    var next = journal!; next.entries[id]?.phase = .reserved
                    guard await save(next) else { report.failed += 1; continue }
                    guard token == sequence else { break }
                    guard await maySubmit(candidate, token: token) else {
                        _ = await close(id, reason: .cancelled)
                        if token != sequence { break }; continue
                    }
                    do {
                        try await center.add(candidate)
                        let permitted = await maySubmit(candidate, token: token)
                        if !permitted {
                            await center.remove([id]); _ = await close(id, reason: .cancelled); break
                        }
                        next = journal!; next.entries[id]?.phase = .installed
                        if await save(next) { report.installed += 1 } else { report.failed += 1 }
                    } catch {
                        await center.remove([id]); _ = await close(id, reason: .failed); report.failed += 1
                    }
                }
                if token != sequence { break }
            }
            guard token == sequence else { continue }
            // A consumed one-shot must not occupy a slot ahead of waiting reminders.
            let selected = desired.filter { candidate in
                guard let entry = journal?.entries[candidate.ticket.identifier], entry.ticket == candidate.ticket else { return false }
                return entry.phase != .closed && !blockedTickets.contains(candidate.ticket.identifier)
            }.prefix(capacity).map { $0.ticket.identifier }
            if Array(selected) != targets.map({ $0.ticket.identifier }) { continue }
            if finish(report) { return }
        }
    }
    @discardableResult private func finish(_ report: LocationReminderReport) -> Bool {
        guard preparations.isEmpty, retirements.isEmpty else { return false }
        var report = report
        let retired = desired.compactMap { journal?.entries[$0.ticket.identifier] }.filter { $0.phase == .closed }
        report.closed = retired.count
        report.failed = max(report.failed, retired.filter { [.failed, .untracked, .ambiguous].contains($0.reason) }.count)
        let callbacks = waiters; waiters = []; running = false
        for callback in callbacks { callback.resume(returning: report) }
        return true
    }
}

/// A reviewed editor proposal is memory-only. It is not an armed journal entry,
/// and its private pin is never copied into a task or portable export.
struct LocationReminderReview: Sendable {
    let workspace: WorkspaceBinding
    let place: LocationPrivatePlace
    let settings: LocationReminderSettings
    let originalRows: [JSON]
    let replacing: String?
    let completion: JSON
    init?(workspace: WorkspaceBinding, task: Record, archive: LocationPrivateArchive, place: LocationPrivatePlace,
          transition: LocationReminderSettings.Transition, replacing: LocationReminderSettings? = nil) {
        guard archive.valid, place.account == workspace.account, archive.places(for: workspace.account).contains(where: { $0 == place }),
              !task.completed, LocationReminderIdentity.uuid(task["task_generation"]),
              replacing == nil || ReminderSpec.rows(task).contains(.object(replacing!.raw)),
              let created = LocationReminderSettings.make(device: archive.device, taskID: task.id, taskGeneration: task.string("task_generation"), place: place, transition: transition, id: replacing?.id ?? UUID().uuidString.lowercased()) else { return nil }
        var fields = replacing?.raw ?? [:]
        for (key, value) in created.raw {
            if key == "location_reference" { fields[key] = .object((fields[key]?.object ?? [:]).merging(value.object) { _, fresh in fresh }) }
            else { fields[key] = value }
        }
        guard let settings = LocationReminderSettings(raw: fields) else { return nil }
        self.workspace = workspace; self.place = place; self.settings = settings
        originalRows = ReminderSpec.rows(task); self.replacing = replacing?.id; completion = task["completion_version"]
    }
    func valid(task: Record, archive: LocationPrivateArchive, workspace: WorkspaceBinding) -> Bool {
        self.workspace == workspace && archive.valid && archive.device == settings.device &&
        task.id == settings.taskID && task.string("task_generation") == settings.taskGeneration && !task.completed && task["completion_version"] == completion &&
        archive.places(for: workspace.account).contains { $0.id == place.id && $0.revision == place.revision && $0.geometry == place.geometry }
    }
    func applying(to task: Record, archive: LocationPrivateArchive, workspace: WorkspaceBinding) -> Record? {
        guard valid(task: task, archive: archive, workspace: workspace), ReminderSpec.rows(task) == originalRows else { return nil }
        var rows = originalRows
        if let replacing {
            guard let index = rows.firstIndex(where: { $0.object["id"]?.text == replacing }) else { return nil }
            rows[index] = .object(settings.raw)
        } else {
            if rows.isEmpty { rows = [ReminderAutomatic.legacyPlaceholder] }
            guard rows.count < ReminderSpec.maximum else { return nil }
            rows.append(.object(settings.raw))
        }
        let known = rows.compactMap { LocationReminderSettings(raw: $0.object) }.filter(\.enabled)
        let identities = rows.compactMap { $0.object["id"]?.text.lowercased() }.filter { !$0.isEmpty }
        guard Set(identities).count == identities.count, Set(known.map(\.duplicateKey)).count == known.count else { return nil }
        for other in known where other.id != settings.id && other.device == settings.device && other.taskID == settings.taskID && other.taskGeneration == settings.taskGeneration && other.transition == settings.transition {
            if let boundary = archive.places(for: workspace.account).first(where: { $0.id == other.placeID && $0.revision == other.placeRevision }), boundary.geometry == place.geometry { return nil }
        }
        var result = task; result["reminder_specs"] = .array(rows); return result
    }
    func permitsSaved(_ task: Record, archive: LocationPrivateArchive, workspace: WorkspaceBinding) -> Bool {
        valid(task: task, archive: archive, workspace: workspace) && ReminderSpec.rows(task).count <= ReminderSpec.maximum &&
        ReminderSpec.rows(task).contains(.object(settings.raw))
    }
}

extension LocationReminderTicket {
    static func bound(account: String, task: Record, settings: LocationReminderSettings) -> Self? {
        guard task.id == settings.taskID, task.string("task_generation") == settings.taskGeneration else { return nil }
        let completion: Int
        if task["completion_version"] == .null { completion = 0 }
        else { guard let number = Recurrence.number(task["completion_version"], in: 0...9_007_199_254_740_991) else { return nil }; completion = number }
        let ticket = Self(account: account, device: settings.device, taskID: task.id, generation: settings.taskGeneration, completionVersion: completion, specID: settings.id, placeID: settings.placeID, placeRevision: settings.placeRevision, arm: settings.arm, transition: settings.transition.rawValue)
        return ticket.valid ? ticket : nil
    }
    static func retired(account: String, before: Record, after: Record?) -> [Self] {
        let kept = (after?.completed == false ? after : nil).map { task in ReminderSpec.rows(task).compactMap { LocationReminderSettings(raw: $0.object) }.filter(\.enabled).compactMap { bound(account: account, task: task, settings: $0) } } ?? []
        return ReminderSpec.rows(before).compactMap { LocationReminderSettings(raw: $0.object) }.compactMap { bound(account: account, task: before, settings: $0) }.filter { !kept.contains($0) }
    }
}

/// Cancellation-only intent, saved atomically with the task snapshot. It cannot
/// prepare or authorize a notification and contains no place name or geometry.
/// Keep acknowledged jobs until their removal is itself durably saved; replaying
/// retirement after a crash is idempotent, including an already-closed receipt.
enum LocationRetirementOutbox {
    static func valid(_ jobs: [String: LocationReminderTicket]) -> Bool {
        jobs.count <= LocationReminderJournal.maximumEntries && jobs.allSatisfy { $0.key == $0.value.identifier && $0.value.valid }
    }
    static func staging(previous: Snapshot, proposed: Snapshot, account: String, acknowledged: [LocationReminderTicket] = []) throws -> Snapshot {
        var jobs = previous.locationRetirements ?? [:]
        guard valid(jobs), valid(proposed.locationRetirements ?? [:]) else { throw LocationStorageFailure.unreadable }
        for (id, ticket) in proposed.locationRetirements ?? [:] {
            guard jobs[id] == nil || jobs[id] == ticket else { throw LocationStorageFailure.changed }
            jobs[id] = ticket
        }
        if previous.tables["tasks"] != proposed.tables["tasks"] {
            let after = Dictionary(grouping: proposed.tables["tasks"] ?? [], by: \.id)
            for before in previous.tables["tasks"] ?? [] {
                // Duplicate task IDs cannot certify that an old intent is still current.
                let current = after[before.id].flatMap { $0.count == 1 ? $0.first : nil }
                if current == before { continue }
                for ticket in LocationReminderTicket.retired(account: account, before: before, after: current) {
                    guard jobs[ticket.identifier] == nil || jobs[ticket.identifier] == ticket else { throw LocationStorageFailure.changed }
                    jobs[ticket.identifier] = ticket
                }
            }
        }
        for ticket in acknowledged where jobs[ticket.identifier] == ticket { jobs[ticket.identifier] = nil }
        guard valid(jobs) else { throw LocationStorageFailure(message: "Finish stopping old location reminders before changing more of them. Your task change has not been saved.") }
        var next = proposed; next.locationRetirements = jobs.isEmpty ? nil : jobs
        return next
    }
}
