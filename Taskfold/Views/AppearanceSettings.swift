import SwiftUI
import AppKit

struct AppearanceSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accent") private var accent = "rose"
    @AppStorage("mac.taskDensity") private var density = DS.Size.densityDefault
    @AppStorage(DayRingSetting.key) private var showDayRing = true
    @AppStorage("mac.savedAccents") private var saved = ""
    @State private var proposed = Color.accentValue(UserDefaults.standard.string(forKey: "accent") ?? "rose")
    @State private var colorPanel = AccentColorPanel()
    private var customs: [String] { saved.split(separator: ",").map(String.init) }
    var body: some View {
        // A native grouped form with the system tint (owner decision 8): Settings is not where the brand lives.
        Form {
            Section {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
                Picker("Density", selection: $density) { Text("Compact").tag("compact"); Text("Roomy").tag("roomy") }.pickerStyle(.segmented).accessibilityIdentifier("taskDensity")
                Toggle("Day ring", isOn: $showDayRing).accessibilityIdentifier("showDayRingToggle").help(DayRingSetting.footer)
            }
            Section("Accent") {
                let rows = Color.accents.chunked(into: 4)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row], id: \.key) { option in
                                swatch(option.key, option.name, option.color).gridColumnAlignment(.leading)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                LabeledContent("Custom") {
                    // A custom colour applies as you pick it, and is kept in the recent colours below.
                    Button {
                        colorPanel.show(proposed) { proposed = $0; applyCustom($0) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(proposed).frame(width: 16, height: 16).overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                            Text("Choose…")
                        }
                    }.accessibilityLabel("Choose custom color").accessibilityIdentifier("customAccentPicker")
                }
                if !customs.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(customs, id: \.self) { value in
                                swatch("custom:" + value.dropFirst(), value, Color.project(value))
                                    .contextMenu { Button("Remove Saved Color") { saved = customs.filter { $0 != value }.joined(separator: ",") } }
                            }
                        }.padding(4)
                    }.frame(height: 62)
                }
            }
        }.formStyle(.grouped).onDisappear { colorPanel.close() }
    }
    private func applyCustom(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        let value = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        saved = ([value] + customs.filter { $0 != value }).prefix(24).joined(separator: ",")
        accent = "custom:" + value.dropFirst()
    }
    private func swatch(_ value: String, _ name: String, _ color: Color) -> some View {
        Button { accent = value } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 22, height: 22).overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                Text(name).font(.caption).lineLimit(1)
                if accent == value { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            }.frame(minHeight: 28)
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(accent == value ? .isSelected : [])
            .accessibilityIdentifier("accent-" + value)
    }
}

/// An explicit native-panel action is keyboard/VoiceOver accessible, including on macOS versions
/// whose SwiftUI color well does not reliably implement the accessibility press action.
@MainActor private final class AccentColorPanel: NSObject {
    private var changed: ((Color) -> Void)?
    func show(_ color: Color, changed: @escaping (Color) -> Void) {
        self.changed = changed
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(color)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func colorChanged(_ sender: NSColorPanel) { changed?(Color(nsColor: sender.color)) }
    func close() {
        guard changed != nil else { return }
        NSColorPanel.shared.close()
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        changed = nil
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
