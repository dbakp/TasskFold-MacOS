import Foundation
@testable import TaskfoldCore

/// Owned loopback test adapter only. Production Backend still constructs and
/// validates its fixed HTTPS request, current session and authenticated receipt.
private final class NativePublicationHTTP: URLProtocol {
    static var endpoint = ""
    static var loseReply = false
    static var loseRemovalReply = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var operation: URLSessionDataTask?
    private var forwarding: URLSession?
    override func stopLoading() { operation?.cancel(); forwarding?.invalidateAndCancel() }
    override func startLoading() {
        guard let requestURL = request.url, let requested = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              requested.scheme == "https", requested.host == "native-publication.example.invalid", requested.path == "/functions/v1/audio-comments", let action = requested.queryItems?.first(where: { $0.name == "action" })?.value, ["publish", "list", "page", "download", "remove"].contains(action),
              let components = URLComponents(string: Self.endpoint), components.scheme == "http", components.host == "127.0.0.1", components.port != nil,
              let destination = URL(string: Self.endpoint + "/?action=" + action) else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 65536); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) } }
        guard body.count <= 10_730_668 else { client?.urlProtocol(self, didFailWithError: URLError(.dataLengthExceedsMaximum)); return }
        var outgoing = URLRequest(url: destination); outgoing.httpMethod = "POST"; outgoing.httpBody = body; outgoing.allHTTPHeaderFields = request.allHTTPHeaderFields; outgoing.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration); forwarding = session
        operation = session.dataTask(with: outgoing) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            guard let data, let response = response as? HTTPURLResponse else { self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
            if ((action == "publish" && Self.loseReply) || (action == "remove" && Self.loseRemovalReply)) && response.statusCode == 200 { self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            let incoming = HTTPURLResponse(url: self.request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: ["Content-Type": response.value(forHTTPHeaderField: "Content-Type") ?? "", "Cache-Control": "no-store", "X-Audio-SHA256": response.value(forHTTPHeaderField: "X-Audio-SHA256") ?? ""])!
            self.client?.urlProtocol(self, didReceive: incoming, cacheStoragePolicy: .notAllowed); self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
        }; operation?.resume()
    }
}
@main struct AudioCommentNativePublicationProof {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments, config = try JSONDecoder().decode(Record.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        NativePublicationHTTP.endpoint = config.string("endpoint"); NativePublicationHTTP.loseReply = config["lose_reply"] == .bool(true)
        let sessionRecord: Record = .init(["access_token": config["token"], "refresh_token": .string("synthetic-refresh"), "expires_in": .number(3600), "user": .object(["id": config["account"]])])
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(sessionRecord))
        let http = URLSessionConfiguration.ephemeral; http.protocolClasses = [NativePublicationHTTP.self]
        let backend = Backend(configuration: ["URL": "https://native-publication.example.invalid", "Key": "synthetic-public"], http: URLSession(configuration: http), session: session, persistSession: { _ in })
        if config["read_only"] == .bool(true) {
            let account=UUID(uuidString:config.string("account"))!,target=try AudioCommentTarget(record:Record(config["target"].object)),incarnation=backend.reminderSessionIncarnation
            let page=try await backend.pageAudio(account:account,target:target,after:nil,origin:backend.baseURL,incarnation:incarnation)
            guard page.items.count==1,let row=page.items.first else { throw AppFailure(message:"Missing shared native recording") }
            let clip=try await backend.downloadAudio(row,origin:backend.baseURL,incarnation:incarnation)
            guard clip.data == (try Data(contentsOf:URL(fileURLWithPath:args[2]))) else { throw AppFailure(message:"Shared native bytes changed") }
            var removalRefused=false
            do { _ = try await backend.removeAudio(row,origin:backend.baseURL,incarnation:incarnation) } catch { removalRefused=true }
            guard removalRefused else { throw AppFailure(message:"Shared read grant allowed removal") }
            print("{\"read_only_verified\":true,\"removal_refused\":true}");return
        }
        let clip = try await AudioCommentDecoding.validate(Data(contentsOf: URL(fileURLWithPath: args[2])))
        let target = try AudioCommentTarget(record: Record(config["target"].object))
        let source = try AudioCommentSavedDraft(owner: .init(config.string("account")), target: target, caption: config.string("caption"), clip: clip, id: UUID(uuidString: config.string("source"))!, revision: UUID(uuidString: config.string("revision"))!)
        let disk = try AudioCommentPublicationDisk(root: URL(fileURLWithPath: args[1]), account: UUID(uuidString: config.string("account"))!, origin: backend.baseURL)
        let incarnation = backend.reminderSessionIncarnation
        let flow = AudioCommentPublicationFlow(storage: .init(disk: disk), transport: backend, incarnation: incarnation, target: target, retainAudioOnConfirmation: config["retain_audio"] == .bool(true), isCurrent: { backend.session?.user.id == config.string("account") && backend.reminderSessionIncarnation == incarnation })
        do { try await flow.publish(source); if NativePublicationHTTP.loseReply { throw AppFailure(message: "Expected a controlled lost reply") } }
        catch { if !NativePublicationHTTP.loseReply { throw error } }
        if config["release_copy"] == .bool(true), let confirmed = try disk.journals().first { _ = try disk.releaseResolvedAudio(confirmed) }
        guard let stored = try disk.journals().first else { throw AppFailure(message: "Missing native publication journal") }
        if config["read_remote"] == .bool(true) {
            let page = try await backend.pageAudio(account: stored.publication.account, target: target, after: nil, origin: backend.baseURL, incarnation: incarnation)
            guard page.next == nil else { throw AppFailure(message: "Unexpected next page") }
            let rows = page.items
            guard rows.count == 1, let remote = rows.first, remote.id == stored.publication.comment, remote.publication.caption.utf8.elementsEqual(stored.publication.caption.utf8) else { throw AppFailure(message: "Remote list mismatch") }
            let downloaded = try await backend.downloadAudio(remote, origin: backend.baseURL, incarnation: incarnation)
            guard downloaded.data == clip.data else { throw AppFailure(message: "Remote bytes mismatch") }
            NativePublicationHTTP.loseRemovalReply = true
            var uncertainRemoval = false
            do { _ = try await backend.removeAudio(remote, origin: backend.baseURL, incarnation: incarnation) } catch { uncertainRemoval = true }
            NativePublicationHTTP.loseRemovalReply = false
            guard uncertainRemoval else { throw AppFailure(message: "Lost removal reply must remain uncertain") }
            let removed = try await backend.removeAudio(remote, origin: backend.baseURL, incarnation: incarnation)
            guard removed.comment == remote.id else { throw AppFailure(message: "Removal mismatch") }
            let empty = try await backend.listAudio(account: stored.publication.account, target: target, origin: backend.baseURL, incarnation: incarnation)
            guard empty.isEmpty else { throw AppFailure(message: "Removed comment remains visible") }
            var blocked = false
            do { _ = try await backend.downloadAudio(remote, origin: backend.baseURL, incarnation: incarnation) } catch { blocked = true }
            guard blocked else { throw AppFailure(message: "Removed recording remains readable") }
            guard let persisted = try disk.journals().first, persisted.publication.sameIntent(as: stored.publication), persisted.receipt?.record == stored.receipt?.record, persisted.clip?.data == stored.clip?.data else { throw AppFailure(message: "Remote actions changed private publication storage") }
        }
        let result = Record(["closed":.bool(stored.closedReceipt != nil), "intent":.object(stored.publication.record.fields), "remote_checked": .bool(config["read_remote"] == .bool(true)), "operation_id": .string(stored.publication.operation.uuidString.lowercased()), "comment_id": .string(stored.publication.comment.uuidString.lowercased()), "asset_id": .string(stored.publication.asset.uuidString.lowercased()), "published": .bool(stored.receipt != nil), "has_audio": .bool(stored.clip != nil), "caption": .string(stored.publication.caption), "sha256": .string(stored.publication.descriptor.sha256)])
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
}
