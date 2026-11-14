import SwiftUI
import Observation

// The Today header ring and the fold-to-complete signature (design review rounds 2 and 3). One file for both apps.
// All numbers come from Core (`DayPlan.todayRing`, `Brand.Ring`); this file only draws them.

/// The day ring, as an object (round 3). Segments are today's tasks in full project colour, sized by estimate:
/// open ones are a 6pt band inside the 10pt track, done ones widen to 10pt and are lit from the top left. 2pt gaps,
/// rounded caps. There is no grey under planned work; only the unplanned remainder shows, as a dashed hairline.
/// Without working hours the whole ring is that dashed hairline until there is work.
struct TodayRingView: View {
    var ring: TodayRing
    var hue: (String) -> ProjectHue
    var size: CGFloat = Brand.Ring.size
    /// Segments drawn as done before the store says so.
    var filling: Set<String> = []
    /// Segments drawn as open although the store says done: the row is still folding toward them (round 3).
    var pending: Set<String> = []
    /// A small count on the ring, for example tasks that have no estimate (Calendar).
    var badge: Int? = nil
    /// Reports where the ring is on screen, so a folding row can fly to its segment.
    var flight: FoldFlight? = nil
    /// An overbooked day (Upcoming, Weekly review): the ring is closed and a thin crimson arc outside it is as long as the overflow.
    var showsOverflow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stroke widths scale with the ring, so a 28pt Calendar ring keeps the same proportions as the 72pt one.
    private var scale: CGFloat { size / CGFloat(Brand.Ring.size) }
    private var doneWidth: CGFloat { max(3, CGFloat(Brand.Ring.doneWidth) * scale) }
    private var openWidth: CGFloat { max(2, CGFloat(Brand.Ring.openWidth) * scale) }
    private var overflow: Double { showsOverflow ? ring.overflowFraction : 0 }
    private var overflowWidth: CGFloat { max(1, size * 3 / 68) }
    /// The ring shrinks a little to leave room for the outer arc, as in the mockup.
    private var overflowScale: CGFloat { overflow > 0 ? 1 - 2 * (overflowWidth + max(0.5, overflowWidth / 2)) / size : 1 }

    var body: some View {
        let diameter = size - doneWidth
        let circumference = Double.pi * Double(diameter)
        ZStack {
            // The unplanned remainder only: a dashed hairline. Planned work never has grey under it.
            let rest = ring.remainder
            if rest.length > 0.0005 {
                Circle().trim(from: rest.start, to: rest.start + rest.length).rotation(.degrees(-90))
                    .stroke(DS.Palette.textTertiary, style: StrokeStyle(lineWidth: CGFloat(Brand.Ring.remainderWidth), lineCap: .round, dash: [2, 3]))
            }
            ForEach(ring.segments) { segment in
                let done = (segment.done && !pending.contains(segment.id)) || filling.contains(segment.id)
                let width = done ? doneWidth : openWidth
                // Round caps reach half a stroke past each end, so inset by that plus half the 2pt gap.
                let inset = (Double(Brand.Ring.gap) * Double(scale) / 2 + Double(width) / 2) / circumference
                let gapless = ring.segments.count == 1 && segment.length >= 0.999
                let mid = segment.start + segment.length / 2
                let from = gapless ? 0 : min(mid, segment.start + inset), to = gapless ? 1 : max(mid, segment.start + segment.length - inset)
                let colour = hue(segment.projectID).color
                let arc = Circle().trim(from: from, to: to).rotation(.degrees(-90))
                ZStack {
                    arc.stroke(colour, style: StrokeStyle(lineWidth: width, lineCap: gapless ? .butt : .round))
                    // Done segments are lit: a highlight from the top left, within the hue.
                    arc.stroke(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0)], startPoint: .topLeading, endPoint: .center),
                               style: StrokeStyle(lineWidth: width, lineCap: gapless ? .butt : .round))
                        .opacity(done ? 1 : 0)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .frame(width: size, height: size)
        .scaleEffect(overflowScale)
        .overlay {
            if overflow > 0 {
                Circle().inset(by: overflowWidth / 2).trim(from: 0, to: overflow).rotation(.degrees(-90))
                    .stroke(DS.Palette.dateOverdue, style: StrokeStyle(lineWidth: overflowWidth, lineCap: .round))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let badge, badge > 0 {
                Text("\(badge)").font(.system(size: max(9, 11 * scale), weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(brand: Brand.ground)).padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                    .background(DS.Palette.textSecondary, in: Capsule())
                    .offset(x: 6, y: -4)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in flight?.ringFrame = frame; flight?.ring = ring }
        .onChange(of: ring) { _, value in flight?.ring = value }
        .onAppear { flight?.ring = ring }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.18), value: ring)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.3), value: filling)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.3), value: pending)
        .accessibilityHidden(true)
    }
}

