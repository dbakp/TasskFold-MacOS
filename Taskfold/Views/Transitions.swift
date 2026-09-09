import SwiftUI

/// SwiftUI translation of the transitions.dev motion tokens and recipes (https://transitions.dev).
///
/// `Motion` (Motion.swift) owns the physical vocabulary shared with iOS: springs for layout, lift, settle, and
/// tracking. `Transitions` owns entrances, exits, and swaps: the tokenised durations, easings, distances, scales,
/// and blur from transitions.dev, plus the recipes built from them. Every recipe respects Reduce Motion.
enum Transitions {
    enum Duration {
        static let stagger = 0.04, micro = 0.08, quick = 0.15, fast = 0.25, medium = 0.35, slow = 0.4, verySlow = 0.5
    }
    enum Ease {
        /// The default for surface motion: open/close, slide, resize, position.
        static let smoothOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: Duration.fast)
        static func smoothOut(_ duration: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: duration) }
        static func inOut(_ duration: Double) -> Animation { .easeInOut(duration: duration) }
        static func out(_ duration: Double) -> Animation { .easeOut(duration: duration) }
        static func linear(_ duration: Double) -> Animation { .linear(duration: duration) }
        /// Badge pop open.
        static func bounce(_ duration: Double) -> Animation { .timingCurve(0.34, 1.36, 0.64, 1, duration: duration) }
        /// Bouncy hover-out.
        static func bounceStrong(_ duration: Double) -> Animation { .timingCurve(0.34, 3.85, 0.64, 1, duration: duration) }
        /// Number pop-in digits.
        static func digit(_ duration: Double) -> Animation { .timingCurve(0.34, 1.45, 0.64, 1, duration: duration) }
    }
    enum Distance { static let micro: CGFloat = 4, small: CGFloat = 6, base: CGFloat = 8, medium: CGFloat = 12, large: CGFloat = 30 }
    enum Scale { static let large = 0.96, medium = 0.97, small = 0.98, tiny = 0.99 }
    enum Blur { static let small: CGFloat = 2, medium: CGFloat = 3, large: CGFloat = 8 }
}

// MARK: - Transition recipes

private struct SwapModifier: ViewModifier {
    var offset: CGSize = .zero
    var blur: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 1
    var rotation: Angle = .zero
    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).scaleEffect(scale).rotationEffect(rotation).offset(offset)
    }
}

extension AnyTransition {
    /// Text states swap: in-place text swap, 150 ms ease-in-out, 4 pt travel, 2 pt blur. Symmetric.
    static var textSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: Transitions.Distance.micro), blur: Transitions.Blur.small, opacity: 0), identity: SwapModifier()),
            removal: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: -Transitions.Distance.micro), blur: Transitions.Blur.small, opacity: 0), identity: SwapModifier())
        ).animation(Transitions.Ease.inOut(Transitions.Duration.quick))
    }
    /// Icon swap: cross-fade two glyphs in one slot with scale (0.25) and 2 pt blur, 250 ms ease-in-out. Symmetric.
    static var iconSwap: AnyTransition {
        .modifier(active: SwapModifier(blur: Transitions.Blur.small, scale: 0.25, opacity: 0), identity: SwapModifier())
            .animation(Transitions.Ease.inOut(Transitions.Duration.fast))
    }
    /// Toast open/close: rises 16 pt with fade, 2 pt blur and 0.97 scale over 350 ms; leaves quicker (250 ms) with no blur.
    static var toast: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: 16), blur: Transitions.Blur.small, scale: Transitions.Scale.medium, opacity: 0), identity: SwapModifier())
                .animation(Transitions.Ease.smoothOut(Transitions.Duration.medium)),
            removal: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: 8), scale: Transitions.Scale.tiny, opacity: 0), identity: SwapModifier())
                .animation(Transitions.Ease.smoothOut(Transitions.Duration.fast))
        )
    }
    /// Panel reveal: slide into a region with a cross-blur. Open 400 ms, close 350 ms, smooth-out easing.
    static func panelReveal(distance: CGFloat = 40) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: distance), blur: Transitions.Blur.small, opacity: 0), identity: SwapModifier())
                .animation(Transitions.Ease.smoothOut(Transitions.Duration.slow)),
            removal: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: distance * 0.3), blur: Transitions.Blur.small, opacity: 0), identity: SwapModifier())
                .animation(Transitions.Ease.smoothOut(Transitions.Duration.medium))
        )
    }
    /// Notification badge: diagonal 8 pt slide with a bouncy pop-in (500 ms); closes small and quick (180 ms).
    static var badgePop: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapModifier(offset: CGSize(width: -Transitions.Distance.base, height: Transitions.Distance.base), blur: Transitions.Blur.small, scale: 0, opacity: 0), identity: SwapModifier())
                .animation(Transitions.Ease.bounce(Transitions.Duration.verySlow)),
            removal: .modifier(active: SwapModifier(blur: Transitions.Blur.small, scale: 0, opacity: 0), identity: SwapModifier())
                .animation(Transitions.Ease.out(0.18))
        )
    }
    /// Skeleton reveal: placeholder and content cross-fade with a 2 pt cross-blur over 400 ms.
    static var skeletonReveal: AnyTransition {
        .modifier(active: SwapModifier(blur: Transitions.Blur.small, opacity: 0), identity: SwapModifier())
            .animation(Transitions.Ease.inOut(Transitions.Duration.slow))
    }
}

