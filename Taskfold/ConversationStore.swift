import SwiftUI

extension Store {
    var conversationsAvailable: Bool {
        #if DEBUG
        if ConversationFixture.enabled { return focusAvailable }
        #endif
        return focusAvailable && signedIn && !localMode && UUID(uuidString: userID) != nil
    }
    var conversationsOnline: Bool {
        #if DEBUG
        if ConversationFixture.enabled { _ = conversationFixtureRevision; return !UserDefaults.standard.bool(forKey: "conversation.fixture.paused") }
        #endif
        return online
    }
    var conversationSending: Bool { conversationSyncGeneration == workspaceGeneration && conversationSyncID != nil }
    var conversationOutbox: [Record] { ConversationOutbox.rows(snapshot, account: userID) }
    var mentionSummary: Record? { conversationMeta("summary") }
    var mentionUnreadCount: Int? { mentionSummary.flatMap { try? ConversationSummary($0).unread } }
    var conversationMentions: [SharedMention] { rows(SharedMention.table).compactMap(SharedMention.init).filter { $0.recipientID == userID }.sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt } }
    func conversationTask(_ comment: SharedComment) -> Record? { ConversationCache.accessible(comment, snapshot: presentationSnapshot) }
    func conversationComments(_ task: Record) -> [SharedComment] {
        rows(SharedComment.table).compactMap(SharedComment.init).filter { $0.taskID == task.id.lowercased() && $0.taskGeneration == task.string("task_generation").lowercased() && $0.projectID == task.string("project_id").lowercased() && !$0.isDeleted }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }
    func conversationName(_ id: String?, project: String) -> String {
        guard let id else { return "Name unavailable" }; if id == userID { return "You" }
        return projectMembers(project).first { $0.id.lowercased() == id }?.string("display_name") ?? "Collaborator"
    }
    func conversationMeta(_ scope: String) -> Record? { rows(ConversationOutbox.viewsTable).first { $0.id == scope && $0.string("account") == userID && $0["version"] == .number(1) && $0["access_token"].text == (workspaceAccessToken ?? "") } }
    func conversationScope(_ task: Record) -> String { "thread:" + task.id.lowercased() + ":" + task.string("task_generation").lowercased() }
    func conversationHasMore(_ scope: String) -> Bool { conversationMeta(scope)?["has_more"].flag ?? false }
    func conversationWritable(taskID: String, generation: String, project: String) -> Bool {
        guard let task = record("tasks", id: taskID), task.string("task_generation").lowercased() == generation.lowercased(),
              task.string("project_id").lowercased() == project.lowercased(), record("projects", id: project) != nil else { return false }
        return nativeConversationTeamCache?.nativeConversationWritable(project:project) != false && !ProjectOrganization.archivedIDs(in: allProjects).contains(project)
    }
    @discardableResult private func commitConversation(_ edit: (inout Snapshot) throws -> Void) -> Bool {
        let before = snapshot
        do { var next = snapshot; try edit(&next); ConversationCache.prune(&next); snapshot = next; try persist(); return true }
        catch { snapshot = before; conversationError = error.localizedDescription; return false }
    }
    @discardableResult func saveConversation(_ change: SharedCommentChange, workspace: WorkspaceBinding, draft: Bool = false, replacing oldID: String? = nil) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), conversationsAvailable, change.account == userID else { conversationError = "Reopen this conversation in your current workspace."; return false }
        if !draft {
            guard let task = record("tasks", id: change.taskID), task.string("task_generation").lowercased() == change.taskGeneration,
                  task.string("project_id").lowercased() == change.projectID, conversationWritable(taskID: change.taskID, generation: change.taskGeneration, project: change.projectID) else { conversationError = "This task changed or is unavailable. Keep your text as a draft."; return false }
        }
        guard commitConversation({ next in
            if let oldID {
                guard let old = ConversationOutbox.rows(next, account: userID).first(where: { $0.id == oldID }), old.string("state") != "pending" else { throw AppFailure(message: "Wait for the saved attempt before editing it.") }
                ConversationOutbox.remove(oldID, account: userID, from: &next)
            }
            try ConversationOutbox.enqueue(change.record, into: &next)
            if draft { ConversationOutbox.setState(change.operationID, account: userID, state: "draft", in: &next) }
        }) else { return false }
        if !draft { Task { await sync(); await syncConversations() } }; return true
    }
    @discardableResult func markConversationMention(_ mention: SharedMention, read: Bool, workspace: WorkspaceBinding) -> Bool {
        guard workspace.matches(account: userID, generation: workspaceGeneration), conversationsAvailable, conversationMentions.contains(where:{$0.id==mention.id}) else { return false }
        do {
            let change = try SharedMentionChange(mention: mention, account: userID, read: read)
            guard commitConversation({ try ConversationOutbox.enqueue(change.record, into: &$0, origin: try? backend.accountRemovalOrigin) }) else { return false }
            Task { await syncConversations() }; return true
        } catch { conversationError = error.localizedDescription; return false }
    }
    func discardConversation(_ id: String, workspace: WorkspaceBinding) {
        guard workspace.matches(account: userID, generation: workspaceGeneration), !conversationSending else { return }
        _ = commitConversation { ConversationOutbox.remove(id, account: userID, from: &$0) }
    }
    func retryConversation(_ id: String, workspace: WorkspaceBinding) {
        guard workspace.matches(account: userID, generation: workspaceGeneration), let row = conversationOutbox.first(where: { $0.id == id }), row.string("state") == "pending" else { return }
        Task { await sync(); await syncConversations() }
    }
    func syncConversations() async {
        guard conversationsAvailable, conversationsOnline, !conversationSending else { return }
        let accessRevision=workspaceReadRevision, accessToken=workspaceAccessToken
        let token = UUID(), binding = WorkspaceBinding(account: userID, generation: workspaceGeneration), account = userID
        conversationSyncID = token; conversationSyncGeneration = workspaceGeneration; conversationError = nil
        var attempted = Set<String>(), completed = false
        defer {
            if conversationSyncID == token {
                conversationSyncID = nil
                // A composer can save another intent while the summary request is in flight.
                if binding.matches(account: userID, generation: workspaceGeneration), (accessRevision != workspaceReadRevision || (completed && conversationOutbox.contains(where: { $0.string("state") == "pending" && !attempted.contains($0.id) }))) {
                    Task { await syncConversations() }
                }
            }
        }
        do {
            while let row = conversationOutbox.first(where: { $0.string("state") == "pending" && !attempted.contains($0.id) }) {
                attempted.insert(row.id)
                guard accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration), conversationSyncID == token else { return }
                if let change = ConversationOutbox.comment(row) {
                    guard conversationWritable(taskID:change.taskID,generation:change.taskGeneration,project:change.projectID) else {continue}
                    if snapshot.pending.contains(where: { $0.table == "tasks" && $0.recordID.lowercased() == change.taskID }) { continue }
                    let reply: SharedCommentReply
                    #if DEBUG
                    if ConversationFixture.enabled { reply = try fixtureCommentReply(change) } else { reply = try await backend.writeSharedComment(change) }
                    #else
                    reply = try await backend.writeSharedComment(change)
                    #endif
                    guard accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration), conversationSyncID == token else { return }
                    guard commitConversation({ ConversationOutbox.apply(reply, change: change, to: &$0) }) else { return }
                } else if let change = ConversationOutbox.mention(row) {
                    guard conversationMentions.contains(where:{$0.id==change.mentionID}) else {continue}
                    let reply: SharedMentionReply
                    #if DEBUG
                    if ConversationFixture.enabled { reply = try fixtureMentionReply(change) } else { reply = try await backend.markSharedMention(change) }
                    #else
                    reply = try await backend.markSharedMention(change)
                    #endif
                    guard accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration), conversationSyncID == token else { return }
                    guard commitConversation({ next in
                        ConversationOutbox.apply(reply, change: change, to: &next)
                        if reply.status == .unavailable { next.tables[SharedMention.table]?.removeAll { $0.id == change.mentionID } }
                        next.tables[ConversationOutbox.viewsTable]?.removeAll { $0.id == "summary" }
                    }) else { return }
                } else { conversationError = "A saved conversation change needs a newer app. Its data is kept on this device." }
            }
            let summary: ConversationSummary
            #if DEBUG
            if ConversationFixture.enabled { summary = try fixtureConversationSummary() } else { summary = try await backend.sharedMentionsSummary(account: account) }
            #else
            summary = try await backend.sharedMentionsSummary(account: account)
            #endif
            guard accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration), conversationSyncID == token else { return }
            _ = commitConversation { next in
                next.tables[ConversationOutbox.viewsTable]?.removeAll { $0.id == "summary" }
                next.tables[ConversationOutbox.viewsTable, default: []].append(Record(["id": .string("summary"), "account": .string(account), "version": .number(1), "access_token": .string(accessToken ?? ""), "total": .number(Double(summary.total)), "unread": .number(Double(summary.unread)), "updated_at": .string(Dates.timestamp())]))
            }
            completed = true
        } catch { if !Task.isCancelled, !(error is CancellationError), accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration), conversationSyncID == token { conversationError = "Couldn’t connect or verify the response. Saved changes remain on this device. " + error.localizedDescription } }
    }
    func refreshConversation(_ task: Record?, earlier: Bool = false, selectedComment: String? = nil, unreadOnly: Bool = false) async {
        guard conversationsAvailable, conversationsOnline else { return }
        let accessRevision=workspaceReadRevision, accessToken=workspaceAccessToken
        let binding = WorkspaceBinding(account: userID, generation: workspaceGeneration), account = userID
        let scope = task.map(conversationScope) ?? (unreadOnly ? "inbox-unread" : "inbox")
        let prior = conversationMeta(scope)
        let baseline = snapshot
        let cursor = earlier ? prior.flatMap { ConversationCursor(Record($0["cursor"].object)) } : nil
        if earlier && cursor == nil { return }
        let pageToken = UUID(); conversationPageTokens[scope] = pageToken
        defer { if conversationPageTokens[scope] == pageToken { conversationPageTokens.removeValue(forKey: scope) } }
        do {
            let page: ConversationPage; var comments: [Record] = []
            #if DEBUG
            if ConversationFixture.enabled {
                page = fixtureConversationPage(task, unreadOnly: unreadOnly)
            } else if let task { page = try await backend.sharedCommentsPage(task: task, account: account, cursor: cursor) }
            else { page = try await backend.sharedMentionsPage(account: account, cursor: cursor, unreadOnly: unreadOnly) }
            #else
            if let task { page = try await backend.sharedCommentsPage(task: task, account: account, cursor: cursor) }
            else { page = try await backend.sharedMentionsPage(account: account, cursor: cursor, unreadOnly: unreadOnly) }
            #endif
            #if DEBUG
            if ConversationFixture.enabled, ProcessInfo.processInfo.arguments.contains("--conversation-access-testing"), conversationFixtureHolding {
                await withCheckedContinuation { continuation in conversationFixtureHolding=false;conversationFixtureWaiting=true;conversationFixtureRelease=continuation }
            }
            #endif
            guard !Task.isCancelled, accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration), conversationPageTokens[scope] == pageToken else { return }
            if task == nil {
                let ids = page.rows.map { $0.string("comment_id") }
                #if DEBUG
                if ConversationFixture.enabled { comments = rows(SharedComment.table).filter { ids.contains($0.id) } }
                else { comments = try await backend.sharedComments(ids: ids, account: account) }
                #else
                comments = try await backend.sharedComments(ids: ids, account: account)
                #endif
            } else if let selectedComment, !page.rows.contains(where: { $0.id == selectedComment }) {
                #if DEBUG
                if ConversationFixture.enabled { comments = rows(SharedComment.table).filter { $0.id == selectedComment } }
                else { comments = try await backend.sharedComments(ids: [selectedComment], account: account) }
                #else
                comments = try await backend.sharedComments(ids: [selectedComment], account: account)
                #endif
            }
            guard !Task.isCancelled, accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration), conversationPageTokens[scope] == pageToken else { return }
            if let task {
                guard let current = record("tasks", id: task.id), current.string("task_generation") == task.string("task_generation"), current.string("project_id") == task.string("project_id") else { return }
            }
            _ = commitConversation { next in
                if let task {
                    if !earlier {
                        let incoming = Set((page.rows + comments).map(\.id))
                        next.tables[SharedComment.table]?.removeAll { row in
                            guard row.string("task_id") == task.id, row.string("task_generation") == task.string("task_generation"), !incoming.contains(row.id),
                                  let old = baseline.tables[SharedComment.table]?.first(where: { $0.id == row.id }) else { return false }
                            return (TaskActivity.integer(row["revision"]) ?? 0) <= (TaskActivity.integer(old["revision"]) ?? 0)
                        }
                    }
                    for row in page.rows + comments { ConversationCache.upsert(row, table: SharedComment.table, in: &next) }
                } else {
                    if !earlier {
                        let incoming = Set(page.rows.map(\.id))
                        next.tables[SharedMention.table]?.removeAll { row in
                            guard (!unreadOnly || row["read_at"] == .null), !incoming.contains(row.id), let old = baseline.tables[SharedMention.table]?.first(where: { $0.id == row.id }) else { return false }
                            return (TaskActivity.integer(row["revision"]) ?? 0) <= (TaskActivity.integer(old["revision"]) ?? 0)
                        }
                    }
                    let requested = Set(page.rows.map { $0.string("comment_id") })
                    // Replace requested comment identities first: an omitted/removed row must not keep an old body.
                    let returned = Set(comments.map(\.id))
                    next.tables[SharedComment.table]?.removeAll { row in
                        guard requested.contains(row.id), !returned.contains(row.id), let previous = baseline.tables[SharedComment.table]?.first(where: { $0.id == row.id }) else { return false }
                        return (TaskActivity.integer(row["revision"]) ?? 0) <= (TaskActivity.integer(previous["revision"]) ?? 0)
                    }
                    for row in comments { ConversationCache.upsert(row, table: SharedComment.table, in: &next) }
                    for row in page.rows { ConversationCache.upsert(row, table: SharedMention.table, in: &next) }
                }
                next.tables[ConversationOutbox.viewsTable]?.removeAll { $0.id == scope }
                next.tables[ConversationOutbox.viewsTable, default: []].append(Record(["id": .string(scope), "version": .number(1), "account": .string(account), "access_token": .string(accessToken ?? ""), "has_more": .bool(page.hasMore), "cursor": page.cursor?.document ?? .null, "updated_at": .string(Dates.timestamp())]))
                ConversationCache.prune(&next)
            }
        } catch { if !Task.isCancelled, !(error is CancellationError), accessRevision==workspaceReadRevision, binding.matches(account: userID, generation: workspaceGeneration) { conversationError = "Conversation refresh failed. Saved content is kept. " + error.localizedDescription } }
    }
}