/// Today's header: the 72pt ring, "Saturday 14 Nov" over "4h 10m of 6h", and Plan (or "Set hours" when there are no
/// working hours). The ring and its text are one VoiceOver element carrying the figures; the button is its own target.
/// At accessibility sizes (round 3) the ring sits above one wrapped sentence, "4h 10m of 6h planned", and Plan moves
/// to the toolbar (`showsPlanButton` false), so nothing reaches the capture capsule.
struct TodayHeader: View {
    var ring: TodayRing
    var date: Date
    var hue: (String) -> ProjectHue
    var filling: Set<String> = []
    var pending: Set<String> = []
    var flight: FoldFlight? = nil
    var plan: () -> Void
    var setHours: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        if textSize.isAccessibilitySize { stacked } else { regular }
    }
    private var dateText: String { date.formatted(.dateTime.weekday(.wide)) + " " + date.formatted(.dateTime.day().month(.abbreviated)) }
    private var ringView: some View { TodayRingView(ring: ring, hue: hue, filling: filling, pending: pending, flight: flight) }
    private var regular: some View {
        HStack(alignment: .center, spacing: DS.Space.l) {
            HStack(alignment: .center, spacing: DS.Space.l) {
                ringView
                VStack(alignment: .leading, spacing: 1) {
                    // "Saturday 14 Nov": sentence case, no comma, never an eyebrow.
                    Text(dateText).font(DS.Font.dateLine).foregroundStyle(DS.Palette.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(ring.figure).foregroundStyle(DS.Palette.textPrimary)
                        Text(ring.capacity ?? "planned").fontWeight(.medium).foregroundStyle(DS.Palette.textSecondary)
                    }
                    .font(DS.Font.ringFigure).lineLimit(1).minimumScaleFactor(0.6)
                }
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            }
            .modifier(RingSummaryAccessibility(date: date, ring: ring))
            Spacer(minLength: 0)
            Button(action: ring.hasWorkingHours ? plan : setHours) {
                Text(ring.hasWorkingHours ? "Plan" : "Set hours")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.brandCrimson)
                    .padding(.horizontal, 14).frame(minHeight: 32)
                    .background(Color.brandCrimson.opacity(0.1), in: Capsule())
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(ring.hasWorkingHours ? "Opens Plan your day" : "Sets your working hours so the ring can show free time")
            .accessibilityIdentifier(ring.hasWorkingHours ? "planDay" : "setWorkingHours")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Accessibility sizes: the ring, then one sentence that wraps, then the date. Plan is in the toolbar.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ringView
            Text(ring.figure + " " + (ring.capacity.map { $0 + " planned" } ?? "planned"))
                .font(.title3.weight(.semibold).width(.expanded)).foregroundStyle(DS.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(dateText).font(DS.Font.dateLine).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .modifier(RingSummaryAccessibility(date: date, ring: ring))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RingSummaryAccessibility: ViewModifier {
    var date: Date
    var ring: TodayRing
    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ". " + ring.accessibilityLabel)
            .accessibilityIdentifier("todayRing")
    }
}

// MARK: - The ring on every list (design review round 6)

/// "4h 10m of 6h": a bold lead and a secondary rest. An overbooked day leads in crimson: "1h 30m over · 7h 30m of 6h".
struct DayFigureText: View {
    var figure: DayFigure
    var body: some View {
        Text(figure.lead).fontWeight(.semibold).foregroundStyle(figure.leadIsAlert ? DS.Palette.dateOverdue : DS.Palette.textPrimary)
            + Text(figure.rest).foregroundStyle(DS.Palette.textSecondary)
    }
}

/// An Upcoming day header: a 20pt ring, the day name and date, and the figure on the right. When the figure no longer
/// fits beside the name (large text, a long overbooked line) it wraps below the name instead of truncating.
struct DayRingHeader: View {
    var name: String
    var detail: String
    var nameColor: Color = DS.Palette.textPrimary
    var ring: TodayRing
    /// A day off draws only the dashed outline.
    var dayOff = false
    var figure: DayFigure
    var spoken: String
    var hue: (String) -> ProjectHue
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .subheadline) private var ringSize = 20

    private var ringView: some View { TodayRingView(ring: dayOff ? ring.outline : ring, hue: hue, size: ringSize, showsOverflow: true) }
    private var title: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            ringView
            Text(name).font(DS.Font.sectionHeader).foregroundStyle(nameColor).lineLimit(1)
            if !detail.isEmpty { Text(detail).font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).lineLimit(1) }
        }
    }
    private var hasFigure: Bool { !figure.text.isEmpty }
    private var figureText: some View { DayFigureText(figure: figure).font(.footnote.monospacedDigit()) }
    var body: some View {
        Group {
            if !hasFigure {
                title
            } else if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DS.Space.xs) { title; figureText.fixedSize(horizontal: false, vertical: true) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: DS.Space.s) { title; Spacer(minLength: DS.Space.s); figureText.lineLimit(1) }
                    VStack(alignment: .leading, spacing: DS.Space.xs) { title; figureText.fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// Under a project's large title: a 28pt ring of its estimated work due this week, "1h 30m of 5h 45m this week", and one
/// plain sentence about its share of the planned week. The ring and both lines are one VoiceOver element.
struct ProjectWeekHeader: View {
    var week: ProjectWeekRing
    var hue: (String) -> ProjectHue
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .headline) private var ringSize = 28
    private var figure: Text {
        Text(week.figure).foregroundStyle(DS.Palette.textPrimary) + Text(" " + week.rest).fontWeight(.medium).foregroundStyle(DS.Palette.textSecondary)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if textSize.isAccessibilitySize {
                TodayRingView(ring: week.ring, hue: hue, size: ringSize)
                figure.font(.headline.width(.expanded).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    TodayRingView(ring: week.ring, hue: hue, size: ringSize)
                    figure.font(.headline.width(.expanded).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let line = week.shareLine { Text(line).font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(week.accessibilityLabel)
        .accessibilityIdentifier("projectWeekRing")
    }
}

/// The Weekly review intro: seven 38pt day rings (the day letter under each, today's crimson and bold, a dashed ring for a
/// day off), then "19h 40m done of 28h planned · 9–15 Nov" and one sentence. Each ring is one VoiceOver element.
struct WeekRingsCard: View {
    var summary: WeekSummary
    var hue: (String) -> ProjectHue
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The date range lives here, nowrap, so the figure line below never wraps awkwardly.
            Text(captionText).font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 2) {
                ForEach(summary.days) { day in
                    VStack(spacing: 5) {
                        TodayRingView(ring: day.isDayOff ? day.ring.outline : day.ring, hue: hue, size: 38, showsOverflow: true)
                        Text(day.letter).font(.caption.weight(day.isToday ? .bold : .semibold)).foregroundStyle(day.isToday ? DS.Palette.dateOverdue : DS.Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.accessibilityLabel)
                    .accessibilityIdentifier("weekRing-" + day.key)
                }
            }
            if summary.isEmpty {
                Text(summary.emptyLine).font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12).padding(.horizontal, 4)
            } else {
                Group {
                    if textSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 2) { figure; rest }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) { figure; rest }
                    }
                }
                .padding(.top, 12).padding(.horizontal, 4)
                if let sentence = summary.sentence {
                    Text(sentence).font(.footnote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3).padding(.horizontal, 4)
                }
            }
        }
        .padding(.top, 14).padding(.bottom, 12).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Palette.textPrimary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weekRings")
    }
    private var figure: some View {
        Text(summary.figure).font(.title3.weight(.semibold).width(.expanded).monospacedDigit()).foregroundStyle(DS.Palette.textPrimary).lineLimit(1).fixedSize()
    }
    private var rest: some View {
        Text(summary.rest).font(.subheadline).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    /// "This week · 9–15 Nov", with non-breaking spaces and word joiners so the range never splits.
    private var captionText: String {
        let range = summary.rangeLabel.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "–", with: "\u{2060}–\u{2060}")
        return "This week · " + range
    }
}

