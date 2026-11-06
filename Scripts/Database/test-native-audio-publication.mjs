import assert from 'node:assert/strict';
import {execFile,spawn} from 'node:child_process';
import {promisify,isDeepStrictEqual} from 'node:util';
import {randomUUID,randomBytes,createHash} from 'node:crypto';
import {readFile as fsReadFile,writeFile as fsWriteFile,mkdir as fsMkdir,rm as fsRm,stat as fsStat,realpath,readdir as fsReaddir} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {createFullSchemaAudioFixture} from './full-schema-audio-fixture.mjs';
assert(Number(process.versions.node.split('.')[0])>=22,'Native full-schema tests require Node 22 or newer; use the bundled runtime.');
const exec=promisify(execFile),[platform,output,mode,transferFlag]=process.argv.slice(2),repo=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
assert(mode===undefined||mode==='--keychain');const protectedStorage=mode==='--keychain';
assert(transferFlag===undefined||['--project-transfer','--project-transfer-mixed','--project-transfer-combined','--project-transfer-connected','--project-transfer-paged'].includes(transferFlag));const pagedFiles=transferFlag==='--project-transfer-paged',fileCount=pagedFiles?101:1,connectedCustody=pagedFiles||transferFlag==='--project-transfer-connected',combinedCustody=connectedCustody||transferFlag==='--project-transfer-combined',mixedRecordings=combinedCustody||transferFlag==='--project-transfer-mixed',projectTransfer=transferFlag!==undefined;assert(!projectTransfer||protectedStorage,'Project transfer requires the actual protected session fixture');
assert(['ios','mac'].includes(platform));assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));assert(!(await fsStat(output).catch(()=>null)));
const device='F2ACCCB5-E5B3-426F-B962-955A113D4EF4',bundle=platform==='ios'?'com.dbakp.taskfold.workflowteststeameditbridge':'com.dbakp.taskfold.mac.workflowteststeameditbridge';
const product=platform==='ios'?'/tmp/taskfold-source-native-ios-products/Debug-iphonesimulator/Taskfold.app':'/tmp/taskfold-workflow-native-mac-build/Build/Products/Debug/Taskfold.app';
const host=platform==='ios'?'/tmp/taskfold-source-selection-ios-host':'/tmp/taskfold-owner-review-mac-host';
const report={platform,nativeProjectTransferRequested:projectTransfer,mixedRecordingsRequested:mixedRecordings,combinedCustodyRequested:combinedCustody,connectedCustodyRequested:connectedCustody,pagedFilesRequested:pagedFiles,expectedFileCount:fileCount,phaseMilliseconds:{},actualAppPublicationFlow:true,genuineLocalAuthRESTStorage:true,scopedAudioTLS:true,protectedKeychainOrReleaseTrustAccepted:false,nativeKeychainRequested:protectedStorage,releaseTrustAccepted:false,normalGatesChanged:false,hostedChanges:false,checks:{},phases:{}};
const command=async(...args)=>(await exec(args[0],args.slice(1),{timeout:90000,maxBuffer:1024*1024})).stdout.trim();
const sleep=ms=>new Promise(r=>setTimeout(r,ms));const hash=data=>createHash('sha256').update(data).digest('hex');const lit=s=>"'"+String(s).replaceAll("'","''")+"'";
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
// A locked Mac can hold a private-container IO request indefinitely. Fail the
// check rather than retaining the app, services and certificate keys behind it.
let privateIOBlocked=false;
const privatePath=path=>platform==='mac'&&String(path).startsWith(join(homedir(),'Library/Containers',bundle)+'/');
const fileIO=(operation,path,args)=>{
 if(!privatePath(path))return operation(path,...args);
 if(privateIOBlocked)return Promise.reject(Object.assign(Error('Private test-container access is still unavailable'),{code:'TASKFOLD_PRIVATE_IO_TIMEOUT'}));
 let timer;return Promise.race([operation(path,...args),new Promise((_,reject)=>{timer=setTimeout(()=>{privateIOBlocked=true;reject(Object.assign(Error('Private test-container IO exceeded five seconds; unlock/approve access before retrying'),{code:'TASKFOLD_PRIVATE_IO_TIMEOUT'}))},5000)})]).finally(()=>clearTimeout(timer));
};
const readFile=(path,...args)=>fileIO(fsReadFile,path,args),writeFile=(path,...args)=>fileIO(fsWriteFile,path,args),mkdir=(path,...args)=>fileIO(fsMkdir,path,args),rm=(path,...args)=>fileIO(fsRm,path,args),stat=(path,...args)=>fileIO(fsStat,path,args),readdir=(path,...args)=>fileIO(fsReaddir,path,args);

