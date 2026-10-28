import SwiftUI

@MainActor struct AudioCommentConversationView: View {
    let request: AudioCommentConversationRequest
    #if DEBUG
    var fixture: AudioConversationPresentationFixture? = nil
    #endif
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var controller: AudioCommentConversationController?
    @State private var removing: AudioCommentRemote?
    @State private var operation: Task<Void, Never>?
    @State private var failure: String?
    @State private var reload = UUID()
    private var allowed: Bool {
        guard phase == .active else { return false }
        #if DEBUG
        if let fixture { return fixture.isCurrent() }
        #endif
        return store.audioReadScope(request.scope.target).map(request.scope.matches) == true
    }
    private var sessionID: UUID {
        #if DEBUG
        if let fixture { return fixture.session }
        #endif
        return store.backend.reminderSessionIncarnation
    }
    private func makeController() throws -> AudioCommentConversationController {
        #if DEBUG
        if let fixture { return try fixture.makeController() }
        #endif
        return try store.audioConversation(scope:request.scope,player:DeviceAudioCommentPlaying())
    }
    private func authorName(_ comment: AudioCommentRemote) -> String {
        #if DEBUG
        if let fixture { return fixture.authorName(comment.author) }
        #endif
        return store.conversationName(comment.author?.uuidString.lowercased(),project:request.scope.target.project?.uuidString.lowercased() ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                if allowed, let controller, controller.isCurrent {
                    Section {
                        ForEach(controller.entries) { comment in
                            AudioConversationRow(comment:comment,controller:controller,author:authorName(comment),play:{
                                if controller.playing == comment.id {controller.stop()} else {run {await controller.play(comment)}}
                            },remove:{removing=comment})
                        }
                        if controller.entries.isEmpty, !controller.working, controller.notice == nil { ContentUnavailableView("No audio comments", systemImage: "waveform", description: Text("Published recordings appear here after refreshing.")) }
                        if controller.hasMore { Button("Load more recordings", systemImage: "chevron.down") { run { await controller.loadMore() } }.frame(minHeight:44).disabled(controller.working).accessibilityIdentifier("audioConversationMore") }
                        if controller.working { ProgressView("Loading recording…") }
                        if let notice = controller.notice { Text(notice).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("audioConversationNotice") }
                    } footer: { Text("Play recordings here without adding copies to Saved recordings.") }
                }
                if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
                if allowed { Button("Refresh recordings", systemImage: "arrow.clockwise") { reload = UUID() }.frame(minHeight:44).disabled(controller?.working == true).accessibilityIdentifier("audioConversationRefresh") }
                else { Text("Conversation closed. Reopen it in the current workspace.").foregroundStyle(.secondary) }
            }.accessibilityIdentifier("audioConversationForm").formStyle(.grouped).navigationTitle("Audio comments")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close(); dismiss() }.accessibilityIdentifier("audioConversationClose") } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .task(id: String(describing: allowed) + sessionID.uuidString + reload.uuidString) {
            close(); failure = nil
            guard allowed else { return }
            do {
                let value = try makeController()
                guard allowed, !Task.isCancelled else { value.close(); return }; controller = value; await value.refresh()
            } catch { if allowed, !Task.isCancelled { failure = "This conversation couldn’t be opened. Your saved recordings are unchanged." } }
        }
        .alert("Remove this audio comment?",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}}),presenting:removing) { comment in
            Button("Remove audio comment",role:.destructive) { removing=nil;run {await controller?.remove(comment)} }.accessibilityIdentifier("audioConversationConfirmRemove")
            Button("Cancel",role:.cancel) {removing=nil}
        } message: { _ in Text("This removes the published comment for everyone with access to this task. Private recordings saved on your devices stay unchanged.") }
        .onChange(of: allowed) { _, value in if !value { close(); dismiss() } }
        .onDisappear { close() }
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard allowed, operation == nil else { return }
        operation = Task { defer { operation = nil }; await action() }
    }
    private func close() { operation?.cancel(); operation = nil; removing = nil; controller?.close(); controller = nil }
}

