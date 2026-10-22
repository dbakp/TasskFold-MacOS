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

/// Private references remain opaque to ReminderSpec. Version 6/reference 1 is
/// one-shot; version 7/reference 2 explicitly requests every visit. Public authoring
/// remains gated pending the remaining native/setup acceptance.
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
    var repeats: Bool { reference["repeats"] == .bool(true) }
    var semanticFields: [String] { [device, taskID, taskGeneration, placeID, placeRevision, transition.rawValue] }
    /// A fresh arm cannot create a duplicate reminder for the same boundary/transition.
    var duplicateKey: String { LocationReminderIdentity.digest(semanticFields) }
    init?(raw: [String: JSON]) {
        guard raw["kind"] == .string("location"),
              LocationReminderIdentity.uuid(raw["id"]), raw["id"] != .string(ReminderSpec.plannedID),
              raw["channels"] == .array([.string("local")]), case .bool? = raw["enabled"],
              case .object(let reference)? = raw["location_reference"],
              ["device", "task_id", "task_generation", "place_id", "place_revision", "arm"].allSatisfy({ LocationReminderIdentity.uuid(reference[$0]) }),
              Transition(rawValue: reference["transition"]?.text ?? "") != nil,
              (raw["version"] == .number(6) && reference["version"] == .number(1) && reference["repeats"] == .bool(false) ||
               raw["version"] == .number(7) && reference["version"] == .number(2) && reference["repeats"] == .bool(true)) else { return nil }
        self.raw = raw
    }
    static func make(device: String, taskID: String, taskGeneration: String, place: LocationPrivatePlace,
                     transition: Transition, repeats: Bool = false, id: String = UUID().uuidString.lowercased(), arm: String = UUID().uuidString.lowercased(), enabled: Bool = true) -> Self? {
        Self(raw: ["version": .number(repeats ? 7 : 6), "id": .string(id), "kind": .string("location"), "channels": .array([.string("local")]), "enabled": .bool(enabled),
                   "location_reference": .object(["version": .number(repeats ? 2 : 1), "device": .string(device), "task_id": .string(taskID), "task_generation": .string(taskGeneration),
                                                  "place_id": .string(place.id), "place_revision": .string(place.revision), "arm": .string(arm), "transition": .string(transition.rawValue), "repeats": .bool(repeats)])])
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
    /// Nil retains the exact legacy envelope/signature; explicit false is invalid.
    var repeats: Bool? = nil
    var isRepeating: Bool { repeats == true }
    static func isLocationSignature(_ value: String) -> Bool { value.hasPrefix("r9:") || value.hasPrefix("r10:") }
    static func validSignature(_ value: String) -> Bool {
        guard isLocationSignature(value), value.count == (value.hasPrefix("r10:") ? 68 : 67), let digest = value.split(separator: ":").last else { return false }
        return digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
    }
    var valid: Bool {
        LocationReminderIdentity.account(account) && [device, taskID, generation, specID, placeID, placeRevision, arm].allSatisfy { LocationReminderIdentity.uuid(.string($0)) } &&
        specID != ReminderSpec.plannedID && (repeats == nil || repeats == true) && (0...9_007_199_254_740_991).contains(completionVersion) && LocationReminderSettings.Transition(rawValue: transition) != nil
    }
    var signature: String {
        let fields = [account, device, taskID, generation, String(completionVersion), specID, placeID, placeRevision, arm, transition]
        return (isRepeating ? "r10:" : "r9:") + LocationReminderIdentity.digest(fields + (isRepeating ? ["every-visit"] : []))
    }
    var identifier: String { (isRepeating ? Self.namespace + "v2." : Self.prefix) + String(signature.split(separator: ":").last!) }
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
                                            specID: settings.id, placeID: place.id, placeRevision: place.revision, arm: settings.arm, transition: settings.transition.rawValue, repeats: settings.repeats ? true : nil)
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
    func repeatingOnly() -> Self { Self(eligible: eligible.filter { $0.ticket.isRepeating }, capacity: capacity, allowSubmissions: allowSubmissions) }
    func respectingHandoffConsent(_ receipts: [String: LocationHandoffImportReceipt], archive: LocationPrivateArchive) -> Self {
        guard LocationHandoffImportLedger.valid(receipts), archive.valid else { return .empty }
        return Self(eligible: eligible.filter { LocationHandoffImportLedger.permitsDelivery($0, receipts: receipts, archive: archive) }, capacity: capacity, allowSubmissions: allowSubmissions)
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
        /// Submission generations, not visits. Only active repeat intents may
        /// advance a generation to pause/recover their OS registration.
        var epoch: Int?
        init(ticket: LocationReminderTicket, phase: Phase, reason: Closure? = nil, epoch: Int? = nil) {
            self.ticket = ticket; self.phase = phase; self.reason = reason; self.epoch = ticket.isRepeating ? (epoch ?? 0) : nil
        }
        var valid: Bool { ticket.valid && ((phase == .closed) == (reason != nil)) && (ticket.isRepeating ? epoch.map { (0...9_007_199_254_740_991).contains($0) } == true : epoch == nil) }
    }
    var version = 1
    let device: String
    var entries: [String: Entry] = [:]
    /// Explicit retirement revokes even an already-delivered receipt without
    /// rewriting its immutable closed entry. No visit timestamps are collected.
    var revoked: [String]? = nil
    var valid: Bool {
        (version == 1 && revoked == nil || (version == 2 || version == 3) && revoked != nil) &&
        (!entries.values.contains(where: { $0.ticket.isRepeating }) || version == 3) &&
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
        if ticket.isRepeating { version = 3; revoked = revoked ?? [] }
        return true
    }
    /// This validates a genuine OS response against current accessible task/place state.
    /// Native response routing still has to prove its origin and fence async actions.
    func permitsResponse(_ ticket: LocationReminderTicket, eligible: [LocationReminderCandidate]) -> Bool {
        guard valid, ticket.device == device, revoked?.contains(ticket.identifier) != true, let entry = entries[ticket.identifier], entry.ticket == ticket,
              eligible.contains(where: { $0.ticket == ticket }) else { return false }
        guard entry.phase != .prepared || ticket.isRepeating && (entry.epoch ?? 0) > 0 else { return false }
        return entry.phase != .closed || [.delivered, .noLongerPending, .ambiguous].contains(entry.reason)
    }
}

