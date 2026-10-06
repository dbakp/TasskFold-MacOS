#!/usr/bin/env python3
"""Render the actual SwiftUI views with isolated fixtures; not a WidgetKit host test."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parent.parent
source = (root / 'TaskfoldWidgets/TaskfoldWidgets.swift').read_text()
source = source.replace('@main\nstruct TaskfoldWidgetBundle', 'struct TaskfoldWidgetBundle')
# WidgetKit exposes a read-only family environment; use explicit families in this standalone renderer.
source = source.replace('@Environment(\\.widgetFamily) private var family', 'var family: WidgetFamily = .systemMedium')
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
        let mode = CommandLine.arguments[2]
        let empty = mode == "empty"
        let entry = empty ? TodayEntry(date: Date(), snapshot: .empty) : TodayEntry.preview
        let productivity = mode.hasPrefix("productivity")
        let snapshot: WidgetSnapshot = mode == "productivity-empty" ? WidgetSnapshot(updated: Date().timeIntervalSinceReferenceDate, tasks: [], account: "preview") : mode == "productivity-legacy" ? WidgetSnapshot(updated: Date().timeIntervalSinceReferenceDate, tasks: entry.snapshot.tasks, version: 1) : entry.snapshot
        let privateTitles = mode == "productivity-private"
        let newContent = VStack(alignment: .leading, spacing: 20) {
            Text("A little room to move").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Hard cutoffs. Small steps. Your choice of time, color and privacy.").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                DeadlineWidgetView(family: .systemSmall, entry: DeadlineEntry(date: entry.date, snapshot: snapshot, hideTitles: privateTitles)).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
                DeadlineWidgetView(entry: DeadlineEntry(date: entry.date, snapshot: snapshot, hideTitles: privateTitles)).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                WindowWidgetView(family: .systemSmall, entry: WindowEntry(date: entry.date, snapshot: snapshot, hideTitles: privateTitles)).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                WindowWidgetView(entry: WindowEntry(date: entry.date, snapshot: snapshot, hideTitles: privateTitles)).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 9) {
                ForEach(WindowBudget.allCases, id: \.self) { budget in
                    WindowWidgetView(family: .systemSmall, entry: WindowEntry(date: entry.date, snapshot: snapshot, budget: budget, palette: budget == .ten ? .mint : budget == .fortyFive ? .rose : .lavender, hideTitles: privateTitles)).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: budget == .ten ? mint : budget == .fortyFive ? brand : plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }
        }
        let content = VStack(alignment: .leading, spacing: 20) {
            Text("Taskfold widgets").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(empty ? "Empty workspace states" : "Today, Focus, Week ahead and Quick capture").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                TodayWidgetView(entry: entry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
                FocusWidgetView(family: .systemSmall, entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                WeekWidgetView(entry: entry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                CaptureWidgetView(entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
        }.padding(32).background(dark ? Color(white: 0.09) : Color.white).environment(\.colorScheme, dark ? .dark : .light)
        let lists = mode.hasPrefix("lists")
        let listSnapshot = mode == "lists-empty" ? WidgetSnapshot(updated: Date().timeIntervalSinceReferenceDate, tasks: [], account: "preview", lists: entry.snapshot.lists) : entry.snapshot
        let chosen = mode == "lists-unavailable" ? "deleted-list" : listSnapshot.availableLists.first?.id
        let listPrivate = mode == "lists-private"
        let listContent = VStack(alignment: .leading, spacing: 20) {
            Text("Your work, close by").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Choose a project, label or saved filter. Keep the useful part in view.").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                ListWidgetView(family: .systemSmall, entry: ListEntry(date: entry.date, snapshot: listSnapshot, listID: chosen, hideTitles: listPrivate)).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                ListWidgetView(entry: ListEntry(date: entry.date, snapshot: listSnapshot, listID: chosen, hideTitles: listPrivate)).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                ListWidgetView(family: .systemLarge, entry: ListEntry(date: entry.date, snapshot: listSnapshot, listID: chosen, palette: .lavender, hideTitles: listPrivate)).padding(16).frame(width: 338, height: 354).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                VStack(spacing: 14) {
                    WindowWidgetView(entry: WindowEntry(date: entry.date, snapshot: listSnapshot, hideTitles: listPrivate, listID: chosen)).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                    ListWidgetView(entry: ListEntry(date: entry.date, snapshot: listSnapshot)).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }
        }
        let actual = Group { if lists { listContent.padding(32).background(mode == "lists-dark" ? Color(white: 0.09) : Color.white).environment(\.colorScheme, mode == "lists-dark" ? .dark : .light) } else if productivity { newContent.padding(32).background(mode == "productivity-dark" ? Color(white: 0.09) : Color.white).environment(\.colorScheme, mode == "productivity-dark" ? .dark : .light).environment(\.dynamicTypeSize, .large) } else { content } }
        let renderer = ImageRenderer(content: actual)
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
    modes = [(mode, mode) for mode in ['lists', 'lists-dark', 'lists-private', 'lists-empty', 'lists-unavailable']] if '--lists' in sys.argv else [('light', 'catalog'), ('dark', 'dark'), ('empty', 'empty')] + [(mode, mode) for mode in ['productivity', 'productivity-dark', 'productivity-empty', 'productivity-private', 'productivity-legacy']]
    for mode, name in modes:
        subprocess.run([str(path / 'preview'), str(output / f'{name}.png'), mode], check=True)
