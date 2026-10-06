#!/usr/bin/env python3
"""Render actual Focus session SwiftUI source with isolated states; not an installed host test."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'TaskfoldWidgets/TaskfoldWidgets.swift').read_text()
source = source.replace('@main\nstruct TaskfoldWidgetBundle', 'struct TaskfoldWidgetBundle')
source = source.replace('@Environment(\\.widgetFamily) private var family', 'var family: WidgetFamily = .systemMedium')
source += r'''
@main struct FocusPreviewRenderer {
    @MainActor static func main() throws {
        let mode = CommandLine.arguments[2]
        var entry = FocusSessionEntry.preview
        if mode == "focus-paused" { entry.snapshot.focusSession?.clock?.status = "paused"; entry.snapshot.focusSession?.clock?.runningSince = nil; entry.snapshot.focusSession?.clock?.elapsedMilliseconds = 300_000 }
        if mode == "focus-ended" { entry.snapshot.focusSession?.clock?.status = "stopped"; entry.snapshot.focusSession?.clock?.runningSince = nil; entry.snapshot.focusSession?.clock?.elapsedMilliseconds = 900_000 }
        if mode == "focus-finished" { entry.date = entry.snapshot.focusSession!.clock!.endDate! }
        if mode == "focus-idle" { entry.snapshot.focusSession?.clock = nil }
        if mode == "focus-private" { entry.hideTitle = true }
        if mode == "focus-conflict" { entry.snapshot.focusSession?.conflict = true; entry.snapshot.pendingSync = 2 }
        if mode == "focus-missing" { entry.snapshot.focusSession?.clock?.taskState = "unavailable"; entry.snapshot.focusSession?.clock?.title = nil }
        if mode == "focus-refresh" { entry.snapshot.focusSession = nil }
        if mode == "focus-dense" { entry.snapshot.focusSession?.clock?.title = "Prepare the quarterly planning notes and share the final draft with the café team"; entry.snapshot.focusSession?.clock?.durationSeconds = 10800 }
        var lavender = entry; lavender.palette = .lavender
        var mintEntry = entry; mintEntry.palette = .mint
        let content = VStack(alignment: .leading, spacing: 20) {
            Text("A little time for one useful step").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("A durable timer. Your task stays yours.").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                FocusSessionWidgetView(family: .systemSmall, entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                FocusSessionWidgetView(entry: entry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                FocusSessionWidgetView(family: .systemSmall, entry: mintEntry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                FocusSessionWidgetView(entry: lavender).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
        }.padding(32).background(mode == "focus-dark" ? Color(white: 0.09) : Color.white)
            .environment(\.colorScheme, mode == "focus-dark" ? .dark : .light)
            .environment(\.dynamicTypeSize, mode == "focus-largest" ? .accessibility3 : .large)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        if let image = renderer.cgImage {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        } else { fatalError("Focus preview did not render") }
    }
}
'''
output = root / 'docs/widget-previews'
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-focus-previews-') as temporary:
    path = Path(temporary)
    (path / 'Preview.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-D', 'TASKFOLD_WIDGET_EXTENSION', str(root / 'Taskfold/Core/WidgetActions.swift'), str(root / 'Taskfold/Core/FocusWidget.swift'), str(root / 'Taskfold/Core/ProjectPulseWidget.swift'), str(path / 'Preview.swift'), '-o', str(path / 'preview')], check=True)
    for mode in ['focus', 'focus-dark', 'focus-paused', 'focus-ended', 'focus-finished', 'focus-idle', 'focus-private', 'focus-conflict', 'focus-missing', 'focus-refresh', 'focus-dense', 'focus-largest']:
        subprocess.run([str(path / 'preview'), str(output / f'{mode}.png'), mode], check=True)
