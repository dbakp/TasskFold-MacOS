import SwiftUI

/// Explicit review/publish controls; this gate is separate from private drafts.
/// A cached receipt describes an earlier acknowledgement, not live comment access.
@MainActor struct AudioCommentPublicationControls: View {
    let source: AudioCommentSavedDraft
    let library: AudioCommentLibraryController
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var flow: AudioCommentPublicationFlow?
    @State private var scope: AudioCommentLiveScope?
    @State private var notice: String?
    @State private var ready = false
    @State private var confirming = false
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @AccessibilityFocusState(for: .voiceOver) private var statusFocused: Bool
    private var current: AudioCommentLiveScope? { store.audioPublishingScope(source.target) }
    private var admitted: Bool { scenePhase == .active && library.isCurrent && flow?.contextIsCurrent == true && scope.map { expected in current.map(expected.matches) == true } == true }
    private var busy: Bool { flow?.state == .saving || flow?.state == .sending || library.working || operation != nil }
    var body: some View {
        if store.audioPublishingEnabled {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Label("Publish to task", systemImage: "paperplane").font(.headline)
                if current == nil {
                    Text("Publishing is unavailable for this recording’s original task. Your local recording is safe.").font(.callout).foregroundStyle(.secondary)
                } else if let flow, ready, admitted {
                    switch flow.state {
                    case .published:
                        Label("Published previously", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("audioPublicationConfirmed")
                        Text("This device kept its confirmation. Open Audio comments in the task to check its current contents.").font(.caption).foregroundStyle(.secondary)
                    case .saving, .sending:
                        ProgressView(flow.state == .sending ? "Publishing recording…" : "Preparing publication…").accessibilityIdentifier("audioPublicationProgress")
                    case .ready, .unconfirmed:
                        if flow.journal != nil {
                            Label("Awaiting confirmation", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text("Check the earlier send safely. Your local recording stays here.").font(.caption).foregroundStyle(.secondary)
                            Button("Check publication", systemImage: "arrow.clockwise") { start(checking: true) }
                                .disabled(busy).accessibilityIdentifier("audioPublicationRetry")
                        } else {
                            Text("Publish the reviewed recording and caption to its original task. Anyone with access to that task may be able to listen.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Publish recording…", systemImage: "paperplane") { confirming = true }
                                .disabled(busy || notice != nil).accessibilityIdentifier("audioPublicationReview")
                        }
                    }
                } else if notice == nil {
                    ProgressView("Checking saved publication…")
                }
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("audioPublicationNotice").accessibilityFocused($statusFocused)
                    if flow?.journal == nil, !busy {
                        Button("Reload publication status", systemImage: "arrow.clockwise") { Task { await restore() } }
                            .accessibilityIdentifier("audioPublicationReload")
                    }
                }
            }
            .task(id: identity) { await restore() }
            .confirmationDialog("Publish this recording?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Publish recording") { start(checking: false) }.disabled(!admitted || busy)
                Button("Cancel", role: .cancel) {}
            } message: { Text("The recording and caption will be shared on the original task. Your saved copy stays on this device.") }
            .onChange(of: current != nil) { _, value in if !value { close() } }
            .onChange(of: library.isCurrent) { _, value in if !value { close() } }
            .onChange(of: scenePhase) { _, value in if value != .active { close() } }
            .onDisappear { close() }
        }
    }
    private var identity: String { source.id.uuidString + source.revision.uuidString + String(describing: current) + String(describing: scenePhase) + store.backend.reminderSessionIncarnation.uuidString }
    private func close() {
        generation = UUID(); operation?.cancel(); operation = nil; flow?.invalidate(); flow = nil; scope = nil; ready = false; notice = nil; confirming = false
    }
    private func restore() async {
        close(); guard let current, scenePhase == .active, library.isCurrent else { return }
        let token = generation
        do {
            let publisher = try store.audioPublisher(for: current, source: source, library: library)
            scope = current; flow = publisher
            try await publisher.restore(source)
            guard generation == token, admitted, !Task.isCancelled else { return }; ready = true
        } catch {
            guard generation == token, scenePhase == .active, library.publicationSourceIsCurrent(source),
                  let live = store.audioPublishingScope(source.target), current.matches(live), !Task.isCancelled else { return }
            notice = error.localizedDescription; ready = true
        }
    }
    private func start(checking: Bool) {
        guard admitted, ready, !busy, let flow else { return }
        let token = generation; notice = nil; library.stopPlayback()
        operation = Task {
            defer { if generation == token { operation = nil } }
            do {
                if checking, let journal = flow.journal { try await flow.retry(journal) }
                else {
                    let fresh = try await library.preparePublicationSource(source)
                    guard admitted, generation == token, !Task.isCancelled else { return }
                    try await flow.publish(fresh)
                }
                guard admitted, generation == token, !Task.isCancelled else { return }
                notice = "Publication confirmed. Your saved recording is still here."; statusFocused = true
            } catch {
                guard admitted, generation == token, !Task.isCancelled else { return }
                if error is AccountSessionAuthorizationRequired { notice = "Sign in again before checking this publication. Your local recording is preserved." }
                else { notice = flow.journal != nil ? "Publication is awaiting confirmation. Use Check publication to retry safely; your local recording is preserved." : error.localizedDescription }
                statusFocused = true
            }
        }
    }
}
