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

    /// Dynamic Type text styles by role (Mac column). Screen titles are Fraunces SemiBold; other display text is
    /// SF Pro Expanded semibold; rows and controls stay SF. Every time and count is tabular.
    enum Font {
        /// PostScript names of the bundled static Fraunces instances (Taskfold/Resources/Fonts, SIL OFL 1.1, see
        /// Fraunces-OFL.txt): wght 600, SOFT 0, WONK 0; opsz 72 for display sizes, opsz 24 for title2-size titles.
        static let displayTitleFace = "Fraunces-SemiBold"
        static let screenTitleFace = "Fraunces24pt-SemiBold"
        /// Screen and panel titles: Fraunces SemiBold 17 (the opsz 24 cut), relative to title2. Display use only;
        /// falls back to the system face if the font is missing.
        static let screenTitle = SwiftUI.Font.custom(screenTitleFace, size: 17, relativeTo: .title2)
        /// The title in the content of every list (design review mac-r1): Fraunces SemiBold 28, relative to largeTitle.
        static let contentTitle = SwiftUI.Font.custom(screenTitleFace, size: 28, relativeTo: .largeTitle)
        /// The inspector's task title: Fraunces SemiBold 20, relative to title2.
        static let inspectorTitle = SwiftUI.Font.custom(screenTitleFace, size: 20, relativeTo: .title2)
        /// The sign-in wordmark: Fraunces SemiBold 34 (the opsz 72 cut), relative to largeTitle.
        static let displayTitle = SwiftUI.Font.custom(displayTitleFace, size: 34, relativeTo: .largeTitle)
        /// 13 pt semibold (the Mac body size), ink; Overdue alone is crimson.
        static let sectionHeader = SwiftUI.Font.body.weight(.semibold)
        static let taskTitle = SwiftUI.Font.body
        /// Pair with `Palette.textSecondary`.
        static let taskNote = SwiftUI.Font.subheadline
        static let taskMeta = SwiftUI.Font.footnote.monospacedDigit()
        static let chip = SwiftUI.Font.caption.weight(.medium)
        static let badge = SwiftUI.Font.caption2.weight(.semibold).monospacedDigit()
        static let inspectorLabel = SwiftUI.Font.subheadline
        /// The ring figure, "4h 10m of 6h".
        static let ringFigure = SwiftUI.Font.callout.monospacedDigit()
        /// A date line under a title, sentence case, never an ALL-CAPS eyebrow. 13 pt on Mac.
        static let dateLine = SwiftUI.Font.body
        /// Times on time-grid blocks.
        static let blockTime = SwiftUI.Font.caption.weight(.semibold).width(.expanded).monospacedDigit()
        /// Today's hero title beside the 72 pt day ring: Fraunces SemiBold 30 (the opsz 72 cut), relative to largeTitle.
        static let heroTitle = SwiftUI.Font.custom(displayTitleFace, size: 30, relativeTo: .largeTitle)
        /// The hero figure's lead, "4h 30m": 15 pt semibold, tabular. Its rest, " of 7h 30m", is `heroFigureRest`.
        static let heroFigure = SwiftUI.Font.title3.weight(.semibold).monospacedDigit()
        static let heroFigureRest = SwiftUI.Font.body.monospacedDigit()
        /// The line under the hero figure, "3h free · 1h 30m done", and the empty day's teaching line: 12 pt.
        static let heroMeta = SwiftUI.Font.callout.monospacedDigit()
        /// The estimate at the end of a Today row, "45m", and the tooltip over the ring.
        static let rowEstimate = SwiftUI.Font.footnote.monospacedDigit()
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
        /// Neutral ink at 0.06 (light) / 0.10 (dark), with the title kept in ink (design review mac-r1: crimson is for acting
        /// and for "late", not for selection).
        static var selectionFill: Color { Color(brand: Brand.ink, opacity: 0.06, darkOpacity: 0.10) }
        /// A hovered Today row (day-ring frame A): ink at 0.05 / 0.06.
        static var hoverFill: Color { Color(brand: Brand.ink, opacity: 0.05, darkOpacity: 0.06) }
        /// A small chip inside running text, such as the "30m" in the empty day's teaching line: ink at 0.07 / 0.10.
        static var chipFill: Color { Color(brand: Brand.ink, opacity: 0.07, darkOpacity: 0.10) }
        /// The dark tooltip over the ring ("Drop to plan · +45m → …"): ink, with ground-coloured text.
        static var tooltip: Color { Color(brand: Brand.ink) }
        static var onTooltip: Color { Color(brand: Brand.ground) }
        /// The Plan your day tray: ink at 0.045 / 0.04 over `surface`, the sidebar's quieter ground. Its rows are `card`.
        static var tray: Color { Color(brand: Brand.ink, opacity: 0.045, darkOpacity: 0.04) }
        static var card: Color { Color(brand: Brand.surface) }
        /// A project's identity hue: its stored colour mapped to the nearest palette pair (stored data is never
        /// rewritten), or a stable hue from its id when it has none. Inbox work is ink.
        static func project(_ record: Record?) -> ProjectHue {
            guard let record else { return ProjectPalette.inbox }
            return ProjectPalette.hue(stored: record.string("color"), projectID: record.id)
        }
    }

    enum Size {
        /// Mac density: "compact" unless the person chose "roomy" (stored values are kept).
        static let densityDefault = "compact"
        static let checkbox: CGFloat = 18
        static let iconS: CGFloat = 12
        static let iconM: CGFloat = 14
        static let iconL: CGFloat = 18
        static let rowMinHeight: CGFloat = 32
        static let rowVerticalPaddingRoomy: CGFloat = 8
        /// Compact (the Mac default): 32 pt one-line rows, about 44 pt with a note line.
        static let rowVerticalPaddingCompact: CGFloat = 6
        static func rowVerticalPadding(compact: Bool) -> CGFloat { compact ? rowVerticalPaddingCompact : rowVerticalPaddingRoomy }
        static let rowHorizontalPadding: CGFloat = Space.m
        /// The list column is capped so lines stay readable in a wide window.
        static let contentMaxWidth: CGFloat = 720
        /// Today's Plan your day tray (day-ring frame C).
        static let planTrayWidth: CGFloat = 290
        /// The colour pip after a Today row's estimate: 3 × 16 pt, full strength when done, dimmer while open.
        static let estimatePip = CGSize(width: 3, height: 16)
        static let estimatePipOpenOpacity = 0.55
        /// A day ring with a task held over it grows by this much (frame C).
        static let ringDropScale: CGFloat = 1.08
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
                        // No hairlines (design review mac-r1): groups are separated by space, so headers don't float with a rule.
                        table.floatsGroupRows = false; table.gridStyleMask = []; table.intercellSpacing = NSSize(width: 0, height: 0)
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
