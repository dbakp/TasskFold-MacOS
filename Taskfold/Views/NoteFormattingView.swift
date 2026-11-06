import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct NoteFormatRequest: Identifiable {
    let id = UUID()
    let taskID: String
    let original: String
    let workspace: WorkspaceBinding
    let generation: JSON
    let storedText: String?
    var source: Record? = nil
    var sourceRootID: String? = nil
    var admission: TaskEditorAdmission? = nil
    var title = "Format notes"
    var confirmation = "Apply"
    var focusOnOpen = false
}

/// Native, selectable note blocks. Every link has already passed the web-only policy;
/// this view never fetches metadata, images, HTML or other embedded resources.
struct NoteMarkupPreview: View {
    @Environment(\.dynamicTypeSize) private var textSize
    let text: String
    var offersOriginalText = false
    var scrollToHeading: ((Int) -> Void)? = nil
    @State private var prepared: NoteMarkup.Prepared?
    @State private var originalText = false
    @State private var contentsPresented = false
    @State private var selectedHeading: HeadingSelection?
    private struct HeadingSelection { let source: String; let id: Int }
    #if DEBUG
    @State private var observedBlocks: Set<Int> = []
    private var observesBlocks: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--workspace-long-note-reading") }
    #endif
    var body: some View {
        Group {
            if let reading = prepared, NoteMarkup.Source(reading.source) == NoteMarkup.Source(text) {
                VStack(alignment: .leading, spacing: 12) {
                    #if DEBUG
                    if observesBlocks { Text("Loaded blocks: \(observedBlocks.count)").font(.caption).accessibilityIdentifier("noteRealizedBlocks") }
                    #endif
                    if offersOriginalText, reading.document.formatted {
                        Toggle("Show original text", isOn: $originalText).accessibilityIdentifier("noteOriginalText")
                    }
                    if reading.document.originalOnly || (offersOriginalText && (!reading.document.formatted || originalText)) {
                        Text(text).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier(offersOriginalText ? "pinnedNoteText" : "notePreviewOriginal")
                    } else {
                        blocks(reading).accessibilityIdentifier(offersOriginalText ? "formattedPinnedNote" : "notePreviewBlocks")
                    }
                }
            } else {
                ProgressView("Preparing note…").frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("notePreviewLoading")
            }
        }
        .toolbar {
            if let reading = prepared, NoteMarkup.Source(reading.source) == NoteMarkup.Source(text), reading.headings.count > 1, !originalText, scrollToHeading != nil {
                ToolbarItem(placement: .primaryAction) {
                    contentsControl(reading)
                }
            }
        }
        .sheet(isPresented: $contentsPresented, onDismiss: finishContentsSelection) { contentsSheet }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in NoteMarkup.safeURL(url.absoluteString) == nil ? .discarded : .systemAction(url) })
        .task(id: NoteMarkup.Source(text)) {
            guard prepared.map({ NoteMarkup.Source($0.source) == NoteMarkup.Source(text) }) != true else { return }
            prepared = nil; originalText = false; selectedHeading = nil; contentsPresented = false
            #if DEBUG
            observedBlocks = []
            #endif
            do {
                let reading = try await NoteMarkup.Prepared.load(text)
                try Task.checkCancellation()
                prepared = reading
            } catch is CancellationError { }
            catch { /* Preparation only throws cancellation; never replace saved text. */ }
        }
    }
    private func jump(_ id: Int, source: String) {
        guard prepared.map({ NoteMarkup.Source($0.source) == NoteMarkup.Source(source) }) == true, NoteMarkup.Source(text) == NoteMarkup.Source(source), !originalText else { return }
        scrollToHeading?(id)
    }
    private func contentsControl(_ reading: NoteMarkup.Prepared) -> some View {
        Group {
            if textSize.isAccessibilitySize {
                Button { selectedHeading = nil; contentsPresented = true } label: { Label("Jump to section", systemImage: "list.bullet") }
            } else {
                Menu {
                    ForEach(reading.headings) { heading in
                        Button(heading.title) { jump(heading.id, source: reading.source) }.accessibilityIdentifier("noteHeadingJump-\(heading.id)")
                    }
                } label: { Label("Jump to section", systemImage: "list.bullet") }
            }
        }.accessibilityIdentifier("noteContents").help("Jump to a section")
    }
    private var contentsSheet: some View {
        NavigationStack {
            List {
                if let reading = prepared, NoteMarkup.Source(reading.source) == NoteMarkup.Source(text) {
                    ForEach(reading.headings) { heading in
                        Button {
                            selectedHeading = .init(source: reading.source, id: heading.id); contentsPresented = false
                        } label: {
                            Text(heading.title).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("noteHeadingJump-\(heading.id)")
                    }
                } else { Text("This note changed. Close sections and reopen them to see the latest headings.") }
            }.navigationTitle("Note sections")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selectedHeading = nil; contentsPresented = false }.accessibilityIdentifier("closeNoteContents") } }
        }
        #if os(iOS)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 420, minHeight: 400)
        #endif
    }
    private func finishContentsSelection() {
        guard let selection = selectedHeading else { return }
        selectedHeading = nil
        jump(selection.id, source: selection.source)
    }
    private func blocks(_ reading: NoteMarkup.Prepared) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(reading.document.blocks, id: \.scrollID) { block in
                Group {
                    switch block.kind {
                    case .paragraph:
                        Text(reading.inlineText[block.id] ?? AttributedString(block.text)).frame(maxWidth: .infinity, alignment: .leading)
                    case .heading(let level):
                        Text(reading.inlineText[block.id] ?? AttributedString(block.text)).font(level <= 2 ? .title3.weight(.semibold) : .headline)
                            .accessibilityAddTraits(.isHeader).frame(maxWidth: .infinity, alignment: .leading)
                    case .bullet:
                        list(block, marker: "•", text: reading.inlineText[block.id] ?? AttributedString(block.text))
                    case .numbered(let marker):
                        list(block, marker: marker, text: reading.inlineText[block.id] ?? AttributedString(block.text))
                    case .quote:
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3)
                            Text(reading.inlineText[block.id] ?? AttributedString(block.text)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }.fixedSize(horizontal: false, vertical: true).padding(.leading, CGFloat(block.depth) * 12)
                    case .code(let language):
                        VStack(alignment: .leading, spacing: 6) {
                            if !language.isEmpty { Text(language).font(.caption).foregroundStyle(.secondary) }
                            Text(block.text).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(12).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                    case .divider: Divider()
                    case .space: Color.clear.frame(height: 2).accessibilityHidden(true)
                    }
                }.id(block.scrollID).accessibilityIdentifier("noteBlock-\(block.id)")
                #if DEBUG
                .onAppear { if observesBlocks { observedBlocks.insert(block.id) } }
                #endif
            }
        }.scrollTargetLayout()
    }
    private func list(_ block: NoteMarkup.Block, marker: String, text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, maxWidth: 64, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.leading, CGFloat(block.depth) * 14).accessibilityElement(children: .combine)
    }
}

