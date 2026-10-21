import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor private final class CaptureModel: ObservableObject {
    @Published var title = ""
    @Published var notes = ""
    @Published var source = ""
    @Published var workspace: SharedCaptureWorkspace?
    @Published var loading = true
    @Published var saving = false
    @Published var message: String?
    private let draftID = UUID()
    private let createdAt = Date()
    var canSave: Bool { !loading && !saving && workspace != nil && (try? content()) != nil }
    private func content() throws -> SharedCaptureContent { try SharedCaptureContent(title: title, notes: notes, source: source) }
    func load(_ items: [NSExtensionItem]) async {
        do {
            workspace = try SharedCaptureDisk.system().workspace()
            guard workspace != nil else { throw SharedCaptureFailure("Open Taskfold and choose a workspace, then share again.") }
            guard !items.isEmpty, items.count <= 4 else { throw SharedCaptureFailure("Share text or one web link at a time.") }
            var texts: [String] = [], links: [String] = []
            var pageTitle = "", count = 0
            for item in items {
                if pageTitle.isEmpty { pageTitle = item.attributedTitle?.string ?? "" }
                if let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
                for provider in item.attachments ?? [] {
                    count += 1
                    guard count <= 8 else { throw SharedCaptureFailure("Share text or one web link at a time.") }
                    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        let value = try await load(provider, type: UTType.url.identifier)
                        let link = try SharedCaptureItem.webLink(value)
                        if !links.contains(link) { links.append(link) }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        let value = try await load(provider, type: UTType.plainText.identifier)
                        let text = try SharedCaptureItem.text(value)
                        if !texts.contains(text) { texts.append(text) }
                    } else { throw SharedCaptureFailure("This version captures text and web links. Share a text selection or link instead of a file.") }
                    guard texts.reduce(0, { $0 + $1.utf8.count }) <= SharedCaptureContent.maximumTextBytes, links.count <= 1 else {
                        throw SharedCaptureFailure("Share no more than 100 KB of text and one web link at a time.")
                    }
                }
            }
            guard !texts.isEmpty || !links.isEmpty else { throw SharedCaptureFailure("The source app did not include text or a web link.") }
            let content = try SharedCaptureContent.suggested(text: SharedCaptureContent.combine(texts), pageTitle: pageTitle, source: links.first ?? "")
            title = content.title; notes = content.notes; source = content.source
        } catch { message = error.localizedDescription; workspace = nil }
        loading = false
    }
    private func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: SharedCaptureFailure("The source app did not include readable content.")) }
            }
        }
    }
    func save() throws {
        guard let workspace, canSave else { throw SharedCaptureFailure("Review the title and source link before saving.") }
        saving = true; defer { saving = false }
        try SharedCaptureDisk.system().save(SharedCaptureDraft(id: draftID, workspace: workspace, content: content(), at: createdAt))
    }
}

private struct CaptureReview: View {
    @ObservedObject var model: CaptureModel
    let cancel: () -> Void
    let save: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").foregroundStyle(Color(red: 0.89, green: 0.12, blue: 0.29))
                Text("Save to Taskfold").font(.title2.weight(.semibold))
            }.padding(20)
            Divider()
            Form {
                if model.loading { ProgressView("Opening shared content…") }
                if let workspace = model.workspace {
                    Section {
                        Label(workspace.label, systemImage: "tray")
                        Text("Save a private draft on this Mac. Open Taskfold’s Shared drafts to choose a destination and add it to your tasks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Task") {
                        TextField("Title", text: $model.title, axis: .vertical).accessibilityIdentifier("sharedCaptureTitle")
                        TextField("Notes", text: $model.notes, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("sharedCaptureNotes")
                        TextField("Source link (optional)", text: $model.source, axis: .vertical).accessibilityIdentifier("sharedCaptureSource").autocorrectionDisabled()
                    }
                    if !model.loading, let error = validationMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
                if let message = model.message { Text(message).foregroundStyle(.red).accessibilityIdentifier("sharedCaptureError") }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save draft", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave).accessibilityIdentifier("saveSharedCapture")
            }.padding(16)
        }.tint(Color(red: 0.89, green: 0.12, blue: 0.29))
    }
    private var validationMessage: String? {
        do { _ = try SharedCaptureContent(title: model.title, notes: model.notes, source: model.source); return nil }
        catch { return error.localizedDescription }
    }
}

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let model = CaptureModel()
    override func loadView() {
        let host = NSHostingView(rootView: CaptureReview(model: model, cancel: { [weak self] in self?.cancel() }, save: { [weak self] in self?.save() }))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 500); view = host
        preferredContentSize = NSSize(width: 440, height: 500)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
    private func cancel() { extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    private func save() {
        do { try model.save(); extensionContext?.completeRequest(returningItems: nil) }
        catch { model.message = error.localizedDescription }
    }
}