// MARK: - Fold to complete (the signature)

enum FoldMotion {
    /// DEBUG `--slow-fold` stretches the fold twelve times so frames can be captured mid-crease and mid-flight.
    static var slowFactor: Double {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--slow-fold") ? 12 : 1
        #else
        1
        #endif
    }
    /// The crease: the row's halves fold flat about its midline.
    static var creaseDuration: Double { 0.18 * slowFactor }
    /// The flight: the folded strip travels along a curve to its own segment. Crease plus flight is about 480 ms,
    /// inside the 500 ms the completed row lingers.
    static var flightDuration: Double { 0.30 * slowFactor }
    /// The whole fold, for lists without a ring.
    static var duration: Double { creaseDuration + flightDuration }
}

/// Where rows fold to (round 3). The Today ring reports its frame and segments; a folding row asks for its segment's
/// point and launches a strip that flies there on the screen-level `FoldFlightLayer`. The ring row and the task rows
/// live in different list cells, where preferences and anchors do not cross, so both sides measure in the global
/// space with `onGeometryChange` and meet here.
@MainActor @Observable final class FoldFlight {
    struct Flight: Identifiable, Equatable {
        let id: String
        var from: CGRect
        var to: CGPoint
        var hue: ProjectHue
    }
    private(set) var flights: [Flight] = []
    /// Segments whose row has arrived. A landed segment widens and lights.
    private(set) var landed: Set<String> = []
    @ObservationIgnored var ringFrame: CGRect = .zero
    @ObservationIgnored var ring: TodayRing?
    /// Called when a strip lands (the medium haptic).
    @ObservationIgnored var onLand: (() -> Void)?

