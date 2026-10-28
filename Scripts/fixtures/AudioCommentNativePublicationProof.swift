import Foundation
@testable import TaskfoldCore

/// Owned loopback test adapter only. Production Backend still constructs and
/// validates its fixed HTTPS request, current session and authenticated receipt.
private final class NativePublicationHTTP: URLProtocol {
    static var endpoint = ""
    static var loseReply = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var operation: URLSessionDataTask?
    private var forwarding: URLSession?
    override func stopLoading() { operation?.cancel(); forwarding?.invalidateAndCancel() }
    override func startLoading() {
        guard request.url?.absoluteString == "https://native-publication.example.invalid/functions/v1/audio-comments?action=publish",
              let components = URLComponents(string: Self.endpoint), components.scheme == "http", components.host == "127.0.0.1", components.port != nil,
              let destination = URL(string: Self.endpoint + "/?action=publish") else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
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
            if Self.loseReply && response.statusCode == 200 { self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            let incoming = HTTPURLResponse(url: self.request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
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
        let clip = try await AudioCommentDecoding.validate(Data(contentsOf: URL(fileURLWithPath: args[2])))
        let target = try AudioCommentTarget(record: Record(config["target"].object))
        let source = try AudioCommentSavedDraft(owner: .init(config.string("account")), target: target, caption: config.string("caption"), clip: clip, id: UUID(uuidString: config.string("source"))!, revision: UUID(uuidString: config.string("revision"))!)
        let disk = try AudioCommentPublicationDisk(root: URL(fileURLWithPath: args[1]), account: UUID(uuidString: config.string("account"))!, origin: backend.baseURL)
        let incarnation = backend.reminderSessionIncarnation
        let flow = AudioCommentPublicationFlow(storage: .init(disk: disk), transport: backend, incarnation: incarnation, target: target, isCurrent: { backend.session?.user.id == config.string("account") && backend.reminderSessionIncarnation == incarnation })
        do { try await flow.publish(source); if NativePublicationHTTP.loseReply { throw AppFailure(message: "Expected a controlled lost reply") } }
        catch { if !NativePublicationHTTP.loseReply { throw error } }
        guard let stored = try disk.journals().first else { throw AppFailure(message: "Missing native publication journal") }
        let result = Record(["operation_id": .string(stored.publication.operation.uuidString.lowercased()), "comment_id": .string(stored.publication.comment.uuidString.lowercased()), "published": .bool(stored.receipt != nil), "has_audio": .bool(stored.clip != nil), "caption": .string(stored.publication.caption), "sha256": .string(stored.publication.descriptor.sha256)])
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
}
