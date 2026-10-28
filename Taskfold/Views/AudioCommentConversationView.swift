import SwiftUI

@MainActor struct AudioCommentConversationView: View {
    let request: AudioCommentConversationRequest
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var controller: AudioCommentConversationController?
    @State private var removing: AudioCommentRemote?
    @State private var operation: Task<Void, Never>?
    @State private var failure: String?
    @State private var reload = UUID()
    private var allowed: Bool { phase == .active && store.audioPublishingScope(request.scope.target).map(request.scope.matches) == true }
    var body: some View {
        NavigationStack {
            Form {
                if allowed, let controller, controller.isCurrent {
                    Section {
                        ForEach(controller.entries) { comment in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Label(comment.author?.uuidString.lowercased() == request.scope.workspace.account ? "You" : comment.author == nil ? "Former member" : "Team member", systemImage: "waveform")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Double(comment.publication.descriptor.milliseconds) / 1000, specifier: "%.1f") sec").font(.caption).foregroundStyle(.secondary)
                                }
                                if !comment.publication.caption.isEmpty { Text(comment.publication.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                                HStack {
                                    Button(controller.playing == comment.id ? "Stop" : "Play recording", systemImage: controller.playing == comment.id ? "stop.fill" : "play.fill") {
                                        if controller.playing == comment.id { controller.stop() } else { run { await controller.play(comment) } }
                                    }.buttonStyle(.bordered).disabled(controller.working).accessibilityIdentifier("audioConversationPlay-" + comment.id.uuidString.lowercased())
                                    Spacer()
                                    Button("Remove…", systemImage: "trash", role: .destructive) { removing = comment }.buttonStyle(.borderless).disabled(controller.working)
                                }
                            }.padding(.vertical, 6)
                        }
                        if controller.entries.isEmpty, !controller.working { ContentUnavailableView("No audio comments", systemImage: "waveform", description: Text("Published recordings appear here after refreshing.")) }
                        if controller.working { ProgressView("Loading recording…") }
                        if let notice = controller.notice { Text(notice).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("audioConversationNotice") }
                    } footer: { Text("This preview shows up to 20 audio comments. Playback checks access again and does not save a private draft.") }
                }
                if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
                if allowed { Button("Refresh recordings", systemImage: "arrow.clockwise") { reload = UUID() }.disabled(controller?.working == true) }
                else { Text("Conversation closed. Reopen it in the current workspace.").foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Audio comments")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close(); dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
        .task(id: String(describing: allowed) + store.backend.reminderSessionIncarnation.uuidString + reload.uuidString) {
            close(); failure = nil
            guard allowed else { return }
            do {
                let value = try store.audioConversation(scope: request.scope, player: DeviceAudioCommentPlaying())
                guard allowed, !Task.isCancelled else { value.close(); return }; controller = value; await value.refresh()
            } catch { if allowed, !Task.isCancelled { failure = "This conversation couldn’t be opened. Your saved recordings are unchanged." } }
        }
        .confirmationDialog("Remove this audio comment?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let comment = removing { Button("Remove audio comment", role: .destructive) { removing = nil; run { await controller?.remove(comment) } } }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("This removes the published comment for everyone with access to this task. Private recordings saved on your devices stay unchanged.") }
        .onChange(of: allowed) { _, value in if !value { close(); dismiss() } }
        .onDisappear { close() }
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard allowed, operation == nil else { return }
        operation = Task { defer { operation = nil }; await action() }
    }
    private func close() { operation?.cancel(); operation = nil; removing = nil; controller?.close(); controller = nil }
}
