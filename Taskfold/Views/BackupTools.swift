import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct WorkspaceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct RestoreReviewRequest: Identifiable {
    let id = UUID()
    var backup: WorkspaceBackup
    var snapshot: Snapshot
    let generation: UUID
    let account: String
    var onlyNewTask = false
}

@MainActor @Observable
private final class BackupUI {
    var history: [RecoveryEntry] = []
    var preserved: [PreservedWorkspaceFile] = []
    var editorEdits: [PreservedWorkspaceFile] = []
    var exportFilename = "Taskfold-backup"
    var confirmingRepair = false
    var didConfirmRepair: (() -> Void)?
    var daily = true
    var busy = false
    var fileRead: BackupFileReadOperation?
    func cancelFileRead() {
        fileRead?.cancel()
        fileRead = nil
        busy = false
    }
    var pickerSession = BackupPickerSession()
    var presentedPicker: BackupPickerSession.Request?
    var intendedWorkspace: UUID?
    var exporting = false
    var document: WorkspaceDocument?
    var review: RestoreReviewRequest?
    var message: String?
    var didSelectFile: ((URL, UUID) -> Void)?
    var didCloseReview: (() -> Void)?
    func cancelPicker() {
        if let request = pickerSession.request { pickerSession.cancel(request) }
        presentedPicker = nil
    }
    func deliver(_ selection: BackupPickerSession.Selection?) {
        if let selection { didSelectFile?(selection.url, selection.workspace) }
    }
    func show(_ error: Error) {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError { return }
        message = error.localizedDescription
    }
}

