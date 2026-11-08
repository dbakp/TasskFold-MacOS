import XCTest
@testable import TaskfoldCore

private struct ExecutorProbe: Decodable, Sendable {
    let onMainThread: Bool
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer().decode(String.self)
        onMainThread = Thread.isMainThread
    }
}

private final class ResponseDecodeGate: @unchecked Sendable {
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(_ started: XCTestExpectation) { self.started = started }
}
private struct HeldResponse: Decodable, Sendable {
    static let lock = NSLock()
    private static var storedGate: ResponseDecodeGate?
    static var gate: ResponseDecodeGate? {
        get { lock.withLock { storedGate } }
        set { lock.withLock { storedGate = newValue } }
    }
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer().decode(String.self)
        guard let gate = Self.gate else { throw CancellationError() }
        gate.started.fulfill()
        guard gate.release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
    }
}

final class ResponseDecodingTests: XCTestCase {
    @MainActor func testResponseDecodeDoesNotRunOnInterfaceThread() async throws {
        let value = try await TaskfoldJSONDecoder.decodeResponse(ExecutorProbe.self, from: Data("\"page\"".utf8))
        XCTAssertFalse(value.onMainThread)
    }

    func testResponseKeepsExactUnknownNumbersAndUnicodeKeys() async throws {
        let data = Data(#"[{"id":"task","subtasks":[{"future":{"exact":9007199254740993,"huge":1e500,"é":1,"é":2}}]}]"#.utf8)
        let expected = try TaskfoldJSONDecoder().decode([Record].self, from: data)
        let actual = try await TaskfoldJSONDecoder.decodeResponse([Record].self, from: data)
        XCTAssertEqual(actual.count, 1)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(actual[0]["subtasks"], expected[0]["subtasks"]))
        let roundTrip = try TaskfoldJSONDecoder().decode([Record].self, from: TaskfoldJSONEncoder().encode(actual))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(roundTrip[0]["subtasks"], expected[0]["subtasks"]))
    }

    func testMalformedResponseIsNotAnEmptySuccessfulPage() async {
        do {
            _ = try await TaskfoldJSONDecoder.decodeResponse([Record].self, from: Data("[{\"id\":".utf8))
            XCTFail("Malformed server data must fail the read")
        } catch is CancellationError { XCTFail("Malformed data is a decoding failure") }
        catch { }
    }

    @MainActor func testCancellationWhileDecodingDiscardsFinishedValue() async throws {
        let started = expectation(description: "Background decoder entered")
        let gate = ResponseDecodeGate(started)
        HeldResponse.gate = gate
        defer { HeldResponse.gate = nil; gate.release.signal() }
        let read = Task { try await TaskfoldJSONDecoder.decodeResponse(HeldResponse.self, from: Data("\"page\"".utf8)) }
        await fulfillment(of: [started], timeout: 3)
        read.cancel()
        gate.release.signal()
        do { _ = try await read.value; XCTFail("A cancelled page must not publish") }
        catch is CancellationError { }
    }
}
