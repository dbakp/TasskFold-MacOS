import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

/// Real authenticated reads through this repository's Backend and widget projection.
/// This supplements installed-host tests; it is not native Mac UI acceptance.
final class NoteFocusAccountIntegrationTests: XCTestCase {
    @MainActor func testAuthenticatedNoteAndEndedFocusRestoreAcrossAccountSwitchAndLogout() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let firstPath = environment["TASKFOLD_NOTE_FOCUS_FIRST"],
              let secondPath = environment["TASKFOLD_NOTE_FOCUS_SECOND"] else {
            throw XCTSkip("Two private disposable account fixtures are required")
        }
        func fixture(_ path: String) throws -> [String: String] {
            try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let first = try fixture(firstPath), second = try fixture(secondPath)
        let owner = try XCTUnwrap(first["userID"]), other = try XCTUnwrap(second["userID"]), nonce = try XCTUnwrap(second["nonce"])
        guard UUID(uuidString: owner) != nil, UUID(uuidString: other) != nil, UUID(uuidString: nonce) != nil, owner != other,
              first["email"] == "taskfold-continuity-" + owner + "@example.invalid",
              second["email"] == "taskfold-note-focus-" + nonce + "@example.invalid" else {
            throw XCTSkip("Fixtures must belong to the isolated continuity/account-switch namespaces")
        }
        let backend = Backend(configuration: ["URL": try XCTUnwrap(first["url"]), "Key": try XCTUnwrap(first["key"])], session: nil, persistSession: { _ in })
        var selectedNote: String?, originalClock: FocusWidgetClock?, originalText: String?
        var originalRows: [String: [[String: JSON]]]?
        for index in [0, 1, 0] {
            let f = index == 0 ? first : second, account = try XCTUnwrap(f["userID"])
            let signedIn = try await backend.signIn(email: try XCTUnwrap(f["email"]), password: try XCTUnwrap(f["password"]), signup: false)
            XCTAssertTrue(signedIn)
            XCTAssertEqual(backend.session?.user.id, account)
            do {
                var tables: [String: [Record]] = [:]
                for table in ["tasks", "projects", "sections", "labels", "saved_views", "view_orders", "focus_sessions"] {
                    tables[table] = try await backend.rows(table)
                    XCTAssertTrue(tables[table]!.allSatisfy { $0.string("user_id") == account })
                }
                let now = Date()
                let payload = WidgetProjection.payload(tasks: tables["tasks"]!, projects: tables["projects"]!, account: account, now: now, notePins: tables["view_orders"]!, focusRecord: tables["focus_sessions"]!.first)
                let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
                if index == 0 {
                    let note = try XCTUnwrap(snapshot.availableNotes.first)
                    let clock = try XCTUnwrap(snapshot.focusSession?.clock)
                    XCTAssertEqual(snapshot.availableNotes.count, 1)
                    XCTAssertEqual(snapshot.focusSessionStatus(at: now), .ended)
                    XCTAssertEqual(clock.taskID, note.taskID)
                    if selectedNote == nil {
                        selectedNote = note.id; originalClock = clock; originalText = note.text
                        originalRows = tables.mapValues { $0.map(\.fields) }
                    }
                    XCTAssertEqual(note.id, selectedNote); XCTAssertEqual(note.text, originalText)
                    XCTAssertEqual(clock, originalClock)
                    XCTAssertEqual(tables.mapValues { $0.map(\.fields) }, originalRows)
                    XCTAssertEqual(snapshot.noteStatus(selectedNote, at: now), .ready)
                    XCTAssertEqual(FocusSessionLink.parse(snapshot.focusSessionURL)?.account, owner)
                } else {
                    XCTAssertTrue(tables.values.allSatisfy(\.isEmpty))
                    XCTAssertTrue(snapshot.availableNotes.isEmpty)
                    XCTAssertNil(snapshot.note(selectedNote))
                    XCTAssertEqual(snapshot.noteStatus(selectedNote, at: now), .unavailable)
                    XCTAssertEqual(snapshot.focusSessionStatus(at: now), .idle)
                    XCTAssertNil(snapshot.focusSession?.clock)
                    XCTAssertEqual(FocusSessionLink.parse(snapshot.focusSessionURL)?.account, other)
                    let serialized = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
                    XCTAssertFalse(serialized.contains(try XCTUnwrap(originalClock).taskID))
                    XCTAssertFalse(serialized.contains(try XCTUnwrap(originalText)))
                }
                // Local revocation preserves the original native Mac/phone sessions.
                _ = try await backend.request("/auth/v1/logout?scope=local", method: "POST")
                try backend.clearSession()
                let signedOut = WidgetProjection.payload(tasks: tables["tasks"]!, projects: tables["projects"]!, account: "", now: now, notePins: tables["view_orders"]!, focusRecord: tables["focus_sessions"]!.first)
                let empty = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(signedOut))
                XCTAssertTrue(empty.availableNotes.isEmpty); XCTAssertTrue(empty.tasks.isEmpty)
                XCTAssertNil(empty.focusSession); XCTAssertEqual(empty.focusSessionURL.host, "today")
                XCTAssertEqual(empty.notesURL.host, "all")
            } catch {
                _ = try? await backend.request("/auth/v1/logout?scope=local", method: "POST")
                try? backend.clearSession(); throw error
            }
        }
    }
}
