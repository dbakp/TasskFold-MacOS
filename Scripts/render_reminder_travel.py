#!/usr/bin/env python3
"""Render owned Mac reminder editor/zone-picker components offscreen with synthetic state.
No real workspace, calendar provider, account, permission request or notification is opened.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--core-build', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
repo = Path(__file__).resolve().parents[1]
product = a.core_build / 'out/Products/Debug'
if (product/'libTaskfoldCore.a').exists():
    modules = product
    link = ['-L', str(product), '-lTaskfoldCore']
else:
    paths = list(a.core_build.rglob('Modules/TaskfoldCore.swiftmodule'))
    if len(paths) != 1:
        raise RuntimeError('Build the owned Core package first')
    modules = paths[0].parent
    link = [str(x) for x in sorted((modules.parent/'TaskfoldCore.build').glob('*.swift.o'))]
view = (repo/'Taskfold/Views/ReminderEditor.swift').read_text()
view = '@testable import TaskfoldCore\nimport SwiftUI\nimport AppKit\n' + view[view.index('struct ReminderDraft:'):view.index('struct ReminderSystemSettingsButton:')]
fixture = r'''
private extension ReminderTimeZonePicker {
    init(previewSelection: String, previewQuery: String) {
        selection = previewSelection; choose = { _ in "Read-only fixture" }
        _query = State(initialValue: previewQuery)
    }
}
@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        let day = TaskPlanner.dayKey(c.date(byAdding: .day, value: 2, to: Date())!, calendar: c)
        let schedule = ReminderCalendarSchedule.make("every day for 5 occurrences", time: "09:00", start: day, zone: "America/New_York")!
        let spec = ReminderSpec.recurring(schedule)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let draft = ReminderDraft(spec: spec, index: 0, workspace: WorkspaceBinding(account: "component-fixture", generation: UUID()), taskID: UUID().uuidString, taskGeneration: .null, wasPersisted: false, originalRows: [.object(spec.raw)])
            try render(ReminderSpecEditor(draft: draft, save: { _ in "Read-only fixture" }), width: 640, height: 760, dark: dark, name: "travel-" + suffix, bottom: true)
            try render(ReminderTimeZonePicker(previewSelection: schedule.timeZone, previewQuery: "New York"), width: 500, height: 600, dark: dark, name: "zone-picker-" + suffix, bottom: false)
        }
    }
    @MainActor static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool, name: String, bottom: Bool) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.4)); host.displayIfNeeded()
        try capture(host, name: name + "-top")
        if bottom, let scroll = scrolls(host).first, let content = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: content.isFlipped ? max(0, content.bounds.height - scroll.contentView.bounds.height) : 0))
            scroll.reflectScrolledClipView(scroll.contentView); host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2)); host.displayIfNeeded()
            try capture(host, name: name + "-bottom")
        }
        window.close()
    }
    @MainActor static func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
    @MainActor static func capture(_ view: NSView, name: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "Preview", code: 1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
    }
}
'''
a.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-travel-preview-') as folder:
    folder = Path(folder)
    (folder/'Preview.swift').write_text(view + '\n' + fixture)
    run = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-I', str(modules), str(folder/'Preview.swift')] + link + ['-o', str(folder/'Preview')], text=True, capture_output=True)
    if run.returncode:
        raise RuntimeError(run.stderr)
    run = subprocess.run([str(folder/'Preview'), str(a.output.resolve())], text=True, capture_output=True)
    if run.returncode:
        raise RuntimeError(run.stdout + run.stderr)
images = sorted(a.output.glob('*.png'))
if len(images) != 6:
    raise RuntimeError('Expected six light/dark editor/picker component captures')
proof = {'sourceSHA256': {f: hashlib.sha256((repo/f).read_bytes()).hexdigest() for f in ['Taskfold/Core/Reminders.swift', 'Taskfold/Views/ReminderEditor.swift']}, 'images': {x.name: hashlib.sha256(x.read_bytes()).hexdigest() for x in images}, 'scope': 'Production Mac editor/picker bodies with read-only synthetic state, tested owned Core, offscreen light/dark rendering. Picker query seeded by fixture-only extension. Window chrome/native interaction/VoiceOver/notification delivery not accepted by these components.'}
(a.output/'manifest.json').write_text(json.dumps(proof, indent=2)+'\n')
print('Rendered six actual reminder travel/zone-picker components')
