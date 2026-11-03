#!/usr/bin/env python3
"""Prepare a reserved, network-blocked project-adoption native host."""
import argparse,hashlib,json,plistlib,subprocess,sys,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--connections',action='store_true');p.add_argument('--recordings',action='store_true',help='Adapt captured recording counts/policy onto the synthetic native workspace');p.add_argument('--private-history',action='store_true',help='Adapt the captured removed-only private history contract');p.add_argument('--reuse-host',action='store_true',help='Reuse a verified reserved team-editor host without copying products');a=p.parse_args();output=a.output.expanduser().resolve()
assert sum([a.connections,a.recordings,a.private_history])<=1, 'Choose one native scenario'
root=Path(__file__).resolve().parent.parent
packet=root/('TaskfoldTests/Fixtures/team-project-adoption-connections-v1.json' if a.connections else 'TaskfoldTests/Fixtures/team-project-adoption-v1.json');data=json.loads(packet.read_text());assert data['syntheticOnly'] and data['containerRemoved']
if a.reuse_host:
 receipt=json.loads((output/'team-editor-test-receipt.json').read_text())
 assert receipt['namespace']=='workflowteststeameditbridge' and receipt['teamRolloutInCopyOnly'] is True
 assert 'com.dbakp.taskfold.workflowteststeameditbridge' in (output/'Taskfold.xcodeproj/project.pbxproj').read_text() or 'com.dbakp.taskfold.mac.workflowteststeameditbridge' in (output/'Taskfold.xcodeproj/project.pbxproj').read_text()
else:
 subprocess.run([sys.executable,str(Path(__file__).with_name('prepare_team_editor_native_test.py')),'--output',str(output)],check=True)
recording_source=None
if a.recordings or a.private_history:
 recording_source=root/('TaskfoldTests/Fixtures/team-project-private-history-v1.json' if a.private_history else 'TaskfoldTests/Fixtures/team-project-unfinished-recordings-v1.json')
 captured=json.loads(recording_source.read_text());assert captured['syntheticOnly'] and captured['containerRemoved']
 if a.private_history:captured=captured['removedOnly']
 # Only capability/count/policy fields are adapted. Workspace IDs, snapshots,
 # audience tokens and responses remain a network-blocked native UI peer;
 # this is not an integrated SQL/gateway native acceptance claim.
 for stage in ['inspect','review']:
  for key in ['recording_custody','recording_transfer','recording_unfinished_transfer','recording_private_history_transfer']:
   if key in captured[stage]['contents']:data[stage]['contents'][key]=captured[stage]['contents'][key]
  data[stage]['commit_supported']=captured[stage]['commit_supported']
 for stage in ['review','command','receipt']:
  for key in ['recording_policy','recording_count','unfinished_recording_count']:
   data[stage][key]=captured[stage][key]
  if a.private_history:data[stage]['retained_recording_count']=captured[stage]['retained_recording_count']
 data['native_recording_scenario']='private-history' if a.private_history else 'mixed'
resource=output/'Taskfold/ProjectAdoptionNative.json';resource.write_text(json.dumps(data,indent=2)+'\n')
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
if 'path = "Taskfold/ProjectAdoptionNative.json"' not in project.read_text():
 project.write_text('\n'.join(lines)+'\n')
info=output/'Taskfold/Info.plist';v=plistlib.loads(info.read_bytes());v['CFBundleDisplayName']='Taskfold Project Transfer Test';info.write_bytes(plistlib.dumps(v))
(output/'project-adoption-host-receipt.json').write_text(json.dumps({'sourceFixtureSHA256':hashlib.sha256(packet.read_bytes()).hexdigest(),'recordingContractSHA256':hashlib.sha256(recording_source.read_bytes()).hexdigest() if recording_source else None,'preparedPacketSHA256':hashlib.sha256(resource.read_bytes()).hexdigest(),'recordings':a.recordings,'privateHistory':a.private_history,'reusedHost':a.reuse_host,'namespace':'workflowteststeameditbridge','syntheticOnly':True,'network':'All requests intercepted in the reserved DEBUG host; no real account/provider access','launch':['--team-editor-testing','--project-adoption-testing','--team-editor-reset']},indent=2)+'\n')
print(output)