    /// The centre of a task's segment on screen, or nil when the task has no segment or the ring is not on screen.
    func target(for id: String) -> CGPoint? {
        guard let ring, let fraction = ring.midpoint(of: id), ringFrame.width > 0 else { return nil }
        let radius = (ringFrame.width - CGFloat(Brand.Ring.doneWidth) * ringFrame.width / CGFloat(Brand.Ring.size)) / 2
        let angle = fraction * 2 * Double.pi
        return CGPoint(x: ringFrame.midX + radius * CGFloat(sin(angle)), y: ringFrame.midY - radius * CGFloat(cos(angle)))
    }
    /// Whether a row for `id` will fly, so its segment waits for it.
    func flies(_ id: String) -> Bool { target(for: id) != nil }
    @discardableResult func launch(id: String, from frame: CGRect, hue: ProjectHue) -> Bool {
        guard let to = target(for: id) else { return false }
        landed.remove(id)
        flights.removeAll { $0.id == id }
        flights.append(Flight(id: id, from: frame, to: to, hue: hue))
        return true
    }
    func land(_ id: String) {
        guard flights.contains(where: { $0.id == id }) else { return }
        flights.removeAll { $0.id == id }
        landed.insert(id)
        onLand?()
    }
    /// Undo: the row came back, so nothing lands.
    func cancel(_ id: String) { flights.removeAll { $0.id == id }; landed.remove(id) }
}

extension EnvironmentValues {
    @Entry var foldFlight: FoldFlight? = nil
}

