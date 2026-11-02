import SwiftUI
import UniformTypeIdentifiers

struct TaskFileUploadRequest: Identifiable {
    let id = UUID()
    let account: String, origin: String, target: Record
    let workspace: UUID, session: UUID
    let readOnly: Bool
    var library: Bool { target.fields.isEmpty }
}
extension Store {
    var taskFileUploadsEnabled: Bool {
        #if DEBUG
        if TaskFileViewerFixture.selectionTesting { return true }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "TaskfoldTaskFilesEnabled") as? Bool == true
    }
    private func fileUploadDirectory(account: String, origin: String) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("vault", account), isDirectory: true)
            .appendingPathComponent("Shared file uploads", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("origin", origin), isDirectory: true)
    }
    func fileUploadRequest(taskID: String? = nil, readOnly: Bool = false) -> TaskFileUploadRequest? {
        guard teamTemplateRecoveryAvailable, let origin = try? backend.accountRemovalOrigin,
              backend.audioPublicationSessionMatches(userID) else { return nil }
        var target = Record([:]), reading = false
        if let taskID {
            guard let source = record("tasks", id: taskID), let admitted = fileUploadReadTarget(source) else { return nil }
            target = admitted; reading = readOnly || (try? captureTeamTaskEditor(source)) == nil
        }
        return .init(account: userID, origin: origin, target: target, workspace: workspaceGeneration, session: backend.reminderSessionIncarnation, readOnly: reading)
    }
    private func fileUploadReadTarget(_ source: Record) -> Record? {
        guard teamOrganizationReadable, !workspaceNeedsRepair, let origin = try? backend.accountRemovalOrigin else { return nil }
        return try? TaskFileReadAdmission.target(account: userID, origin: origin, task: source, projects: rows("projects"), cache: nativeConversationTeamCache,
            teamsEnabled: Bundle.main.object(forInfoDictionaryKey: "TaskfoldTeamsEnabled") as? Bool == true)
    }
    func fileUploadReadRequest(source: Record, workspace: WorkspaceBinding) -> TaskFileUploadRequest? {
        guard workspace.matches(account: userID, generation: workspaceGeneration), let request = fileUploadRequest(taskID: source.id, readOnly: true),
              TaskFileReadAdmission.matches(request.target, source: source) else { return nil }
        return request
    }
    func fileUploadReadable(_ request: TaskFileUploadRequest) -> Bool {
        guard fileUploadCurrent(request), !request.library, let task = record("tasks", id: request.target.string("task_id")) else { return false }
        return fileUploadReadTarget(task) == request.target
    }

    var hasFileUploadRecovery: Bool {
        guard let request = fileUploadRequest() else { return false }
        return FileManager.default.fileExists(atPath: fileUploadDirectory(account: request.account, origin: request.origin).appendingPathComponent(TaskFileUploadJournal.fileName).path)
    }
    func fileUploadCurrent(_ request: TaskFileUploadRequest) -> Bool {
        teamTemplateRecoveryAvailable && userID == request.account && workspaceGeneration == request.workspace
            && backend.reminderSessionIncarnation == request.session && backend.audioPublicationSessionMatches(request.account)
            && (try? backend.accountRemovalOrigin) == request.origin
    }
    func fileUploadMayPublish(_ request: TaskFileUploadRequest) -> Bool {
        guard !request.readOnly, fileUploadReadable(request), taskFileUploadsEnabled, !request.library, online, !syncing, snapshot.pending.isEmpty,
              let source = record("tasks", id: request.target.string("task_id")), source["task_generation"] == request.target["task_generation"],
              source["project_id"] == request.target["project_id"], let admission = try? captureTeamTaskEditor(source) else { return false }
        return admission.scope.team == request.target.string("team_id")
    }
    func fileUploadModel(_ request: TaskFileUploadRequest) throws -> TaskFileUploadModel {
        guard !request.readOnly, fileUploadCurrent(request) else { throw TaskFileUploadJournal.invalid }
        let directory = fileUploadDirectory(account: request.account, origin: request.origin), root = cacheURL.deletingLastPathComponent(), account = request.account
        let io = ReviewedTeamCommandFileIO<TaskFileUploadJournal>(directory: directory, account: account, origin: request.origin, encryptionKey: { try BackupVault.deviceKey(account: account) })
        let vault = TaskFileUploadVault(io: io, coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: root)
        let service: any TaskFileUploadTransport
        #if DEBUG
        service = TaskFileNativeProviderFixture.enabled ? TaskFileNativeProviderTransport(backend) : backend
        #else
        service = backend
        #endif
        return TaskFileUploadModel(account: account, origin: request.origin, target: request.target, vault: vault, service: service, incarnation: request.session,
            current: { [weak self] in self?.fileUploadCurrent(request) == true }, publishAllowed: { [weak self] in self?.fileUploadMayPublish(request) == true })
    }
    func fileUploadAttachments(_ request: TaskFileUploadRequest) -> [Record] {
        guard fileUploadReadable(request), let task = record("tasks", id: request.target.string("task_id")) else { return [] }
        return task["attachments"].list.map { Record($0.object) }.filter { TaskFileUploadJournal.validID($0.string("storage_object_id")) }
    }
    func downloadFile(_ attachment: Record, request: TaskFileUploadRequest) async throws -> Data {
        guard fileUploadAttachments(request).contains(attachment) else { throw TaskFileUploadJournal.invalid }
        let bytes = try await backend.downloadTaskFile(attachment, target: request.target, account: request.account, origin: request.origin, incarnation: request.session)
        guard fileUploadAttachments(request).contains(attachment) else { throw CancellationError() }; return bytes
    }
}

