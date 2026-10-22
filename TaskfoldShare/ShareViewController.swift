import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor private final class CaptureModel: ObservableObject {
    @Published var title = ""
    @Published var notes = ""
    @Published var source = ""
    @Published var workspace: SharedCaptureWorkspace?
    @Published var omittedMapPreview = false
    @Published var loading = true
    @Published var saving = false
    @Published var message: String?
    private let draftID = UUID()
    private let createdAt = Date()
    var canSave: Bool { !loading && !saving && workspace != nil && (try? content()) != nil }
    private func content() throws -> SharedCaptureContent { try SharedCaptureContent(title: title, notes: notes, source: source) }
    func load(_ items: [NSExtensionItem]) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        do {
            try Task.checkCancellation()
            workspace = try SharedCaptureDisk.system().workspace()
            guard workspace != nil else { throw SharedCaptureFailure("Open Taskfold and choose a workspace, then share again.") }
            let intake = try await SharedCaptureIntake.read(items, deadline: deadline)
            try Task.checkCancellation()
            let content = intake.content
            omittedMapPreview = intake.omittedMapPreview
            title = content.title; notes = content.notes; source = content.source
        } catch is CancellationError { workspace = nil }
        catch { message = error.localizedDescription; workspace = nil }
        loading = false
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
                    .disabled(model.loading || model.saving)
                    if !model.loading, let error = validationMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
                if model.omittedMapPreview {
                    Text("Map previews aren’t copied. Review the included text and source link.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("sharedCaptureMapNotice")
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
    private var readTask: Task<Void,Never>?
    override func loadView() {
        let host = NSHostingView(rootView: CaptureReview(model: model, cancel: { [weak self] in self?.cancel() }, save: { [weak self] in self?.save() }))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 500); view = host
        preferredContentSize = NSSize(width: 440, height: 500)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        readTask = Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
    override func viewWillDisappear() { super.viewWillDisappear(); readTask?.cancel() }
    deinit { readTask?.cancel() }
    private func cancel() { readTask?.cancel(); extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    private func save() {
        do { try model.save(); extensionContext?.completeRequest(returningItems: nil) }
        catch { model.message = error.localizedDescription }
    }
}
