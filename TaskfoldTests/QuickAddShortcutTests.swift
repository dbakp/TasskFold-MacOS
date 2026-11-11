import XCTest
@testable import QuickAddShortcutModel

final class QuickAddShortcutTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "QuickAddShortcutTests-" + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }

    func testDefaultIsControlOptionSpace() {
        XCTAssertEqual(QuickAddShortcut.default.keyCode, 49)
        XCTAssertEqual(QuickAddShortcut.default.modifiers, QuickAddShortcut.control | QuickAddShortcut.option)
        XCTAssertEqual(QuickAddShortcut.default.displayString, "⌃⌥Space")
        XCTAssertNil(QuickAddShortcut.default.problem)
    }

    func testDisplayStringUsesMacModifierOrder() {
        let all = QuickAddShortcut(keyCode: 2, modifiers: QuickAddShortcut.command | QuickAddShortcut.shift | QuickAddShortcut.option | QuickAddShortcut.control)
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘D")
        XCTAssertEqual(QuickAddShortcut(keyCode: 36, modifiers: QuickAddShortcut.command).displayString, "⌘↩")
        XCTAssertEqual(QuickAddShortcut(keyCode: 122, modifiers: 0).displayString, "F1")
        XCTAssertEqual(QuickAddShortcut(keyCode: 126, modifiers: QuickAddShortcut.option).displayString, "⌥↑")
        XCTAssertEqual(QuickAddShortcut(keyCode: 127, modifiers: QuickAddShortcut.option).displayString, "⌥Key 127")
    }

    func testFlagsConvertToCarbonBits() {
        let shortcut = QuickAddShortcut(keyCode: 49, flags: [.control, .option])
        XCTAssertEqual(shortcut, .default)
        XCTAssertEqual(QuickAddShortcut(keyCode: 0, flags: [.command, .shift, .capsLock]).modifiers, QuickAddShortcut.command | QuickAddShortcut.shift)
    }

    func testStorageRoundTrip() {
        let suite = defaults()
        let chosen = QuickAddShortcut(keyCode: 11, modifiers: QuickAddShortcut.command | QuickAddShortcut.option)
        QuickAddShortcutStore.save(chosen, suite)
        XCTAssertEqual(QuickAddShortcutStore.load(suite), chosen)
        QuickAddShortcutStore.save(.default, suite)
        XCTAssertEqual(QuickAddShortcutStore.load(suite), .default)
    }

    func testNothingStoredLoadsTheDefaultAndClearedStaysCleared() {
        let suite = defaults()
        XCTAssertEqual(QuickAddShortcutStore.load(suite), .default)
        QuickAddShortcutStore.save(nil, suite)
        XCTAssertNil(QuickAddShortcutStore.load(suite))
        QuickAddShortcutStore.reset(suite)
        XCTAssertEqual(QuickAddShortcutStore.load(suite), .default)
    }

    func testUnreadableStorageFallsBackToTheDefault() {
        let suite = defaults()
        suite.set(["keyCode": "x"], forKey: QuickAddShortcutStore.key)
        XCTAssertEqual(QuickAddShortcutStore.load(suite), .default)
        suite.set(["keyCode": 500, "modifiers": 4096], forKey: QuickAddShortcutStore.key)
        XCTAssertEqual(QuickAddShortcutStore.load(suite), .default)
        suite.set("garbage", forKey: QuickAddShortcutStore.key)
        XCTAssertEqual(QuickAddShortcutStore.load(suite), .default)
    }

    func testValidation() {
        XCTAssertEqual(QuickAddShortcut(keyCode: 0, modifiers: 0).problem, .needsModifier)
        XCTAssertEqual(QuickAddShortcut(keyCode: 0, modifiers: QuickAddShortcut.shift).problem, .needsModifier)
        XCTAssertNil(QuickAddShortcut(keyCode: 122, modifiers: 0).problem, "Function keys register alone")
        XCTAssertEqual(QuickAddShortcut(keyCode: 49, modifiers: QuickAddShortcut.command).problem, .reserved("Spotlight"))
        XCTAssertEqual(QuickAddShortcut(keyCode: 2, modifiers: QuickAddShortcut.control | QuickAddShortcut.option | QuickAddShortcut.command).problem, .reserved("Taskfold (Edit Deadlines)"))
        XCTAssertNil(QuickAddShortcut(keyCode: 49, modifiers: QuickAddShortcut.command | QuickAddShortcut.shift).problem)
    }
}
