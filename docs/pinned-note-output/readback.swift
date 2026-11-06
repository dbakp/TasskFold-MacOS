import Foundation
import PDFKit
let file = URL(fileURLWithPath: CommandLine.arguments[1])
guard let pdf = PDFDocument(url: file), let text = pdf.string else { fatalError("Unreadable actual PDF") }
guard pdf.pageCount > 1, text.contains("Design section 1"), text.contains("Design section 8"), text.contains("FINAL-NATIVE-PRINT-INSTRUCTION") else { fatalError("Incomplete actual PDF") }
print("Actual pinned-note PDF: \(pdf.pageCount) pages; first/eighth sections and final instruction verified.")
