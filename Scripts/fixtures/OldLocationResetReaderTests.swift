import XCTest
@testable import TaskfoldCore
final class OldLocationResetReaderTests: XCTestCase {
    func testNewResetAuthorityIsRefusedWithoutOrdinaryWritesOverwritingIt() async throws {
        let golden = try XCTUnwrap(Bundle.module.url(forResource: "reset-location", withExtension: "json", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: golden), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), file = LocationPrivateFile(applicationSupport: root)
        _ = try await store.setAllowance(account: "compat-reset", enabled: true, expectedDevice: nil)
        try bytes.write(to: file.url, options: .atomic)
        XCTAssertThrowsError(try file.read())
        do { _ = try await store.setAllowance(account: "compat-reset", enabled: false, expectedDevice: "98000000-0000-4000-8000-000000000001"); XCTFail("Previous reader overwrote newer reset authority") } catch {}
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }
}
