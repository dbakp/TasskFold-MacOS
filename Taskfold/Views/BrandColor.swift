import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// SwiftUI side of Core/Brand.swift: role colours that follow light and dark, the priority check and the project
// pebble. The same file is compiled into the app, the widgets and (iOS) the watch, so all of them draw priority and
// project identity the same way. Watch faces are always dark, so the watch uses the dark values.

extension BrandRGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

extension Color {
    /// A role colour with its light and dark values, optionally at an opacity per appearance.
    init(brand pair: BrandPair, opacity: Double = 1, darkOpacity: Double? = nil) {
        #if os(watchOS)
        let c = pair.dark
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: darkOpacity ?? opacity)
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            let c = pair.value(dark: dark)
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: dark ? (darkOpacity ?? opacity) : opacity)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = pair.value(dark: dark)
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: dark ? (darkOpacity ?? opacity) : opacity)
        })
        #endif
    }
    static var brandCrimson: Color { Color(brand: Brand.crimson) }
    static var brandInk: Color { Color(brand: Brand.ink) }
    static var brandSecondary: Color { Color(brand: Brand.secondary) }
    static var brandGround: Color { Color(brand: Brand.ground) }
    static var brandSurface: Color { Color(brand: Brand.surface) }
}

extension ProjectHue {
    var color: Color { Color(brand: pair) }
    /// White or ink, whichever reads better on this hue's solid fill in the current appearance.
    var onColor: Color {
        Color(brand: BrandPair(Self.hex(Brand.textOn(pair.light, dark: false)), Self.hex(Brand.textOn(pair.dark, dark: true))))
    }
    private static func hex(_ c: BrandRGB) -> UInt32 {
        (UInt32((c.red * 255).rounded()) << 16) | (UInt32((c.green * 255).rounded()) << 8) | UInt32((c.blue * 255).rounded())
    }
}

/// The task check. Priority is its strength (P1 a 2.5pt crimson ring with a 15% fill, down to a P4 hairline); a done
/// task is a solid disc in `doneColor` (the project colour) with a check.
struct PriorityCheck: View {
    var priority: Int
    var checked = false
    var doneColor: Color = .brandCrimson
    var size: CGFloat = 22
    var body: some View {
        let strength = CheckStrength.forPriority(priority)
        ZStack {
            Circle().fill(Color(brand: Brand.crimson, opacity: strength.fillOpacity.light, darkOpacity: strength.fillOpacity.dark))
                .opacity(checked ? 0 : 1)
            Circle().strokeBorder(Color(brand: strength.pair, opacity: strength.strokeOpacity.light, darkOpacity: strength.strokeOpacity.dark), lineWidth: strength.lineWidth)
                .opacity(checked ? 0 : 1)
            Circle().fill(doneColor).opacity(checked ? 1 : 0)
            Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white).opacity(checked ? 1 : 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A project's identity pebble, drawn before its name.
struct ProjectPebble: View {
    var hue: ProjectHue
    var size: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(hue.color)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