#if DEBUG
enum ConversationFixture {
    static let owner = "f1799000-0000-4000-8000-000000000001"
    static let member = "f1799000-0000-4000-8000-000000000002"
    static let project = "f1799000-0000-4000-8000-000000000010"
    static let task = "f1799000-0000-4000-8000-000000000020"
    static var enabled: Bool { (Bundle.main.bundleIdentifier ?? "").contains(".workflowtests") && ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--conversation-testing") }
}
extension Store {
    func seedConversationFixture() {
        guard ConversationFixture.enabled else { return }
        dailyBackupsEnabled = false; disableNotifications(); disableFocusAlerts()
        guard ProcessInfo.processInfo.arguments.contains("--conversation-seed") else { return }
        UserDefaults.standard.set(ProcessInfo.processInfo.arguments.contains("--conversation-offline"), forKey: "conversation.fixture.paused")
        var task = Record.task(user: userID, project: ConversationFixture.project); task["id"] = .string(ConversationFixture.task); task["title"] = .string("Review the launch notes")
        let now = Dates.timestamp(), commentID = UUID().uuidString.lowercased()
        snapshot = Snapshot(tables: ["tasks": [task], "projects": [Record(["id": .string(ConversationFixture.project), "user_id": .string(userID), "name": .string("Launch studio")])],
            "project_members:" + ConversationFixture.project: [Record(["user_id": .string(ConversationFixture.member), "display_name": .string("Morgan Lee"), "status": .string("accepted")])],
            SharedComment.table: [Record(["id": .string(commentID), "task_id": .string(task.id), "task_generation": task["task_generation"], "project_id": task["project_id"], "author_id": .string(ConversationFixture.member), "body": .string("Could you review the launch notes before our next check-in?"), "mention_ids": .array([.string(userID)]), "revision": .number(1), "created_at": .string(now), "updated_at": .string(now), "deleted_at": .null])],
            SharedMention.table: [Record(["id": .string(UUID().uuidString.lowercased()), "comment_id": .string(commentID), "recipient_id": .string(userID), "revision": .number(1), "created_at": .string(now), "read_at": .null])]])
        if ProcessInfo.processInfo.arguments.contains("--conversation-conflict-seed"), var own = snapshot.tables[SharedComment.table]?.first {
            own["id"] = .string("f1799000-0000-4000-8000-000000000040"); own["author_id"] = .string(userID); own["body"] = .string("Latest notes from the other device"); own["mention_ids"] = .array([.string(ConversationFixture.member)]); own["revision"] = .number(2)
            snapshot.tables[SharedComment.table, default: []].append(own)
            if let intent = try? SharedCommentChange(account: userID, taskID: task.id, taskGeneration: task.string("task_generation"), projectID: ConversationFixture.project, commentID: own.id, expectedRevision: 1, body: "My retained offline review", mentionIDs: [ConversationFixture.member]) {
                try? ConversationOutbox.enqueue(intent.record, into: &snapshot)
                ConversationOutbox.setState(intent.operationID, account: userID, state: "conflict", in: &snapshot)
            }
        }
        undoStack = []; redoStack = []; try? persist()
    }
    private func fixtureConversationSummary() throws -> ConversationSummary { try ConversationSummary(Record(["total": .number(Double(conversationMentions.count)), "unread": .number(Double(conversationMentions.filter { !$0.isRead }.count))])) }
    private func fixtureConversationPage(_ task: Record?, unreadOnly: Bool) -> ConversationPage { ConversationPage(rows: task.map { task in rows(SharedComment.table).filter { $0.string("task_id") == task.id } } ?? rows(SharedMention.table).filter { !unreadOnly || $0["read_at"] == .null }, cursor: nil) }
    private func fixtureCommentReply(_ change: SharedCommentChange) throws -> SharedCommentReply {
        let existing = record(SharedComment.table, id: change.commentID), now = Dates.timestamp()
        if let existing, (TaskActivity.integer(existing["revision"]) ?? 0) != change.expectedRevision {
            return try SharedCommentReply(data: JSONEncoder().encode(Record(["status": .string("conflict"), "current": .object(existing.fields)])), change: change)
        }
        var row = existing ?? Record(["id": .string(change.commentID), "task_id": .string(change.taskID), "task_generation": .string(change.taskGeneration), "project_id": .string(change.projectID), "author_id": .string(userID), "created_at": .string(now)])
        let revision = (existing.flatMap { TaskActivity.integer($0["revision"]) } ?? 0) + 1
        row["body"] = .string(change.body); row["mention_ids"] = .array(change.mentionIDs.map(JSON.string)); row["revision"] = .number(Double(revision)); row["updated_at"] = .string(now); row["deleted_at"] = change.deleting ? .string(now) : .null
        return try SharedCommentReply(data: JSONEncoder().encode(Record(["status": .string("saved"), "operation_id": .string(change.operationID), "acknowledged_revision": .number(Double(revision)), "current": .object(row.fields)])), change: change)
    }
    private func fixtureMentionReply(_ change: SharedMentionChange) throws -> SharedMentionReply {
        guard var row = record(SharedMention.table, id: change.mentionID) else { return try SharedMentionReply(data: Data(#"{"status":"unavailable"}"#.utf8), change: change) }
        let revision = (TaskActivity.integer(row["revision"]) ?? 0) + 1; row["read_at"] = change.read ? .string(Dates.timestamp()) : .null; row["revision"] = .number(Double(revision))
        return try SharedMentionReply(data: JSONEncoder().encode(Record(["status": .string("saved"), "operation_id": .string(change.operationID), "acknowledged_revision": .number(Double(revision)), "current": .object(row.fields)])), change: change)
    }
}
#endif
