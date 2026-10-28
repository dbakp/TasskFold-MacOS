import SwiftUI

struct ConversationRequest: Identifiable {
    let id = UUID()
    let workspace: WorkspaceBinding
    let taskID: String
    let generation: String
    let project: String
    var selectedComment: String? = nil
    init(task: Record, workspace: WorkspaceBinding, selectedComment: String? = nil) {
        taskID = task.id; generation = task.string("task_generation"); project = task.string("project_id"); self.workspace = workspace; self.selectedComment = selectedComment
    }
}
struct MentionsRequest: Identifiable { let id = UUID(); let workspace: WorkspaceBinding }
private struct MentionsActionKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues { var openMentions: () -> Void { get { self[MentionsActionKey.self] } set { self[MentionsActionKey.self] = newValue } } }
private struct ConversationComposerRequest: Identifiable {
    let id = UUID()
    let target: ConversationRequest
    let operationID = UUID().uuidString.lowercased()
    let newCommentID = UUID().uuidString.lowercased()
    var baseline: SharedComment?
    var saved: Record?
}

struct SharedConversationView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ConversationRequest
    var openTask: ((Record) -> Void)? = nil
    @State private var composer: ConversationComposerRequest?
    @State private var removing: SharedComment?
    @State private var loading = false
    @State private var audioConversation: AudioCommentConversationRequest?
    private var task: Record? {
        guard request.workspace.matches(account: store.userID, generation: store.workspaceGeneration),
              let task = store.record("tasks", id: request.taskID), task.string("task_generation") == request.generation,
              task.string("project_id") == request.project, store.record("projects", id: request.project) != nil else { return nil }
        return task
    }
    private var writable: Bool { store.conversationWritable(taskID: request.taskID, generation: request.generation, project: request.project) }
    private var active: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) }
    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let task {
                            Text(task.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversationTaskTitle")
                            Text(store.record("projects", id: request.project)?.name ?? "Project").font(.subheadline).foregroundStyle(.secondary)
                            ConversationStatus()
                            if let audio=store.audioConversationRequest(taskID:task.id) {
                                Button("Audio comments",systemImage:"waveform.bubble") { audioConversation=audio }.frame(minHeight:44).accessibilityIdentifier("sharedConversationAudio")
                            }
                            if !writable { Text("This conversation is read-only right now. You can keep unsent text as a private draft.").font(.footnote).foregroundStyle(.secondary) }
                            let comments = store.conversationComments(task)
                            if let selected = request.selectedComment, !comments.contains(where: { $0.id == selected }), !loading, store.conversationMeta(store.conversationScope(task)) != nil {
                                Text("This comment is no longer available. Other accessible comments appear below.").font(.footnote).foregroundStyle(.secondary)
                            }
                            if comments.isEmpty {
                                ContentUnavailableView("Start the conversation", systemImage: "bubble.left.and.bubble.right", description: Text("Share a thought or mention someone from this project."))
                            }
                            if store.conversationHasMore(store.conversationScope(task)) {
                                Button("Load earlier comments") { Task { loading = true; await store.refreshConversation(task, earlier: true); loading = false } }.frame(minHeight: 44).disabled(loading).accessibilityIdentifier("conversationEarlier")
                            }
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(comments) { comment in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(store.conversationName(comment.authorID, project: request.project)).font(.subheadline.weight(.semibold))
                                        Text(comment.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                        if !comment.mentionIDs.isEmpty {
                                            Label(comment.mentionIDs.map { store.conversationName($0, project: request.project) }.joined(separator: ", "), systemImage: "at").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                        }
                                        Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                        HStack {
                                            if comment.authorID == store.userID { Button("Edit") { composer = ConversationComposerRequest(target: request, baseline: comment) }.frame(minHeight: 44).accessibilityIdentifier("conversationEdit-" + comment.id) }
                                            if comment.authorID == store.userID || store.record("projects", id: request.project)?.string("user_id") == store.userID {
                                                Button("Remove", role: .destructive) { removing = comment }.frame(minHeight: 44)
                                            }
                                        }.disabled(!writable || store.conversationOutbox.contains { ConversationOutbox.comment($0)?.commentID == comment.id })
                                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(comment.id == request.selectedComment ? Color.taskfold.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18)).id(comment.id).accessibilityElement(children: .contain).accessibilityIdentifier("conversationComment-" + comment.id)
                                }
                            }
                            Button { composer = ConversationComposerRequest(target: request) } label: { Label("Write a comment", systemImage: "square.and.pencil").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent).disabled(!writable).accessibilityIdentifier("conversationCompose")
                            if !task["comments"].list.isEmpty { Text("Earlier and imported comments remain in the task’s details.").font(.caption).foregroundStyle(.secondary) }
                        } else { ContentUnavailableView("Conversation unavailable", systemImage: "lock.bubble", description: Text("This task moved, was removed or is no longer available. Your saved comment text remains in Mentions.")) }
                        // Keep private draft sheets mounted after shared access is withdrawn.
                        ConversationOutboxSection(workspace: request.workspace, target: request)
                    }.padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                }.accessibilityIdentifier("conversationScroll")
                    .task(id: "\(store.workspaceReadRevision)-\(store.lastSync?.timeIntervalSince1970 ?? 0)") { if let task { loading = true; await store.refreshConversation(task, selectedComment: request.selectedComment); loading = false; if let id = request.selectedComment { reader.scrollTo(id, anchor: .center) } } }
            }.navigationTitle("Conversation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("conversationClose") }
                ToolbarItem { Button { Task { if let task { loading = true; await store.refreshConversation(task, selectedComment: request.selectedComment); loading = false } } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading || !store.conversationsOnline).accessibilityLabel("Refresh conversation") }
                #if DEBUG
                if ConversationFixture.enabled, ProcessInfo.processInfo.arguments.contains("--conversation-access-testing") {
                    ToolbarItem {
                        if store.conversationFixtureWaiting { Text("Reply held").accessibilityIdentifier("conversationHeldReply") }
                        else { Button("Hold refresh") { guard let task else {return};store.conversationFixtureHolding=true;Task {await store.refreshConversation(task)} }.disabled(loading).accessibilityIdentifier("conversationHoldReply") }
                    }
                }
                #endif
                if let openTask, task != nil { ToolbarItem { Button { guard active, let current=self.task else { return }; dismiss(); openTask(current) } label: { Image(systemName: "arrow.up.forward.app") }.accessibilityLabel("Open task").accessibilityIdentifier("conversationOpenTask") } }
            }
            .sheet(item: $composer) { ConversationComposer(request: $0) }
            .confirmationDialog("Remove this comment for everyone?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove comment", role: .destructive) {
                    guard let comment = removing else { return }
                    do { let change = try SharedCommentChange(account: store.userID, taskID: comment.taskID, taskGeneration: comment.taskGeneration, projectID: comment.projectID, commentID: comment.id, expectedRevision: comment.revision, body: "", deleting: true); _ = store.saveConversation(change, workspace: request.workspace) } catch { store.conversationError = error.localizedDescription }; removing = nil
                }
            } message: { Text("Its text and mentions will be removed. A saved removal waits for a connection.") }
            .onChange(of: store.workspaceReadRevision) { _, _ in if task == nil || !writable { removing=nil } }
            .sheet(item:$audioConversation) { AudioCommentConversationView(request:$0) }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 650, minHeight: 580)
        #endif
    }
}

