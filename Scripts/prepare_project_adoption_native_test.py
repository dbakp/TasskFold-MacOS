#!/usr/bin/env python3
"""Prepare a reserved, network-blocked project-adoption native host."""
import argparse,hashlib,json,plistlib,subprocess,sys,uuid
from pathlib import Path

def write_if_changed(path, data):
 if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--combined',action='store_true',help='Adapt the owning combined custody contract; network-blocked UI only');p.add_argument('--files',action='store_true',help='Adapt the captured private-file contract onto the native synthetic workspace');p.add_argument('--connections',action='store_true');p.add_argument('--recordings',action='store_true',help='Adapt captured recording counts/policy onto the synthetic native workspace');p.add_argument('--private-history',action='store_true',help='Adapt the captured removed-only private history contract');p.add_argument('--reuse-host',action='store_true',help='Reuse a verified reserved team-editor host without copying products');a=p.parse_args();output=a.output.expanduser().resolve()
assert sum([a.connections,a.recordings,a.private_history,a.files,a.combined])<=1, 'Choose one native scenario'
root=Path(__file__).resolve().parent.parent
packet=root/('TaskfoldTests/Fixtures/team-project-adoption-connections-v1.json' if (a.connections or a.combined) else 'TaskfoldTests/Fixtures/team-project-adoption-v1.json');data=json.loads(packet.read_text());assert data['syntheticOnly'] and data['containerRemoved']
if a.reuse_host:
 marker=output/'team-editor-test-receipt.json'
 if marker.exists():
  receipt=json.loads(marker.read_text())
  assert receipt['namespace']=='workflowteststeameditbridge' and receipt['teamRolloutInCopyOnly'] is True
 else:
  # The stable Mac host predates the team-editor receipt. Verify its actual
  # app identity and private-storage isolation instead of inventing a marker.
  assert output==Path('/private/tmp/taskfold-owner-review-mac-host')
  project=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(output/'Taskfold.xcodeproj/project.pbxproj')],text=True))
  objects=project['objects'];app=next(v for v in objects.values() if v.get('isa')=='PBXNativeTarget' and v.get('name')=='Taskfold')
  configs=objects[app['buildConfigurationList']]['buildConfigurations']
  assert {objects[k]['buildSettings'].get('PRODUCT_BUNDLE_IDENTIFIER') for k in configs}=={'com.dbakp.taskfold.mac.workflowteststeameditbridge'}
  info=plistlib.loads((output/'Taskfold/Info.plist').read_bytes())
  assert info['CFBundleIdentifier']=='com.dbakp.taskfold.mac.workflowteststeameditbridge'
  assert 'group.com.dbakp.taskfold.workflowteststeameditbridge' in (output/'Taskfold/Core/Store.swift').read_text()
  backend=(output/'Taskfold/Core/Backend.swift').read_text()
  assert 'com.taskfold.workflowteststeameditbridge.session' in backend and all(x not in backend for x in ['com.taskfold.mac.session','com.taskfold.ios.session'])
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
file_source=None
if a.files or a.combined:
 import copy
 file_source=root/'TaskfoldTests/Fixtures/project-file-preparation-native-v1.json'
 captured=json.loads(file_source.read_text());assert captured['syntheticOnly'] and captured['containerRemoved']
 for stage in ['inspect','review']:
  data[stage]['contents']['file_custody']=captured['inspection']['contents']['file_custody']
  data[stage]['contents']['provider_files']=1
  data[stage]['contents']['attachments']=2
  data[stage]['file_preparation']=captured['inspection']['file_preparation']
 data['inspect']['commit_supported']=False
 data['review']['commit_supported']=False
 data['review']['requires_provider_custody']=True
 data['native_file_scenario']=True
 data['file_contract']={k:captured[k] for k in ['prepared','ready']}
 data['file_contract']['inventory_token']=captured['review']['file_transfer']['inventory_token']
 for stage in ['source_snapshot','destination_snapshot']:
  attachment=copy.deepcopy(captured['taskFileResolveReceipt']['attachment'])
  attachment['name']=captured['ready']['items'][0]['label']
  if stage=='source_snapshot':
   attachment['id']='fdad0000-0000-4000-8000-000000000030'
   attachment['storage_object_id']='fdad0000-0000-4000-8000-000000000031'
  data[stage]['tasks'][0]['attachments'].append(attachment)
