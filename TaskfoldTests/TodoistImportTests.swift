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
    func testInterruptedSaveExplainsUncertaintyAndPreservesExactRetrySource() throws {
        for code in [URLError.networkConnectionLost, .timedOut, .notConnectedToInternet] {
            let workspace = UUID(); var flow = try approved(workspace)
            let save = try flow.begin(previewOnly: false, workspace: workspace)
            flow.fail(URLError(code), request: save, workspace: workspace)
            XCTAssertEqual(flow.message, "Taskfold couldn’t confirm the import. It may already have saved. Retry this import safely: previously imported items and your Taskfold edits are preserved.")
            XCTAssertNil(flow.result); XCTAssertNotNil(flow.preview); XCTAssertFalse(flow.busy)
            let retry = try flow.begin(previewOnly: false, workspace: workspace)
            XCTAssertEqual(retry.body, save.body)
            flow.fail(URLError(code), request: save, workspace: workspace)
            XCTAssertTrue(flow.busy, "An old interruption must not cancel the retry")
            XCTAssertNil(flow.message)
            XCTAssertTrue(try flow.accept(receipt(), request: retry, workspace: workspace))
            XCTAssertEqual(flow.token, "")
        }
    }
    func testPreviewInterruptionDoesNotSuggestASavedImport() throws {
        let workspace = UUID(); var flow = TodoistImportFlow(); flow.updateToken(token)
        let request = try flow.begin(previewOnly: true, workspace: workspace)
        let failure = URLError(.networkConnectionLost)
        flow.fail(failure, request: request, workspace: workspace)
        XCTAssertEqual(flow.message, failure.localizedDescription); XCTAssertNil(flow.preview)
        XCTAssertThrowsError(try flow.begin(previewOnly: false, workspace: workspace))
    }

}


extension TodoistImportTests {
    private func headingPreview(available: Bool) -> Record {
        var row = preview(); row["headings"] = .object(["version": .number(1), "roots": .number(1), "subtasks": .number(1), "available": .bool(available)]); return row
    }
    func testUnavailableHeadingPreviewKeepsSourceButCannotStartImport() throws {
        let workspace = UUID(); var flow = TodoistImportFlow(); flow.updateToken(token)
        let request = try flow.begin(previewOnly: true, workspace: workspace)
        _ = try flow.accept(headingPreview(available: false), request: request, workspace: workspace)
        XCTAssertEqual(flow.headingCount, 2); XCTAssertFalse(flow.canImport)
        XCTAssertThrowsError(try flow.begin(previewOnly: false, workspace: workspace, supportsHeadings: true))
        XCTAssertNotNil(flow.preview); XCTAssertEqual(flow.token, token); XCTAssertFalse(flow.busy)
    }
    func testAvailableHeadingPreviewRequiresDeclaredClientSupportAndCapturedApproval() throws {
        let workspace = UUID(); var flow = TodoistImportFlow(); flow.updateToken(token)
        let request = try flow.begin(previewOnly: true, workspace: workspace, supportsHeadings: true)
        XCTAssertEqual(request.body["capabilities"], .array([.string("task_headings")]))
        _ = try flow.accept(headingPreview(available: true), request: request, workspace: workspace)
        XCTAssertTrue(flow.canImport)
        XCTAssertThrowsError(try flow.begin(previewOnly: false, workspace: workspace))
        let save = try flow.begin(previewOnly: false, workspace: workspace, supportsHeadings: true)
        XCTAssertEqual(save.body["headingApproval"], .object(["roots": .number(1), "subtasks": .number(1)]))
        XCTAssertEqual(save.body["sourceAccount"], .string("source-a"))
    }
    func testTypedReceiptNeedsConfirmedFormatAndCapabilityBeforeClearingToken() throws {
        let workspace = UUID(); var flow = TodoistImportFlow(); flow.updateToken(token)
        let request = try flow.begin(previewOnly: true, workspace: workspace, supportsHeadings: true)
        _ = try flow.accept(headingPreview(available: true), request: request, workspace: workspace)
        let save = try flow.begin(previewOnly: false, workspace: workspace, supportsHeadings: true)
        XCTAssertThrowsError(try flow.accept(receipt(), request: save, workspace: workspace))
        flow.fail(AppFailure(message: "Unconfirmed format"), request: save, workspace: workspace)
        XCTAssertNotNil(flow.preview); XCTAssertEqual(flow.token, token)
        let retry = try flow.begin(previewOnly: false, workspace: workspace, supportsHeadings: true)
        XCTAssertEqual(save.body, retry.body)
        var result = receipt(); result["formatVersion"] = .number(2); result["capabilities"] = .array([.string("task_headings")])
        XCTAssertTrue(try flow.accept(result, request: retry, workspace: workspace)); XCTAssertNil(flow.preview); XCTAssertEqual(flow.token, "")
    }
    func testMalformedOrUnrequestedHeadingResponseNeverAuthorizesImport() throws {
        let workspace = UUID()
        var invalid = [headingPreview(available: true), headingPreview(available: false), headingPreview(available: false), headingPreview(available: false)]
        invalid[1]["headings"] = .object(["version": .number(2), "roots": .number(1), "subtasks": .number(0), "available": .bool(false)])
        invalid[2]["headings"] = .object(["version": .number(1), "roots": .number(99), "subtasks": .number(0), "available": .bool(false)])
        invalid[3]["headings"] = .object(["version": .number(1), "roots": .number(0.5), "subtasks": .number(0), "available": .bool(false)])
        for row in invalid {
            var flow = TodoistImportFlow(); flow.updateToken(token); let request = try flow.begin(previewOnly: true, workspace: workspace)
            XCTAssertThrowsError(try flow.accept(row, request: request, workspace: workspace)); XCTAssertFalse(flow.canImport); XCTAssertNil(flow.preview)
        }
    }
    func testLegacyPreviewDoesNotInventHeadingApprovalOrChangeLiteralTaskText() throws {
        let workspace = UUID(); var flow = try approved(workspace)
        XCTAssertEqual(flow.headingCount, 0); XCTAssertTrue(flow.canImport)
        let save = try flow.begin(previewOnly: false, workspace: workspace)
        XCTAssertNil(save.body["headingApproval"]); XCTAssertNil(save.body["capabilities"])
        var literal = Record.task(user: "synthetic"); literal["title"] = .string("* Literal Taskfold text")
        XCTAssertEqual(TaskKind(literal), .task); XCTAssertEqual(literal.title, "* Literal Taskfold text")
    }
}


extension TodoistImportTests {
    func testHeadingAwareClientCannotApproveLegacyServiceWithoutTypeReview() throws {
        let workspace = UUID(); var flow = TodoistImportFlow(); flow.updateToken("isolated-fixture-token")
        let request = try flow.begin(previewOnly: true, workspace: workspace, supportsHeadings: true)
        XCTAssertThrowsError(try flow.accept(preview(), request: request, workspace: workspace))
        XCTAssertNil(flow.preview); XCTAssertFalse(flow.canImport)
        flow.fail(AppFailure(message: "Service needs heading review"), request: request, workspace: workspace)
        XCTAssertEqual(flow.token, "isolated-fixture-token"); XCTAssertFalse(flow.busy)
    }
}
