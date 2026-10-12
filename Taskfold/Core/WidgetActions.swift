import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A credential-free handoff. Account and task identities are checked again by the app.
public struct WidgetCompletionRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var account: String
    public var taskID: String
    public var token: String
    public var createdAt: Date
    public init(account: String, taskID: String, token: String, at date: Date = Date()) throws {
        guard !account.isEmpty, !taskID.isEmpty, let id = UUID(uuidString: token) else { throw WidgetActionFailure("Refresh this widget before completing a task.") }
        self.id = id; self.account = account; self.taskID = taskID; self.token = token; self.createdAt = date
    }
    public func matches(_ other: WidgetCompletionRequest) -> Bool { account == other.account && taskID.lowercased() == other.taskID.lowercased() && token == other.token }
}
public struct WidgetActionFailure: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct WidgetActionRead {
    public var data: Data?
    public var pendingTaskIDs: [String]
}

/// A short-lived acknowledgement of a durably saved widget action, never a pending tap.
public struct WidgetCompletionFeedback: Codable, Equatable, Sendable {
    public var account: String
    public var taskID: String
    public var title: String
    public var listIDs: [String]
    public var savedAt: Date
    public var expiresAt: Date { savedAt.addingTimeInterval(8) }
    public func visible(account: String, listID: String?, at date: Date) -> Bool {
        !account.isEmpty && self.account == account && listID.map(listIDs.contains) == true && date >= savedAt && date < expiresAt
    }
    public static func capture(_ request: WidgetCompletionRequest, projection: Data?, at date: Date = Date()) -> Self? {
        struct Projection: Decodable {
            struct Task: Decodable { var id: String; var title: String; var completionToken: String? }
            struct List: Decodable { var id: String; var days: [String: [String]]; var timeZone: String }
            var account: String; var tasks: [Task]; var lists: [List]
        }
        guard let projection, let value = try? JSONDecoder().decode(Projection.self, from: projection),
              value.account == request.account,
              let task = value.tasks.first(where: { $0.id.lowercased() == request.taskID.lowercased() && $0.completionToken == request.token }) else { return nil }
        let lists = value.lists.filter { list in
            guard let zone = TimeZone(identifier: list.timeZone) else { return false }
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
            return (list.days["*"] ?? list.days[formatter.string(from: date)])?.contains(task.id) == true
        }.map(\.id)
        return Self(account: request.account, taskID: task.id, title: task.title, listIDs: lists, savedAt: date)
    }
}

