import SwiftUI

@MainActor struct AudioCommentConversationView: View {
    let request: AudioCommentConversationRequest
    #if DEBUG
    var fixture: AudioConversationPresentationFixture? = nil
    #endif
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var textSize
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
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Label(authorName(comment), systemImage: "waveform")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Double(comment.publication.descriptor.milliseconds) / 1000, specifier: "%.1f") sec").font(.caption).foregroundStyle(.secondary)
                                }
                                if !comment.publication.caption.isEmpty { Text(comment.publication.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                                if textSize.isAccessibilitySize {
                                    VStack(alignment:.leading,spacing:12) { playback(comment,controller); removal(comment,controller) }
                                } else {
                                    HStack { playback(comment,controller); Spacer(); removal(comment,controller) }
                                }
                            }.padding(.vertical, 6).accessibilityElement(children:.contain).accessibilityIdentifier("audioConversationRow-" + comment.id.uuidString.lowercased())
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
    private func playback(_ comment: AudioCommentRemote, _ controller: AudioCommentConversationController) -> some View {
        Button {
            if controller.playing == comment.id { controller.stop() } else { run { await controller.play(comment) } }
        } label: { Label(controller.playing == comment.id ? "Stop" : "Play recording",systemImage:controller.playing == comment.id ? "stop.fill" : "play.fill").frame(minHeight:44) }
        .buttonStyle(.bordered).disabled(controller.working)
        .accessibilityLabel(controller.playing == comment.id ? "Stop recording playback" : "Play recording")
        .accessibilityIdentifier("audioConversationPlay-" + comment.id.uuidString.lowercased())
    }
    @ViewBuilder private func removal(_ comment: AudioCommentRemote, _ controller: AudioCommentConversationController) -> some View {
        if controller.mayRemove(comment) {
            Button(role:.destructive) { removing=comment } label: { Label("Remove…",systemImage:"trash").frame(minHeight:44) }
                .buttonStyle(.borderless).disabled(controller.working).accessibilityLabel("Remove audio comment")
                .accessibilityIdentifier("audioConversationRemove-" + comment.id.uuidString.lowercased())
        }
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard allowed, operation == nil else { return }
        operation = Task { defer { operation = nil }; await action() }
    }
    private func close() { operation?.cancel(); operation = nil; removing = nil; controller?.close(); controller = nil }
}
