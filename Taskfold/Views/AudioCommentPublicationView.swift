import SwiftUI

/// Audience wording comes from the server review, independently of cached access.
struct AudioPublicationAudienceSummary: View {
    let approval: AudioCommentPublicationApproval
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Who can listen", systemImage: "person.2").font(.headline)
            Text(approval.audienceDescription).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Downloaded copies cannot be recalled.").font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine).accessibilityLabel("Who can listen. " + approval.audienceDescription + " Downloaded copies cannot be recalled.").accessibilityIdentifier("audioPublicationAudience")
    }
}

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
    @State private var resuming = false
    @State private var closing = false
    @State private var activity = "Preparing publication…"
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @AccessibilityFocusState(for: .voiceOver) private var statusFocused: Bool
    @AccessibilityFocusState(for: .voiceOver) private var audienceFocused: Bool
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
                    case .closed:
                        Label("Original publication closed", systemImage: "checkmark.shield").accessibilityIdentifier("audioPublicationClosed")
                        Text("That send can’t resume. It may have been visible earlier. Your private recording is preserved; edit and save a new version if you want to publish again.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    case .saving, .sending:
                        ProgressView(activity).accessibilityIdentifier("audioPublicationProgress")
                    case .ready, .unconfirmed:
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            actions(flow, now: context.date)
                        }
                    }
                } else if notice == nil { ProgressView("Checking saved publication…") }
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("audioPublicationNotice").accessibilityFocused($statusFocused)
                    if flow?.journal == nil, !busy {
                        Button("Reload publication status", systemImage: "arrow.clockwise") { Task { await restore() } }.frame(minHeight: 44).accessibilityIdentifier("audioPublicationReload")
                    }
                }
            }.buttonStyle(.borderless)
            .task(id: identity) { await restore() }
            .alert(resuming ? "Resume the original send?" : "Publish this recording?", isPresented: $confirming) {
                Button(resuming ? "Resume original send" : "Publish recording") { start(resuming ? .resume : .publish) }.disabled(!admitted || busy).accessibilityIdentifier("audioPublicationConfirm")
                Button("Cancel", role: .cancel) { if !resuming { flow?.discardAudienceReview(); audienceFocused = false; notice = "Review cancelled. Your saved recording is preserved."; statusFocused = true } }
            } message: {
                Text((resuming ? flow?.journal?.approval : flow?.reviewedApproval)?.audienceDescription ?? "Review who can listen before publishing. Your private recording stays on this device.")
            }
            .confirmationDialog("Close the original send?", isPresented: $closing) {
                Button("Close original send", role: .destructive) { start(.close) }.accessibilityIdentifier("audioPublicationCloseConfirm")
                Button("Cancel", role: .cancel) {}
            } message: { Text("Prevents this send from finishing. If it already finished, its confirmation will be kept. Your saved recording stays here.") }
            .onChange(of: current != nil) { _, value in if !value { close() } }
            .onChange(of: library.isCurrent) { _, value in if !value { close() } }
            .onChange(of: scenePhase) { _, value in if value != .active { close() } }
            .onDisappear { close() }
        }
    }
    @ViewBuilder private func actions(_ flow: AudioCommentPublicationFlow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let approval = flow.reviewedApproval {
                AudioPublicationAudienceSummary(approval: approval).accessibilityFocused($audienceFocused)
                if approval.permits(approval.publication, now: now) {
                    Button("Publish recording…", systemImage: "paperplane") { resuming = false; confirming = true }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(busy).accessibilityIdentifier("audioPublicationReview")
                } else { Text("This audience review expired. Review it again before publishing.").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("audioPublicationApprovalExpired") }
            } else if let journal = flow.journal {
                Label("Saved publication request", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("Check its original result without uploading audio. Your private recording stays here.").font(.caption).foregroundStyle(.secondary)
                if let approval = journal.approval {
                    AudioPublicationAudienceSummary(approval: approval)
                    if approval.permits(journal.publication, now: now) {
                        Button("Resume original send…", systemImage: "paperplane") { resuming = true; confirming = true }
                            .frame(minHeight: 44).disabled(busy).accessibilityIdentifier("audioPublicationResume")
                    } else { Text("The saved review expired. You can still check the original result.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("audioPublicationApprovalExpired") }
                }
                Button("Check publication", systemImage: "arrow.clockwise") { start(.check) }.frame(minHeight: 44).disabled(busy).accessibilityIdentifier("audioPublicationRetry")
                Button("Close original send…", systemImage: "xmark.circle") { closing = true }
                    .frame(minHeight: 44).disabled(busy).accessibilityIdentifier("audioPublicationCloseOriginal")
            } else {
                Text("Review who can listen before sharing this recording and caption. Reviewing does not upload audio.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(flow.reviewedApproval == nil ? "Review who can listen" : "Review audience again", systemImage: "person.2") { start(.review) }
                .frame(minHeight: 44).disabled(busy).accessibilityIdentifier("audioPublicationAudienceReview")
        }
    }
    private enum Action { case review, publish, resume, check, close }
    private var identity: String { source.id.uuidString + source.revision.uuidString + String(describing: current) + String(describing: scenePhase) + store.backend.reminderSessionIncarnation.uuidString }
    private func close() {
        generation = UUID(); operation?.cancel(); operation = nil; flow?.invalidate(); flow = nil; scope = nil; ready = false; notice = nil; confirming = false; closing = false
    }
    private func restore() async {
        close(); guard let current, scenePhase == .active, library.isCurrent else { return }
        let token = generation
        do {
            let publisher = try store.audioPublisher(for: current, source: source, library: library)
            scope = current; flow = publisher; try await publisher.restore(source)
            guard generation == token, admitted, !Task.isCancelled else { return }; ready = true
        } catch {
            guard generation == token, scenePhase == .active, library.publicationSourceIsCurrent(source), let live = store.audioPublishingScope(source.target), current.matches(live), !Task.isCancelled else { return }
            notice = error.localizedDescription; ready = true
        }
    }
    private func start(_ action: Action) {
        guard admitted, ready, !busy, let flow else { return }
        let token = generation; notice = nil; statusFocused = false; audienceFocused = false; library.stopPlayback()
        activity = action == .review ? "Reviewing who can listen…" : (action == .check || action == .close) ? "Checking original send…" : "Publishing recording…"
        operation = Task {
            defer { if generation == token { operation = nil } }
            do {
                switch action {
                case .check, .close: if let journal = flow.journal { try await flow.checkPublication(journal, closing: action == .close) }
                case .resume: if let journal = flow.journal { try await flow.retry(journal) }
                case .review, .publish:
                    let fresh = try await library.preparePublicationSource(source)
                    guard admitted, generation == token, !Task.isCancelled else { return }
                    if action == .review { try await flow.reviewAudience(fresh) } else { try await flow.publish(fresh) }
                }
                guard admitted, generation == token, !Task.isCancelled else { return }
                if flow.state == .closed { notice = "Original publication closed. Your private recording is preserved." }
                else if flow.state == .published { notice = "The original send was confirmed. Your saved recording is still here." }
                else if action == .review, let approval = flow.reviewedApproval { notice = "Audience reviewed. " + approval.audienceDescription }
                else { notice = "The original send is still unconfirmed. Your recording is preserved." }
                if action == .review, flow.reviewedApproval != nil { audienceFocused = true } else { statusFocused = true }
            } catch {
                guard admitted, generation == token, !Task.isCancelled else { return }
                if error is AccountSessionAuthorizationRequired { notice = "Sign in again before reviewing this publication. Your local recording is preserved." }
                else { notice = error.localizedDescription }
                statusFocused = true
            }
        }
    }
}
