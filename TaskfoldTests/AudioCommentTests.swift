import XCTest
import CryptoKit
import AVFoundation
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
        XCTAssertEqual(clip.descriptor.milliseconds, 1000)
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
        let changed = try AudioCommentDescriptor(byteCount: clip.data.count, milliseconds: 1068, sha256: String(repeating: "0", count: 64))
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

    func testNativeTwoMinuteBoundaryAllowsAACPaddingButRejectsLongerPresentation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-audio-limit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)); buffer.frameLength = 44100
        for index in 0..<44100 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.04) }
        for extraFrames in [0, 4410] {
            buffer.frameLength = 44100
            let url = folder.appendingPathComponent("limit-\(extraFrames).m4a")
            do {
                let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
                for _ in 0..<120 { try file.write(from: buffer) }
                if extraFrames > 0 { buffer.frameLength = AVAudioFrameCount(extraFrames); try file.write(from: buffer) }
            }
            let data = try Data(contentsOf: url)
            if extraFrames == 0 {
                XCTAssertGreaterThan(try AudioCommentClip.encodedMilliseconds(in: data), 120000)
                let clip = try await AudioCommentDecoding.validate(data)
                XCTAssertEqual(clip.descriptor.milliseconds, 120000)
                let restored = try AudioCommentClip(restoring: data, descriptor: clip.descriptor)
                XCTAssertEqual(restored.descriptor, clip.descriptor)
                XCTAssertEqual(restored.data, data)
            } else {
                XCTAssertLessThan(try AudioCommentClip.encodedMilliseconds(in: data), 121000)
                do { _ = try await AudioCommentDecoding.validate(data); XCTFail("Overlong audio admitted") }
                catch { XCTAssertTrue(error is AudioCommentFailure) }
            }
        }
    }

    func testRestoreIsScopeBoundAndCloseRemovesPrivateMediaAndCaption() throws {
        var draft = try ready()
        let clip = try XCTUnwrap(draft.clip)
        XCTAssertThrowsError(try draft.restore(clip, caption: "Wrong", workspace: WorkspaceBinding(account: workspace.account, generation: UUID()), target: draft.target))
        XCTAssertThrowsError(try AudioCommentClip(decoded: fixture(), milliseconds: Int.min))
        XCTAssertThrowsError(try AudioCommentClip(decoded: fixture(), milliseconds: Int.max))
        try draft.restore(clip, caption: "Private caption", workspace: workspace, target: draft.target)
        draft.close()
        XCTAssertNil(draft.clip); XCTAssertTrue(draft.caption.isEmpty); XCTAssertNil(draft.publication)
        XCTAssertThrowsError(try draft.restore(clip, caption: "Late", workspace: workspace, target: draft.target))
    }

}

