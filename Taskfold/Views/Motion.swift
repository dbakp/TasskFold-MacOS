import SwiftUI
import AppKit

/// The iOS motion vocabulary tuned for the desktop: the same set of tokens, shorter and with less bounce,
/// because a pointer is more precise than a finger and a large window magnifies overshoot.
enum Motion {
    /// Rows entering, leaving, or moving.
    static let layout = Animation.spring(duration: 0.3, bounce: 0.08)
    /// State flips: checks, chevrons, selection.
    static let quick = Animation.spring(duration: 0.18, bounce: 0.04)
    /// A card lifting off the surface.
    static let lift = Animation.spring(duration: 0.22, bounce: 0.14)
    /// A card settling after a drop.
    static let settle = Animation.spring(duration: 0.32, bounce: 0.1)
    /// Something following the pointer.
    static let track = Animation.interactiveSpring(response: 0.14, dampingFraction: 0.9)

    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? .easeInOut(duration: 0.12) : animation
    }
}

/// Trackpad feedback only where the Mac convention expects it: an alignment tick as a drag crosses a slot,
/// and a level change when something lands or completes. Nothing fires for plain clicks.
@MainActor
enum Feedback {
    private static var performer: NSHapticFeedbackPerformer { NSHapticFeedbackManager.defaultPerformer }
    /// Insertion point moved to a new slot.
    static func tick() { performer.perform(.alignment, performanceTime: .now) }
    /// A dragged task landed.
    static func drop() { performer.perform(.levelChange, performanceTime: .now) }
    /// A task was completed.
    static func complete() { performer.perform(.levelChange, performanceTime: .drawCompleted) }
}

/// Gentle scale-and-dim press feedback for clickable surfaces that are not system buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.985
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// Springy icon button: the check control and other single-glyph controls.
struct GlyphStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .contentShape(.rect)
    }
}

extension View {
    /// Applies a shared animation only when Reduce Motion is off.
    func motion<V: Equatable>(_ animation: Animation, value: V, reduceMotion: Bool) -> some View {
        self.animation(Motion.respecting(reduceMotion, animation), value: value)
    }
}

/// The surface behind a task card in the calendar and drag previews. Continuous corners, hairline edge.
struct CardSurface: ViewModifier {
    var radius: CGFloat = 10
    var elevated = false
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(elevated ? 0.4 : 0.7), lineWidth: 1))
            .shadow(color: .black.opacity(elevated ? 0.22 : 0.04), radius: elevated ? 18 : 1.5, y: elevated ? 10 : 1)
    }
}

/// A subtle hover wash for rows that are not inside a system List.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    var radius: CGFloat = 8
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
    }
}

extension Color {
    static let taskfold = Color(red: 0.88, green: 0.12, blue: 0.30)
    static func priority(_ value: Int) -> Color { [1: .red, 2: .orange, 3: .blue, 4: .secondary][value] ?? .secondary }
    static func project(_ value: String) -> Color {
        let names: [String: Color] = ["red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "blue": .blue, "purple": .purple, "pink": .pink, "gray": .gray, "teal": .teal, "berry_red": .taskfold, "charcoal": .gray]
        if let color = names[value] { return color }
        let hex = value.replacingOccurrences(of: "#", with: "")
        if let number = UInt64(hex, radix: 16), hex.count == 6 { return Color(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255) }
        return .taskfold
    }
}

/// A drawn check control following the transitions.dev checkbox and success-check recipes: the ring carries the
/// priority colour, the fill lands in 150 ms, and the check path draws over 350 ms with smooth-out easing. When
/// a task is completed the glyph also settles in from a slight rotation and blur so the moment reads as a success.
struct CheckMark: View {
    var checked: Bool
    var color: Color
    var emphasized: Bool
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().strokeBorder(color.opacity(emphasized ? 0.9 : 0.55), lineWidth: emphasized ? 1.6 : 1.3)
                .opacity(checked ? 0 : 1)
                .animation(Transitions.Ease.smoothOut(Transitions.Duration.quick), value: checked)
            Circle().fill(checked ? (emphasized ? color : Color.taskfold) : .clear)
                .scaleEffect(checked ? 1 : 0.6)
                .animation(Transitions.Ease.smoothOut(Transitions.Duration.quick), value: checked)
            DrawnCheck()
                .trim(from: 0, to: checked ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.6, size * 0.11), lineCap: .round, lineJoin: .round))
                .rotationEffect(.degrees(checked || reduceMotion ? 0 : 80))
                .blur(radius: checked || reduceMotion ? 0 : Transitions.Blur.large * 0.4)
                .opacity(checked ? 1 : 0)
                .animation(checked ? Transitions.Ease.smoothOut(Transitions.Duration.medium).delay(reduceMotion ? 0 : Transitions.Duration.micro) : Transitions.Ease.smoothOut(Transitions.Duration.quick), value: checked)
        }
        .frame(width: size, height: size)
    }
}

struct TaskfoldMark: View {
    var size: CGFloat = 72
    var body: some View {
        Image(systemName: "checkmark.rectangle.stack.fill")
            .font(.system(size: size * 0.46, weight: .medium)).symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.taskfold).frame(width: size, height: size)
            .background(Color.taskfold.opacity(0.1), in: .rect(cornerRadius: size * 0.28, style: .continuous))
    }
}
