#!/usr/bin/env python3
"""Create-only native restore transport against disposable accounts, never real work.
Operator-provided fixture JSON: users [uuid, uuid], password. Login emails are
 taskfold-restore-<uuid>@example.invalid. Remove both users after the run.
"""
import argparse,json,plistlib,uuid
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from urllib.parse import urlencode
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('fixture',type=Path)
parser.add_argument('--configuration',type=Path,default=Path(__file__).resolve().parents[1]/'Taskfold/Backend.plist')
args=parser.parse_args(); fixture=json.loads(args.fixture.read_text()); config=plistlib.loads(args.configuration.read_bytes())
CREATE='handling=strict,resolution=ignore-duplicates,missing=default,return=representation'
def request(path,method='GET',body=None,token=None,prefer='return=representation',expected=(200,)):
    headers={'apikey':config['Key'],'Content-Type':'application/json','Prefer':prefer}
    if token: headers['Authorization']='Bearer '+token
    try:
        with urlopen(Request(config['URL']+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method),timeout=20) as response: status,raw=response.status,response.read()
    except HTTPError as error: status,raw=error.code,error.read()
    if status not in expected:
        detail=json.loads(raw) if raw else {}
        raise AssertionError(f'{method} {path.split("?")[0]}: HTTP {status}, code={detail.get("code")}, message={detail.get("message")}')
    return json.loads(raw) if raw else None

def login(user):return request('/auth/v1/token?grant_type=password','POST',{'email':f'taskfold-restore-{user}@example.invalid','password':fixture['password']})['access_token']
def post(table,row,token):
    conflict='user_id,id' if table in ['favorites','view_preferences','view_orders'] else 'id'
    return request('/rest/v1/'+table+'?'+urlencode({'on_conflict':conflict}),'POST',row,token,CREATE,(200,201))
def get(table,record,owner,token):return request('/rest/v1/'+table+'?'+urlencode({'id':'eq.'+record,'user_id':'eq.'+owner,'select':'*'}),token=token)
owner,outsider=fixture['users']; a,b,foreign=login(owner),login(owner),login(outsider)
project,label,section,task,view=[str(uuid.uuid4()) for _ in range(5)]
query={'version':1,'root':{'op':'predicate','field':'project','value':project}}
rows={
 'projects':{'id':project,'user_id':owner,'name':'Restore fixture','color':'#e31e4b','order_index':0,'source_metadata':{}},
 'labels':{'id':label,'user_id':owner,'name':'Restore label','color':'#e31e4b'},
 'sections':{'id':section,'user_id':owner,'project_id':project,'name':'Restore section','order_index':0},
 'tasks':{'id':task,'user_id':owner,'title':'Backup title','project_id':project,'section_id':section,'labels':[label],'completed':False,'priority':4,'deadline_date':'2026-10-25','duration_minutes':25,'due_date':'2026-10-25','due_time':'02:30:00','time_zone':'Europe/Copenhagen','scheduled_at':'2026-10-25T01:30:00Z','is_recurring':False,'source_metadata':{},'reminder_specs':[]},
 'saved_views':{'id':view,'user_id':owner,'name':'Restore filter','query_ast':query,'layout':'board','grouping':'priority','sort_by':'deadline','include_completed':False,'order_index':0},
 'favorites':{'id':'view:'+view,'user_id':owner,'order_index':0},
 'view_preferences':{'id':'project:'+project,'user_id':owner,'layout':'board','grouping':'priority','sort_by':'deadline','include_completed':False,'priority_filter':0,'overdue_collapsed':False},
 'view_orders':{'id':'project:'+project+'|section:'+section,'user_id':owner,'ids':[task]}}
for table,row in rows.items():
    inserted=post(table,row,a); assert len(inserted)==1 and inserted[0]['id']==row['id'],table
    seen=get(table,row['id'],owner,b); assert len(seen)==1 and seen[0]['user_id']==owner,table
request('/rest/v1/tasks?'+urlencode({'id':'eq.'+task}),'PATCH',{'title':'Newer server edit','duration_minutes':45},b)
for table,row in rows.items():
    assert post(table,row,a)==[],f'{table}: a restore retry updated an existing record'
    assert get(table,row['id'],owner,a)[0]['id']==row['id']
    assert get(table,row['id'],owner,foreign)==[],f'{table}: foreign workspace was visible'
seen=get('tasks',task,owner,a)[0]
assert seen['title']=='Newer server edit' and seen['duration_minutes']==45
assert seen['deadline_date']=='2026-10-25' and seen['scheduled_at'].startswith('2026-10-25T01:30:00')
assert get('saved_views',view,owner,b)[0]['query_ast']==query
assert get('view_orders',rows['view_orders']['id'],owner,b)[0]['ids']==[task]
request('/rest/v1/tasks?on_conflict=id','POST',rows['tasks'],foreign,CREATE,(403,))
print('PASS: all eight restore tables create with defaults and are read by a second session; repeat POSTs preserve newer server edits, fixed instants and relationships; foreign account cannot read or insert them.')