private struct ConversationStatus: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.conversationsOnline { Label("Offline · changes are saved on this device", systemImage: "icloud.slash").font(.footnote).foregroundStyle(.secondary) }
            if store.conversationSending { ProgressView("Sending saved changes…").font(.footnote) }
            if let error = store.conversationError { Text(error).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversationError") }
        }
    }
}

private struct ConversationComposer: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ConversationComposerRequest
    @State private var bodyText = ""
    @FocusState private var bodyFocused: Bool
    @State private var people = Set<String>()
    @State private var loaded = false
    @State private var discard = false
    private var existing: SharedCommentChange? { request.saved.flatMap(ConversationOutbox.comment) }
    private var initialBody: String { existing?.body ?? request.baseline?.body ?? "" }
    private var initialPeople: Set<String> { Set(existing?.mentionIDs ?? request.baseline?.mentionIDs ?? []) }
    private var hasChanges: Bool { loaded && (bodyText != initialBody || people != initialPeople) }
    private var draftValid: Bool { !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bodyText.utf8.count <= 16000 }
    private var members: [Record] { store.projectMembers(request.target.project).filter { UUID(uuidString: $0.id) != nil && $0.id != store.userID } }
    private var unavailablePeople: Set<String> { people.subtracting(Set(members.map(\.id))) }
    private var valid: Bool { store.conversationWritable(taskID: request.target.taskID, generation: request.target.generation, project: request.target.project) && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bodyText.utf8.count <= 16000 && unavailablePeople.isEmpty }
    private var active: Bool { request.target.workspace.matches(account: store.userID, generation: store.workspaceGeneration) }
    var body: some View {
        NavigationStack {
            Form {
                #if DEBUG
                if ConversationFixture.enabled, ProcessInfo.processInfo.arguments.contains("--conversation-access-testing") {
                    Text("Fixture access: " + (store.nativeConversationTeamCache?.boundary.projects[request.target.project]?.role ?? (store.nativeConversationTeamCache == nil ? "legacy":"revoked")))
                        .font(.caption2).lineLimit(1).minimumScaleFactor(0.5).accessibilityIdentifier("conversationAccessFixtureState")
                }
                #endif
                if !store.conversationWritable(taskID: request.target.taskID, generation: request.target.generation, project: request.target.project) {
                    Section { Text("Read-only conversation. You can save a private draft.").font(.callout).foregroundStyle(.secondary) }
                }
                Section("Comment") { TextField("Share your thoughts", text: $bodyText, axis: .vertical).lineLimit(5...15).focused($bodyFocused).accessibilityIdentifier("conversationBody")
                    if bodyText.utf8.count > 16000 { Text("This comment is too long. Shorten it before sending.").foregroundStyle(.red) }
                }
                if active, request.saved?.string("state") == "conflict", let baseline = request.baseline,
                   let latest = store.record(SharedComment.table,id:baseline.id).flatMap(SharedComment.init),
                   latest.taskID == request.target.taskID.lowercased(), latest.taskGeneration == request.target.generation.lowercased(), latest.projectID == request.target.project.lowercased(), store.conversationTask(latest) != nil {
                    Section("Latest shared version") { Text(latest.body).fixedSize(horizontal: false, vertical: true); Text("Sending your draft replaces this version. Any newer edit will still need review.").font(.caption).foregroundStyle(.secondary) }
                }
                Section { ForEach(members) { member in Toggle(member.string("display_name"), isOn: Binding(get: { people.contains(member.id) }, set: { if $0 { people.insert(member.id) } else { people.remove(member.id) } })).frame(minHeight: 44).accessibilityIdentifier("conversationPerson-" + member.id) }
                    ForEach(Array(unavailablePeople).sorted(), id: \.self) { id in Button("Remove unavailable teammate", role: .destructive) { people.remove(id) }.frame(minHeight: 44) }
                    if members.isEmpty { Text("Invite a teammate from the project’s sharing controls to mention someone.").foregroundStyle(.secondary) }
                } header: { Text("Mention people") } footer: { Text("Selected people will see this in Mentions. Typing a name alone does not send a mention.") }
                if let error = store.conversationError { Section { Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
                Button("Save draft on this device") { save(draft: true) }.disabled(!draftValid).accessibilityIdentifier("conversationSaveDraft")
            }.formStyle(.grouped).navigationTitle(request.baseline == nil ? "New comment" : "Edit comment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if hasChanges { discard = true } else { dismiss() } }.accessibilityIdentifier("conversationCancel") }
                #if DEBUG
                if ConversationFixture.enabled, ProcessInfo.processInfo.arguments.contains("--conversation-access-testing") {
                    ToolbarItem { HStack {
                        Button("Make read-only",systemImage:"lock") {store.changeConversationAccessFixture(readable:true)}.accessibilityIdentifier("conversationReadOnlyAccess")
                        Button("Revoke test access",systemImage:"lock.slash") {store.changeConversationAccessFixture(readable:false)}.accessibilityIdentifier("conversationRevokeAccess")
                    }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                }
                #endif
                ToolbarItem(placement: .confirmationAction) { Button("Send") { save(draft: false) }.disabled(!valid || !active).accessibilityIdentifier("conversationSend") }
            }
            .task {
                guard !loaded else { return }; loaded = true
                bodyText = initialBody; people = initialPeople
                if !store.localMode { _ = try? await store.refreshProjectMembers(request.target.project) }
            }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("Keep this comment as a draft?", isPresented: $discard, titleVisibility: .visible) {
                Button("Save draft") { save(draft: true) }.disabled(!draftValid)
                Button("Discard edits", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: store.workspaceReadRevision) { _, _ in bodyFocused=false }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 500)
        #endif
    }
    private func save(draft: Bool) {
        guard active else { return }
        do {
            let change = try SharedCommentChange(account: store.userID, taskID: request.target.taskID, taskGeneration: request.target.generation, projectID: request.target.project,
                commentID: request.baseline?.id ?? existing?.commentID ?? request.newCommentID, expectedRevision: request.baseline?.revision ?? existing?.expectedRevision ?? 0,
                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines), mentionIDs: Array(people), operationID: request.operationID)
            if store.saveConversation(change, workspace: request.target.workspace, draft: draft, replacing: request.saved?.id) { dismiss() }
        } catch { store.conversationError = error.localizedDescription }
    }
}

private struct ConversationOutboxSection: View {
    @Environment(Store.self) private var store
    let workspace: WorkspaceBinding
    var target: ConversationRequest? = nil
    @State private var composer: ConversationComposerRequest?
    @State private var discard: String?
    @State private var removalReview: Record?
    private var saved: [Record] { store.conversationOutbox.filter { row in guard let target else { return true }; return ConversationOutbox.comment(row)?.taskID == target.taskID } }
    var body: some View {
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Drafts & saved changes").font(.headline)
                ForEach(saved) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(label(row)).font(.subheadline.weight(.medium))
                        if let change = ConversationOutbox.comment(row), !change.deleting { Text(change.body).lineLimit(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        if let change = ConversationOutbox.mention(row) {
                            Text(change.read ? "Mark mention as read" : "Mark mention as unread").font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversationSavedIntent-" + row.id)
                        } else if ConversationOutbox.comment(row)?.deleting == true {
                            Text("Remove shared comment").font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversationSavedIntent-" + row.id)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { savedActions(row) }.fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 8) { savedActions(row) }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .contain).accessibilityIdentifier("conversationSaved-" + row.id)
                }
            }.sheet(item: $composer) { ConversationComposer(request: $0) }
                .confirmationDialog("Remove the latest shared version?", isPresented: Binding(get: { removalReview != nil }, set: { if !$0 { removalReview = nil } }), titleVisibility: .visible) {
                    Button("Remove latest comment", role: .destructive) {
                        guard let row = removalReview, let old = ConversationOutbox.comment(row), let latest = store.record(SharedComment.table, id: old.commentID).flatMap(SharedComment.init), !latest.isDeleted,
                              latest.taskID == old.taskID, latest.taskGeneration == old.taskGeneration, latest.projectID == old.projectID else { removalReview = nil; return }
                        do { let change = try SharedCommentChange(account: store.userID, taskID: old.taskID, taskGeneration: old.taskGeneration, projectID: old.projectID, commentID: old.commentID, expectedRevision: latest.revision, body: "", deleting: true)
                            _ = store.saveConversation(change, workspace: workspace, replacing: row.id)
                        } catch { store.conversationError = error.localizedDescription }; removalReview = nil
                    }
                } message: { Text(removalReview.flatMap(ConversationOutbox.comment).flatMap { store.record(SharedComment.table, id: $0.commentID) }.map { $0.string("body") } ?? "Refresh this conversation before retrying the removal.") }
                .confirmationDialog("Discard this saved change?", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }), titleVisibility: .visible) { Button("Discard", role: .destructive) { if let id = discard { store.discardConversation(id, workspace: workspace) }; discard = nil } }
        }
    }
    @ViewBuilder private func savedActions(_ row: Record) -> some View {
    if row.string("state") == "pending" { Button("Retry") { store.retryConversation(row.id, workspace: workspace) }.frame(minHeight: 44).disabled(store.conversationSending || !store.conversationsOnline || !retryAllowed(row)) }
    else if let change = ConversationOutbox.comment(row), !change.deleting {
        Button("Review") {
            let task = Record(["id": .string(change.taskID), "task_generation": .string(change.taskGeneration), "project_id": .string(change.projectID)])
            let current = store.rows(SharedComment.table).first { $0.id == change.commentID && $0.string("task_id") == change.taskID && $0.string("task_generation") == change.taskGeneration && $0.string("project_id") == change.projectID }.flatMap(SharedComment.init)
            composer = ConversationComposerRequest(target: ConversationRequest(task: task, workspace: workspace), baseline: current, saved: row)
        }.frame(minHeight: 44).accessibilityIdentifier("conversationReview-" + row.id)
    }
    if row.string("state") != "pending", let change = ConversationOutbox.comment(row), change.deleting {
        Button("Review removal") { removalReview = row }.frame(minHeight: 44).disabled(!store.conversationWritable(taskID: change.taskID, generation: change.taskGeneration, project: change.projectID))
    }
    Button("Discard", role: .destructive) { discard = row.id }.frame(minHeight: 44).disabled(store.conversationSending)
    }
    private func retryAllowed(_ row:Record) -> Bool {
        if let change=ConversationOutbox.comment(row) {return store.conversationWritable(taskID:change.taskID,generation:change.taskGeneration,project:change.projectID)}
        if let change=ConversationOutbox.mention(row) {return store.conversationMentions.contains{$0.id==change.mentionID}}
        return false
    }
    private func label(_ row: Record) -> String {
        guard ConversationOutbox.valid(row) else { return "Saved data needs a newer app" }
        if row.string("state")=="pending", !retryAllowed(row) {return "Access changed · saved change kept here"}
        switch row.string("state") { case "pending": return store.conversationsOnline ? "Waiting to send" : "Saved here · waiting for a connection"; case "draft": return "Draft saved on this device"; case "conflict": return "Changed elsewhere · review your draft"; case "recipients_changed": return "Review the people mentioned"; case "archived": return "Project archived · change kept here"; default: return "Task or permission changed · text kept here" }
    }
}

