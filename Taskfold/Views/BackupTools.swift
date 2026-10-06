import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct WorkspaceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
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
}

@MainActor @Observable
private final class BackupUI {
    var history: [RecoveryEntry] = []
    var daily = true
    var busy = false
    var importing = false
    var selectedFile: URL?
    var pickerClosed = false
    var intendedWorkspace: UUID?
    var exporting = false
    var document: WorkspaceDocument?
    var review: RestoreReviewRequest?
    var message: String?
    var didSelectFile: ((URL) -> Void)?
    var didCloseReview: (() -> Void)?
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
        content.environment(ui)
            .fileExporter(isPresented: $ui.exporting, document: ui.document, contentType: .json, defaultFilename: "Taskfold-backup-" + Dates.day(Date())) { result in
                if case .failure(let error) = result { ui.show(error) }
                ui.document = nil
            }
            #if os(iOS)
            .sheet(isPresented: $ui.importing, onDismiss: {
                ui.pickerClosed = true
                if let url = ui.selectedFile { ui.selectedFile = nil; ui.didSelectFile?(url) }
            }) {
                BackupFilePicker { result in
                    do { ui.selectedFile = try result.get() } catch { ui.show(error) }
                    ui.importing = false
                    // UIKit may notify dismissal before delivering its selected URL.
                    if ui.pickerClosed, let url = ui.selectedFile { ui.selectedFile = nil; ui.didSelectFile?(url) }
                }
            }
            #else
            .fileImporter(isPresented: $ui.importing, allowedContentTypes: [.json]) { result in
                do { ui.didSelectFile?(try result.get()) } catch { ui.show(error) }
            }
            #endif
            .sheet(item: $ui.review, onDismiss: { ui.didCloseReview?() }) { request in
                RestoreReview(request: request).presentationDetents([.large])
            }
            .alert("Backups & restore", isPresented: Binding(get: { ui.message != nil }, set: { if !$0 { ui.message = nil } })) {
                Button("OK") { ui.message = nil }
            } message: { Text(ui.message ?? "") }
    }
}

