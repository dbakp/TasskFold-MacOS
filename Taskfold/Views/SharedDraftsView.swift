import SwiftUI

struct SharedDraftsView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var binding: WorkspaceBinding?
    @State private var drafts: [SharedCaptureDraft] = []
    @State private var selected: SharedCaptureDraft?
    @State private var discarding: SharedCaptureDraft?
    @State private var message: String?
    var body: some View {
        WorkflowShell(title: "Shared drafts") {
            List {
                Section {
                    Text("Capture a thought or web link with the Share menu in another app. Review it here, choose its destination and add it when you’re ready.").foregroundStyle(.secondary)
                    Text("Drafts stay on this device and belong to the workspace where they were captured.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Section { Text(message).foregroundStyle(.red); Button("Try again", action: refresh) } }
                if drafts.isEmpty && message == nil {
                    ContentUnavailableView("A place for shared thoughts", systemImage: "square.and.arrow.down", description: Text("Choose Taskfold in another app’s Share menu to save a draft."))
                }
                ForEach(drafts) { draft in
                    Button { selected = draft } label: {
                        HStack(spacing: 12) {
                            Image(systemName: draft.content.source.isEmpty ? "text.alignleft" : "link").foregroundStyle(Color.taskfold)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.content.title).font(.headline).lineLimit(2)
                                if !draft.content.source.isEmpty { Text(draft.content.source).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Text(draft.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityIdentifier("sharedDraft-" + draft.taskID)
                        .contextMenu { Button("Discard draft", role: .destructive) { discarding = draft } }
                }
            }
        }
        .onAppear {
            if binding == nil { binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) }
            refresh()
        }
        .onChange(of: phase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: store.workspaceGeneration) { _, _ in drafts = []; selected = nil; discarding = nil; message = "Reopen shared drafts in your current workspace." }
        .sheet(item: $selected, onDismiss: refresh) { draft in SharedDraftReview(draft: draft, binding: binding) }
        .confirmationDialog("Discard this draft?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("Discard draft", role: .destructive) {
                guard let draft = discarding else { return }
                do { try store.discardSharedCapture(draft, binding: binding); discarding = nil; refresh() }
                catch { message = error.localizedDescription }
            }
        } message: { Text("Only this saved draft will be removed. Your tasks stay unchanged.") }
    }
    private func refresh() {
        do { drafts = try store.sharedCaptureDrafts(binding); message = nil }
        catch { drafts = []; message = error.localizedDescription }
    }
}

private struct SharedDraftReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    let draft: SharedCaptureDraft
    let binding: WorkspaceBinding?
    @State private var title = ""
    @State private var notes = ""
    @State private var source = ""
    @State private var project = ""
    @State private var message: String?
    var body: some View {
        WorkflowShell(title: "Review shared draft") {
            if binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true {
                Form {
                    Section("Task") {
                        TextField("Title", text: $title, axis: .vertical).accessibilityIdentifier("sharedDraftTitle")
                        TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...12).accessibilityIdentifier("sharedDraftNotes")
                        TextField("Source link (optional)", text: $source, axis: .vertical).accessibilityIdentifier("sharedDraftSource")
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                    }
                    Section("Destination") {
                        Picker("Project", selection: $project) { Text("Inbox").tag(""); ForEach(store.projects) { Text($0.name).tag($0.id) } }
                        Text("Shared text is kept as written. Dates, labels and priorities are not inferred from it.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Add task", action: save).disabled((try? content()) == nil).accessibilityIdentifier("addSharedDraft")
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("sharedDraftError") }
                }.formStyle(.grouped).accessibilityIdentifier("sharedDraftReviewForm")
            } else { ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Reopen shared drafts in your current workspace.")) }
        }.onAppear { title = draft.content.title; notes = draft.content.notes; source = draft.content.source }
    }
    private func content() throws -> SharedCaptureContent { try SharedCaptureContent(title: title, notes: notes, source: source) }
    private func save() {
        do {
            let content = try content()
            var saved = false
            #if os(macOS)
            workspace.run("Add Shared Task") { saved = store.addSharedCapture(draft, content: content, project: project, binding: binding) }
            #else
            saved = store.addSharedCapture(draft, content: content, project: project, binding: binding)
            #endif
            if saved { dismiss() }
            else {
                message = store.error ?? "This task couldn’t be saved. Your draft is kept; please try again."
                // Expected save errors belong to this review, preserving its fields and retry.
                store.error = nil
            }
        } catch { message = error.localizedDescription }
    }
}
