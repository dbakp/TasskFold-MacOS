import SwiftUI

/// The pieces the shared quick-entry parser pulled out of a title, each as a chip that can be declined.
/// Declining keeps the words in the title. Chips are keyboard reachable: Tab into them, Space or Delete
/// declines, Escape returns focus to the text.
struct QuickEntryChips: View {
    let tokens: [QuickEntry.Token]
    var compact = false
    let decline: (QuickEntry.Token) -> Void
    var returnFocus: () -> Void = {}
    @FocusState private var focusedChip: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func symbol(for group: String) -> String {
        if group.hasPrefix("reminder_specs") { return "bell" }
        switch group { case "project_id": return "folder"; case "section_id": return "rectangle.stack"; case "assigned_to": return "person.crop.circle"; case "priority": return "flag.fill"; case "labels": return "tag.fill"; case "due_time": return "clock"; case "recurrence": return "repeat"; case "deadline_date": return "flag.checkered"; case "duration_minutes": return "hourglass"; default: return "calendar" }
    }
    static func name(for group: String) -> String {
        if group.hasPrefix("reminder_specs") { return "reminder" }
        switch group { case "project_id": return "project"; case "section_id": return "section"; case "assigned_to": return "assignee"; case "priority": return "priority"; case "labels": return "label"; case "due_time": return "time"; case "recurrence": return "repeat"; case "deadline_date": return "deadline"; case "duration_minutes": return "estimate"; default: return "date" }
    }

    var body: some View {
        QuickEntryChipLayout(spacing: 6) {
            ForEach(tokens) { token in
                chip(token)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity), removal: .scale(scale: 0.9).combined(with: .opacity)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : Transitions.Ease.smoothOut(Transitions.Duration.quick), value: tokens.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickEntryChips")
    }

    private func chip(_ token: QuickEntry.Token) -> some View {
        let focused = focusedChip == token.id
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: Self.symbol(for: token.group)).font(.caption2.weight(.semibold))
            Text(token.label).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            Button { decline(token) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                    .background(Color.taskfold.opacity(0.14), in: .circle)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Keep “\(token.text)” in the title")
            .accessibilityLabel("Keep “\(token.text)” in the title")
            .accessibilityIdentifier("decline-\(token.group)")
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, compact ? 2 : 3)
        .foregroundStyle(Color.taskfold)
        .background(Color.taskfold.opacity(0.12), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.taskfold.opacity(focused ? 0.9 : 0), lineWidth: 1.5))
        .focusable(true)
        .focused($focusedChip, equals: token.id)
        .focusEffectDisabled()
        .onKeyPress(.space) { decline(token); returnFocus(); return .handled }
        .onKeyPress(.delete) { decline(token); returnFocus(); return .handled }
        .onKeyPress(.escape) { returnFocus(); return .handled }
        .animation(Transitions.Ease.smoothOut(Transitions.Duration.quick), value: focused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.name(for: token.group).capitalized) \(token.label), from “\(token.text)”")
        .accessibilityHint("Press Space or Delete to keep those words in the title instead")
        .accessibilityIdentifier("chip-\(token.group)")
    }
}

/// Each app owns its layout. Measure long labels against the actual available width,
/// then place complete chips on rows without requiring a sideways preview scroll.
struct QuickEntryChipLayout: Layout {
    var spacing: CGFloat = 8
    private func rows(_ subviews: Subviews, width: CGFloat) -> (CGSize, [CGPoint], [CGSize]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var points: [CGPoint] = [], sizes: [CGSize] = []
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); sizes.append(size)
            usedWidth = max(usedWidth, x + size.width); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), points, sizes)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: max(1, proposal.width ?? .greatestFiniteMagnitude)).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, points, sizes) = rows(subviews, width: max(1, bounds.width))
        for i in subviews.indices {
            subviews[i].place(at: CGPoint(x: bounds.minX + points[i].x, y: bounds.minY + points[i].y), anchor: .topLeading, proposal: ProposedViewSize(sizes[i]))
        }
    }
}
