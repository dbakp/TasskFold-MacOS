import XCTest
@testable import TaskfoldCore

/// The guard that keeps tests, previews, fixtures and captures away from the hosted Supabase project.
final class HostedBackendGuardTests: XCTestCase {
    private let hosted = "https://zqxflydiyfjeedqvyova.supabase.co"
    private var refusals: [String] = []
    private var savedHandler: ((String) -> Void)?
    private var savedTrap = true

    override func setUp() {
        super.setUp()
        refusals = []; savedHandler = HostedBackendGuard.onRefusal; savedTrap = HostedBackendGuard.trapExplicitRefusals
        HostedBackendGuard.onRefusal = { [unowned self] in refusals.append($0) }
        HostedBackendGuard.trapExplicitRefusals = false // a real refusal traps in DEBUG; the test observes it instead
    }
    override func tearDown() {
        HostedBackendGuard.onRefusal = savedHandler ?? { _ in }; HostedBackendGuard.trapExplicitRefusals = savedTrap
        super.tearDown()
    }

    func testHostedDetectionCoversProjectAndAnySupabaseHost() {
        for origin in [hosted, "https://abcdefghijklmnopqrst.supabase.co", "HTTPS://ZQXFLYDIYFJEEDQVYOVA.SUPABASE.CO", hosted + ":443/rest/v1",
                       hosted + ".", "https://user:pw@abcdefghijklmnopqrst.supabase.co", "https://db.abcdefghijklmnopqrst.supabase.co", "https://x.supabase.in",
                       "https://supabase.co", "not a url supabase.co"] {
            XCTAssertTrue(HostedBackendGuard.isHosted(origin), origin)
        }
        for origin in ["http://127.0.0.1:54321", "https://localhost:54321", "https://synthetic.example", "https://native-auth.test", "https://hosted-backend-blocked-in-tests.invalid",
                       "https://supabase.co.evil.invalid", "", "https://example.invalid/supabase.co"] {
            XCTAssertFalse(HostedBackendGuard.isHosted(origin), origin)
        }
    }

