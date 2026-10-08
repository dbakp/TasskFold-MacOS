#if DEBUG
import SwiftUI
/// Visible only in the isolated debug workspace. Production clock events stay authoritative.
struct CalendarContextFixtureControls: ViewModifier {
    var editor = false
    private var prefix: String { editor ? "calendarEditorFixture" : "calendarFixture" }
    @Environment(Store.self) private var store
    @ViewBuilder func body(content: Content) -> some View {
        if store.clockWindowFixtureEnabled {
            VStack(spacing: 0) {
                HStack {
                    Button("Advance window clock") { store.setClockWindowFixtureClock(1) }
                        .accessibilityIdentifier(prefix + "AdvanceWindow").frame(minHeight: 44)
                    Text(store.clockWindowFixtureDataStatus).font(.caption2).accessibilityIdentifier(prefix + "WindowStatus")
                }.padding(.horizontal, 8).frame(maxWidth: .infinity).background(.bar, ignoresSafeAreaEdges: [])
                content
            }
        } else if store.calendarContextFixtureEnabled {
            VStack(spacing: 0) {
                HStack {
                    Menu("Fixture clock") {
                        Button("Fixture silent next day") { store.setCalendarFixtureClock(1) }
                        Button("Fixture next day") { store.setCalendarFixtureClock(1); NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil) }
                        Button("Fixture Honolulu") { store.setCalendarFixtureClock(2); NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil) }
                        Button("Prepare fixture resume") { store.setCalendarFixtureClock(3) }
                    }.accessibilityIdentifier(prefix + "Clock").frame(minHeight: 44)
                    Text(store.calendarContext.today + " · " + store.calendarContext.timeZone).font(.caption2).accessibilityIdentifier(prefix + "Context")
                    Text(store.calendarFixtureDataStatus).font(.caption2).accessibilityIdentifier(prefix + "DataStatus")
                }.padding(.horizontal, 8).frame(maxWidth: .infinity).background(.bar, ignoresSafeAreaEdges: [])
                content
            }
        } else { content }
    }
}

/// Isolated app execution harness; it is not an installed WidgetKit host.
struct WidgetActionTestPanel: View {
    @Environment(Store.self) private var store
    @State private var reminderRoute: ReminderTaskRoute?
    @State private var captured: WidgetCompletionRequest?
    @State private var message: String?
    @State private var pending = 0
    private let rootID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa10"
    private func inboxLink(account: String) -> URL {
        var components = URLComponents(); components.scheme = "taskfold"; components.host = "review"; components.path = "/inbox"
        components.queryItems = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "batch", value: "5")]
        return components.url!
    }
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--reminder-route-testing") {
            VStack(spacing: 4) {
                Text(store.reminderRouteFixtureOutcome).accessibilityIdentifier("reminderRouteOutcome")
                Button("End fixture") { store.disableNotifications() }.accessibilityIdentifier("endReminderRouteFixture")
                Button("Open earlier reminder") { Task { NotificationRoute.shared.taskRequest = await store.legacyReminderRouteFixtureRequest() } }.accessibilityIdentifier("openLegacyReminderRoute")
                Button("Delete and undo") { store.restoreReminderRouteFixtureTask() }.accessibilityIdentifier("restoreReminderTask")
                HStack {
                    Button("Hold reminder") { reminderRoute = store.reminderRouteFixtureRequest() }.accessibilityIdentifier("holdReminderRoute")
                    Button("Reenter workspace") { store.renewReminderRouteFixtureWorkspace() }.accessibilityIdentifier("renewReminderWorkspace")
                    Button("Release reminder") { NotificationRoute.shared.taskRequest = reminderRoute }.accessibilityIdentifier("releaseReminderRoute")
                }.font(.system(size: 12))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--pulse-widget-testing") {
            VStack(spacing: 4) {
                Text(store.pulseWidgetFixtureProjection()).font(.system(size: 10)).accessibilityIdentifier("pulseProjection")
                HStack {
                    Link("Open pulse", destination: ProjectPulseLink(account: store.userID, project: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71").url).accessibilityIdentifier("pulseWidgetOpen")
                    Link("Other workspace", destination: ProjectPulseLink(account: "other-workspace", project: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71").url).accessibilityIdentifier("pulseWidgetOther")
                    Link("Missing project", destination: ProjectPulseLink(account: store.userID, project: "missing-project").url).accessibilityIdentifier("pulseWidgetMissing")
                }.font(.system(size: 12))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--focus-widget-testing") {
            VStack(spacing: 4) {
                Text(store.focusWidgetFixtureProjection()).font(.system(size: 10)).accessibilityIdentifier("focusProjection")
                HStack {
                    Link("Open Focus", destination: FocusSessionLink(account: store.userID).url).accessibilityIdentifier("focusWidgetOpen")
                    Link("Other workspace", destination: FocusSessionLink(account: "other-workspace").url).accessibilityIdentifier("focusWidgetOtherWorkspace")
                }.font(.system(size: 12))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--pinned-notes-testing") {
            VStack(spacing: 4) {
                Text(store.pinnedNotesFixtureProjection()).font(.system(size: 10)).accessibilityIdentifier("noteProjection")
                HStack {
                    Link("Read note", destination: noteLink(account: store.userID, id: "note-first")).accessibilityIdentifier("noteOpenRead")
                    Link("Missing note", destination: noteLink(account: store.userID, id: "missing-note")).accessibilityIdentifier("noteOpenMissing")
                    Link("Other workspace", destination: noteLink(account: "other-workspace", id: "note-first")).accessibilityIdentifier("noteOtherWorkspace")
                }.font(.system(size: 12))
                Button("Fail next save") { store.inboxFixtureFailSave = true }.accessibilityIdentifier("noteFailSave")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--inbox-review-testing") {
            VStack(spacing: 4) {
                Text(store.inboxWidgetFixtureCount()).font(.system(size: 10)).accessibilityIdentifier("inboxProjection")
                Text(store.inboxFixturePlan()).font(.system(size: 10)).accessibilityIdentifier("inboxFixturePlan")
                HStack {
                    Link("Review Inbox", destination: inboxLink(account: store.userID)).accessibilityIdentifier("inboxOpenReview")
                    Link("Other workspace", destination: inboxLink(account: "other-workspace")).accessibilityIdentifier("inboxOtherWorkspace")
                }.font(.system(size: 12))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--capacity-widget-testing") {
            VStack(spacing: 4) {
                Text(store.capacityWidgetFixtureDay()).font(.system(size: 10)).accessibilityIdentifier("capacityProjection")
                HStack {
                    Link("Today's plan", destination: WidgetLinksFixture.today).accessibilityIdentifier("capacityOpenToday")
                    Link("Tomorrow's plan", destination: WidgetLinksFixture.tomorrow).accessibilityIdentifier("capacityOpenTomorrow")
                }.font(.system(size: 12)).buttonStyle(.bordered)
            }.padding(8).background(.regularMaterial)
        } else {
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
    }
    private func noteLink(account: String, id: String) -> URL {
        var parts = URLComponents(); parts.scheme = "taskfold"; parts.host = "note"; parts.path = "/" + id
        parts.queryItems = [URLQueryItem(name: "account", value: account)]; return parts.url!
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
private enum WidgetLinksFixture {
    static var today: URL { URL(string: "taskfold://day/" + TaskPlanner.dayKey(Date()))! }
    static var tomorrow: URL { URL(string: "taskfold://day/" + TaskPlanner.dayKey(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))! }
}

#endif
