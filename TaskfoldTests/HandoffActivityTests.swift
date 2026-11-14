import XCTest
@testable import TaskfoldCore

final class HandoffActivityTests: XCTestCase {
    private let task = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let project = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testActivityTypeIsTheSharedConstant() {
        XCTAssertEqual(HandoffActivity.activityType, "com.dbakp.taskfold.continue")
    }

    func testEveryDestinationRoundTrips() throws {
        for destination in [HandoffActivity.Destination.task(task), .project(project), .today, .calendar] {
            let made = try XCTUnwrap(HandoffActivity.make(destination, account: "acct-1"))
            let parsed = try HandoffActivity.parse(made.userInfo).get()
            XCTAssertEqual(parsed, made)
            XCTAssertEqual(parsed.destination, destination)
        }
    }

    func testPayloadCarriesIDsOnlyNeverContent() throws {
        let info = HandoffActivity(destination: .task(task), account: "acct-1").userInfo
        XCTAssertEqual(Set(info.keys), ["v", "k", "id", "a"])
        XCTAssertEqual(Set(HandoffActivity(destination: .today, account: "acct-1").userInfo.keys), ["v", "k", "a"])
        // A title riding along is refused, so a future caller cannot leak content through this type.
        var leaking = info; leaking["title"] = "Quarterly numbers"
        XCTAssertEqual(HandoffActivity.parse(leaking), .failure(.unexpectedField))
        var named = info; named["name"] = "Secret project"
        XCTAssertEqual(HandoffActivity.parse(named), .failure(.unexpectedField))
    }

    func testApplyMarksHandoffOnlyAndRequiresTheKeys() {
        let activity = NSUserActivity(activityType: HandoffActivity.activityType)
        HandoffActivity(destination: .project(project), account: "acct-1").apply(to: activity)
        XCTAssertTrue(activity.isEligibleForHandoff)
        XCTAssertFalse(activity.isEligibleForSearch)
        XCTAssertFalse(activity.isEligibleForPublicIndexing)
        XCTAssertEqual(activity.requiredUserInfoKeys, ["v", "k", "id", "a"])
        XCTAssertNil(activity.title)
        XCTAssertNil(activity.webpageURL)
        XCTAssertEqual(HandoffActivity.parse(activity.userInfo), .success(.init(destination: .project(project), account: "acct-1")))
    }