if a.combined:
 import copy
 combined_source=root/'TaskfoldTests/Fixtures/combined-project-custody-v1.json'
 combined=json.loads(combined_source.read_text());assert combined['syntheticOnly']
 for stage in ['inspect','review']:
  for key in ['recording_custody','recording_transfer','recording_unfinished_transfer','recording_private_history_transfer','file_custody','provider_files','attachments','webhooks','email_routes','global_webhooks','project_webhooks','queued_webhook_events','inflight_webhook_events','pending_project_webhooks']:
   data[stage]['contents'][key]=copy.deepcopy(combined['inspection']['contents'][key])
  data[stage]['file_preparation']=combined['inspection']['file_preparation']
  data[stage]['commit_supported']=False
  data[stage]['connection_pause_supported']=combined['inspection']['connection_pause_supported']
 for stage in ['review','command','receipt']:
  for key in ['recording_policy','recording_count','unfinished_recording_count','retained_recording_count','connection_policy']:
   data[stage][key]=combined['review'][key]
  if stage!='command':data[stage]['connection_effects']=combined['review']['connection_effects']
 data['native_recording_scenario']='private-history'
 data['native_combined_scenario']=True
 ready=copy.deepcopy(combined['ready']);prepared=copy.deepcopy(ready)
 prepared['state']='preparing';prepared['prepared']=0
 for item in prepared['items']:item['state']='waiting'
 data['file_contract']={'prepared':prepared,'ready':ready,'inventory_token':combined['review']['file_transfer']['inventory_token']}
resource=output/'Taskfold/ProjectAdoptionNative.json';write_if_changed(resource,(json.dumps(data,indent=2)+'\n').encode())
project=output/'Taskfold.xcodeproj/project.pbxproj'
objects_data=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(project)],text=True))
objects=objects_data['objects']
path='Taskfold/ProjectAdoptionNative.json'
ref=next((k for k,v in objects.items() if v.get('isa')=='PBXFileReference' and v.get('path')==path),None)
if ref is None:
 ref=uuid.uuid4().hex[:24].upper();objects[ref]={'isa':'PBXFileReference','lastKnownFileType':'text.json','path':path,'sourceTree':'<group>'}
build=next((k for k,v in objects.items() if v.get('isa')=='PBXBuildFile' and v.get('fileRef')==ref),None)
if build is None:
 build=uuid.uuid4().hex[:24].upper();objects[build]={'isa':'PBXBuildFile','fileRef':ref}
app=next(v for v in objects.values() if v.get('isa')=='PBXNativeTarget' and v.get('name')=='Taskfold')
phase=next(objects[k] for k in app['buildPhases'] if objects[k]['isa']=='PBXResourcesBuildPhase')
if build not in phase['files']:phase['files'].append(build)
group=objects[objects_data['rootObject']]['mainGroup']
if ref not in objects[group]['children']:objects[group]['children'].append(ref)
write_if_changed(project,plistlib.dumps(objects_data))
subprocess.run(['plutil','-lint',str(project)],check=True,stdout=subprocess.DEVNULL)
info=output/'Taskfold/Info.plist';v=plistlib.loads(info.read_bytes());v['CFBundleDisplayName']='Taskfold Project Transfer Test';v['TaskfoldTeamsEnabled']=True;write_if_changed(info,plistlib.dumps(v))
(output/'project-adoption-host-receipt.json').write_text(json.dumps({'combined':a.combined,'combinedContractSHA256':hashlib.sha256(combined_source.read_bytes()).hexdigest() if a.combined else None,'fileContractSHA256':hashlib.sha256(file_source.read_bytes()).hexdigest() if file_source else None,'files':a.files or a.combined,'sourceFixtureSHA256':hashlib.sha256(packet.read_bytes()).hexdigest(),'recordingContractSHA256':hashlib.sha256(recording_source.read_bytes()).hexdigest() if recording_source else None,'preparedPacketSHA256':hashlib.sha256(resource.read_bytes()).hexdigest(),'recordings':a.recordings,'privateHistory':a.private_history,'reusedHost':a.reuse_host,'namespace':'workflowteststeameditbridge','syntheticOnly':True,'network':'All requests intercepted in the reserved DEBUG host; no real account/provider access','launch':['--team-editor-testing','--project-adoption-testing','--team-editor-reset']},indent=2)+'\n')
print(output)