struct LocationReminderObservation: Sendable {
    var pending: [LocationReminderCandidate]
    var delivered: Set<String> = []
    var unrecognized: Set<String> = []
}
protocol LocationReminderReviewRequiredError: Error { var requiresLocationReview: Bool { get } }
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
    /// Ongoing repeat consent permits another registration after a known pause or
    /// OS loss. One-shots and explicitly closed/revoked intents never take this path.
    private func restartRepeat(_ identifier: String) async -> Bool {
        guard var state = journal, let old = state.entries[identifier], old.ticket.isRepeating,
              old.phase == .reserved || old.phase == .installed, let epoch = old.epoch, epoch < 9_007_199_254_740_991,
              state.revoked?.contains(identifier) != true else { return false }
        state.entries[identifier] = .init(ticket: old.ticket, phase: .prepared, epoch: epoch + 1)
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
                    if changed { state.version = max(state.version, matching.contains(where: { $0.isRepeating }) ? 3 : 2); state.revoked = revoked.sorted() }
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
            var repeatRecovery = false
            let unexpected = observation.pending.filter { !targetIDs.contains($0.ticket.identifier) }.map { $0.ticket.identifier } + observation.unrecognized.filter { $0.hasPrefix(LocationReminderTicket.namespace) }
            await center.remove(unexpected)
            guard token == sequence else { continue }
            for (identifier, entry) in state.entries where entry.phase != .closed && !targetIDs.contains(identifier) {
                if entry.ticket.isRepeating, desired.contains(where: { $0.ticket == entry.ticket }) {
                    if entry.phase != .prepared, !(await restartRepeat(identifier)) { report.failed += 1 }
                } else if entry.phase != .prepared || entry.ticket.isRepeating && (entry.epoch ?? 0) > 0 {
                    if await close(identifier, reason: .cancelled) { report.closed += 1 } else { report.failed += 1 }
                }
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
                    } else if matches.count == 1, candidate.matches(matches[0]), candidate.ticket.isRepeating || !observation.delivered.contains(id) {
                        if entry.phase == .reserved {
                            var next = journal!; next.entries[id]?.phase = .installed
                            if !(await save(next)) { report.failed += 1 }
                        }
                        report.installed += 1
                    } else {
                        await center.remove([id])
                        if candidate.ticket.isRepeating && matches.isEmpty {
                            if await restartRepeat(id) { repeatRecovery = true } else { report.failed += 1 }
                        } else {
                            let reason: LocationReminderJournal.Closure = observation.delivered.contains(id) ? .delivered : (matches.isEmpty ? (entry.phase == .reserved ? .ambiguous : .noLongerPending) : .failed)
                            if await close(id, reason: reason) { report.closed += 1 } else { report.failed += 1 }
                        }
                    }
                } else if journal?.entries[id] == nil {
                    // No durable explicit intent: a restored/synced row cannot arm itself.
                    await center.remove([id]); report.failed += 1
                } else if candidate.ticket.isRepeating, (journal?.entries[id]?.epoch ?? 0) > 0, matches.count == 1, candidate.matches(matches[0]) {
                    // A paused repeat can adopt its own still-pending registration.
                    // Never-submitted epoch zero cannot claim this OS proof.
                    var next = journal!; next.entries[id]?.phase = .installed
                    if await save(next) { report.installed += 1 } else { report.failed += 1 }
                } else if (!candidate.ticket.isRepeating || (journal?.entries[id]?.epoch ?? 0) == 0) && (!matches.isEmpty || observation.delivered.contains(id)) {
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
                        await center.remove([id])
                        if candidate.ticket.isRepeating && (error as? any LocationReminderReviewRequiredError)?.requiresLocationReview != true { _ = await restartRepeat(id) }
                        else { _ = await close(id, reason: .failed) }
                        report.failed += 1
                    }
                }
                if token != sequence { break }
            }
            guard token == sequence else { continue }
            if repeatRecovery { continue }
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
          transition: LocationReminderSettings.Transition, repeats: Bool? = nil, replacing: LocationReminderSettings? = nil, identity: (id: String, arm: String)? = nil) {
        guard archive.valid, place.account == workspace.account, archive.places(for: workspace.account).contains(where: { $0 == place }),
              !task.completed, LocationReminderIdentity.uuid(task["task_generation"]),
              replacing == nil || ReminderSpec.rows(task).contains(.object(replacing!.raw)),
              let created = LocationReminderSettings.make(device: archive.device, taskID: task.id, taskGeneration: task.string("task_generation"), place: place, transition: transition, repeats: repeats ?? replacing?.repeats ?? false, id: identity?.id ?? replacing?.id ?? UUID().uuidString.lowercased(), arm: identity?.arm ?? UUID().uuidString.lowercased()) else { return nil }
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
        let ticket = Self(account: account, device: settings.device, taskID: task.id, generation: settings.taskGeneration, completionVersion: completion, specID: settings.id, placeID: settings.placeID, placeRevision: settings.placeRevision, arm: settings.arm, transition: settings.transition.rawValue, repeats: settings.repeats ? true : nil)
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
    static func staging(previous: Snapshot, proposed: Snapshot, account: String, acknowledged: [LocationReminderTicket] = [], newResponse: LocationNotificationAction? = nil, cleanup: LocationActionCleanup? = nil, installationReset: LocationInstallationReset? = nil) throws -> Snapshot {
        guard cleanup == nil || (cleanup?.account == account && newResponse == nil) else { throw LocationStorageFailure.changed }
        guard installationReset == nil || (installationReset?.account == account && newResponse == nil && cleanup == nil) else { throw LocationStorageFailure.changed }
        if let response = newResponse {
            guard response.valid, response.ticket.account == account, previous.locationActions?[response.source] == nil,
                  proposed.locationActions?[response.source] == response else { throw LocationStorageFailure(message: "This notification action has already been applied or changed.") }
        }
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
        let previousActions = try cleanup?.retaining(previous.locationActions ?? [:]) ?? previous.locationActions ?? [:]
        let proposedActions = try cleanup?.retaining(proposed.locationActions ?? [:]) ?? proposed.locationActions ?? [:]
        let actions = try LocationNotificationLedger.merging(
            installationReset?.retaining(previousActions) ?? previousActions,
            installationReset?.retaining(proposedActions) ?? proposedActions)
        var next = proposed; next.locationActions = actions.isEmpty ? nil : actions
        next.locationRetirements = jobs.isEmpty ? nil : jobs
        return next
    }
}


