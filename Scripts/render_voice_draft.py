#!/usr/bin/env python3
"""Render the owned voice view offscreen with a minimal read-only workspace fixture.
No recorder is started, no input is posted and no real Store or credentials load.
This is component layout evidence, not complete Mac app or microphone acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=True)
source = r'''
import SwiftUI
import AppKit
import Observation
@MainActor @Observable final class Store {
    var userID = "component-fixture"
    var workspaceGeneration = UUID()
}
@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "com.dbakp.taskfold.voicepreview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (name, dark) in [("voice-ready-light", false), ("voice-ready-dark", true)] {
            let store = Store(), request = VoiceDraftRequest(workspace: WorkspaceBinding(account: "component-fixture", generation: storeGeneration()), original: "Original typed draft")
            store.workspaceGeneration = request.workspace.generation
            let hosting = NSHostingView(rootView: VoiceDraftView(request: request, onApply: { _ in false }).environment(store).defaultAppStorage(defaults).environment(\.colorScheme, dark ? .dark : .light).frame(width: 640, height: 680))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.3)); hosting.displayIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw NSError(domain: "Preview", code: 1) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
            window.close()
        }
    }
    static func storeGeneration() -> UUID { UUID() }
}
'''
backend = (repo/'Taskfold/Core/Backend.swift').read_text()
helpers = (repo/'Taskfold/Core/InboxReview.swift').read_text().split('enum InboxReviewBatch')[0] + '\n' + re.search(r'struct AppFailure: LocalizedError \{.*?\n\}', backend, re.S).group(0)
with tempfile.TemporaryDirectory(prefix='taskfold-voice-preview-') as name:
    folder = Path(name); app = folder/'VoicePreview.app'; binary = app/'Contents/MacOS/Preview'; binary.parent.mkdir(parents=True)
    (folder/'Preview.swift').write_text(source); (folder/'Helpers.swift').write_text(helpers)
    info = {'CFBundleIdentifier':'com.dbakp.taskfold.voicepreview','CFBundleExecutable':'Preview','CFBundleName':'VoicePreview','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSUIElement':True,'NSMicrophoneUsageDescription':'Only record after an explicit recording action.','NSSpeechRecognitionUsageDescription':'On-device transcription into a reviewed draft.'}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    result = subprocess.run(['xcrun','swiftc','-parse-as-library',str(folder/'Helpers.swift'),str(folder/'Preview.swift'),str(repo/'Taskfold/Core/VoiceDraft.swift'),str(repo/'Taskfold/VoiceCapture.swift'),str(repo/'Taskfold/Views/VoiceDraftView.swift'),'-o',str(binary)],text=True,capture_output=True)
    if result.returncode:raise RuntimeError(result.stderr)
    result = subprocess.run([str(binary),str(args.output.resolve())],text=True,capture_output=True)
    if result.returncode:raise RuntimeError(result.stdout+result.stderr)
images = ['voice-ready-light.png','voice-ready-dark.png']
evidence = {'images':{name:hashlib.sha256((args.output/name).read_bytes()).hexdigest() for name in images},'sourceSHA256':{name:hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in ['Taskfold/Core/VoiceDraft.swift','Taskfold/VoiceCapture.swift','Taskfold/Views/VoiceDraftView.swift']},'scope':'Real production voice view, minimal read-only Store fixture, offscreen AppKit light/dark layout; no recording, permission request or full-app interaction.'}
(args.output/'manifest.json').write_text(json.dumps(evidence,indent=2)+'\n')
print('Rendered two offscreen voice view previews; no recording started.')