/// The strips in flight, drawn above the list. Not hit-testable and hidden from accessibility.
struct FoldFlightLayer: View {
    var model: FoldFlight
    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ForEach(model.flights) { flight in
                FoldStrip(flight: flight, origin: origin) { model.land(flight.id) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One folded strip on its way: it leaves the row's midline as a paper strip, takes on the project colour and narrows
/// to the segment's width as it curves up to the segment, then lands.
private struct FoldStrip: View {
    var flight: FoldFlight.Flight
    var origin: CGPoint
    var landed: () -> Void
    @State private var progress: Double = 0
    var body: some View {
        Color.clear
            .modifier(FoldStripPath(progress: progress, from: CGRect(origin: CGPoint(x: flight.from.minX - origin.x, y: flight.from.minY - origin.y), size: flight.from.size),
                                    to: CGPoint(x: flight.to.x - origin.x, y: flight.to.y - origin.y), colour: flight.hue.color))
            .task {
                withAnimation(.spring(duration: FoldMotion.flightDuration, bounce: 0.12), completionCriteria: .logicallyComplete) { progress = 1 } completion: { landed() }
            }
    }
}

/// Position, size and colour of a strip at `progress` along a quadratic curve: across from the row to the ring's
/// column, then up to the segment. Animatable, so the spring drives the path itself.
private struct FoldStripPath: ViewModifier, Animatable {
    var progress: Double
    var from: CGRect
    var to: CGPoint
    var colour: Color
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let t = CGFloat(min(1.1, max(0, progress)))
        let start = CGPoint(x: from.minX + min(from.width, 220) / 2 + 16, y: from.midY)
        // Slide along the row's own line to the ring's column, then rise into the segment, so the strip never crosses the date text beside the ring.
        let control = CGPoint(x: to.x, y: start.y)
        let u = 1 - t
        let point = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * to.x, y: u * u * start.y + 2 * u * t * control.y + t * t * to.y)
        let width = max(CGFloat(Brand.Ring.doneWidth), (1 - t) * min(from.width, 220) + t * CGFloat(Brand.Ring.doneWidth))
        let height = 6 + 4 * t
        return ZStack {
            Capsule().fill(DS.Palette.surfaceRaised).shadow(color: .black.opacity(0.18 * Double(1 - t)), radius: 4, y: 2)
            Capsule().fill(colour).opacity(Double(min(1, t * 1.6)))
        }
        .frame(width: width, height: height)
        .position(point)
    }
}

/// Ticking a task folds its row: it creases along its midline and the two halves fold flat (rotation3DEffect, the
/// lower half shaded). On Today (`flight` set and the task has a segment) the folded strip then flies to its own
/// segment on the ring, which widens on arrival. Elsewhere the strip fades where it is. Reduce Motion: the row fades.
/// The animated copies are hidden from accessibility and hit testing; the real row stays in place, transparent.
struct FoldAway: ViewModifier {
    var active: Bool
    var towardRing = false
    /// The task and its hue, so the strip knows where to fly and what colour it becomes.
    var id: String? = nil
    var hue: ProjectHue? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.foldFlight) private var flight
    @State private var fold: Double = 0
    @State private var travel: Double = 0
    @State private var launched = false
    @State private var frame = FrameBox()
    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(active ? 0 : 1).animation(.easeOut(duration: FoldMotion.duration * 0.6), value: active)
        } else {
            content
                .opacity(active ? 0 : 1)
                .overlay {
                    if active && !launched {
                        content.modifier(FoldHalves(fold: fold, travel: travel, towardRing: towardRing))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
                // A lingering row can be a fresh view that is already active, so start the fold one frame after it appears.
                .task(id: active) {
                    fold = 0; travel = 0; launched = false
                    guard active else { return }
                    try? await Task.sleep(for: .milliseconds(16))
                    let crease = FoldMotion.creaseDuration
                    let flies = towardRing && id.map { flight?.flies($0) == true } == true
                    withAnimation(.spring(duration: crease, bounce: 0.08)) { fold = 1 }
                    if flies, let id, let flight {
                        try? await Task.sleep(for: .seconds(crease * 0.92))
                        guard !Task.isCancelled else { return }
                        if flight.launch(id: id, from: frame.rect, hue: hue ?? ProjectPalette.inbox) { launched = true; return }
                    }
                    withAnimation(.spring(duration: FoldMotion.flightDuration, bounce: 0.05).delay(crease * 0.8)) { travel = 1 }
                }
        }
    }
}

/// A row's frame, kept out of view state so scrolling never re-renders the row.
final class FrameBox { var rect: CGRect = .zero }

/// The two halves of a folding row: each half turns about the midline crease, the lower one in shadow, until the row
/// is a strip. Without a flight the strip then shrinks and fades in place.
struct FoldHalves: ViewModifier {
    var fold: Double
    var travel: Double
    var towardRing: Bool
    func body(content: Content) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            VStack(spacing: 0) {
                content.frame(width: w, height: h, alignment: .top).frame(width: w, height: h / 2, alignment: .top).clipped()
                    .overlay(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.10 * fold)], startPoint: .top, endPoint: .bottom))
                    .rotation3DEffect(.degrees(-84 * fold), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.85)
                content.frame(width: w, height: h, alignment: .bottom).frame(width: w, height: h / 2, alignment: .bottom).clipped()
                    .overlay(LinearGradient(colors: [.black.opacity(0.28 * fold), .black.opacity(0.12 * fold)], startPoint: .top, endPoint: .bottom))
                    .rotation3DEffect(.degrees(84 * fold), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.85)
            }
            .scaleEffect(x: 1 - 0.6 * travel, y: 1, anchor: .leading)
            .opacity(1 - travel)
        }
    }
}
