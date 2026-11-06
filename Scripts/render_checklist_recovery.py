#!/usr/bin/env python3
"""Render the production checklist review component without accounts or input.
The review values are a read-only layout fixture, not a recovery-engine substitute.
Core tests and native acceptance verify the actual engine/Store separately.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=True)
view = (repo/'Taskfold/Views/SubtaskOrganizer.swift').read_text()
marker = '// MARK: Checklist recovery review'
assert view.count(marker) == 1
component = 'import SwiftUI\n' + view.split(marker)[1]
source = r'''
import SwiftUI
import AppKit
// Data-only fixture for component layout; no production Store or account load.
enum ChecklistRecovery {
    enum Reason { case missing, duplicate, invalid, textOnly }
    struct Change: Identifiable {
        let id: Int; let title: String; let reason: Reason; let depth: Int
    }
    struct Review { let changes: [Change]; let itemCount: Int }
}
@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let review = ChecklistRecovery.Review(changes: [
            .init(id:0,title:"Plan the workshop",reason:.duplicate,depth:0),
            .init(id:1,title:"Keep participant notes and the complete multi-line instructions",reason:.duplicate,depth:1),
            .init(id:2,title:"Arrange the room",reason:.invalid,depth:0),
            .init(id:3,title:"Send the follow-up",reason:.textOnly,depth:0)],itemCount:5)
        for (name,dark) in [("recovery-light",false),("recovery-dark",true)] {
            let hosting = NSHostingView(rootView: NavigationStack {
                Form { ChecklistRecoveryReview(review:review,recover:{},original:{}) }.formStyle(.grouped).navigationTitle("Organize subtasks")
            }.environment(\.colorScheme,dark ? .dark : .light).frame(width:660,height:780))
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:780),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=hosting;window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.3));hosting.displayIfNeeded()
            guard let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else {throw NSError(domain:"Preview",code:1)}
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else {throw NSError(domain:"Preview",code:2)}
            try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name+".png"));window.close()
        }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='taskfold-checklist-preview-') as name:
    folder = Path(name); app = folder/'ChecklistPreview.app'; binary = app/'Contents/MacOS/Preview'; binary.parent.mkdir(parents=True)
    (folder/'Preview.swift').write_text(source); (folder/'Component.swift').write_text(component)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.dbakp.taskfold.checklistpreview','CFBundleExecutable':'Preview','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSUIElement':True}))
    result = subprocess.run(['xcrun','swiftc','-parse-as-library',str(folder/'Preview.swift'),str(folder/'Component.swift'),'-o',str(binary)],capture_output=True,text=True)
    if result.returncode: raise RuntimeError(result.stderr)
    result = subprocess.run([str(binary),str(args.output.resolve())],capture_output=True,text=True)
    if result.returncode: raise RuntimeError(result.stdout+result.stderr)
hash_file = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
evidence = {'images':{name:hash_file(args.output/name) for name in ['recovery-light.png','recovery-dark.png']},'sourceSHA256':{'Taskfold/Views/SubtaskOrganizer.swift':hash_file(repo/'Taskfold/Views/SubtaskOrganizer.swift')},'scope':'Actual production review component with data-only review fixture, default native tint, offscreen AppKit light/dark layout. No accounts, real Store, input, recovery mutation, Share action or full-app accessibility acceptance.'}
(args.output/'manifest.json').write_text(json.dumps(evidence,indent=2)+'\n')
print('Rendered two production checklist review components offscreen; no account or input used.')
