#!/usr/bin/env python3
"""Scoped real Auth/REST/Storage acceptance. Only generated disposable users.
Credentials are read/written in a supplied owner-private file, never printed.
No real account may be supplied as a fixture. No email is sent by creation.
"""
import argparse, base64, hashlib, json, os, secrets, urllib.request, urllib.error, uuid, time
from datetime import datetime, timezone
from pathlib import Path

URL = 'https://zqxflydiyfjeedqvyova.supabase.co'
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('Redirect refused')

class Acceptance:
    def __init__(self, path):
        self.path = path.resolve()
        if self.path.stat().st_mode & 0o077: raise RuntimeError('Fixture must be owner-private')
        self.state = json.loads(self.path.read_text())
        if self.state['url'] != URL: raise RuntimeError('Unexpected project')
        self.http = urllib.request.build_opener(NoRedirect())
        self.checks = {}
    def save(self):
        fd = os.open(self.path, os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f: json.dump(self.state, f)
    def call(self, path, method='GET', value=None, token=None, raw=None, headers=None):
        hs = {'apikey': self.state['publicKey'], 'Authorization': 'Bearer ' + (token or self.state['adminKey'])}
        hs.update(headers or {})
        data = raw
        if value is not None: data = json.dumps(value).encode(); hs['Content-Type'] = 'application/json'
        req = urllib.request.Request(URL+path, data=data, headers=hs, method=method)
        try:
            with self.http.open(req, timeout=35) as res: return res.status, res.read(2_000_001)
        except urllib.error.HTTPError as e: return e.code, e.read(4096)
    def require(self, name, value):
        self.checks[name] = bool(value)
        if not value: raise RuntimeError('Acceptance failed: '+name)
    def json(self, path, method='GET', value=None, token=None, headers=None):
        status, data = self.call(path,method,value,token,headers=headers)
        if not 200 <= status < 300: raise RuntimeError('HTTP '+str(status)+' at '+path.split('?')[0])
        return json.loads(data) if data else None
    def owned_user(self, role):
        user = self.state['accounts'][role]
        server = self.json('/auth/v1/admin/users/'+user['id'])
        self.require(role+'IsGeneratedDisposableAccount', server['id']==user['id'] and server['email']==user['email'] and server.get('app_metadata',{}).get('taskfold_removal_fixture')==self.state['fixture'])
        return user
    def table(self, name, value, token):
        return self.json('/rest/v1/'+name,'POST',value,token,{'Prefer':'return=representation'})[0]
    def seed(self):
        if self.state.get('accounts') and not self.state.get('cleaned'): raise RuntimeError('Existing fixture must be resumed, not replaced')
        self.state={key:self.state[key] for key in ['url','adminKey','publicKey']}
        self.state.update(fixture=str(uuid.uuid4()),accounts={},cleaned=False,files=[]); self.save()
        for role in ['A','B']:
            identity=str(uuid.uuid4()); email='taskfold-removal-live-'+identity+'@example.invalid'; password=secrets.token_urlsafe(40)
            created=self.json('/auth/v1/admin/users','POST',{'email':email,'password':password,'email_confirm':True,'app_metadata':{'taskfold_removal_fixture':self.state['fixture']}})
            # Save immediately so a later network failure never loses a created user.
            self.state['accounts'][role]={'id':created['id'],'email':email,'password':password};self.save()
            session=self.json('/auth/v1/token?grant_type=password','POST',{'email':email,'password':password},self.state['publicKey'])
            self.state['accounts'][role]['session']=session;self.save();self.owned_user(role)
        a,b=(self.state['accounts'][x] for x in ['A','B']); ta,tb=(x['session']['access_token'] for x in [a,b])
        pa=self.table('projects',{'id':str(uuid.uuid4()),'user_id':a['id'],'name':'Synthetic removal owner project'},ta)
        pb=self.table('projects',{'id':str(uuid.uuid4()),'user_id':b['id'],'name':'Synthetic surviving project'},tb)
        self.state['projects']={'A':pa['id'],'B':pb['id']};self.save()
        for owner,member,project,auth,recipient in [(a,b,pa,ta,tb),(b,a,pb,tb,ta)]:
            inv=self.table('project_collaborators',{'id':str(uuid.uuid4()),'project_id':project['id'],'invited_by':owner['id'],'invited_email':member['email'],'role':'collaborator','status':'pending'},auth)
            self.json('/rest/v1/project_collaborators?id=eq.'+inv['id'],'PATCH',{'status':'accepted'},recipient,{'Prefer':'return=representation'})
        own=self.table('tasks',{'id':str(uuid.uuid4()),'user_id':a['id'],'project_id':pa['id'],'title':'Synthetic account-owned work'},ta)
        shared=self.table('tasks',{'id':str(uuid.uuid4()),'user_id':b['id'],'project_id':pa['id'],'assigned_to':a['id'],'title':'Preserve outsider work'},tb)
        survive=self.table('tasks',{'id':str(uuid.uuid4()),'user_id':b['id'],'project_id':pb['id'],'title':'Preserve shared history'},tb)
        comment_id=str(uuid.uuid4())
        comment_result=self.json('/rest/v1/rpc/taskfold_write_comment','POST',{'_operation_id':str(uuid.uuid4()),'_comment_id':comment_id,'_task_id':survive['id'],'_task_generation':survive['task_generation'],'_project_id':pb['id'],'_expected_revision':0,'_body':'Synthetic shared history must survive','_mentions':[],'_delete':False},ta)
        self.require('SharedCommentSavedThroughPublicRPC',comment_result.get('status')=='saved')
        self.state['tasks']={'A':own['id'],'shared':shared['id'],'B':survive['id']};self.state['comment']=comment_id;self.save()
        png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6XGkAAAAASUVORK5CYII=')
        files=[]
        for role,bucket,name,body,mime in [('A','avatars','avatar.png',png,'image/png'),('A','task-attachments','proof.txt',b'Synthetic account removal attachment','text/plain'),('B','avatars','avatar.png',png,'image/png'),('B','task-attachments','keep.txt',b'Keep outsider bytes exactly','text/plain')]:
            user=self.state['accounts'][role];path=user['id']+'/'+name
            status,_=self.call('/storage/v1/object/'+bucket+'/'+path,'POST',token=user['session']['access_token'],raw=body,headers={'Content-Type':mime})
            self.require(role+bucket+'UploadSucceeded',200<=status<300)
            entry={'role':role,'bucket':bucket,'path':path,'SHA256':hashlib.sha256(body).hexdigest()};files.append(entry);self.state['files']=files;self.save()
            status,actual=self.call('/storage/v1/object/authenticated/'+bucket+'/'+path,token=user['session']['access_token'])
            self.require(role+bucket+'ActualBytesReadable',status==200 and hashlib.sha256(actual).hexdigest()==entry['SHA256'])
        self.state['baselineB']=survive;self.save()
        self.require('RealPasswordSessionsIssued',bool(ta and tb))
    def upload_probe(self):
        # The orchestrator holds the same account's begin transaction open.
        # A real Storage write must wait for that row lock, then refuse the
        # pending account. This does not prove first-authorization visibility
        # for every full endpoint/upload interleaving.
        time.sleep(6)
        requested=datetime.now(timezone.utc).isoformat()
        a=self.state['accounts']['A']; started=time.monotonic()
        status,body=self.call('/storage/v1/object/avatars/'+a['id']+'/concurrent-proof.png','POST',token=a['session']['access_token'],raw=b'synthetic lock proof',headers={'Content-Type':'image/png'})
        elapsed=time.monotonic()-started
        refused=status in [401,403] or status==400 and str(json.loads(body).get('statusCode')) in ['401','403']
        self.probe={'requestedAt':requested,'finishedAt':datetime.now(timezone.utc).isoformat(),'httpStatus':status,'elapsedSeconds':round(elapsed,3),'statusCode':str(json.loads(body).get('statusCode')) if body.startswith(b'{') else None}
        self.require('PendingRemovalRefusesRealStorageWrite',refused)
        self.require('RealStorageWriteWaitedForAuthorizationLock',elapsed>=1)
        self.state['probeElapsedSeconds']=round(elapsed,3);self.save()
    def remove(self):
        a=self.owned_user('A');self.owned_user('B');token=a['session']['access_token']
        endpoint='/functions/v1/delete-account'
        status,_=self.call(endpoint,'POST',{},token)
        self.require('LegacyClientRefused',status==428)
        status,body=self.call('/auth/v1/admin/users/'+a['id'])
        self.require('LegacyRefusalPreservesAuth',status==200 and json.loads(body)['id']==a['id'])
        status,_=self.call(endpoint,'POST',{'account':self.state['accounts']['B']['id']},token,headers={'X-Taskfold-Account-Removal':'2'})
        self.require('CallerCannotChooseAnotherAccount',status==400)
        prepared=self.json(endpoint,'POST',{'action':'prepare'},token,{'X-Taskfold-Account-Removal':'2'})
        self.require('LivePreparationMatchesAccount',prepared.get('prepared') is True and prepared.get('account')==a['id'] and isinstance(prepared.get('proof'),str))
        self.state['statusProof']=prepared['proof'];self.save()
        headers={'X-Taskfold-Account-Removal':'2','X-Taskfold-Account-Removal-Proof':prepared['proof']}
        status,body=self.call(endpoint,'POST',{},token,headers=headers)
        self.require('LiveEndpointConfirmedDeletion',status==200 and json.loads(body).get('deleted') is True)
        self.state['ownerRemoved']=True;self.save()
        status,body=self.call(endpoint,'POST',{},token,headers=headers)
        self.require('OriginalAuthorizationRecoversSuccessAfterAuthDeletion',status==200 and json.loads(body).get('deleted') is True)
        self.verify()
    def verify(self):
        a,b=(self.state['accounts'][x] for x in ['A','B']);tb=b['session']['access_token']
        status,_=self.call('/auth/v1/admin/users/'+a['id']);self.require('OwnerAuthHardDeleted',status==404)
        self.owned_user('B')
        status,_=self.call('/auth/v1/user',token=a['session']['access_token']);self.require('RemovedAuthCannotReadOwnUser',status in [401,403])
        for entry in self.state['files']:
            status,body=self.call('/storage/v1/object/authenticated/'+entry['bucket']+'/'+entry['path'])
            self.require(entry['role']+entry['bucket']+('ActualBytesRemoved' if entry['role']=='A' else 'ActualBytesPreserved'), status in [400,404] if entry['role']=='A' else status==200 and hashlib.sha256(body).hexdigest()==entry['SHA256'])
        preserved=self.json('/rest/v1/tasks?id=eq.'+self.state['tasks']['B'],token=tb)
        self.require('OutsiderIndependentTaskExactlyPreserved',preserved==[self.state['baselineB']])
        shared=self.json('/rest/v1/tasks?id=eq.'+self.state['tasks']['shared'],token=tb)
        self.require('OutsiderSharedTaskSurvivesUnassigned',len(shared)==1 and shared[0]['title']=='Preserve outsider work' and shared[0]['project_id'] is None and shared[0]['assigned_to'] is None)
        comment=self.json('/rest/v1/task_comments?id=eq.'+self.state['comment'],token=tb)
        self.require('SharedHistorySurvivesAnonymously',len(comment)==1 and comment[0]['body']=='Synthetic shared history must survive' and comment[0]['author_id'] is None)
        status,denial=self.call('/storage/v1/object/avatars/'+a['id']+'/recreate.png','POST',token=a['session']['access_token'],raw=b'old JWT must not recreate data',headers={'Content-Type':'image/png'})
        self.require('StaleJWTUploadRefused',status in [401,403] or status==400 and str(json.loads(denial).get('statusCode')) in ['401','403'])
    def watch_native_pause(self, expire=False):
        # Independent server verification while the native app still retains
        # its saved cache and unconfirmed private recovery command.
        marker=self.path.parent/'native-recovery-paused.json'
        deadline=time.monotonic()+150
        while time.monotonic()<deadline:
            try: paused=json.loads(marker.read_text())
            except (FileNotFoundError,json.JSONDecodeError): paused={}
            if paused.get('owner')==self.state['accounts']['A']['id'] and paused.get('cachePreserved') is True: break
            time.sleep(.25)
        else: raise RuntimeError('Native recovery pause not observed')
        self.verify()
        self.require('ServerVerifiedWhileNativeRecoveryPaused',True)
        if expire:
            token_hash=paused.get('authorizationHash','')
            if len(token_hash)!=64 or any(c not in '0123456789abcdef' for c in token_hash): raise RuntimeError('Missing exact removal receipt hash')
            ready=self.path.parent/'native-expiry-ready.json'
            fd=os.open(ready,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
            with os.fdopen(fd,'w') as f: json.dump({'owner':self.state['accounts']['A']['id'],'outsider':self.state['accounts']['B']['id'],'fixture':self.state['fixture'],'authorizationHash':token_hash},f)
            deadline=time.monotonic()+45
            while time.monotonic()<deadline:
                try: pruned=json.loads((self.path.parent/'native-receipt-pruned.json').read_text())
                except (FileNotFoundError,json.JSONDecodeError): pruned={}
                if pruned.get('owner')==self.state['accounts']['A']['id'] and pruned.get('pruned') is True: break
                time.sleep(.25)
            else: raise RuntimeError('Exact synthetic receipt was not pruned')
            status=self.json('/rest/v1/rpc/taskfold_account_removal_status','POST',{'_token_hash':token_hash})
            self.require('ExpiredSyntheticReceiptIsUnavailable',status is None)
        target=self.path.parent/'native-server-verified.json'
        fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as f: json.dump({'owner':self.state['accounts']['A']['id'],'verified':True},f)
    def watch_native_expiry_pause(self):
        self.watch_native_pause(expire=True)
    def cleanup(self):
        # Only exact Admin-created IDs/email/metadata from this private fixture
        # may be deleted; real accounts can never be supplied as cleanup input.
        for role in list(self.state['accounts']):
            user=self.state['accounts'][role];status,_=self.call('/auth/v1/admin/users/'+user['id'])
            if status==404:continue
            self.owned_user(role)
            for entry in self.state.get('files',[]):
                if entry['role']==role:
                    status,_=self.call('/storage/v1/object/'+entry['bucket'],'DELETE',{'prefixes':[entry['path']]})
                    self.require(role+entry['bucket']+'FixtureFileCleanup',200<=status<300)
            status,_=self.call('/auth/v1/admin/users/'+user['id'],'DELETE',{'should_soft_delete':False})
            self.require(role+'DisposableAuthCleanup',200<=status<300)
        for role,user in self.state['accounts'].items():
            self.require(role+'AuthAbsentAfterCleanup',self.call('/auth/v1/admin/users/'+user['id'])[0]==404)
        self.state['cleaned']=True;self.save()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--private-fixture',type=Path,required=True);p.add_argument('--phase',choices=['seed','upload-probe','watch-native-pause','watch-native-expiry-pause','remove','verify','cleanup'],required=True);p.add_argument('--evidence',type=Path,required=True);a=p.parse_args()
    run=Acceptance(a.private_fixture)
    try:
        getattr(run,a.phase.replace('-','_'))()
        report={'phase':a.phase,'status':'passed','checks':run.checks,'fixture':run.state.get('fixture'),'accounts':{r:u['id'] for r,u in run.state.get('accounts',{}).items()},'probe':getattr(run,'probe',None),'probeElapsedSeconds':run.state.get('probeElapsedSeconds'),'scope':'Real deployed endpoint/Auth/REST/Storage with generated users only. upload-probe requires a separately held service-only begin transaction; it proves that controlled lock overlap, not every full endpoint/upload race or native UI.'}
    except Exception as e:
        report={'phase':a.phase,'status':'failed','checks':run.checks,'probe':getattr(run,'probe',None),'error':str(e),'scope':'No secret or HTTP response body included.'}
        a.evidence.write_text(json.dumps(report,indent=2)+'\n');raise SystemExit(str(e))
    a.evidence.write_text(json.dumps(report,indent=2)+'\n');print(a.phase+': '+report['status']+' ('+str(len(run.checks))+' checks)')
