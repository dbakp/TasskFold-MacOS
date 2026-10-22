import XCTest
@testable import TaskfoldCore

private final class CaptureProviderFixture: @unchecked Sendable {
    let provider = NSItemProvider()
    let started = XCTestExpectation(description: "Producer asked for data")
    private let lock = NSLock()
    private var callback: ((Data?,Error?) -> Void)?
    private var invoked = false
    var wasInvoked: Bool { lock.lock();defer{lock.unlock()};return invoked }
    init(type: String = "public.plain-text") {
        started.assertForOverFulfill = false
        provider.registerDataRepresentation(forTypeIdentifier:type,visibility:.all) { [self] completion in
            lock.lock();callback = completion;invoked = true;lock.unlock();started.fulfill()
            return nil
        }
    }
    func send(_ data: Data?, error: Error? = nil) {
        lock.lock();let completion = callback;callback = nil;lock.unlock();completion?(data,error)
    }
}

final class SharedCaptureProviderTests: XCTestCase {
    func testRealFoundationPlainTextRepresentationKeepsLiteralText() async throws {
        let fixture = CaptureProviderFixture()
        let read = Task {try await SharedCaptureProvider.read(fixture.provider,type:"public.plain-text",deadline:.now.advanced(by:.seconds(3)))}
        defer{read.cancel();fixture.send(nil)}
        await fulfillment(of:[fixture.started],timeout:2)
        fixture.send(Data("Plan tomorrow\nKeep #literal and https://example.com/ as words".utf8))
        let result = try await read.value
        XCTAssertEqual(try SharedCaptureItem.text(result),"Plan tomorrow\nKeep #literal and https://example.com/ as words")
    }
    func testRealFoundationWebURLRepresentationUsesExistingValidation() async throws {
        let fixture = CaptureProviderFixture(type:"public.url")
        let read = Task {try await SharedCaptureProvider.read(fixture.provider,type:"public.url",deadline:.now.advanced(by:.seconds(3)))}
        defer{read.cancel();fixture.send(nil)}
        await fulfillment(of:[fixture.started],timeout:2)
        fixture.send(Data("https://maps.apple.com/?q=Public%20sample".utf8))
        let result = try await read.value
        XCTAssertEqual(try SharedCaptureItem.webLink(result),"https://maps.apple.com/?q=Public%20sample")
    }
    func testMissingProducerResultBecomesUsefulFailureWithoutAValue() async throws {
        let fixture = CaptureProviderFixture()
        let read = Task {try await SharedCaptureProvider.read(fixture.provider,type:"public.plain-text",deadline:.now.advanced(by:.seconds(3)))}
        defer{read.cancel();fixture.send(nil)}
        await fulfillment(of:[fixture.started],timeout:2);fixture.send(nil)
        do{_ = try await read.value;XCTFail("Missing provider data became readable content")}catch{XCTAssertTrue(error is SharedCaptureFailure,error.localizedDescription)}
    }
    func testProducerFailureDoesNotExposeItsInternalErrorOrReturnPartialData() async throws {
        let fixture = CaptureProviderFixture()
        let read = Task {try await SharedCaptureProvider.read(fixture.provider,type:"public.plain-text",deadline:.now.advanced(by:.seconds(3)))}
        defer{read.cancel();fixture.send(nil)}
        await fulfillment(of:[fixture.started],timeout:2)
        fixture.send(nil,error:NSError(domain:"synthetic-provider-private-path",code:73))
        do{_ = try await read.value;XCTFail("Failed source returned content")}catch{XCTAssertFalse(error.localizedDescription.contains("synthetic-provider-private-path"));XCTAssertTrue(error.localizedDescription.contains("source app"))}
    }
    @MainActor func testCancellationBeforeStartingDoesNotAskTheProducer() async throws {
        let fixture = CaptureProviderFixture()
        let read = Task {try await SharedCaptureProvider.read(fixture.provider,type:"public.plain-text",deadline:.now.advanced(by:.seconds(3)))}
        read.cancel()
        do{_ = try await read.value;XCTFail("Cancelled intake returned content")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertFalse(fixture.wasInvoked)
    }
    func testCancellationWhileWaitingAndLateProducerReplyResumeOnlyOnce() async throws {
        let fixture = CaptureProviderFixture()
        let read = Task {try await SharedCaptureProvider.read(fixture.provider,type:"public.plain-text",deadline:.now.advanced(by:.seconds(3)))}
        defer{read.cancel();fixture.send(nil)}
        await fulfillment(of:[fixture.started],timeout:2);read.cancel()
        do{_ = try await read.value;XCTFail("Dismissed intake returned content")}catch{XCTAssertTrue(error is CancellationError)}
        fixture.send(Data("Too late to change the dismissed review".utf8))
        await Task.yield() // The real Foundation callback must be safe after cancellation.
    }
    func testDeadlineStopsSilentProducerAndIgnoresItsLateSuccess() async throws {
        let fixture = CaptureProviderFixture()
        let read = Task {try await SharedCaptureProvider.read(fixture.provider,type:"public.plain-text",deadline:.now.advanced(by:.milliseconds(150)))}
        defer{read.cancel();fixture.send(nil)}
        await fulfillment(of:[fixture.started],timeout:2)
        do{_ = try await read.value;XCTFail("Silent producer did not time out")}catch{XCTAssertTrue(error.localizedDescription.contains("took too long"),error.localizedDescription)}
        fixture.send(Data("Late result".utf8));await Task.yield()
    }
    func testExpiredSharedDeadlineDoesNotStartTheNextAttachment() async throws {
        let first = CaptureProviderFixture(),second = CaptureProviderFixture()
        let deadline = ContinuousClock.now.advanced(by:.milliseconds(150))
        let read = Task {try await SharedCaptureProvider.read(first.provider,type:"public.plain-text",deadline:deadline)}
        defer{read.cancel();first.send(nil);second.send(nil)}
        await fulfillment(of:[first.started],timeout:2);first.send(Data("First item".utf8))
        _ = try await read.value
        try await Task.sleep(until:deadline,clock:.continuous)
        do{_ = try await SharedCaptureProvider.read(second.provider,type:"public.plain-text",deadline:deadline);XCTFail("A new attachment restarted the intake deadline")}catch{XCTAssertTrue(error.localizedDescription.contains("took too long"))}
        XCTAssertFalse(second.wasInvoked)
    }
    func testParallelIntakesKeepTheirResultsSeparateWhenOneTimesOut() async throws {
        let slow = CaptureProviderFixture(),fresh = CaptureProviderFixture()
        let first = Task {try await SharedCaptureProvider.read(slow.provider,type:"public.plain-text",deadline:.now.advanced(by:.milliseconds(150)))}
        let second = Task {try await SharedCaptureProvider.read(fresh.provider,type:"public.plain-text",deadline:.now.advanced(by:.seconds(3)))}
        defer{first.cancel();second.cancel();slow.send(nil);fresh.send(nil)}
        await fulfillment(of:[slow.started,fresh.started],timeout:2);fresh.send(Data("Fresh review".utf8))
        let result = try await second.value
        XCTAssertEqual(try SharedCaptureItem.text(result),"Fresh review")
        do{_ = try await first.value;XCTFail("Slow producer did not stop")}catch{}
        slow.send(Data("Old review".utf8));await Task.yield()
    }
}

final class SharedCaptureIntakeTests: XCTestCase {
    func item(_ providers: [NSItemProvider], text: String? = nil, title: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem();item.attachments = providers
        item.attributedContentText = text.map(NSAttributedString.init(string:));item.attributedTitle = title.map(NSAttributedString.init(string:));return item
    }
    func testObservedMapsFormatsKeepRealTextAndLinkWithoutLoadingMapObject() async throws {
        let map = CaptureProviderFixture(type:"com.apple.mapkit.map-item"),url = CaptureProviderFixture(type:"public.url"),text = CaptureProviderFixture()
        let selection = item([map.provider,url.provider,text.provider],title:"Public place title")
        let read = Task {try await SharedCaptureIntake.read([selection],deadline:.now.advanced(by:.seconds(3)))}
        defer{read.cancel();url.send(nil);text.send(nil)}
        await fulfillment(of:[url.started],timeout:2);url.send(Data("https://maps.apple.com/?q=Public%20sample".utf8))
        await fulfillment(of:[text.started],timeout:2);text.send(Data("Original place words\nLiteral #label and tomorrow stay words".utf8))
        let result = try await read.value
        XCTAssertTrue(result.omittedMapPreview);XCTAssertFalse(map.wasInvoked)
        XCTAssertEqual(result.content.source,"https://maps.apple.com/?q=Public%20sample")
        XCTAssertEqual(result.content.title,"Public place title")
        XCTAssertEqual(result.content.notes,"Original place words\nLiteral #label and tomorrow stay words")
    }
    func testMapObjectAloneDoesNotBecomeAGuessedTaskOrSourceLink() async throws {
        let map = CaptureProviderFixture(type:"com.apple.mapkit.map-item")
        do{_ = try await SharedCaptureIntake.read([item([map.provider],title:"Not sufficient content")]);XCTFail("Opaque map object became a task")}catch{XCTAssertTrue(error.localizedDescription.contains("web link"))}
        XCTAssertFalse(map.wasInvoked)
    }
    func testUnknownAttachmentWithReadableURLRefusesTheWholeSelection() async throws {
        let url = CaptureProviderFixture(type:"public.url"),pdf = CaptureProviderFixture(type:"com.adobe.pdf")
        let read = Task{try await SharedCaptureIntake.read([self.item([url.provider,pdf.provider])])}
        defer{read.cancel();url.send(nil)}
        await fulfillment(of:[url.started],timeout:2);url.send(Data("https://example.com/".utf8))
        do{_ = try await read.value;XCTFail("Unknown attachment was silently dropped")}catch{XCTAssertTrue(error.localizedDescription.contains("instead of a file"))}
        XCTAssertFalse(pdf.wasInvoked)
    }
    func testMapIdentifierCannotHideAnAdditionalUnknownRepresentation() async throws {
        let map = CaptureProviderFixture(type:"com.apple.mapkit.map-item")
        let neverLoaded = XCTestExpectation(description:"Unknown mixed provider must stay unread");neverLoaded.isInverted = true
        map.provider.registerDataRepresentation(forTypeIdentifier:"com.adobe.pdf",visibility:.all){completion in neverLoaded.fulfill();completion(Data("%PDF".utf8),nil);return nil}
        do{_ = try await SharedCaptureIntake.read([item([map.provider])]);XCTFail("Mixed opaque representation bypassed refusal")}catch{}
        XCTAssertFalse(map.wasInvoked)
    }
    func testSharedIntakeDeadlineDoesNotProducePartialContentAfterFirstAttachment() async throws {
        let url = CaptureProviderFixture(type:"public.url"),text = CaptureProviderFixture()
        let read = Task{try await SharedCaptureIntake.read([self.item([url.provider,text.provider])],deadline:.now.advanced(by:.milliseconds(150)))}
        defer{read.cancel();url.send(nil);text.send(nil)}
        await fulfillment(of:[url.started],timeout:2);url.send(Data("https://example.com/".utf8))
        await fulfillment(of:[text.started],timeout:2)
        do{_ = try await read.value;XCTFail("A partial URL capture escaped its silent second item")}catch{XCTAssertTrue(error.localizedDescription.contains("took too long"))}
        text.send(Data("Too late".utf8));await Task.yield()
    }
    func testItemAndAttachmentLimitsRefuseBeforeStartingExcessProviders() async throws {
        let map = CaptureProviderFixture(type:"com.apple.mapkit.map-item"),url = CaptureProviderFixture(type:"public.url")
        do{_ = try await SharedCaptureIntake.read(Array(repeating:item([]),count:5));XCTFail("Too many items accepted")}catch{}
        do{_ = try await SharedCaptureIntake.read([item(Array(repeating:map.provider,count:8)+[url.provider])]);XCTFail("Too many attachments accepted")}catch{}
        XCTAssertFalse(map.wasInvoked);XCTAssertFalse(url.wasInvoked)
    }
    func testAttributedTextAggregateIncludesSeparatorsAndNeverTruncates() async throws {
        let a=String(repeating:"A",count:50_000),b=String(repeating:"B",count:50_000)
        let first=item([],text:a),second=item([],text:b)
        do{_ = try await SharedCaptureIntake.read([first,second]);XCTFail("Joined text exceeded the byte budget")}catch{}
        XCTAssertEqual(first.attributedContentText?.string,a);XCTAssertEqual(second.attributedContentText?.string,b)
    }
    func testFileURLStillRefusesCaptureWithoutOpeningIt() async throws {
        let file = CaptureProviderFixture(type:"public.url")
        let read=Task{try await SharedCaptureIntake.read([self.item([file.provider])])}
        defer{read.cancel();file.send(nil)}
        await fulfillment(of:[file.started],timeout:2);file.send(Data("file:///private/not-a-readable-source.txt".utf8))
        do{_ = try await read.value;XCTFail("Local file URL became a source link")}catch{XCTAssertTrue(error.localizedDescription.contains("http"))}
    }
}
