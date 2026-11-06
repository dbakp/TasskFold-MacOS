import SwiftUI

/// Applying updates the owning editor, which retains its existing Save/recovery/Undo path.
struct TodoistHeadingConversionReview: View {
    @Environment(\.dismiss) private var dismiss
    let request: TodoistHeadingConversion
    let available: () -> Bool
    let apply: (Bool) throws -> Void
    @State private var removeMarker: Bool
    @State private var failure: String?
    init(request: TodoistHeadingConversion, available: @escaping () -> Bool, apply: @escaping (Bool) throws -> Void) {
        self.request = request; self.available = available; self.apply = apply
        _removeMarker = State(initialValue: request.removeMarkerByDefault)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Imported heading", systemImage: "textformat").font(.headline)
                    Text("This older Todoist import kept its heading as a task. Choose whether to make this copy a heading that stays open.")
                        .foregroundStyle(.secondary)
                }
                Section("Imported title") { Text(request.sourceTitle).textSelection(.enabled) }
                Section("Title after conversion") {
                    Text(request.title(removingMarker: removeMarker)).textSelection(.enabled).accessibilityIdentifier("headingConversionTitle")
                    if request.canRemoveMarker {
                        Toggle("Remove the leading * marker", isOn: $removeMarker).accessibilityIdentifier("headingConversionRemoveMarker")
                    }
                    if request.titleChangedSinceImport {
                        Text("Your title has changed since import. Your current wording is kept; the imported title will not replace it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Notes, dates, reminders, files and nested tasks are kept. Ordinary tasks beneath this heading can still be completed. Recurrence settings are kept, but a heading stays open and creates no recurring successor.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Todoist is unchanged. This choice applies only to the current Taskfold copy.").font(.caption).foregroundStyle(.secondary)
                    if !available() { Text("The task or workspace changed. Close this review and open the current task.").foregroundStyle(.secondary).accessibilityIdentifier("headingConversionChanged") }
                    if let failure { Text(failure).foregroundStyle(.red).accessibilityIdentifier("headingConversionError") }
                }
            }.formStyle(.grouped).accessibilityIdentifier("headingConversionForm").navigationTitle("Review heading")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("headingConversionCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use heading") {
                        do { guard available() else { throw AppFailure(message: "Reopen this review from the current task.") }; try apply(removeMarker); dismiss() }
                        catch { failure = error.localizedDescription }
                    }.disabled(!available()).accessibilityIdentifier("headingConversionApply")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 570)
        #else
        .presentationDetents([.large])
        #endif
    }
}
