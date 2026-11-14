import SwiftUI
import AppKit

/// Design tokens for the Mac app. The names match the iOS app; see docs/DESIGN_TOKENS.md.
/// Views use these instead of numeric literals for spacing, radius, text styles and semantic colour.
enum DS {
    /// 4-pt grid.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    /// Use `.continuous` rounded rectangles and `Capsule()` for pills.
    enum Radius {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let xl: CGFloat = 20
    }

    /// Dynamic Type text styles by role (Mac column). Display text is SF Pro Expanded semibold; every time and count is tabular.
    enum Font {
        static let screenTitle = SwiftUI.Font.title2.weight(.semibold).width(.expanded)
        static let sectionHeader = SwiftUI.Font.subheadline.weight(.semibold)
        static let taskTitle = SwiftUI.Font.body
        /// Pair with `Palette.textSecondary`.
        static let taskNote = SwiftUI.Font.subheadline
        static let taskMeta = SwiftUI.Font.footnote.monospacedDigit()
        static let chip = SwiftUI.Font.caption.weight(.medium)
        static let badge = SwiftUI.Font.caption2.weight(.semibold).monospacedDigit()
        static let inspectorLabel = SwiftUI.Font.subheadline
        /// The ring figure, "4h 10m of 6h".
        static let ringFigure = SwiftUI.Font.title3.weight(.semibold).width(.expanded).monospacedDigit()
        /// A date line under a title, sentence case, never an ALL-CAPS eyebrow.
        static let dateLine = SwiftUI.Font.subheadline
        /// Times on time-grid blocks.
        static let blockTime = SwiftUI.Font.caption.weight(.semibold).width(.expanded).monospacedDigit()
    }

    /// Semantic colour, from Core/Brand.swift. Crimson owns "act / today" only; dates are ink except overdue.
    enum Palette {
        static var textPrimary: Color { Color(brand: Brand.ink) }
        static var textSecondary: Color { Color(brand: Brand.secondary) }
        static var textTertiary: Color { Color(brand: Brand.ink, opacity: 0.4, darkOpacity: 0.45) }
        static var separator: Color { Color(nsColor: .separatorColor) }
        /// Round 3: one warm ground, light and dark (#FBFAF9 / #141113), like the iPhone.
        static var surface: Color { Color(brand: Brand.ground) }
        static var surfaceRaised: Color { Color(nsColor: .controlBackgroundColor) }
        static var surfaceSunken: Color { Color(brand: Brand.ink, opacity: Brand.trackOpacity.light, darkOpacity: Brand.trackOpacity.dark) }
        static var danger: Color { .red }
        static var success: Color { .green }
        static var dateOverdue: Color { Color(brand: Brand.crimson) }
        /// Dates are ink: colour is kept for overdue.
        static var dateToday: Color { textPrimary }
        static var dateTomorrow: Color { textPrimary }
        static var dateThisWeek: Color { textPrimary }
        static var dateLater: Color { textPrimary }
        /// Quick Add highlight roles: `#project` and `/section`, and `@label` read as quiet ink tokens.
        static var accentSecondary: Color { textPrimary }
        static var label: Color { textSecondary }
        /// A calm caution colour for "over capacity": information, not an error.
        static var caution: Color { textSecondary }
        static func priority(_ value: Int) -> Color { Color.priority(value) }
        static var accent: Color { Color.taskfold }
        /// The fill of a prominent button: the crimson fill for the brand accent (white text reaches 4.5:1 in dark mode
        /// too, where #FF4F6B would be 3.19:1), otherwise the chosen accent.
        static var accentFill: Color { (UserDefaults.standard.string(forKey: "accent") ?? "rose") == "rose" ? Color(brand: Brand.crimsonFill) : Color.taskfold }
        /// Accent at 0.14 (light) / 0.22 (dark). A selected row keeps `textPrimary`, never white on light grey.
        static var selectionFill: Color {
            let accent = NSColor(Color.taskfold)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return accent.withAlphaComponent(dark ? 0.22 : 0.14)
            })
        }
        /// A project's identity hue: its stored colour mapped to the nearest palette pair (stored data is never
        /// rewritten), or a stable hue from its id when it has none. Inbox work is ink.
        static func project(_ record: Record?) -> ProjectHue {
            guard let record else { return ProjectPalette.inbox }
            return ProjectPalette.hue(stored: record.string("color"), projectID: record.id)
        }
    }

    enum Size {
        static let checkbox: CGFloat = 18
        static let iconS: CGFloat = 12
        static let iconM: CGFloat = 14
        static let iconL: CGFloat = 18
        static let rowMinHeight: CGFloat = 32
        static let rowVerticalPaddingRoomy: CGFloat = 8
        static let rowVerticalPaddingCompact: CGFloat = 4
        static func rowVerticalPadding(compact: Bool) -> CGFloat { compact ? rowVerticalPaddingCompact : rowVerticalPaddingRoomy }
        static let rowHorizontalPadding: CGFloat = Space.m
        static let contentMaxWidth: CGFloat = 860
    }

    /// Aliases onto the existing `Motion` vocabulary (the Mac values stay shorter and subtler on purpose).
    enum Motion {
        static let complete = Taskfold.Motion.settle
        static let appear = Taskfold.Motion.quick
        static let reorder = Taskfold.Motion.layout
    }
}

/// Stops AppKit painting its own accent/grey selection behind task rows, so the row can draw
/// `DS.Palette.selectionFill` and keep primary text colour. Attach as a `.background` of the List.
struct QuietNativeSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        // Only the table that this background sits behind is quieted: its scroll
        // view must contain the probe's centre in window coordinates. Walking up
        // and taking the first table found could otherwise reach the sidebar.
        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                let centre = self.convert(NSPoint(x: self.bounds.midX, y: self.bounds.midY), to: nil)
                var node: NSView? = self.superview
                while let current = node {
                    if let table = Self.table(in: current, containing: centre) {
                        table.selectionHighlightStyle = .none
                        return
                    }
                    node = current.superview
                }
            }
        }
        private static func table(in view: NSView, containing point: NSPoint) -> NSTableView? {
            if let table = view as? NSTableView {
                let host: NSView = table.enclosingScrollView ?? table
                return host.convert(host.bounds, to: nil).contains(point) ? table : nil
            }
            for sub in view.subviews {
                if let found = table(in: sub, containing: point) { return found }
            }
            return nil
        }
    }
}