/// Each platform owns this native form, its export document and restore preview.
struct BackupTools: View {
    @Environment(Store.self) private var store
    @Environment(BackupUI.self) private var ui
    private var history: [RecoveryEntry] { get { ui.history } nonmutating set { ui.history = newValue } }
    private var daily: Bool { get { ui.daily } nonmutating set { ui.daily = newValue } }
    private var busy: Bool { get { ui.busy } nonmutating set { ui.busy = newValue } }
    private var importing: Bool { get { ui.importing } nonmutating set { ui.importing = newValue } }
    private var exporting: Bool { get { ui.exporting } nonmutating set { ui.exporting = newValue } }
    private var document: WorkspaceDocument? { get { ui.document } nonmutating set { ui.document = newValue } }
    private var review: RestoreReviewRequest? { get { ui.review } nonmutating set { ui.review = newValue } }
    private var message: String? { get { ui.message } nonmutating set { ui.message = newValue } }
    var body: some View {
        Section {
            Button("Back up now", systemImage: "externaldrive.badge.checkmark") { run { _ = try await store.makeRecoveryBackup(); await refreshHistory(); message = "Recovery copy saved on this device." } }
                .accessibilityIdentifier("backupNow")
            Button("Export workspace", systemImage: "square.and.arrow.up") {
                let backup = WorkspaceBackup.make(store.snapshot, account: store.userID)
                export(backup)
            }.accessibilityIdentifier("backupExport")
            Button("Restore from file", systemImage: "arrow.counterclockwise") { ui.pickerClosed = false; ui.intendedWorkspace = store.workspaceGeneration; importing = true }.accessibilityIdentifier("backupImport")
            Toggle("Daily recovery copies", isOn: Binding(get: { daily }, set: { daily = $0 })).accessibilityIdentifier("dailyBackups")
            if let warning = store.backupWarning { Text(warning).font(.callout).foregroundStyle(.secondary) }
        } header: { Text("Backups & restore") } footer: {
            Text("Keep up to 20 encrypted recovery copies on this device. Export a portable JSON backup for another device. Exported files contain your workspace data; keep them somewhere private.")
        }
        .disabled(busy || !(store.signedIn || store.localMode))
        .onChange(of: daily) { _, value in store.dailyBackupsEnabled = value }
        .task(id: store.workspaceGeneration) {
            let model = ui, owner = store
            model.didSelectFile = { [weak model] url in if let model { Self.readFile(url, store: owner, ui: model) } }
            model.didCloseReview = { [weak model] in if let model { Task { await Self.refreshHistory(store: owner, ui: model) } } }
            daily = store.dailyBackupsEnabled; await refreshHistory()
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
    private static func readFile(_ url: URL, store: Store, ui: BackupUI) {
        let generation = ui.intendedWorkspace ?? store.workspaceGeneration
        guard generation == store.workspaceGeneration else { ui.show(BackupFailure(message: "The workspace changed. Choose the backup again in the intended workspace.")); return }
        ui.busy = true
        Task {
            defer { ui.busy = false }
            do {
                let backup = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= WorkspaceBackup.maximumBytes else { throw BackupFailure(message: "Choose a backup no larger than 256 MB.") }
                    return try WorkspaceBackup.read(Data(contentsOf: url))
                }.value
                guard generation == store.workspaceGeneration else { throw BackupFailure(message: "The workspace changed. Choose the backup again in the intended workspace.") }
                ui.review = RestoreReviewRequest(backup: backup, snapshot: store.snapshot, generation: generation, account: store.userID)
            } catch { ui.show(error) }
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
            document = WorkspaceDocument(data: data); exporting = true
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
                document = WorkspaceDocument(data: data); exporting = true
            } else { preview(payload.workspace) }
        }
    }
    private func refreshHistory() async { await Self.refreshHistory(store: store, ui: ui) }
    private static func refreshHistory(store: Store, ui: BackupUI) async {
        let vault = store.backupVault, generation = store.workspaceGeneration
        do {
            let entries = try await Task.detached(priority: .utility) { try vault.entries() }.value
            if generation == store.workspaceGeneration { ui.history = entries }
        } catch { if generation == store.workspaceGeneration { store.backupWarning = "Recovery copies could not be read: " + error.localizedDescription } }
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
    private var plan: Result<RestorePlan, Error> { Result { try request.backup.plan(current: request.snapshot, account: request.account, policy: policy) } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Review your restore", systemImage: "arrow.counterclockwise.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(Color.taskfold)
                    if let date = TaskPlanning.instant(request.backup.createdAt) { LabeledContent("Backup created", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Picker("Matching records", selection: $policy) { ForEach(RestorePolicy.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("restorePolicy")
                    Text(policy == .keepCurrent ? "Add missing work and keep the records already in this workspace." : "Add missing work and restore matching records to the values in this backup.").font(.callout).foregroundStyle(.secondary)
                }
                switch plan {
                case .success(let value):
                    Section("Changes") {
                        LabeledContent("Add", value: "\(value.added)").accessibilityIdentifier("restoreAdded")
                        LabeledContent("Update", value: "\(value.updated)").accessibilityIdentifier("restoreUpdated")
                        LabeledContent("Keep", value: "\(value.kept)")
                        ForEach(WorkspaceBackup.workTables.filter { value.counts[$0] != nil }, id: \.self) { table in
                            LabeledContent(["projects":"Projects", "labels":"Labels", "sections":"Sections", "tasks":"Tasks", "saved_views":"Saved filters", "favorites":"Favorites", "view_preferences":"View settings", "view_orders":"Task ordering", "focus_sessions":"Focus session"][table] ?? table, value: "\(value.counts[table] ?? 0)")
                        }
                    }
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
                        Button(busy ? "Saving recovery copy…" : "Restore \(value.total) \(value.total == 1 ? "record" : "records")") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    let restored = try await store.restore(request.backup, policy: policy, reviewed: request.snapshot, generation: request.generation)
                                    finished = true
                                    message = "Restored \(restored.total) \(restored.total == 1 ? "record" : "records"). Your recovery copy is available in Backups & restore."
                                } catch { message = error.localizedDescription }
                            }
                        }.disabled(busy || changed || store.syncing || value.total == 0).accessibilityIdentifier("restoreApply")
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .frame(maxWidth: .infinity).padding().accessibilityIdentifier("restoreApply")
                    }.background(.regularMaterial)
                }
            }
            .navigationTitle("Restore backup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .alert(finished ? "Restore complete" : "Restore could not finish", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
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
