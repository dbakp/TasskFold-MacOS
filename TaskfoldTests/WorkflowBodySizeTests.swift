import XCTest
import CryptoKit
@testable import TaskfoldCore

final class WorkflowBodySizeTests: XCTestCase {
    private func corpus() -> [JSON] {
        var values: [JSON] = [.null, .bool(false), .bool(true), .array([]), .object([:])]
        let strings = ["", "\"\\/,:[]{}", "line\nnext\tcolumn\rreturn", "é", "e\u{301}", "\u{2028}\u{2029}", "東京 العربية 🙂"]
        for text in strings { values += [.string(text), .object([text: .string(text)])] }
        for byte in 0...127 { values.append(.string(String(Unicode.Scalar(byte)!))) }
        let numbers: [Double] = [0, -0.0, 1, -1, 1.5, -1.5, .pi, .leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude, 1e-7, 1e20, 1e21, 1e308, .infinity, -.infinity, .nan]
        values += numbers.map(JSON.number)
        var bits: UInt64 = 0x9e3779b97f4a7c15
        for index in 0..<600 {
            bits = bits &* 6364136223846793005 &+ 1442695040888963407
            let number = JSON.number(Double(bitPattern: bits))
            values += [number, .object(["quoted : ,": .array([.string("\\\"/"), number, .number(Double(index))])])]
        }
        // Every representable scalar: controls, noncharacters, combining forms,
        // supplementary planes and separators must keep their previous byte cost.
        let scalars = (0...0x10ffff).compactMap(Unicode.Scalar.init)
        let unicode = String(String.UnicodeScalarView(scalars))
        values.append(.object([unicode: .string(unicode)]))
        for depth in [1, 126, 127, 128, 129, 255, 510, 511, 512, 513, 600] {
            var value = JSON.string("deep / \" : ,")
            for index in 0..<depth { value = index.isMultiple(of: 2) ? .array([value]) : .object(["value": value]) }
            values.append(value)
        }
        values.append(.array((0..<5000).map { .object(["id": .string("row-\($0)"), "order": .number(Double($0)), "title": .string("Keep : , \" \\ / é e\u{301} 🙂"), "done": .bool(false)]) }))
        return values
    }

    func testLegacyBudgetBoundaryRemainsExact() {
        for delta in [-1, 0, 1] {
            let change = Mutation(table: "test", recordID: "test", method: "POST", fields: ["n": .string(String(repeating: "x", count: WorkflowUndo.maximumBytes - 9 + delta))])
            XCTAssertEqual(WorkflowUndo.bodyBytes(change), WorkflowUndo.maximumBytes + delta)
            XCTAssertEqual(WorkflowUndo.bodyBytes(change), WorkflowUndo.encodedBodyBytes(change))
            XCTAssertEqual(WorkflowUndo.fitsBody(change), delta <= 0)
        }
    }

    func testFrozenBodySizeCorpus() throws {
        let values = corpus()
        let sizes = values.enumerated().map { index, value in
            let change = Mutation(table: "test", recordID: "test", method: "POST", fields: ["value": value])
            let size = WorkflowUndo.bodyBytes(change)
            XCTAssertEqual(size, WorkflowUndo.encodedBodyBytes(change), "Corpus case \(index)")
            return size
        }
        let bytes = try JSONEncoder().encode(sizes)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        print("WORKFLOW_BODY_SIZE_CORPUS \(values.count) \(digest)")
        // Frozen from the original encoder/scanner before the production change.
        XCTAssertEqual(digest, "61adeb48f306dd1a3e94f15647507e6227a67af0e1221eb2d262de442bd3acf6")
        XCTAssertEqual(sizes[0], 15)
        XCTAssertEqual(sizes[1], 16)
        XCTAssertEqual(sizes[2], 15)
    }
}
