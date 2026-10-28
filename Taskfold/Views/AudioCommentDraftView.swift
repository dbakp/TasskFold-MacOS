import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import AppKit

@MainActor struct AudioCommentDraftView: View {
    let request: AudioCommentDraftRequest
    let liveScope: () -> AudioCommentLiveScope?
    @State private var capture: AudioCommentCapture
    @State private var leaving = false
    @State private var deleting = false
    @State private var copyReview: AudioCommentInterruptedWrite?
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
                        if !capture.interrupted.isEmpty || capture.interruptionFailure != nil || capture.interruptedActionsNeedAttention {
                            interruptedSection
                        }
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
        .sheet(item: $copyReview) { write in
            NavigationStack {
                Group {
                    if valid, capture.isCurrent, let draft = capture.interruptedDraft(write) {
                        Form {
                            Section { Text("Save this as a new private draft. The saved version stays.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            Section("Recording caption") { Text(draft.caption.isEmpty ? "No caption" : draft.caption).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioCopyCaption") }
                            Section {
                                Text(clock(Double(draft.clip.descriptor.milliseconds) / 1000) + " · AAC audio").foregroundStyle(.secondary)
                                Button("Save separate draft", systemImage: "doc.badge.plus") {
                                    copyReview = nil
                                    Task { _ = await capture.saveInterruptedCopy(write) }
                                }.disabled(!capture.editable || capture.needsSave).accessibilityIdentifier("audioCopyConfirm")
                            }
                        }.accessibilityIdentifier("audioCopyForm")
                    } else { ContentUnavailableView("Recording unavailable", systemImage: "waveform") }
                }
                .navigationTitle("Keep both")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { copyReview = nil }.accessibilityIdentifier("audioCopyCancel") } }
            }
            #if os(macOS)
            .frame(minWidth: 520, idealWidth: 580, minHeight: 460, idealHeight: 620)
            #else
            .presentationSizing(.page).presentationDetents([.large])
            #endif
        }
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
    private var interruptedSection: some View {
        Section("Recordings to recover") {
            Text("Recover a recording to review it privately. Nothing is sent.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(capture.interrupted, id: \.id) { write in
                if let draft = capture.interruptedDraft(write) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.caption.isEmpty ? "Interrupted recording" : draft.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        Text(clock(Double(draft.clip.descriptor.milliseconds) / 1000)).font(.caption).foregroundStyle(.secondary)
                        Button("Recover recording", systemImage: "arrow.clockwise") { Task { _ = await capture.recoverInterrupted(write) } }
                            .buttonStyle(.borderless).frame(minHeight: 44).disabled(!capture.editable || capture.needsSave).accessibilityIdentifier("audioInterrupted-" + write.id.uuidString.lowercased())
                        Button("Keep both…", systemImage: "doc.badge.plus") { copyReview = write }
                            .buttonStyle(.borderless).frame(minHeight: 44).disabled(!capture.editable || capture.needsSave).accessibilityIdentifier("audioInterruptedCopy-" + write.id.uuidString.lowercased())
                    }
                }
            }
            if let failure = capture.interruptionFailure { Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioInterruptedWarning") }
            if capture.interruptedActionsNeedAttention {
                Text("An interrupted action is kept privately and needs a separate recovery review.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioInterruptedPending")
            }
            Button("Check again") { Task { await capture.refresh() } }.disabled(capture.busy).accessibilityIdentifier("audioCheckInterrupted")
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


/// The task editor resolves its real Store context again before opening storage
/// and throughout the nested recording screen. No permission is requested here.
@MainActor struct TaskAudioDraftView: View {
    @Environment(Store.self) private var store
    let request: AudioCommentDraftRequest
    let taskID: String
    @Environment(\.dismiss) private var dismiss
    @State private var storage: AudioCommentDraftStorage?
    @State private var failure: String?
    @State private var retry = UUID()
    private var current: Bool { store.audioDraftScope(taskID: taskID).map(request.scope.matches) == true }
    var body: some View {
        Group {
            if current, let storage {
                AudioCommentDraftView(request: request, storage: storage, recorder: recorder(), player: player(), liveScope: {
                    store.audioDraftScope(taskID: taskID)
                })
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if !current { ContentUnavailableView("Recording unavailable", systemImage: "waveform", description: Text("Reopen the current task to review its recordings.")) }
                        else if let failure { Text(failure).fixedSize(horizontal: false, vertical: true); Button("Try again") { retry = UUID() } }
                        else { ProgressView("Opening private recordings…") }
                    }.padding().navigationTitle("Audio drafts")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                }
            }
        }
        .task(id: retry) {
            guard current else { return }
            do {
                let directory = try store.audioDraftDirectory(for: request.scope, taskID: taskID)
                let opened = try await AudioCommentDraftStorage.open(applicationSupport: directory, owner: .init(request.scope.workspace.account))
                guard !Task.isCancelled, current else { return }
                storage = opened; failure = nil
            } catch { if current { failure = "Private recordings could not be opened. Existing files are kept." } }
        }
    }
    private func recorder() -> any AudioCommentRecording {
        #if DEBUG
        if AudioCommentNativeFixture.taskEditorTesting { return AudioCommentNativeFixture.taskEditorRecorder() }
        #endif
        return DeviceAudioCommentRecording()
    }
    private func player() -> any AudioCommentPlaying {
        #if DEBUG
        if AudioCommentNativeFixture.taskEditorTesting { return AudioCommentNativeFixture.taskEditorPlayer() }
        #endif
        return DeviceAudioCommentPlaying()
    }
}