/// One response may change work once. The ledger is local snapshot metadata, not
/// a shared task or portable export. A snooze records an explicit future fire time,
/// never a visit timestamp, private label or boundary geometry.
struct LocationNotificationAction: Codable, Equatable, Sendable {
    static let category = "taskfold.location.snooze"
    static let prefix = "taskfold.ls1."
    static let maximum = 2048
    enum Kind: String, Codable, Sendable { case complete, tomorrow, snooze }
    enum Phase: String, Codable, Sendable { case queued, reserved, installed, closed }
    enum End: String, Codable, Sendable { case consumed, cancelled, failed, ambiguous, expired }
    let source: String
    let ticket: LocationReminderTicket
    let action: Kind
    let fireAt: Double?
    var revision = 0
    var phase: Phase
    var end: End?
    static func sourceValid(_ value: String) -> Bool { value.hasPrefix("la1:") && value.count == 68 && value.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) } }
    var valid: Bool {
        Self.sourceValid(source) && ticket.valid && (0...9_007_199_254_740_991).contains(revision) &&
        (action == .snooze ? fireAt.map { $0.isFinite && (1...Double(FocusSession.maximumTimestamp) / 1000).contains($0) && $0.rounded() == $0 } == true && ((phase == .closed) == (end != nil)) : fireAt == nil && phase == .closed && end == .consumed)
    }
    func request(title: String) -> ReminderRequest? {
        guard valid, action == .snooze, let fireAt else { return nil }
        let event = DueReminder(id: source, title: title, body: "Your snoozed place reminder.", date: Date(timeIntervalSince1970: 0), taskID: ticket.taskID, specID: ticket.specID, signature: ticket.signature)
        return ReminderRequest.make(account: ticket.account, event: event, fireAt: Date(timeIntervalSince1970: fireAt), snoozed: true)
    }
    func matches(_ request: ReminderRequest) -> Bool { self.request(title: request.event.title)?.matchesSnooze(request) == true }
    var permitsResponse: Bool { action == .snooze && (phase == .reserved || phase == .installed || phase == .closed && (end == .consumed || end == .ambiguous)) }
    func advancing(_ phase: Phase, end: End? = nil) -> Self {
        var next = self; next.phase = phase; next.end = end; next.revision += 1; return next
    }
    func sameIntent(_ other: Self) -> Bool { source == other.source && ticket == other.ticket && action == other.action && fireAt == other.fireAt }
}

enum LocationNotificationProof: Sendable {
    case boundary(LocationReminderCandidate)
    case visit(LocationReminderCandidate, occurrence: String)
    case snooze(ReminderRequest)
    var source: String {
        switch self {
        case .boundary(let candidate): "la1:" + LocationReminderIdentity.digest(["boundary", candidate.ticket.identifier])
        case .visit(let candidate, let occurrence): "la1:" + LocationReminderIdentity.digest(["visit", candidate.ticket.identifier, occurrence])
        case .snooze(let request): "la1:" + LocationReminderIdentity.digest(["snooze", request.identifier, request.event.signature, ReminderSignature.milliseconds(request.fireAt)])
        }
    }
    /// The system delivery date distinguishes visits; only its opaque digest enters
    /// a spent-action source. Merely observing a visit persists no timestamp/history.
    static func received(_ candidate: LocationReminderCandidate, deliveredAt: Date?) -> Self? {
        guard candidate.ticket.isRepeating else { return .boundary(candidate) }
        guard let deliveredAt, deliveredAt.timeIntervalSince1970.isFinite,
              (1...Double(FocusSession.maximumTimestamp) / 1000).contains(deliveredAt.timeIntervalSince1970) else { return nil }
        return .visit(candidate, occurrence: LocationReminderIdentity.digest([candidate.ticket.identifier, ReminderSignature.milliseconds(deliveredAt)]))
    }
    func candidate(account: String, tasks: [Record], archive: LocationPrivateArchive, cancellations: [String: LocationReminderTicket], actions: [String: LocationNotificationAction]) -> LocationReminderCandidate? {
        guard archive.valid, archive.allows(account: account) else { return nil }
        let candidates = LocationReminderPlan(account: account, device: archive.device, tasks: tasks, places: archive.places(for: account), availableNotificationSlots: 20, allowed: true, allowSubmissions: false).eligible
        return candidates.first { candidate in
            guard cancellations[candidate.ticket.identifier] == nil, archive.journal.permitsResponse(candidate.ticket, eligible: candidates) else { return false }
            switch self {
            case .boundary(let observed): return !candidate.ticket.isRepeating && candidate.matches(observed)
            case .visit(let observed, let occurrence):
                return candidate.ticket.isRepeating && occurrence.count == 64 && occurrence.allSatisfy { "0123456789abcdef".contains($0) } && candidate.matches(observed)
            case .snooze(let request):
                return actions[request.event.id].map { $0.ticket == candidate.ticket && $0.permitsResponse && $0.matches(request) } == true
            }
        }
    }
}

enum LocationSnoozeTransition: Sendable { case reserve, installed, notSubmitted, failed }
enum LocationSnoozeAcknowledgement: Sendable { case saved, retry, obsolete }

/// A durable explicit private reset denies every former installation locally.
/// Production cache writes must revalidate this proof under the private file lock.
/// The proof is never decoded from a task, backup or notification payload.
struct LocationInstallationReset: Sendable {
    let account: String
    let device: String
    init(account: String, archive: LocationPrivateArchive) throws {
        guard LocationReminderIdentity.account(account), archive.valid, (archive.version == 3 || archive.version == 4),
              archive.supersedesEarlierInstallations == true else { throw LocationStorageFailure.changed }
        self.account = account; device = archive.device
    }
    func retaining(_ records: [String: LocationNotificationAction]) throws -> [String: LocationNotificationAction] {
        guard LocationNotificationLedger.valid(records) else { throw LocationStorageFailure.unreadable }
        return records.filter { $0.value.ticket.account != account || $0.value.ticket.device == device }
    }
}

/// Explicit maintenance authority from a readable private journal. Only exact,
/// permanently denied tickets may lose their spent-action records. Delivered or
/// ambiguous one-shots and active repeats can still receive genuine responses.
struct LocationActionCleanup: Sendable {
    let account: String
    let journal: LocationReminderJournal
    init(account: String, archive: LocationPrivateArchive) throws {
        guard LocationReminderIdentity.account(account), archive.valid else { throw LocationStorageFailure.unreadable }
        self.account = account; journal = archive.journal
    }
    func permitsRemoval(_ record: LocationNotificationAction) -> Bool {
        guard record.valid, record.ticket.account == account, record.ticket.device == journal.device,
              let entry = journal.entries[record.ticket.identifier], entry.ticket == record.ticket, entry.phase == .closed else { return false }
        return journal.revoked?.contains(record.ticket.identifier) == true || [.cancelled, .failed, .untracked].contains(entry.reason)
    }
    func retaining(_ records: [String: LocationNotificationAction]) throws -> [String: LocationNotificationAction] {
        guard LocationNotificationLedger.valid(records) else { throw LocationStorageFailure.unreadable }
        return records.filter { !permitsRemoval($0.value) }
    }
}

