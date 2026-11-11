import SwiftUI

/// A calm, non-modal banner while a Focus filter narrows Taskfold: "Focus: Work · showing 3 projects".
/// "Show all" sets the filter aside for this activation of the Focus; nothing is changed or deleted.
struct FocusFilterBanner: View {
    @Environment(Store.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let scope = store.focusScope {
                row(text: scope.bannerText, symbol: "scope", action: "Show all", hint: "Shows every project until this Focus changes", label: scope.bannerAccessibilityLabel) {
                    store.setFocusFilterShowAll(true)
                }
            } else if let paused = store.focusScopePaused {
                row(text: "Showing all projects", symbol: "scope", action: "Resume filter", hint: "Narrows Taskfold to the Focus projects again",
                    label: "Focus filter paused. Showing all projects.") { store.setFocusFilterShowAll(false) }
            }
        }
        .animation(Motion.respecting(reduceMotion, Motion.quick), value: store.focusScope?.activation)
        .animation(Motion.respecting(reduceMotion, Motion.quick), value: store.focusScopePaused?.activation)
    }

    private func row(text: String, symbol: String, action: String, hint: String, label: String, perform: @escaping () -> Void) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s)) : AnyLayout(HStackLayout(spacing: DS.Space.m))
        return layout {
            Label { Text(text).font(DS.Font.taskMeta.weight(.medium)).foregroundStyle(DS.Palette.textPrimary).fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: symbol).foregroundStyle(DS.Palette.accent) }
            if !typeSize.isAccessibilitySize { Spacer(minLength: DS.Space.s) }
            Button(action: perform) {
                Text(action).font(DS.Font.chip).foregroundStyle(DS.Palette.accent)
                    .padding(.horizontal, DS.Space.m).frame(minHeight: DS.Size.rowMinHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(hint)
            .accessibilityIdentifier("focusFilterShowAll")
        }
        .padding(.leading, DS.Space.l).padding(.trailing, DS.Space.xs).padding(.vertical, DS.Space.xxs)
        .background(DS.Palette.selectionFill, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("focusFilterBanner")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
