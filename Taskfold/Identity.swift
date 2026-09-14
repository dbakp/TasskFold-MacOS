import SwiftUI
import CryptoKit

extension Store {
    /// Provider metadata supplies presentation only; project access is always checked by the server.
    var accountName: String {
        if localMode { return "Local Workspace" }
        let metadata = backend.session?.user.user_metadata ?? [:]
        let identity = backend.session?.user.identities?.first { $0.provider == "google" }?.identity_data ?? [:]
        let candidates = [profile.string("display_name"), identity["full_name"]?.text, identity["name"]?.text,
                          metadata["full_name"]?.text, metadata["name"]?.text, localMode ? "Local Workspace" : backend.session?.user.email]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "My Account"
    }
    var accountIdentity: Record {
        Record(["user_id": .string(userID), "display_name": .string(accountName),
                "avatar_url": (localMode ? nil : (avatarURL ?? backend.session?.user.googleAvatarURL)).map { .string($0.absoluteString) } ?? .null])
    }
}

struct MemberCache: Codable {
    var people: [String: [Record]] = [:]
    var dates: [String: Date] = [:]
    var signatures: [String: String] = [:]
}

extension Workspace {
    private var memberCacheURL: URL { store.cacheURL.deletingLastPathComponent().appending(path: "members-\(store.userID).json") }
    func restoreMemberCache() {
        guard rosterAccount != store.userID else { return }
        rosterAccount = store.userID
        rosterCache = (try? Data(contentsOf: memberCacheURL)).flatMap { try? JSONDecoder().decode(MemberCache.self, from: $0) } ?? MemberCache()
        projectMembers = rosterCache.people
    }
    func persistMemberCache() {
        guard rosterAccount == store.userID else { return }
        rosterCache.people = projectMembers
        do {
            try FileManager.default.createDirectory(at: memberCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(rosterCache).write(to: memberCacheURL, options: .atomic)
        } catch { memberLoadError = "Names are available for this session, but couldn’t be saved for offline use." }
    }
    func refreshMemberDirectory(force projects: Set<String> = []) async {
        guard store.signedIn else { return }
        restoreMemberCache()
        guard !store.localMode else { return }
        guard store.online else { memberLoadError = "Offline. Showing cached names and photos; permissions are checked when changes sync."; return }
        let account = store.userID
        let available = Set(store.projects.map(\.id))
        projectMembers = projectMembers.filter { available.contains($0.key) }
        rosterCache.dates = rosterCache.dates.filter { available.contains($0.key) }
        rosterCache.signatures = rosterCache.signatures.filter { available.contains($0.key) }
        var failed = false
        for project in store.projects {
            guard !Task.isCancelled, store.userID == account else { return }
            let signature = ([project.string("user_id")] + store.rows("project_collaborators").filter { $0.string("project_id") == project.id }.map { [$0.id, $0.string("user_id"), $0.string("status"), $0.string("role")].joined(separator: ":") }.sorted()).joined(separator: "|")
            if !projects.contains(project.id), rosterCache.signatures[project.id] == signature,
               let date = rosterCache.dates[project.id], Date().timeIntervalSince(date) < 900 { continue }
            do {
                let data = try await store.backend.request("/rest/v1/rpc/taskfold_project_members", method: "POST", body: ["_project_id": .string(project.id)])
                guard !Task.isCancelled, store.userID == account else { return }
                projectMembers[project.id] = try JSONDecoder().decode([Record].self, from: data)
                rosterCache.dates[project.id] = Date(); rosterCache.signatures[project.id] = signature
            } catch { failed = true }
        }
        guard store.userID == account else { return }
        memberLoadError = failed ? "Some names and photos may be out of date. Cached identities are shown; retry when connected." : nil
        persistMemberCache()
    }
}

/// Small account-scoped photo cache; a failed refresh keeps an already downloaded photo available offline.
actor AvatarImages {
    static let shared = AvatarImages()
    private var memory: [String: (data: Data, date: Date)] = [:]
    func data(url: URL, account: String) async -> Data? {
        let key = SHA256.hash(data: Data((account + "|" + url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = memory[key], Date().timeIntervalSince(cached.date) < 86400 { return cached.data }
        let folder = URL.cachesDirectory.appending(path: "Taskfold/Avatars")
        let path = folder.appending(path: key)
        let fallback = try? Data(contentsOf: path)
        let modified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let fallback, Date().timeIntervalSince(modified) < 86400 { memory[key] = (fallback, modified); return fallback }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count < 5_000_000, response.mimeType?.hasPrefix("image/") == true, NSImage(data: data) != nil else { return fallback }
            if memory.count >= 128, let oldest = memory.min(by: { $0.value.date < $1.value.date })?.key { memory.removeValue(forKey: oldest) }
            memory[key] = (data, Date())
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: path, options: .atomic)
            return data
        } catch { return fallback }
    }
}

struct PersonAvatar: View {
    @Environment(Store.self) private var store
    let person: Record
    var size: CGFloat = 24
    var didLoad: ((Bool) -> Void)? = nil
    @State private var photo: NSImage?
    private var url: URL? { ProfileAvatar.url(person.string("avatar_url")) }
    private var name: String { person.string("display_name") }
    var body: some View {
        Group {
            if let photo { Image(nsImage: photo).resizable().scaledToFill() }
            else {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.15))
                    if name.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.secondary) }
                    else { Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.primary) }
                }
            }
        }.frame(width: size, height: size).clipShape(.circle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.isEmpty ? "Profile photo" : "Photo of \(name)")
        .accessibilityValue(photo == nil ? "Placeholder" : "Loaded")
        .task(id: store.userID + (url?.absoluteString ?? "")) {
            photo = nil; didLoad?(false)
            guard let url, let data = await AvatarImages.shared.data(url: url, account: store.userID), !Task.isCancelled else { return }
            photo = NSImage(data: data); didLoad?(photo != nil)
        }
    }
}
