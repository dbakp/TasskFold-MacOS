#!/usr/bin/env python3
"""Render the actual SwiftUI views with isolated fixtures; not a WidgetKit host test."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'TaskfoldWidgets/TaskfoldWidgets.swift').read_text()
source = source.replace('@main\nstruct TaskfoldWidgetBundle', 'struct TaskfoldWidgetBundle')
# WidgetKit exposes a read-only family environment; use explicit families in this standalone renderer.
source = source.replace('@Environment(\\.widgetFamily) private var family', 'private let family: WidgetFamily = .systemMedium', 1)
source = source.replace('@Environment(\\.widgetFamily) private var family', 'private let family: WidgetFamily = .systemSmall', 1)
source = source.replace('Link(destination:', 'PreviewLink(destination:')
source += r'''
struct PreviewLink<Content: View>: View {
    let content: Content
    init(destination: URL, @ViewBuilder label: () -> Content) { content = label() }
    var body: some View { content }
}
@main struct PreviewRenderer {
    @MainActor static func main() throws {
        let dark = CommandLine.arguments[2] == "dark"
        let empty = CommandLine.arguments[2] == "empty"
        let entry = empty ? TodayEntry(date: Date(), snapshot: .empty) : TodayEntry.preview
        let content = VStack(alignment: .leading, spacing: 20) {
            Text("Taskfold widgets").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(empty ? "Empty workspace states" : "Today, Focus, Week ahead and Quick capture").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                TodayWidgetView(entry: entry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
                FocusWidgetView(entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                WeekWidgetView(entry: entry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                CaptureWidgetView(entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
        }.padding(32).background(dark ? Color(white: 0.09) : Color.white).environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }
}
'''
output = root / 'docs/widget-previews'
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-widget-previews-') as temporary:
    path = Path(temporary)
    (path / 'Preview.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'Preview.swift'), '-o', str(path / 'preview')], check=True)
    for mode, name in [('light', 'catalog'), ('dark', 'dark'), ('empty', 'empty')]:
        subprocess.run([str(path / 'preview'), str(output / f'{name}.png'), mode], check=True)
