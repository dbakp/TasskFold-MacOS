import XCTest
@testable import TaskfoldCore

/// The owned colour system (Core/Brand.swift): measured contrast, check strength per priority and the project palette.
final class BrandTests: XCTestCase {
    func testTokensMatchTheApprovedSystem() {
        XCTAssertEqual(Brand.crimson.light.hex, "#C8102E"); XCTAssertEqual(Brand.crimson.dark.hex, "#FF4F6B")
        XCTAssertEqual(Brand.ink.light.hex, "#1C1A1B"); XCTAssertEqual(Brand.secondary.light.hex, "#6E6A6C")
        XCTAssertEqual(Brand.ground.light.hex, "#FBFAF9"); XCTAssertEqual(Brand.ground.dark.hex, "#141113")
    }

    /// Every text role reaches 4.5:1 on the ground and on raised surfaces, in light and dark.
    func testTextContrastIsAtLeastFourPointFiveInBothThemes() {
        for dark in [false, true] {
            for background in [Brand.ground.value(dark: dark), Brand.surface.value(dark: dark)] {
                for role in [Brand.ink, Brand.secondary, Brand.crimson, Brand.crimsonOnTint] {
                    let ratio = role.value(dark: dark).contrast(with: background)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(role.value(dark: dark).hex) on \(background.hex) is \(ratio)")
                }
            }
            // Crimson token text on its own 10% (light) / 16% (dark) tint inside the Quick Add panel.
            let panel = Brand.surface.value(dark: dark)
            let tint = Brand.crimson.value(dark: dark).over(panel, opacity: dark ? 0.16 : 0.10)
            XCTAssertGreaterThanOrEqual(Brand.crimsonOnTint.value(dark: dark).contrast(with: tint), 4.5)
            // The send button's glyph.
            XCTAssertGreaterThanOrEqual(Brand.onCrimson.value(dark: dark).contrast(with: Brand.crimson.value(dark: dark)), 4.5)
            // Filled crimson buttons (Apply, Start review, Add an idea): white on #C8102E / #E0284A, not on #FF4F6B (3.19:1).
            let fill = Brand.crimsonFill.value(dark: dark)
            XCTAssertGreaterThanOrEqual(Brand.onCrimsonFill.value(dark: dark).contrast(with: fill), 4.5, "button text on \(fill.hex)")
        }
        XCTAssertEqual(Brand.crimsonFill.dark.hex, "#E0284A")
        XCTAssertLessThan(BrandRGB(0xFFFFFF).contrast(with: Brand.crimson.dark), 4.5, "the reason filled buttons do not use #FF4F6B")
    }

    /// Round 3: text on every time-grid block clears 4.5:1 in both themes. Placed tasks are solid hue with white or ink;
    /// suggestions are the hue at 25% over the ground with ink; events are ink at 5% / 8% with ink and secondary text.
    func testTextOnEveryBlockIsAtLeastFourPointFive() {
        for dark in [false, true] {
            let ground = Brand.ground.value(dark: dark)
            for hue in ProjectPalette.hues + [ProjectPalette.inbox] {
                let fill = hue.pair.value(dark: dark)
                let placed = Brand.textOn(fill, dark: dark).contrast(with: fill)
                XCTAssertGreaterThanOrEqual(placed, 4.5, "placed \(hue.name) dark=\(dark): \(placed)")
                let tint = fill.over(ground, opacity: Brand.suggestionOpacity)
                let suggested = Brand.onSuggestion.value(dark: dark).contrast(with: tint)
                XCTAssertGreaterThanOrEqual(suggested, 4.5, "suggested \(hue.name) dark=\(dark): \(suggested)")
            }
            let event = Brand.ink.value(dark: dark).over(ground, opacity: dark ? Brand.eventOpacity.dark : Brand.eventOpacity.light)
            for role in [Brand.ink, Brand.secondary] {
                XCTAssertGreaterThanOrEqual(role.value(dark: dark).contrast(with: event), 4.5, "event text dark=\(dark)")
            }
        }
    }