enum LocationNotificationLedger {
    static func valid(_ records: [String: LocationNotificationAction]) -> Bool {
        records.count <= LocationNotificationAction.maximum && records.allSatisfy { $0.key == $0.value.source && $0.value.valid }
    }
    /// A recovered/undone snapshot cannot forget a response or rewind its state.
    static func merging(_ previous: [String: LocationNotificationAction], _ proposed: [String: LocationNotificationAction]) throws -> [String: LocationNotificationAction] {
        guard valid(previous), valid(proposed) else { throw LocationStorageFailure.unreadable }
        var result = previous
        for (id, next) in proposed {
            if let old = previous[id] {
                guard old.sameIntent(next), old.revision != next.revision || old == next else { throw LocationStorageFailure.changed }
                if next.revision <= old.revision { continue }
                guard old.phase != .closed,
                      old.phase != .installed || next.phase == .closed,
                      old.phase != .queued || [.reserved, .closed].contains(next.phase) else { throw LocationStorageFailure.changed }
            }
            result[id] = next
        }
        guard valid(result) else { throw LocationStorageFailure(message: "This device’s location action history is full. Your change has not been saved.") }
        return result
    }
    static func reconciled(_ records: [String: LocationNotificationAction], pending: [ReminderRequest], candidates: [LocationReminderCandidate], now: Date) -> [String: LocationNotificationAction] {
        var next = records
        for (id, record) in records where record.action == .snooze && record.phase != .closed {
            guard candidates.contains(where: { $0.ticket == record.ticket }) else { next[id] = record.advancing(.closed, end: .cancelled); continue }
            let found = pending.contains { record.matches($0) }
            switch record.phase {
            case .queued:
                if found { next[id] = record.advancing(.closed, end: .failed) }
                else if (record.fireAt ?? 0) <= now.timeIntervalSince1970 { next[id] = record.advancing(.closed, end: .expired) }
            case .reserved, .installed:
                if !found { next[id] = record.advancing(.closed, end: record.phase == .reserved ? .ambiguous : .consumed) }
                else if record.phase == .reserved { next[id] = record.advancing(.installed) }
            case .closed: break
            }
        }
        return next
    }
}

// MARK: Private desktop-to-phone place drafts
/// A private transport proposal, never a shared task reminder or placebook row.
/// Account context is deliberately outside the RPC body and survives UI awaits.
struct LocationHandoffProposal: Equatable, Sendable {
    static let maximumTime = 253_402_300_799_000
    static let requestKeys: Set<String> = ["version","id","task_id","task_generation","completion_version","authored_at_ms","place_name","latitude_e6","longitude_e6","radius_m","transition","repeats"]
    static let payloadKeys: Set<String> = ["place_name","latitude_e6","longitude_e6","radius_m","transition","repeats"]
    let account: String
    let raw: [String: JSON]
    var id: String { raw["id"]!.text }
    var taskID: String { raw["task_id"]!.text }
    var generation: String { raw["task_generation"]!.text }
    var completion: Int { raw["completion_version"]!.integer }
    var authoredMilliseconds: Int { raw["authored_at_ms"]!.integer }
    var payload: [String: JSON] { raw.filter { Self.payloadKeys.contains($0.key) } }
    var payloadDigest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try! encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
    }
    init?(account: String, raw: [String: JSON]) {
        guard LocationReminderIdentity.uuid(.string(account)), Set(raw.keys) == Self.requestKeys, raw["version"] == .number(1),
              ["id","task_id","task_generation"].allSatisfy({ LocationReminderIdentity.uuid(raw[$0]) }),
              Recurrence.number(raw["completion_version"] ?? .null, in: 0...9_007_199_254_740_991) != nil,
              Recurrence.number(raw["authored_at_ms"] ?? .null, in: 0...Self.maximumTime) != nil,
              case .string(let name)? = raw["place_name"], !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.unicodeScalars.count <= 120, name.utf8.count <= 480,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              Recurrence.number(raw["latitude_e6"] ?? .null, in: -90_000_000...90_000_000) != nil,
              Recurrence.number(raw["longitude_e6"] ?? .null, in: -180_000_000...180_000_000) != nil,
              Recurrence.number(raw["radius_m"] ?? .null, in: 100...5000) != nil,
              LocationReminderSettings.Transition(rawValue: raw["transition"]?.text ?? "") != nil, case .bool? = raw["repeats"] else { return nil }
        self.account = account; self.raw = raw
    }
    static func make(account: String, task: Record, place: LocationPrivatePlace, transition: LocationReminderSettings.Transition, repeats: Bool,
                     now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> Self? {
        let milliseconds = floor(now.timeIntervalSince1970 * 1000)
        guard place.account == account, !task.completed, milliseconds.isFinite, (0...Double(maximumTime)).contains(milliseconds) else { return nil }
        let completion = task["completion_version"] == .null ? JSON.number(0) : task["completion_version"]
        return Self(account: account, raw: ["version": .number(1),"id": .string(id),"task_id": .string(task.id),"task_generation": task["task_generation"],
            "completion_version": completion,"authored_at_ms": .number(milliseconds),"place_name": .string(place.name),
            "latitude_e6": .number(Double(place.latitudeE6)),"longitude_e6": .number(Double(place.longitudeE6)),"radius_m": .number(Double(place.radius)),
            "transition": .string(transition.rawValue),"repeats": .bool(repeats)])
    }
    func matches(task: Record, account: String) -> Bool {
        self.account == account && task.id == taskID && task.string("task_generation") == generation && !task.completed &&
        (task["completion_version"] == .null ? 0 : Recurrence.number(task["completion_version"], in: 0...9_007_199_254_740_991)) == completion
    }
}