const servicePaths=['Scripts/Database/test-native-audio-publication.mjs','Scripts/Database/full-schema-runtime.mjs','Scripts/Database/full-schema-gateway.mjs','Scripts/Database/full-schema-audio-fixture.mjs','Scripts/Database/full-schema-audio-server.ts','supabase/functions/audio-comment-maintenance/handler.ts','supabase/functions/audio-comments/handler.ts','supabase/functions/audio-comments/wire.ts',...(combinedCustody?['supabase/functions/project-files/handler.ts','supabase/functions/task-files/handler.ts']:[])];
report.serviceSourceSHA256=Object.fromEntries(await Promise.all(servicePaths.map(async path=>[path,hash(await readFile(join(repo,path)))])));
let runtime,audio,initialDevice,root,home,config,mediaFolder,mediaFile,cache,pid,untrustedDir,activePhase,child;const streamed=new Map();let streamBuffer="";
async function deviceState(){const d=JSON.parse(await command('xcrun','simctl','list','devices','--json'));return Object.values(d.devices).flat().find(x=>x.udid===device).state}
async function stop(){
 if(platform==='ios'){try{await command('xcrun','simctl','terminate',device,bundle)}catch{};if(pid){for(let i=0;i<30;i++){try{process.kill(pid,0)}catch(error){if(error.code==='ESRCH'){pid=null;return}throw error}await sleep(100)}throw Error('Owned iPhone app did not close')}return}
 if(!pid&&activePhase){const rows=(await command('ps','-axo','pid=,command=')).split('\n').filter(line=>line.includes(product+'/Contents/MacOS/Taskfold')&&line.includes('--full-schema-phase='+activePhase));assert(rows.length<=1,'Ambiguous reserved Mac process');if(rows.length)pid=Number(rows[0].trim().split(/\s/)[0])}
 if(pid){try{const comm=await command('ps','-p',String(pid),'-o','comm=');assert(await realpath(comm)===await realpath(product+'/Contents/MacOS/Taskfold'));process.kill(pid,'SIGTERM');for(let i=0;i<30;i++){try{process.kill(pid,0)}catch{pid=null;return}await sleep(100)}throw Error('Owned Mac app did not close')}catch(error){if(error.code===1){pid=null;return}throw error}}
}
async function launch(name){
 await stop();activePhase=name;const flags=['--team-editor-testing','--full-schema-native-testing','--full-schema-phase='+name,...(protectedStorage?['--full-schema-keychain-testing']:[]),...(mixedRecordings?['--full-schema-mixed-recordings-testing']:[]),...(combinedCustody?['--full-schema-combined-custody-testing']:[]),...(connectedCustody?['--full-schema-connected-custody-testing']:[]),...(pagedFiles?['--full-schema-paged-files-testing']:[])];
 if(protectedStorage&&platform==='mac')flags.push('--full-schema-config='+join(root,'config.json'));
 if(platform==='ios'){const text=await command('xcrun','simctl','launch',device,bundle,...flags);pid=Number(text.match(/: (\d+)$/)?.[1]);assert(pid)}
 else if(protectedStorage){
  streamBuffer='';child=spawn(join(product,'Contents/MacOS/Taskfold'),flags,{stdio:['ignore','pipe','ignore']});pid=child.pid;assert(pid);
  child.stdout.on('data',chunk=>{streamBuffer+=chunk.toString();let index;while((index=streamBuffer.indexOf('\n'))>=0){const line=streamBuffer.slice(0,index);streamBuffer=streamBuffer.slice(index+1);if(line.startsWith('TASKFOLD_NATIVE_REPORT ')){try{const value=JSON.parse(Buffer.from(line.slice(23),'base64').toString());if(value.nonce===config.nonce)streamed.set(value.phase,value)}catch{}}}if(streamBuffer.length>262144)streamBuffer=''});
 }else{await command('open','-n',product,'--args',...flags);for(let i=0;i<50;i++){const rows=(await command('ps','-axo','pid=,comm=')).split('\n').filter(s=>s.trim().endsWith(product+'/Contents/MacOS/Taskfold'));if(rows.length===1){pid=Number(rows[0].trim().split(/\s/)[0]);break}await sleep(100)}assert(pid)}
}
async function files(path){let result=[];for(const entry of await readdir(path,{withFileTypes:true})){const p=join(path,entry.name);if(entry.isDirectory())result.push(...await files(p));else if(entry.isFile())result.push(p)}return result}
async function phase(name){
 const path=join(root,name+'.json');if(!(protectedStorage&&platform==='mac'))await rm(path,{force:true});streamed.delete(name);await launch(name);const started=Date.now(),deadline=started+(pagedFiles&&name.startsWith('audio-project-')?600000:90000);let nextProgress=started+30000;
 while(Date.now()<deadline){try{const data=protectedStorage&&platform==='mac'?streamed.get(name):JSON.parse(await readFile(path,'utf8'));if(data?.nonce===config.nonce&&data.phase===name){report.phases[name]=data;if(data.accepted!==true)throw Error('Native '+name+' refused: '+(data.message??'unknown result'));check('actual native phase '+name,true);report.phaseMilliseconds[name]=Date.now()-started;await stop();return data}}catch(error){if(error.code!=='ENOENT'&&!(error instanceof SyntaxError))throw error}if(pagedFiles&&Date.now()>=nextProgress){nextProgress=Date.now()+30000;console.log('native progress',name,await runtime.raw("select count(*) filter(where phase='ready')||'/'||count(*) from taskfold_private.project_file_preparation_items"))}await sleep(150)}throw Error('Actual native '+name+' exceeded deadline');
}
try{
 await command('python3',join(repo,'Scripts/check_test_storage.py'),'--path','/tmp');await command('codesign','--verify','--deep','--strict',product);
 if(projectTransfer&&platform==='mac'){
  const entitlements=await command('codesign','-d','--entitlements',':-',product);
  const identifier=entitlements.match(/<key>com\.apple\.application-identifier<\/key>\s*<string>([^<]+)<\/string>/)?.[1]??null;
  const profile=!!(await stat(join(product,'Contents/embedded.provisionprofile')).catch(()=>null));
  report.macProtectedVaultIdentity={applicationIdentifier:identifier,embeddedProfile:profile,runtimeAccepted:false};
  assert(identifier?.endsWith('.'+bundle)&&profile,'The isolated Mac app needs its own provisioned app identity for the Data Protection Keychain transfer vault. Configure dedicated test signing; do not reuse the normal app identity or weaken the vault.');
 }

 const paths=['Taskfold/Core/Store.swift','Taskfold/Core/Backend.swift','Taskfold/Core/Backups.swift','Taskfold/Core/Models.swift','Taskfold/Core/AudioComments.swift','Taskfold/Core/AudioCommentVault.swift','Taskfold/Core/AudioCommentPublishing.swift','Taskfold/Core/AudioCommentPending.swift','Taskfold/Core/AudioCommentDecoding.swift','Taskfold/TeamTemplateNativeFixture.swift',...(projectTransfer?['Taskfold/Core/TeamProjectAdoption.swift','Taskfold/Core/TeamOrganizationCommand.swift','Taskfold/Views/TeamProjectAdoptionView.swift',...(combinedCustody?['Taskfold/Core/ProjectFilePreparation.swift','Taskfold/Core/TaskFileUpload.swift']:[])]:[])];
 const binary=join(product,platform==='ios'?'':'Contents/MacOS','Taskfold.debug.dylib'),compiled=await stat(binary);report.sourceSHA256={};
 for(const path of paths){const source=await readFile(join(repo,path),'utf8');let scoped=source.replaceAll('backupcanceltests','workflowteststeameditbridge');
  const mapping=path==='Taskfold/Core/Backend.swift'?{'com.taskfold.ios.session':'com.taskfold.workflowteststeameditbridge.session','com.dbakp.taskfold.mac.backupcanceltests':'com.dbakp.taskfold.mac.workflowteststeameditbridge','com.dbakp.taskfold.backupcanceltests':'com.dbakp.taskfold.workflowteststeameditbridge','com.taskfold.recovery.v1':'com.taskfold.workflowteststeameditbridge.recovery'}:path==='Taskfold/Core/Backups.swift'?{'com.taskfold.recovery.v1':'com.taskfold.workflowteststeameditbridge.recovery'}:path==='Taskfold/Core/Store.swift'?{'group.com.dbakp.taskfold':'group.com.dbakp.taskfold.workflowteststeameditbridge'}:{};
  for(const [from,to] of Object.entries(mapping))scoped=scoped.replaceAll(from,to);
  assert.equal(await readFile(join(host,path),'utf8'),scoped,'Prepared native source differs: '+path);assert(compiled.mtimeMs>=(await stat(join(host,path))).mtimeMs,'Rebuild current '+path);report.sourceSHA256[path]=hash(source);
 }
 report.binarySHA256=hash(await readFile(binary));
 if(platform==='ios'){
  initialDevice=await deviceState();if(initialDevice==='Shutdown'){await command('xcrun','simctl','boot',device);await command('xcrun','simctl','bootstatus',device,'-b')}
  await command('xcrun','simctl','install',device,product);home=await command('xcrun','simctl','get_app_container',device,bundle,'data');assert(home.includes('/'+device+'/data/Containers/Data/Application/'));
 }else if(!protectedStorage){
  home=join(homedir(),'Library/Containers',bundle,'Data');assert(await stat(home),'Existing reserved Mac sandbox is required');
 }
 runtime=await createFullSchemaRuntime();if(projectTransfer)report.baselineAdvisors=await runtime.advisors();audio=await createFullSchemaAudioFixture(runtime,{projectFiles:combinedCustody,interruptible:pagedFiles});report.migrations=runtime.migrations;report.images=runtime.images;
 const nonce=randomUUID(),password=randomBytes(24).toString('base64url'),email='native-audio-'+nonce+'@example.invalid';
 const signup=await runtime.request('auth','/signup',{method:'POST',body:{email,password}});assert.equal(signup.status,200);const account=signup.value.user.id,authorization=signup.value.access_token,task=randomUUID(),project=randomUUID();
 const api=(path,body)=>runtime.request('rest',path,{method:'POST',authorization,body,headers:{Prefer:'return=representation'}});
 assert.equal((await api('/projects',{id:project,user_id:account,name:'Native audio workshop'})).status,201);
 const source=await api('/tasks',{id:task,user_id:account,project_id:project,title:'Native audio publication proof',description:'Keep unrelated task content',subtasks:projectTransfer?[{id:randomUUID(),title:'Keep the original child',completed:false,opaque_child:{preserved:true},subtasks:[{id:randomUUID(),title:'Keep the completed grandchild',completed:true,completed_at:'2026-10-01T09:00:00Z'}]}]:[]});assert.equal(source.status,201);
 await runtime.raw('update taskfold_private.audio_comment_config set enabled=true,audience_review_enabled=true');
 const transferUsers={},team=projectTransfer?randomUUID():null;
 if(projectTransfer){
  for(const name of ['old','new']){
   const signup=await runtime.request('auth','/signup',{method:'POST',body:{email:'native-recording-'+name+'-'+nonce+'@example.invalid',password:randomBytes(24).toString('base64url')}});assert.equal(signup.status,200);
   transferUsers[name]={id:signup.value.user.id,token:signup.value.access_token,email:signup.value.user.email};
  }
  const claims=JSON.parse(Buffer.from(authorization.split('.')[1],'base64url'));
  await runtime.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(account)},'Native recording transfer');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(account)},'admin'),(${lit(team)},${lit(transferUsers.new.id)},'member');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true;update taskfold_private.audio_comment_config set team_publication_enabled=true,project_transfer_enabled=true;set local request.jwt.claim.sub=${lit(account)};set local request.jwt.claims=${lit(JSON.stringify({sub:account,session_id:claims.session_id}))};insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(gen_random_uuid(),${lit(project)},${lit(transferUsers.old.email)},${lit(account)});update public.project_collaborators set status='accepted' where project_id=${lit(project)};`);
 }

 const originals=[];
 if(combinedCustody){
  const attachments=[],comments=[];
  for(let index=1;index<=fileCount;index++){
   const bytes=Buffer.from(pagedFiles?'%PDF-1.7\nNative paged custody '+index+'\n%%EOF\n':'%PDF-1.7\nNative combined custody\n%%EOF\n'),name=account+'/'+randomUUID()+'.pdf';
   const upload=await fetch(runtime.urls.storage+'/object/task-attachments/'+name,{method:'POST',headers:{apikey:runtime.anon,Authorization:'Bearer '+authorization,'Content-Type':'application/pdf','x-upsert':'false'},body:bytes});assert.equal(upload.status,200);await upload.arrayBuffer();
   const original=JSON.parse(await runtime.raw("select to_jsonb(o) from storage.objects o where bucket_id='task-attachments' and name="+lit(name)));
   const ref={id:randomUUID(),storage_object_id:original.id,name:'Keep original alias '+index+'.pdf',url:'https://old-provider.example.invalid/private',future:{keep:[null,false,'exact'],...(pagedFiles?{fixture_index:index}:{})}};
   attachments.push(ref);comments.push({id:randomUUID(),text:'Keep this file discussion '+index,attachment:{...ref,id:randomUUID(),name:'Discussion alias '+index+'.pdf'}});originals.push({bytes,name,id:original.id});
  }
  const edit=await runtime.request('rest','/tasks?id=eq.'+task,{method:'PATCH',authorization,headers:{Prefer:'return=representation'},body:{attachments,comments}});assert.equal(edit.status,200);
  await runtime.raw('update taskfold_private.project_file_preparation_config set enabled=true,transfer_enabled=true;update taskfold_private.task_file_upload_config set enabled=true');
 }
 const connectionIDs={email:randomUUID(),hook:randomUUID(),pending:randomUUID(),global:randomUUID(),otherEmail:randomUUID(),otherHook:randomUUID()},otherProject=randomUUID(),otherTask=randomUUID();
 let outsideConnections,outsideQueue,selectedQueued,selectedSettings,outsideCanonical;
 const outsideState=()=>runtime.raw(`select jsonb_build_object('email',(select to_jsonb(e) from taskfold_private.email_routes e where id=${lit(connectionIDs.otherEmail)}),'hooks',(select jsonb_agg(to_jsonb(h) order by id) from taskfold_private.webhook_subscriptions h where id in(${lit(connectionIDs.otherHook)},${lit(connectionIDs.global)})))`);
 const selectedIdentity=()=>runtime.raw(`select jsonb_build_object('email',(select to_jsonb(e)-array['state','revision','updated_at'] from taskfold_private.email_routes e where id=${lit(connectionIDs.email)}),'hook',(select to_jsonb(h)-array['state','revision'] from taskfold_private.webhook_subscriptions h where id=${lit(connectionIDs.hook)}))`);
 const otherCanonical=()=>runtime.raw(`select jsonb_build_object('project',(select to_jsonb(p) from public.projects p where id=${lit(otherProject)}),'task',(select to_jsonb(t) from public.tasks t where id=${lit(otherTask)}))`);
 const outsideEvents=()=>runtime.raw(`select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]'::jsonb) from taskfold_private.webhook_outbox e where task_id=${lit(otherTask)}`);
 if(connectedCustody){
  assert.equal((await api('/projects',{id:otherProject,user_id:account,name:'Keep unrelated connections'})).status,201);
  assert.equal((await api('/tasks',{id:otherTask,user_id:account,project_id:otherProject,title:'Keep unrelated queued work'})).status,201);
  await runtime.raw(`insert into taskfold_private.email_routes(id,user_id,name,alias_hash,alias_domain,project_id,sender_email,requested_at,state) values(${lit(connectionIDs.email)},${lit(account)},'Synthetic selected email',repeat('c',64),'capture.example.invalid',${lit(project)},'sender@example.invalid',now(),'active'),(${lit(connectionIDs.otherEmail)},${lit(account)},'Synthetic unselected email',repeat('e',64),'capture.example.invalid',${lit(otherProject)},'sender@example.invalid',now(),'active');
  insert into taskfold_private.webhook_subscriptions(id,user_id,name,endpoint,scope,project_id,events,ttl_days,secret_hash,secret_envelope,state,expires_at,verified_at) values(${lit(connectionIDs.hook)},${lit(account)},'Synthetic selected hook','https://receiver.example.invalid/events','project',${lit(project)},array['task.updated'],30,repeat('d',64),'{}','active',now()+interval '1 day',now()),(${lit(connectionIDs.pending)},${lit(account)},'Synthetic unfinished hook','https://receiver.example.invalid/events','project',${lit(project)},array['task.updated'],30,repeat('a',64),'{}','pending',now()+interval '1 day',null),(${lit(connectionIDs.global)},${lit(account)},'Synthetic global hook','https://receiver.example.invalid/events','all',null,array['task.updated'],30,repeat('f',64),'{}','active',now()+interval '1 day',now()),(${lit(connectionIDs.otherHook)},${lit(account)},'Synthetic unrelated hook','https://receiver.example.invalid/events','project',${lit(otherProject)},array['task.updated'],30,repeat('b',64),'{}','active',now()+interval '1 day',now());`);
  for(const id of [task,otherTask]){const result=await runtime.request('rest','/tasks?id=eq.'+id,{method:'PATCH',authorization,body:{description:'Keep original queued connection work'},headers:{Prefer:'return=representation'}});assert.equal(result.status,200)}
  selectedSettings=await selectedIdentity();outsideCanonical=await otherCanonical();outsideConnections=await outsideState();outsideQueue=await outsideEvents();assert(JSON.parse(outsideQueue).length>0);
 }
 root=platform==='mac'&&protectedStorage?'/private/tmp/taskfold-native-audio-control-'+nonce:join(home,'Library/Application Support/TaskfoldFullSchemaNative-workflowteststeameditbridge');await mkdir(root,{recursive:true,mode:0o700});
 mediaFolder=platform==='mac'&&protectedStorage?undefined:join(root,'audio-'+nonce);mediaFile=join(root,'audio-media-'+nonce+'.m4a');
 const media=await readFile(new URL('../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a',import.meta.url));await writeFile(mediaFile,media,{mode:0o600});
 const der=pem=>Buffer.from(pem.replace(/-----[^\n]+-----/g,'').replace(/\s/g,''),'base64').toString('base64');
 config={version:1,nonce,account,task,sibling:team??randomUUID(),origin:new URL(runtime.urls.auth).origin,key:runtime.anon,email,password,audioOrigin:audio.endpoint,audioCA:der(audio.certificateAuthority),expectedFileCount:fileCount,...(protectedStorage?{protectedStorage:true}:{})};
 cache=platform==='mac'&&protectedStorage?undefined:join(home,'Library/Application Support/Taskfold',account+'.json');
 const save=()=>writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});await save();if(!protectedStorage)await rm(join(root,'session.json'),{force:true});
 if(protectedStorage)report.retainedTestKeychainItems=[{service:'com.taskfold.full-schema.session.'+nonce,account:'supabase'},{service:'com.taskfold.full-schema.backup.'+nonce,account}];
 const created=await phase('audio-create');check('app used the genuine account and original clip',created.account===account&&created.clipSHA256===hash(media));
 const draftPaths=platform==='mac'&&protectedStorage?[]:(await files(mediaFolder)).filter(p=>/\/draft-[a-f0-9-]+\.bin$/.test(p));if(!(platform==='mac'&&protectedStorage))assert.equal(draftPaths.length,1);const originalDraft=protectedStorage?created.rawDraftSHA256:hash(await readFile(draftPaths[0]));assert(/^[a-f0-9]{64}$/.test(originalDraft));report.originalDraftDiskSHA256=originalDraft;
 if(protectedStorage&&platform==='ios')check('app and independent raw recording bytes agree',hash(await readFile(draftPaths[0]))===originalDraft);
 const originalTask=(await runtime.request('rest','/tasks?id=eq.'+task+'&select=*',{authorization})).value[0];
 // A different, well-formed CA must fail; no system trust changes or trust-all delegate.
 untrustedDir=join(root,'wrong-ca-'+nonce);await mkdir(untrustedDir,{mode:0o700});await exec('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',join(untrustedDir,'key'),'-out',join(untrustedDir,'cert'),'-days','1','-subj','/CN=Unrelated disposable CA','-addext','basicConstraints=critical,CA:TRUE']);
 const trusted=config.audioCA;config.audioCA=der(await readFile(join(untrustedDir,'cert'),'utf8'));await save();
 const denied=await phase('audio-deny');check('native URLSession rejects the unrelated CA and preserves the source',denied.rejectedUntrustedTLS&&audio.state.authRequests===0&&(protectedStorage?denied.rawDraftSHA256:hash(await readFile(draftPaths[0])))===originalDraft);
 config.audioCA=trusted;await save();
 const loss=await phase('audio-loss');check('one real upload committed before native reply loss',loss.pending&&loss.approvalSaved&&loss.droppedReplies===1&&audio.state.uploads===1);
 check('original native intent was not regenerated after failed TLS review',loss.intentFingerprint===denied.intentFingerprint&&loss.operation===denied.operation);
 const publication=JSON.parse(await runtime.raw(`select to_jsonb(p) from taskfold_private.audio_comment_publications p where operation_id=${lit(loss.operation)}`));check('actual database contains the committed native publication',publication.state==='published');
 const recovered=await phase('audio-check');check('cold original confirmation and download use the published receipt',!recovered.pending&&recovered.receipt?.operation_id===loss.operation&&recovered.downloadedExactBytes&&recovered.intentFingerprint===loss.intentFingerprint);
 check('confirmation and reading do not upload a second recording',audio.state.uploads===1);
 const beforeOffline={auth:audio.state.authRequests,rpc:audio.state.rpcRequests,downloads:audio.state.downloads};
 const verified=await phase('audio-verify');check('published journal survives offline cold reopening',verified.offline&&!verified.pending&&isDeepStrictEqual(verified.receipt,recovered.receipt)&&verified.intentFingerprint===loss.intentFingerprint);
 check('offline cold verification performs no requests',isDeepStrictEqual(beforeOffline,{auth:audio.state.authRequests,rpc:audio.state.rpcRequests,downloads:audio.state.downloads}));
 report.finalDraftDiskSHA256=protectedStorage?verified.rawDraftSHA256:hash(await readFile(draftPaths[0]));check('original private recording file remains byte exact',report.finalDraftDiskSHA256===originalDraft);check('one original object and one publication exist',await runtime.raw("select (select count(*) from storage.objects where bucket_id='taskfold-audio-v1')=1 and (select count(*) from taskfold_private.audio_comment_publications)=1")==='t');
 const finalTask=(await runtime.request('rest','/tasks?id=eq.'+task+'&select=*',{authorization})).value[0];check('publication preserves unrelated canonical task data',isDeepStrictEqual(finalTask,originalTask));
 if(protectedStorage){
  for(const name of ['audio-create','audio-deny','audio-loss','audio-check','audio-verify']){
   const value=report.phases[name];check('actual protected session and encrypted recovery '+name,value.protectedSessionReadback&&value.encryptedRecoveryReadback&&value.privateDraftMode===384&&value.rawDraftSHA256===originalDraft&&value.backupKeyFingerprint===created.backupKeyFingerprint&&value.backupCiphertextSHA256===created.backupCiphertextSHA256&&(platform!=='ios'||typeof value.simulatorFileProtectionAttribute==='string'));
  }
  report.nativeKeychainAccepted=true;report.hardwareFileProtectionAccepted=false;
 }

 if(projectTransfer){
  const read=async(user,comment,status)=>{
   const response=await audio.call(user.token,'download',{comment_id:comment});const bytes=Buffer.from(await response.arrayBuffer());assert.equal(response.status,status);return bytes;
  };
  const call=async(user,action,body)=>{
   const response=await audio.call(user.token,action,body);const value=await response.json();assert.equal(response.status,200,action+' '+JSON.stringify(value));return value;
  };
  const descriptor={version:1,mime_type:'audio/mp4',byte_count:media.length,duration_ms:1000,sha256:hash(media)};
  const intent=user=>({version:1,account:user.id,operation_id:randomUUID(),comment_id:randomUUID(),asset_id:randomUUID(),target:{task_id:task,task_generation:originalTask.task_generation,project_id:project},caption:'Synthetic private history',audio:descriptor});
  const owner={id:account,token:authorization};let removed,pending,pendingApproval,crossingSend,queued,transferLoss;
  if(mixedRecordings){
   removed=intent(owner);pending=intent(transferUsers.old);
   const quote=await call(owner,'review',{intent:removed});await call(owner,'publish',{intent:removed,approval:quote.approval,audio_base64:media.toString('base64')});await call(owner,'remove',{comment_id:removed.comment_id});
   pendingApproval=(await call(transferUsers.old,'review',{intent:pending})).approval;
   await runtime.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=true,project_private_history_enabled=true');
  }
  const stableLedger=()=>runtime.raw("select coalesce(jsonb_agg(to_jsonb(p) order by operation_id),'[]'::jsonb) from taskfold_private.audio_comment_publications p"+(mixedRecordings?" where operation_id<>"+lit(pending.operation_id):''));
  const originalLedger=await stableLedger();let originalObjects;
  check('original personal collaborator receives exact recording before transfer',(await read(transferUsers.old,loss.comment,200)).equals(media));
  const beforeDenied=audio.state.downloads;await read(transferUsers.new,loss.comment,404);check('future team member cannot fetch personal recording bytes',audio.state.downloads===beforeDenied);
  const transfer=async()=>{
   originalObjects=await runtime.raw("select coalesce(jsonb_agg(to_jsonb(o) order by id),'[]'::jsonb) from storage.objects o where bucket_id='taskfold-audio-v1'");
   if(connectedCustody){selectedQueued=JSON.parse(await runtime.raw(`select coalesce(jsonb_agg(id order by id),'[]'::jsonb) from taskfold_private.webhook_outbox where task_id=${lit(task)} and payload is not null and status in('pending','leased','failed')`));assert(selectedQueued.length>0)}
   queued=await phase('audio-project-queue');check('actual Store preserves one original reviewed recording transfer',queued.pending&&queued.command.recording_policy===(mixedRecordings?'move_recordings_keep_removed_private_v1':'published_recordings_v1')&&queued.rawDraftSHA256===originalDraft&&queued.diskMatchesStore);
   if(mixedRecordings)check('actual native review binds published unfinished and retained counts',queued.command.recording_count===1&&queued.command.unfinished_recording_count===1&&queued.command.retained_recording_count===1);
   if(combinedCustody)check('actual native private-copy consent and saved preparation agree',queued.filePreparationPending&&/^[a-f0-9]{64}$/.test(queued.filePreparationFingerprint)&&queued.command.file_policy?.action==='share_copies_keep_originals');
   if(pagedFiles)check('native consent includes both complete manifest pages',queued.filePageCount===2&&queued.fileItemCount===fileCount&&/^[a-f0-9]{64}$/.test(queued.fileManifestFingerprint));
   if(connectedCustody)check('native review binds only selected connection effects',queued.command.connection_policy==='pause'&&isDeepStrictEqual(queued.connectionEffects,{email_routes_paused:1,project_webhooks_paused:1,pending_webhooks_cancelled:1,global_webhooks_excluded:1,queued_updates_discarded:selectedQueued.length}));
   config.queuedFingerprint=queued.commandFingerprint;await save();
   check('offline original send has not transferred the project',await runtime.raw(`select count(*) from taskfold_private.team_content_projects where project_id=${lit(project)}`)==='0');
   let transferError;
   audio.state.afterStorageGet=async()=>{audio.state.afterStorageGet=null;try{transferLoss=await phase('audio-project-loss')}catch(error){transferError=error;throw error}};
   let crossing;try{crossing=await read(transferUsers.old,loss.comment,404)}catch(error){throw transferError??error};check('native project commit withholds an old-audience download already in flight',JSON.parse(crossing.toString()).code==='unavailable'&&transferLoss?.pending&&transferLoss.droppedReplies===1&&transferLoss.commandFingerprint===queued.commandFingerprint&&isDeepStrictEqual(transferLoss.command,queued.command));
  };
  if(pagedFiles){
   let finishHook,interrupted=false,hookError;const hookDone=new Promise(resolve=>{finishHook=resolve});
   audio.state.afterStoragePut=async()=>{audio.state.afterStoragePut=null;try{await audio.interruptHandler();interrupted=true}catch(error){hookError=error}finally{finishHook()}};
   let transportLost=false;try{await call(transferUsers.old,'publish',{intent:pending,approval:pendingApproval,audio_base64:media.toString('base64')})}catch{transportLost=true}
   let timer;await Promise.race([hookDone,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Owned upload-interruption hook did not finish')),5000)})]).finally(()=>clearTimeout(timer));if(hookError)throw hookError;
   check('real interrupted handler leaves original unfinished publication',transportLost&&interrupted&&await runtime.raw('select state from taskfold_private.audio_comment_publications where operation_id='+lit(pending.operation_id))==='pending');
   await audio.restartHandler();config.audioOrigin=audio.endpoint;await save();report.ownedHandlerRestarted=true;
   await transfer();
   crossingSend=await call(transferUsers.old,'publish',{intent:pending,approval:pendingApproval,audio_base64:media.toString('base64')});
   check('interrupted original upload confirms closed without another upload',isDeepStrictEqual(crossingSend.closed,{protocol:1,intent:pending,state:'closed'})&&audio.state.uploads===fileCount+3);
   check('interrupted and removed histories remain privately fenced',isDeepStrictEqual(JSON.parse(await runtime.raw('select jsonb_agg(operation_id order by operation_id) from taskfold_private.audio_project_private_history')),[removed.operation_id,pending.operation_id].sort()));
  }else if(mixedRecordings){
   let callbackError;audio.state.afterStoragePut=async()=>{audio.state.afterStoragePut=null;try{await transfer()}catch(error){callbackError=error;throw error}};
   try{crossingSend=await call(transferUsers.old,'publish',{intent:pending,approval:pendingApproval,audio_base64:media.toString('base64')})}catch(error){throw callbackError??error}
   if(callbackError)throw callbackError;
   check('native mixed transfer stops the real in-flight upload',isDeepStrictEqual(crossingSend.closed,{protocol:1,intent:pending,state:'closed'}));
   check('only stopped and removed originals receive private fences',isDeepStrictEqual(JSON.parse(await runtime.raw("select jsonb_agg(operation_id order by operation_id) from taskfold_private.audio_project_private_history")),[removed.operation_id,pending.operation_id].sort()));
  }else await transfer();
  if(pagedFiles)check('cold preparation recovers every original page and item',transferLoss.filePageCount===2&&transferLoss.fileItemCount===fileCount&&transferLoss.fileManifestFingerprint===queued.fileManifestFingerprint);
  if(connectedCustody)check('cold lost reply retains exact reviewed connection effects',isDeepStrictEqual(transferLoss.connectionEffects,queued.connectionEffects));
  if(combinedCustody)check('cold file preparation retains exact original identity',transferLoss.filePreparationPending&&transferLoss.filePreparationFingerprint===queued.filePreparationFingerprint);
  check('actual native original transfer committed exactly one custody record',await runtime.raw(`select (select count(*) from taskfold_private.team_content_projects where project_id=${lit(project)} and team_id=${lit(team)})=1 and (select count(*) from taskfold_private.audio_comment_custody)=1`)==='t');
  await runtime.raw('update taskfold_private.audio_comment_config set project_transfer_enabled=false,project_unfinished_transfer_enabled=false,project_private_history_enabled=false;update taskfold_private.team_project_config set native_project_adoption_enabled=false');
  if(combinedCustody)await runtime.raw('update taskfold_private.project_file_preparation_config set enabled=false,transfer_enabled=false');
  const replay=await phase('audio-project-replay');check('cold original retry confirms while new transfers are paused',!replay.pending&&replay.receipt.replayed&&replay.receipt.request_id===queued.command.request_id&&isDeepStrictEqual(replay.receipt.command,queued.command)&&replay.commandFingerprint===queued.commandFingerprint);
  if(connectedCustody)check('cold confirmation binds the original connection effects',isDeepStrictEqual(replay.connectionEffects,queued.connectionEffects)&&replay.receipt.command.connection_policy==='pause');
  if(pagedFiles)check('cold committed preparation recovers the complete original manifest',replay.filePageCount===2&&replay.fileItemCount===fileCount&&replay.fileManifestFingerprint===queued.fileManifestFingerprint);
  check('real Store refresh exposes current team and exact original recording',replay.workspaceRefreshed&&replay.downloadedExactBytes&&replay.diskMatchesStore&&replay.rawDraftSHA256===originalDraft);
  if(combinedCustody)check('actual Backend verifies copied file and clears only confirmed preparation',replay.downloadedExactFileBytes&&replay.clearedFilePreparation&&!replay.filePreparationPending);
  check('new current team audience receives exact original bytes',(await read(transferUsers.new,loss.comment,200)).equals(media));
  const retiredDownloads=audio.state.downloads;await read(transferUsers.old,loss.comment,404);check('retired collaborator cannot reach Storage after transfer',audio.state.downloads===retiredDownloads);
  const beforeCold={auth:audio.state.authRequests,rpc:audio.state.rpcRequests,downloads:audio.state.downloads};
  const cold=await phase('audio-project-verify');check('transferred Store and cleared original journal survive offline cold reopening',cold.offline&&!cold.pending&&cold.diskMatchesStore&&cold.rawDraftSHA256===originalDraft&&cold.commandFingerprint===queued.commandFingerprint);
  check('offline transferred workspace performs no audio service requests',isDeepStrictEqual(beforeCold,{auth:audio.state.authRequests,rpc:audio.state.rpcRequests,downloads:audio.state.downloads}));
  check('project transfer and cold retries preserve original publication ledger',await stableLedger()===originalLedger);
  check('project transfer and retries preserve original Storage objects',await runtime.raw("select coalesce(jsonb_agg(to_jsonb(o) order by id),'[]'::jsonb) from storage.objects o where bucket_id='taskfold-audio-v1'")===originalObjects&&audio.state.uploads===(combinedCustody?fileCount+3:mixedRecordings?3:1));
  if(mixedRecordings){
   for(const value of [removed,pending]){const before=audio.state.downloads;await read(transferUsers.new,value.comment_id,404);check('private history is refused before Storage '+value.operation_id,audio.state.downloads===before)}
   const uploads=audio.state.uploads;const retry=await call(transferUsers.old,'publish',{intent:pending,approval:pendingApproval,audio_base64:media.toString('base64')});check('stopped original stays closed after cold native confirmation',isDeepStrictEqual(retry.closed,crossingSend.closed)&&audio.state.uploads===uploads);
   report.nativeMixedRecordingTransferAccepted=true;
  }
  const transferredTask=(await runtime.request('rest','/tasks?id=eq.'+task+'&select=*',{authorization})).value[0];
  if(combinedCustody){
   const strip=value=>{const copy={...value};delete copy.attachments;delete copy.comments;return copy};
   check('combined native transfer preserves all other canonical and older nested fields',isDeepStrictEqual(strip(transferredTask),strip(originalTask)));
   const attachments=transferredTask.attachments,comments=transferredTask.comments;
   check('all task and discussion file references survive transfer',attachments.length===fileCount&&comments.length===fileCount);
   check('combined native transfer preserves aliases opaque fields and discussion',attachments.every((a,i)=>a.name===originalTask.attachments[i].name&&isDeepStrictEqual(a.future,originalTask.attachments[i].future))&&comments.every((c,i)=>c.text===originalTask.comments[i].text&&c.attachment.name===originalTask.comments[i].attachment.name));
   const copies=attachments.map(a=>a.storage_object_id);
   check('one copied file identity serves each pair of references',new Set(copies).size===fileCount&&comments.every((c,i)=>c.attachment.storage_object_id===copies[i])&&copies.every(id=>!originals.some(o=>o.id===id))&&await runtime.raw('select count(*) from taskfold_private.project_file_preparations')==='1'&&await runtime.raw('select count(*) from taskfold_private.task_file_uploads')===String(fileCount)&&await runtime.raw('select count(*) from taskfold_private.team_content_files')===String(fileCount));
   const readFile=async(token,body)=>{
    for(let attempt=0;attempt<3;attempt++){
     const response=await audio.taskFiles(token,'download',body);if(response.status!==429)return response;
     const delay=Number(response.headers.get('Retry-After'));assert(Number.isInteger(delay)&&delay>=1&&delay<=60);await response.arrayBuffer();assert(attempt<2,'Verifier rate retry exhausted');console.log('verifier respects real rate delay',delay);await sleep(delay*1000);
    }
   };
   let copiedExact=true,privateExact=true,oldDenied=true,originalPrivate=true;
   for(let i=0;i<fileCount;i++){
    const body={object_id:copies[i],task_id:task,task_generation:transferredTask.task_generation};
    const teamFile=await readFile(transferUsers.new.token,body);copiedExact&&=teamFile.status===200&&Buffer.from(await teamFile.arrayBuffer()).equals(originals[i].bytes);
    const before=audio.state.downloads,oldFile=await readFile(transferUsers.old.token,body);await oldFile.arrayBuffer();oldDenied&&=oldFile.status===404&&audio.state.downloads===before;
    const original=await fetch(runtime.urls.storage+'/object/authenticated/task-attachments/'+originals[i].name,{headers:{apikey:runtime.anon,Authorization:'Bearer '+authorization}});privateExact&&=original.status===200&&Buffer.from(await original.arrayBuffer()).equals(originals[i].bytes);
    if(pagedFiles){const refused=await fetch(runtime.urls.storage+'/object/authenticated/task-attachments/'+originals[i].name,{headers:{apikey:runtime.anon,Authorization:'Bearer '+transferUsers.new.token}});const bytes=Buffer.from(await refused.arrayBuffer());originalPrivate&&=refused.status!==200&&!bytes.equals(originals[i].bytes)}
   }
   check('new team receives every exact copied file',copiedExact);
   check('retired audience cannot reach any copied file Storage',oldDenied);
   check('every original file remains exact and privately readable',privateExact);
   if(pagedFiles){check('new team cannot read any original private file',originalPrivate);check('real rate limits are respected during large preparation and reads',audio.state.rateLimitedRPCs>0);report.nativePagedProjectFilesAccepted=true}
   check('offline cold confirmation keeps preparation cleared',!cold.filePreparationPending);
   report.nativeCombinedFileRecordingTransferAccepted=true;
  }else check('project transfer keeps exact task fields and older nested content',isDeepStrictEqual(transferredTask,originalTask));
  if(connectedCustody){
   const result=JSON.parse(await runtime.raw(`select jsonb_build_object('email',(select state from taskfold_private.email_routes where id=${lit(connectionIDs.email)}),'hook',(select state from taskfold_private.webhook_subscriptions where id=${lit(connectionIDs.hook)}),'pending',(select state from taskfold_private.webhook_subscriptions where id=${lit(connectionIDs.pending)}),'pending_secret',(select secret_envelope from taskfold_private.webhook_subscriptions where id=${lit(connectionIDs.pending)}))`));
   check('native transfer pauses selected routes and retires unfinished verification',isDeepStrictEqual(result,{email:'paused',hook:'paused',pending:'revoked',pending_secret:null}));
   const events=JSON.parse(await runtime.raw(`select jsonb_agg(jsonb_build_object('id',id,'status',status,'payload',payload,'lease',lease_id) order by id) from taskfold_private.webhook_outbox where task_id=${lit(task)}`));
   check('only reviewed selected queued payloads are cancelled and cleared',isDeepStrictEqual(events,selectedQueued.map(id=>({id,status:'cancelled',payload:null,lease:null}))));
   check('pausing preserves original route and webhook ownership and settings',await selectedIdentity()===selectedSettings);
   check('unselected project and canonical task remain byte exact',await otherCanonical()===outsideCanonical);
   check('unselected and global connection settings remain byte exact',await outsideState()===outsideConnections);
   check('unselected queued payloads remain byte exact',await outsideEvents()===outsideQueue);
   check('native connected transfer creates no outbound delivery jobs',await runtime.raw('select count(*) from net.http_request_queue')==='0'&&await runtime.raw('show cron.launch_active_jobs')==='off');
   report.nativeConnectedProjectTransferAccepted=true;
  }
  report.advisors=await runtime.advisors();const prior=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no new advisor findings',report.advisors.result.every(x=>prior.has(x.cache_key)));
  report.nativeProjectTransferAccepted=true;
 }
 for(const path of paths)assert.equal(hash(await readFile(join(repo,path))),report.sourceSHA256[path],path+' changed during native acceptance');
 for(const path of servicePaths)assert.equal(hash(await readFile(join(repo,path))),report.serviceSourceSHA256[path],path+' changed during native acceptance');report.sourceUnchanged=true;report.handlerCounters={auth:audio.state.authRequests,rpc:audio.state.rpcRequests,uploads:audio.state.uploads,downloads:audio.state.downloads,rateLimitedRPCs:audio.state.rateLimitedRPCs};report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code};process.exitCode=1}