    func testContrastFormulaMatchesWCAGReferenceValues() {
        XCTAssertEqual(BrandRGB(0x000000).contrast(with: BrandRGB(0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(BrandRGB(0x777777).contrast(with: BrandRGB(0xFFFFFF)), 4.48, accuracy: 0.01)
    }

    func testCheckStrengthPerPriority() {
        let p1 = CheckStrength.forPriority(1), p2 = CheckStrength.forPriority(2), p3 = CheckStrength.forPriority(3), p4 = CheckStrength.forPriority(4)
        XCTAssertEqual(p1.lineWidth, 2.5); XCTAssertEqual(p1.tone, .crimson); XCTAssertEqual(p1.strokeOpacity.light, 1); XCTAssertEqual(p1.fillOpacity.light, 0.15)
        XCTAssertEqual(p2.lineWidth, 2); XCTAssertEqual(p2.tone, .crimson); XCTAssertEqual(p2.strokeOpacity.light, 0.6); XCTAssertEqual(p2.fillOpacity.light, 0)
        XCTAssertEqual(p3.lineWidth, 1.5); XCTAssertEqual(p3.tone, .ink); XCTAssertEqual(p3.strokeOpacity.light, 0.4)
        XCTAssertEqual(p4.lineWidth, 1); XCTAssertEqual(p4.tone, .ink); XCTAssertEqual(p4.strokeOpacity.light, 0.25)
        // Unknown or missing priorities draw as P4; strength falls strictly from P1 to P4.
        XCTAssertEqual(CheckStrength.forPriority(0), p4); XCTAssertEqual(CheckStrength.forPriority(9), p4)
        XCTAssertTrue(zip([p1, p2, p3], [p2, p3, p4]).allSatisfy { $0.lineWidth > $1.lineWidth })
        XCTAssertEqual(p1.stroke(dark: true).colour, Brand.crimson.dark)
        XCTAssertEqual(p3.stroke(dark: false).colour, Brand.ink.light)
    }

    func testPaletteHasEightDistinctHuesAndNoCrimson() {
        XCTAssertEqual(ProjectPalette.hues.count, 8)
        XCTAssertEqual(Set(ProjectPalette.hues.map(\.pair.light)).count, 8)
        XCTAssertEqual(ProjectPalette.hues.first { $0.id == "studio" }?.pair.light.hex, "#4338A8", "rust is replaced by indigo")
        for a in ProjectPalette.hues.indices { for b in ProjectPalette.hues.indices where b > a {
            let x = ProjectPalette.hues[a].pair, y = ProjectPalette.hues[b].pair
            XCTAssertGreaterThan(x.light.distance(to: y.light), 0.05, "\(ProjectPalette.hues[a].name) / \(ProjectPalette.hues[b].name) light")
            XCTAssertGreaterThan(x.dark.distance(to: y.dark), 0.05, "\(ProjectPalette.hues[a].name) / \(ProjectPalette.hues[b].name) dark")
        } }
        for hue in ProjectPalette.hues {
            // No red-family hue anywhere: nothing between magenta-red and orange-red competes with crimson.
            for value in [hue.pair.light, hue.pair.dark] where value.oklch.c >= 0.04 {
                let angle = value.oklch.h
                XCTAssertFalse(angle >= 345 || angle <= 50, "\(hue.name) \(value.hex) is red-family at \(Int(angle))°")
            }
            XCTAssertGreaterThan(hue.pair.light.distance(to: Brand.crimson.light), 0.05, hue.name)
            // Pebbles and ring segments are non-text marks: 3:1 against the ground.
            XCTAssertGreaterThanOrEqual(hue.pair.light.contrast(with: Brand.ground.light), 3, hue.name)
            XCTAssertGreaterThanOrEqual(hue.pair.dark.contrast(with: Brand.ground.dark), 3, hue.name)
        }
    }

    func testStoredColoursMapToNearestPairWithoutRewritingThem() {
        XCTAssertEqual(ProjectPalette.hue(stored: "#3b82f6", projectID: "p").id, "work")
        XCTAssertEqual(ProjectPalette.hue(stored: "blue", projectID: "p").id, "work")
        XCTAssertEqual(ProjectPalette.hue(stored: "#14b8a6", projectID: "p").id, "home")
        XCTAssertEqual(ProjectPalette.hue(stored: "orange", projectID: "p").id, "personal")
        XCTAssertEqual(ProjectPalette.hue(stored: "violet", projectID: "p").id, "focus")
        XCTAssertEqual(ProjectPalette.hue(stored: "grape", projectID: "p").id, "studio", "a blue-purple lands on indigo")
        XCTAssertEqual(ProjectPalette.hue(stored: "#22c55e", projectID: "p").id, "garden")
        // A stored red no longer lands on a red-family hue: it maps to the warm amber.
        XCTAssertEqual(ProjectPalette.hue(stored: "red", projectID: "p").id, "personal")
        XCTAssertEqual(ProjectPalette.hue(stored: "#4338a8", projectID: "p").id, "studio")
        XCTAssertEqual(ProjectPalette.hue(stored: "sky_blue", projectID: "p").id, "travel")
        XCTAssertEqual(ProjectPalette.hue(stored: "charcoal", projectID: "p").id, "admin")
        XCTAssertEqual(ProjectPalette.hue(stored: "#6b7280", projectID: "p").id, "admin")
        // An exact palette value maps to itself, in either case.
        for hue in ProjectPalette.hues { XCTAssertEqual(ProjectPalette.hue(stored: hue.pair.light.hex.lowercased(), projectID: "x").id, hue.id) }
    }

    func testProjectsWithoutAReadableColourGetAStableHueFromTheirId() {
        let a = ProjectPalette.hue(stored: nil, projectID: "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(a, ProjectPalette.hue(stored: "", projectID: "11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(a, ProjectPalette.hue(stored: "not-a-colour", projectID: "11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(ProjectPalette.stableIndex("abc"), ProjectPalette.stableIndex("abc"))
        XCTAssertEqual(Set((0..<64).map { ProjectPalette.stableIndex("project-\($0)") }).count, 8, "ids spread over every hue")
        XCTAssertEqual(ProjectPalette.hue(stored: nil, projectID: ""), ProjectPalette.inbox)
    }

    func testTextOnBlocksPicksTheBetterOfWhiteAndInk() {
        for hue in ProjectPalette.hues {
            for dark in [false, true] {
                let fill = hue.pair.value(dark: dark), text = Brand.textOn(fill, dark: dark)
                let other = text == BrandRGB(0xFFFFFF) ? Brand.ink.light : BrandRGB(0xFFFFFF)
                XCTAssertGreaterThanOrEqual(text.contrast(with: fill), other.contrast(with: fill))
                // Round 3: teal and sky were deepened, so every hue now clears 4.5 (was 4.2 floor).
                XCTAssertGreaterThanOrEqual(text.contrast(with: fill), 4.5, "\(hue.name) \(dark)")
            }
        }
    }
}