/// Shared by the audio-only reader and the mixed conversation timeline.
@MainActor struct AudioConversationRow: View {
    let comment: AudioCommentRemote
    let controller: AudioCommentConversationController
    let author: String
    let play: () -> Void
    let remove: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label(author,systemImage:"waveform").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Double(comment.publication.descriptor.milliseconds) / 1000,specifier:"%.1f") sec").font(.caption).foregroundStyle(.secondary)
            }
            if !comment.publication.caption.isEmpty {Text(comment.publication.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
            if let published = TaskPlanning.instant(comment.record.string("published_at")) {
                Text(published.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if textSize.isAccessibilitySize {
                VStack(alignment:.leading,spacing:12) {playback;removal}
            } else {HStack {playback;Spacer();removal}}
        }.padding(.vertical,6).accessibilityElement(children:.contain).accessibilityIdentifier("audioConversationRow-"+comment.id.uuidString.lowercased())
    }
    private var playback: some View {
        Button(action:play) {
            Label(controller.playing == comment.id ? "Stop":"Play recording",systemImage:controller.playing == comment.id ? "stop.fill":"play.fill").frame(minHeight:44)
        }.buttonStyle(.bordered).disabled(controller.working)
            .accessibilityLabel(controller.playing == comment.id ? "Stop recording playback":"Play recording")
            .accessibilityIdentifier("audioConversationPlay-"+comment.id.uuidString.lowercased())
    }
    @ViewBuilder private var removal: some View {
        if controller.mayRemove(comment) {
            Button(role:.destructive,action:remove) {Label("Remove…",systemImage:"trash").frame(minHeight:44)}
                .buttonStyle(.borderless).disabled(controller.working).accessibilityLabel("Remove audio comment")
                .accessibilityIdentifier("audioConversationRemove-"+comment.id.uuidString.lowercased())
        }
    }
}

/// Merge only the loaded, currently admitted rows. Each medium retains its own
/// cursor and authority; loading text never downloads media or publishes audio.
@MainActor struct UnifiedConversationTimeline<TextRow: View>: View {
    let request: ConversationRequest
    let comments: [SharedComment]
    let audioRequest: AudioCommentConversationRequest?
    let textHasMore: Bool
    let refresh: UUID
    @ViewBuilder let textRow: (SharedComment) -> TextRow
    #if DEBUG
    var fixture: AudioConversationPresentationFixture? = nil
    #endif
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var controller: AudioCommentConversationController?
    @State private var removing: AudioCommentRemote?
    @State private var operation: Task<Void,Never>?
    @State private var failure: String?
    private var audioAllowed: Bool {
        guard phase == .active, let audioRequest,
              audioRequest.scope.workspace == request.workspace,
              audioRequest.scope.target.task.uuidString.lowercased() == request.taskID.lowercased(),
              audioRequest.scope.target.generation.uuidString.lowercased() == request.generation.lowercased(),
              (audioRequest.scope.target.project?.uuidString.lowercased() ?? "") == request.project.lowercased() else {return false}
        #if DEBUG
        if let fixture {return fixture.isCurrent()}
        #endif
        return request.workspace.matches(account:store.userID,generation:store.workspaceGeneration)
            && store.audioReadScope(audioRequest.scope.target).map(audioRequest.scope.matches) == true
    }
    private var live: AudioCommentConversationController? {audioAllowed && controller?.isCurrent == true ? controller:nil}
    private var session: UUID {
        #if DEBUG
        if let fixture {return fixture.session}
        #endif
        return store.backend.reminderSessionIncarnation
    }
    private var loadKey: String {
        [String(audioAllowed),request.workspace.account,request.workspace.generation.uuidString,request.taskID,request.generation,request.project,
         audioRequest?.scope.origin ?? "",session.uuidString,refresh.uuidString].joined(separator:"|")
    }
    private var entries: [ConversationTimelineEntry] {
        ConversationTimelineEntry.merge(text:comments,audio:live?.entries ?? [],account:request.workspace.account,taskID:request.taskID,generation:request.generation,project:request.project)
    }
    private func author(_ value: AudioCommentRemote) -> String {
        #if DEBUG
        if let fixture {return fixture.authorName(value.author)}
        #endif
        return store.conversationName(value.author?.uuidString.lowercased(),project:request.project)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            if textHasMore || live?.hasMore == true {
                Text("More comments are available. This timeline shows the comments loaded so far.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("conversationPartialTimeline")
            }
            if entries.isEmpty, failure == nil, live?.notice == nil,
               audioRequest == nil || live != nil && live?.working == false {
                ContentUnavailableView("Start the conversation",systemImage:"bubble.left.and.bubble.right",description:Text("Share a thought or mention someone from this project."))
            }
            LazyVStack(alignment:.leading,spacing:18) {
                ForEach(entries) { entry in
                    switch entry {
                    case .text(let comment): textRow(comment)
                    case .audio(let comment):
                        if let live {
                            AudioConversationRow(comment:comment,controller:live,author:author(comment),play:{
                                if live.playing == comment.id {live.stop()} else {run {await live.play(comment)}}
                            },remove:{removing=comment})
                                .padding(16).frame(maxWidth:.infinity,alignment:.leading)
                                .background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:18))
                        }
                    }
                }
            }.accessibilityIdentifier("conversationTimeline")
            if let live {
                if live.working {ProgressView("Loading recording…")}
                if let notice=live.notice {Text("Recordings: " + notice).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("conversationAudioNotice")}
                if live.hasMore {
                    Button("Load more recordings",systemImage:"chevron.down") {run {await live.loadMore()}}
                        .frame(minHeight:44).disabled(live.working).accessibilityIdentifier("conversationAudioMore")
                }
            }
            if let failure {Text(failure).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }.task(id:loadKey) {
            close();failure=nil
            guard audioAllowed,let audioRequest else {return}
            do {
                let value:AudioCommentConversationController
                #if DEBUG
                if let fixture {value=try fixture.makeController()}
                else {value=try store.audioConversation(scope:audioRequest.scope,player:DeviceAudioCommentPlaying())}
                #else
                value=try store.audioConversation(scope:audioRequest.scope,player:DeviceAudioCommentPlaying())
                #endif
                guard audioAllowed,!Task.isCancelled else {value.close();return}
                controller=value;await value.refresh()
            } catch {if audioAllowed,!Task.isCancelled {failure="Recordings couldn’t be opened. Text comments and saved recordings are unchanged."}}
        }
        .alert("Remove this audio comment?",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}}),presenting:removing) {comment in
            Button("Remove audio comment",role:.destructive) {removing=nil;run {await live?.remove(comment)}}.accessibilityIdentifier("audioConversationConfirmRemove")
            Button("Cancel",role:.cancel) {removing=nil}
        } message: {_ in Text("This removes the published comment for everyone with access to this task. Private recordings saved on your devices stay unchanged.")}
        .onChange(of:audioAllowed) {_,allowed in if !allowed {close()}}
        .onDisappear {close()}
    }
    private func run(_ action:@escaping @MainActor () async -> Void) {
        guard audioAllowed,operation == nil else {return}
        operation=Task {defer {operation=nil};await action()}
    }
    private func close() {operation?.cancel();operation=nil;removing=nil;controller?.close();controller=nil}
}
