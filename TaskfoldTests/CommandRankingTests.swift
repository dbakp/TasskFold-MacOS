import XCTest
@testable import TaskfoldCore

final class CommandRankingTests: XCTestCase {
    typealias C = CommandRanking.Candidate
    func ids(_ list: [C], _ query: String) -> [String] { CommandRanking.rank(list, query: query).map(\.id) }

    func testEmptyQueryKeepsEverythingInInputOrderThenBoost() {
        let list = [C(id: "a", title: "Alpha"), C(id: "b", title: "Beta", boost: 5), C(id: "c", title: "Gamma")]
        XCTAssertEqual(ids(list, "  "), ["b", "a", "c"])
    }
    func testExactBeatsPrefixBeatsWordPrefixBeatsSubstring() {
        let list = [C(id: "sub", title: "Unreported"), C(id: "word", title: "Write report"), C(id: "prefix", title: "Report card"), C(id: "exact", title: "Report")]
        XCTAssertEqual(ids(list, "report"), ["exact", "prefix", "word", "sub"])
    }
    func testIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(ids([C(id: "x", title: "Café plans")], "CAFE"), ["x"])
    }
    func testEveryTermMustMatchInAnyOrder() {
        let list = [C(id: "1", title: "Plan today"), C(id: "2", title: "Plan quarter")]
        XCTAssertEqual(ids(list, "today plan"), ["1"])
        XCTAssertEqual(ids(list, "plan zzz"), [])
    }
    func testInitialsAndSubsequenceMatchButScatteredLettersRankLower() {
        let list = [C(id: "scattered", title: "Pick up the tools"), C(id: "initials", title: "Plan today")]
        XCTAssertEqual(ids(list, "pt"), ["initials", "scattered"])
        XCTAssertEqual(ids([C(id: "w", title: "Write report")], "wrpt"), ["w"])
        XCTAssertEqual(ids([C(id: "w", title: "Write report")], "zq"), [])
    }
    func testSingleLetterDoesNotFuzzyMatchEverything() {
        XCTAssertEqual(ids([C(id: "a", title: "Inbox")], "z"), [])
    }
    func testKeywordsAndDetailMatchBelowTitle() {
        let list = [C(id: "detail", title: "Zebra", detail: "Go to calendar"), C(id: "key", title: "Zulu", keywords: ["calendar"]), C(id: "title", title: "Calendar")]
        XCTAssertEqual(ids(list, "calendar"), ["title", "key", "detail"])
    }
    func testShorterTitleWinsOnEqualMatchClassAndTiesKeepInputOrder() {
        let list = [C(id: "long", title: "Inbox review for the whole quarter and more"), C(id: "short", title: "Inbox review")]
        XCTAssertEqual(ids(list, "inbox"), ["short", "long"])
        XCTAssertEqual(ids([C(id: "a", title: "Task"), C(id: "b", title: "Task")], "task"), ["a", "b"])
    }
    func testBoostLimitAndScoreAccessor() {
        let list = [C(id: "task", title: "New task"), C(id: "cmd", title: "New project", boost: 50)]
        XCTAssertEqual(ids(list, "new"), ["cmd", "task"])
        XCTAssertEqual(CommandRanking.rank(list, query: "new", limit: 1).count, 1)
        XCTAssertEqual(CommandRanking.rank(list, query: "new", limit: 0), [])
        XCTAssertNil(CommandRanking.score(query: "q", candidate: list[0]))
    }
}
