import SwiftUI
import UniformTypeIdentifiers

// Child rows cutover (identical on iOS and macOS): Store helpers for satellites that create subtasks, and the one
// review that offers offline edits saved by the retired JSON child-record system for export.

extension Store {
    /// Adds titled subtasks under a saved parent as one undoable commit (Suggest steps / on-device AI).
    @discardableResult
    func addChildTasks(_ titles: [String], to parentID: String) -> Bool {
        guard TaskTree.rowsEnabled, let parent = record("tasks", id: parentID) else { error = "This task is no longer available."; return false }
        guard !titles.isEmpty else { return false }
        let rows = ChildRowSteps.rows(titles, under: parent, tree: TaskTree(tasks), account: userID)
        return commit(rows.map { Mutation(table: "tasks", recordID: $0.id, method: "POST", fields: $0.fields) })
    }

    /// Every legacy child journal that still holds saved work, as saved. Empty when there is nothing to offer.
    func legacyChildJournals() async throws -> [String: Data] {
        guard TaskTree.rowsEnabled, let scope = childTaskFieldRecoveryScope else { return [:] }
        return try legacyChildJournalBlobs(scope)
    }
}

/// The exported file: the saved journals as one JSON document.
struct LegacySubtaskEditsFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// "Subtask edits saved before the update": shown once per account and launch when legacy journals hold saved work.
struct LegacySubtaskEditsReview: ViewModifier {
    @Environment(Store.self) private var store
    @State private var journals: [String: Data] = [:]
    @State private var presented = false
    @State private var exporting = false
    @State private var file: LegacySubtaskEditsFile?
    @State private var failure: String?
    private var dismissedKey: String { "taskfold.legacySubtaskEditsDismissed." + store.userID }

    func body(content: Content) -> some View {
        content
            .task(id: store.childTaskFieldRecoveryScope?.account ?? "") {
                guard TaskTree.rowsEnabled, store.childTaskFieldRecoveryScope != nil, !UserDefaults.standard.bool(forKey: dismissedKey) else { return }
                guard let found = try? await store.legacyChildJournals(), !found.isEmpty, !Task.isCancelled else { return }
                journals = found; presented = true
            }
            .sheet(isPresented: $presented) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LegacyChildJournalExport.message).fixedSize(horizontal: false, vertical: true)
                        Text(journals.count == 1 ? "1 saved group of edits" : "\(journals.count) saved groups of edits").foregroundStyle(.secondary)
                        if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .navigationTitle(LegacyChildJournalExport.title)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Not now") { presented = false }.accessibilityIdentifier("legacySubtaskEditsLater")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Export…") {
                                do { file = LegacySubtaskEditsFile(data: try LegacyChildJournalExport.document(journals)); exporting = true }
                                catch { failure = "These edits couldn’t be prepared for export. They are still saved on this device." }
                            }.accessibilityIdentifier("legacySubtaskEditsExport")
                        }
                    }
                    .fileExporter(isPresented: $exporting, document: file, contentType: .json, defaultFilename: "Taskfold subtask edits") { result in
                        switch result {
                        case .success: UserDefaults.standard.set(true, forKey: dismissedKey); presented = false
                        case .failure: failure = "The export didn’t finish. The edits are still saved on this device."
                        }
                    }
                }
                .frame(minWidth: 360, minHeight: 220)
            }
    }
}

extension View {
    /// Offers legacy child journals for export once subtasks are rows.
    func legacySubtaskEditsReview() -> some View { modifier(LegacySubtaskEditsReview()) }
}