struct MentionsInboxView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: MentionsRequest
    let openTask: (Record) -> Void
    @State private var thread: ConversationRequest?
    @State private var loading = false
    @State private var unreadOnly = true
    private var active: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !active { ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Open Mentions in your current workspace.")) }
                    else if !store.conversationsAvailable { ContentUnavailableView("Mention people in your projects", systemImage: "at", description: Text("Sign in to use shared conversations and Mentions. Local task comments stay on this device.")) }
                    else {
                        if let count = store.mentionUnreadCount { Text("\(count) unread").font(.title2.weight(.semibold)).accessibilityIdentifier("mentionsUnread") }
                        else { Text("Check your mentions").font(.title2.weight(.semibold)) }
                        Picker("Show mentions", selection: $unreadOnly) { Text("Unread").tag(true); Text("All").tag(false) }.pickerStyle(.segmented).accessibilityIdentifier("mentionsFilter")
                        ConversationStatus()
                        ConversationOutboxSection(workspace: request.workspace)
                        if store.conversationMentions.filter({ !unreadOnly || !$0.isRead }).isEmpty, store.conversationMeta(unreadOnly ? "inbox-unread" : "inbox") != nil {
                            ContentUnavailableView(unreadOnly ? "No unread mentions here" : "No mentions here yet", systemImage: "at", description: Text("Mentions from your project teammates appear here. Refresh to check for new ones."))
                        }
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(store.conversationMentions.filter { !unreadOnly || !$0.isRead }) { mention in
                                let comment = store.record(SharedComment.table, id: mention.commentID).flatMap(SharedComment.init)
                                let task = comment.flatMap(store.conversationTask)
                                VStack(alignment: .leading, spacing: 10) {
                                    if let comment, let task, !comment.isDeleted {
                                        Text(store.conversationName(comment.authorID, project: comment.projectID)).font(.subheadline.weight(.semibold))
                                        Button { thread = ConversationRequest(task: task, workspace: request.workspace, selectedComment: comment.id) } label: {
                                            VStack(alignment: .leading, spacing: 8) { Text(task.title).font(.headline); Text(comment.body).font(.body).lineLimit(5) }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        }.buttonStyle(.plain).accessibilityIdentifier("mentionOpen-" + mention.id)
                                        Text(mention.isRead ? "Read" : "Unread").font(.caption).foregroundStyle(.secondary)
                                        Button(mention.isRead ? "Mark unread" : "Mark read") { _ = store.markConversationMention(mention, read: !mention.isRead, workspace: request.workspace) }.frame(minHeight: 44).disabled(store.conversationOutbox.contains { ConversationOutbox.mention($0)?.mentionID == mention.id }).accessibilityIdentifier("mentionRead-" + mention.id)
                                    } else { Text("This mention is no longer available.").foregroundStyle(.secondary) }
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.taskfold.opacity(mention.isRead ? 0.035 : 0.085), in: RoundedRectangle(cornerRadius: 18))
                            }
                        }
                        if store.conversationHasMore(unreadOnly ? "inbox-unread" : "inbox") { Button("Load earlier mentions") { Task { loading = true; await store.refreshConversation(nil, earlier: true, unreadOnly: unreadOnly); loading = false } }.frame(minHeight: 44).disabled(loading) }
                        #if DEBUG
                        if ConversationFixture.enabled { Button(store.conversationsOnline ? "Pause test delivery" : "Resume test delivery") { UserDefaults.standard.set(store.conversationsOnline, forKey: "conversation.fixture.paused"); store.conversationFixtureRevision += 1; Task { await store.syncConversations() } }.accessibilityIdentifier("conversationFixtureDelivery") }
                        #endif
                    }
                }.padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("mentionsScroll").navigationTitle("Mentions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("mentionsClose") }
                ToolbarItem { Button { Task { loading = true; await store.sync(); await store.syncConversations(); await store.refreshConversation(nil, unreadOnly: unreadOnly); loading = false } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading || !store.conversationsOnline).accessibilityLabel("Refresh mentions").accessibilityIdentifier("mentionsRefresh") }
            }
            .task(id: "\(unreadOnly)-\(store.lastSync?.timeIntervalSince1970 ?? 0)-\(store.workspaceReadRevision)") { loading = true; await store.syncConversations(); await store.refreshConversation(nil, unreadOnly: unreadOnly); loading = false }
            .sheet(item: $thread) { SharedConversationView(request: $0, openTask: openTask) }
            .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 660, minHeight: 580)
        #endif
    }
}
