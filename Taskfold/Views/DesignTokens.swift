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

    /// Dynamic Type text styles by role (Mac column).
    enum Font {
        static let screenTitle = SwiftUI.Font.title2.weight(.semibold)
        static let sectionHeader = SwiftUI.Font.subheadline.weight(.semibold)
        static let taskTitle = SwiftUI.Font.body
        /// Pair with `Palette.textSecondary`.
        static let taskNote = SwiftUI.Font.subheadline
        static let taskMeta = SwiftUI.Font.footnote
        static let chip = SwiftUI.Font.caption.weight(.medium)
        static let badge = SwiftUI.Font.caption2.weight(.semibold).monospacedDigit()
        static let inspectorLabel = SwiftUI.Font.subheadline
    }

    /// Semantic colour. Priority and accent pass through to the existing palette tables in Motion.swift.
    enum Palette {
        static var textPrimary: Color { Color(nsColor: .labelColor) }
        static var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
        static var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }
        static var separator: Color { Color(nsColor: .separatorColor) }
        static var surface: Color { Color(nsColor: .windowBackgroundColor) }
        static var surfaceRaised: Color { Color(nsColor: .controlBackgroundColor) }
        static var surfaceSunken: Color { Color(nsColor: .tertiarySystemFill) }
        static var danger: Color { .red }
        static var success: Color { .green }
        static var dateOverdue: Color { priority(1) }
        static var dateToday: Color { .green }
        static var dateTomorrow: Color { .orange }
        static var dateThisWeek: Color { .purple }
        static var dateLater: Color { textSecondary }
        /// Quick Add highlight roles: `#project` and `/section`, and `@label`.
        static var accentSecondary: Color { .teal }
        static var label: Color { .purple }
        static func priority(_ value: Int) -> Color { Color.priority(value) }
        static var accent: Color { Color.taskfold }
        /// Accent at 0.14 (light) / 0.22 (dark). A selected row keeps `textPrimary`, never white on light grey.
        static var selectionFill: Color {
            let accent = NSColor(Color.taskfold)
            return Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return accent.withAlphaComponent(dark ? 0.22 : 0.14)
            })
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
