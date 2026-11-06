#!/usr/bin/env python3
"""Render the production Mac send form with read-only data, without an account load or UI input."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

p=argparse.ArgumentParser()
p.add_argument('--core-build',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();repo=Path(__file__).resolve().parents[1];a.output.mkdir(parents=True,exist_ok=True)
product=a.core_build/'out/Products/Debug'
if (product/'libTaskfoldCore.a').exists() and (product/'TaskfoldCore.swiftmodule').exists():
    module_path=product;link_inputs=['-L',str(product),'-lTaskfoldCore']
else:
    modules=list(a.core_build.rglob('Modules/TaskfoldCore.swiftmodule'))
    assert len(modules)==1,'Build this repository’s Core package first'
    debug=modules[0].parent.parent
    objects=sorted((debug/'TaskfoldCore.build').glob('*.swift.o'));assert objects
    module_path=debug/'Modules';link_inputs=[str(x) for x in objects]
view=(repo/'Taskfold/Views/ReminderEditor.swift').read_text()
marker='#if os(macOS)\nstruct LocationHandoffSendRequest:'
assert view.count(marker)==1
component='@testable import TaskfoldCore\nimport SwiftUI\nimport MapKit\n'+marker+view.split(marker)[1]
source=r'''
@testable import TaskfoldCore
import SwiftUI
import AppKit
import Observation
@MainActor @Observable final class Store {
    var userID="f083cafe-8100-4000-8000-000000000001"
    var workspaceGeneration=UUID()
    var locationHandoffAvailable=true
    func record(_ table:String,id:String)->Record? { var task=Record.task(user:userID);task["id"] = .string(id);task["title"] = .string("Prepare the studio review");return task }
    func locationHandoffs(workspace:WorkspaceBinding) async throws->[LocationHandoffRecord] { [] }
    func sendLocationHandoff(_ proposal:LocationHandoffProposal,workspace:WorkspaceBinding) async throws->LocationHandoffRecord { throw AppFailure(message:"Read-only component preview") }
    func discardLocationHandoff(_ row:LocationHandoffRecord,workspace:WorkspaceBinding) async throws { throw AppFailure(message:"Read-only component preview") }
}
@main struct Preview {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store=Store(), workspace=WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration)
        let place=LocationPrivatePlace.make(account:store.userID,name:"Sample design studio",latitude:55.676098,longitude:12.568337,radius:250)!
        for dark in [false,true] {
            let view=LocationHandoffSendView(request:.init(taskID:"f083cafe-8300-4000-8000-000000000001",workspace:workspace),initialPlace:place)
                .environment(store).environment(\.colorScheme,dark ? .dark : .light).tint(Color(red:0.88,green:0.12,blue:0.30)).frame(width:640,height:820)
            let host=NSHostingView(rootView:view)
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:820),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=host;window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.8));host.displayIfNeeded()
            try capture(host,"send-"+(dark ? "dark" : "light")+"-top")
            if let scroll=scrolls(host).first,let content=scroll.documentView {
                let point=NSPoint(x:0,y:content.isFlipped ? max(0,content.bounds.height-scroll.contentView.bounds.height) : 0)
                scroll.contentView.scroll(to:point);scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.2));host.displayIfNeeded()
                try capture(host,"send-"+(dark ? "dark" : "light")+"-bottom")
            }
            window.close()
        }
    }
    @MainActor static func capture(_ host:NSView,_ name:String) throws {
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw NSError(domain:"Render",code:1)}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else {throw NSError(domain:"Render",code:2)}
        try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name+".png"))
    }
    @MainActor static func scrolls(_ view:NSView)->[NSScrollView] { (view as? NSScrollView).map{[$0]} ?? view.subviews.flatMap(scrolls) }
}
'''
with tempfile.TemporaryDirectory(prefix='taskfold-handoff-render-') as temp:
    temp=Path(temp);app=temp/'HandoffPreview.app';binary=app/'Contents/MacOS/Preview';binary.parent.mkdir(parents=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.dbakp.taskfold.handoffpreview','CFBundleExecutable':'Preview','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSUIElement':True}))
    (temp/'Component.swift').write_text(component);(temp/'Preview.swift').write_text(source)
    result=subprocess.run(['xcrun','swiftc','-parse-as-library','-I',str(module_path),str(temp/'Component.swift'),str(temp/'Preview.swift')]+link_inputs+['-o',str(binary)],capture_output=True,text=True)
    if result.returncode:raise RuntimeError(result.stderr)
    result=subprocess.run([str(binary),str(a.output.resolve())],capture_output=True,text=True)
    if result.returncode:raise RuntimeError(result.stdout+result.stderr)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
manifest={'images':{f.name:sha(f) for f in sorted(a.output.glob('*.png'))},'sourceSHA256':{'Taskfold/Views/ReminderEditor.swift':sha(repo/'Taskfold/Views/ReminderEditor.swift')},'scope':'Production send form with actual owned Core models, synthetic initial pin and read-only Store stand-in. Offscreen native AppKit light/dark top/bottom layout only. No production Store, account load, UI input, Maps search, upload, permission, keyboard or VoiceOver acceptance.'}
(a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Rendered production send form in light/dark without an account or input.')