struct TaskFileUploadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct TaskFileUploadRecoveryButton: View {
    @Environment(Store.self) private var store
    @State private var request: TaskFileUploadRequest?
    var body: some View {
        if store.hasFileUploadRecovery {
            Button("Saved file upload", systemImage: "arrow.up.doc") { request = store.fileUploadRequest() }.accessibilityIdentifier("fileUploadRecovery")
                .sheet(item: $request) { TaskFileUploadView(request: $0) }
        }
    }
}

private struct TaskFileCopyAttempt: Equatable {
    let id = UUID()
    let source: String, shared: Bool, name: String
}

struct TaskFileUploadView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TaskFileUploadRequest
    @State private var model: TaskFileUploadModel?
    @State private var importing = false
    @State private var exporting = false
    @State private var document: TaskFileUploadDocument?
    @State private var filename = "Attachment"
    @State private var localMessage: String?
    @State private var downloading = false
    @State private var copyAttempt: TaskFileCopyAttempt?
    @State private var copyStatus: String?
    @AccessibilityFocusState private var copyFocused: String?
    @AccessibilityFocusState private var statusFocused: Bool
    private var available: Bool { store.fileUploadCurrent(request) }
    var body: some View {
        let completingCopy = copyAttempt
        NavigationStack {
            Form {
                if available, let copyStatus { Section { Text(copyStatus).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("fileCopyStatus") } }
                if available, request.readOnly {
                    if store.fileUploadReadable(request) {
                        Text("View-only access. Save a copy of a shared file below.").foregroundStyle(.secondary).accessibilityIdentifier("fileReadOnlyNotice")
                    } else { ContentUnavailableView("Shared files unavailable", systemImage: "lock", description: Text("Refresh project access and reopen this task.")) }
                } else if available, let model {
                    if model.loaded {
                        Section {
                            if model.needsRefresh {
                                Text("Saved upload needs refreshing").accessibilityIdentifier("fileUploadRefreshNeeded")
                                Text("Another window may have changed recovery. Refresh before sharing, stopping or clearing it. You can still save your displayed original as a private copy.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Refresh saved upload", systemImage: "arrow.clockwise") {
                                copyStatus = nil; localMessage = nil
                                Task { await model.load() }
                            }.disabled(model.busy || downloading || copyAttempt != nil).accessibilityIdentifier("fileUploadRefresh")
                        }
                    }
                    if !model.loaded {
                        Section {
                            Text(model.busy ? "Opening saved upload…" : "Saved upload needs review")
                            if !model.busy { Button("Try again") { Task { await model.load() } } }
                        }
                    } else if let pending = model.pending {
                        Section("Saved upload") {
                            Text(pending.name).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(pending.bytes.count), countStyle: .file)).foregroundStyle(.secondary)
                            Text(status(pending)).accessibilityIdentifier("fileUploadState")
                            Button("Save local copy…", systemImage: "square.and.arrow.down") { export(pending.bytes, name: pending.name, source: "local", shared: false) }.disabled(model.busy || downloading || copyAttempt != nil).accessibilityFocused($copyFocused, equals: "local").accessibilityIdentifier("fileUploadSaveLocalCopy")
                            if !pending.resolved {
                                if model.sameTarget {
                                    Button(pending.phase == .queued ? "Share file" : "Retry upload", systemImage: "arrow.up.doc") { Task { await model.act("publish"); if available { await store.sync() } } }
                                        .disabled(model.busy || !model.canPublish || downloading).accessibilityIdentifier("fileUploadPublish")
                                } else { Text("Open the original task to retry this saved upload.").foregroundStyle(.secondary) }
                                if pending.phase == .attempted {
                                    Button("Check status", systemImage: "arrow.clockwise") { Task { await model.act("resolve"); if available { await store.sync() } } }.disabled(model.busy || model.needsRefresh || downloading).accessibilityIdentifier("fileUploadCheck")
                                }
                                Button(pending.phase == .queued ? "Remove unsent copy" : "Stop upload", role: .destructive) { Task { await model.act("cancel") } }.disabled(model.busy || model.needsRefresh || downloading).accessibilityIdentifier("fileUploadStop")
                                Text("Your original file stays encrypted on this device until the result is confirmed. Closing this sheet keeps recovery available in Account.").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Button("Clear recovery copy", role: .destructive) { Task { await model.finish() } }.disabled(model.busy || model.needsRefresh || downloading).accessibilityIdentifier("fileUploadClear")
                                Text(pending.phase == .published ? "Clears only this device’s recovery copy. The shared file stays with its task." : "Clears only this device’s recovery copy. This upload wasn’t shared.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } else if !request.library {
                        Section {
                            if store.taskFileUploadsEnabled {
                                Button("Choose a file…", systemImage: "doc.badge.plus") { copyStatus = nil; localMessage = nil; importing = true }.accessibilityFocused($copyFocused, equals: "choose").disabled(!model.loaded || model.busy || model.needsRefresh || !store.fileUploadMayPublish(request)).accessibilityIdentifier("fileUploadChoose")
                                Text("Share a file up to 5 MB with people who can access this project.").font(.footnote).foregroundStyle(.secondary)
                            } else { Text("New file sharing is paused. You can still save existing shared files.").foregroundStyle(.secondary) }
                        }
                    } else { ContentUnavailableView("No saved upload", systemImage: "checkmark.circle") }
                    if model.busy || downloading { ProgressView(downloading ? "Preparing file…" : "Saving upload status…").accessibilityIdentifier("fileUploadProgress") }
                    if let message = localMessage ?? model.message { Section { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityFocused($statusFocused).accessibilityIdentifier("fileUploadMessage") } }
                } else if !available { ContentUnavailableView("Workspace changed", systemImage: "lock", description: Text(request.readOnly ? "Reopen this task in the original account." : "Reopen saved file recovery from the original account.")) }
                else if let localMessage { Text(localMessage) } else { ProgressView("Opening saved upload…") }
                    if store.fileUploadReadable(request) {
                        Section("Shared files") {
                            if store.fileUploadAttachments(request).isEmpty { Text("No shared files yet.").foregroundStyle(.secondary).accessibilityIdentifier("fileReadEmpty") }
                            ForEach(store.fileUploadAttachments(request)) { attachment in
                                Button { download(attachment) } label: { Label(attachment.string("name"), systemImage: "arrow.down.doc") }.disabled(model?.busy == true || downloading || copyAttempt != nil).accessibilityFocused($copyFocused, equals: attachment.id).accessibilityLabel("Save a copy of " + attachment.string("name")).accessibilityIdentifier("downloadSharedFile-" + attachment.id)
                            }
                        }
                    }
                if request.readOnly, downloading { ProgressView("Preparing file…").accessibilityIdentifier("fileUploadProgress") }
                if available, request.readOnly, let localMessage { Text(localMessage).fixedSize(horizontal: false, vertical: true).accessibilityFocused($statusFocused).accessibilityIdentifier("fileUploadMessage") }

            }
            .accessibilityIdentifier("taskFileForm")
            .formStyle(.grouped).navigationTitle(request.library ? "Saved upload" : "Shared files")
            .toolbar {
                #if DEBUG
                if TaskFileViewerFixture.enabled && !TaskFileViewerFixture.refreshTesting { ToolbarItem { Button("Withdraw test access") { store.withdrawFileViewerFixture() }.accessibilityIdentifier("fileViewerWithdrawAccess") } }
                if TaskFileViewerFixture.refreshTesting, let model {
                    ToolbarItem { Button("Change recovery") {
                        Task {
                            do {
                                let other = try store.fileUploadModel(request); await other.load()
                                guard other.pending?.phase == .queued, other.pending?.name == "Original recovery.txt" else { return }
                                await other.act("cancel")
                                await other.choose(Data("replacement recovery".utf8), name: "Updated recovery.txt", type: "text/plain")
                                other.close()
                            } catch { }
                        }
                    }.disabled(model.busy).accessibilityIdentifier("fileRefreshExternalChange") }
                }
                #endif
                ToolbarItem(placement: .cancellationAction) { Button("Close") { model?.close(); dismiss() }.accessibilityIdentifier("fileUploadDismiss") } }
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 520, minHeight: 380, idealHeight: 580)
            #endif
        }
        .task { guard !request.readOnly else { return }; do { let value = try store.fileUploadModel(request); model = value; await value.load() } catch { localMessage = "Your saved upload couldn’t be opened. Nothing was sent." } }
        .onDisappear { model?.close(); invalidateCopy() }
        .onChange(of: available) { _, value in if !value { importing = false; invalidateCopy(); model?.close() } }
        .onChange(of: store.fileUploadReadable(request)) { _, readable in if !readable, copyAttempt?.shared == true { invalidateCopy() } }
        .onChange(of: copyStatus) { _, message in
            if available, let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onChange(of: localMessage) { _, _ in statusFocused = true }
        .onChange(of: model?.message) { _, _ in statusFocused = true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false, onCompletion: { result in
            guard available, !request.readOnly, store.fileUploadMayPublish(request), let model else { return }
            switch result {
            case .success(let urls):
                guard urls.count == 1, let url = urls.first else { localMessage = "Choose one file. Your saved upload is unchanged."; return }
                Task {
                    do {
                        let bytes = try await Task.detached(priority: .userInitiated) {
                            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var bytes = Data()
                            while true { try Task.checkCancellation(); let chunk = try handle.read(upToCount: min(262144, TaskFileUploadJournal.maximumBytes + 1 - bytes.count)) ?? Data(); if chunk.isEmpty { break }; bytes.append(chunk); guard bytes.count <= TaskFileUploadJournal.maximumBytes else { throw TaskFileUploadJournal.invalid } }
                            return bytes
                        }.value
                        guard available, store.fileUploadMayPublish(request) else { return }
                        let proposed = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        await model.choose(bytes, name: url.lastPathComponent, type: TaskFileUploadJournal.types.contains(proposed) ? proposed : "application/octet-stream")
                    } catch { if available { localMessage = "The file couldn’t be read. Choose an available file up to 5 MB." } }
                }
            case .failure(let error): if (error as NSError).code == NSUserCancelledError { copyFocused = "choose" } else { localMessage = "No file was selected. Your saved upload is unchanged." }
            }
        }, onCancellation: {
            if available { copyFocused = "choose" }
        })
        .fileExporter(isPresented: $exporting, document: document, contentTypes: [.data], defaultFilename: filename, onCompletion: { result in
            finishCopy(result, attempt: completingCopy)
        }, onCancellation: {
            finishCopy(nil, attempt: completingCopy)
        })
        #if DEBUG
        .fileDialogDefaultDirectory(TaskFileViewerFixture.dialogDirectory(importing: importing))
        .fileDialogCustomizationID("taskfold.shared-files.native-fixture")
        #endif
    }
    private func finishCopy(_ result: Result<URL, Error>?, attempt: TaskFileCopyAttempt?) {
        guard let attempt, copyAttempt?.id == attempt.id else { return }
        document = nil; copyAttempt = nil
        guard available, !attempt.shared || store.fileUploadReadable(request) else { return }
        copyFocused = attempt.source
        guard let result else { copyStatus = "Copy cancelled. Your file is unchanged."; return }
        switch result {
        case .success(let url):
            copyStatus = "Copy saved."
            #if DEBUG
            TaskFileViewerFixture.recordCopy(url, request: request, name: attempt.name, shared: attempt.shared)
            #endif
        case .failure(let error):
            copyStatus = (error as NSError).code == NSUserCancelledError ? "Copy cancelled. Your file is unchanged." : "The copy couldn’t be saved. Your original file is kept."
        }
    }
    private func invalidateCopy() {
        exporting = false; document = nil; copyAttempt = nil; copyStatus = nil; copyFocused = nil
    }

    private func status(_ value: TaskFileUploadJournal) -> String {
        switch value.phase { case .queued: return "Saved on this device"; case .attempted: return "Result not yet confirmed"; case .published: return "Shared successfully"; case .cancelled: return "Upload stopped"; case .expired: return "Upload expired" }
    }
    private func export(_ data: Data, name: String, source: String, shared: Bool) {
        guard available, copyAttempt == nil, !shared || store.fileUploadReadable(request) else { return }
        filename = URL(fileURLWithPath: name).lastPathComponent
        copyAttempt = .init(source: source, shared: shared, name: filename); copyStatus = nil; localMessage = nil
        document = .init(data: data); exporting = true
    }
    private func download(_ attachment: Record) {
        guard available, !downloading, copyAttempt == nil else { return }; copyStatus = nil; localMessage = nil; downloading = true
        Task { defer { downloading = false }; do { let bytes = try await store.downloadFile(attachment, request: request); guard available else { return }; export(bytes, name: attachment.string("name"), source: attachment.id, shared: true) } catch { if available { localMessage = "The file couldn’t be opened. Refresh the task and try again." } } }
    }
}

#if DEBUG
@MainActor enum TaskFileViewerFixture {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--file-viewer-testing") }
    static var copyTesting: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--file-copy-testing") }
    static var selectionTesting: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--file-selection-testing") }
    static var refreshTesting: Bool { selectionTesting && ProcessInfo.processInfo.arguments.contains("--file-recovery-refresh-testing") }
    static let sampleName = "Taskfold-file-upload-sample.txt"
    static let copyName = "Taskfold-shared-file-copy-proof.txt"
    static var documents: URL { URL.documentsDirectory }
    static var copyDirectory: URL { documents.appendingPathComponent("Taskfold-file-copy-destination", isDirectory: true) }
    static var receipt: URL { documents.appendingPathComponent("Taskfold-file-copy-receipt.json") }
    static func dialogDirectory(importing: Bool) -> URL? {
        guard copyTesting || selectionTesting else { return nil }
        return importing ? documents : copyDirectory
    }
    private static var dialogsPrepared = false
    static func prepareFileDialogs() throws {
        guard !dialogsPrepared, copyTesting || selectionTesting else { return }
        try FileManager.default.createDirectory(at: copyDirectory.appendingPathComponent("Taskfold-copy-marker", isDirectory: true), withIntermediateDirectories: true)
        let source = documents.appendingPathComponent(sampleName)
        if !FileManager.default.fileExists(atPath: source.path) { try Data("hello".utf8).write(to: source, options: .atomic) }
        if ProcessInfo.processInfo.arguments.contains("--team-editor-reset") {
            for path in [copyDirectory.appendingPathComponent(copyName), copyDirectory.appendingPathComponent(sampleName)] where FileManager.default.fileExists(atPath: path.path) {
                guard try Data(contentsOf: path) == Data("hello".utf8) else { throw TaskFileUploadJournal.invalid }
                try FileManager.default.removeItem(at: path)
            }
            if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
        }
        dialogsPrepared = true
    }
    static func recordCopy(_ url: URL, request: TaskFileUploadRequest, name: String, shared: Bool) {
        guard copyTesting || selectionTesting else { return }
        let value = ["url": url.absoluteString, "account": request.account, "name": name, "source": shared ? "shared" : "local"]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) { try? data.write(to: receipt, options: .atomic) }
    }
    static let generation = "ec240000-0000-4000-8000-000000000071"
    static var attachment: Record { Record(["id": .string("ec240000-0000-4000-8000-000000000072"), "storage_object_id": .string("ec240000-0000-4000-8000-000000000073"), "name": .string(copyTesting ? copyName : "Workshop notes.txt"), "size": .number(5), "type": .string("text/plain"), "sha256": .string(TaskFileUploadJournal.digest(Data("hello".utf8)))]) }
}
extension Store {
    func withdrawFileViewerFixture() {
        guard TaskFileViewerFixture.enabled, let cache = nativeConversationTeamCache else { return }
        do {
            var raw = cache.boundary.raw; raw["projects"] = .array([])
            let boundary = try TeamWorkspaceBoundary(raw, account: userID, origin: "https://synthetic.example")
            snapshot.teamWorkspace = try TeamWorkspaceCache(boundary: boundary, previous: cache, pending: snapshot.pending, tasks: [])
            try persist()
        } catch { self.error = error.localizedDescription }
    }
}
struct TaskFileViewerFixtureScreen: View {
    @Environment(Store.self) private var store
    @State private var files: TaskFileUploadRequest?
    @State private var opening: TaskEditorOpening?
    @State private var proof = ""
    var body: some View {
        NavigationStack {
            Form {
                if let source = store.record("tasks", id: TeamEditorNativeFixture.taskID) {
                    Text(source.title).accessibilityIdentifier("fileViewerSavedTitle")
                    Text("Project role: " + (store.nativeConversationTeamCache?.boundary.projects[source.string("project_id")]?.role ?? "unavailable")).accessibilityIdentifier("fileViewerRole")
                    if TaskFileViewerFixture.selectionTesting {
                        Button("Open file capture") { files = store.fileUploadRequest(taskID: source.id) }.accessibilityIdentifier("fileSelectionOpen")
                    }
                    if TaskFileNativeProviderFixture.enabled {
                        Button("Prepare publication proof") {
                            Task {
                                do {
                                    guard let request = store.fileUploadRequest(taskID: source.id) else { return }
                                    let model = try store.fileUploadModel(request); await model.load()
                                    if model.pending == nil { await model.choose(Data("Native provider original".utf8), name: "Native provider proof.txt", type: "text/plain") }
                                    model.close(); files = request
                                } catch { proof = "Provider fixture needs review" }
                            }
                        }.accessibilityIdentifier("fileProviderOpen")
                        TaskFileUploadRecoveryButton()
                    }
                    if TaskFileViewerFixture.refreshTesting {
                        Button("Prepare saved recovery proof") {
                            Task {
                                do {
                                    guard let request = store.fileUploadRequest(taskID: source.id) else { return }
                                    let model = try store.fileUploadModel(request); await model.load()
                                    if model.pending == nil { await model.choose(Data("original recovery".utf8), name: "Original recovery.txt", type: "text/plain") }
                                    model.close(); files = request
                                } catch { proof = "Recovery fixture needs review" }
                            }
                        }.accessibilityIdentifier("fileRefreshOpen")
                    }
                    Button("Open task details") {
                        opening = TaskEditorOpening(task: source, admission: store.editorAdmission(source))
                    }.accessibilityIdentifier("fileViewerOpenDetails")
                    Button("Verify readable download") {
                        Task {
                            do {
                                guard let request = store.fileUploadReadRequest(source: source, workspace: .init(account: store.userID, generation: store.workspaceGeneration)),
                                      let attachment = store.fileUploadAttachments(request).first else { throw CancellationError() }
                                let before = store.snapshot
                                let bytes = try await store.downloadFile(attachment, request: request)
                                proof = bytes == Data("hello".utf8) && before.tables == store.snapshot.tables && before.pending == store.snapshot.pending ? "Verified bytes; saved tasks unchanged" : "Unexpected change"
                            } catch { proof = "Read refused" }
                        }
                    }.accessibilityIdentifier("fileViewerVerifyDownload")
                }
                Text(proof).accessibilityIdentifier("fileViewerDownloadProof")
                Text("Queued changes: \(store.snapshot.pending.count)").accessibilityIdentifier("fileViewerQueued")
            }.navigationTitle("Shared file viewer")
            .task { do { try TaskFileViewerFixture.prepareFileDialogs() } catch { proof = "File fixture needs review" } }
            .sheet(item: $files) { TaskFileUploadView(request: $0) }
            .sheet(item: $opening) { opening in
                #if os(macOS)
                TaskInspectorForm(taskID: opening.task.id, admission: opening.admission).frame(minWidth: 560, minHeight: 500)
                #else
                TaskEditor(task: opening.task, admission: opening.admission)
                #endif
            }
        }
    }
}
#endif

