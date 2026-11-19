import SwiftUI
import os
import Security

struct SharedDraftsView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var binding: WorkspaceBinding?
    @State private var drafts: [SharedCaptureDraft] = []
    @State private var selected: SharedCaptureDraft?
    @State private var discarding: SharedCaptureDraft?
    @State private var loading = false
    @State private var discardingInProgress = false
    @State private var reader = SharedCaptureReviewReader()
    @State private var message: String?
    var body: some View {
        WorkflowShell(title: "Shared drafts") {
            List {
                Section {
                    Text("Capture a thought or web link with the Share menu in another app. Review it here, choose its destination and add it when you’re ready.").foregroundStyle(.secondary)
                    Text("Drafts stay on this device and belong to the workspace where they were captured.").font(.caption).foregroundStyle(.secondary)
                }
                #if DEBUG
                if SharedCaptureCountNativeFixture.enabled && SharedCaptureCountNativeFixture.reviewEnabled {
                    Button("Release review read") { Task { await SharedCaptureCountNativeFixture.reviewGate?.resume() } }.accessibilityIdentifier("releaseSharedReview")
                }
                #endif
                if let message { Section { Text(message).foregroundStyle(.red); Button("Try again", action: refresh) } }
                if discardingInProgress { Section { ProgressView("Discarding draft…").accessibilityIdentifier("sharedDraftDiscarding") } }
                if loading { Section { ProgressView("Loading shared drafts…").accessibilityIdentifier("sharedDraftsLoading") } }
                if !loading && drafts.isEmpty && message == nil {
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
                    }.buttonStyle(.plain).disabled(discardingInProgress).accessibilityIdentifier("sharedDraft-" + draft.taskID)
                        .contextMenu { Button("Discard draft", role: .destructive) { discarding = draft } }
                }
            }
        }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise", action: refresh).disabled(discardingInProgress).accessibilityIdentifier("refreshSharedDrafts") }
        .onAppear {
            if binding == nil { binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) }
            refresh()
        }
        .onChange(of: phase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: store.sharedCaptureReadContext) { before, after in
            // Receipt and destination refreshes must not discard an open edit.
            // Loss/change of the private workspace or session still closes it.
            if before?.workspace != after?.workspace || before?.session != after?.session || before?.origin != after?.origin { selected = nil }
            discarding = nil; refresh()
        }
        .onDisappear { reader.invalidate(); loading = false; drafts = [] }
        .sheet(item: $selected, onDismiss: refresh) { draft in SharedDraftReview(draft: draft, binding: binding) }
        .confirmationDialog("Discard this draft?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("Discard draft", role: .destructive) {
                guard let draft = discarding else { return }
                guard !discardingInProgress else { return }
                discardingInProgress = true; discarding = nil; message = nil
                Task { @MainActor in
                    defer { discardingInProgress = false }
                    do { try await store.discardSharedCapture(draft, binding: binding); refresh() }
                    catch { message = error.localizedDescription }
                }
            }
        } message: { Text("Only this saved draft will be removed. Your tasks stay unchanged.") }
    }
    private func refresh() {
        drafts = []; message = nil; loading = true
        store.loadSharedCaptureDrafts(binding, reader: reader) { result in
            loading = false
            switch result {
            case .success(let loaded): drafts = loaded; message = nil
            case .failure(let error): drafts = []; message = error.localizedDescription
            }
        }
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
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        WorkflowShell(title: "Review shared draft") {
            if binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true {
                Form {
                    #if DEBUG
                    if SharedCaptureCountNativeFixture.enabled && SharedCaptureCountNativeFixture.reviewEnabled {
                        Section {
                            Button("Refresh another receipt") { store.refreshSharedReviewReceiptNative() }.accessibilityIdentifier("refreshSharedReviewReceipt")
                            Button("Restore test receipts") { store.refreshSharedReviewReceiptNative(restore: true) }.accessibilityIdentifier("restoreSharedReviewReceipt")
                            if SharedCaptureCountNativeFixture.actionsEnabled {
                                Button("Release mailbox action") { Task { await SharedCaptureCountNativeFixture.actionGate?.resume() } }.accessibilityIdentifier("releaseSharedAction")
                            }
                        }
                    }
                    #endif
                    Section("Task") {
                        TextField("Title", text: $title, axis: .vertical).accessibilityIdentifier("sharedDraftTitle")
                        TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...12).accessibilityIdentifier("sharedDraftNotes")
                        TextField("Source link (optional)", text: $source, axis: .vertical).accessibilityIdentifier("sharedDraftSource")
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                    }
                    .disabled(saving)
                    Section("Destination") {
                        Picker("Project", selection: $project) { Text("Inbox").tag(""); ForEach(store.projects) { Text($0.name).tag($0.id) } }
                        Text("Shared text is kept as written. Dates, labels and priorities are not inferred from it.").font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(saving)
                    Section {
                        Button(saving ? "Adding task…" : "Add task", action: save).disabled(saving || (try? content()) == nil).accessibilityIdentifier("addSharedDraft")
                        Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
                    }
                    if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("sharedDraftError") }
                }.formStyle(.grouped).accessibilityIdentifier("sharedDraftReviewForm")
            } else { ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Reopen shared drafts in your current workspace.")) }
        }.interactiveDismissDisabled(saving)
        .onAppear { title = draft.content.title; notes = draft.content.notes; source = draft.content.source }
    }
    private func content() throws -> SharedCaptureContent { try SharedCaptureContent(title: title, notes: notes, source: source) }
    private func save() {
        guard !saving else { return }
        do {
            let content = try content(), destination = project
            let requestContext = store.sharedCaptureReadContext
            saving = true; message = nil
            Task { @MainActor in
                defer { saving = false }
                do {
                    let saved: Bool
                    #if os(macOS)
                    saved = try await store.addSharedCapture(draft, content: content, project: destination, binding: binding) { change in
                        var committed = false
                        workspace.run("Add Shared Task") { committed = store.commit([change], sharedCaptureReceipt: draft) }
                        return committed
                    }
                    #else
                    saved = try await store.addSharedCapture(draft, content: content, project: destination, binding: binding)
                    #endif
                    guard let requestContext, let current = store.sharedCaptureReadContext,
                          current.workspace == requestContext.workspace, current.session == requestContext.session,
                          current.origin == requestContext.origin else { return }
                    if saved { dismiss() }
                    else {
                        message = store.error ?? "This task couldn’t be saved. Your draft is kept; please try again."
                        store.error = nil
                    }
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
}

/// Storage permission can wait independently of the first app window. On the Mac this sits inside the detail
/// column, never above the split view, so it cannot cover column headers (mac-r2 CAL-1).
struct SharedStorageSetupBanner: View {
    @Environment(Store.self) private var store
    @State private var visible = false
    @State private var takingLonger = false
    @State private var dismissed = false
    /// Debug UI tests and screenshots force the failed state on, whatever the build's signing.
    static var forced: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--force-setup-banner")
        #else
        false
        #endif
    }
    /// An unsigned Debug build has no App Group, so widgets can never connect. Say so once in the log rather than
    /// showing a banner the developer cannot act on (mac-r2 CAL-2). Release builds always show it.
    @MainActor static let suppressed: Bool = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--hide-setup-banner") { return true }
        guard !forced, !SharedStartupNativeFixture.enabled, !SharedStorageAvailability.appGroupEntitled else { return false }
        SharedStorageAvailability.logger.notice("Debug build without an App Group: widgets and shared drafts stay off, and the setup banner is hidden.")
        return true
        #else
        return false
        #endif
    }()
    private var failed: Bool { Self.forced || store.startupSharingFailed }
    private var shown: Bool { Self.forced ? !dismissed : visible && !store.startupSharedStorageReady && !dismissed }
    var body: some View {
        VStack(spacing: 0) {
            if !Self.suppressed && shown {
                HStack(alignment: .center, spacing: 8) {
                    if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary).accessibilityHidden(true) }
                    else if store.startupSharingWorking && !takingLonger { ProgressView().controlSize(.mini) }
                    Text(failed ? "Widgets can’t see your tasks yet. Your tasks are safe." : takingLonger ? "Widgets are taking longer than usual to connect. Your tasks are safe." : "Connecting widgets…")
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help(takingLonger && !failed ? "You can keep using Taskfold. If macOS shows an access request for Taskfold, respond to it." : "")
                        .accessibilityIdentifier("startupSharedStorageStatus")
                    Spacer(minLength: 0)
                    if failed || !store.startupSharingWorking {
                        Button("Try Again") { dismissed = false; store.retryStartupPublication() }.buttonStyle(.link)
                            .accessibilityIdentifier("retryStartupSharedStorage")
                    }
                    Button { dismissed = true } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Hide until the next launch")
                        .accessibilityLabel("Dismiss storage status")
                        .accessibilityHint("Taskfold keeps trying in the background.")
                        .accessibilityIdentifier("dismissStartupSharedStorageStatus")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5).frame(minHeight: 28)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("startupSharedStorageBanner")
            }
        }.task(id: store.startupSharedStorageReady) {
            visible = false; takingLonger = false; dismissed = false
            guard !store.startupSharedStorageReady else { return }
            do {
                try await Task.sleep(for: .milliseconds(350)); visible = true
                try await Task.sleep(for: .seconds(10)); takingLonger = true
            } catch { }
        }
    }
}

/// Whether this build can reach the App Group that widgets and the share extension read.
enum SharedStorageAvailability {
    static let logger = Logger(subsystem: "com.dbakp.taskfold", category: "SharedStorage")
    static let appGroupEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String] else { return false }
        return !value.isEmpty
    }()
}