    func testRejectsMissingAndMalformedFields() {
        XCTAssertEqual(HandoffActivity.parse(nil), .failure(.malformed))
        XCTAssertEqual(HandoffActivity.parse([:]), .failure(.malformed))
        XCTAssertEqual(HandoffActivity.parse(["k": "today", "a": "x"]), .failure(.malformed))                       // no version
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "a": "x"]), .failure(.malformed))                             // no kind
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "today"]), .failure(.missingAccount))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "today", "a": ""]), .failure(.missingAccount))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "task", "a": "x"]), .failure(.missingID))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "project", "a": "x", "id": ""]), .failure(.missingID))
        XCTAssertEqual(HandoffActivity.parse(["v": "1", "k": "today", "a": "x"]), .failure(.malformed))             // wrong type
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": 7, "a": "x"]), .failure(.malformed))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "task", "a": "x", "id": 5]), .failure(.invalidID))
        XCTAssertEqual(HandoffActivity.parse([1: "x"]), .failure(.malformed))
    }

    func testRejectsUnknownVersionKindAndUnexpectedID() {
        XCTAssertEqual(HandoffActivity.parse(["v": 2, "k": "today", "a": "x"]), .failure(.unsupportedVersion))
        XCTAssertEqual(HandoffActivity.parse(["v": 0, "k": "today", "a": "x"]), .failure(.unsupportedVersion))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "settings", "a": "x"]), .failure(.unknownDestination))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "Task", "a": "x", "id": task]), .failure(.unknownDestination))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "today", "a": "x", "id": task]), .failure(.unexpectedID))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "calendar", "a": "x", "id": task]), .failure(.unexpectedID))
    }

    func testRejectsHostileIDsAndAccounts() {
        for id in ["../../etc", "a b", "id?x=1", "id/other", "taskfold://task/1", "é", "x\u{0}y", String(repeating: "a", count: 65), "a\nb", "%2e%2e"] {
            XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "task", "a": "x", "id": id]), .failure(.invalidID), id)
        }
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "today", "a": String(repeating: "a", count: 201)]), .failure(.invalidAccount))
        XCTAssertEqual(HandoffActivity.parse(["v": 1, "k": "today", "a": "x\ny"]), .failure(.invalidAccount))
        XCTAssertNil(HandoffActivity.make(.task("not an id"), account: "x"))
        XCTAssertNil(HandoffActivity.make(.today, account: ""))
        XCTAssertNotNil(HandoffActivity.make(.task(String(repeating: "a", count: 64)), account: "x"))
    }

    func testResolveOpensOnlyWhatThisWorkspaceHas() {
        func resolve(_ destination: HandoffActivity.Destination, account: String = "acct-1", current: String = "acct-1", signedIn: Bool = true,
                     tasks: Set<String> = [], projects: Set<String> = []) -> Result<HandoffActivity.Destination, HandoffActivity.Failure> {
            HandoffActivity.resolve(HandoffActivity(destination: destination, account: account).userInfo, account: current, signedIn: signedIn,
                                    hasTask: { tasks.contains($0) }, hasProject: { projects.contains($0) })
        }
        XCTAssertEqual(resolve(.task(task), tasks: [task]), .success(.task(task)))
        XCTAssertEqual(resolve(.project(project), projects: [project]), .success(.project(project)))
        XCTAssertEqual(resolve(.today), .success(.today))
        XCTAssertEqual(resolve(.calendar), .success(.calendar))
        // Unknown, deleted or not-shared ids fail without throwing or opening something else.
        XCTAssertEqual(resolve(.task(task)), .failure(.unavailable))
        XCTAssertEqual(resolve(.task(task), tasks: [project]), .failure(.unavailable))
        XCTAssertEqual(resolve(.project(project), tasks: [project]), .failure(.unavailable))
        // Another account, or nobody signed in, never reaches the lookup.
        XCTAssertEqual(resolve(.task(task), account: "acct-2", tasks: [task]), .failure(.otherWorkspace))
        XCTAssertEqual(resolve(.today, account: "acct-2"), .failure(.otherWorkspace))
        XCTAssertEqual(resolve(.task(task), signedIn: false, tasks: [task]), .failure(.signedOut))
        XCTAssertEqual(resolve(.today, current: ""), .failure(.signedOut))
    }

    func testResolveTurnsUntrustedInputIntoAMessageNotACrash() {
        let none: (String) -> Bool = { _ in true }
        let hostile: [[AnyHashable: Any]?] = [nil, [:], ["v": 1], ["v": 9, "k": "task", "a": "x", "id": task], ["v": 1, "k": "task", "a": "x", "id": "../x"], ["junk": true]]
        for info in hostile {
            XCTAssertEqual(HandoffActivity.resolve(info, account: "x", signedIn: true, hasTask: none, hasProject: none), .failure(.invalid))
        }
        for failure in [HandoffActivity.Failure.invalid, .signedOut, .otherWorkspace, .unavailable] {
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertFalse(failure.message.contains(task))
        }
    }

    @MainActor func testAdvertiserShowsTheLatestClaimAndFallsBack() {
        let advertiser = HandoffAdvertiser()
        let today = UUID(), editor = UUID()
        XCTAssertNil(advertiser.current)
        advertiser.claim(today, .today)
        XCTAssertEqual(advertiser.current, .today)
        advertiser.claim(editor, .task(task))
        XCTAssertEqual(advertiser.current, .task(task))
        advertiser.claim(today, .today)                         // an unchanged claim does not jump ahead of the editor
        XCTAssertEqual(advertiser.current, .task(task))
        advertiser.release(editor)
        XCTAssertEqual(advertiser.current, .today)
        advertiser.claim(today, .calendar)                      // the same screen changing its mind replaces its claim
        XCTAssertEqual(advertiser.current, .calendar)
        XCTAssertEqual(advertiser.claims.count, 1)
        advertiser.release(today); advertiser.release(today)
        XCTAssertNil(advertiser.current)
    }
}
