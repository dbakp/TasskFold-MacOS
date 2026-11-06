import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class WidgetRecordLinkTests: XCTestCase {
    func testRecordLinksCannotResolveReusedIDsInAnotherWorkspace() throws {
        for host in ["task", "project", "label", "view"] {
            let link = WidgetLinks.scoped(host, id: "same record /?#%", account: "owner /?#%")
            let parts = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "account", value: "owner /?#%")])
            XCTAssertEqual(parts.percentEncodedPath, "/same%20record%20%2F%3F%23%25")
            XCTAssertTrue(WidgetRecordLink.allows(link, account: "owner /?#%", available: true))
            XCTAssertFalse(WidgetRecordLink.allows(link, account: "other-owner", available: true))
            XCTAssertFalse(WidgetRecordLink.allows(link, account: "owner /?#%", available: false))
            XCTAssertFalse(WidgetRecordLink.allows(link, account: "", available: true))
        }
    }
    func testMalformedScopedRecordLinksFailClosedBeforeNavigation() {
        for host in ["task", "project", "label", "view"] {
            for suffix in ["/shared?account=", "/shared?account", "/shared?account=owner&account=other", "/shared?account=owner&extra=1", "/shared?account=owner#fragment", "/shared/extra?account=owner", "?account=owner"] {
                XCTAssertFalse(WidgetRecordLink.allows(URL(string: "taskfold://" + host + suffix)!, account: "owner", available: true), host + suffix)
            }
        }
    }
    func testLegacySharedLinksAndOtherDedicatedRoutesKeepTheirExistingHandlers() {
        for value in ["taskfold://task/shared", "taskfold://project/shared", "taskfold://label/shared", "taskfold://view/shared", "taskfold://focus?account=other", "taskfold://note/shared?account=other", "https://task/shared?account=other"] {
            XCTAssertTrue(WidgetRecordLink.allows(URL(string: value)!, account: "owner", available: true))
        }
        XCTAssertEqual(WidgetLinks.task("shared", account: "").absoluteString, "taskfold://all")
        XCTAssertTrue(WidgetRecordLink.allows(WidgetLinks.task("shared", account: "owner"), account: "owner", available: true))
        XCTAssertFalse(WidgetRecordLink.allows(WidgetLinks.task("shared", account: "owner"), account: "other", available: true))
    }
}