/// Present from the settings form itself, never a recycled section/row.
@MainActor struct BackupPresentation: ViewModifier {
    @State private var ui = BackupUI()
    func body(content: Content) -> some View {
        @Bindable var ui = ui
        let confirmingRepair = ui.confirmingRepair
        // macOS presentation bindings may evaluate outside this body's
        // observation scope. Read their state here so button actions refresh it.
        let review = ui.review
        let message = ui.message
        content.environment(ui)
            // A popped settings page must not retain a coordinated read after
            // its workspace observer and Cancel control disappear.
            .onDisappear { ui.confirmingRepair=false; ui.didConfirmRepair=nil; ui.cancelPicker(); if ui.fileRead != nil { ui.cancelFileRead() } }
            .safeAreaInset(edge: .bottom) {
                if ui.fileRead != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Opening backup…").accessibilityIdentifier("backupReadProgress")
                            Spacer(minLength: 8)
                            Button("Cancel") { ui.cancelFileRead() }
                                .accessibilityIdentifier("backupReadCancel")
                        }
                        Text("Waiting for the file provider. Your current work is unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            }
            .alert("Preserve the original and reopen?", isPresented: Binding(get:{confirmingRepair},set:{ui.confirmingRepair=$0})) {
                Button("Preserve file and reopen") { let action=ui.didConfirmRepair;ui.didConfirmRepair=nil;action?() }
                Button("Cancel",role:.cancel) {ui.didConfirmRepair=nil}
            } message: {
                Text("An encrypted, verified copy of the entire original file will be kept on this device. The unreadable working file will then be replaced. Unsynced work stays in the preserved file for repair. Cloud tasks and existing recovery copies are kept.")
            }
            .fileExporter(isPresented: $ui.exporting, document: ui.document, contentType: .json, defaultFilename: ui.exportFilename + "-" + Dates.day(Date())) { result in
                if case .failure(let error) = result { ui.show(error) }
                ui.document = nil
            }
            #if os(iOS)
            .sheet(item: $ui.presentedPicker) { request in
                BackupPickerSheet(request: request, ui: ui)
            }
            #endif
            .sheet(item: Binding(get: { review }, set: { ui.review = $0 }), onDismiss: { ui.didCloseReview?() }) { request in
                RestoreReview(request: request).presentationDetents([.large])
            }
            .alert("Backups & restore", isPresented: Binding(get: { message != nil }, set: { if !$0 { ui.message = nil } })) {
                Button("OK") { ui.message = nil }
            } message: { Text(ui.message ?? "") }
    }
}

#if os(iOS)
/// Keep dismissal and provider callbacks attached to this sheet's immutable request.
private struct BackupPickerSheet: View {
    let request: BackupPickerSession.Request
    let ui: BackupUI
    @Environment(Store.self) private var store
    var body: some View {
        BackupFilePicker { result in
            guard ui.pickerSession.accepts(request, workspace: store.workspaceGeneration) else { return }
            switch result {
            case .success(let url):
                let selection = ui.pickerSession.select(url, for: request, workspace: store.workspaceGeneration)
                ui.presentedPicker = nil
                ui.deliver(selection)
            case .failure(let error):
                ui.pickerSession.cancel(request)
                ui.presentedPicker = nil
                ui.show(error)
            }
        }
        .onDisappear {
            // UIKit can dismiss before delivering the selected URL.
            ui.deliver(ui.pickerSession.close(request, workspace: store.workspaceGeneration))
        }
    }
}
#endif

/// Each platform owns this native form, its export document and restore preview.
struct BackupTools: View {
    @State private var showingTeamDrafts=false
    @Environment(Store.self) private var store
    @Environment(BackupUI.self) private var ui
    private var history: [RecoveryEntry] { get { ui.history } nonmutating set { ui.history = newValue } }
    private var daily: Bool { get { ui.daily } nonmutating set { ui.daily = newValue } }
    private var busy: Bool { get { ui.busy } nonmutating set { ui.busy = newValue } }
    private var exporting: Bool { get { ui.exporting } nonmutating set { ui.exporting = newValue } }
    private var document: WorkspaceDocument? { get { ui.document } nonmutating set { ui.document = newValue } }
    private var review: RestoreReviewRequest? { get { ui.review } nonmutating set { ui.review = newValue } }
    private var message: String? { get { ui.message } nonmutating set { ui.message = newValue } }
    var body: some View {
        Section {
            if store.workspaceNeedsRepair {
                Label("Your saved workspace needs recovery", systemImage: "externaldrive.badge.exclamationmark")
                Text("The original file is protected. Preserve it before reopening this workspace, then sync cloud work or restore a backup.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Preserve file and reopen…") {
                    let expected=store.workspaceGeneration
                    ui.didConfirmRepair = {
                        run {
                            guard expected==store.workspaceGeneration else { throw BackupFailure(message:"The workspace changed. Review recovery again.") }
                            // Reopening changes the workspace generation and closes
                            // this settings presentation. Store supplies the success notice.
                            try await store.preserveUnreadableWorkspace()
                        }
                    }
                    ui.confirmingRepair=true
                }.accessibilityIdentifier("preserveUnreadableWorkspace")
            }
            Button("Saved team drafts",systemImage:"doc.text") {showingTeamDrafts=true}
                .disabled(store.teamDraftVault == nil).accessibilityIdentifier("savedTeamDrafts")
                .sheet(isPresented:$showingTeamDrafts){SavedTeamDraftsView()}
            Button("Back up now", systemImage: "externaldrive.badge.checkmark") { run { _ = try await store.makeRecoveryBackup(); await refreshHistory(); message = "Recovery copy saved on this device." } }
                .accessibilityIdentifier("backupNow").disabled(store.workspaceNeedsRepair)
            Button("Export workspace", systemImage: "square.and.arrow.up") {
                let backup = WorkspaceBackup.make(store.presentationSnapshot, account: store.userID)
                export(backup)
            }.accessibilityIdentifier("backupExport").disabled(store.workspaceNeedsRepair)
            Button("Restore from file", systemImage: "arrow.counterclockwise", action: chooseRestoreFile).accessibilityIdentifier("backupImport")
            Toggle("Daily recovery copies", isOn: Binding(get: { daily }, set: { daily = $0 })).accessibilityIdentifier("dailyBackups").disabled(store.workspaceNeedsRepair)
            if let warning = store.backupWarning { Text(warning).font(.callout).foregroundStyle(.secondary) }
        } header: { Text("Backups & restore") } footer: {
            Text("Keep up to 20 encrypted recovery copies on this device. Export a portable JSON backup for another device. Exported files contain your workspace data; keep them somewhere private.")
        }
        .disabled(busy || !(store.signedIn || store.localMode))
        .onChange(of: daily) { _, value in store.dailyBackupsEnabled = value }
        .task(id: store.workspaceGeneration) {
            let model = ui, owner = store
            if model.fileRead != nil, model.intendedWorkspace != owner.workspaceGeneration { model.cancelFileRead() }
            if let request = model.pickerSession.request, request.workspace != owner.workspaceGeneration { model.cancelPicker() }
            model.didSelectFile = { [weak model] url, generation in if let model { Self.readFile(url, generation: generation, store: owner, ui: model) } }
            model.didCloseReview = { [weak model] in if let model { Task { await Self.refreshHistory(store: owner, ui: model) } } }
            ui.history=[]; ui.preserved=[]; ui.editorEdits=[]
            daily = store.dailyBackupsEnabled; await refreshHistory()
        }

        if !ui.editorEdits.isEmpty {
            Section {
                ForEach(ui.editorEdits) { entry in
                    Menu {
                        Button("Review Inbox copy") { openEditorEdit(entry,exportOriginal:false) }.accessibilityIdentifier("editorRecoveryReview-"+entry.id.uuidString.lowercased())
                        Button("Export original edit") { openEditorEdit(entry,exportOriginal:true) }
                    } label: {
                        Label("Unsent edit · " + entry.createdAt.formatted(date:.abbreviated,time:.shortened),systemImage:"doc.badge.clock")
                    }.disabled(busy).accessibilityIdentifier("editorRecovery-"+entry.id.uuidString.lowercased())
                }
            } header: {Text("Unsent task edits")} footer: {
                Text("Full edits stay encrypted on this device, separately from daily copies. Review a separate Inbox copy, or export the original privately for repair. Original-edit files are not portable workspace backups.")
            }
        }
        if !ui.preserved.isEmpty {
            Section {
                ForEach(ui.preserved) { entry in
                    Button {
                        let vault=store.backupVault, generation=store.workspaceGeneration
                        run {
                            let bytes=try await Task.detached(priority: .utility) { try vault.preservedBytes(entry.id) }.value
                            guard generation==store.workspaceGeneration else { throw CancellationError() }
                            ui.exportFilename="Taskfold-preserved-workspace"
                            document=WorkspaceDocument(data:bytes); exporting=true
                        }
                    } label: {
                        Label("Export original · " + entry.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "square.and.arrow.up")
                    }.disabled(busy).accessibilityIdentifier("preservedWorkspace-"+entry.id.uuidString.lowercased())
                }
            } header: { Text("Preserved workspace files") } footer: {
                Text("Encrypted originals are kept separately from daily copies. Export only to a private location for repair. These files may be damaged and are not portable backups.")
            }
        }
        if !history.isEmpty {
            Section("Recovery copies on this device") {
                ForEach(history) { entry in
                    Menu {
                        Button("Preview restore", systemImage: "arrow.counterclockwise") { load(entry, exportFile: false) }
                        Button("Export copy", systemImage: "square.and.arrow.up") { load(entry, exportFile: true) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Text("\(entry.kind) · \(entry.records) \(entry.records == 1 ? "record" : "records")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "ellipsis.circle").foregroundStyle(Color.taskfold)
                        }.contentShape(Rectangle())
                    }.accessibilityIdentifier("recovery-" + entry.kind).disabled(busy)
                }
            }
        }
    }
    private func chooseRestoreFile() {
        #if os(macOS)
        guard let window = NSApp.keyWindow else {
            ui.show(BackupFailure(message: "Open Backups & restore again to choose a file."))
            return
        }
        // SwiftUI's fileImporter can fail to present from a Settings form.
        // Attach the native panel to the window that owns this action instead.
        let request = ui.pickerSession.begin(workspace: store.workspaceGeneration)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            // AppKit can invoke completion while the native panel remains onscreen.
            // Dismiss it before showing read progress or another restore sheet.
            panel.orderOut(nil)
            guard ui.pickerSession.accepts(request, workspace: store.workspaceGeneration) else { return }
            guard response == .OK, let url = panel.url else { ui.pickerSession.cancel(request); return }
            _ = ui.pickerSession.select(url, for: request, workspace: store.workspaceGeneration)
            ui.deliver(ui.pickerSession.close(request, workspace: store.workspaceGeneration))
        }
        #else
        ui.presentedPicker = ui.pickerSession.begin(workspace: store.workspaceGeneration)
        #endif
    }
    private static func readFile(_ url: URL, generation: UUID, store: Store, ui: BackupUI) {
        guard generation == store.workspaceGeneration else { ui.show(BackupFailure(message: "The workspace changed. Choose the backup again in the intended workspace.")); return }
        ui.fileRead?.cancel()
        ui.intendedWorkspace = generation
        let operation = BackupFileReadOperation()
        ui.fileRead = operation
        ui.busy = true
        Task {
            defer {
                if ui.fileRead === operation { ui.fileRead = nil; ui.busy = false }
            }
            do {
                let backup = try await Task.detached(priority: .userInitiated) {
                    try operation.read(url)
                }.value
                guard ui.fileRead === operation else { return }
                guard generation == store.workspaceGeneration else { throw BackupFailure(message: "The workspace changed. Choose the backup again in the intended workspace.") }
                ui.review = RestoreReviewRequest(backup: backup, snapshot: store.snapshot, generation: generation, account: store.userID)
            } catch {
                guard ui.fileRead === operation else { return }
                ui.show(error)
            }
        }
    }
    private func preview(_ backup: WorkspaceBackup) {
        review = RestoreReviewRequest(backup: backup, snapshot: store.snapshot, generation: store.workspaceGeneration, account: store.userID)
    }
    private func export(_ backup: WorkspaceBackup) {
        let generation = store.workspaceGeneration
        run {
            let data = try await Task.detached(priority: .utility) { try backup.data() }.value
            guard generation == store.workspaceGeneration else { throw BackupFailure(message: "The workspace changed. Export again from the intended workspace.") }
            ui.exportFilename="Taskfold-backup"; document = WorkspaceDocument(data: data); exporting = true
        }
    }
    private func load(_ entry: RecoveryEntry, exportFile: Bool) {
        let vault = store.backupVault, generation = store.workspaceGeneration
        run {
            let payload = try await Task.detached(priority: .utility) { try vault.load(entry) }.value
            guard generation == store.workspaceGeneration else { throw BackupFailure(message: "The workspace changed. Reopen its recovery copies.") }
            if exportFile {
                let data = try await Task.detached(priority: .utility) { try payload.workspace.data() }.value
                guard generation == store.workspaceGeneration else { throw BackupFailure(message: "The workspace changed. Export again from the intended workspace.") }
                ui.exportFilename="Taskfold-backup"; document = WorkspaceDocument(data: data); exporting = true
            } else { preview(payload.workspace) }
        }
    }
    private func openEditorEdit(_ entry: PreservedWorkspaceFile, exportOriginal: Bool) {
        let vault=store.backupVault, generation=store.workspaceGeneration, account=store.userID
        run {
            let origin=store.localMode ? nil:try store.backend.accountRemovalOrigin
            let value=try await Task.detached(priority:.utility) {try vault.editorDraft(entry.id,origin:origin)}.value
            guard generation==store.workspaceGeneration,account==store.userID else {throw CancellationError()}
            if exportOriginal {
                let data=try await Task.detached(priority:.utility) {try JSONEncoder().encode(value)}.value
                guard generation==store.workspaceGeneration else {throw CancellationError()}
                ui.exportFilename="Taskfold-original-edit";document=WorkspaceDocument(data:data);exporting=true
            } else {
                let snapshot=store.snapshot
                let backup=try await Task.detached(priority:.userInitiated) {try value.copyBackup(current:snapshot)}.value
                guard generation==store.workspaceGeneration,account==store.userID,store.snapshot==snapshot else {throw BackupFailure(message:"Your workspace changed. Review this saved edit again.")}
                review=RestoreReviewRequest(backup:backup,snapshot:snapshot,generation:generation,account:account,onlyNewTask:true)
            }
        }
    }
    private func refreshHistory() async { await Self.refreshHistory(store: store, ui: ui) }
    private static func refreshHistory(store: Store, ui: BackupUI) async {
        let vault = store.backupVault, generation = store.workspaceGeneration
        var failures: [String] = []
        do {
            let entries = try await Task.detached(priority: .utility) { try vault.entries() }.value
            if generation == store.workspaceGeneration { ui.history = entries }
        } catch { failures.append(error.localizedDescription) }
        do {
            let preserved = try await Task.detached(priority: .utility) { try vault.preservedFiles() }.value
            if generation == store.workspaceGeneration { ui.preserved = preserved }
        } catch { failures.append(error.localizedDescription) }
        do {
            let edits=try await Task.detached(priority:.utility) {try vault.editorEntries()}.value
            if generation==store.workspaceGeneration {ui.editorEdits=edits}
        } catch {failures.append(error.localizedDescription)}
        if generation == store.workspaceGeneration, !failures.isEmpty { store.backupWarning = "Some recovery files could not be read: " + failures.joined(separator: " ") }

    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await operation() } catch { show(error) } }
    }
    private func show(_ error: Error) {
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError { return }
        message = error.localizedDescription
    }
}

