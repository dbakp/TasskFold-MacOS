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
        switch group { case "priority": return "flag.fill"; case "labels": return "tag.fill"; case "due_time": return "clock"; case "recurrence": return "repeat"; default: return "calendar" }
    }
    static func name(for group: String) -> String {
        switch group { case "priority": return "priority"; case "labels": return "label"; case "due_time": return "time"; case "recurrence": return "repeat"; default: return "date" }
    }

    var body: some View {
        HStack(spacing: 6) {
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
        return HStack(spacing: 5) {
            Image(systemName: Self.symbol(for: token.group)).font(.caption2.weight(.semibold))
            Text(token.label).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
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
        .background(Color.taskfold.opacity(0.12), in: .capsule)
        .overlay(Capsule().strokeBorder(Color.taskfold.opacity(focused ? 0.9 : 0), lineWidth: 1.5))
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
