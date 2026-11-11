import SwiftUI

#if DEBUG
/// `--control-previews-fixture`: draws Taskfold's Control Center and Lock Screen controls as tiles,
/// because the Simulator's Control Center does not host third-party controls. It uses the same symbols,
/// titles and tint as the widget extension's controls, so a reviewer can see each state side by side.
struct SystemControlPreviewsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Controls").font(DS.Font.screenTitle).accessibilityAddTraits(.isHeader)
                Text("Control Center and Lock Screen").font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.Space.m)], spacing: DS.Space.m) {
                    tile(symbol: "plus.circle.fill", title: "Add Task", detail: "Opens Taskfold ready to type", on: false)
                    tile(symbol: "sun.max.fill", title: "Today", detail: "Open Today", on: false)
                    tile(symbol: "play.circle.fill", title: "Focus timer", detail: "Start", on: false)
                    tile(symbol: "timer", title: "Focus timer", detail: "Running", on: true)
                }
                Text("The Focus timer reads the shared snapshot. A tap leaves one expiring request in the App Group, and Taskfold applies it through its normal Focus session path.")
                    .font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(DS.Space.xl)
        }
        .background(DS.Palette.surface)
        .accessibilityIdentifier("systemControlPreviews")
    }

    private func tile(symbol: String, title: String, detail: String, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Image(systemName: symbol).font(.title2).foregroundStyle(on ? Color.white : DS.Palette.accent)
            Spacer(minLength: DS.Space.s)
            Text(title).font(DS.Font.sectionHeader).foregroundStyle(on ? Color.white : DS.Palette.textPrimary)
            Text(detail).font(DS.Font.taskMeta).foregroundStyle(on ? Color.white.opacity(0.85) : DS.Palette.textSecondary)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(on ? DS.Palette.accent : DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }
}
#endif
