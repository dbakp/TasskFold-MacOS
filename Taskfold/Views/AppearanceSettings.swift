import SwiftUI
import AppKit

struct AppearanceSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accent") private var accent = "rose"
    @AppStorage("mac.taskDensity") private var density = "roomy"
    @AppStorage("mac.savedAccents") private var saved = ""
    @State private var proposed = Color.accentValue(UserDefaults.standard.string(forKey: "accent") ?? "rose")
    @State private var colorPanel = AccentColorPanel()
    private var customs: [String] { saved.split(separator: ",").map(String.init) }
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
                Picker("Task layout", selection: $density) { Text("Roomy").tag("roomy"); Text("Compact").tag("compact") }.pickerStyle(.segmented).accessibilityIdentifier("taskDensity")
                Text("Preferences apply only to this Mac. Accent shades adapt to keep controls readable in light and dark appearance.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Accent color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(Color.accents, id: \.key) { option in swatch(option.key, option.name, option.color) }
                }.padding(.vertical, 5)
                LabeledContent("Custom color") {
                    Button {
                        colorPanel.show(proposed) { proposed = $0 }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(proposed).frame(width: 16, height: 16).overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                            Text("Choose…")
                        }
                    }.accessibilityLabel("Choose custom color").accessibilityIdentifier("customAccentPicker")
                }
                Button("Save Custom Accent") {
                    guard let color = NSColor(proposed).usingColorSpace(.sRGB) else { return }
                    let value = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
                    saved = ([value] + customs.filter { $0 != value }).prefix(24).joined(separator: ",")
                    accent = "custom:" + value.dropFirst()
                }.accessibilityIdentifier("saveCustomAccent")
                if !customs.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(customs, id: \.self) { value in
                                swatch("custom:" + value.dropFirst(), value, Color.project(value))
                                    .contextMenu { Button("Remove Saved Color") { saved = customs.filter { $0 != value }.joined(separator: ",") } }
                            }
                        }.padding(4)
                    }.frame(height: 62)
                    Text("Up to 24 recent custom colors are saved. Removing a saved color keeps your current accent.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped).onDisappear { colorPanel.close() }
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