#if DEBUG
/// Exact isolated host only. Disposable user token, never a service key.
@MainActor enum TaskFileNativeProviderFixture {
    static var enabled: Bool { TaskFileViewerFixture.selectionTesting && ProcessInfo.processInfo.arguments.contains("--file-provider-native-testing") }
    static var auditURL: URL { URL.documentsDirectory.appendingPathComponent("taskfold-file-provider-native-audit.json") }
    static func observe(_ value: [String: Any]) {
        guard enabled else { return }
        var values = ((try? Data(contentsOf: auditURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
        values.append(value); values = Array(values.suffix(16))
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) { try? data.write(to: auditURL, options: .atomic) }
    }
    static var configurationURL: URL { URL.documentsDirectory.appendingPathComponent("taskfold-file-provider-native.json") }
    static func configuration() throws -> (url: URL, token: String) {
        guard enabled else { throw CancellationError() }
        let data = try Data(contentsOf: configurationURL)
        guard data.count <= 32768, let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(value.keys) == ["schema", "account", "url", "token"], value["schema"] == "1", value["account"] == TeamEditorNativeFixture.account,
              let url = value["url"].flatMap(URL.init(string:)), url.scheme == "http", url.host == "127.0.0.1", url.port.map({ $0 > 0 && $0 <= 65535 }) == true,
              url.path.isEmpty || url.path == "/", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let token = value["token"], token.utf8.count <= 16384, token.split(separator: ".").count == 3, !token.contains(where: { $0.isWhitespace }) else { throw CancellationError() }
        return (url, token)
    }
    static func reply(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = try configuration()
        guard request.httpMethod == "POST", request.url?.scheme == "https", request.url?.host == "synthetic.example",
              request.url?.path == "/functions/v1/task-files", let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false),
              parts.queryItems?.count == 1, let action = parts.queryItems?.first, action.name == "action", ["publish", "resolve", "cancel", "download"].contains(action.value ?? ""),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer " + config.token else { throw CancellationError() }
        var body = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var chunk = [UInt8](repeating: 0, count: 262144)
            while stream.hasBytesAvailable {
                try Task.checkCancellation(); let count = stream.read(&chunk, maxLength: chunk.count)
                guard count >= 0 else { throw CancellationError() }; if count == 0 { break }
                body.append(contentsOf: chunk.prefix(count)); guard body.count <= TaskFileUploadJournal.maximumStoredBytes else { throw CancellationError() }
            }
        }
        guard body.count <= TaskFileUploadJournal.maximumStoredBytes else { throw CancellationError() }
        let target = config.url.appending(queryItems: [.init(name: "action", value: action.value)])
        var forwarded = URLRequest(url: target); forwarded.httpMethod = "POST"; forwarded.httpBody = body; forwarded.timeoutInterval = 30
        forwarded.setValue("application/json", forHTTPHeaderField: "Content-Type"); forwarded.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = []; settings.httpCookieStorage = nil; settings.urlCache = nil
        let session = URLSession(configuration: settings); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: forwarded, delegate: TaskFileNativeRedirectRefusal.shared)
        guard let response = response as? HTTPURLResponse, response.url == target else { throw CancellationError() }
        var result = Data(); let maximum = action.value == "download" ? TaskFileUploadJournal.maximumBytes : 64000
        for try await byte in bytes { try Task.checkCancellation(); guard result.count < maximum else { throw CancellationError() }; result.append(byte) }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value } }
        guard let delivered = HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: headers) else { throw CancellationError() }
        return (result, delivered)
    }
}
@MainActor private final class TaskFileNativeProviderTransport: TaskFileUploadTransport {
    let backend: Backend
    init(_ backend: Backend) { self.backend = backend }
    func taskFileReply(_ journal: TaskFileUploadJournal, action: String, incarnation: UUID) async throws -> Data {
        do {
            let data = try await backend.taskFileReply(journal, action: action, incarnation: incarnation)
            var value: [String: Any] = ["action": action, "transportReturned": true, "response": String(decoding: data, as: UTF8.self)]
            do { value["validatedPhase"] = try journal.receiving(data).phase.rawValue }
            catch { value["receiptRejected"] = true }
            TaskFileNativeProviderFixture.observe(value); return data
        } catch {
            let error = error as NSError
            TaskFileNativeProviderFixture.observe(["action": action, "transportReturned": false, "domain": error.domain, "code": error.code])
            throw error
        }
    }
}
private final class TaskFileNativeRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = TaskFileNativeRedirectRefusal()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class TaskFileNativeProviderProtocol: URLProtocol, @unchecked Sendable {
    private let workerLock = NSLock()
    private var worker: Task<Void, Never>?
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" && request.url?.host == "synthetic.example" && request.url?.path == "/functions/v1/task-files" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Task { @MainActor in
            do {
                let (data, response) = try await TaskFileNativeProviderFixture.reply(self.request)
                try Task.checkCancellation()
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
            } catch { if !Task.isCancelled { self.client?.urlProtocol(self, didFailWithError: error) } }
        }
        workerLock.lock(); worker = value; let cancel = stopped; workerLock.unlock(); if cancel { value.cancel() }
    }
    override func stopLoading() { workerLock.lock(); stopped = true; let value = worker; workerLock.unlock(); value?.cancel() }
}
#endif
