import SwiftUI
import PDFKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct PrintReviewRequest: Identifiable {
    let id = UUID()
    let document: PrintDocument
    let workspace: WorkspaceBinding
    let isCurrent: @MainActor () -> Bool
}
private struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PrintReviewView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    let request: PrintReviewRequest
    @State private var options = TaskPrintRenderer.Options()
    @State private var output: TaskPrintRenderer.Output?
    @State private var renderedOptions: TaskPrintRenderer.Options?
    @State private var exportData = Data()
    @State private var failure: String?
    @State private var status: String?
    @State private var retry = 0
    @State private var exporting = false
    @State private var printing = false
    @State private var showingOptions = false
    private struct RenderKey: Equatable { let options: TaskPrintRenderer.Options; let retry: Int; let available: Bool }
    private var prepared: TaskPrintRenderer.Output? { renderedOptions == options ? output : nil }
    private var available: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) && request.isCurrent() }
    private var itemLabel: String { "\(request.document.count) " + (request.document.noteOnly ? (request.document.count == 1 ? "note" : "notes") : (request.document.count == 1 ? "task" : "tasks")) }
    private var filename: String {
        let value = request.document.title.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.prefix(70)
        return value.isEmpty ? "Taskfold" : String(value)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if available {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.document.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader).accessibilityIdentifier("printDocumentTitle")
                        if !textSize.isAccessibilitySize, !request.document.subtitle.isEmpty { Text(request.document.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        HStack(alignment: .firstTextBaseline) {
                            if let output = prepared { Text("\(output.pages) \(output.pages == 1 ? "page" : "pages") · \(itemLabel)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("printPageCount") }
                            Spacer(minLength: 12)
                            Text(options.paper.rawValue).font(.caption).foregroundStyle(.secondary).accessibilityLabel("Paper size, " + options.paper.rawValue)
                        }
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("printStatus") }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    if let failure {
                        ScrollView { VStack(alignment: .leading, spacing: 12) { Text(failure).foregroundStyle(.red).accessibilityIdentifier("printError"); Button("Try again") { retry += 1 } }.padding() }
                    }
                    if let output = prepared { NativePDFPreview(data: output.data).accessibilityIdentifier("printPDFPreview") }
                    else if failure == nil { ProgressView("Preparing pages…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { Spacer(minLength: 12) }
                    ViewThatFits(in: .horizontal) {
                        HStack { saveButton; printButton }
                        VStack { saveButton; printButton }
                    }.buttonStyle(.bordered).padding()
                } else {
                    ContentUnavailableView("Document changed", systemImage: "doc.badge.clock", description: Text("Close this preview and reopen it from your current workspace. Your saved work is unchanged."))
                        .accessibilityIdentifier("printSourceChanged")
                }
            }.navigationTitle("Print & PDF")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closePrintReview") }
                    ToolbarItem(placement: .confirmationAction) { Button("Options", systemImage: "slider.horizontal.3") { showingOptions = true }.disabled(!available).accessibilityIdentifier("printOptions") }
                }
                .sheet(isPresented: $showingOptions) { optionsSheet }
                .task(id: RenderKey(options: options, retry: retry, available: available)) { await render() }
                .onChange(of: available) { _, valid in if !valid { output = nil; renderedOptions = nil; exportData = Data(); exporting = false; printing = false; showingOptions = false } }
                .fileExporter(isPresented: $exporting, document: PDFFileDocument(data: exportData), contentType: .pdf, defaultFilename: filename) { result in
                    guard available else { return }
                    switch result { case .success: status = "PDF saved"; case .failure(let error): if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription } }
                }
                #if os(iOS)
                .sheet(isPresented: $printing) { NativePrintPanel(data: prepared?.data ?? Data(), title: request.document.title, allowed: available, finish: { error in printing = false; if let error { failure = error } }) }
                #endif
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 760, minHeight: 650, idealHeight: 820)
        #endif
    }
    private var optionsSheet: some View {
        NavigationStack {
            Form {
                if available {
                    Section("Page") {
                        Picker("Paper size", selection: $options.paper) { ForEach(TaskPrintRenderer.Paper.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("printPaper")
                    }
                    if !request.document.noteOnly {
                        Section("Content") {
                            Toggle("Include notes", isOn: $options.notes).accessibilityIdentifier("printIncludeNotes")
                            Toggle("Include checklists", isOn: $options.checklists).accessibilityIdentifier("printIncludeChecklists")
                        }
                        Section { Text("Includes all matching tasks and collapsed groups. Checklists include their nested items.").foregroundStyle(.secondary) }
                    }
                    if !request.document.subtitle.isEmpty { Section { Text(request.document.subtitle).foregroundStyle(.secondary) } }
                } else { Text("The document or workspace changed. Close this preview and reopen it.") }
            }.formStyle(.grouped).navigationTitle("Print options")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOptions = false }.accessibilityIdentifier("closePrintOptions") } }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
    private var saveButton: some View {
        Button("Save PDF…", systemImage: "square.and.arrow.down") { guard available, let output = prepared else { return }; exportData = output.data; status = nil; exporting = true }
            .disabled(!available || prepared == nil).accessibilityIdentifier("saveTaskPDF")
    }
    private var printButton: some View {
        Button("Print…", systemImage: "printer") {
            guard available, let output = prepared else { return }
            #if os(iOS)
            printing = true
            #else
            guard let pdf = PDFDocument(data: output.data), let window = NSApp.keyWindow,
                  let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { failure = "The print panel could not open. You can still save this PDF."; return }
            info.paperSize = options.paper.size; info.orientation = .portrait
            guard let operation = pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { failure = "The print panel could not open. You can still save this PDF."; return }
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            #endif
        }.disabled(!available || prepared == nil).accessibilityIdentifier("printTaskPDF")
    }
    @MainActor private func render() async {
        output = nil; renderedOptions = nil; failure = nil; status = nil
        guard available else { return }
        let capturedOptions = options, document = request.document
        let work = Task.detached(priority: .userInitiated) { try TaskPrintRenderer.render(document, options: capturedOptions) }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            guard available, options == capturedOptions else { return }
            renderedOptions = capturedOptions; output = value
        } catch is CancellationError { }
        catch { if !Task.isCancelled, available { failure = error.localizedDescription } }
    }
}

