import SwiftUI

// The lighter Mac (design review mac-r1): every list opens with one title line in the content, Fraunces 28 over a
// 13 pt secondary line, and nothing else above the tasks. Controls live in the toolbar, the menus and the inspector.

/// "Today" over "Thursday 19 November", with optional trailing content on the same line (the ring, a figure, Plan).
struct ListTitleHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    /// A project's colour dot before the title.
    var dot: ProjectHue? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(alignment: .center, spacing: DS.Space.s + DS.Space.xxs) {
                    if let dot { Circle().fill(dot.color).frame(width: 10, height: 10).accessibilityHidden(true) }
                    Text(title).font(DS.Font.contentTitle).foregroundStyle(DS.Palette.textPrimary).lineLimit(2)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("listTitle")
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(DS.Font.dateLine).foregroundStyle(DS.Palette.textSecondary).monospacedDigit().lineLimit(1)
                        .accessibilityIdentifier("listSubtitle")
                }
            }
            Spacer(minLength: DS.Space.l)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ListTitleHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, dot: ProjectHue? = nil) {
        self.init(title: title, subtitle: subtitle, dot: dot) { EmptyView() }
    }
}

/// A 28 pt day ring. With nothing estimated it is a quiet full hairline track, not a dashed circle, so it never reads as a
/// spinner; "No estimates" shows on hover.
struct InlineDayRing: View {
    var ring: TodayRing
    var hue: (String) -> ProjectHue
    var size: CGFloat = 28
    var pending: Set<String> = []
    var flight: FoldFlight? = nil
    @AppStorage(DayRingSetting.key) private var showRing = true
    var body: some View {
        if showRing {
            Group {
                if ring.segments.isEmpty {
                    Circle().strokeBorder(Color(brand: Brand.ink, opacity: 0.12, darkOpacity: 0.2), lineWidth: 2.5)
                        .frame(width: size, height: size)
                        .help(ring.hasWorkingHours ? "No estimates" : "No working hours set")
                } else {
                    TodayRingView(ring: ring, hue: hue, size: size, pending: pending, flight: flight)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Today's trailing title content: the ring, "0m of 8h" in tabular SF, and one text button, Plan, which becomes
/// "Shut down" once working hours are over (owner decision 3). Without working hours it offers "Set hours".
struct TodayTitleTrailing: View {
    @Environment(Store.self) private var store
    var ring: TodayRing
    var hue: (String) -> ProjectHue
    var pending: Set<String> = []
    var flight: FoldFlight? = nil
    let plan: () -> Void
    let shutdown: () -> Void
    let setHours: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s + DS.Space.xxs) {
            InlineDayRing(ring: ring, hue: hue, pending: pending, flight: flight)
            (Text(ring.figure).fontWeight(.semibold).foregroundStyle(DS.Palette.textPrimary)
             + Text(" " + (ring.capacity ?? "planned")).foregroundStyle(DS.Palette.textSecondary))
                .font(DS.Font.ringFigure).lineLimit(1).fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ring.accessibilityLabel)
                .accessibilityIdentifier("todayRing")
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let prompt = store.dayPlanPrompt(now: context.date)
                if !ring.hasWorkingHours {
                    textButton("Set hours", identifier: "setWorkingHours", hint: "Sets your working hours so the ring can show free time", action: setHours)
                } else if prompt == .shutdown {
                    textButton("Shut down", identifier: "dayShutdown", hint: "Review today and close it", action: shutdown)
                } else {
                    textButton("Plan", identifier: "planDay", hint: "Opens Plan your day", quiet: prompt == .planned || prompt == .shutDown, action: plan)
                }
            }
        }
    }
    private func textButton(_ title: String, identifier: String, hint: String, quiet: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(DS.Font.ringFigure.weight(.semibold))
                .foregroundStyle(quiet ? DS.Palette.textSecondary : Color.brandCrimson)
                .padding(.leading, DS.Space.xs).frame(minHeight: 28).contentShape(.rect)
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityHint(hint).accessibilityIdentifier(identifier)
    }
}

/// A list's group header: 13 pt semibold ink with a tertiary count, "Today  4". Only Overdue is crimson.
struct ListGroupHeader: View {
    var title: String
    var detail: String = ""
    var count: Int? = nil
    var alert = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(title).font(DS.Font.sectionHeader).foregroundStyle(alert ? DS.Palette.dateOverdue : DS.Palette.textPrimary)
            if !detail.isEmpty { Text(detail).font(DS.Font.sectionHeader.weight(.regular)).foregroundStyle(DS.Palette.textSecondary).lineLimit(1) }
            if let count, count > 0 {
                Text("\(count)").font(DS.Font.sectionHeader.weight(.regular)).monospacedDigit().foregroundStyle(DS.Palette.textTertiary)
                    .contentTransition(.numericText())
            }
        }
    }
}