struct LocationHandoffRecord: Equatable, Sendable {
    enum State: String, Sendable { case pending, claimed, imported, discarded, expired }
    static let keys: Set<String> = ["version","account_id","id","task_id","task_generation","completion_version","authored_at_ms","created_at_ms","expires_at_ms","state","claim_device","available","payload"]
    let raw: [String: JSON]
    let state: State
    let proposal: LocationHandoffProposal?
    var id: String { raw["id"]!.text }
    var account: String { raw["account_id"]!.text }
    var device: String? { if case .string(let value)? = raw["claim_device"] { return value }; return nil }
    var expiresMilliseconds: Int { raw["expires_at_ms"]!.integer }
    var available: Bool { raw["available"] == .bool(true) }
    init?(raw: [String: JSON], account: String, device: String?, serverMilliseconds: Int) {
        guard Set(raw.keys) == Self.keys, raw["version"] == .number(1), raw["account_id"] == .string(account),
              LocationReminderIdentity.uuid(.string(account)), device.map({ LocationReminderIdentity.uuid(.string($0)) }) ?? true,
              ["id","task_id","task_generation"].allSatisfy({ LocationReminderIdentity.uuid(raw[$0]) }),
              let completion = Recurrence.number(raw["completion_version"] ?? .null, in: 0...9_007_199_254_740_991),
              let authored = Recurrence.number(raw["authored_at_ms"] ?? .null, in: 0...LocationHandoffProposal.maximumTime),
              let created = Recurrence.number(raw["created_at_ms"] ?? .null, in: 0...LocationHandoffProposal.maximumTime),
              let expiry = Recurrence.number(raw["expires_at_ms"] ?? .null, in: 0...LocationHandoffProposal.maximumTime),
              authored <= created + 300_000, created <= authored + 86_400_000, created <= serverMilliseconds + 300_000,
              expiry > created, expiry <= created + 604_800_000,
              let state = State(rawValue: raw["state"]?.text ?? ""), case .bool(let available)? = raw["available"],
              raw["claim_device"] == .null || LocationReminderIdentity.uuid(raw["claim_device"]) else { return nil }
        let claimed: String? = raw["claim_device"] == .null ? nil : raw["claim_device"]?.text
        guard state != .pending || claimed == nil, ![State.claimed,.imported].contains(state) || claimed != nil,
              !available || ([State.pending,.claimed].contains(state) && expiry > serverMilliseconds),
              ![State.pending,.claimed].contains(state) || expiry > serverMilliseconds else { return nil }
        let expectsPayload = available && (state == .pending || claimed == device && device != nil)
        let proposal: LocationHandoffProposal?
        if expectsPayload {
            guard case .object(let payload)? = raw["payload"], Set(payload.keys) == LocationHandoffProposal.payloadKeys else { return nil }
            var request = payload
            request["version"] = .number(1); request["id"] = raw["id"]; request["task_id"] = raw["task_id"]; request["task_generation"] = raw["task_generation"]
            request["completion_version"] = .number(Double(completion)); request["authored_at_ms"] = .number(Double(authored))
            guard let value = LocationHandoffProposal(account: account, raw: request) else { return nil }; proposal = value
        } else { guard raw["payload"] == .null else { return nil }; proposal = nil }
        self.raw = raw; self.state = state; self.proposal = proposal
    }
}

/// Persist this nonce in device-private storage BEFORE claiming. A lost response
/// can resume only the same account/device review. It contains no geometry/name.
struct LocationHandoffReviewTicket: Codable, Equatable, Sendable {
    var version = 2
    let account: String
    let id: String
    let device: String
    let nonce: String
    let taskID: String
    let generation: String
    let completion: Int
    let expiresMilliseconds: Int
    let payloadDigest: String
    let placeID: String
    let placeRevision: String
    let specID: String
    let arm: String
    var key: String { account + "|" + id }
    var valid: Bool {
        version == 2 && [account,id,device,nonce,taskID,generation,placeID,placeRevision,specID,arm].allSatisfy { LocationReminderIdentity.uuid(.string($0)) } &&
        (0...9_007_199_254_740_991).contains(completion) && (0...LocationHandoffProposal.maximumTime).contains(expiresMilliseconds) &&
        payloadDigest.count == 64 && payloadDigest.allSatisfy { "0123456789abcdef".contains($0) }
    }
    init?(record: LocationHandoffRecord, device: String, nonce: String = UUID().uuidString.lowercased()) {
        guard record.available, record.state == .pending, record.device == nil, let proposal = record.proposal else { return nil }
        account = record.account; id = record.id; self.device = device; self.nonce = nonce; taskID = proposal.taskID; generation = proposal.generation
        completion = proposal.completion; expiresMilliseconds = record.expiresMilliseconds; payloadDigest = proposal.payloadDigest
        placeID = UUID().uuidString.lowercased(); placeRevision = UUID().uuidString.lowercased()
        specID = UUID().uuidString.lowercased(); arm = UUID().uuidString.lowercased()
        guard valid else { return nil }
    }
    func matches(_ record: LocationHandoffRecord) -> Bool {
        valid && record.account == account && record.id == id && record.raw["task_id"] == .string(taskID) && record.raw["task_generation"] == .string(generation) &&
        record.raw["completion_version"] == .number(Double(completion)) && record.expiresMilliseconds == expiresMilliseconds &&
        (record.proposal.map { $0.payloadDigest == payloadDigest } ?? true)
    }
}

struct LocationHandoffResponse: Sendable {
    static let maximumBytes = 2_000_000
    let account: String
    let serverMilliseconds: Int
    let records: [LocationHandoffRecord]
    static func read(_ data: Data, account: String, device: String?) throws -> Self {
        guard data.count <= maximumBytes, LocationReminderIdentity.uuid(.string(account)), device.map({ LocationReminderIdentity.uuid(.string($0)) }) ?? true else { throw AppFailure(message: "Private place drafts could not be read. Your tasks are unchanged.") }
        let json = try JSONDecoder().decode(JSON.self, from: data)
        guard case .object(let fields) = json, Set(fields.keys) == ["version","account_id","server_now_ms","items"], fields["version"] == .number(1), fields["account_id"] == .string(account),
              let now = Recurrence.number(fields["server_now_ms"] ?? .null, in: 0...LocationHandoffProposal.maximumTime), case .array(let items)? = fields["items"], items.count <= 256 else { throw AppFailure(message: "These private place drafts need a newer Taskfold version or a fresh sign-in.") }
        let records = items.compactMap { value -> LocationHandoffRecord? in guard case .object(let raw) = value else { return nil }; return LocationHandoffRecord(raw: raw, account: account, device: device, serverMilliseconds: now) }
        guard records.count == items.count, Set(records.map(\.id)).count == records.count else { throw AppFailure(message: "A private place draft changed or could not be read. No reminder has been added.") }
        return Self(account: account, serverMilliseconds: now, records: records)
    }
}

