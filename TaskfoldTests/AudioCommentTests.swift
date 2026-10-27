import XCTest
import CryptoKit
@testable import TaskfoldCore

final class AudioCommentTests: XCTestCase {
    let workspace = WorkspaceBinding(account: "11111111-1111-4111-8111-111111111111", generation: UUID())
    func target() throws -> AudioCommentTarget { try .init(task: UUID(), generation: UUID(), project: UUID()) }
    func fixture() throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "audio-comment-synthetic-tone", withExtension: "m4a", subdirectory: "Fixtures"))) }
    func ready() throws -> AudioCommentDraft {
        var draft = AudioCommentDraft(workspace: workspace, target: try target())
        let token = try draft.begin(workspace: workspace, target: draft.target)
        draft.started(token, workspace: workspace, target: draft.target)
        XCTAssertTrue(draft.receive(try AudioCommentClip(data: fixture()), token: token, workspace: workspace, target: draft.target))
        return draft
    }
    func replacing(_ bytes: Data, marker: String, offset: Int = 0, with replacement: [UInt8]) throws -> Data {
        var result = bytes
        let range = try XCTUnwrap(bytes.range(of: Data(marker.utf8)))
        let start = range.lowerBound + offset
        result.replaceSubrange(start..<(start + replacement.count), with: replacement)
        return result
    }
    func testGeneratedAACHasBoundedDurationAndExactBinaryDigest() throws {
        let data = try fixture(), clip = try AudioCommentClip(data: data)
        XCTAssertEqual(clip.data, data)
        XCTAssertEqual(clip.descriptor.byteCount, data.count)
        XCTAssertEqual(clip.descriptor.milliseconds, 1069)
        XCTAssertEqual(clip.descriptor.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertTrue(clip.verifies(clip.descriptor))
        XCTAssertFalse(clip.verifies(try .init(byteCount: data.count, milliseconds: 1070, sha256: clip.descriptor.sha256)))
    }
    func testEmptyOversizedAndTruncatedContainersRefuseWithoutPartialAudio() throws {
        XCTAssertThrowsError(try AudioCommentClip(data: Data()))
        XCTAssertThrowsError(try AudioCommentClip(data: Data(repeating: 0, count: AudioCommentDescriptor.maximumBytes + 1)))
        let data = try fixture()
        // Includes incomplete top-level header, movie, free-space and media-data atom.
        for count in [1, 3, 7, 15, 27, 28, 29, 100, 1034, data.count - 1] {
            XCTAssertThrowsError(try AudioCommentClip(data: data.prefix(count)), "length \(count)")
        }
    }
    func testOversizedExtendedAtomAndTrailingGarbageRefuse() throws {
        var extended = Data([0,0,0,1]); extended.append(Data("ftyp".utf8)); extended.append(Data(repeating: 255, count: 8))
        XCTAssertThrowsError(try AudioCommentClip(data: extended))
        var trailing = try fixture(); trailing.append(0)
        XCTAssertThrowsError(try AudioCommentClip(data: trailing))
        var short = try fixture(); short.replaceSubrange(0..<4, with: [0,0,0,4])
        XCTAssertThrowsError(try AudioCommentClip(data: short))
    }
    func testVideoUnknownCodecDuplicateTrackAndFragmentedAudioRefuse() throws {
        let data = try fixture()
        for pair in [("soun", "vide"), ("mp4a", "alac"), ("free", "moof"), ("udta", "trak")] {
            XCTAssertThrowsError(try AudioCommentClip(data: replacing(data, marker: pair.0, with: Array(pair.1.utf8))))
        }
    }
    func testInvalidDurationVersionZeroTimescaleAndExcessiveLengthRefuse() throws {
        let data = try fixture()
        XCTAssertThrowsError(try AudioCommentClip(data: replacing(data, marker: "mvhd", offset: 4, with: [2])))
        XCTAssertThrowsError(try AudioCommentClip(data: replacing(data, marker: "mdhd", offset: 16, with: [0,0,0,0])))
        XCTAssertThrowsError(try AudioCommentClip(data: replacing(data, marker: "mvhd", offset: 20, with: [255,255,255,255])))
    }
    func testMalformedSampleDescriptionRefusesRatherThanReadingOutsidePayload() throws {
        let data = try fixture()
        XCTAssertThrowsError(try AudioCommentClip(data: replacing(data, marker: "stsd", offset: 8, with: [0,0,0,2])))
        XCTAssertThrowsError(try AudioCommentClip(data: replacing(data, marker: "stsd", offset: -4, with: [0,0,0,8])))
    }
    func testDescriptorWireRejectsExtraFieldsFractionalValuesAndInvalidDigest() throws {
        let descriptor = try AudioCommentClip(data: fixture()).descriptor
        XCTAssertEqual(try JSONDecoder().decode(AudioCommentDescriptor.self, from: JSONEncoder().encode(descriptor)), descriptor)
        for (key, value) in [("version", JSON.number(2)), ("byte_count", .number(1.5)), ("duration_ms", .number(-1)), ("duration_ms", .number(120001)), ("sha256", .string(descriptor.sha256.uppercased())), ("mime_type", .string("video/mp4")), ("url", .string("https://invalid.example/private"))] {
            var record = descriptor.record; record.fields[key] = value
            XCTAssertThrowsError(try AudioCommentDescriptor(record: record), key)
        }
    }
    func testTargetRequiresTaskIncarnationAndNeverAcceptsArbitraryObjectPath() throws {
        let target = try target(), asset = UUID()
        XCTAssertEqual(try AudioCommentTarget(record: target.record), target)
        XCTAssertEqual(try target.objectName(asset: asset), "audio-comments/v1/\(target.task.uuidString.lowercased())/\(target.generation.uuidString.lowercased())/\(asset.uuidString.lowercased()).m4a")
        XCTAssertThrowsError(try AudioCommentTarget(task: .init(), generation: AudioCommentTarget.zero, project: nil))
        XCTAssertThrowsError(try target.objectName(asset: AudioCommentTarget.zero))
        var injected = target.record; injected.fields["object_name"] = .string("someone-else/audio.m4a")
        XCTAssertThrowsError(try AudioCommentTarget(record: injected))
        XCTAssertNoThrow(try AudioCommentTarget(task: UUID(), generation: UUID(), project: nil))
    }
    func testLatePermissionAndRecordingCallbacksCannotCrossScope() throws {
        var draft = AudioCommentDraft(workspace: workspace, target: try target())
        let token = try draft.begin(workspace: workspace, target: draft.target)
        let other = WorkspaceBinding(account: workspace.account, generation: UUID())
        draft.started(token, workspace: other, target: draft.target)
        XCTAssertEqual(draft.phase, .authorizing)
        draft.started(token, workspace: workspace, target: draft.target)
        XCTAssertFalse(draft.receive(try AudioCommentClip(data: fixture()), token: token, workspace: other, target: draft.target))
        XCTAssertFalse(draft.receive(try AudioCommentClip(data: fixture()), token: token, workspace: workspace, target: try target()))
        draft.close()
        XCTAssertFalse(draft.receive(try AudioCommentClip(data: fixture()), token: token, workspace: workspace, target: draft.target))
        XCTAssertNil(draft.clip)
    }
    func testReplacementFailureKeepsReviewedClipAndOldCallbackCannotOverwriteIt() throws {
        var draft = try ready(); let original = try XCTUnwrap(draft.clip).descriptor
        let old = try draft.begin(workspace: workspace, target: draft.target)
        draft.failed(old)
        XCTAssertEqual(draft.phase, .review); XCTAssertEqual(draft.clip?.descriptor, original)
        let current = try draft.begin(workspace: workspace, target: draft.target)
        draft.failed(old); XCTAssertEqual(draft.token, current)
        draft.started(current, workspace: workspace, target: draft.target); draft.finishing()
        XCTAssertFalse(draft.receive(try AudioCommentClip(data: fixture()), token: old, workspace: workspace, target: draft.target))
        XCTAssertTrue(draft.receive(try AudioCommentClip(data: fixture()), token: current, workspace: workspace, target: draft.target))
    }
    func testPublishingRequiresReviewAndUnchangedScope() throws {
        var draft = AudioCommentDraft(workspace: workspace, target: try target())
        XCTAssertThrowsError(try draft.preparePublication(workspace: workspace, target: draft.target))
        draft = try ready()
        XCTAssertThrowsError(try draft.preparePublication(workspace: WorkspaceBinding(account: UUID().uuidString, generation: workspace.generation), target: draft.target))
        XCTAssertThrowsError(try draft.preparePublication(workspace: workspace, target: try target()))
        XCTAssertEqual(draft.phase, .review); XCTAssertNil(draft.publication)
    }
    func testUncertainRetryPreservesEveryIdentifierAndExactCaption() throws {
        var draft = try ready(); try draft.editCaption("  Reviewed cafe\u{301}\nمراجعة 🪴  ")
        let intent = try draft.preparePublication(workspace: workspace, target: draft.target)
        XCTAssertThrowsError(try draft.editCaption("changed"))
        XCTAssertThrowsError(try draft.begin(workspace: workspace, target: draft.target))
        draft.unconfirmed()
        XCTAssertThrowsError(try draft.retry(workspace: WorkspaceBinding(account: workspace.account, generation: UUID()), target: draft.target))
        let retry = try draft.retry(workspace: workspace, target: draft.target)
        XCTAssertTrue(intent.sameIntent(as: retry))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(intent), try encoder.encode(retry))
        XCTAssertTrue(draft.confirmed(retry, workspace: workspace, target: draft.target))
        XCTAssertThrowsError(try draft.retry(workspace: workspace, target: draft.target))
    }
    func testCanonicalEquivalentCaptionDoesNotConfirmAnotherRawIntent() throws {
        var draft = try ready(); try draft.editCaption("café")
        let original = try draft.preparePublication(workspace: workspace, target: draft.target)
        let altered = try AudioCommentPublication(account: original.account, target: original.target, caption: "cafe\u{301}", descriptor: original.descriptor, operation: original.operation, comment: original.comment, asset: original.asset)
        XCTAssertEqual(original.caption, altered.caption) // Swift semantic string equality alone is insufficient.
        XCTAssertNotEqual(original, altered)
        XCTAssertFalse(original.sameIntent(as: altered))
        XCTAssertFalse(draft.confirmed(altered, workspace: workspace, target: draft.target))
        XCTAssertTrue(draft.confirmed(original, workspace: workspace, target: draft.target))
    }
    func testPublicationRoundTripAndCaptionBounds() throws {
        var draft = try ready(); try draft.editCaption(String(repeating: "🪴", count: 1000))
        XCTAssertThrowsError(try draft.editCaption(String(repeating: "🪴", count: 1001)))
        XCTAssertThrowsError(try draft.editCaption("bad\0caption"))
        let intent = try draft.preparePublication(workspace: workspace, target: draft.target)
        let returned = try JSONDecoder().decode(AudioCommentPublication.self, from: JSONEncoder().encode(intent))
        XCTAssertTrue(intent.sameIntent(as: returned))
        var injected = intent.record; injected.fields["public_url"] = .string("https://invalid.example/audio")
        XCTAssertThrowsError(try AudioCommentPublication(record: injected))
    }
    func testLocalWorkspaceCanReviewButCannotInventCloudAccount() throws {
        let local = WorkspaceBinding(account: "local", generation: UUID()), target = try target()
        var draft = AudioCommentDraft(workspace: local, target: target)
        let token = try draft.begin(workspace: local, target: target); draft.started(token, workspace: local, target: target)
        XCTAssertTrue(draft.receive(try AudioCommentClip(data: fixture()), token: token, workspace: local, target: target))
        XCTAssertThrowsError(try draft.preparePublication(workspace: local, target: target))
        XCTAssertEqual(draft.phase, .review); XCTAssertNotNil(draft.clip)
    }
    func testNativeDecoderReadsTheEntireGeneratedClipWithoutPlayback() async throws {
        let clip = try await AudioCommentDecoding.validate(fixture())
        XCTAssertEqual(clip.descriptor.milliseconds, 1069)
    }
    func testNativeDecoderRejectsContainerWithDamagedAACPayload() async throws {
        var data = try fixture()
        let range = try XCTUnwrap(data.range(of: Data("mdat".utf8)))
        data.replaceSubrange(range.upperBound..<data.endIndex, with: Data(repeating: 0, count: data.endIndex - range.upperBound))
        // Structural admission cannot establish decodability of these sample bytes.
        XCTAssertNoThrow(try AudioCommentClip(data: data))
        do { _ = try await AudioCommentDecoding.validate(data); XCTFail("Damaged AAC must refuse") }
        catch { XCTAssertTrue(error is AudioCommentFailure) }
    }
    func testCancelledDecoderDoesNotDeliverReviewedClip() async throws {
        let data = try fixture()
        let task = Task { try await AudioCommentDecoding.validate(data) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled validation delivered audio") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPendingPublicationSurvivesRelaunchWithoutChangingIntentOrAudio() throws {
        var draft = try ready()
        try draft.editCaption("  cafe\u{301}\nKeep exact wording 🪴  ")
        let intent = try draft.preparePublication(workspace: workspace, target: draft.target)
        let pending = try AudioCommentPending(publication: intent, clip: XCTUnwrap(draft.clip))
        let data = try pending.encoded()
        let restored = try AudioCommentPending(encoded: data, account: intent.account)
        XCTAssertTrue(restored.publication.sameIntent(as: intent))
        XCTAssertEqual(restored.clip.data, draft.clip?.data)
        XCTAssertThrowsError(try AudioCommentPending(encoded: data, account: UUID()))
    }
    func testPendingPublicationRefusesChangedAudioOrDescriptor() throws {
        var draft = try ready()
        let intent = try draft.preparePublication(workspace: workspace, target: draft.target)
        let clip = try XCTUnwrap(draft.clip)
        let changed = try AudioCommentDescriptor(byteCount: clip.data.count, milliseconds: 1068, sha256: clip.descriptor.sha256)
        let altered = try AudioCommentPublication(account: intent.account, target: intent.target, caption: intent.caption, descriptor: changed)
        XCTAssertThrowsError(try AudioCommentPending(publication: altered, clip: clip))
        let pending = try AudioCommentPending(publication: intent, clip: clip)
        var fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: pending.encoded(), format: nil) as? [String: Any])
        var audio = clip.data
        // Free-space byte preserves audio/container validity while changing exact digest.
        let free = try XCTUnwrap(audio.range(of: Data("free".utf8)))
        audio[free.upperBound] ^= 1
        XCTAssertNoThrow(try AudioCommentClip(data: audio))
        fields["audio"] = audio
        let corrupted = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        XCTAssertThrowsError(try AudioCommentPending(encoded: corrupted, account: intent.account))
    }
    func testPendingEnvelopeRefusesUnexpectedFieldsAndOversizedInput() throws {
        var draft = try ready()
        let intent = try draft.preparePublication(workspace: workspace, target: draft.target)
        let pending = try AudioCommentPending(publication: intent, clip: XCTUnwrap(draft.clip))
        var fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: pending.encoded(), format: nil) as? [String: Any])
        fields["url"] = "https://invalid.example/audio"
        let data = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        XCTAssertThrowsError(try AudioCommentPending(encoded: data, account: intent.account))
        XCTAssertThrowsError(try AudioCommentPending(encoded: Data(repeating: 0, count: 8_100_001), account: intent.account))
    }

}
