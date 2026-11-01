import SwiftUI
import UniformTypeIdentifiers

struct TaskFileUploadRequest: Identifiable {
    let id = UUID()
    let account: String, origin: String, target: Record
    let workspace: UUID, session: UUID
    var library: Bool { target.fields.isEmpty }
}
extension Store {
    var taskFileUploadsEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "TaskfoldTaskFilesEnabled") as? Bool == true }
    private func fileUploadDirectory(account: String, origin: String) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("vault", account), isDirectory: true)
            .appendingPathComponent("Shared file uploads", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("origin", origin), isDirectory: true)
    }
    func fileUploadRequest(taskID: String? = nil) -> TaskFileUploadRequest? {
        guard teamTemplateRecoveryAvailable, let origin = try? backend.accountRemovalOrigin,
              backend.audioPublicationSessionMatches(userID) else { return nil }
        var target = Record([:])
        if let taskID {
            guard teamOrganizationReadable, !workspaceNeedsRepair, let cache = nativeConversationTeamCache, cache.boundary.belongs(account: userID, origin: origin),
                  let source = record("tasks", id: taskID), TaskFileUploadJournal.validID(source.id), TaskFileUploadJournal.validID(source.string("task_generation")),
                  let permission = cache.boundary.projects[source.string("project_id")], let team = permission.team else { return nil }
            target = Record(["team_id": .string(team), "project_id": .string(permission.id), "task_id": .string(source.id), "task_generation": source["task_generation"]])
        }
        return .init(account: userID, origin: origin, target: target, workspace: workspaceGeneration, session: backend.reminderSessionIncarnation)
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
        guard fileUploadCurrent(request), taskFileUploadsEnabled, !request.library, online, !syncing, snapshot.pending.isEmpty,
              let source = record("tasks", id: request.target.string("task_id")), source["task_generation"] == request.target["task_generation"],
              source["project_id"] == request.target["project_id"], let admission = try? captureTeamTaskEditor(source) else { return false }
        return admission.scope.team == request.target.string("team_id")
    }
    func fileUploadModel(_ request: TaskFileUploadRequest) throws -> TaskFileUploadModel {
        guard fileUploadCurrent(request) else { throw TaskFileUploadJournal.invalid }
        let directory = fileUploadDirectory(account: request.account, origin: request.origin), root = cacheURL.deletingLastPathComponent(), account = request.account
        let io = ReviewedTeamCommandFileIO<TaskFileUploadJournal>(directory: directory, account: account, origin: request.origin, encryptionKey: { try BackupVault.deviceKey(account: account) })
        let vault = TaskFileUploadVault(io: io, coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("TeamCommandLocks", isDirectory: true), removalDirectory: root)
        return TaskFileUploadModel(account: account, origin: request.origin, target: request.target, vault: vault, service: backend, incarnation: request.session,
            current: { [weak self] in self?.fileUploadCurrent(request) == true }, publishAllowed: { [weak self] in self?.fileUploadMayPublish(request) == true })
    }
    func fileUploadAttachments(_ request: TaskFileUploadRequest) -> [Record] {
        guard fileUploadCurrent(request), teamOrganizationReadable, let cache = nativeConversationTeamCache, cache.boundary.belongs(account: request.account, origin: request.origin), !request.library, let task = record("tasks", id: request.target.string("task_id")), task["task_generation"] == request.target["task_generation"],
              task["project_id"] == request.target["project_id"], let permission = cache.boundary.projects[task.string("project_id")], permission.team == request.target.string("team_id") else { return [] }
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
    @AccessibilityFocusState private var statusFocused: Bool
    private var available: Bool { store.fileUploadCurrent(request) }
    var body: some View {
        NavigationStack {
            Form {
                if available, let model {
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
                            Button("Save local copy…", systemImage: "square.and.arrow.down") { export(pending.bytes, name: pending.name) }.disabled(model.busy || downloading)
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
                                Button("Choose a file…", systemImage: "doc.badge.plus") { importing = true }.disabled(!model.loaded || model.busy || !store.fileUploadMayPublish(request)).accessibilityIdentifier("fileUploadChoose")
                                Text("Share a file up to 5 MB with people who can access this project.").font(.footnote).foregroundStyle(.secondary)
                            } else { Text("New file sharing is paused. You can still save existing shared files.").foregroundStyle(.secondary) }
                        }
                    } else { ContentUnavailableView("No saved upload", systemImage: "checkmark.circle") }
                    if !request.library, !store.fileUploadAttachments(request).isEmpty {
                        Section("Shared files") {
                            ForEach(store.fileUploadAttachments(request)) { attachment in
                                Button { download(attachment) } label: { Label(attachment.string("name"), systemImage: "arrow.down.doc") }.disabled(model.busy || downloading).accessibilityLabel("Save a copy of " + attachment.string("name"))
                            }
                        }
                    }
                    if model.busy || downloading { ProgressView(downloading ? "Preparing file…" : "Saving upload status…").accessibilityIdentifier("fileUploadProgress") }
                    if let message = localMessage ?? model.message { Section { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityFocused($statusFocused).accessibilityIdentifier("fileUploadMessage") } }
                } else if !available { ContentUnavailableView("Workspace changed", systemImage: "lock", description: Text("Reopen saved file recovery from the original account.")) }
                else if let localMessage { Text(localMessage) } else { ProgressView("Opening saved upload…") }
            }
            .formStyle(.grouped).navigationTitle(request.library ? "Saved upload" : "Shared files")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model?.close(); dismiss() }.accessibilityIdentifier("fileUploadDismiss") } }
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 520, minHeight: 380, idealHeight: 580)
            #endif
        }
        .task { do { let value = try store.fileUploadModel(request); model = value; await value.load() } catch { localMessage = "Your saved upload couldn’t be opened. Nothing was sent." } }
        .onDisappear { model?.close(); document = nil }
        .onChange(of: available) { _, value in if !value { importing = false; exporting = false; document = nil; model?.close() } }
        .onChange(of: model?.message) { _, _ in statusFocused = true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard available, let model else { return }
            switch result {
            case .success(let url):
                Task {
                    do {
                        let bytes = try await Task.detached(priority: .userInitiated) {
                            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var bytes = Data()
                            while true { try Task.checkCancellation(); let chunk = try handle.read(upToCount: min(262144, TaskFileUploadJournal.maximumBytes + 1 - bytes.count)) ?? Data(); if chunk.isEmpty { break }; bytes.append(chunk); guard bytes.count <= TaskFileUploadJournal.maximumBytes else { throw TaskFileUploadJournal.invalid } }
                            return bytes
                        }.value
                        guard available else { return }
                        let proposed = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        await model.choose(bytes, name: url.lastPathComponent, type: TaskFileUploadJournal.types.contains(proposed) ? proposed : "application/octet-stream")
                    } catch { if available { localMessage = "The file couldn’t be read. Choose an available file up to 5 MB." } }
                }
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { localMessage = "No file was selected. Your saved upload is unchanged." }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: filename) { result in
            document = nil
            if available, case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { localMessage = "The copy couldn’t be saved. Your original file is kept." }
        }
    }
    private func status(_ value: TaskFileUploadJournal) -> String {
        switch value.phase { case .queued: return "Saved on this device"; case .attempted: return "Result not yet confirmed"; case .published: return "Shared successfully"; case .cancelled: return "Upload stopped"; case .expired: return "Upload expired" }
    }
    private func export(_ data: Data, name: String) {
        guard available else { return }; document = .init(data: data); filename = URL(fileURLWithPath: name).lastPathComponent; exporting = true
    }
    private func download(_ attachment: Record) {
        guard available, !downloading else { return }; downloading = true
        Task { defer { downloading = false }; do { let bytes = try await store.downloadFile(attachment, request: request); guard available else { return }; export(bytes, name: attachment.string("name")) } catch { if available { localMessage = "The file couldn’t be opened. Refresh the task and try again." } } }
    }
}