struct NoteFormattingView: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: NoteFormatRequest
    /// Returns a review-specific error, or nil after the caller accepts the text.
    let apply: (String) -> String?
    @State private var recoverySession: TaskEditorSession?
    @State private var sourceRecord: Record?
    @State private var sourceContext: TaskEditorSourceContext?
    @State private var editorFinished = false
    @State private var accessStopped = false
    @State private var text: String
    @State private var selection: TextSelection?
    @State private var preview = false
    @State private var previewScrollID: String?
    @State private var link = false
    @State private var url = "https://"
    @State private var linkSelection: NSRange?
    @State private var message: String?
    @State private var discard = false
    @FocusState private var focused: Bool
    init(request: NoteFormatRequest, apply: @escaping (String) -> String?) {
        self.request = request; self.apply = apply; _text = State(initialValue: request.original)
    }
    private var available: Bool {
        guard !accessStopped,request.workspace.matches(account:store.userID,generation:store.workspaceGeneration) else {return false}
        if let admission=request.admission,(!admission.matches(account:store.userID,generation:store.workspaceGeneration,currentRoot:store.record("tasks",id:admission.rootID)) || !store.editorMayWrite(source:admission.source.root ?? admission.source.record,proposed:admission.source.record,teamDraft:admission.teamDraft)) {return false}
        guard let sourceRecord else {return true}
        guard let sourceContext,store.editorMayWrite(source:sourceContext.root ?? sourceRecord,proposed:sourceRecord,teamDraft:request.admission?.teamDraft),sourceContext.matches(sourceContext.root.flatMap{store.record("tasks",id:$0.id)}) else {return false}
        return true
    }
    private func checkpoint() {
        guard !editorFinished else {return}
        guard NoteMarkup.Source(text) != NoteMarkup.Source(request.original) else {_=recoverySession?.finish();return}
        if recoverySession?.closed==true,let sourceRecord,request.workspace.matches(account:store.userID,generation:store.workspaceGeneration) {recoverySession=try? store.beginEditorSession(sourceRecord)}
        guard let session=recoverySession else {return}
        var draft=session.original;draft["description"] = .string(text)
        session.capture(draft,extras:["source_identity":sourceContext?.identity ?? .null,"formatting":.bool(true),"link_url":.string(url)])
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if available {
                    #if DEBUG
                    if store.noteConcurrentFixtureEnabled, let original = request.storedText {
                        Button("Other edit") { store.simulateConcurrentNoteEditForTesting(taskID: request.taskID, original: original) }
                            .accessibilityIdentifier("simulateConcurrentNoteEdit").padding(.horizontal)
                    }
                    #endif
                    Group {
                        if textSize.isAccessibilitySize { modePicker.pickerStyle(.menu) }
                        else { modePicker.pickerStyle(.segmented) }
                    }.padding()
                    if preview {
                        ScrollView {
                            if text.isEmpty { ContentUnavailableView("Your note starts here", systemImage: "text.alignleft", description: Text("Write a few words, then preview the formatting.")) }
                            else { NoteMarkupPreview(text: text, scrollToHeading: { previewScrollID = NoteMarkup.scrollID($0) }).padding(20).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("noteFormatPreview") }
                        }.scrollPosition(id: $previewScrollID, anchor: .top)
                    } else {
                        if message == nil {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                tool("Bold", "bold", .bold)
                                tool("Italic", "italic", .italic)
                                tool("Heading", "textformat.size", .heading)
                                tool("Bullets", "list.bullet", .bullet)
                                tool("Numbered list", "list.number", .numbered)
                                tool("Quote", "text.quote", .quote)
                                tool("Code", "chevron.left.forwardslash.chevron.right", .code)
                                Button { guard let span = selectedRange else { focused = false; message = "Choose one text selection before adding a link."; return }; linkSelection = span; url = "https://"; message = nil; link = true } label: { Label("Link", systemImage: "link") }.accessibilityIdentifier("noteFormat-link")
                            }.buttonStyle(.bordered).padding(.horizontal).padding(.bottom, 10)
                        }
                        }
                        TextEditor(text: $text, selection: $selection)
                            .font(.body).padding(.horizontal, 16).focused($focused)
                            .accessibilityLabel("Note text").accessibilityIdentifier("noteFormatText")
                        if !focused && message == nil {
                            Text("Select words or lines, then choose a style. Preview before applying; the original text stays available.")
                                .font(.caption).foregroundStyle(.secondary).padding()
                        }
                    }
                    if let message {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView {
                                Text(message).foregroundStyle(.red).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("noteFormatError")
                            }
                            .frame(height: textSize.isAccessibilitySize ? 160 : 120)
                            .accessibilityIdentifier("noteFormatErrorScroll")
                            Button("Copy text", action: copyText).frame(minHeight: 44)
                        }.padding()
                    }
                } else {
                    ScrollView {VStack(alignment:.leading,spacing:16) {
                        Label("Editing paused",systemImage:"lock.shield").font(.title2)
                        Text("Reopen the current task before editing again.")
                        if let session=recoverySession,session.latest != nil {
                            Text(session.preserved ? "Your unsent formatting is saved privately in Unsent task edits.":"Preserving your unsent formatting…")
                            if let failure=session.failure {Text(failure).foregroundStyle(.red);Button("Retry preserving edit") {_=session.flush()}}
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}
                }
            }.navigationTitle(request.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(request.confirmation) { guard available else { return }; if let error = apply(text) { focused = false; message = error } else { editorFinished=true;_=recoverySession?.finish();dismiss() } }
                            .disabled(!available || link).accessibilityIdentifier("applyNoteFormatting")
                    }
                }
                .onChange(of: store.workspaceGeneration) { _, _ in link = false; focused = false }
                .onChange(of: focused) { _, editing in if editing { message = nil } }
                .onChange(of: preview) { _, reading in if reading { focused = false } }
                .interactiveDismissDisabled(NoteMarkup.Source(text) != NoteMarkup.Source(request.original))
                .confirmationDialog("Discard your formatting changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard changes", role: .destructive) {if recoverySession?.finish() != false {editorFinished=true;dismiss()}} }
                .sheet(isPresented: $link) {
                    NavigationStack {
                        Form {
                            TextField("Web address", text: $url).autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never).keyboardType(.URL)
                                #endif
                                .accessibilityIdentifier("noteLinkURL")
                            Text("The selected words become the link label. Only web links are supported.").font(.caption).foregroundStyle(.secondary)
                            if let message { Text(message).foregroundStyle(.red) }
                        }.navigationTitle("Add a link")
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { link = false; message = nil } }
                                ToolbarItem(placement: .confirmationAction) { Button("Add link") { format(.link, span: linkSelection); if message == nil { link = false } }.accessibilityIdentifier("confirmNoteLink") }
                            }
                    }
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 250)
                    #endif
                }
        }
        .onAppear {
            guard recoverySession==nil,available else {return}
            var original=request.source ?? store.record("tasks",id:request.taskID) ?? Record(["id":.string(request.taskID),"title":.string("Recovered notes"),"description":.string(request.original),"task_generation":request.generation])
            original["description"] = .string(request.original)
            sourceRecord=original;sourceContext=request.admission?.source ?? TaskEditorSourceContext(record:original,root:store.record("tasks",id:request.sourceRootID ?? SubtaskTree.referencePath(request.taskID)?.first ?? request.taskID))
            do {recoverySession=try store.beginEditorSession(original)} catch {message="Your note could not be protected. Keep this editor open and retry."}
            if request.focusOnOpen, recoverySession != nil { focused = true }
        }
        .onChange(of: NoteMarkup.Source(text)) { _, _ in previewScrollID = nil; checkpoint() }
        .onChange(of:available) {_,value in if !value {checkpoint();accessStopped=true;link=false;focused=false}}
        .onDisappear {checkpoint()}
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 520, idealHeight: 650)
        #endif
    }
    private var modePicker: some View {
        Picker("Note view", selection: $preview) { Text("Write").tag(false); Text("Preview").tag(true) }
            .accessibilityIdentifier("noteFormatMode")
    }
    private var selectedRange: NSRange? {
        if let selection {
            guard case .selection(let range) = selection.indices else { return nil }
            return NSRange(range, in: text)
        }
        return NSRange(location: text.utf16.count, length: 0)
    }
    private func tool(_ title: String, _ symbol: String, _ style: NoteFormatting.Style) -> some View {
        Button { format(style) } label: { Label(title, systemImage: symbol) }
            .accessibilityIdentifier("noteFormat-" + style.rawValue)
    }
    private func format(_ style: NoteFormatting.Style, span: NSRange? = nil) {
        do {
            guard available else { return }
            guard let span = span ?? selectedRange else { throw AppFailure(message: "Choose one text selection before formatting it.") }
            let edit = try NoteFormatting.apply(style, to: text, selection: span, url: url)
            text = edit.text
            if let range = Range(edit.selection, in: text) { selection = TextSelection(range: range) }
            message = nil; focused = true
        } catch { focused = false; message = error.localizedDescription }
    }
    private func cancel() { if !available {checkpoint();if recoverySession?.latest==nil || recoverySession?.flush()==true {editorFinished=true;dismiss()}} else if NoteMarkup.Source(text) != NoteMarkup.Source(request.original) { discard = true } else { dismiss() } }
    private func copyText() {
        guard available else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
