#if DEBUG
import SwiftUI

/// Exists only in the reserved isolated host with an explicit launch flag and
/// bundled SQL-generated synthetic contract. Every HTTP request is intercepted.
@MainActor enum ProjectAdoptionNativeFixture {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--project-adoption-testing") }
    static let origin = "https://synthetic.example"
    static var packet: [String: JSON] {
        precondition(enabled)
        guard let url = Bundle.main.url(forResource: "ProjectAdoptionNative", withExtension: "json"), let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([String: JSON].self, from: data), p["syntheticOnly"] == .bool(true), p["containerRemoved"] == .bool(true), p["origin"] == .string(origin) else { preconditionFailure("Prepared synthetic contract required") }
        return p
    }
    static var account: String { packet["account"]!.text }
    static var team: String { packet["body"]!.object["team_id"]!.text }
    static var root: String { packet["body"]!.object["roots"]!.list[0].text }
    static var stateURL: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldProjectAdoptionNative", isDirectory: true).appendingPathComponent("server.json") }
    struct State: Codable {
        var version = 1
        var applied = false
        var attempts: [String] = []
        var requests: [String] = []
        var commands: [String: [String: JSON]] = [:]
        var revoked = false
        var lastInspection: [String: JSON]?
        var lastReview: [String: JSON]?
    }
    static func read() throws -> State { guard enabled else { throw CancellationError() }; return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) }
    static func write(_ state: State) throws { guard enabled else { throw CancellationError() }; try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(state).write(to: stateURL, options: .atomic) }
    static func reset() throws { try write(State()) }
    static func backend() -> Backend {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ProjectAdoptionNoNetwork.self]
        let s = try! JSONDecoder().decode(Session.self, from: JSONEncoder().encode(["access_token": JSON.string("synthetic-auth"), "refresh_token": .string("synthetic-refresh"), "expires_in": .number(3600), "user": .object(["id": .string(account)])]))
        return Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: c), session: s, persistSession: { _ in })
    }
    static func boundary(_ s: State) -> [String: JSON] {
        if s.revoked {
            return ["workspace_boundary_protocol": .number(1), "account": .string(account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "f", count: 64)), "teams": .array([]), "projects": .array([])]
        }
        return packet[s.applied ? "destination_boundary" : "source_boundary"]!.object
    }
    static func rows(_ s: State) -> [String: [Record]] {
        if s.revoked { return [:] }
        return packet[s.applied ? "destination_snapshot" : "source_snapshot"]!.object.mapValues { $0.list.map { Record($0.object) } }
    }
    static func reply(_ operation: String, _ b: [String: JSON]) throws -> ([String: JSON], Int) {
        var s = try read(); let p = packet
        if operation == "adopt" {
            guard let q = b["request_id"]?.text, TeamProjectValue.id(q) else { throw TeamProjectAdoptionValue.invalid }
            s.attempts.append(q); try write(s)
            if let old = s.commands[q] {
                guard old == b else { throw TeamProjectAdoptionValue.invalid }
                var r = p["receipt"]!.object; r["request_id"] = .string(q); r["replayed"] = .bool(true); return (r,200)
            }
            guard !s.applied, !s.revoked, let r = s.lastReview, b["review_token"] == r["review_token"], b["expires_at"] == r["expires_at"], b["inspection_token"] == r["inspection_token"], try TeamProjectAdoptionValue.date(b["expires_at"]) > Date(),
                  p["body"]!.object.allSatisfy({ b[$0.key] == $0.value }), b["decisions"] == .array(r["decisions"]!.list.map { .object($0.object.filter { $0.key != "effective_role" }) }) else { throw TeamProjectAdoptionValue.invalid }
            s.applied = true; s.commands[q] = b; try write(s)
            if ProcessInfo.processInfo.arguments.contains("--project-adoption-drop-reply") { return (["code": .string("synthetic_confirmation_lost")],503) }
            var result = p["receipt"]!.object; result["request_id"] = .string(q); return (result,200)
        }
        guard !s.applied, !s.revoked else { throw TeamProjectAdoptionValue.invalid }
        if operation == "inspect" {
            guard b == p["body"]!.object else { throw TeamProjectAdoptionValue.invalid }
            let i = p["inspect"]!.object; s.lastInspection = i; try write(s); return (i,200)
        }
        guard operation == "review", let i = s.lastInspection, b["inspection_token"] == i["inspection_token"], p["body"]!.object.allSatisfy({ b[$0.key] == $0.value }), let values = b["decisions"]?.list else { throw TeamProjectAdoptionValue.invalid }
        let inspected = try TeamProjectAdoptionInspection(i, scope: TeamProjectAdoptionScope(account: account, origin: origin, team: team, roots: [root], visibility: .private))
        let choices = try values.map { try TeamProjectAdoptionDecision($0.object) }; _ = try inspected.reviewBody(choices)
        var r = p["review"]!.object
        r["decisions"] = .array(choices.sorted { $0.id < $1.id }.map { d in var fields = d.body.object; fields["effective_role"] = p["review"]!.object["decisions"]!.list.first { $0.object["user_id"] == .string(d.user) }!.object["effective_role"]; return .object(fields) })
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        r["expires_at"] = .string(formatter.string(from: Date().addingTimeInterval(ProcessInfo.processInfo.arguments.contains("--project-adoption-short-review") ? 30 : 900)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        r["review_token"] = .string(CalendarOAuthConfiguration.digest(String(decoding: try encoder.encode(r), as: UTF8.self)))
        s.lastReview = r; try write(s); return (r,200)
    }
}
private final class ProjectAdoptionNoNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Task { @MainActor in
            guard ProjectAdoptionNativeFixture.enabled, request.url?.scheme == "https", request.url?.host == "synthetic.example" else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            do {
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating:0,count:4096); while stream.hasBytesAvailable && data.count <= 300000 { let n = stream.read(&bytes,maxLength:bytes.count); if n <= 0 { break }; data.append(contentsOf:bytes.prefix(n)) } }
                let b = data.isEmpty ? [:] : try JSONDecoder().decode([String: JSON].self, from: data), path = request.url!.path
                var result: JSON; var status = 200
                var s = try ProjectAdoptionNativeFixture.read(); s.requests.append((request.httpMethod ?? "GET") + " " + path); try ProjectAdoptionNativeFixture.write(s); let p = ProjectAdoptionNativeFixture.packet
                if request.httpMethod == "GET", path.hasPrefix("/rest/v1/"), !path.hasPrefix("/rest/v1/rpc/") {
                    let table = String(path.dropFirst("/rest/v1/".count))
                    guard Set(Backend.workspaceTables + [TaskAssignmentProvenance.table,SharedComment.table,SharedMention.table]).contains(table) else { throw TeamProjectAdoptionValue.invalid }
                    var rows = ProjectAdoptionNativeFixture.rows(s)[table,default:[]]
                    let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
                    if table == TaskActivity.table {
                        let cursor = Int64(query.first { $0.name == "sequence" }?.value?.replacingOccurrences(of:"gt.",with:"") ?? "0") ?? 0
                        rows = rows.filter { (TaskActivity.integer($0["sequence"]) ?? 0) > cursor }.sorted { (TaskActivity.integer($0["sequence"]) ?? 0) < (TaskActivity.integer($1["sequence"]) ?? 0) }
                    } else {
                        let key = table == "profiles" ? "user_id" : "id"
                        rows.sort { $0.string(key) < $1.string(key) }
                        let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
                        rows = Array(rows.dropFirst(max(0,offset)))
                    }
                    result = .array(rows.prefix(500).map { .object($0.fields) })
                } else if path == "/rest/v1/rpc/taskfold_workspace_boundary" { result = .object(ProjectAdoptionNativeFixture.boundary(s)) }
                else if path == "/rest/v1/rpc/taskfold_teams", b["_action"] == .string("get"), !s.revoked { result = p["team_detail"]! }
                else if path == "/rest/v1/rpc/taskfold_team_projects", b["_action"] == .string("list"), !s.revoked { result = p[s.applied ? "destination_page" : "source_page"]! }
                else if path == "/rest/v1/rpc/taskfold_team_project_adoption", let op = b["operation"]?.text { let reply = try ProjectAdoptionNativeFixture.reply(op,b["body"]!.object); result = .object(reply.0); status = reply.1 }
                else { throw TeamProjectAdoptionValue.invalid }
                finish(result,status:status)
            } catch { finish(.object(["code": .string("PT409")]),status:409) }
        }
    }
    private func finish(_ value: JSON,status: Int) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONEncoder().encode(value));client?.urlProtocolDidFinishLoading(self)
    }
}
struct ProjectAdoptionNativeFixtureView: View {
    @Environment(Store.self) private var store
    @State private var ready = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                if ready {
                    Section { NavigationLink("Open team projects") { TeamProjectManagementView(teamID: ProjectAdoptionNativeFixture.team) }.accessibilityIdentifier("openProjectTransferTeam") }
                    SavedProjectTransferLink()
                    Text("Queued edits: \(store.snapshot.pending.count)").accessibilityIdentifier("projectTransferQueue")
                    Text(store.allProjects.first(where: { $0.id == ProjectAdoptionNativeFixture.root })?.name ?? "Project unavailable").accessibilityIdentifier("projectTransferSavedProject")
                } else { ProgressView("Preparing isolated workspace…") }
                if let failure { Text(failure) }
            }.navigationTitle("Project transfer test")
        }.task {
            guard !ready else { return }
            do {
                if ProcessInfo.processInfo.arguments.contains("--team-editor-reset") { try await store.projectAdoptionVault.removeAccount(ProjectAdoptionNativeFixture.account,origin:ProjectAdoptionNativeFixture.origin) }
                ready = true
            } catch { failure = "Private fixture recovery could not be prepared." }
        }
    }
}
#endif