    func testTestContextDetection() {
        func context(_ arguments: [String] = ["Taskfold"], _ environment: [String: String] = [:], bundle: String? = "com.dbakp.taskfold", xctest: Bool = false) -> Bool {
            HostedBackendGuard.isTestContext(arguments: arguments, environment: environment, bundleIdentifier: bundle, xctestLoaded: xctest)
        }
        XCTAssertFalse(context(), "an ordinary launch is not a test context")
        XCTAssertFalse(context(["Taskfold", "-appearance", "light"], bundle: "com.dbakp.taskfold.mac"))
        XCTAssertTrue(context(xctest: true))
        for argument in ["--uitesting", "--preview", "--live-auth-ui-test", "--capture=x.png", "--team-editor-testing", "--workflow-fixture", "--starter-open"] {
            XCTAssertTrue(context(["Taskfold", argument]), argument)
        }
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCInjectBundleInto", "TASKFOLD_TEST_CONTEXT"] {
            XCTAssertTrue(context(["Taskfold"], [key: "1"]), key)
        }
        for bundle in ["com.dbakp.taskfold.workflowtestssharecloud", "com.dbakp.taskfold.mac.p0signeduitests", "com.dbakp.taskfold.backupcanceltests", "com.dbakp.taskfold.mac.p0widgethosts"] {
            XCTAssertTrue(context(bundle: bundle), bundle)
        }
    }

    func testOptInRequiresExactlyOne() {
        XCTAssertTrue(HostedBackendGuard.isOptedIn(environment: ["TASKFOLD_ALLOW_HOSTED_TESTS": "1"]))
        for value in ["0", "true", "yes", "", " 1"] { XCTAssertFalse(HostedBackendGuard.isOptedIn(environment: ["TASKFOLD_ALLOW_HOSTED_TESTS": value]), value) }
        XCTAssertFalse(HostedBackendGuard.isOptedIn(environment: [:]))
    }

    func testHostedConfigurationIsReplacedWithUnroutableStubInTestContext() {
        for explicit in [true, false] {
            refusals = []
            let result = HostedBackendGuard.vetted(["URL": hosted, "Key": "public-key"], explicit: explicit, testContext: true, optedIn: false)
            XCTAssertEqual(result["URL"], HostedBackendGuard.blockedOrigin)
            XCTAssertNotEqual(result["Key"], "public-key", "the hosted key must not travel with a blocked configuration")
            XCTAssertFalse(HostedBackendGuard.isHosted(result["URL"] ?? ""))
            XCTAssertEqual(URL(string: result["URL"] ?? "")?.host?.hasSuffix(".invalid"), true)
            XCTAssertEqual(refusals.count, 1, "refusal must be loud, never silent")
            XCTAssertTrue(refusals[0].contains("TASKFOLD_ALLOW_HOSTED_TESTS"))
        }
    }

    func testLocalAndStubConfigurationsAndNonTestRunsPassThrough() {
        for origin in ["http://127.0.0.1:54321", "https://synthetic.example", HostedBackendGuard.blockedOrigin] {
            XCTAssertEqual(HostedBackendGuard.vetted(["URL": origin, "Key": "k"], explicit: true, testContext: true, optedIn: false), ["URL": origin, "Key": "k"])
        }
        XCTAssertEqual(HostedBackendGuard.vetted(["URL": hosted, "Key": "k"], explicit: false, testContext: false, optedIn: false)["URL"], hosted, "production launches are untouched")
        XCTAssertTrue(refusals.isEmpty)
    }

    func testHumanOptInAllowsHostedForDeliberateLiveTest() {
        XCTAssertEqual(HostedBackendGuard.vetted(["URL": hosted, "Key": "k"], explicit: true, testContext: true, optedIn: true)["URL"], hosted)
        XCTAssertTrue(refusals.isEmpty)
    }

    func testRequestLevelGuardRefusesHostedURLs() throws {
        let url = try XCTUnwrap(URL(string: hosted + "/auth/v1/signup"))
        XCTAssertFalse(HostedBackendGuard.permitsRequest(to: url, testContext: true, optedIn: false))
        XCTAssertEqual(refusals.count, 1)
        XCTAssertTrue(HostedBackendGuard.permitsRequest(to: url, testContext: true, optedIn: true))
        XCTAssertTrue(HostedBackendGuard.permitsRequest(to: url, testContext: false, optedIn: false))
        XCTAssertTrue(HostedBackendGuard.permitsRequest(to: try XCTUnwrap(URL(string: "http://127.0.0.1:54321/auth/v1/signup")), testContext: true, optedIn: false))
    }

    @MainActor func testBackendNeverKeepsAHostedURLUnderXCTest() throws {
        try XCTSkipIf(HostedBackendGuard.isOptedIn(), "A human opted in to hosted tests for this run")
        XCTAssertTrue(HostedBackendGuard.isTestContext(), "XCTest itself must be detected as a test context")
        let backend = Backend(configuration: ["URL": hosted, "Key": "public-key"], session: nil, persistSession: { _ in })
        XCTAssertFalse(HostedBackendGuard.isHosted(backend.baseURL))
        XCTAssertEqual(backend.baseURL, HostedBackendGuard.blockedOrigin)
        XCTAssertEqual(refusals.count, 1)
    }

    @MainActor func testBackendRequestToBlockedStubFailsWithoutNetworkToProduction() async throws {
        try XCTSkipIf(HostedBackendGuard.isOptedIn(), "A human opted in to hosted tests for this run")
        let backend = Backend(configuration: ["URL": hosted, "Key": "public-key"], session: nil, persistSession: { _ in })
        do { _ = try await backend.request("/auth/v1/signup", method: "POST", body: [:], authenticated: false); XCTFail("a blocked backend must not succeed") }
        catch { /* unroutable .invalid host: connection failure, never production */ }
    }
}
