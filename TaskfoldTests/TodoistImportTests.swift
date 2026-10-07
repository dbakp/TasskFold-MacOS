import XCTest
@testable import TaskfoldCore

final class TodoistImportTests: XCTestCase {
    private let token = "isolated-fixture-token"
    private func preview() -> Record { Record(["preview": .bool(true), "sourceAccount": .string("source-a"), "counts": .object(Dictionary(uniqueKeysWithValues: TodoistImportFlow.countKeys.map { ($0, .number(2)) })), "warnings": .array([.string("Unsupported reminders")])]) }
    private func receipt() -> Record { var row = Record(["success": .bool(true), "sourceAccount": .string("source-a"), "warnings": .array([.string("Unsupported reminders")])]); for key in TodoistImportFlow.resultKeys { row[key] = .number(key.hasSuffix("Skipped") ? 2 : 0) }; return row }
    private func approved(_ workspace: UUID) throws -> TodoistImportFlow { var flow = TodoistImportFlow(); flow.updateToken(token); let request = try flow.begin(previewOnly: true, workspace: workspace); XCTAssertFalse(try flow.accept(preview(), request: request, workspace: workspace)); return flow }

    func testPreviewBoundToTokenAndWorkspaceBeforeImport() throws {
        let workspace = UUID(); var flow = TodoistImportFlow()
        for input in ["", "short", String(repeating: "x", count: 513)] { flow.updateToken(input); XCTAssertFalse(flow.canPreview); XCTAssertThrowsError(try flow.begin(previewOnly: true, workspace: workspace)) }
        flow.updateToken("  " + token + "\n"); XCTAssertTrue(flow.canPreview)
        XCTAssertThrowsError(try flow.begin(previewOnly: false, workspace: workspace))
        let previewRequest = try flow.begin(previewOnly: true, workspace: workspace)
        XCTAssertEqual(previewRequest.body, ["userToken": .string(token), "preview": .bool(true), "stream": .bool(false), "sourceAccount": .null])
        flow.updateToken("different-fixture-token"); XCTAssertEqual(flow.token, "  " + token + "\n", "Editing is disabled while requesting")
        XCTAssertThrowsError(try flow.begin(previewOnly: true, workspace: workspace))
        _ = try flow.accept(preview(), request: previewRequest, workspace: workspace)
        XCTAssertThrowsError(try flow.begin(previewOnly: false, workspace: UUID()))
        let request = try flow.begin(previewOnly: false, workspace: workspace)
        XCTAssertEqual(request.body["sourceAccount"], .string("source-a")); XCTAssertEqual(request.body["preview"], .bool(false))
    }
    func testTokenChangeInvalidatesApprovalAndError() throws {
        let workspace = UUID(); var flow = try approved(workspace)
        flow.updateToken("another-fixture-token")
        XCTAssertNil(flow.preview); XCTAssertNil(flow.result); XCTAssertEqual(flow.warnings, [])
        XCTAssertThrowsError(try flow.begin(previewOnly: false, workspace: workspace))
    }
    func testInvalidPreviewNeverOffersImportOrInventsZeroCounts() throws {
        let workspace = UUID()
        var cases = [Record(), preview(), preview(), preview(), preview(), preview()]
        cases[1]["sourceAccount"] = .string(""); cases[2]["preview"] = .bool(false)
        cases[3]["counts"] = .object([:]); cases[4]["warnings"] = .array([.number(1)])
        cases[5]["counts"] = .object(Dictionary(uniqueKeysWithValues: TodoistImportFlow.countKeys.map { ($0, .number(-1)) }))
        for row in cases {
            var flow = TodoistImportFlow(); flow.updateToken(token); let request = try flow.begin(previewOnly: true, workspace: workspace)
            XCTAssertThrowsError(try flow.accept(row, request: request, workspace: workspace))
            flow.fail(AppFailure(message: "Invalid preview"), request: request, workspace: workspace)
            XCTAssertFalse(flow.busy); XCTAssertNil(flow.preview); XCTAssertThrowsError(try flow.begin(previewOnly: false, workspace: workspace))
        }
        for n in [0.5, 1e20] {
            var row = preview(); var counts = row["counts"].object; counts["tasks"] = .number(n); row["counts"] = .object(counts)
            var flow = TodoistImportFlow(); flow.updateToken(token); let request = try flow.begin(previewOnly: true, workspace: workspace)
            XCTAssertThrowsError(try flow.accept(row, request: request, workspace: workspace))
        }
    }
    func testUnconfirmedOrChangedAccountReceiptKeepsRetryApproval() throws {
        let workspace = UUID(); var rows = [receipt(), receipt(), receipt(), receipt()]
        rows[0]["success"] = .bool(false); rows[1]["sourceAccount"] = .string("source-b"); rows[2].fields.removeValue(forKey: "tasksSkipped"); rows[3]["commentsImported"] = .number(-1)
        for row in rows {
            var flow = try approved(workspace); let request = try flow.begin(previewOnly: false, workspace: workspace)
            XCTAssertThrowsError(try flow.accept(row, request: request, workspace: workspace))
            flow.fail(AppFailure(message: "Unconfirmed import"), request: request, workspace: workspace)
            XCTAssertNil(flow.result); XCTAssertNotNil(flow.preview); XCTAssertEqual(flow.token, token)
        }
    }
    func testLostResponseRetryAndLateResponseCannotOverwriteReceipt() throws {
        let workspace = UUID(); var flow = try approved(workspace)
        let first = try flow.begin(previewOnly: false, workspace: workspace)
        flow.fail(AppFailure(message: "Response lost"), request: first, workspace: workspace)
        XCTAssertEqual(flow.message, "Response lost"); XCTAssertEqual(flow.warnings, ["Unsupported reminders"])
        let retry = try flow.begin(previewOnly: false, workspace: workspace); XCTAssertEqual(retry.body, first.body)
        XCTAssertFalse(try flow.accept(receipt(), request: first, workspace: workspace)); XCTAssertTrue(flow.busy)
        XCTAssertTrue(try flow.accept(receipt(), request: retry, workspace: workspace))
        XCTAssertFalse(flow.busy); XCTAssertNil(flow.preview); XCTAssertEqual(flow.token, ""); XCTAssertEqual(flow.result?["tasksSkipped"], .number(2))
        flow.fail(AppFailure(message: "Late failure"), request: first, workspace: workspace); XCTAssertNil(flow.message)
        XCTAssertEqual(TodoistImportFlow.resultTitle("tasksSkipped"), "Tasks already imported")
    }
    func testWorkspaceChangeAndDismissalDiscardResponseAndToken() throws {
        let workspace = UUID(); var flow = try approved(workspace); let request = try flow.begin(previewOnly: false, workspace: workspace)
        XCTAssertFalse(try flow.accept(receipt(), request: request, workspace: UUID())); XCTAssertNil(flow.result); XCTAssertEqual(flow.token, "")
        flow.updateToken(token); let previewRequest = try flow.begin(previewOnly: true, workspace: workspace); flow.reset()
        XCTAssertFalse(try flow.accept(preview(), request: previewRequest, workspace: workspace)); XCTAssertNil(flow.preview); XCTAssertFalse(flow.busy)
    }
}
