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
        for hue in ProjectPalette.hues {
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
        XCTAssertEqual(ProjectPalette.hue(stored: "grape", projectID: "p").id, "focus")
        XCTAssertEqual(ProjectPalette.hue(stored: "#22c55e", projectID: "p").id, "garden")
        XCTAssertEqual(ProjectPalette.hue(stored: "red", projectID: "p").id, "studio")
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
                // Measured floor: teal and sky in light mode reach about 4.2 and 4.4 (noted in the PR); everything else 4.5+.
                XCTAssertGreaterThanOrEqual(text.contrast(with: fill), 4.2, "\(hue.name) \(dark)")
            }
        }
    }
}