/// Account-bound presentation, separate from any task editor admission.
@MainActor struct PrivateAudioLibraryView: View {
    let request: AudioCommentLibraryRequest
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: AudioCommentLibraryController?
    @State private var failure: String?
    @State private var retry = UUID()
    private var current: Bool { store.audioLibraryScope().map(request.scope.matches) == true }
    var body: some View {
        NavigationStack {
            Group {
                if !current {
                    ContentUnavailableView("Recordings closed", systemImage: "lock", description: Text("Reopen private recordings in your current workspace."))
                } else if let controller {
                    AudioSavedLibraryContent(controller: controller, taskLabel: { target in
                        guard current else { return nil }; return store.audioLibraryTask(target)
                    })
                } else if let failure {
                    VStack(spacing: 16) { Text(failure).fixedSize(horizontal: false, vertical: true); Button("Try again") { retry = UUID() } }.padding()
                } else { ProgressView("Opening private recordings…") }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Private recordings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { controller?.close(); dismiss() }.accessibilityIdentifier("audioLibraryClose")
                }
                if current, let controller {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                            .disabled(controller.working).accessibilityIdentifier("audioLibraryRefresh")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 540)
        #else
        .presentationSizing(.page)
        .presentationDetents([.large])
        #endif
        .task(id: retry) {
            guard current else { return }
            do {
                let directory = try store.audioLibraryDirectory(for: request.scope)
                let storage = try await AudioCommentDraftStorage.open(applicationSupport: directory, owner: .init(request.scope.workspace.account))
                guard current, !Task.isCancelled else { return }
                let value = AudioCommentLibraryController(scope: request.scope, storage: storage, player: player())
                value.currentScope = { store.audioLibraryScope() }
                value.setActive(scenePhase == .active); controller = value; failure = nil
                await value.refresh()
            } catch { if current, !Task.isCancelled { failure = "Private recordings could not be opened. Existing files are kept." } }
        }
        .onChange(of: current) { _, _ in controller?.contextChanged() }
        .onChange(of: scenePhase) { _, phase in
            controller?.setActive(phase == .active)
            if phase == .active, current { Task { await controller?.refresh(preservingExports: true) } }
        }
        .onDisappear { controller?.close() }
    }
    private func player() -> any AudioCommentPlaying {
        #if DEBUG
        if AudioCommentNativeFixture.taskEditorTesting { return AudioCommentNativeFixture.taskEditorPlayer() }
        #endif
        return DeviceAudioCommentPlaying()
    }
}

@MainActor private struct AudioSavedLibraryContent: View {
    @State private var exportItem: AudioRecordingTransfer?
    @State private var exportStatus: String?
    let controller: AudioCommentLibraryController
    let taskLabel: (AudioCommentTarget) -> (title: String, location: AudioCommentSavedLibrary.TaskLocation)?
    @AccessibilityFocusState(for: .voiceOver) private var captionFocused: Bool
    var body: some View {
        Form {
            if let selected = controller.selected {
                Section {
                    taskDescription(selected.target)
                    Text(selected.caption.isEmpty ? "No written caption" : selected.caption)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("audioLibraryCaption").accessibilityFocused($captionFocused)
                    Text(duration(selected)).font(.caption).foregroundStyle(.secondary)
                    Button(controller.playing ? "Stop playback" : "Play recording", systemImage: controller.playing ? "stop.fill" : "play.fill") {
                        if controller.playing { controller.stopPlayback() } else { Task { await controller.play() } }
                    }.disabled(controller.working).accessibilityIdentifier("audioLibraryPlay")
                    Button("Export recording backup…", systemImage: "square.and.arrow.up") {
                        exportStatus = nil
                        Task {
                            do { exportItem = AudioRecordingTransfer(permit: try await controller.prepareExport()) }
                            catch { if controller.isCurrent, !(error is CancellationError) { exportStatus = error.localizedDescription } }
                        }
                    }.disabled(controller.working || exportItem != nil).accessibilityIdentifier("audioLibraryExport")
                    Text("Includes audio and caption. Task and account links are left out.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Back to recordings") { invalidateExport(); controller.clearSelection() }.disabled(exportItem != nil).accessibilityIdentifier("audioLibraryBack")
                } header: { Text("Saved recording") } footer: {
                    Text("Your recording is kept independently of changes to its original task.")
                }
            } else if let library = controller.library {
                if library.drafts.isEmpty {
                    Section { ContentUnavailableView("No saved recordings", systemImage: "waveform", description: Text("Audio drafts you save in this account will appear here.")) }
                } else {
                    Section {
                        ForEach(library.drafts, id: \.id) { draft in
                            Button { Task { await controller.select(draft) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label {
                                        Text(draft.caption.isEmpty ? "Recording" : draft.caption).foregroundStyle(.primary).lineLimit(2)
                                    } icon: { Image(systemName: "waveform").foregroundStyle(.tint) }
                                    taskDescription(draft.target)
                                    Text(duration(draft)).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 4)
                            }.buttonStyle(.plain).disabled(controller.working).accessibilityIdentifier("audioLibraryRow-" + draft.id.uuidString.lowercased())
                        }
                    } header: { Text("Saved recordings") } footer: {
                        Text("Private to this account on this device. Recordings are not included in workspace backups.")
                    }
                }
                if library.recoveryFileCount + library.pendingSaveCount + library.pendingPublicationCount + library.interruptedFileCount > 0 {
                    Section {
                        Label("Additional recording work is preserved", systemImage: "waveform.badge.exclamationmark")
                        Text("This library shows finished drafts. Other recording work is kept for recovery.").font(.callout).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("audioLibraryRecoveryNotice")
                }
            }
            if controller.working { Section { ProgressView("Preparing…").accessibilityIdentifier("audioLibraryProgress") } }
            if let exportStatus { Section { Text(exportStatus).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioLibraryExportStatus") } }
            if let notice = controller.notice { Section { Text(notice).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioLibraryNotice") } }
        }.formStyle(.grouped).accessibilityIdentifier("audioLibraryForm")
            .onChange(of: controller.selected?.id) { _, value in
                captionFocused = value != nil
                if value != nil { exportStatus = nil }
            }
            .onChange(of: controller.isCurrent) { _, value in if !value { invalidateExport(); exportStatus = nil } }
            .onDisappear { invalidateExport() }
            .background { exportPresenter }
    }
    private func invalidateExport() { exportItem?.permit.invalidate(); exportItem = nil }
    @ViewBuilder private var exportPresenter: some View {
        if let item = exportItem {
            AudioRecordingSavePresenter(item: item) { id, result in
                guard exportItem?.id == id else { return }
                defer { invalidateExport() }
                guard item.permit.isAllowed else { return }
                switch result {
                case .some(.success(let url)):
                    #if DEBUG
                    AudioCommentNativeFixture.recordExportResult(url, request: id)
                    #endif
                    exportStatus = "Recording backup saved."
                case .some(.failure(let error)):
                    let value = error as NSError
                    exportStatus = value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError ? "Export cancelled." : error.localizedDescription
                case .none: exportStatus = "Export cancelled."
                }
            }.id(item.id)
        }
    }
    @ViewBuilder private func taskDescription(_ target: AudioCommentTarget) -> some View {
        if let label = taskLabel(target) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.title).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if label.location == .moved { Text("Task moved · original recording kept").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("audioLibraryMoved") }
            }
        } else {
            Text("Original task unavailable").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("audioLibraryUnavailable")
        }
    }
    private func duration(_ draft: AudioCommentSavedDraft) -> String {
        let seconds = max(1, (draft.clip.descriptor.milliseconds + 999) / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct AudioRecordingTransfer: Transferable, Identifiable, Sendable {
    let id = UUID()
    let permit: AudioCommentRecordingExport
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { item in try await item.permit.release() }
            .suggestedFileName("Taskfold-recording.json")
    }
}
@MainActor private struct AudioRecordingSavePresenter: View {
    let item: AudioRecordingTransfer
    let finish: (UUID, Result<URL, Error>?) -> Void
    @State private var showing = false
    var body: some View {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            .fileExporter(isPresented: $showing, item: item, contentTypes: [.json], defaultFilename: "Taskfold-recording",
                          onCompletion: { finish(item.id, $0) }, onCancellation: { finish(item.id, nil) })
            .task { showing = true }
            .onDisappear { item.permit.invalidate() }
    }
}
