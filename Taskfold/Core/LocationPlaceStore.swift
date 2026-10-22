import Foundation
import Darwin

struct LocationStorageFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    static let unreadable = Self(message: "Saved places could not be read. Your existing data has not been replaced.")
    static let changed = Self(message: "This place or location setup changed. Reload it before trying again.")
}

struct LocationPrivateArchive: Codable, Equatable, Sendable {
    static let maximumPlaces = 50
    var version = 1
    let device: String
    var places: [[String: JSON]] = []
    /// Version 2 adds explicit account/device consent; version 1 has no allowance.
    var allowedAccounts: [String]? = nil
    var journal: LocationReminderJournal
    init(device: String = UUID().uuidString.lowercased()) { self.device = device; journal = .init(device: device) }
    var valid: Bool {
        let decoded = places.compactMap(LocationPrivatePlace.init(raw:))
        return (version == 1 && allowedAccounts == nil || version == 2 && allowedAccounts != nil) &&
        (allowedAccounts.map { $0.count <= 50 && Set($0).count == $0.count && $0.allSatisfy(LocationReminderIdentity.account) } ?? true) &&
        LocationReminderIdentity.uuid(.string(device)) && journal.valid && journal.device == device &&
        places.count <= Self.maximumPlaces && decoded.count == places.count && Set(decoded.map(\.id)).count == places.count
    }
    func allows(account: String) -> Bool { valid && allowedAccounts?.contains(account) == true }
    func places(for account: String) -> [LocationPrivatePlace] {
        places.compactMap(LocationPrivatePlace.init(raw:)).filter { $0.account == account }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func decode(_ data: Data) throws -> Self {
        let json = try JSONDecoder().decode(JSON.self, from: data)
        func keys(_ value: JSON, allowed: Set<String>) -> Bool { if case .object(let object) = value { return Set(object.keys).isSubset(of: allowed) }; return false }
        guard keys(json, allowed: ["version","device","places","journal","allowedAccounts"]), let journal = json.object["journal"],
              keys(journal, allowed: ["version","device","entries","revoked"]), case .object(let entries)? = journal.object["entries"] else { throw LocationStorageFailure.unreadable }
        for entry in entries.values {
            guard keys(entry, allowed: ["ticket","phase","reason"]), let ticket = entry.object["ticket"],
                  keys(ticket, allowed: ["account","device","taskID","generation","completionVersion","specID","placeID","placeRevision","arm","transition"]) else { throw LocationStorageFailure.unreadable }
        }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.valid else { throw LocationStorageFailure.unreadable }; return archive
    }
}

/// Fixed private pathname, no App Group and no connection to portable work snapshots.
/// The nonblocking process lock protects read/modify/write across store instances.
struct LocationPrivateFile: Sendable {
    static let maximumBytes = 4_000_000
    let directory: URL
    var url: URL { directory.appendingPathComponent("state-v1.json") }
    init(applicationSupport: URL) { directory = applicationSupport.appendingPathComponent("LocationPrivate", isDirectory: true) }
    private func checkedDirectory(create: Bool) throws -> Bool {
        let fm = FileManager.default
        do {
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw LocationStorageFailure.unreadable }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard create else { return false }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if create {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var folder = directory; try folder.setResourceValues(values)
        }
        return true
    }
    func read() throws -> LocationPrivateArchive? {
        guard try checkedDirectory(create: false) else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { if errno == ENOENT { return nil }; throw LocationStorageFailure.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= Self.maximumBytes else { throw LocationStorageFailure.unreadable }
        var data = Data()
        while data.count <= Self.maximumBytes {
            guard let next = try handle.read(upToCount: min(65_536, Self.maximumBytes + 1 - data.count)), !next.isEmpty else { break }
            data.append(next)
        }
        guard data.count <= Self.maximumBytes else { throw LocationStorageFailure.unreadable }
        do { return try LocationPrivateArchive.decode(data) } catch { throw LocationStorageFailure.unreadable }
    }
    func transaction<T>(_ edit: (LocationPrivateArchive?) throws -> (LocationPrivateArchive, T)) throws -> T {
        try locked {
            let (next, result) = try edit(read())
            try write(next); return result
        }
    }
    /// Used only after an explicit whole-installation reset confirmation, including for
    /// unreadable data. A fresh device identity makes all former references unavailable.
    func reset() throws -> LocationPrivateArchive {
        try locked { let fresh = LocationPrivateArchive(); try write(fresh); return fresh }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        _ = try checkedDirectory(create: true)
        let descriptor = Darwin.open(directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocationStorageFailure.unreadable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LocationStorageFailure(message: "Places are being updated. Try again in a moment.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func write(_ archive: LocationPrivateArchive) throws {
        guard archive.valid else { throw LocationStorageFailure.unreadable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= Self.maximumBytes else { throw LocationStorageFailure(message: "This device’s saved-place storage is full.") }
        // Refuse aliased targets even on reset; never follow a link into other data.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw LocationStorageFailure.unreadable }
        }
        let temp = directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
        let descriptor = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocationStorageFailure.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temp.path)
        #endif
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard Darwin.rename(temp.path, url.path) == 0 else { throw LocationStorageFailure.unreadable }
        let folder = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { throw LocationStorageFailure(message: "The save may have completed. Reload places before trying again.") }
        defer { Darwin.close(folder) }
        guard fsync(folder) == 0 else { throw LocationStorageFailure(message: "The save may have completed. Reload places before trying again.") }
    }
}

actor LocationPrivateStore {
    let file: LocationPrivateFile
    init(applicationSupport: URL) { file = .init(applicationSupport: applicationSupport) }
    /// Keep all UI-test private state outside the real installation's placebook.
    static var applicationSupport: URL {
        var root = URL.applicationSupportDirectory.appendingPathComponent("Taskfold", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            let lifecycle = Bundle.main.bundleIdentifier == "com.dbakp.taskfold.workflowtestsp1" && ProcessInfo.processInfo.arguments.contains("--location-workspace-fixture")
            let editor = Bundle.main.bundleIdentifier == "com.dbakp.taskfold.workflowtestsp1" && ProcessInfo.processInfo.arguments.contains("--location-editor-fixture")
            root.appendPathComponent(editor ? "ui-testing-location-editor" : lifecycle ? "ui-testing-location-workspace" : "ui-testing-places", isDirectory: true)
        }
        #endif
        return root
    }
    func snapshot() throws -> LocationPrivateArchive? { try file.read() }
    /// Explicit device consent, outside task snapshots and portable backups. Existing
    /// v1 files load with consent off; reset mints a new installation with consent off.
    @discardableResult func setAllowance(account: String, enabled: Bool, expectedDevice: String?) throws -> LocationPrivateArchive {
        guard LocationReminderIdentity.account(account) else { throw LocationStorageFailure.changed }
        return try file.transaction { current in
            guard current?.device == expectedDevice, current != nil || enabled else { throw LocationStorageFailure.changed }
            var next = current ?? LocationPrivateArchive()
            var accounts = next.allowedAccounts ?? []
            accounts.removeAll { $0 == account }
            if enabled {
                guard accounts.count < 50 else { throw LocationStorageFailure(message: "Location reminders are enabled for too many workspaces on this device. Turn one off before adding another.") }
                accounts.append(account)
            }
            next.version = 2; next.allowedAccounts = accounts.sorted()
            return (next, next)
        }
    }

    func places(account: String) throws -> [LocationPrivatePlace] {
        guard LocationReminderIdentity.account(account) else { throw LocationStorageFailure.unreadable }
        return try file.read()?.places(for: account) ?? []
    }
    @discardableResult func save(_ place: LocationPrivatePlace, replacing original: LocationPrivatePlace? = nil) throws -> LocationPrivateArchive {
        try file.transaction { current in
            var next = current ?? LocationPrivateArchive()
            if let index = next.places.firstIndex(where: { $0["id"] == .string(place.id) }) {
                if next.places[index] == place.raw { return (next, next) } // Idempotent retry after an uncertain commit.
                guard let original, original.account == place.account, original.id == place.id, next.places[index] == original.raw else { throw LocationStorageFailure.changed }
                next.places[index] = place.raw
            } else {
                guard original == nil, next.places.count < LocationPrivateArchive.maximumPlaces else { throw LocationStorageFailure(message: "This device can save up to 50 places. Remove a place before adding another.") }
                next.places.append(place.raw)
            }
            return (next, next)
        }
    }
    func delete(_ place: LocationPrivatePlace) throws {
        try file.transaction { current in
            guard var next = current, let index = next.places.firstIndex(where: { $0["id"] == .string(place.id) }), next.places[index] == place.raw else { throw LocationStorageFailure.changed }
            next.places.remove(at: index); return (next, ())
        }
    }
    func clearPlaces(account: String) throws {
        guard LocationReminderIdentity.account(account) else { throw LocationStorageFailure.unreadable }
        try file.transaction { current in
            guard var next = current else { throw LocationStorageFailure.changed }
            next.places.removeAll { $0["account"] == .string(account) }; return (next, ())
        }
    }
    /// The engine is the only journal writer. Reject stale processes rather than losing
    /// another acknowledged preparation or rewinding a submitted/closed one-shot.
    func saveJournal(_ journal: LocationReminderJournal) throws {
        try file.transaction { current in
            guard var next = current, journal.valid, journal.device == next.device, journal.version >= next.journal.version,
                  Set(next.journal.revoked ?? []).isSubset(of: Set(journal.revoked ?? [])) else { throw LocationStorageFailure.changed }
            let rank: [LocationReminderJournal.Phase: Int] = [.prepared: 0, .reserved: 1, .installed: 2, .closed: 3]
            for (id, old) in next.journal.entries {
                guard let updated = journal.entries[id], updated.ticket == old.ticket, rank[updated.phase]! >= rank[old.phase]!, old.phase != .closed || updated == old else { throw LocationStorageFailure.changed }
            }
            for (id, entry) in journal.entries where next.journal.entries[id] == nil {
                guard entry.phase == .prepared || entry.phase == .closed && entry.reason == .cancelled && journal.revoked?.contains(id) == true else { throw LocationStorageFailure.changed }
            }
            next.journal = journal; return (next, ())
        }
    }
    func resetAllPrivateData(confirmed: Bool) throws -> LocationPrivateArchive {
        guard confirmed else { throw LocationStorageFailure.changed }; return try file.reset()
    }
}
