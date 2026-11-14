import SwiftUI

// One time grid for Calendar Day and Plan your day (design review, rounds 2 and 3). Both draw at the same scale and
// with the same blocks: events are quiet neutral glass with a 3pt bar in their calendar's colour, placed tasks are
// solid in their project colour with white or ink text, and suggestions (Fit my day previews) are the hue at 25% with
// a dashed border in the hue and ink text. Every block's text is measured at 4.5:1 or more in BrandTests. Blocks are
// exactly start and duration; nothing is padded to a minimum height. One file for both apps.

enum TimeGrid {
    /// 64pt per hour, in both places.
    static let pointsPerMinute: CGFloat = 64.0 / 60.0
    static let hourHeight: CGFloat = 64
    static let cornerRadius: CGFloat = 9
    /// Below this height a block is one line: the title, then its time.
    static let compactHeight: CGFloat = 34
}

/// How a block reads.
enum TimeGridBlockKind {
    /// A calendar event; the colour is its calendar's, for the leading bar (nil draws a neutral bar).
    case event(Color?)
    case task(ProjectHue)
    case suggestion(ProjectHue)
}

/// A block's face. The caller sizes it (exactly duration × scale) and adds its own gestures and accessibility.
struct TimeGridBlock: View {
    var title: String
    /// "10:00–11:30" or "15:30".
    var time: String
    /// Shown after the time on taller blocks: the project name or the calendar.
    var detail: String? = nil
    var kind: TimeGridBlockKind
    var height: CGFloat
    var body: some View {
        let compact = height < TimeGrid.compactHeight
        Group {
            if compact {
                HStack(spacing: 8) {
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(1).foregroundStyle(titleColor)
                    Text([time, detail].compactMap { $0 }.joined(separator: " · ")).font(DS.Font.blockTime).lineLimit(1).foregroundStyle(metaColor)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(height > 60 ? 2 : 1).foregroundStyle(titleColor)
                    Text([time, detail].compactMap { $0 }.joined(separator: " · ")).font(DS.Font.blockTime).lineLimit(1).foregroundStyle(metaColor)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.leading, bar == nil ? 0 : 3)
        .background(background, in: RoundedRectangle(cornerRadius: TimeGrid.cornerRadius, style: .continuous))
        .overlay(alignment: .leading) { if let bar { Rectangle().fill(bar).frame(width: 3) } }
        .overlay { border }
        .clipShape(RoundedRectangle(cornerRadius: TimeGrid.cornerRadius, style: .continuous))
    }
    /// Events carry a 3pt bar in their calendar's colour.
    private var bar: Color? {
        if case .event(let colour) = kind { return colour ?? DS.Palette.textTertiary }
        return nil
    }
    private var titleColor: Color {
        switch kind {
        case .event: DS.Palette.textPrimary
        case .task(let hue): hue.onColor
        case .suggestion: Color(brand: Brand.onSuggestion)
        }
    }
    /// Full strength, not faded: the meta line is text too and must clear 4.5:1.
    private var metaColor: Color {
        switch kind {
        case .event: DS.Palette.textSecondary
        case .task(let hue): hue.onColor
        case .suggestion: Color(brand: Brand.onSuggestion)
        }
    }
    private var background: Color {
        switch kind {
        case .event: Color(brand: Brand.ink, opacity: Brand.eventOpacity.light, darkOpacity: Brand.eventOpacity.dark)
        case .task(let hue): hue.color
        case .suggestion(let hue): hue.color.opacity(Brand.suggestionOpacity)
        }
    }
    @ViewBuilder private var border: some View {
        let shape = RoundedRectangle(cornerRadius: TimeGrid.cornerRadius, style: .continuous)
        switch kind {
        case .event: shape.strokeBorder(Color(brand: Brand.ink, opacity: 0.12, darkOpacity: 0.16), lineWidth: 0.5)
        case .task: EmptyView()
        case .suggestion(let hue): shape.strokeBorder(hue.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }
}

extension PlannerEvent {
    /// The calendar's colour for the block's bar, when the calendar has one.
    var calendarColour: Color? { color.flatMap { BrandRGB(hex: $0) }.map(\.color) }
}
