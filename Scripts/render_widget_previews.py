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
source = source.replace('Link(destination:', 'PreviewLink(destination:').replace('Link("', 'PreviewLink("')
source += r'''
struct PreviewLink<Content: View>: View {
    let content: Content
    init(destination: URL, @ViewBuilder label: () -> Content) { content = label() }
    var body: some View { content }
}
extension PreviewLink where Content == Text {
    init(_ title: String, destination: URL) { content = Text(title) }
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
        var listSnapshot = mode == "lists-empty" ? WidgetSnapshot(updated: Date().timeIntervalSinceReferenceDate, tasks: [], account: "preview", lists: entry.snapshot.lists) : entry.snapshot
        if mode == "lists-pending" { listSnapshot.pendingTaskIDs = ["preview-1"] }
        if mode == "lists-sync" { listSnapshot.pendingSync = 2 }
        if mode == "lists-dense", let first = listSnapshot.tasks.first {
            listSnapshot.tasks = (0..<9).map { index in
                var task = first; task.id = "dense-\(index)"
                task.title = "Prepare the quarterly planning notes and share the final draft with the team"
                task.deadline = WidgetSnapshot.day(entry.date); task.completionToken = UUID().uuidString.lowercased()
                return task
            }
            listSnapshot.lists[0].days = ["*": listSnapshot.tasks.map(\.id)]
        }
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

        let capacity = mode.hasPrefix("capacity")
        var capacityEntry = CapacityEntry.preview
        if mode == "capacity-empty" { capacityEntry.snapshot = .empty }
        if mode == "capacity-private" { capacityEntry.hideDetails = true }
        if var value = capacityEntry.snapshot.capacity {
            if mode == "capacity-off" { value.calendarState = "off"; value.calendarUpdated = nil }
            if mode == "capacity-incomplete" { value.calendarState = "incomplete" }
            if mode == "capacity-refresh" { value.calendarUpdated = capacityEntry.date.addingTimeInterval(-3601).timeIntervalSinceReferenceDate }
            for key in value.days.keys {
                if mode == "capacity-overload" { value.days[key]?.estimated = 540; value.days[key]?.busy = 120; value.days[key]?.unknown = 0 }
                if mode == "capacity-unknown" { value.days[key]?.unknown = 4 }
                if mode == "capacity-off" { value.days[key]?.busy = 0 }
                if mode == "capacity-rest" { value.days[key]?.working = 0; value.days[key]?.busy = 0; value.days[key]?.estimated = 60 }
            }
            capacityEntry.snapshot.capacity = value
        }
        var tomorrowCapacity = capacityEntry; tomorrowCapacity.day = .tomorrow; tomorrowCapacity.palette = .lavender
        let capacityContent = VStack(alignment: .leading, spacing: 20) {
            Text("A day with room to breathe").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("A whole-day budget. Real estimates. Calendar busy time counted once.").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                CapacityWidgetView(family: .systemSmall, entry: capacityEntry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                CapacityWidgetView(entry: capacityEntry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                CapacityWidgetView(family: .systemSmall, entry: tomorrowCapacity).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                CapacityWidgetView(entry: tomorrowCapacity).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
        }.environment(\.dynamicTypeSize, mode == "capacity-largest" ? .accessibility3 : .large)


        let inbox = mode.hasPrefix("inbox")
        var inboxEntry = InboxEntry.preview
        if mode == "inbox-empty" { inboxEntry.snapshot.tasks = [] }
        if mode == "inbox-private" { inboxEntry.hideDetails = true }
        if mode == "inbox-legacy" { inboxEntry.snapshot.version = 1 }
        if mode == "inbox-dense", let first = inboxEntry.snapshot.tasks.first {
            inboxEntry.snapshot.tasks = (0..<125).map { index in
                var task = first; task.id = "inbox-dense-\(index)"
                task.title = "Prepare the quarterly planning notes and share the final draft with the team"
                return task
            }
        }
        var tenInbox = inboxEntry; tenInbox.batch = .ten; tenInbox.palette = .mint
        let inboxContent = VStack(alignment: .leading, spacing: 20) {
            Text("A little clarity, one decision at a time").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("An honest Inbox count. Keep, organize or finish. Your dates stay yours.").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                InboxWidgetView(family: .systemSmall, entry: inboxEntry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                InboxWidgetView(entry: inboxEntry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                InboxWidgetView(family: .systemSmall, entry: tenInbox).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                InboxWidgetView(entry: tenInbox).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
        }.environment(\.dynamicTypeSize, mode == "inbox-largest" ? .accessibility3 : .large)


        let notes = mode.hasPrefix("notes")
        var noteEntry = NoteEntry.preview
        if mode == "notes-private" { noteEntry.hideDetails = true }
        if mode == "notes-choose" { noteEntry.noteID = nil }
        if mode == "notes-deleted" { noteEntry.snapshot.notes = [] }
        if mode == "notes-legacy" { noteEntry.snapshot.notes = nil }
        if mode == "notes-blank" { noteEntry.snapshot.notes?[0].text = "" }
        if mode == "notes-dense" {
            noteEntry.snapshot.notes?[0].title = "A longer reference for the café, the studio and the next good idea"
            noteEntry.snapshot.notes?[0].text = String(repeating: "Keep the café and 👩🏽‍💻 details.\nLeave room for ideas and finish one clear step.\n", count: 12)
            noteEntry.snapshot.notes?[0].truncated = true
        }
        var roseNote = noteEntry; roseNote.palette = .rose
        var lavenderNote = noteEntry; lavenderNote.palette = .lavender
        let noteContent = VStack(alignment: .leading, spacing: 20) {
            Text("A thought worth keeping close").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Instructions, a checklist, an idea. Explicitly pinned. Tap to read it all.").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                NoteWidgetView(family: .systemSmall, entry: noteEntry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
                NoteWidgetView(entry: noteEntry).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
            }
            HStack(alignment: .top, spacing: 20) {
                NoteWidgetView(family: .systemLarge, entry: roseNote).padding(16).frame(width: 338, height: 354).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
                VStack(spacing: 14) {
                    NoteWidgetView(family: .systemSmall, entry: roseNote).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
                    NoteWidgetView(family: .systemSmall, entry: lavenderNote).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }
        }.environment(\.dynamicTypeSize, mode == "notes-largest" ? .accessibility3 : .large)

        let actual = Group { if notes { noteContent.padding(32).background(mode == "notes-dark" ? Color(white: 0.09) : Color.white).environment(\.colorScheme, mode == "notes-dark" ? .dark : .light) } else if inbox { inboxContent.padding(32).background(mode == "inbox-dark" ? Color(white: 0.09) : Color.white).environment(\.colorScheme, mode == "inbox-dark" ? .dark : .light) } else if capacity { capacityContent.padding(32).background(mode == "capacity-dark" ? Color(white: 0.09) : Color.white).environment(\.colorScheme, mode == "capacity-dark" ? .dark : .light) } else if lists { listContent.padding(32).background(mode == "lists-dark" ? Color(white: 0.09) : Color.white).environment(\.colorScheme, mode == "lists-dark" ? .dark : .light) } else if productivity { newContent.padding(32).background(mode == "productivity-dark" ? Color(white: 0.09) : Color.white).environment(\.colorScheme, mode == "productivity-dark" ? .dark : .light).environment(\.dynamicTypeSize, .large) } else { content } }
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
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-D', 'TASKFOLD_WIDGET_EXTENSION', str(root / 'Taskfold/Core/WidgetActions.swift'), str(root / 'Taskfold/Core/FocusWidget.swift'), str(root / 'Taskfold/Core/ProjectPulseWidget.swift'), str(path / 'Preview.swift'), '-o', str(path / 'preview')], check=True)
    modes = [(mode, mode) for mode in ['notes', 'notes-dark', 'notes-private', 'notes-choose', 'notes-deleted', 'notes-legacy', 'notes-blank', 'notes-dense', 'notes-largest']] if '--notes' in sys.argv else [(mode, mode) for mode in ['inbox', 'inbox-dark', 'inbox-empty', 'inbox-private', 'inbox-legacy', 'inbox-dense', 'inbox-largest']] if '--inbox' in sys.argv else [(mode, mode) for mode in ['capacity', 'capacity-dark', 'capacity-overload', 'capacity-unknown', 'capacity-off', 'capacity-incomplete', 'capacity-refresh', 'capacity-empty', 'capacity-private', 'capacity-rest', 'capacity-largest']] if '--capacity' in sys.argv else [(mode, mode) for mode in ['lists', 'lists-dark', 'lists-private', 'lists-empty', 'lists-unavailable', 'lists-pending', 'lists-sync', 'lists-dense']] if '--lists' in sys.argv else [('light', 'catalog'), ('dark', 'dark'), ('empty', 'empty')] + [(mode, mode) for mode in ['productivity', 'productivity-dark', 'productivity-empty', 'productivity-private', 'productivity-legacy']]
    for mode, name in modes:
        subprocess.run([str(path / 'preview'), str(output / f'{name}.png'), mode], check=True)
