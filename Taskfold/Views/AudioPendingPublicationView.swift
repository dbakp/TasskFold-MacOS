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
                                Label(journal.publication.caption.isEmpty ? "Recording" : journal.publication.caption, systemImage: journal.closedReceipt != nil ? "checkmark.shield" : (journal.isPending ? "clock.arrow.circlepath" : "checkmark.circle"))
                                    .lineLimit(2).foregroundStyle(.primary)
                                Text(journal.closedReceipt != nil ? "Closed · private recording kept" : (journal.isPending ? "Awaiting confirmation · original version kept" : "Confirmed · private recording kept")).font(.caption).foregroundStyle(.secondary)
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
private enum PendingAudioAction {
    case resume,close,remove
    var title:String {
        switch self {case .resume:return "Resume the original send?";case .close:return "Close the original send?";case .remove:return "Remove this private copy?"}
    }
    var button:String {switch self {case .resume:return "Resume original send";case .close:return "Close original send";case .remove:return "Remove private copy"}}
    var message:String {
        switch self {
        case .resume:return "Upload the original reviewed recording and caption to its original task. Your private recording stays here."
        case .close:return "Prevent this send from finishing. If it was already published, its confirmation will be kept instead. This does not remove a published comment or your private recording."
        case .remove:return "This removes only the publication recording kept on this device. Keep a private copy first if you need it. The server comment and saved drafts are not removed."
        }
    }
}
@MainActor private struct AudioPendingPublicationReview: View {
    let request:PendingAudioReview
    let controller:AudioCommentPendingLibrary
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var operation:Task<Void,Never>?
    @State private var flow:AudioCommentPublicationFlow?
    @State private var confirming:PendingAudioAction?
    @State private var notice:String?
    private var current:Bool {phase == .active && controller.isCurrent}
    private var busy:Bool {controller.working || operation != nil}
    var body:some View {
        NavigationStack {
            Form {
                if current,let journal=controller.selected {
                    Section("Original recording") {
                        Text(journal.publication.caption.isEmpty ? "No written caption":journal.publication.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        Text("\(Double(journal.publication.descriptor.milliseconds)/1000,specifier:"%.1f") seconds").font(.caption).foregroundStyle(.secondary)
                        Text(store.audioLibraryTask(journal.publication.target)?.title ?? "Original task unavailable").font(.subheadline).foregroundStyle(.secondary)
                        Button(controller.playing ? "Stop playback":"Play original recording",systemImage:controller.playing ? "stop.fill":"play.fill") {
                            if controller.playing {controller.stopPlayback()} else {Task {await controller.play()}}
                        }.frame(minHeight:44).disabled(busy).accessibilityIdentifier("audioPendingPlay")
                        Button("Keep a private copy",systemImage:"square.and.arrow.down") {run {try await controller.keepPrivateCopy()}}
                            .frame(minHeight:44).disabled(busy).accessibilityIdentifier("audioPendingKeep")
                        Text("Keeps this original version in Saved recordings. Your edited draft stays unchanged.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section(journal.closedReceipt != nil ? "Original publication closed":(journal.isPending ? "Awaiting confirmation":"Confirmed previously")) {
                        if journal.isPending {
                            Button("Check original send",systemImage:"arrow.clockwise") {run {try await checkOriginal(journal,closing:false)}}
                                .frame(minHeight:44).disabled(busy).accessibilityIdentifier("audioPendingRetry")
                            Text("Checks only your original send’s status, without uploading audio or reopening the task.").font(.caption).foregroundStyle(.secondary)
                            if store.audioPublishingScope(journal.publication.target) != nil {
                                Button("Resume original send…",systemImage:"paperplane") {confirming = .resume}
                                    .frame(minHeight:44).disabled(busy).accessibilityIdentifier("audioPendingResume")
                            } else {Text("The original task is unavailable for publishing. Status checks and your private recording remain available.").font(.caption).foregroundStyle(.secondary)}
                            Button("Close original send…",systemImage:"xmark.circle") {confirming = .close}
                                .frame(minHeight:44).disabled(busy).accessibilityIdentifier("audioPendingCloseOriginal")
                        } else {
                            if journal.closedReceipt != nil {
                                Label("That send can’t resume",systemImage:"checkmark.shield")
                                Text("It may have been visible earlier. Keep this private recording; edit and save a new version if you want to publish again.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            } else {Label("This device kept the server confirmation",systemImage:"checkmark.circle").foregroundStyle(.green)}
                            Button("Remove private publication copy…",role:.destructive) {confirming = .remove}.frame(minHeight:44).disabled(busy).accessibilityIdentifier("audioPendingRemove")
                        }
                    }
                    if busy {ProgressView("Working with the original recording…")}
                    if let notice=notice ?? controller.notice {Section {Text(notice).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("audioPendingNotice")}}
                } else if controller.working {ProgressView("Opening original recording…")}
                else {Text(current ? (controller.notice ?? "This publication changed. Reopen its current copy."):"Publication review closed.").foregroundStyle(.secondary)}
            }.formStyle(.grouped).navigationTitle("Publication review")
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button("Close") {close();dismiss()}}}
        }
        #if os(macOS)
        .frame(minWidth:520,minHeight:500)
        #endif
        .task {await controller.select(request.journal)}
        .alert(confirming?.title ?? "",isPresented:Binding(get:{confirming != nil},set:{if !$0 {confirming=nil}}),presenting:confirming) {action in
            Button(action.button,role:action == .resume ? nil:.destructive) {
                confirming=nil
                guard let journal=controller.selected else {return}
                switch action {
                case .resume:run {
                    controller.stopPlayback();let publisher=try store.audioPendingPublisher(journal,library:controller);flow=publisher
                    try await publisher.retry(journal);guard current,!Task.isCancelled else {return};try await controller.updateAfterConfirmation();notice=outcome(publisher)
                }
                case .close:run {try await checkOriginal(journal,closing:true)}
                case .remove:run {try await controller.removeResolvedCopy();dismiss()}
                }
            }.accessibilityIdentifier("audioPendingConfirm")
            Button("Cancel",role:.cancel) {confirming=nil}
        } message: {action in Text(action.message)}
        .onChange(of:current) {_,value in if !value {close();dismiss()}}
        .onDisappear {close()}
    }
    private func outcome(_ value:AudioCommentPublicationFlow)->String {
        switch value.state {
        case .published:return "The original send was confirmed. This private recording is still kept here."
        case .closed:return "Original publication closed. This private recording is still kept here."
        default:return "The original send is still unconfirmed. Checking did not upload audio. You can keep the recording or explicitly close the original send."
        }
    }
    private func checkOriginal(_ journal:AudioCommentPublicationJournal,closing:Bool) async throws {
        controller.stopPlayback();let checker=try store.audioPendingChecker(journal,library:controller);flow=checker
        try await checker.checkPublication(journal,closing:closing)
        guard current,!Task.isCancelled else {return};try await controller.updateAfterConfirmation();notice=outcome(checker)
    }
    private func run(_ action:@escaping @MainActor () async throws -> Void) {
        guard current,!busy else {return};notice=nil
        operation=Task {
            defer {operation=nil}
            do {try await action()}
            catch {if current,!Task.isCancelled {notice=error is AccountSessionAuthorizationRequired ? "Sign in again before checking this publication. Your recording is preserved.":error.localizedDescription}}
        }
    }
    private func close() {operation?.cancel();operation=nil;flow?.invalidate();flow=nil;confirming=nil;controller.clearSelection()}
}
