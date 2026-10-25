#!/usr/bin/env python3
"""Prepare a reserved, network-blocked project-adoption native host."""
import argparse,hashlib,json,plistlib,subprocess,sys,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--connections',action='store_true');a=p.parse_args();output=a.output.expanduser().resolve()
root=Path(__file__).resolve().parent.parent
packet=root/('TaskfoldTests/Fixtures/team-project-adoption-connections-v1.json' if a.connections else 'TaskfoldTests/Fixtures/team-project-adoption-v1.json');data=json.loads(packet.read_text());assert data['syntheticOnly'] and data['containerRemoved']
subprocess.run([sys.executable,str(Path(__file__).with_name('prepare_team_editor_native_test.py')),'--output',str(output)],check=True)
resource=output/'Taskfold/ProjectAdoptionNative.json';resource.write_bytes(packet.read_bytes())
project=output/'Taskfold.xcodeproj/project.pbxproj';s=project.read_text();ref=uuid.uuid4().hex[:24].upper();build=uuid.uuid4().hex[:24].upper()
s=s.replace('objects = {','objects = {\n'+ref+' = { isa = PBXFileReference; lastKnownFileType = text.json; path = "Taskfold/ProjectAdoptionNative.json"; sourceTree = "<group>"; };\n'+build+' = { isa = PBXBuildFile; fileRef = '+ref+'; };',1)
lines=s.splitlines();sourceRef=next(x.split(' =')[0] for x in lines if 'path = "Taskfold/ProjectAdoptionNativeFixture.swift"' in x)
# Find the primary app's resource phase through its existing Info/Backend resource.
backendRefs=[x.split(' =')[0] for x in lines if 'isa = PBXFileReference;' in x and ('Backend.plist' in x or 'Assets.xcassets' in x)]
backendBuilds=[x.split(' =')[0] for x in lines if 'isa = PBXBuildFile;' in x and any('fileRef = '+r+';' in x for r in backendRefs)]
resourceLines=[i for i,x in enumerate(lines) if 'isa = PBXResourcesBuildPhase;' in x and any(b in x for b in backendBuilds)]
assert resourceLines,'App resource phase not found';i=resourceLines[0];lines[i]=lines[i].replace('files = (','files = ('+build+',',1)
for i,x in enumerate(lines):
 if 'isa = PBXGroup;' in x and sourceRef in x:lines[i]=x.replace('children = (','children = ('+ref+',',1)
project.write_text('\n'.join(lines)+'\n')
info=output/'Taskfold/Info.plist';v=plistlib.loads(info.read_bytes());v['CFBundleDisplayName']='Taskfold Project Transfer Test';info.write_bytes(plistlib.dumps(v))
(output/'project-adoption-host-receipt.json').write_text(json.dumps({'sourceFixtureSHA256':hashlib.sha256(packet.read_bytes()).hexdigest(),'namespace':'workflowteststeameditbridge','syntheticOnly':True,'network':'All requests intercepted in the reserved DEBUG host; no real account/provider access','launch':['--team-editor-testing','--project-adoption-testing','--team-editor-reset']},indent=2)+'\n')
print(output)
