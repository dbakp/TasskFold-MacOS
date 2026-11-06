import XCTest
import CoreTransferable
import UniformTypeIdentifiers
@testable import TaskfoldCore

@available(macOS 15.2, *)
@MainActor final class ReviewedTaskOutputTests: XCTestCase {
    private let csv = Data("Title,Notes\r\n\"Café e\u{301}\",\"=Literal\nKeep this\"\r\n".utf8)
    private let pdf = Data("%PDF-1.7\nSynthetic representation bytes\n%%EOF".utf8)
    private func refuses<T: Transferable>(_ item: T, as type: UTType, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await item.exported(as: type); XCTFail("A revoked representation released bytes", file: file, line: line) }
        catch { }
    }
    func testActualPDFAndCSVRepresentationsKeepExactBytesAndTypes() async throws {
        let a = TaskPDFTransfer(permit: .init(data: pdf, allowed: { true }))
        let b = TaskCSVTransfer(permit: .init(data: csv, allowed: { true }))
        let aData = try await a.exported(as: .pdf), bData = try await b.exported(as: .commaSeparatedText)
        XCTAssertEqual(aData, pdf); XCTAssertEqual(bData, csv)
        XCTAssertEqual(a.exportedContentTypes(), [.pdf]); XCTAssertEqual(b.exportedContentTypes(), [.commaSeparatedText])
        XCTAssertNotEqual(a.id, b.id)
    }
    func testLiveSourceAndWorkspaceAreCheckedAtProviderRequest() async {
        let binding = WorkspaceBinding(account: "synthetic-output-owner", generation: UUID())
        var account = binding.account, generation = binding.generation, source = true
        let item = TaskCSVTransfer(permit: .init(data: csv, allowed: { binding.matches(account: account, generation: generation) && source }))
        source = false; await refuses(item, as: .commaSeparatedText)
        source = true; account = "other-synthetic-owner"; await refuses(item, as: .commaSeparatedText)
        account = binding.account; generation = UUID(); await refuses(item, as: .commaSeparatedText)
    }
    func testOptionsChangeRefusesOldRepresentation() async {
        let original = TaskRowCSV.Options(); var current = original
        let item = TaskCSVTransfer(permit: .init(data: csv, allowed: { current == original }))
        current.notes = false; await refuses(item, as: .commaSeparatedText)
    }
    func testClosedPresentationNeverRevivesWhenAnotherPresentationOpens() async throws {
        let old = ReviewedTaskOutputLifetime()
        let stale = TaskPDFTransfer(permit: .init(data: pdf, allowed: { old.isActive }))
        old.close()
        let next = ReviewedTaskOutputLifetime()
        let fresh = TaskPDFTransfer(permit: .init(data: pdf, allowed: { next.isActive }))
        await refuses(stale, as: .pdf)
        let data = try await fresh.exported(as: .pdf); XCTAssertEqual(data, pdf)
        await refuses(stale, as: .pdf)
    }
    func testInvalidatedSaveCannotReleaseAgainButAnotherSaveCan() async throws {
        let a = TaskCSVTransfer(permit: .init(data: csv, allowed: { true }))
        let b = TaskCSVTransfer(permit: .init(data: csv, allowed: { true }))
        a.permit.invalidate(); XCTAssertFalse(a.permit.isAllowed)
        await refuses(a, as: .commaSeparatedText)
        let data = try await b.exported(as: .commaSeparatedText); XCTAssertEqual(data, csv)
    }
    func testProviderRepeatedRequestsRecheckAndDoNotRetractEarlierCopies() async throws {
        var source = true
        let item = TaskPDFTransfer(permit: .init(data: pdf, allowed: { source }))
        let earlier = try await item.exported(as: .pdf)
        source = false; await refuses(item, as: .pdf)
        XCTAssertEqual(earlier, pdf, "Data already handed to a provider is outside app revocation")
    }
    func testActualFileExportRefusesAfterRevocationWithoutWritingPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-output-transfer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = TaskCSVTransfer(permit: .init(data: csv, allowed: { true }))
        let file = try await item.export(to: directory, contentType: .commaSeparatedText)
        XCTAssertEqual(try Data(contentsOf: file), csv)
        try FileManager.default.removeItem(at: file)
        item.permit.invalidate()
        do { _ = try await item.export(to: directory, contentType: .commaSeparatedText); XCTFail("Revoked file export succeeded") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }
    func testDelayedSeparateProviderTaskSeesRevocationBeforeRelease() async throws {
        let gate = OutputProviderGate(), item = TaskCSVTransfer(permit: .init(data: csv, allowed: { true }))
        let work = Task.detached { await gate.wait(); return try await item.exported(as: .commaSeparatedText) }
        await gate.entered()
        item.permit.invalidate(); await gate.open()
        do { _ = try await work.value; XCTFail("Delayed provider released revoked data") } catch { }
    }
    func testCancelledProviderTaskCannotRelease() async throws {
        let gate = OutputProviderGate(), item = TaskPDFTransfer(permit: .init(data: pdf, allowed: { true }))
        let work = Task.detached { await gate.wait(); return try await item.exported(as: .pdf) }
        await gate.entered(); work.cancel(); await gate.open()
        do { _ = try await work.value; XCTFail("Cancelled provider released data") } catch { }
    }
}

private actor OutputProviderGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrived = false
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        arrived = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func entered() async { if !arrived { await withCheckedContinuation { observer = $0 } } }
    func open() { waiter?.resume(); waiter = nil }
}