#if os(iOS)
private struct NativePDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.backgroundColor = .secondarySystemBackground; return view }
    func updateUIView(_ view: PDFView, context: Context) { if context.coordinator.data != data { context.coordinator.data = data; view.document = PDFDocument(data: data); view.autoScales = true } }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}
private struct NativePrintPanel: UIViewControllerRepresentable {
    let data: Data
    let title: String
    let allowed: Bool
    let finish: (String?) -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(data: data, title: title, allowed: allowed, finish: finish) }
    func updateUIViewController(_ controller: Controller, context: Context) { if !allowed { controller.cancel() } }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.cancel() }
    final class Controller: UIViewController {
        let data: Data; let jobTitle: String; let allowed: Bool; let finish: (String?) -> Void
        private var presented = false
        init(data: Data, title: String, allowed: Bool, finish: @escaping (String?) -> Void) { self.data = data; jobTitle = title; self.allowed = allowed; self.finish = finish; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented, allowed else { return }; presented = true
            let print = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil); info.jobName = jobTitle; info.outputType = .general
            print.printInfo = info; print.printingItem = data; print.showsPageRange = true
            let completion: UIPrintInteractionController.CompletionHandler = { [weak self] _, _, error in self?.finish(error?.localizedDescription) }
            if UIDevice.current.userInterfaceIdiom == .pad { print.present(from: CGRect(x: view.bounds.midX, y: 1, width: 1, height: 1), in: view, animated: true, completionHandler: completion) }
            else { print.present(animated: true, completionHandler: completion) }
        }
        func cancel() { if presented { presented = false; UIPrintInteractionController.shared.dismiss(animated: false) } }
    }
}
#else
private struct NativePDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) { if context.coordinator.data != data { context.coordinator.data = data; view.document = PDFDocument(data: data); view.autoScales = true } }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}
#endif
