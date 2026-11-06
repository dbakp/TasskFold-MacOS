import Foundation

/// Shares only in-flight reads. A later refresh always starts a new operation.
/// Each store owns its pool; keys also fence account, provider and access changes.
@MainActor final class ProjectMemberReads {
    struct Scope: Hashable, Sendable {
        let account: String
        let generation: UUID
        let access: UUID
        let session: UUID
        let origin: String
        let project: String
    }
    private struct Entry {
        let id: UUID
        let task: Task<[Record], Error>
        var waiters: Set<UUID>
    }
    private var entries: [Scope: Entry] = [:]
    var pendingCount: Int { entries.count }
    var waiterCount: Int { entries.values.reduce(0) { $0 + $1.waiters.count } }

    func load(_ scope: Scope, operation: @escaping @MainActor () async throws -> [Record]) async throws -> [Record] {
        try Task.checkCancellation()
        guard !scope.account.isEmpty, !scope.project.isEmpty else { throw CancellationError() }
        let waiter = UUID()
        let id: UUID
        let task: Task<[Record], Error>
        if var entry = entries[scope] {
            id = entry.id; task = entry.task
            entry.waiters.insert(waiter); entries[scope] = entry
        } else {
            id = UUID(); task = Task {
                try Task.checkCancellation()
                let value = try await operation()
                try Task.checkCancellation()
                return value
            }
            entries[scope] = Entry(id: id, task: task, waiters: [waiter])
        }
        defer { release(scope, id: id, waiter: waiter) }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }, onCancel: {
            Task { @MainActor [weak self] in self?.release(scope, id: id, waiter: waiter) }
        })
    }

    private func release(_ scope: Scope, id: UUID, waiter: UUID) {
        guard var entry = entries[scope], entry.id == id, entry.waiters.remove(waiter) != nil else { return }
        if entry.waiters.isEmpty {
            entries.removeValue(forKey: scope)
            entry.task.cancel()
        } else { entries[scope] = entry }
    }
    func cancelAll() {
        let tasks = entries.values.map(\.task)
        entries.removeAll()
        for task in tasks { task.cancel() }
    }
}

enum ProjectMemberDemand {
    static func needsDirectory(expression: String?, fields: [String], context: FilterContext) -> Bool {
        guard let expression else { return fields.contains { ["assignee", "assigned_by", "assignee_name"].contains($0) } }
        guard var parser = try? FilterParser(expression, context: context) else { return false }
        _ = try? parser.parse()
        return parser.needsPeopleDirectory
    }
}
