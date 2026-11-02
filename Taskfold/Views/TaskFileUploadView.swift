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
        return TaskFileUploadModel(account: account, origin: request.origin, target: request.target, vault: vault, service: backend, incarnation: request.session,
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
                                    Button("Check status", systemImage: "arrow.clockwise") { Task { await model.act("resolve"); if available { await store.sync() } } }.disabled(model.busy || downloading).accessibilityIdentifier("fileUploadCheck")
                                }
                                Button(pending.phase == .queued ? "Remove unsent copy" : "Stop upload", role: .destructive) { Task { await model.act("cancel") } }.disabled(model.busy || downloading).accessibilityIdentifier("fileUploadStop")
                                Text("Your original file stays encrypted on this device until the result is confirmed. Closing this sheet keeps recovery available in Account.").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Button("Clear recovery copy", role: .destructive) { Task { await model.finish() } }.disabled(model.busy || downloading).accessibilityIdentifier("fileUploadClear")
                                Text("Clears only this device’s recovery copy. The shared file stays with its task.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } else if !request.library {
                        Section {
                            if store.taskFileUploadsEnabled {
                                Button("Choose a file…", systemImage: "doc.badge.plus") { copyStatus = nil; localMessage = nil; importing = true }.accessibilityFocused($copyFocused, equals: "choose").disabled(!model.loaded || model.busy || !store.fileUploadMayPublish(request)).accessibilityIdentifier("fileUploadChoose")
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
            .formStyle(.grouped).navigationTitle(request.library ? "Saved upload" : "Shared files")
            .toolbar {
                #if DEBUG
                if TaskFileViewerFixture.enabled { ToolbarItem { Button("Withdraw test access") { store.withdrawFileViewerFixture() }.accessibilityIdentifier("fileViewerWithdrawAccess") } }
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