enum LocationHandoffCommand: Sendable {
    case put(LocationHandoffProposal), list(device: String?), claim(LocationHandoffReviewTicket), finish(LocationHandoffReviewTicket), abandon(LocationHandoffReviewTicket), discard(id: String)
    var rpc: String {
        switch self { case .put: "put"; case .list: "list"; case .claim: "claim"; case .finish: "finish"; case .abandon: "abandon"; case .discard: "discard" }
    }
    var device: String? { switch self { case .list(let device): device; case .claim(let t), .finish(let t), .abandon(let t): t.device; default: nil } }
    func body(account: String) throws -> [String: JSON] {
        guard LocationReminderIdentity.uuid(.string(account)), device.map({ LocationReminderIdentity.uuid(.string($0)) }) ?? true else { throw AppFailure(message: "Sign in before sending a private place draft.") }
        switch self {
        case .put(let proposal): guard proposal.account == account else { throw CancellationError() }; return ["_request": .object(proposal.raw)]
        case .list(let device): return ["_device": device.map(JSON.string) ?? .null]
        case .claim(let t), .finish(let t), .abandon(let t): guard t.valid, t.account == account else { throw CancellationError() }; return ["_id": .string(t.id),"_device": .string(t.device),"_nonce": .string(t.nonce)]
        case .discard(let id): guard LocationReminderIdentity.uuid(.string(id)) else { throw AppFailure(message: "This private place draft is unavailable.") }; return ["_id": .string(id)]
        }
    }
    func accepts(_ response: LocationHandoffResponse) -> Bool {
        switch self {
        case .list: return true
        case .put(let proposal):
            guard response.records.count == 1, let row = response.records.first else { return false }
            return row.id == proposal.id && row.raw["task_id"] == .string(proposal.taskID) && row.raw["task_generation"] == .string(proposal.generation) &&
                row.raw["completion_version"] == .number(Double(proposal.completion)) && row.raw["authored_at_ms"] == .number(Double(proposal.authoredMilliseconds)) && (row.proposal.map { $0 == proposal } ?? true)
        case .claim(let t), .finish(let t), .abandon(let t):
            guard response.records.count == 1, let row = response.records.first else { return false }
            return t.matches(row) && row.device == t.device
        case .discard(let id): return response.records.count == 1 && response.records.first?.id == id
        }
    }
}

@MainActor struct LocationHandoffAPI {
    let backend: Backend
    func perform(_ command: LocationHandoffCommand, account: String, isCurrent: @MainActor () -> Bool) async throws -> LocationHandoffResponse {
        guard isCurrent(), backend.session?.user.id == account else { throw CancellationError() }
        let incarnation = backend.reminderSessionIncarnation, body = try command.body(account: account)
        let data = try await backend.request("/rest/v1/rpc/taskfold_location_handoff_" + command.rpc, method: "POST", body: body, expectedAccount: account)
        guard isCurrent(), backend.reminderSessionIncarnation == incarnation, backend.session?.user.id == account else { throw CancellationError() }
        let response = try LocationHandoffResponse.read(data, account: account, device: command.device)
        guard command.accepts(response) else { throw AppFailure(message: "This private place draft changed. Reopen the review before continuing.") }
        return response
    }
}


/// A local task-cache receipt, written in the same atomic replacement as the task.
/// No private nonce, label, coordinates or full proposal enters the workspace cache.
struct LocationHandoffImportReceipt: Codable, Equatable, Sendable {
    var version = 1
    let reviewID: String
    let expiresMilliseconds: Int
    let ticket: LocationReminderTicket
    let recoveryEpoch: String?
    var key: String { ticket.account + "|" + reviewID }
    var valid: Bool { version == 1 && LocationReminderIdentity.uuid(.string(reviewID)) &&
        (0...LocationHandoffProposal.maximumTime).contains(expiresMilliseconds) && ticket.valid && LocationReminderIdentity.uuid(.string(ticket.account)) &&
        (recoveryEpoch.map { LocationReminderIdentity.uuid(.string($0)) } ?? true) }
    init?(review: LocationHandoffReviewTicket, task: Record, settings: LocationReminderSettings, recoveryEpoch: String? = nil) {
        guard review.valid, settings.id == review.specID, settings.arm == review.arm, settings.device == review.device,
              settings.placeID == review.placeID, settings.placeRevision == review.placeRevision,
              settings.taskID == review.taskID, settings.taskGeneration == review.generation,
              !task.completed, ReminderSpec.rows(task).contains(.object(settings.raw)),
              let ticket = LocationReminderTicket.bound(account: review.account, task: task, settings: settings),
              ticket.completionVersion == review.completion else { return nil }
        reviewID = review.id; expiresMilliseconds = review.expiresMilliseconds; self.ticket = ticket; self.recoveryEpoch = recoveryEpoch
        guard valid else { return nil }
    }
    /// Resume only the still-saved reviewed reference. A private journal entry or
    /// retirement/revocation always takes precedence, including after Undo/Redo.
    func recoveryCandidate(account: String, tasks: [Record], archive: LocationPrivateArchive, cancellations: [String: LocationReminderTicket]) -> LocationReminderCandidate? {
        guard valid, ticket.account == account, archive.valid, archive.device == ticket.device, archive.allows(account: account),
              let recoveryEpoch, archive.handoffEpochs?[account] == recoveryEpoch,
              archive.journal.entries[ticket.identifier] == nil, archive.journal.revoked?.contains(ticket.identifier) != true,
              cancellations[ticket.identifier] == nil else { return nil }
        let matches = tasks.filter { $0.id == ticket.taskID }
        guard matches.count == 1, let task = matches.first, !task.completed,
              let settings = ReminderSpec.rows(task).compactMap({ LocationReminderSettings(raw: $0.object) }).first(where: { $0.id == ticket.specID }),
              let place = archive.places(for: account).first(where: { $0.id == ticket.placeID && $0.revision == ticket.placeRevision }),
              let candidate = LocationReminderCandidate(account: account, device: archive.device, task: task, settings: settings, place: place),
              candidate.ticket == ticket else { return nil }
        return candidate
    }
    func matches(_ review: LocationHandoffReviewTicket) -> Bool {
        valid && review.valid && reviewID == review.id && expiresMilliseconds == review.expiresMilliseconds &&
        ticket.account == review.account && ticket.device == review.device && ticket.taskID == review.taskID &&
        ticket.generation == review.generation && ticket.completionVersion == review.completion && ticket.specID == review.specID &&
        ticket.arm == review.arm && ticket.placeID == review.placeID && ticket.placeRevision == review.placeRevision
    }
}

