#!/usr/bin/env python3
"""Render owned Today/Focus views under SwiftUI privacy redaction, not a system host."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = (root / 'TaskfoldWidgets/TaskfoldWidgets.swift').read_text()
source = source.replace('@main\nstruct TaskfoldWidgetBundle', 'struct TaskfoldWidgetBundle')
source = source.replace('@Environment(\\.widgetFamily) private var family', 'var family: WidgetFamily = .systemMedium')
source = source.replace('Link(destination:', 'PrivacyPreviewLink(destination:').replace('Link("', 'PrivacyPreviewLink("')
source += r'''
struct PrivacyPreviewLink<Content: View>: View {
    let content: Content
    init(destination: URL, @ViewBuilder label: () -> Content) { content = label() }
    var body: some View { content }
}
extension PrivacyPreviewLink where Content == Text {
    init(_ title: String, destination: URL) { content = Text(title) }
}
@main struct PrivacyPreviewRenderer {
    @MainActor static func main() throws {
        let privateMode = CommandLine.arguments[2] == "privacy"
        let now = Date(timeIntervalSince1970: 1791792000)
        let task = WidgetTask(id: "privacy-fixture", title: "Review confidential studio proposal", due: WidgetSnapshot.day(now), time: "10:30", priority: 1, project: "Private studio", color: "purple")
        let entry = TodayEntry(date: now, snapshot: WidgetSnapshot(updated: now.timeIntervalSinceReferenceDate, tasks: [task], account: "preview"))
        let content = VStack(alignment: .leading, spacing: 20) {
            Text(privateMode ? "SwiftUI privacy redaction" : "Normal rendering").font(.title2.bold())
            HStack(spacing: 20) {
                TodayWidgetView(family: .systemSmall, entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: brand))
                TodayWidgetView(family: .systemMedium, entry: entry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: brand))
            }
            HStack(spacing: 20) {
                FocusWidgetView(family: .systemSmall, entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum))
                FocusWidgetView(family: .systemMedium, entry: entry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum))
            }
        }.redacted(reason: privateMode ? .privacy : []).padding(24).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Privacy preview did not render") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
'''
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-privacy-preview-') as temporary:
    stage = Path(temporary)
    (stage / 'Preview.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-D', 'TASKFOLD_WIDGET_EXTENSION', str(root / 'Taskfold/Core/WidgetActions.swift'), str(root / 'Taskfold/Core/FocusWidget.swift'), str(root / 'Taskfold/Core/ProjectPulseWidget.swift'), str(stage / 'Preview.swift'), '-o', str(stage / 'preview')], check=True)
    for mode in ['normal', 'privacy']:
        subprocess.run([str(stage / 'preview'), str(args.output / (mode + '.png')), mode], check=True)
