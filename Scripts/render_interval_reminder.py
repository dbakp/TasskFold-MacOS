#!/usr/bin/env python3
"""Render the actual Mac reminder editor with a read-only interval fixture.
Requires this repository's tested Core build. Opens no app account or permission dialog.
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
if (product / 'libTaskfoldCore.a').exists() and (product / 'TaskfoldCore.swiftmodule').exists():
    module_path = product
    link_inputs = ['-L', str(product), '-lTaskfoldCore']
else:
    modules = list(a.core_build.rglob('Modules/TaskfoldCore.swiftmodule'))
    if len(modules) != 1:
        raise RuntimeError('Build the owned Core package first, then pass its scratch directory')
    debug = modules[0].parent.parent
    objects = sorted((debug / 'TaskfoldCore.build').glob('*.swift.o'))
    if not objects:
        raise RuntimeError('Owned Core objects missing')
    module_path = debug / 'Modules'
    link_inputs = [str(x) for x in objects]
view = (repo / 'Taskfold/Views/ReminderEditor.swift').read_text()
view = '@testable import TaskfoldCore\nimport SwiftUI\n' + view[view.index('struct ReminderDraft:'):view.index('struct ReminderSystemSettingsButton:')]
preview = r'''
@testable import TaskfoldCore
import SwiftUI
import AppKit
@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for dark in [false, true] {
            let start = Date().addingTimeInterval(3600)
            let spec = ReminderSpec.interval(ReminderIntervalSchedule(start: start, everyMinutes: 30, count: 3, until: start.addingTimeInterval(86400))!)
            let draft = ReminderDraft(spec: spec, index: 0, workspace: WorkspaceBinding(account: "component-fixture", generation: UUID()), taskID: UUID().uuidString, taskGeneration: .null, wasPersisted: false, originalRows: [.object(spec.raw)])
            let host = NSHostingView(rootView: ReminderSpecEditor(draft: draft, save: { _ in "Read-only fixture" }).environment(\.colorScheme, dark ? .dark : .light).frame(width: 640, height: 760))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.4)); host.displayIfNeeded()
            try capture(host, name: "interval-" + (dark ? "dark" : "light") + "-top")
            if let scroll = scrolls(host).first, let content = scroll.documentView {
                let point = NSPoint(x: 0, y: content.isFlipped ? max(0, content.bounds.height - scroll.contentView.bounds.height) : 0)
                scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2)); host.displayIfNeeded()
                try capture(host, name: "interval-" + (dark ? "dark" : "light") + "-bottom")
            }
            window.close()
        }
    }
    @MainActor static func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
    @MainActor static func capture(_ host: NSView, name: String) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "Preview", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
    }
}
'''
a.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='taskfold-interval-preview-') as folder:
    folder = Path(folder)
    (folder/'Editor.swift').write_text(view)
    (folder/'Preview.swift').write_text(preview)
    command = ['xcrun', 'swiftc', '-parse-as-library', '-I', str(module_path), str(folder/'Editor.swift'), str(folder/'Preview.swift')] + link_inputs + ['-o', str(folder/'Preview')]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    result = subprocess.run([str(folder/'Preview'), str(a.output.resolve())], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
images = sorted(a.output.glob('interval-*.png'))
if len(images) != 4:
    raise RuntimeError('Expected top and bottom of the actual scrollable editor in light/dark')
proof = {'sourceSHA256': {f: hashlib.sha256((repo/f).read_bytes()).hexdigest() for f in ['Taskfold/Views/ReminderEditor.swift', 'Taskfold/Core/ReminderIntervalSchedule.swift', 'Taskfold/Core/Reminders.swift']}, 'images': {x.name: hashlib.sha256(x.read_bytes()).hexdigest() for x in images}, 'scope': 'Actual Mac ReminderSpecEditor compiled against this repository\'s tested Core. Read-only synthetic interval, offscreen top/bottom light/dark. No full app interaction, recording or notification delivery acceptance.'}
(a.output/'manifest.json').write_text(json.dumps(proof, indent=2)+'\n')
print('Rendered four actual Mac editor component previews')