/// A monotonic device-local record: Undo, sync and snapshot restoration cannot erase
/// a saved import. Never reclaim by an untrusted wall clock and then allow a replay.
enum LocationHandoffImportLedger {
    static let maximum = 4096
    static func valid(_ rows: [String: LocationHandoffImportReceipt]) -> Bool {
        rows.count <= maximum && rows.allSatisfy { $0.key == $0.value.key && $0.value.valid }
    }
    static func permitsDelivery(_ candidate: LocationReminderCandidate, receipts: [String: LocationHandoffImportReceipt], archive: LocationPrivateArchive) -> Bool {
        guard receipts.count <= maximum else { return false }
        let imports = receipts.values.filter { $0.ticket == candidate.ticket }
        guard !imports.isEmpty else { return true } // A separately reviewed fresh arm has its own journal authority.
        guard imports.count == 1, let receipt = imports.first, receipt.valid, let epoch = receipt.recoveryEpoch else { return false }
        return archive.device == candidate.ticket.device && archive.allows(account: candidate.ticket.account) && archive.handoffEpochs?[candidate.ticket.account] == epoch
    }
    static func staging(previous: Snapshot, proposed: Snapshot, accepting receipt: LocationHandoffImportReceipt? = nil) throws -> [String: LocationHandoffImportReceipt]? {
        var records = previous.locationImports ?? [:]
        guard valid(records), valid(proposed.locationImports ?? [:]) else { throw LocationStorageFailure.unreadable }
        if let receipt {
            guard receipt.valid, records[receipt.key] == nil, proposed.locationImports?[receipt.key] == receipt,
                  let saved = proposed.tables["tasks"]?.filter({ $0.id == receipt.ticket.taskID }), saved.count == 1,
                  !saved[0].completed,
                  let settings = ReminderSpec.rows(saved[0]).compactMap({ LocationReminderSettings(raw: $0.object) }).first(where: { $0.id == receipt.ticket.specID }),
                  LocationReminderTicket.bound(account: receipt.ticket.account, task: saved[0], settings: settings) == receipt.ticket,
                  !(previous.tables["tasks"] ?? []).contains(where: { task in
                      task.id == receipt.ticket.taskID && ReminderSpec.rows(task).contains(.object(settings.raw))
                  }) else { throw LocationStorageFailure(message: "This place draft was already saved or changed. No second reminder was added.") }
        }
        for (key, record) in proposed.locationImports ?? [:] {
            guard records[key] == nil || records[key] == record else { throw LocationStorageFailure.changed }
            records[key] = record
        }
        guard valid(records) else { throw LocationStorageFailure(message: "This device’s saved place-draft history is full. Your task has not changed.") }
        return records.isEmpty ? nil : records
    }
}

extension LocationHandoffReviewTicket {
    func matches(_ proposal: LocationHandoffProposal) -> Bool {
        valid && proposal.account == account && proposal.id == id && proposal.taskID == taskID && proposal.generation == generation &&
        proposal.completion == completion && proposal.payloadDigest == payloadDigest
    }
    func reviewedPlace(_ proposal: LocationHandoffProposal) -> LocationPrivatePlace? {
        guard matches(proposal) else { return nil }
        return LocationPrivatePlace(raw: ["version": .number(1), "id": .string(placeID), "revision": .string(placeRevision),
            "account": .string(account), "name": proposal.raw["place_name"]!, "latitude_e6": proposal.raw["latitude_e6"]!,
            "longitude_e6": proposal.raw["longitude_e6"]!, "radius_m": proposal.raw["radius_m"]!])
    }
    func reviewedSettings(_ proposal: LocationHandoffProposal) -> LocationReminderSettings? {
        guard let place = reviewedPlace(proposal), let transition = LocationReminderSettings.Transition(rawValue: proposal.raw["transition"]!.text) else { return nil }
        return .make(device: device, taskID: taskID, taskGeneration: generation, place: place, transition: transition,
            repeats: proposal.raw["repeats"] == .bool(true), id: specID, arm: arm)
    }
}


/// A visible, memory-only review; server Claim and a protected header precede it.
/// Task/permission changes are not inferred from receiving or decoding this value.
struct LocationHandoffDeviceReview: Sendable {
    let ticket: LocationHandoffReviewTicket
    let proposal: LocationHandoffProposal
    let baseline: Record
    let workspace: WorkspaceBinding
    init?(ticket: LocationHandoffReviewTicket, claimed: LocationHandoffRecord, task: Record, workspace: WorkspaceBinding) {
        guard ticket.matches(claimed), claimed.state == .claimed, claimed.device == ticket.device, claimed.available,
              let proposal = claimed.proposal, ticket.matches(proposal), proposal.matches(task: task, account: workspace.account) else { return nil }
        self.ticket = ticket; self.proposal = proposal; baseline = task; self.workspace = workspace
    }
    func preparing(task: Record, archive: LocationPrivateArchive, workspace: WorkspaceBinding) -> LocationReminderReview? {
        guard self.workspace == workspace, ticket.matches(proposal), proposal.matches(task: task, account: workspace.account),
              ReminderSpec.rows(baseline) == ReminderSpec.rows(task), archive.device == ticket.device,
              archive.handoffReviews?[ticket.key] == ticket, let place = ticket.reviewedPlace(proposal), archive.places.contains(place.raw),
              let transition = LocationReminderSettings.Transition(rawValue: proposal.raw["transition"]!.text) else { return nil }
        return LocationReminderReview(workspace: workspace, task: task, archive: archive, place: place,
            transition: transition, repeats: proposal.raw["repeats"] == .bool(true), identity: (ticket.specID,ticket.arm))
    }
}