finally{
 try{if(protectedStorage&&report.phases['audio-create']){const result=await phase('audio-cleanup');report.syntheticAppFilesRemoved=result.syntheticFilesRemoved;report.testKeychainRetained=result.testKeychainRetained}await stop();report.appClosed=true}catch(error){report.cleanupError=error.message;report.accepted=false;process.exitCode=1;try{await stop();report.appClosed=true}catch{}}
 // Stop services before touching potentially protected host-side app files.
 if(audio){try{await audio.close();report.handlerClosed=true}catch(error){report.handlerCleanupError=error.message;process.exitCode=1}}
 if(runtime){try{report.servicesRemoved=await runtime.close()}catch(error){report.serviceCleanupError=error.message;process.exitCode=1}}
 report.pendingPrivateFiles=[];
 const cleanup=[...(root?['config.json','session.json'].map(path=>join(root,path)):[]),mediaFolder,mediaFile,untrustedDir,cache].filter(Boolean);
 for(const path of cleanup){try{await rm(path,{recursive:true,force:true})}catch(error){report.pendingPrivateFiles.push(path);report.privateCleanupError=error.code??error.message;process.exitCode=1}}
 if(platform==='mac'&&protectedStorage&&root){await rm(root,{recursive:true,force:true});report.controlFolderRemoved=true}
 if(platform==='ios'&&initialDevice){if(initialDevice==='Shutdown'&&await deviceState()==='Booted')await command('xcrun','simctl','shutdown',device);report.simulatorRestored=await deviceState()===initialDevice}
 report.privateIOBlocked=privateIOBlocked;report.checkCount=Object.keys(report.checks).length;
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,error:report.error,checks:report.checkCount,appClosed:report.appClosed,servicesRemoved:report.servicesRemoved,privateIOBlocked}));
 // Outstanding kernel IO requests must not keep a failed private-container
 // check alive after its app/services are closed and its result is retained.
 if(privateIOBlocked)process.exit(1);
}