/// Locks both snapshot reads and queue updates across the app/extension processes.
/// Cache credentials and executable task mutations never enter this directory.
public final class WidgetActionDisk: @unchecked Sendable {
    public static let group = "group.com.dbakp.taskfold"
    public static let capacity = 128
    private static let processLock = NSLock()
    private let directory: URL
    private struct Queue: Codable { var version = 1; var requests: [WidgetCompletionRequest] = [] }
    private struct Projection: Decodable {
        struct Task: Decodable { var id: String; var completionToken: String? }
        var version: Int; var account: String; var tasks: [Task]
        private enum CodingKeys: String, CodingKey { case version, account, tasks }
        init(from decoder: Decoder) throws {
            let row = try decoder.container(keyedBy: CodingKeys.self)
            version = try row.decodeIfPresent(Int.self, forKey: .version) ?? 1
            account = try row.decodeIfPresent(String.self, forKey: .account) ?? ""
            tasks = try row.decode([Task].self, forKey: .tasks)
        }
        func accepts(_ request: WidgetCompletionRequest) -> Bool {
            version == 2 && account == request.account && tasks.contains { $0.id.lowercased() == request.taskID.lowercased() && $0.completionToken == request.token }
        }
    }
    public init(directory: URL) { self.directory = directory }
    public static func system() throws -> WidgetActionDisk {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw WidgetActionFailure("Open Taskfold to refresh this widget's connection.")
        }
        return WidgetActionDisk(directory: directory)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("widget-actions.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WidgetActionFailure("This widget could not save its action. Open Taskfold and try again.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw WidgetActionFailure("This widget could not save its action. Open Taskfold and try again.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func queue() throws -> Queue {
        let url = directory.appendingPathComponent("widget-actions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Queue() }
        let queue = try JSONDecoder().decode(Queue.self, from: Data(contentsOf: url))
        guard queue.version == 1, queue.requests.count <= Self.capacity, Set(queue.requests.map(\.id)).count == queue.requests.count,
              queue.requests.allSatisfy({ UUID(uuidString: $0.token) == $0.id && !$0.account.isEmpty && !$0.taskID.isEmpty }) else {
            throw WidgetActionFailure("The widget action file needs attention. Open Taskfold before trying again.")
        }
        return queue
    }
    private func write(_ queue: Queue) throws {
        try JSONEncoder().encode(queue).write(to: directory.appendingPathComponent("widget-actions.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    public func publish(_ data: Data) throws {
        try locked { try data.write(to: directory.appendingPathComponent("widget.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
    public func clearProjection() throws {
        try locked {
            let url = directory.appendingPathComponent("widget.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    public func read() throws -> WidgetActionRead {
        try locked {
            let url = directory.appendingPathComponent("widget.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return WidgetActionRead(data: nil, pendingTaskIDs: []) }
            let data = try Data(contentsOf: url), projection = try JSONDecoder().decode(Projection.self, from: data)
            guard projection.version == 2, !projection.account.isEmpty else { return WidgetActionRead(data: data, pendingTaskIDs: []) }
            let pending = try queue().requests.filter { projection.accepts($0) }.map(\.taskID)
            return WidgetActionRead(data: data, pendingTaskIDs: pending)
        }
    }
    public func enqueue(_ request: WidgetCompletionRequest) throws -> WidgetCompletionRequest {
        try locked {
            var queue = try queue()
            let projection = try JSONDecoder().decode(Projection.self, from: Data(contentsOf: directory.appendingPathComponent("widget.json")))
            guard UUID(uuidString: request.token) == request.id, projection.accepts(request) else { throw WidgetActionFailure("This task or workspace changed. Refresh the widget before completing it.") }
            if let existing = queue.requests.first(where: { $0.id == request.id }) {
                guard existing.matches(request) else { throw WidgetActionFailure("Refresh the widget before completing this task.") }
                return existing
            }
            guard queue.requests.count < Self.capacity else { throw WidgetActionFailure("Open Taskfold to finish pending widget actions, then try again.") }
            queue.requests.append(request); try write(queue); return request
        }
    }
    public func pending(account: String) throws -> [WidgetCompletionRequest] { try locked { try queue().requests.filter { $0.account == account } } }
    public func acknowledge(_ request: WidgetCompletionRequest) throws {
        try locked {
            var queue = try queue()
            queue.requests.removeAll { $0.id == request.id && $0.matches(request) }
            try write(queue)
        }
    }
}

#if !SWIFT_PACKAGE
import AppIntents
struct CompleteWidgetTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete widget task"
    static let description = IntentDescription("Completes a task from the widget's current workspace.")
    static let isDiscoverable = false
    static let openAppWhenRun = false
    @available(iOS 26, macOS 26, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @available(iOS 27, macOS 27, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Workspace") var account: String
    @Parameter(title: "Task") var taskID: String
    @Parameter(title: "Completion") var token: String
    init() {}
    init(account: String, taskID: String, token: String) { self.account = account; self.taskID = taskID; self.token = token }
    @MainActor func perform() async throws -> some IntentResult {
        let request = try WidgetCompletionRequest(account: account, taskID: taskID, token: token)
        #if TASKFOLD_WIDGET_EXTENSION
        _ = try WidgetActionDisk.system().enqueue(request)
        #else
        try Store.shared.performWidgetCompletion(request)
        #endif
        return .result()
    }
}
#if !TASKFOLD_WIDGET_EXTENSION
@available(iOSApplicationExtension, unavailable)
@available(macOSApplicationExtension, unavailable)
@available(*, deprecated)
extension CompleteWidgetTaskIntent: ForegroundContinuableIntent {}
#endif
#endif
