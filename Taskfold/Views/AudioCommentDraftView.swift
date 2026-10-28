import SwiftUI
import AppKit

@MainActor struct AudioCommentDraftView: View {
    let request: AudioCommentDraftRequest
    let liveScope: () -> AudioCommentLiveScope?
    @State private var capture: AudioCommentCapture
    @State private var leaving = false
    @State private var deleting = false
    @State private var pendingDiscard: AudioCommentSaveIntent?
    @FocusState private var captionFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    init(request: AudioCommentDraftRequest, storage: AudioCommentDraftStorage, recorder: any AudioCommentRecording, player: any AudioCommentPlaying, liveScope: @escaping () -> AudioCommentLiveScope?) {
        self.request = request; self.liveScope = liveScope
        _capture = State(initialValue: .init(request: request, recorder: recorder, player: player, storage: storage))
    }
    private var valid: Bool { liveScope().map(request.scope.matches) == true }
    var body: some View {
        NavigationStack {
            Group {
                if valid, capture.session.phase != .closed {
                    Form {
                        Section {
                            Label(request.title, systemImage: "waveform").font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            Text("Private to this workspace on this device.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Section {
                            if stackStatus {
                                VStack(alignment: .leading, spacing: 10) { statusLabel; durationLabel }.frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                HStack(alignment: .firstTextBaseline) { statusLabel; Spacer(minLength: 12); durationLabel }
                            }
                            if capture.session.clip == nil, let notice = capture.notice { noticeText(notice) }
                            if capture.loading || capture.saving { ProgressView(capture.saving ? "Saving recording…" : "Opening recording…") }
                            else if capture.session.phase == .finishing {
                                ProgressView("Checking recording…")
                                Button("Cancel processing") { capture.cancelRecording() }.accessibilityIdentifier("audioCancelProcessing")
                            } else if capture.recordingBusy {
                                Button(capture.session.phase == .authorizing ? "Cancel request" : "Stop recording", systemImage: "stop.fill") { capture.stop() }
                                    .buttonStyle(.borderedProminent).accessibilityIdentifier("audioStop")
                            } else {
                                Button(capture.session.clip == nil ? "Record" : "Replace recording", systemImage: "mic.fill") { capture.start() }
                                    .buttonStyle(.borderedProminent).disabled(!capture.editable).accessibilityIdentifier("audioRecord")
                            }
                            Text("Up to 2 minutes. Reviewed audio has a private recovery copy; Save keeps a draft.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let clip = capture.session.clip {
                                Button(capture.playing ? "Stop playback" : "Play recording", systemImage: capture.playing ? "stop.fill" : "play.fill") {
                                    if capture.playing { capture.stopPlayback() } else { capture.play() }
                                }.buttonStyle(.bordered).disabled(!capture.editable).accessibilityIdentifier("audioPlayback")
                                Text("\(clock(Double(clip.descriptor.milliseconds) / 1000)) · AAC audio").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if capture.session.clip != nil {
                            Section("Caption (optional)") {
                                TextEditor(text: Binding(get: { capture.session.caption }, set: { capture.editCaption($0) }))
                                    .frame(minHeight: textSize.isAccessibilitySize ? 220 : 120).font(.body).focused($captionFocused).disabled(!capture.editable)
                                    .accessibilityLabel("Recording caption").accessibilityIdentifier("audioCaption")
                                Button(capture.saveUnconfirmed ? "Retry save" : capture.saved != nil && !capture.needsSave ? "Saved on this device" : "Save draft", systemImage: capture.saved != nil && !capture.needsSave ? "checkmark.circle.fill" : "square.and.arrow.down") { Task { _ = await capture.save() } }
                                    .disabled(capture.busy || !valid || capture.saveConflict || capture.saved != nil && !capture.needsSave).accessibilityIdentifier("audioSave")
                                if let notice = capture.notice { noticeText(notice) }
                                if capture.saveConflict {
                                    Button("Save as separate draft", systemImage: "doc.badge.plus") { Task { _ = await capture.saveSeparateDraft() } }
                                        .disabled(capture.busy).accessibilityIdentifier("audioSaveCopy")
                                }
                                if let failure = capture.recovery.failure {
                                    Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Button("Retry recovery copy") { Task { _ = await capture.preserveReview() } }.disabled(capture.busy).accessibilityIdentifier("audioRetryRecovery")
                                } else if capture.recovery.pending {
                                    Text("Keeping a recovery copy…").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("audioRecoveryStatus")
                                } else if capture.recovery.durable {
                                    Text("Recovery copy kept privately on this device.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("audioRecoveryStatus")
                                }
                            }
                        }
                        if capture.retainedRecoveryFailed && !capture.hasUnwrittenSaves {
                            Section("Recovery needs attention") {
                                Text("An interrupted review is waiting for a recovery copy. Keep Taskfold open and retry before quitting.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button("Retry interrupted reviews") { Task { await capture.refresh() } }.disabled(capture.busy).accessibilityIdentifier("audioRetryInterrupted")
                            }
                        }
                        if !capture.pendingSaves.isEmpty { pendingSaveSection }
                        if !capture.recoverable.isEmpty {
                            Section("Interrupted reviews") {
                                Text("Review a recovered recording before saving it. Earlier saved drafts stay separate.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                ForEach(capture.recoverable, id: \.id) { draft in
                                    Button { Task { await capture.restore(draft, recovering: true) } } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(draft.caption.isEmpty ? "Recovered recording" : draft.caption).lineLimit(3)
                                            Text(clock(Double(draft.clip.descriptor.milliseconds) / 1000)).font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    }.disabled(!capture.editable || capture.needsSave).accessibilityIdentifier("audioRecovery-" + draft.id.uuidString.lowercased())
                                }
                            }
                        }
                        if !capture.available.isEmpty {
                            Section("Saved recordings for this task") {
                                ForEach(capture.available, id: \.id) { draft in
                                    Button {
                                        Task { await capture.restore(draft) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(draft.caption.isEmpty ? "Recording" : draft.caption).lineLimit(3)
                                            Text(clock(Double(draft.clip.descriptor.milliseconds) / 1000)).font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    }.disabled(!capture.editable || capture.needsSave).accessibilityIdentifier("audioSaved-" + draft.id.uuidString.lowercased())
                                }
                                if capture.needsSave { Text("Save this recording before opening another draft.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if capture.saved != nil {
                            Section { Button("Delete recording draft", role: .destructive) { deleting = true }.disabled(!capture.editable || capture.needsSave).accessibilityIdentifier("audioDelete") }
                        }
                    }.formStyle(.grouped).accessibilityIdentifier("audioDraftForm")
                } else { ContentUnavailableView("Recording closed", systemImage: "lock", description: Text("Reopen the task in its current workspace to continue.")) }
            }
            .navigationTitle("Audio draft")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: leave).disabled(capture.loading || capture.saving).accessibilityIdentifier("audioClose") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { if await capture.save() { capture.close(); dismiss() } } }
                        .disabled(capture.busy || capture.saveConflict || capture.session.clip == nil || !valid).accessibilityIdentifier("audioSaveClose")
                }
            }
            .confirmationDialog("Keep this recording?", isPresented: $leaving, titleVisibility: .visible) {
                if capture.saveConflict {
                    Button("Save separate draft and close") { Task { if await capture.saveSeparateDraft() { capture.close(); dismiss() } } }
                } else {
                    Button("Save draft and close") { Task { if await capture.save() { capture.close(); dismiss() } } }
                }
                if capture.canDiscardReview { Button(capture.saveConflict ? "Discard this review" : "Discard unsaved changes", role: .destructive) { Task { if await capture.discardReviewAndClose() { dismiss() } } } }
                Button("Keep reviewing", role: .cancel) { }
            } message: { Text(capture.saveConflict ? (capture.canDiscardReview ? "Save a separate draft, or discard just this review. Other saved recordings and pending Saves stay on this device." : "Save a separate draft to keep this review without replacing another version.") : capture.saveUnconfirmed ? "Retry to confirm the save before closing. Your recording is still here." : "Save this recording to keep it on this device. Any earlier saved draft remains if you discard these changes.") }
            .confirmationDialog("Discard this pending recording?", isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }), titleVisibility: .visible, presenting: pendingDiscard) { intent in
                Button("Discard pending recording", role: .destructive) { Task { await capture.discardPendingSave(intent) } }.accessibilityIdentifier("audioConfirmDiscardPending")
                Button("Cancel", role: .cancel) { }
            } message: { _ in Text("This removes the unfinished recording from this device. Earlier saved drafts stay.") }
            .confirmationDialog("Delete this recording draft?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete recording draft", role: .destructive) { Task { _ = await capture.deleteSaved() } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This removes the saved recording and caption from this device.") }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 580, idealHeight: 720)
        .background(AudioCommentQuitBridge(readyForTermination: !capture.busy).frame(width: 0, height: 0))
        #else
        .presentationSizing(.page).presentationDetents([.large])
        #endif
        #if os(iOS)
        .safeAreaInset(edge: .bottom) { if captionFocused { HStack { Spacer(); Button("Hide keyboard") { captionFocused = false }.accessibilityIdentifier("audioHideKeyboard") }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar) } }
        #endif
        .onChange(of: capture.recordingBusy) { _, busy in if busy { captionFocused = false } }
        .onChange(of: request.id) { _, _ in capture.close(); dismiss() }
        .interactiveDismissDisabled(capture.busy || capture.needsSave)
        .task { capture.currentScope = liveScope; await capture.refresh() }
        .onDisappear { capture.close() }
        .onChange(of: valid) { _, active in if !active { capture.contextChanged(); dismiss() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { _ = await capture.prepareForDeparture() }
            }
        }
    }
    private var pendingSaveSection: some View {
        Section("Saves to finish") {
            Text(capture.hasUnwrittenSaves ? "Some recordings still need to be saved on this device. Keep Taskfold open and choose Finish saving." : "Your recording is kept privately. Finish saving or discarding it below.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(capture.pendingSaves, id: \.id) { intent in
                VStack(alignment: .leading, spacing: 12) {
                    Button { Task { await capture.resumeSave(intent) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if intent.phase == .saving { Text(intent.next.caption.isEmpty ? "Finish saving recording" : intent.next.caption).lineLimit(3) }
                            Label(intent.phase == .discarding ? "Finish discarding recording" : "Finish saving", systemImage: intent.phase == .discarding ? "trash" : "arrow.clockwise")
                                .font(intent.phase == .discarding ? .body : .caption).foregroundStyle(intent.phase == .discarding ? .primary : .secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.borderless).disabled(!capture.editable || capture.needsSave).accessibilityIdentifier("audioPendingSave-" + intent.id.uuidString.lowercased())
                    if capture.isRetainedSave(intent) {
                        Text("Finish saving before discarding this recording.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if intent.phase == .saving {
                        Button("Discard pending recording", role: .destructive) { pendingDiscard = intent }
                            .buttonStyle(.borderless).disabled(!capture.editable || capture.needsSave).frame(minHeight: 44).accessibilityIdentifier("audioDiscardPending-" + intent.id.uuidString.lowercased())
                    }
                }
            }
        }
    }
    private var stackStatus: Bool {
        #if os(iOS)
        return textSize.isAccessibilitySize && sizeClass == .compact
        #else
        return false
        #endif
    }
    private var statusLabel: some View { Label(status, systemImage: capture.session.phase == .recording ? "mic.fill" : "waveform").font(.headline).foregroundStyle(capture.session.phase == .recording ? Color.red : Color.primary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioStatus") }
    private var durationLabel: some View { Text(clock(capture.elapsed)).font(.title2.monospacedDigit()).accessibilityLabel("Recording duration").accessibilityValue(clock(capture.elapsed)).accessibilityIdentifier("audioDuration") }
    private func noticeText(_ notice: String) -> some View { Text(notice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioNotice") }
    private var status: String {
        switch capture.session.phase {
        case .ready: return "Ready to record"
        case .authorizing: return "Waiting for microphone access"
        case .recording: return "Recording"
        case .finishing: return "Microphone off"
        case .review: return capture.needsSave ? "Review recording" : "Saved privately"
        default: return "Recording closed"
        }
    }
    private func clock(_ seconds: TimeInterval) -> String { let total = max(0, Int(seconds.rounded(.down))); return String(format: "%d:%02d", total / 60, total % 60) }
    private func leave() {
        capture.cancelRecording(); capture.stopPlayback()
        if capture.saveDurable { capture.close(); dismiss() }
        else if capture.needsSave { leaving = true } else { capture.close(); dismiss() }
    }
}

/// Only this audio sheet delegates normal Quit to AppDelegate's durable recovery
/// barrier. Other windows/sheets retain their own termination policy.
private struct AudioCommentQuitBridge: NSViewRepresentable {
    let readyForTermination: Bool
    final class Bridge: NSView {
        private weak var configuredWindow: NSWindow?
        private var previous: Bool?
        var readyForTermination = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() {
            guard let window, window.sheetParent != nil else { restore(); return }
            if configuredWindow !== window {
                restore(); configuredWindow = window; previous = window.preventsApplicationTerminationWhenModal
            }
            // Busy recording/decoding still uses the sheet's original protection.
            // Reviewed clips and frozen Saves are retained before onDisappear.
            window.preventsApplicationTerminationWhenModal = readyForTermination ? false : (previous ?? true)
        }
        func restore() {
            if let window = configuredWindow, let previous { window.preventsApplicationTerminationWhenModal = previous }
            configuredWindow = nil; previous = nil
        }
    }
    func makeNSView(context: Context) -> Bridge { Bridge() }
    func updateNSView(_ view: Bridge, context: Context) {
        view.readyForTermination = readyForTermination; view.install()
        // SwiftUI can attach the representable just before beginSheet sets its parent.
        DispatchQueue.main.async { [weak view] in view?.install() }
    }
    static func dismantleNSView(_ view: Bridge, coordinator: ()) { view.restore() }
}
