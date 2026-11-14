import SwiftUI

// The Today header ring (design review, redesign round 2) and the fold-to-complete signature. One file for both apps.
// All numbers come from Core (`DayPlan.todayRing`, `Brand`); this file only draws them.

/// A ring whose segments are today's tasks in their project colours, sized by estimate. Done segments are full colour,
/// open ones a 35% tint, and the track left over is free capacity. Without working hours the track is dashed.
struct TodayRingView: View {
    var ring: TodayRing
    var hue: (String) -> ProjectHue
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7
    /// Segments drawn as done before the store says so: the row folding into them right now.
    var filling: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // A hairline gap between neighbouring segments, as a fraction of the circumference.
        let gap = ring.segments.count > 1 ? Double(lineWidth * 0.22) / (Double.pi * Double(size - lineWidth)) : 0
        ZStack {
            Circle().stroke(ring.hasWorkingHours ? DS.Palette.surfaceSunken : DS.Palette.textTertiary,
                            style: StrokeStyle(lineWidth: ring.hasWorkingHours ? lineWidth : max(1.5, lineWidth * 0.3), dash: ring.hasWorkingHours ? [] : [3, 4]))
            ForEach(ring.segments) { segment in
                let from = segment.start + gap / 2, to = max(segment.start + gap / 2, segment.start + segment.length - gap / 2)
                Circle().trim(from: from, to: to)
                    .stroke(hue(segment.projectID).color.opacity(segment.done || filling.contains(segment.id) ? 1 : Brand.openSegmentOpacity),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.12), value: ring)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.12), value: filling)
        .accessibilityHidden(true)
    }
}

/// Today's header: the 64pt ring, "Saturday 14 Nov" over "4h 10m of 6h", and Plan (or "Set hours" when there are no
/// working hours). The ring and its text are one VoiceOver element carrying the figures; the button is its own target.
struct TodayHeader: View {
    var ring: TodayRing
    var date: Date
    var hue: (String) -> ProjectHue
    var filling: Set<String> = []
    var plan: () -> Void
    var setHours: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        let stacked = textSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.m)) : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.l))
        layout {
            let summary = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s)) : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.l))
            summary {
                TodayRingView(ring: ring, hue: hue, filling: filling)
                VStack(alignment: .leading, spacing: 1) {
                    // "Saturday 14 Nov": sentence case, no comma, never an eyebrow.
                    Text(date.formatted(.dateTime.weekday(.wide)) + " " + date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(DS.Font.dateLine).foregroundStyle(DS.Palette.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(ring.figure).foregroundStyle(DS.Palette.textPrimary)
                        Text(ring.capacity ?? "planned").fontWeight(.medium).foregroundStyle(DS.Palette.textSecondary)
                    }
                    .font(DS.Font.ringFigure).lineLimit(stacked ? nil : 1).minimumScaleFactor(0.8)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide)) + ". " + ring.accessibilityLabel)
            .accessibilityIdentifier("todayRing")
            if !stacked { Spacer(minLength: 0) }
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
}
