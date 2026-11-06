#!/usr/bin/env python3
"""Exercise the capture listener pattern in actual SwiftUI, without URL dispatch.

This is a framework/model probe, not installed widget or native app acceptance.
It never opens Taskfold, reads its caches, or changes system preferences.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

SWIFT = r'''
import SwiftUI
import AppKit

@MainActor @Observable final class Probe {
    let fixed: Bool
    let account = "probe"
    let generation = UUID()
    var destination = "today"
    var revision = 0
    var queue = CapturePresentationQueue()
    var appeared: [String] = []
    var captures: [String] = []
    var capturesAfterSwitch: [String] = []
    var capturesAfterWarmRequest: [String] = []
    init(fixed: Bool) { self.fixed = fixed }
}
struct Surface: View {
    let probe: Probe
    let destination: String
    var body: some View {
        Text(destination)
            .onAppear { probe.appeared.append(destination) }
            .onChange(of: probe.revision, initial: probe.fixed) { _, _ in
                guard probe.destination == destination else { return }
                if !probe.fixed || probe.queue.take(destination: destination, account: probe.account, generation: probe.generation) {
                    probe.captures.append(destination)
                }
            }
    }
}
struct ProbeRoot: View {
    let probe: Probe
    var body: some View { Surface(probe: probe, destination: probe.destination).id(probe.destination) }
}
@main struct Main {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        let fixed = arguments[1] == "fixed"
        let path = URL(fileURLWithPath: arguments[2])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let probe = Probe(fixed: fixed)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ProbeRoot(probe: probe))
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            probe.destination = "inbox"
            probe.queue.request(destination: "inbox", workspace: WorkspaceBinding(account: probe.account, generation: probe.generation))
            probe.revision += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { probe.capturesAfterSwitch = probe.captures }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            probe.queue.request(destination: "inbox", workspace: WorkspaceBinding(account: probe.account, generation: probe.generation))
            probe.revision += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { probe.capturesAfterWarmRequest = probe.captures }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { probe.destination = "today" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { probe.destination = "inbox" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            let result: [String: Any] = ["mode": fixed ? "fixed" : "old", "appeared": probe.appeared, "captures": probe.captures, "capturesAfterSwitch": probe.capturesAfterSwitch, "capturesAfterWarmRequest": probe.capturesAfterWarmRequest, "requestPending": probe.queue.pending != nil]
            do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: path) }
            catch { fputs("Probe receipt could not be saved\n", stderr) }
            app.terminate(nil)
        }
        app.run()
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error('Output must be a new directory.')
    output.mkdir(parents=True)
    source = Path(__file__).resolve().parents[1]
    binding = (source / 'Taskfold/Core/InboxReview.swift').read_text()
    match = re.search(r'struct WorkspaceBinding:.*?\n}', binding, re.S)
    assert match, 'Workspace binding declaration not found'
    (output / 'WorkspaceBinding.swift').write_text('import Foundation\n' + match.group(0) + '\n')
    (output / 'Probe.swift').write_text(SWIFT)
    capture = source / 'Taskfold/Core/CapturePresentation.swift'
    executable = output / 'capture-probe'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(output / 'WorkspaceBinding.swift'), str(capture), str(output / 'Probe.swift'), '-o', str(executable)], check=True)
    results = []
    for mode in ['old', 'fixed']:
        receipt = output / (mode + '.json')
        subprocess.run([str(executable), mode, str(receipt)], check=True, timeout=20)
        results.append(json.loads(receipt.read_text()))
    assert 'today' in results[0]['appeared'] and 'inbox' in results[0]['appeared']
    assert results[0]['capturesAfterSwitch'] == [] and results[0]['capturesAfterWarmRequest'] == ['inbox'] and results[0]['requestPending'], 'Old listener must reproduce the dropped presentation but handle an already-mounted view'
    assert 'inbox' in results[1]['appeared']
    assert results[1]['capturesAfterSwitch'] == ['inbox'] and results[1]['capturesAfterWarmRequest'] == ['inbox', 'inbox'], 'Both new and mounted destinations must consume their request'
    assert results[1]['captures'] == ['inbox', 'inbox'] and not results[1]['requestPending'], 'Remount without another request must not reopen capture'
    final = {'scope': 'Actual SwiftUI listener-pattern and owned capture-queue probe; no app/widget/URL dispatch.', 'results': results, 'captureSourceSHA256': hashlib.sha256(capture.read_bytes()).hexdigest(), 'workspaceBindingSHA256': hashlib.sha256(match.group(0).encode()).hexdigest()}
    (output / 'receipt.json').write_text(json.dumps(final, indent=2) + '\n')
    print(json.dumps(final))


if __name__ == '__main__':
    main()
