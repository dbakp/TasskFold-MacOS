import Foundation

// TaskFold's owned colour system (design review, redesign round 2). Pure values only, so the apps, the widgets,
// the watch and the Core tests read the same numbers. Each platform turns these into its own colour type.
//
// Roles:
//   - Crimson owns one job, "act / today": primary buttons, the selected tab, the overdue date, P1.
//   - Ink and secondary carry text. Dates are ink, except overdue, which is crimson.
//   - Priority is the strength of the check, not a hue (see `CheckStrength`).
//   - Projects get an identity palette of eight deep hues (see `ProjectPalette`), shown as a pebble before the
//     project name, as ring segments and as time-grid blocks. Stored project colours are never rewritten; they are
//     mapped to the nearest palette pair for display.

/// An sRGB colour with components in 0...1.
struct BrandRGB: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255; green = Double((hex >> 8) & 0xFF) / 255; blue = Double(hex & 0xFF) / 255
    }
    /// "#C8102E" or "C8102E". Nil for anything else.
    init?(hex text: String) {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// WCAG 2 relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    /// WCAG 2 contrast ratio, 1...21.
    func contrast(with other: BrandRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    /// This colour at `opacity` over an opaque `background`.
    func over(_ background: BrandRGB, opacity: Double) -> BrandRGB {
        let o = min(1, max(0, opacity))
        return BrandRGB(red: red * o + background.red * (1 - o), green: green * o + background.green * (1 - o), blue: blue * o + background.blue * (1 - o))
    }
    /// OKLab, for perceptual nearest-colour matching.
    var oklab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    /// OKLCh: lightness, chroma and hue angle in degrees.
    var oklch: (l: Double, c: Double, h: Double) {
        let p = oklab
        var h = atan2(p.b, p.a) * 180 / .pi
        if h < 0 { h += 360 }
        return (p.l, sqrt(p.a * p.a + p.b * p.b), h)
    }
    func distance(to other: BrandRGB) -> Double {
        let p = oklab, q = other.oklab
        return sqrt(pow(p.l - q.l, 2) + pow(p.a - q.a, 2) + pow(p.b - q.b, 2))
    }
}

/// One role's light and dark value.
struct BrandPair: Equatable, Hashable, Sendable {
    var light: BrandRGB
    var dark: BrandRGB
    init(_ light: UInt32, _ dark: UInt32) { self.light = BrandRGB(light); self.dark = BrandRGB(dark) }
    func value(dark isDark: Bool) -> BrandRGB { isDark ? dark : light }
}

enum Brand {
    /// Act / today. Primary buttons, the selected tab, Overdue, P1. Nothing else.
    static let crimson = BrandPair(0xC8102E, 0xFF4F6B)
    /// Crimson text on a crimson 10-16% tint (Quick Add tokens and chips).
    static let crimsonOnTint = BrandPair(0x9E0C24, 0xFF7A8F)
    static let ink = BrandPair(0x1C1A1B, 0xF3EFF0)
    static let secondary = BrandPair(0x6E6A6C, 0xA39C9F)
    /// The page. Dark mode is a warm near-black, not an inversion.
    static let ground = BrandPair(0xFBFAF9, 0x141113)
    /// Cards, sheets and glass panels: one step lifted from the ground.
    static let surface = BrandPair(0xFFFFFF, 0x2C2629)
    /// Text that sits on crimson.
    static let onCrimson = BrandPair(0xFFFFFF, 0x141113)
    /// The ring track and quiet fills are ink at this opacity.
    static let trackOpacity = (light: 0.08, dark: 0.10)
    /// Open ring segments are their project colour at this opacity; done segments are full colour.
    static let openSegmentOpacity = 0.35
    /// Time-grid suggestions (dashed) are drawn at this opacity of a placed block.
    static let suggestionOpacity = 0.5

    /// White or ink, whichever reads better on `fill`.
    static func textOn(_ fill: BrandRGB, dark isDark: Bool) -> BrandRGB {
        let white = BrandRGB(0xFFFFFF), ink = Brand.ink.light
        return fill.contrast(with: white) >= fill.contrast(with: ink) ? white : ink
    }
}

/// Priority is the strength of the check. Overdue is never a ring: it is a crimson date.
struct CheckStrength: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case crimson, ink }
    var lineWidth: Double
    var tone: Tone
    /// Opacity of the ring stroke, light and dark.
    var strokeOpacity: (light: Double, dark: Double)
    /// Opacity of the crimson fill inside the ring (P1 only), light and dark.
    var fillOpacity: (light: Double, dark: Double)

    static func == (a: CheckStrength, b: CheckStrength) -> Bool {
        a.lineWidth == b.lineWidth && a.tone == b.tone && a.strokeOpacity == b.strokeOpacity && a.fillOpacity == b.fillOpacity
    }

    /// P1 2.5pt crimson with a 15% fill, P2 crimson 60% at 2pt, P3 ink 40% at 1.5pt, P4 ink 25% at 1pt.
    static func forPriority(_ priority: Int) -> CheckStrength {
        switch priority {
        case 1: CheckStrength(lineWidth: 2.5, tone: .crimson, strokeOpacity: (1, 1), fillOpacity: (0.15, 0.18))
        case 2: CheckStrength(lineWidth: 2, tone: .crimson, strokeOpacity: (0.6, 0.6), fillOpacity: (0, 0))
        case 3: CheckStrength(lineWidth: 1.5, tone: .ink, strokeOpacity: (0.4, 0.45), fillOpacity: (0, 0))
        default: CheckStrength(lineWidth: 1, tone: .ink, strokeOpacity: (0.25, 0.28), fillOpacity: (0, 0))
        }
    }
    var pair: BrandPair { tone == .crimson ? Brand.crimson : Brand.ink }
    func stroke(dark: Bool) -> (colour: BrandRGB, opacity: Double) { (pair.value(dark: dark), dark ? strokeOpacity.dark : strokeOpacity.light) }
    func fill(dark: Bool) -> (colour: BrandRGB, opacity: Double) { (Brand.crimson.value(dark: dark), dark ? fillOpacity.dark : fillOpacity.light) }
}

