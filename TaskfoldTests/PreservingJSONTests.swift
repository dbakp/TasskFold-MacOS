import XCTest
import CryptoKit
@testable import TaskfoldCore

final class PreservingJSONTests: XCTestCase {
    private let owner = "cc170000-0000-4000-8000-000000000001"
    private let task = "cc170000-0000-4000-8000-000000000002"
    private let generation = "cc170000-0000-4000-8000-000000000003"
    private func decode(_ text: String) throws -> JSON { try TaskfoldJSONDecoder().decode(JSON.self, from: Data(text.utf8)) }
    private func encode(_ value: JSON) throws -> Data { try TaskfoldJSONEncoder().encode(value) }
    private func record() throws -> Record {
        let raw = "{\"id\":\"\(task)\",\"user_id\":\"\(owner)\",\"task_generation\":\"\(generation)\",\"title\":\"Original title\",\"completed\":false,\"completion_version\":0,\"priority\":4,\"source_metadata\":{\"exact\":9007199254740993,\"large\":1e1000,\"small\":1e-1000,\"keys\":{\"é\":1,\"e\\u0301\":2}},\"subtasks\":[{\"id\":\"child\",\"title\":\"Keep child\",\"opaque\":1e1000}]}"
        return try TaskfoldJSONDecoder().decode(Record.self, from: Data(raw.utf8))
    }
    func testUnsafeNumbersRemainUnquotedExactJSON() throws {
        for token in ["9007199254740993","-9007199254740993","1e1000","1E+1000","1e-1000","1e100","123456789012345678901234567890.123456789","0e99999999999999999999999"] {
            let value = try decode(token); guard case .preserved(let original) = value else { return XCTFail(token) }
            XCTAssertEqual(original.kind,.number); XCTAssertEqual(try encode(value),Data(token.utf8))
            XCTAssertEqual(try TaskfoldJSONDecoder().decode(JSON.self,from:encode(value)),value)
        }
    }
    func testOrdinaryNumbersRetainExistingProjection() throws {
        for token in ["0","-0","1.5","0.1","1e2","4.000","9007199254740991"] {
            guard case .number = try decode(token) else { return XCTFail(token) }
        }
        XCTAssertEqual(JSON.number(Double.infinity).integer,0);XCTAssertEqual(JSON.number(Double.nan).integer,0)
        XCTAssertEqual(JSON.number(Double(Int.max)).integer,0);XCTAssertEqual(JSON.number(1.9).integer,1)
    }
    func testDistinctUnicodeKeysRemainCompleteAndByteExact() throws {
        for raw in [#"{"é":1,"e\u0301":2}"#,#"{"\u00e9":1e1000,"é":9007199254740993,"note":"café 🪴"}"#] {
            let value=try decode(raw);guard case .preserved(let preserved)=value else{return XCTFail(raw)}
            XCTAssertEqual(preserved.kind,.object);XCTAssertEqual(try encode(value),Data(raw.utf8))
        }
    }
    func testKnownRootFieldsRemainEditableBesideOpaqueFutureValues() throws {
        let original=try record();var edited=original;edited["title"] = .string("Edited title")
        let data=try TaskfoldJSONEncoder().encode(edited),returned=try TaskfoldJSONDecoder().decode(Record.self,from:data)
        XCTAssertEqual(returned.title,"Edited title");XCTAssertEqual(returned["source_metadata"],original["source_metadata"]);XCTAssertEqual(returned["subtasks"],original["subtasks"])
        let text=String(decoding:data,as:UTF8.self);XCTAssertTrue(text.contains("9007199254740993"));XCTAssertTrue(text.contains("1e1000"));XCTAssertFalse(text.contains("taskfold-preserved-json-"))
    }
    func testSnapshotAndPendingIntentSurviveColdFileRoundTrip() throws {
        let original=try record();var edited=original;edited["title"] = .string("Local edit")
        var snapshot=Snapshot();snapshot.tables["tasks"]=[edited]
        snapshot.pending=[Mutation(table:"tasks",recordID:task,method:"PATCH",fields:["title":.string("Local edit")],baseline:original.fields)]
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-exact-cache-"+UUID().uuidString+".json");defer{try? FileManager.default.removeItem(at:file)}
        try TaskfoldJSONEncoder().encode(snapshot).write(to:file,options:.atomic)
        let cold=try TaskfoldJSONDecoder().decode(Snapshot.self,from:Data(contentsOf:file))
        XCTAssertEqual(cold,snapshot);XCTAssertEqual(cold.pending.first?.baseline?["source_metadata"],original["source_metadata"])
        XCTAssertEqual(cold.tables["tasks"]?.first?["source_metadata"],original["source_metadata"])
    }
    func testPortableBackupPreservesOpaqueValuesAndOmitsExecutableQueue() throws {
        let original=try record();var snapshot=Snapshot();snapshot.tables["tasks"]=[original];snapshot.pending=[Mutation(table:"tasks",recordID:task,method:"PATCH",fields:["title":.string("Pending")])]
        let backup=WorkspaceBackup.make(snapshot,account:owner);try backup.validate()
        let data=try backup.data(),cold=try WorkspaceBackup.read(data)
        XCTAssertEqual(cold.tables["tasks"]?.first?["source_metadata"],original["source_metadata"]);XCTAssertEqual(cold.unsyncedChanges,1)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("taskfold-preserved-json-"))
    }
    func testActualEncryptedRecoveryRetainsOriginalAndQueue() throws {
        let original=try record();var snapshot=Snapshot();snapshot.tables["tasks"]=[original];snapshot.pending=[Mutation(table:"tasks",recordID:task,method:"PATCH",fields:["description":.string("Queued notes")],baseline:original.fields)]
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-exact-vault-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(size:.bits256),vault=BackupVault(directory:directory,account:owner,key:{key})
        let entry=try vault.save(snapshot,kind:"Exact cache proof")
        let reopened=BackupVault(directory:directory,account:owner,key:{key});XCTAssertEqual(try reopened.load(entry).snapshot,snapshot)
        XCTAssertFalse(String(decoding:try Data(contentsOf:vault.file(entry)),as:UTF8.self).contains("Original title"))
    }
    func testFoundationWriterRefusesOpaqueValuesInsteadOfAlteringThem() throws {
        let value=try decode("1e1000");XCTAssertThrowsError(try Foundation.JSONEncoder().encode(value))
    }
    func testAmbiguousRecordAndTypedJSONMetadataAreRefused() throws {
        let data=Data(#"{"id":"safe","é":1,"e\u0301":2}"#.utf8)
        XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(Record.self,from:data))
        XCTAssertThrowsError(try TaskfoldJSONDecoder().decode([String:JSON].self,from:data))
        XCTAssertEqual(try encode(TaskfoldJSONDecoder().decode(JSON.self,from:data)),data)
    }
    func testTypedInspectionCanIgnoreOpaqueOriginalContent() throws {
        struct Header:Decodable {let id:String}
        let data=Data(#"{"id":"safe","future":{"é":1e1000,"e\u0301":2}}"#.utf8)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Header.self,from:data).id,"safe")
    }
    func testTypedLargeUnsignedCountersDoNotPassThroughDouble() throws {
        struct Counter:Codable,Equatable {let generation:UInt64}
        let data=Data(#"{"generation":18446744073709551615}"#.utf8)
        let value=try TaskfoldJSONDecoder().decode(Counter.self,from:data);XCTAssertEqual(value.generation,UInt64.max)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Counter.self,from:TaskfoldJSONEncoder().encode(value)),value)
    }
    func testMalformedOrAmbiguousSyntaxIsNotAcceptedAsOpaque() throws {
        for text in [#"{"a":1,"a":2}"#,#"{"a":1,"\u0061":2}"#,"[01]","[1e]","[1,]",#"{"é":1,"e\u0301":"\uD800"}"#,"true false","NaN","+1"] {XCTAssertThrowsError(try decode(text),text)}
        XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(JSON.self,from:Data([34,0xC0,0x80,34])))
    }
    func testUserStringsThatResembleMarkersAreOrdinaryData() throws {
        let source=try decode("1e1000"),text="taskfold-preserved-json-not-a-real-marker"
        let value=JSON.object(["future":source,"text":.string(text),text:.string("key remains")])
        let returned=try TaskfoldJSONDecoder().decode(JSON.self,from:encode(value));XCTAssertEqual(returned,value)
    }
    func testAnActualPlaceholderCollisionRefusesAllOutput() throws {
        struct Collision:Encodable {
            let value:JSON
            enum Keys:String,CodingKey {case future,authored}
            func encode(to encoder:Encoder)throws{
                var c=encoder.container(keyedBy:Keys.self);try c.encode(value,forKey:.future)
                let context=encoder.userInfo[PreservedJSONEncodingContext.key] as! PreservedJSONEncodingContext
                try c.encode(context.parts.keys.first!,forKey:.authored)
            }
        }
        XCTAssertThrowsError(try TaskfoldJSONEncoder().encode(Collision(value:decode("1e1000"))))
    }
    func testDateDataFormattingMatchFoundationForOrdinaryValues() throws {
        struct Value:Codable,Equatable {let date:Date;let bytes:Data;let name:String}
        let value=Value(date:Date(timeIntervalSince1970:1234),bytes:Data([0,1,255]),name:"café 🪴")
        let standard=Foundation.JSONEncoder(),preserving=TaskfoldJSONEncoder();standard.dateEncodingStrategy = .iso8601;preserving.dateEncodingStrategy = .iso8601;standard.outputFormatting = [.sortedKeys,.prettyPrinted];preserving.outputFormatting = [.sortedKeys,.prettyPrinted]
        XCTAssertEqual(try preserving.encode(value),try standard.encode(value))
        let decoder=TaskfoldJSONDecoder();decoder.dateDecodingStrategy = .iso8601;XCTAssertEqual(try decoder.decode(Value.self,from:preserving.encode(value)),value)
    }
    func testUnsupportedKeyConversionCannotHideOpaqueValues() throws {
        struct Value:Decodable{let futureValue:JSON}
        let decoder=TaskfoldJSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertThrowsError(try decoder.decode(Value.self,from:Data(#"{"future_value":9007199254740993}"#.utf8)))
    }
    func testSharedEncoderAndDecoderUseIndependentPerCallContexts() async throws {
        let encoder=TaskfoldJSONEncoder(),decoder=TaskfoldJSONDecoder(),value=try record()
        try await withThrowingTaskGroup(of:Record.self){group in
            for _ in 0..<24{group.addTask{try decoder.decode(Record.self,from:encoder.encode(value))}}
            for try await result in group{XCTAssertEqual(result,value)}
        }
    }
    func testPreservedValuesDoNotBypassBackupDepthOrCollectionLimits() throws {
        var entries=["\"é\":1","\"e\\u0301\":2"];entries += (0..<1000).map{"\"key\($0)\":true"}
        let value=try decode("{"+entries.joined(separator:",")+"}");guard case .preserved(let preserved)=value else{return XCTFail()}
        XCTAssertThrowsError(try preserved.validate(maximumDepth:32,maximumObject:1000))
        XCTAssertThrowsError(try preserved.validate(maximumDepth:0));XCTAssertThrowsError(try preserved.validate(maximumDepth:32,maximumValues:5))
    }
    func testHugeExponentBodySizingNeverTrapsOrCertifiesTinyRequests() throws {
        for token in ["1e9223372036854775807","1e-9223372036854775808","1e9223372036854775808"] {
            let value=try decode(token),change=Mutation(table:"tasks",recordID:task,method:"POST",fields:["future":value])
            XCTAssertFalse(WorkflowUndo.fitsBody(change))
        }
        let value=try decode("1e4000000000000000000"),change=Mutation(table:"tasks",recordID:task,method:"POST",fields:["future":.array([value,value,value])]);XCTAssertFalse(WorkflowUndo.fitsBody(change))
    }
    func testOrdinaryLegacyCacheStillDecodesWithoutMigrationTags() throws {
        let data=Data(#"{"tables":{"tasks":[{"id":"one","title":"Legacy task","completed":false}]},"pending":[],"widgetCompletion":{"states":{},"receipts":{},"receiptOrder":[]}}"#.utf8)
        let old=try Foundation.JSONDecoder().decode(Snapshot.self,from:data),new=try TaskfoldJSONDecoder().decode(Snapshot.self,from:data);XCTAssertEqual(new,old)
    }
    func testDataSlicesRetainExactOpaqueByteRanges() throws {
        let bytes=Data("prefix1e1000suffix".utf8),slice=bytes[6..<12]
        XCTAssertEqual(try encode(TaskfoldJSONDecoder().decode(JSON.self,from:slice)),Data("1e1000".utf8))
    }
    func testExistingUTFEncodingsAndBOMKeepExactJSONValues() throws {
        let text = #"{"large":1e1000,"keys":{"é":1,"e\u0301":2}}"#
        let expected = try decode(text)
        for encoding in [String.Encoding.utf8,.utf16LittleEndian,.utf16BigEndian,.utf32LittleEndian,.utf32BigEndian] {
            for scalar in ["1","null",#""🪴""#] { let scalarBytes = try XCTUnwrap(scalar.data(using: encoding)); XCTAssertEqual(try TaskfoldJSONDecoder().decode(JSON.self, from: scalarBytes),try decode(scalar)) }
            let bytes=try XCTUnwrap(text.data(using:encoding))
            XCTAssertEqual(try TaskfoldJSONDecoder().decode(JSON.self,from:bytes),expected)
            let bom:Data
            switch encoding { case .utf8:bom=Data([0xEF,0xBB,0xBF]);case .utf16LittleEndian:bom=Data([0xFF,0xFE]);case .utf16BigEndian:bom=Data([0xFE,0xFF]);case .utf32LittleEndian:bom=Data([0xFF,0xFE,0,0]);default:bom=Data([0,0,0xFE,0xFF]) }
            XCTAssertEqual(try TaskfoldJSONDecoder().decode(JSON.self,from:bom+bytes),expected)
        }
    }

}
