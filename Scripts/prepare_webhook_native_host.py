#!/usr/bin/env python3
"""Prepare an independent, signed Simulator acceptance host, never the shipping app."""
import argparse,json,plistlib,re,shutil
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
mode=p.add_mutually_exclusive_group(required=True)
mode.add_argument('--connection',type=Path)
mode.add_argument('--local',action='store_true',help='Local synthetic peer only; no hosted credentials')
p.add_argument('--output',required=True,type=Path)
p.add_argument('--feature',choices=['webhooks','automation','email'],default='webhooks')
a=p.parse_args()
if a.feature=='automation' and not a.local:p.error('Automation host supports only --local synthetic tests')
if a.feature=='email' and a.local:p.error('Email host requires a disposable hosted connection')
root=Path(__file__).resolve().parent.parent; target=a.output.resolve()
assert target != root and root not in target.parents, 'Host must be outside the source repository'
assert not target.exists(), 'Use a fresh owned host directory'
if a.local:
 c={'SUPABASE_ANON_KEY':'synthetic-public'};url='https://webhook-management.test'
else:
 assert a.connection.stat().st_mode & 0o077 == 0, 'Owner-private branch connection required'
 c=json.loads(a.connection.read_text());url=c['SUPABASE_URL']
 assert re.fullmatch(r'https://[a-z]{20}\.supabase\.co',url) and 'zqxflydiyfjeedqvyova' not in url, 'Disposable branch only'
 assert c['SUPABASE_ANON_KEY'] and c['SUPABASE_ANON_KEY'] != c['SUPABASE_SERVICE_ROLE_KEY']
target.mkdir(parents=True,mode=0o700)
for name in ['Taskfold.xcodeproj','Taskfold','TaskfoldWidgets','TaskfoldShare','TaskfoldUITests','TaskfoldTests','Config','TestSupport']:
 if (root/name).exists():shutil.copytree(root/name,target/name,ignore=shutil.ignore_patterns('xcuserdata','.DS_Store'))
original='com.dbakp.taskfold'; prefix=original+('.workflowtestsp1' if a.feature=='automation' else '.workflowtestswebhooks')
for f in [target/'Taskfold.xcodeproj/project.pbxproj',*target.rglob('*.entitlements')]:
 f.write_text(f.read_text().replace(original,prefix))
# Branch public configuration only. Admin credentials never enter any app bundle.
backend=target/'Taskfold/Backend.plist'
assert backend.exists(), 'Expected fixed Backend resource'
backend.write_bytes(plistlib.dumps({'URL':url,'Key':c['SUPABASE_ANON_KEY']}))
info=target/'Taskfold/Info.plist';value=plistlib.loads(info.read_bytes());name='Taskfold Local Automation Test' if a.feature=='automation' else ('Taskfold Local Webhook Test' if a.local else 'Taskfold Hosted Webhook Test');value['CFBundleDisplayName']=name;value['CFBundleName']=name
if a.feature=='email':
 value['TaskfoldEmailCaptureEnabled']=True;value['CFBundleDisplayName']='Taskfold Hosted Email Test';value['CFBundleName']='Taskfold Hosted Email Test'
for row in value.get('CFBundleURLTypes',[]):row['CFBundleURLSchemes']=['taskfold-local-automation-test' if a.feature=='automation' else 'taskfold-hosted-webhook-test']
info.write_bytes(plistlib.dumps(value))
print('Prepared isolated native Simulator inputs')
