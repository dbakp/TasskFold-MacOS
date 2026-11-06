import XCTest
@testable import TaskfoldCore

extension AudioCommentVaultTests {
    func testInterruptedPrimaryCannotReplaceADraftWithAnOutstandingSave() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let pending = try AudioCommentSaveIntent(next: original.replacing(caption: "Pending in the other editor", clip: original.clip), base: original.revision, reviews: [])
        try file.prepareSave(pending, fence: file.departureFence())
        let staged = try original.replacing(caption: "Interrupted update", clip: original.clip)
        let path = try stage(staged.encoded(), in: file), item = try XCTUnwrap(file.interruptedWrites().first)
        XCTAssertThrowsError(try file.recover(item, replacing: original.revision))
        XCTAssertEqual(try file.drafts(), [original]); XCTAssertEqual(try file.saves(), [pending])
        XCTAssertEqual(try Data(contentsOf: path), try staged.encoded())
    }
    func testInterruptedReplacementCannotReassignRecoveryProvenance() throws {
        let file = try vault(), base = try draft()
        let original = try AudioCommentSavedDraft(owner: base.owner, target: base.target, caption: base.caption, clip: base.clip, id: base.id, revision: base.revision, origin: .init(try draft()))
        try file.save(original)
        let changed = try AudioCommentSavedDraft(owner: original.owner, target: original.target, caption: "Different origin", clip: original.clip, id: original.id, origin: .init(try draft()))
        let path = try stage(changed.encoded(), in: file), item = try XCTUnwrap(file.interruptedWrites().first)
        XCTAssertThrowsError(try file.recover(item, replacing: original.revision))
        XCTAssertEqual(try file.drafts(), [original]); XCTAssertEqual(try Data(contentsOf: path), try changed.encoded())
    }
}

extension AudioCommentVaultTests {
    func testInterruptedCatalogKeepsReadableStagesAlongsideIncompleteBytes() throws {
        let file = try vault("local"), original = try draft(file.owner)
        try file.save(original)
        let recovered = try draft(file.owner), good = try stage(recovered.encoded(recovery: true), in: file)
        let partial = Data("interrupted binary payload".utf8), damaged = try stage(partial, in: file)
        let catalog = try file.interruptedCatalog()
        XCTAssertEqual(catalog.unreadableCount, 1); XCTAssertEqual(catalog.writes.count, 1)
        guard case .review(let value) = catalog.writes[0].payload else { return XCTFail("Expected the intact review") }
        XCTAssertEqual(value, recovered); XCTAssertThrowsError(try file.interruptedWrites())
        XCTAssertEqual(try Data(contentsOf: damaged), partial); XCTAssertEqual(try file.drafts(), [original])
        try file.recover(catalog.writes[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path))
        XCTAssertEqual(try file.drafts(recovery: true), [recovered]); XCTAssertEqual(try file.drafts(), [original])
        XCTAssertEqual(try Data(contentsOf: damaged), partial)
    }
    func testInterruptedCatalogDoesNotExposeForeignOwnerPayload() throws {
        let file = try vault("local"), foreign = try draft(.init("other"))
        let data = try foreign.encoded(), path = try stage(data, in: file)
        let catalog = try file.interruptedCatalog()
        XCTAssertTrue(catalog.writes.isEmpty); XCTAssertEqual(catalog.unreadableCount, 1)
        XCTAssertEqual(try Data(contentsOf: path), data); XCTAssertTrue(try file.drafts().isEmpty)
    }
    func testInterruptedCatalogRejectsFilesystemLinksInsteadOfTreatingThemAsCorruptPayloads() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let outside = root.appendingPathComponent("outside.bin"), data = try original.encoded()
        try data.write(to: outside)
        let link = file.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try file.interruptedCatalog()); XCTAssertEqual(try Data(contentsOf: outside), data)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: outside, to: link)
        XCTAssertThrowsError(try file.interruptedCatalog()); XCTAssertEqual(try Data(contentsOf: outside), data)
        try FileManager.default.removeItem(at: link)
        XCTAssertEqual(try file.drafts(), [original])
    }
    func testInterruptedCatalogPreservesJournalAndPublicationKindsWithoutPromotingThem() throws {
        let file = try vault(), next = try draft(), intent = try AudioCommentSaveIntent(next: next, base: nil, reviews: [])
        _ = try stage(intent.encoded(), in: file)
        _ = try stage(pending().encoded(), in: file)
        let catalog = try file.interruptedCatalog()
        XCTAssertEqual(catalog.unreadableCount, 0); XCTAssertEqual(catalog.writes.count, 2)
        XCTAssertEqual(catalog.writes.filter { if case .save = $0.payload { return true }; return false }.count, 1)
        XCTAssertEqual(catalog.writes.filter { if case .pending = $0.payload { return true }; return false }.count, 1)
        XCTAssertTrue(try file.saves().isEmpty); XCTAssertTrue(try file.pending().isEmpty); XCTAssertTrue(try file.drafts().isEmpty)
    }
    func testInterruptedCatalogRemainsBoundedAndNeverDeletesAnExcessFile() throws {
        let file = try vault("local"), bytes = Data("partial".utf8)
        for _ in 0...AudioCommentVault.maximumEntries { _ = try stage(bytes, in: file) }
        let catalog = try file.interruptedCatalog()
        XCTAssertEqual(catalog.unreadableCount, AudioCommentVault.maximumEntries + 1)
        XCTAssertTrue(catalog.writes.isEmpty)
        let extra = file.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
        try bytes.write(to: extra)
        XCTAssertThrowsError(try file.interruptedCatalog())
        XCTAssertEqual(try Data(contentsOf: extra), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: file.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".write-") }.count, AudioCommentVault.maximumEntries + 2)
    }
}
