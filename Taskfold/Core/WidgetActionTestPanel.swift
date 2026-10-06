#if DEBUG
import SwiftUI
/// Isolated app execution harness; it is not an installed WidgetKit host.
struct WidgetActionTestPanel: View {
    @Environment(Store.self) private var store
    @State private var captured: WidgetCompletionRequest?
    @State private var message: String?
    @State private var pending = 0
    private let rootID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa10"
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Original: \(store.record("tasks", id: rootID)?.completed == true ? "completed" : "open")").accessibilityIdentifier("widgetRootState")
                Text("Next copies: \(store.tasks.filter { $0.string("recurrence_parent_id") == rootID }.count)").accessibilityIdentifier("widgetCopyCount")
                Text("Queued: \(pending)").accessibilityIdentifier("widgetPendingCount")
            }.font(.caption)
            Text("Drafts: \(store.tasks.filter { $0.title == "Saved occurrence draft" }.count)").font(.caption).accessibilityIdentifier("widgetDraftCount")
            HStack {
                Button("Complete via intent") { perform(captured) }.accessibilityIdentifier("widgetCompleteFixture")
                Button("Queue only") {
                    do { if let captured { try store.queueWidgetActionFixture(captured) }; pending = store.widgetActionFixturePending() }
                    catch { message = error.localizedDescription }
                }.accessibilityIdentifier("widgetQueueFixture")
            }
            HStack {
                Button("Undo completion") { store.undo(); pending = store.widgetActionFixturePending() }.accessibilityIdentifier("widgetUndoFixture")
                Button("Retry old tap") { perform(captured) }.accessibilityIdentifier("widgetRetryFixture")
                Button("Other workspace") {
                    if var request = captured { request.account = "other-workspace"; perform(request) }
                }.accessibilityIdentifier("widgetWrongAccountFixture")
            }
        }.buttonStyle(.bordered).controlSize(.regular).padding(8).background(.regularMaterial)
        .task(id: "\(store.taskRevision)-\(store.widgetFixtureReady)") {
            guard !ProcessInfo.processInfo.arguments.contains("--widget-action-seed") || store.widgetFixtureReady else { return }
            if captured == nil, let token = WidgetCompletion.tokens(store.snapshot)[rootID] {
                captured = try? WidgetCompletionRequest(account: store.userID, taskID: rootID, token: token)
            }
            pending = store.widgetActionFixturePending()
        }
        .alert("Widget action", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func perform(_ request: WidgetCompletionRequest?) {
        guard let request else { return }
        Task { @MainActor in
            do { _ = try await CompleteWidgetTaskIntent(account: request.account, taskID: request.taskID, token: request.token).perform() }
            catch { message = error.localizedDescription; store.error = nil }
            pending = store.widgetActionFixturePending()
        }
    }
}
#endif
