import SwiftUI
import AppKit

struct AppearanceSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accent") private var accent = "rose"
    @AppStorage("mac.taskDensity") private var density = "roomy"
    @AppStorage("mac.savedAccents") private var saved = ""
    @State private var proposed = Color.taskfold
    private var customs: [String] { saved.split(separator: ",").map(String.init) }
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
                Picker("Task layout", selection: $density) { Text("Roomy").tag("roomy"); Text("Compact").tag("compact") }.pickerStyle(.segmented).accessibilityIdentifier("taskDensity")
                Text("Appearance preferences apply only to this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Accent color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(Color.accents, id: \.key) { option in swatch(option.key, option.name, option.color) }
                }.padding(.vertical, 5)
                ColorPicker("Custom color", selection: $proposed, supportsOpacity: false).accessibilityIdentifier("customAccentPicker")
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
        }.formStyle(.grouped)
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
