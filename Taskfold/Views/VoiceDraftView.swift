import SwiftUI
import Speech
#if os(iOS)
import UIKit
#endif

struct VoiceDraftView: View {
    let request: VoiceDraftRequest
    let onApply: (String) -> Bool
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("voiceDraft.locale") private var preferredLocale = ""
    @State private var capture: VoiceCapture
    @State private var applied = false
    @FocusState private var transcriptFocused: Bool
    private var languages: [String] { VoiceLanguageChoices.ids }
    private var locale: String {
        if languages.contains(preferredLocale) { return preferredLocale }
        if languages.contains(Locale.current.identifier) { return Locale.current.identifier }
        return languages.first { Locale(identifier: $0).language.languageCode == Locale.current.language.languageCode } ?? languages.first ?? "en-US"
    }
    init(request: VoiceDraftRequest, onApply: @escaping (String) -> Bool) {
        self.request = request; self.onApply = onApply
        _capture = State(initialValue: VoiceCapture(request: request, driver: VoiceRecordingFactory.make(workspace: request.workspace)))
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Label(status, systemImage: capture.session.phase == .recording ? "mic.fill" : "waveform")
                        .font(.headline).accessibilityIdentifier("voiceStatus")
                    Text("Dictate, correct the transcript, then review the tasks before saving. Audio stays on this device.").font(.callout).foregroundStyle(.secondary)
                    languageControl.disabled(capture.session.busy).accessibilityIdentifier("voiceLanguage")
                    if capture.session.phase == .finishing {
                        ProgressView("Finishing transcription…").accessibilityIdentifier("voiceFinishing")
                    } else if capture.session.busy {
                        Button(capture.session.phase == .authorizing ? "Cancel request" : "Stop recording", systemImage: "stop.fill") { capture.stop() }
                            .buttonStyle(.bordered).accessibilityIdentifier("voiceStop")
                    } else {
                        Button(capture.session.text.isEmpty ? "Start recording" : "Record another line", systemImage: "mic") { capture.start(locale: locale) }
                            .buttonStyle(.borderedProminent).disabled(applied || capture.session.phase == .closed).accessibilityIdentifier("voiceStart")
                    }
                    if let notice = capture.notice { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("voiceNotice") }
                    Text("Up to a minute per recording. Each recording adds a line; you can also split the text below.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Transcript") {
                    TextEditor(text: Binding(get: { capture.session.text }, set: { capture.edit($0) }))
                        .font(.body).frame(minHeight: textSize.isAccessibilitySize ? 260 : 150).focused($transcriptFocused).disabled(capture.session.busy || applied)
                        .accessibilityLabel("Transcript").accessibilityHint("Edit into one task per line before applying.").accessibilityIdentifier("voiceTranscript").id("voiceTranscript")
                    Text("Apply appends this text to your draft. Cancel keeps your original text.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            .onChange(of: transcriptFocused) { _, focused in
                guard focused else { return }
                let reviewID = request.id
                Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard transcriptFocused, request.id == reviewID, capture.session.phase != .closed,
                          request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("voiceTranscript", anchor: .center) }
                }
            }
            .navigationTitle("Dictate tasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { capture.close(); dismiss() }.accessibilityIdentifier("voiceCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply).accessibilityLabel("Apply transcript to draft").disabled(applied || capture.session.busy || capture.session.phase == .closed || capture.session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("voiceApply")
                }

            }
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 560, idealHeight: 660)
        #endif
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            if transcriptFocused {
                HStack { Spacer(); Button("Hide keyboard") { transcriptFocused = false }.accessibilityIdentifier("voiceHideKeyboard") }
                    .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
            }
        }
        #endif
        .onChange(of: capture.session.busy) { _, busy in if busy { transcriptFocused = false } }
        .onAppear { capture.currentWorkspace = { [store] in WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) } }
        .onDisappear { capture.close() }
        .onChange(of: request.id) { _, _ in capture.close(); dismiss() }
        .onChange(of: store.workspaceGeneration) { _, _ in capture.close(); dismiss() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { capture.stop() }
            else if phase == .inactive && capture.session.phase == .recording { capture.stop() }
        }
    }
    private var languageSelection: Binding<String> { Binding(get: { locale }, set: { preferredLocale = $0 }) }
    @ViewBuilder private var languageControl: some View {
        if textSize.isAccessibilitySize {
            Menu {
                Picker("Language", selection: languageSelection) {
                    ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Language").font(.subheadline).foregroundStyle(.secondary)
                        Text(languageName(locale)).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
            }.menuIndicator(.hidden).accessibilityLabel("Dictation language").accessibilityValue(languageName(locale))
        } else {
            Picker("Language", selection: languageSelection) {
                ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
            }
        }
    }
    private var status: String {
        switch capture.session.phase {
        case .ready: return "Ready to dictate"
        case .authorizing: return "Waiting for permission…"
        case .recording: return "Listening"
        case .finishing: return "Microphone off"
        case .review: return "Review your transcript"
        case .closed: return "Draft closed"
        }
    }
    private func languageName(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }
    private func apply() {
        do {
            let combined = try capture.session.applying(to: request.original, request: request, account: store.userID, generation: store.workspaceGeneration)
            guard onApply(combined) else { capture.notice = "The original draft changed. Reopen dictation from that draft."; return }
            applied = true; capture.close(); dismiss()
        } catch { capture.notice = error.localizedDescription }
    }
}


@MainActor private enum VoiceLanguageChoices {
    static let ids: [String] = {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        return (supported.isEmpty ? [Locale.current.identifier] : supported).sorted {
            (Locale.current.localizedString(forIdentifier: $0) ?? $0).localizedStandardCompare(Locale.current.localizedString(forIdentifier: $1) ?? $1) == .orderedAscending
        }
    }()
}