struct RestoreReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var request: RestoreReviewRequest
    @State private var policy = RestorePolicy.keepCurrent
    @State private var busy = false
    @State private var message: String?
    @State private var finished = false
    private var changed: Bool { request.generation != store.workspaceGeneration || request.account != store.userID || request.snapshot != store.snapshot }
    private var plan: Result<RestorePlan, Error> { Result { let result=try request.backup.plan(current: request.snapshot, account: request.account, policy: policy);if request.onlyNewTask {try TaskEditorRecovery.requireNewTaskPlan(result)};return result } }
    private func countRow(_ label: String, value: Int, identifier: String) -> some View {
        LabeledContent(label, value: "\(value)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("\(value)")
            .accessibilityIdentifier(identifier)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(request.onlyNewTask ? "Review your recovered edit":"Review your restore", systemImage: "arrow.counterclockwise.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(Color.taskfold)
                    if let date = TaskPlanning.instant(request.backup.createdAt) { LabeledContent("Backup created", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    if !request.onlyNewTask { Picker("Matching records", selection: $policy) { ForEach(RestorePolicy.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("restorePolicy") }
                    if request.onlyNewTask {Text(TaskEditorRecovery.copyNotice).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("editorRecoveryNotice")}
                    Text(policy == .keepCurrent ? "Add missing work and keep the records already in this workspace." : "Add missing work and restore matching records to the values in this backup.").font(.callout).foregroundStyle(.secondary)
                }
                if request.onlyNewTask, let task=request.backup.tables["tasks"]?.first {
                    Section("Recovered task") {
                        Text(task.title).font(.headline).accessibilityIdentifier("editorRecoveryTitle")
                        if !task.string("description").isEmpty {
                            Text(String(task.string("description").prefix(4000))).textSelection(.enabled).accessibilityIdentifier("editorRecoveryNotes")
                            if task.string("description").count>4000 {Text("Preview shortened; the full notes remain in the copy and original edit.").font(.caption).foregroundStyle(.secondary)}
                        }
                        if !task.string("due_date").isEmpty {LabeledContent("Planned",value:task.string("due_date")+" "+task.string("due_time"))}
                        LabeledContent("Checklist",value:"\(task["subtasks"].list.count) main items")
                        LabeledContent("Files",value:String(task["attachments"].list.count))
                    }
                }
                switch plan {
                case .success(let value):
                    Section("Changes") {
                        countRow("Add", value: value.added, identifier: "restoreAdded")
                        countRow("Update", value: value.updated, identifier: "restoreUpdated")
                        countRow("Keep", value: value.kept, identifier: "restoreKept")
                        ForEach(WorkspaceBackup.workTables.filter { value.counts[$0] != nil }, id: \.self) { table in
                            countRow(["projects":"Projects", WorkflowTemplate.table:"Templates", "labels":"Labels", "sections":"Sections", "tasks":"Tasks", "saved_views":"Saved filters", "favorites":"Favorites", "view_preferences":"View settings", "view_orders":"Task ordering", "focus_sessions":"Focus session", "reminder_preferences":"Reminder preferences"][table] ?? table, value: value.counts[table] ?? 0, identifier: "restoreCount-" + table)
                        }
                    }.accessibilityElement(children: .contain)
                    Section("Before you restore") {
                        Text("An encrypted recovery copy will be saved first. Existing work outside the backup stays in your workspace.")
                        ForEach(value.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    }
                    if changed {
                        Section {
                            Text("Your workspace changed since this preview. Review the latest counts before restoring.")
                            Button("Refresh preview") { request.snapshot = store.snapshot }.disabled(request.generation != store.workspaceGeneration || request.account != store.userID).accessibilityIdentifier("restoreRefresh")
                        }
                    }

                case .failure(let error): Section { Text(error.localizedDescription).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).disabled(busy)
            .safeAreaInset(edge: .bottom) {
                if case .success(let value) = plan {
                    VStack(spacing: 0) {
                        Divider()
                        Button(busy ? "Saving recovery copy…" : request.onlyNewTask ? "Recover to Inbox" : "Restore \(value.total) \(value.total == 1 ? "record" : "records")") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    let restored = try await store.restore(request.backup, policy: policy, reviewed: request.snapshot, generation: request.generation, onlyNewTask:request.onlyNewTask)
                                    finished = true
                                    message = request.onlyNewTask ? "A new task was added to Inbox. Your full original edit remains in Unsent task edits." : "Restored \(restored.total) \(restored.total == 1 ? "record" : "records"). Your recovery copy is available in Backups & restore."
                                } catch { message = error.localizedDescription }
                            }
                        }.disabled(busy || changed || store.syncing || value.total == 0).accessibilityIdentifier("restoreApply")
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .frame(maxWidth: .infinity).padding().accessibilityIdentifier("restoreApply")
                    }.background(.regularMaterial)
                }
            }
            .navigationTitle(request.onlyNewTask ? "Recover task edit":"Restore backup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .alert(finished ? (request.onlyNewTask ? "Task recovered":"Restore complete") : "Restore could not finish", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil; if finished { dismiss() } }
            } message: { Text(message ?? "") }
        }
        #if os(macOS)
        .frame(width: 620, height: 660)
        #endif
    }
}

#if os(iOS)
/// SwiftUI's onDismiss finishes the picker-to-preview handoff before presenting
/// another sheet, keeping the preview reachable to VoiceOver and native controls.
private struct BackupFilePicker: UIViewControllerRepresentable {
    var completion: (Result<URL, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { completion(.success(url)) } else { completion(.failure(CocoaError(.userCancelled))) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(.failure(CocoaError(.userCancelled))) }
    }
}
#endif

/// Keep access-loss recovery discoverable after sync succeeds and across relaunches.
struct AccessRecoveryBanner: View {
    @Environment(Store.self) private var store
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var reviewing = false
    var body: some View {
        Group {
            if textSize.isAccessibilitySize {
                ScrollView { content.padding() }
                    .frame(height: 280)
                    .clipped()
                    .accessibilityIdentifier("accessRecoveryScroll")
            } else { content.padding() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .sheet(isPresented: $reviewing) { AccessRecoveryReview() }
        .onChange(of: store.workspaceGeneration) { _, _ in reviewing = false }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shared access was removed. Your unsynced work is saved on this device.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("accessRecoveryMessage")
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { reviewButton; dismissButton }
            } else {
                HStack { reviewButton; Spacer(minLength: 8); dismissButton }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    private var reviewButton: some View {
        Button { reviewing = true } label: {
            Text("View recovery copies").fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .frame(maxWidth: textSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.tint)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("reviewAccessRecovery")
    }
    private var dismissButton: some View {
        Button { store.acknowledgeAccessRecovery() } label: {
            Text("Dismiss").fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .frame(maxWidth: textSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .accessibilityIdentifier("dismissAccessRecovery")
    }
}

private struct AccessRecoveryReview: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose an Access removed copy to preview or restore your unsynced work. Restored shared projects become copies you own.")
                }
                BackupTools()
            }
            .modifier(BackupPresentation())
            .navigationTitle("Backups & restore")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 540)
        #endif
    }
}
