import SwiftUI

// One time grid for Calendar Day and Plan your day (design review, redesign round 2). Both draw at the same scale and
// with the same blocks: events are quiet neutral glass, placed tasks are solid in their project colour, suggestions
// (Fit my day previews) are dashed. Blocks are exactly start and duration; nothing is padded to a minimum height.
// One file for both apps.

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
    case event
    case task(ProjectHue)
    case suggestion(ProjectHue)
}

/// A block's face. The caller sizes it (exactly duration × scale) and adds its own gestures and accessibility.
struct TimeGridBlock: View {
    var title: String
    /// "10:00–11:30" or "15:30".
    var time: String
    /// Shown after the time on taller blocks: the project name, the calendar, or "suggested".
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
        .background(background, in: RoundedRectangle(cornerRadius: TimeGrid.cornerRadius, style: .continuous))
        .overlay { border }
        .clipShape(RoundedRectangle(cornerRadius: TimeGrid.cornerRadius, style: .continuous))
    }
    private var titleColor: Color {
        switch kind {
        case .event: DS.Palette.textPrimary
        case .task(let hue): hue.onColor
        case .suggestion(let hue): hue.color
        }
    }
    private var metaColor: Color {
        switch kind {
        case .event: DS.Palette.textSecondary
        case .task(let hue): hue.onColor.opacity(0.8)
        case .suggestion(let hue): hue.color
        }
    }
    private var background: Color {
        switch kind {
        case .event: Color(brand: Brand.ink, opacity: 0.05, darkOpacity: 0.08)
        case .task(let hue): hue.color
        case .suggestion(let hue): hue.color.opacity(0.12)
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
