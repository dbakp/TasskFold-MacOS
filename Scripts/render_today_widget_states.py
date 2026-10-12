#!/usr/bin/env python3
"""Render owned Today unavailable/loaded-empty/loaded-task states; not a system-host test."""
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
source = source.replace('Link(destination:', 'TodayStatePreviewLink(destination:').replace('Link("', 'TodayStatePreviewLink("')
source += r'''
struct TodayStatePreviewLink<Content: View>: View {
    let content: Content
    init(destination: URL, @ViewBuilder label: () -> Content) { content = label() }
    var body: some View { content }
}
extension TodayStatePreviewLink where Content == Text {
    init(_ title: String, destination: URL) { content = Text(title) }
}
@main struct TodayStateRenderer {
    @MainActor static func main() throws {
        let state = CommandLine.arguments[2], dark = CommandLine.arguments[3] == "dark"
        let now = Date(timeIntervalSince1970: 1791792000)
        let task = WidgetTask(id: "today-state", title: "Review the studio proposal", due: WidgetSnapshot.day(now), time: "10:30", priority: 1, project: "Studio", color: "purple")
        let snapshot = state == "unavailable" ? WidgetSnapshot.empty : WidgetSnapshot(updated: now.timeIntervalSinceReferenceDate, tasks: state == "empty" ? [] : [task], account: "preview")
        let entry = TodayEntry(date: now, snapshot: snapshot)
        let content = HStack(alignment: .top, spacing: 20) {
            TodayWidgetView(family: .systemSmall, entry: entry).padding(16).frame(width: 164, height: 164).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
            TodayWidgetView(family: .systemMedium, entry: entry).padding(16).frame(width: 344, height: 164).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
            TodayWidgetView(family: .systemLarge, entry: entry).padding(16).frame(width: 344, height: 344).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
        }.padding(24).background(dark ? Color(white: 0.09) : Color.white).environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Today state preview did not render") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
'''
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-today-state-preview-') as temporary:
    stage = Path(temporary)
    (stage / 'Preview.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-D', 'TASKFOLD_WIDGET_EXTENSION', str(root / 'Taskfold/Core/WidgetActions.swift'), str(root / 'Taskfold/Core/FocusWidget.swift'), str(root / 'Taskfold/Core/ProjectPulseWidget.swift'), str(stage / 'Preview.swift'), '-o', str(stage / 'preview')], check=True)
    for state in ['unavailable', 'empty', 'ready']:
        for scheme in ['light', 'dark']:
            subprocess.run([str(stage / 'preview'), str(args.output / (state + '-' + scheme + '.png')), state, scheme], check=True)
