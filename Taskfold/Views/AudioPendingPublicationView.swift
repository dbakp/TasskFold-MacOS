import SwiftUI

private struct PendingAudioReview: Identifiable {
    let journal: AudioCommentPublicationJournal
    var id: UUID { journal.publication.operation }
}
@MainActor struct AudioPendingPublicationSection: View {
    let library: AudioCommentLibraryController
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var controller: AudioCommentPendingLibrary?
    @State private var review: PendingAudioReview?
    @State private var failure: String?
    @State private var reload = UUID()
    private var allowed: Bool { phase == .active && store.audioPendingScope().map(library.scope.matches) == true }
    var body: some View {
        if store.audioPublishingEnabled, library.scope.origin != nil {
            Section {
                if let controller, allowed {
                    ForEach(controller.entries, id: \.publication.operation) { journal in
                        Button { review = .init(journal: journal) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(journal.publication.caption.isEmpty ? "Recording" : journal.publication.caption, systemImage: journal.receipt == nil ? "clock.arrow.circlepath" : "checkmark.circle")
                                    .lineLimit(2).foregroundStyle(.primary)
                                Text(journal.receipt == nil ? "Awaiting confirmation · original version kept" : "Confirmed · private recording kept").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("audioPendingRow-" + journal.publication.operation.uuidString.lowercased())
                    }
                    if controller.entries.isEmpty, !controller.working { Text("No publication copies to review.").foregroundStyle(.secondary) }
                    if controller.working { ProgressView("Loading publication copies…") }
                    if let notice = controller.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                if let failure { Text(failure).foregroundStyle(.secondary) }
                Button("Reload publication copies", systemImage: "arrow.clockwise") { reload = UUID() }.disabled(controller?.working == true)
            } header: { Text("Publication copies") } footer: {
                Text("Original versions are kept independently of edits or removal of saved drafts. Checking a send never replaces an edited draft.")
            }
            .task(id: String(describing: allowed) + store.backend.reminderSessionIncarnation.uuidString + reload.uuidString) {
                controller?.close(); controller = nil; review = nil; failure = nil
                guard allowed else { return }
                do {
                    let value = try await store.audioPendingLibrary(scope: library.scope, player: DeviceAudioCommentPlaying())
                    guard allowed, !Task.isCancelled else { value.close(); return }; controller = value; await value.refresh()
                } catch { if allowed, !Task.isCancelled { failure = "Publication copies could not be opened. Existing recordings are kept." } }
            }
            .sheet(item: $review, onDismiss: { controller?.clearSelection(); Task { await controller?.refresh(); await library.refresh() } }) { request in
                if let controller { AudioPendingPublicationReview(request: request, controller: controller) }
            }
            .onChange(of: allowed) { _, value in if !value { review = nil; controller?.setActive(false) } }
            .onDisappear { controller?.close() }
        }
    }
}
@MainActor private struct AudioPendingPublicationReview: View {
    let request: PendingAudioReview
    let controller: AudioCommentPendingLibrary
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var operation: Task<Void, Never>?
    @State private var flow: AudioCommentPublicationFlow?
    @State private var removing = false
    @State private var notice: String?
    private var current: Bool { phase == .active && controller.isCurrent }
    private var busy: Bool { controller.working || operation != nil }
    var body: some View {
        NavigationStack {
            Form {
                if current, let journal = controller.selected {
                    Section("Original recording") {
                        Text(journal.publication.caption.isEmpty ? "No written caption" : journal.publication.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("\(Double(journal.publication.descriptor.milliseconds) / 1000, specifier: "%.1f") seconds").font(.caption).foregroundStyle(.secondary)
                        Text(store.audioLibraryTask(journal.publication.target)?.title ?? "Original task unavailable").font(.subheadline).foregroundStyle(.secondary)
                        Button(controller.playing ? "Stop playback" : "Play original recording", systemImage: controller.playing ? "stop.fill" : "play.fill") {
                            if controller.playing { controller.stopPlayback() } else { Task { await controller.play() } }
                        }.disabled(busy).accessibilityIdentifier("audioPendingPlay")
                        Button("Keep a private copy", systemImage: "square.and.arrow.down") { run { try await controller.keepPrivateCopy() } }.disabled(busy).accessibilityIdentifier("audioPendingKeep")
                        Text("Keeps this original version in Saved recordings. Your edited draft stays unchanged.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section(journal.receipt == nil ? "Awaiting confirmation" : "Confirmed previously") {
                        if journal.receipt == nil {
                            if store.audioPublishingScope(journal.publication.target) != nil {
                                Button("Check original publication", systemImage: "arrow.clockwise") {
                                    run {
                                        controller.stopPlayback()
                                        let publisher = try store.audioPendingPublisher(journal, library: controller); flow = publisher
                                        try await publisher.retry(journal)
                                        guard current, !Task.isCancelled else { return }; try await controller.updateAfterConfirmation()
                                        notice = "Publication confirmed. This original recording is still kept here."
                                    }
                                }.disabled(busy).accessibilityIdentifier("audioPendingRetry")
                                Text("Resumes the original reviewed send. Its recording and caption remain unchanged.").font(.caption).foregroundStyle(.secondary)
                            } else { Text("The original task is not available for publishing. You can still play or keep your private recording.").foregroundStyle(.secondary) }
                        } else {
                            Label("This device kept the server confirmation", systemImage: "checkmark.circle").foregroundStyle(.green)
                            Button("Remove private publication copy…", role: .destructive) { removing = true }.disabled(busy).accessibilityIdentifier("audioPendingRemove")
                        }
                    }
                    if busy { ProgressView("Working…") }
                    if let notice = notice ?? controller.notice { Section { Text(notice).fixedSize(horizontal: false, vertical: true) } }
                } else if controller.working { ProgressView("Opening original recording…") }
                else { Text(current ? (controller.notice ?? "This publication changed. Reopen its current copy.") : "Publication review closed.").foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Publication review")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close(); dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
        .task { await controller.select(request.journal) }
        .confirmationDialog("Remove this private copy?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove private copy", role: .destructive) { run { try await controller.removeConfirmedCopy(); dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes only the publication recording kept on this device. Keep a private copy first if you need it. The server comment and any saved draft are not removed.") }
        .onChange(of: current) { _, value in if !value { close(); dismiss() } }
        .onDisappear { close() }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard current, !busy else { return }; notice = nil
        operation = Task {
            defer { operation = nil }
            do { try await action() }
            catch { if current, !Task.isCancelled { notice = error is AccountSessionAuthorizationRequired ? "Sign in again before checking this publication. Your recording is preserved." : error.localizedDescription } }
        }
    }
    private func close() { operation?.cancel(); operation = nil; flow?.invalidate(); flow = nil; controller.clearSelection() }
}