/// One identity hue.
struct ProjectHue: Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var pair: BrandPair
}

enum ProjectPalette {
    /// The eight identity hues. Distinct in lightness as well as hue; none is crimson.
    static let hues: [ProjectHue] = [
        ProjectHue(id: "work", name: "Blue", pair: BrandPair(0x2F5BD3, 0x6F93FF)),
        ProjectHue(id: "home", name: "Teal", pair: BrandPair(0x0F8C83, 0x3FC2B6)),
        ProjectHue(id: "personal", name: "Amber", pair: BrandPair(0xC77B12, 0xF0A43A)),
        ProjectHue(id: "focus", name: "Violet", pair: BrandPair(0x7A3E9D, 0xB07BD6)),
        ProjectHue(id: "garden", name: "Moss", pair: BrandPair(0x4F7A2A, 0x8BBE5A)),
        ProjectHue(id: "studio", name: "Rust", pair: BrandPair(0xB5482B, 0xF07A5A)),
        ProjectHue(id: "travel", name: "Sky", pair: BrandPair(0x1F7FB8, 0x5DB6EC)),
        ProjectHue(id: "admin", name: "Slate", pair: BrandPair(0x4A5568, 0xA0AEC0)),
    ]
    /// Inbox and tasks without a project.
    static let inbox = ProjectHue(id: "inbox", name: "Ink", pair: BrandPair(0x6E6A6C, 0xA39C9F))

    /// Named colours that projects may already store (Todoist names and the app's own names). Values are the
    /// colours those names were drawn with before, so the nearest-pair match keeps each project recognisable.
    static let namedColours: [String: UInt32] = [
        "berry_red": 0xB8255F, "red": 0xDB4035, "orange": 0xFF9933, "yellow": 0xFAD000, "olive_green": 0xAFB83B,
        "lime_green": 0x7ECC49, "green": 0x299438, "mint_green": 0x6ACCBC, "teal": 0x158FAD, "sky_blue": 0x14AAF5,
        "light_blue": 0x96C3EB, "blue": 0x4073FF, "grape": 0x884DFF, "violet": 0xAF38EB, "lavender": 0xEB96EB,
        "magenta": 0xE05194, "salmon": 0xFF8D85, "charcoal": 0x808080, "grey": 0xB8B8B8, "gray": 0x8E8E93, "taupe": 0xCCAC93,
        "purple": 0xAF52DE, "pink": 0xFF2D55,
    ]

    /// The display hue for a stored colour. A stored name or hex maps to the nearest pair (by OKLab distance to the
    /// light value); greys go to Slate. Nothing stored, or something unreadable, picks a stable hue from the project id.
    static func hue(stored colour: String?, projectID: String) -> ProjectHue {
        if let rgb = rgb(stored: colour) { return nearest(rgb) }
        return projectID.isEmpty ? inbox : hues[stableIndex(projectID)]
    }
    static func rgb(stored colour: String?) -> BrandRGB? {
        guard let raw = colour?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        if let named = namedColours[raw] { return BrandRGB(named) }
        return BrandRGB(hex: raw)
    }
    /// Nearest palette pair. Stored colours are usually brighter than the deep palette, so the match is by hue angle
    /// first (OKLCh), with lightness only as a tie-breaker. Low-chroma colours (greys) always map to Slate, so a grey
    /// never turns into a hue, and Slate never takes a coloured project.
    static func nearest(_ rgb: BrandRGB) -> ProjectHue {
        let target = rgb.oklch
        if target.c < 0.04 { return hues[7] }
        func score(_ hue: ProjectHue) -> Double {
            let p = hue.pair.light.oklch
            let dh = abs(target.h - p.h)
            return min(dh, 360 - dh) / 180 + abs(target.l - p.l) * 0.5
        }
        return hues.dropLast().min { score($0) < score($1) } ?? hues[0]
    }
    /// FNV-1a over the id's UTF-8 bytes: the same id picks the same hue on every device and launch.
    static func stableIndex(_ id: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return Int(hash % UInt64(hues.count))
    }
}
