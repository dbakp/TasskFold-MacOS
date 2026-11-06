import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct ReviewedTaskOutputFailure: LocalizedError {
    var errorDescription: String? { "The source or workspace changed. Reopen this export from the current list." }
}

/// A presentation never reopens its old permits when the view appears again.
@MainActor final class ReviewedTaskOutputLifetime {
    private(set) var isActive = true
    func close() { isActive = false }
}

/// Providers can request a representation after a Save/Share control was tapped.
/// Evaluate live source, workspace and options on the main actor at byte release.
@MainActor final class ReviewedTaskOutput {
    private var bytes: Data?
    private let allowed: @MainActor () -> Bool
    init(data: Data, allowed: @escaping @MainActor () -> Bool) {
        bytes = data; self.allowed = allowed
    }
    var isAllowed: Bool { bytes != nil && allowed() }
    func invalidate() { bytes = nil }
    func release() throws -> Data {
        try Task.checkCancellation()
        guard let bytes, allowed() else { throw ReviewedTaskOutputFailure() }
        return bytes
    }
}

protocol ReviewedTaskOutputTransfer: Transferable, Identifiable where ID == UUID {
    var permit: ReviewedTaskOutput { get }
    static var contentType: UTType { get }
}

struct TaskPDFTransfer: ReviewedTaskOutputTransfer, Sendable {
    let id = UUID()
    let permit: ReviewedTaskOutput
    static var contentType: UTType { .pdf }
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { value in
            try await value.permit.release()
        }.suggestedFileName("Taskfold.pdf")
    }
}

struct TaskCSVTransfer: ReviewedTaskOutputTransfer, Sendable {
    let id = UUID()
    let permit: ReviewedTaskOutput
    static var contentType: UTType { .commaSeparatedText }
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { value in
            try await value.permit.release()
        }.suggestedFileName("Taskfold-tasks.csv")
    }
}