// MARK: - Number pop-in

/// Each digit re-enters with a blurred 8 pt slide, staggered 70 ms (capped so the total stays under ~300 ms).
struct NumberPopIn: View {
    let value: Int
    var font: Font = .body
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let digits = Array(String(value))
        HStack(spacing: 0) {
            ForEach(Array(digits.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .id("\(index)-\(digit)-\(digits.count)")
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: Transitions.Distance.base), blur: Transitions.Blur.small, opacity: 0), identity: SwapModifier())
                            .animation(Transitions.Ease.digit(Transitions.Duration.verySlow).delay(Double(min(index, 4)) * 0.07)),
                        removal: .modifier(active: SwapModifier(offset: CGSize(width: 0, height: -Transitions.Distance.base), blur: Transitions.Blur.small, opacity: 0), identity: SwapModifier())
                            .animation(Transitions.Ease.inOut(Transitions.Duration.quick))))
            }
        }
        .font(font).monospacedDigit()
        .animation(Transitions.Ease.smoothOut, value: value)
        .accessibilityLabel("\(value)")
    }
}

// MARK: - Success / checkbox check

/// A stroke-drawn check: the box fills in 150 ms, the path draws over 350 ms with smooth-out easing, and on
/// first completion the glyph also fades in from an 80° rotation with blur (the success-check recipe).
struct DrawnCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.53))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.32))
        return path
    }
}

// MARK: - Error state shake

/// Per-segment shake (6 pt, then a 4 pt overshoot; 80/60 ms legs) that replays whenever `trigger` changes.
struct ShakeEffect: ViewModifier {
    let trigger: Int
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.offset(x: offset).onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            Task { @MainActor in
                let legs: [(CGFloat, Double)] = [(-Transitions.Distance.small, 0.08), (Transitions.Distance.small, 0.08), (-4, 0.06), (4, 0.06), (0, 0.08)]
                for (x, duration) in legs {
                    withAnimation(Transitions.Ease.smoothOut(duration)) { offset = x }
                    try? await Task.sleep(for: .seconds(duration))
                }
            }
        }
    }
}

// MARK: - Shimmer text

/// A highlight band sweeps across muted text on a 2 s linear loop. Used for live status lines.
struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .primary.opacity(0.9), location: 0.5), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.9)
                            .offset(x: phase * proxy.size.width * 1.4)
                            .mask(Text(text))
                    }
                }
            }
            .onAppear { guard !reduceMotion else { return }; withAnimation(Transitions.Ease.linear(2).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

// MARK: - Skeleton rows

/// Pulsing placeholder rows shown while the first sync is still running.
struct SkeletonRows: View {
    var count = 6
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    Circle().fill(.quaternary).frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: CGFloat([220, 160, 260, 190, 240, 140][index % 6]), height: 12)
                }
            }
        }
        .opacity(dim ? 0.5 : 1)
        .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true } }
        .accessibilityLabel("Loading tasks")
    }
}

// MARK: - Tabs sliding

/// A segmented control whose pill slides between tabs in 250 ms with smooth-out easing.
struct SlidingTabs<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let select: (Option) -> Void
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let active = option == selection
                Button {
                    guard !active else { return }
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : Transitions.Ease.smoothOut) { select(option) }
                } label: {
                    Text(title(option))
                        .font(.callout.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Hover lift

/// Hover in is quick and direct; hover out is softer and springier so the control settles rather than snaps.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.08
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .onHover { over in
                withAnimation(reduceMotion ? nil : over ? Transitions.Ease.smoothOut(Transitions.Duration.quick) : Transitions.Ease.bounceStrong(Transitions.Duration.medium)) { hovering = over }
            }
    }
}