#if DEBUG
/// Exact disposable hosts only. All Backend HTTP is intercepted; no Keychain read,
/// real account, shared backend or actual task sync participates in this fixture.
enum LocationHandoffNativeFixture {
    static let account = "f083cafe-8100-4000-8000-000000000001"
    static let taskID = "f083cafe-8300-4000-8000-000000000001"
    static let generation = "f083cafe-8400-4000-8000-000000000001"
    static let draftID = "f083cafe-8600-4000-8000-000000000001"
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowtestsp1","com.dbakp.taskfold.mac.workflowtestsnotes1"].contains(Bundle.main.bundleIdentifier ?? "") &&
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--location-handoff-native-fixture")
    }
    static var root: URL {
        #if os(macOS)
        URL(fileURLWithPath: "/private/tmp/taskfold-handoff-native-mac", isDirectory: true)
        #else
        URL.applicationSupportDirectory.appendingPathComponent("Taskfold/HandoffNativeFixture", isDirectory: true)
        #endif
    }
    static var sender: Bool { ProcessInfo.processInfo.arguments.contains("--handoff-sender") }
    @MainActor static func backend() -> Backend {
        precondition(enabled)
        if ProcessInfo.processInfo.arguments.contains("--handoff-reset") {
            try? FileManager.default.removeItem(at: root)
        }
        UserDefaults.standard.set(false, forKey: "localMode")
        UserDefaults.standard.set(false, forKey: ReminderPreferences.key(account))
        UserDefaults.standard.set(false, forKey: "dailyBackups." + account)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LocationHandoffFixtureHTTP.self]
        let session = try! JSONDecoder().decode(Session.self, from: JSONEncoder().encode(JSON.object([
            "access_token": .string("synthetic-handoff-access"),"refresh_token": .string("synthetic-handoff-refresh"),"expires_in": .number(3600),
            "user": .object(["id": .string(account),"email": .string("handoff-native@example.invalid")])
        ])))
        return Backend(configuration: ["URL":"https://handoff-native.invalid","Key":"synthetic-public-key"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    static func task() -> Record {
        var task = Record.task(user: account); task["id"] = .string(taskID); task["task_generation"] = .string(generation)
        task["completion_version"] = .number(0); task["title"] = .string("Prepare the studio review")
        return task
    }
    static func failTaskSaveOnce() -> Bool {
        guard enabled, ProcessInfo.processInfo.arguments.contains("--handoff-task-save-fails-once") else { return false }
        let marker = root.appendingPathComponent("task-save-refused")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return false }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data("synthetic failure consumed".utf8).write(to: marker, options: .atomic)
        return true
    }
}
private final class LocationHandoffFixtureHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard LocationHandoffNativeFixture.enabled else { finish(403, .object(["message": .string("Fixture is unavailable.")])); return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            let response = try serve(); finish(response.0, response.1)
        } catch { finish(500, .object(["message": .string("The synthetic fixture could not be read.")])) }
    }
    private func body() throws -> [String: JSON] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        }
        return try JSONDecoder().decode(JSON.self, from: data).object
    }
    private func serve() throws -> (Int, JSON) {
        let fixture = LocationHandoffNativeFixture.self, now = Int(floor(Date().timeIntervalSince1970*1000))
        let url = fixture.root.appendingPathComponent("server.json")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        var state: [String: JSON]
        if let data = try? Data(contentsOf: url) { state = try JSONDecoder().decode(JSON.self, from: data).object }
        else {
            state = ["records": .object([:]),"nonces": .object([:]),"putCalls": .number(0),"claimCalls": .number(0),"finishCalls": .number(0)]
            if !fixture.sender {
                let place = LocationPrivatePlace.make(account: fixture.account, name: "Sample design studio", latitude: 55.676098, longitude: 12.568337, radius: 250)!
                let proposal = LocationHandoffProposal.make(account: fixture.account, task: fixture.task(), place: place, transition: .arrive, repeats: true, id: fixture.draftID)!
                state["records"] = .object([proposal.id: .object(document(proposal, now: now))])
            }
        }
        var rows = state["records"]!.object, nonces = state["nonces"]!.object
        let arguments = try body(), operation = request.url?.lastPathComponent.replacingOccurrences(of: "taskfold_location_handoff_", with: "") ?? ""
        guard request.url?.host == "handoff-native.invalid", request.url?.path.hasPrefix("/rest/v1/rpc/taskfold_location_handoff_") == true else {
            return (404,.object(["message":.string("Only isolated place-draft RPCs are available.")]))
        }
        let device = arguments["_device"] ?? .null, id = arguments["_id"]?.text ?? ""
        var selected: [[String:JSON]] = []
        var status = 200
        if operation == "put" {
            state["putCalls"] = .number(Double(state["putCalls"]!.integer+1))
            guard let proposal = LocationHandoffProposal(account: fixture.account, raw: arguments["_request"]?.object ?? [:]) else { return (400,.object(["message":.string("Review the synthetic place first.")])) }
            if rows[proposal.id] == nil { rows[proposal.id] = .object(document(proposal, now: now)) }
            selected = [rows[proposal.id]!.object]
            if ProcessInfo.processInfo.arguments.contains("--handoff-put-lost-response-once"), state["putLost"] != .bool(true) { state["putLost"] = .bool(true); status = 503 }
        } else if operation == "list" {
            selected = rows.values.map(\.object).sorted { $0["id"]!.text < $1["id"]!.text }
        } else {
            guard var row = rows[id]?.object else { return (404,.object(["message":.string("This place draft is unavailable.")])) }
            if operation == "claim" {
                state["claimCalls"] = .number(Double(state["claimCalls"]!.integer+1))
                if row["state"] == .string("pending") { row["state"] = .string("claimed"); row["claim_device"] = device; nonces[id] = arguments["_nonce"] }
                guard row["claim_device"] == device, nonces[id] == arguments["_nonce"] else { return (409,.object(["message":.string("Continue the review on its original device.")])) }
            } else if operation == "finish" || operation == "abandon" {
                guard row["claim_device"] == device, nonces[id] == arguments["_nonce"] else { return (409,.object(["message":.string("The saved review changed.")])) }
                if operation == "finish" {
                    state["finishCalls"] = .number(Double(state["finishCalls"]!.integer+1))
                    if ProcessInfo.processInfo.arguments.contains("--handoff-finish-unavailable") { status = 503 }
                }
                if status == 200 { row["state"] = .string(operation == "finish" ? "imported" : "discarded"); row["available"] = .bool(false); row["payload"] = .null }
            } else if operation == "discard" {
                guard row["state"] == .string("pending") else { return (409,.object(["message":.string("A device review has started.")])) }
                row["state"] = .string("discarded"); row["available"] = .bool(false); row["payload"] = .null
            } else { return (404,.object(["message":.string("Unsupported synthetic operation.")])) }
            rows[id] = .object(row); selected = [row]
        }
        state["records"] = .object(rows); state["nonces"] = .object(nonces)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        if status != 200 { return (status,.object(["message":.string("The connection was interrupted. Retry to confirm the same draft.")])) }
        selected = selected.map { raw in
            var row = raw
            if row["state"] == .string("claimed"), row["claim_device"] != device { row["payload"] = .null }
            return row
        }
        return (200,.object(["version":.number(1),"account_id":.string(fixture.account),"server_now_ms":.number(Double(now)),"items":.array(selected.map(JSON.object))]))
    }
    private func document(_ proposal: LocationHandoffProposal, now: Int) -> [String:JSON] {
        ["version":.number(1),"account_id":.string(proposal.account),"id":.string(proposal.id),"task_id":.string(proposal.taskID),"task_generation":.string(proposal.generation),
         "completion_version":.number(Double(proposal.completion)),"authored_at_ms":.number(Double(proposal.authoredMilliseconds)),"created_at_ms":.number(Double(now)),
         "expires_at_ms":.number(Double(now+604_800_000)),"state":.string("pending"),"claim_device":.null,"available":.bool(true),"payload":.object(proposal.payload)]
    }
    private func finish(_ status: Int, _ value: JSON) {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"] )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
