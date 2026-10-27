import SwiftUI

@MainActor struct AudioCommentDraftView: View {
    let request: AudioCommentDraftRequest
    let liveScope: () -> AudioCommentLiveScope?
    @State private var capture: AudioCommentCapture
    @State private var leaving = false
    @State private var deleting = false
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
                            Text("Up to 2 minutes. Replacements keep this draft until ready.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                                    .disabled(capture.busy || !valid || capture.saved != nil && !capture.needsSave).accessibilityIdentifier("audioSave")
                                if let notice = capture.notice { noticeText(notice) }
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
                    }.formStyle(.grouped)
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
                        .disabled(capture.busy || capture.session.clip == nil || !valid).accessibilityIdentifier("audioSaveClose")
                }
            }
            .confirmationDialog("Keep this recording?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Save draft and close") { Task { if await capture.save() { capture.close(); dismiss() } } }
                if !capture.saveUnconfirmed { Button("Discard unsaved changes", role: .destructive) { capture.close(); dismiss() } }
                Button("Keep reviewing", role: .cancel) { }
            } message: { Text(capture.saveUnconfirmed ? "Retry to confirm the save before closing. Your recording is still here." : "Save this recording to keep it on this device. Any earlier saved draft remains if you discard these changes.") }
            .confirmationDialog("Delete this recording draft?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete recording draft", role: .destructive) { Task { _ = await capture.deleteSaved() } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This removes the saved recording and caption from this device.") }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 580, idealHeight: 720)
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
            if phase != .active { capture.stopPlayback(); if capture.session.phase == .recording { capture.stop() } }
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
        if capture.needsSave { leaving = true } else { capture.close(); dismiss() }
    }
}