extension AudioCommentTests {
    func testPortableRecordingKeepsExactCaptionAndAudioWithoutSourceIdentity() throws {
        let clip = try AudioCommentClip(data: fixture()), caption = "Keep cafe\u{301} 🪴\nhttps://example.invalid/a?b=c\nLiteral /private/path"
        let value = try AudioCommentPortableRecording(caption: caption, clip: clip), bytes = try value.encoded()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "caption", "descriptor", "audio_base64"])
        let restored = try AudioCommentPortableRecording(encoded: bytes)
        XCTAssertTrue(restored.caption.utf8.elementsEqual(caption.utf8))
        XCTAssertEqual(restored.clip.data, clip.data); XCTAssertEqual(restored.clip.descriptor, clip.descriptor)
        XCTAssertEqual(try restored.encoded(), bytes)
    }
    func testPortableRecordingRejectsForeignFormatsExtraFieldsAndWrongTypes() throws {
        let clip = try AudioCommentClip(data: fixture())
        let bytes = try AudioCommentPortableRecording(caption: "Original", clip: clip).encoded()
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (key, value) in [("format", "taskfold-workspace-v1" as Any), ("account", "other-owner" as Any), ("caption", 12 as Any), ("descriptor", "https://example.invalid/audio" as Any), ("audio_base64", ["url":"file:///private/audio.m4a"] as Any)] {
            var changed = root; changed[key] = value
            XCTAssertThrowsError(try AudioCommentPortableRecording(encoded: JSONSerialization.data(withJSONObject: changed)), key)
        }
        for key in root.keys {
            var changed = root; changed.removeValue(forKey: key)
            XCTAssertThrowsError(try AudioCommentPortableRecording(encoded: JSONSerialization.data(withJSONObject: changed)), key)
        }
    }
    func testPortableRecordingRejectsMalformedBase64DigestMismatchAndTruncatedAudio() throws {
        let clip = try AudioCommentClip(data: fixture())
        let bytes = try AudioCommentPortableRecording(caption: "Original", clip: clip).encoded()
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for audio in ["%%%", "", Data(clip.data.dropLast(8)).base64EncodedString()] {
            var changed = root; changed["audio_base64"] = audio
            XCTAssertThrowsError(try AudioCommentPortableRecording(encoded: JSONSerialization.data(withJSONObject: changed)))
        }
        var changed = root, descriptor = try XCTUnwrap(root["descriptor"] as? [String: Any])
        descriptor["sha256"] = String(repeating: "0", count: 64); changed["descriptor"] = descriptor
        XCTAssertThrowsError(try AudioCommentPortableRecording(encoded: JSONSerialization.data(withJSONObject: changed)))
    }
    func testPortableRecordingBoundsFileAndCaptionBeforeAdmission() throws {
        let clip = try AudioCommentClip(data: fixture())
        XCTAssertThrowsError(try AudioCommentPortableRecording(caption: String(repeating: "a", count: 4001), clip: clip))
        XCTAssertThrowsError(try AudioCommentPortableRecording(caption: "Hidden\0suffix", clip: clip))
        XCTAssertThrowsError(try AudioCommentPortableRecording(encoded: Data()))
        XCTAssertThrowsError(try AudioCommentPortableRecording(encoded: Data(repeating: 32, count: AudioCommentPortableRecording.maximumFileBytes + 1)))
        let escaped = String(repeating: "\u{0001}", count: 4000)
        let portable = try AudioCommentPortableRecording(caption: escaped, clip: clip)
        XCTAssertTrue(try AudioCommentPortableRecording(encoded: portable.encoded()).caption.utf8.elementsEqual(escaped.utf8))
    }

    func testPortableRecordingAcceptsMaximumClipAndEscapedCaptionWithinFileBudget() throws {
        var data = try fixture()
        let padding = AudioCommentDescriptor.maximumBytes - data.count, length = UInt32(padding)
        XCTAssertGreaterThan(padding, 8)
        data.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        data.append(Data("free".utf8)); data.append(Data(repeating: 255, count: padding - 8))
        let clip = try AudioCommentClip(data: data), caption = String(repeating: "\u{0001}", count: 4000)
        let portable = try AudioCommentPortableRecording(caption: caption, clip: clip), encoded = try portable.encoded()
        XCTAssertEqual(data.count, AudioCommentDescriptor.maximumBytes)
        XCTAssertLessThanOrEqual(encoded.count, AudioCommentPortableRecording.maximumFileBytes)
        let decoded = try AudioCommentPortableRecording(encoded: encoded)
        XCTAssertEqual(decoded.clip.data, data); XCTAssertEqual(decoded.clip.descriptor, clip.descriptor)
        XCTAssertTrue(decoded.caption.utf8.elementsEqual(caption.utf8))
    }
    func testPortableRecordingDoesNotNormalizeCanonicallyEquivalentCaptions() throws {
        let clip = try AudioCommentClip(data: fixture())
        let a = try AudioCommentPortableRecording(caption: "café", clip: clip), b = try AudioCommentPortableRecording(caption: "cafe\u{301}", clip: clip)
        XCTAssertNotEqual(try a.encoded(), try b.encoded())
        XCTAssertTrue(try AudioCommentPortableRecording(encoded: b.encoded()).caption.utf8.elementsEqual(b.caption.utf8))
    }
}
