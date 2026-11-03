// Actual app process + production Backend/Store with real local Auth/REST.
// A reserved DEBUG URLProtocol changes transport only and can drop one real reply.
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify,isDeepStrictEqual} from 'node:util';
import {randomUUID,randomBytes,createHash} from 'node:crypto';
import {readFile,writeFile,mkdir,rm,stat,realpath} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const exec=promisify(execFile),[platform,output,mode='root']=process.argv.slice(2);
assert(['root','child','structure','field-conflict','structure-conflict'].includes(mode));
assert(['ios','mac'].includes(platform));assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
try{await stat(output);throw Error('Preserve previous result')}catch(e){if(e.code!=='ENOENT')throw e}
const repo=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const device='F2ACCCB5-E5B3-426F-B962-955A113D4EF4';
const bundle=platform==='ios'?'com.dbakp.taskfold.workflowteststeameditbridge':'com.dbakp.taskfold.mac.workflowteststeameditbridge';
const product=platform==='ios'?'/tmp/taskfold-prepared-undo-signed-ios-build/Build/Products/Debug-iphonesimulator/Taskfold.app':'/tmp/taskfold-workflow-native-mac-build/Build/Products/Debug/Taskfold.app';
const report={platform,mode,actualAppBackendStore:false,genuineLocalAuthREST:false,transportIsTestOnly:true,genuineTLSOrKeychainAcceptance:false,hostedChanges:false,checks:{},phases:{}};
let runtime,initialDevice,root,home,config,pid,cache;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const command=async(...args)=>(await exec(args[0],args.slice(1),{timeout:60000,maxBuffer:1024*1024})).stdout.trim();
const lit=v=>"'"+String(v).replaceAll("'","''")+"'";
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
async function deviceState(){const devices=JSON.parse(await command('xcrun','simctl','list','devices','--json'));return Object.values(devices.devices).flat().find(d=>d.udid===device).state}
async function stop(){
 if(platform==='ios'){try{await command('xcrun','simctl','terminate',device,bundle)}catch{};if(pid){for(let i=0;i<30;i++){try{process.kill(pid,0)}catch(e){if(e.code==='ESRCH'){pid=null;return}throw e}await sleep(100)}throw Error('Owned iPhone app did not quit')}return}
 if(pid){try{const comm=await command('ps','-p',String(pid),'-o','comm=');assert(await realpath(comm)===await realpath(product+'/Contents/MacOS/Taskfold')); process.kill(pid,'SIGTERM');for(let i=0;i<30;i++){try{process.kill(pid,0)}catch{pid=null;return}await sleep(100)}throw Error('Owned Mac app did not quit')}catch(e){if(e.code===1){pid=null;return}throw e}}
}
async function launch(phase){
 await stop();
 const flags=['--team-editor-testing','--full-schema-native-testing','--full-schema-phase='+phase];
 if(platform==='ios'){const text=await command('xcrun','simctl','launch',device,bundle,...flags);pid=Number(text.match(/: (\d+)$/)?.[1]);assert(pid)}
 else{await command('open','-n',product,'--args',...flags);for(let i=0;i<50;i++){const rows=(await command('ps','-axo','pid=,comm=')).split('\n').filter(s=>s.trim().endsWith(product+'/Contents/MacOS/Taskfold'));if(rows.length===1){pid=Number(rows[0].trim().split(/\s/)[0]);break}await sleep(100)}assert(pid,'Owned Mac app PID missing')}
}
async function phase(name){
 await launch(name);const file=join(root,name+'.json'),deadline=Date.now()+90000;
 while(Date.now()<deadline){try{const data=JSON.parse(await readFile(file,'utf8'));if(data.nonce===config.nonce&&data.phase===name){report.phases[name]=data;check('actual Store phase '+name,data.accepted===true);await stop();return data}}catch(e){if(e.code!=='ENOENT'&&!(e instanceof SyntaxError))throw e}await sleep(150)}
 throw Error('Actual app phase '+name+' exceeded its deadline');
}
const json=async path=>JSON.parse(await readFile(path,'utf8'));
// Compare baseline field-name Sets semantically; keep authored arrays exact.
const reviewEntry=row=>Array.isArray(row.before?.fields)?{...row,before:{...row.before,fields:[...row.before.fields].sort()}}:row;
const sameReviewHistory=(a,b)=>isDeepStrictEqual(a.map(reviewEntry),b.map(reviewEntry));
try{
 await command('python3',join(repo,'Scripts/check_test_storage.py'),'--path','/tmp');
 await command('codesign','--verify','--deep','--strict',product);
 const host=platform==='ios'?'/tmp/taskfold-owner-review-ios-host':'/tmp/taskfold-owner-review-mac-host';
 const mapping={'com.dbakp.taskfold.task':'com.dbakp.taskfold.workflowteststeameditbridge.task','com.taskfold.ios.session':'com.taskfold.workflowteststeameditbridge.session','com.taskfold.recovery.v1':'com.taskfold.workflowteststeameditbridge.recovery','group.com.dbakp.taskfold':'group.com.dbakp.taskfold.workflowteststeameditbridge'};
 const paths=['Taskfold/Core/Store.swift','Taskfold/Core/Backend.swift','Taskfold/Core/Models.swift','Taskfold/Core/TeamWorkspace.swift','Taskfold/TeamTemplateNativeFixture.swift','Taskfold/Core/ChildTaskFieldCommands.swift','Taskfold/Core/ChildTaskCompletionCommands.swift','Taskfold/Core/ChildTaskStructureCommands.swift','Taskfold/Core/ChildTaskStructureRecovery.swift','Taskfold/Core/ChildTaskStructurePresentation.swift','Taskfold/Core/ChildTaskStructureDraft.swift','Taskfold/Core/SubtaskTree.swift','Taskfold/Views/ChildTaskFieldViews.swift',platform==='ios'?'Taskfold/Views/TaskEditor.swift':'Taskfold/Views/TaskInspector.swift'];
 const executable=join(product,platform==='ios'?'':'Contents/MacOS','Taskfold.debug.dylib');const compiled=await stat(executable);report.sourceSHA256={};
 for(const path of paths){const source=await readFile(join(repo,path),'utf8');let expected=source;for(const [from,to] of Object.entries(mapping))expected=expected.replaceAll(from,to);assert.equal(await readFile(join(host,path),'utf8'),expected,'Prepared host does not match '+path);assert(compiled.mtimeMs>=(await stat(join(host,path))).mtimeMs,'Build does not include the current prepared source');report.sourceSHA256[path]=createHash('sha256').update(source).digest('hex')}
 report.binarySHA256=createHash('sha256').update(await readFile(executable)).digest('hex');

 if(platform==='ios'){
  initialDevice=await deviceState();if(initialDevice==='Shutdown'){await command('xcrun','simctl','boot',device);await command('xcrun','simctl','bootstatus',device,'-b')}
  await exec('xcrun',['simctl','install',device,product],{timeout:120000,maxBuffer:1024*1024});home=await command('xcrun','simctl','get_app_container',device,bundle,'data');assert(home.includes('/'+device+'/data/Containers/Data/Application/'));
 }else{
  home=join(homedir(),'Library/Containers',bundle,'Data');
  if(!(await stat(home).catch(()=>null))){await launch('invalid');for(let i=0;i<50;i++){if(await stat(home).catch(()=>null))break;await sleep(100)}await stop()}
 }
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;
 const password=randomBytes(24).toString('base64url'),nonce=randomUUID(),task=randomUUID(),sibling=randomUUID(),child=randomUUID(),project=randomUUID();
 const signup=await runtime.request('auth','/signup',{method:'POST',body:{email:'native-store-'+nonce+'@example.invalid',password}});assert.equal(signup.status,200);const authorization=signup.value.access_token,account=signup.value.user.id;
 const api=(path,options={})=>runtime.request('rest',path,{authorization,...options});
 assert.equal((await api('/projects',{method:'POST',body:{id:project,user_id:account,name:'Native Store workshop'}})).status,201);
 const children=[{id:child,title:'Original child',subtasks:[],future:{keep:[null,false,'exact']}},{id:sibling,title:'Original sibling',subtasks:[]}];
 if(mode.startsWith('structure'))children[0].subtasks=[{id:randomUUID(),title:'Nested branch content',subtasks:[],future:{keep:[false,null,'nested exact']}}];
 const taskResponse=await api('/tasks',{method:'POST',headers:{Prefer:'return=representation'},body:{id:task,user_id:account,project_id:project,title:'Original task title',description:'Original server description',subtasks:children}});assert.equal(taskResponse.status,201);const source=taskResponse.value[0];report.genuineLocalAuthREST=true;
 const promotion=await runtime.raw(`update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true;select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(task)}`);
 check('synthetic root is explicitly record-authoritative',promotion.split('\n').at(-1)==='records');
 if(mode.startsWith('structure'))await runtime.raw('update taskfold_private.child_task_record_config set completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true');
 root=join(home,'Library/Application Support/TaskfoldFullSchemaNative-workflowteststeameditbridge');await mkdir(root,{recursive:true,mode:0o700});
 for(const file of ['config.json','session.json','initial.json','queue.json','loss.json','replay.json','verify.json','child-queue.json','child-loss.json','child-replay.json','child-verify.json','structure-queue.json','structure-loss.json','structure-replay.json','structure-verify.json','structure-undo.json','structure-undo-verify.json','structure-redo.json','structure-redo-verify.json',...['field','structure'].flatMap(f=>['queue','refuse','save','send','verify'].map(p=>f+'-review-'+p+'.json'))])await rm(join(root,file),{force:true});
 config={version:1,nonce,account,task,sibling,child,origin:new URL(runtime.urls.rest).origin,key:runtime.anon,email:'native-store-'+nonce+'@example.invalid',password,queuedFingerprint:null};
 await writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});cache=join(home,'Library/Application Support/Taskfold',account+'.json');
 if(mode.endsWith('-conflict')){
  const hierarchy=mode==='structure-conflict',family=hierarchy?'structure':'field',prefix=family+'-review-';
  const baseline=(await api('/tasks?id=eq.'+task+'&select=*')).value[0].subtasks;
  const queued=await phase(prefix+'queue');report.actualAppBackendStore=true;
  const original=queued.history[0].command.body;
  check('offline review request stays in its own journal',queued.history.length===1&&queued.history[0].phase==='queued'&&queued.pending===0);
  config.queuedFingerprint=queued.originalFingerprint;await writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});
  check('offline review queue leaves server unchanged',isDeepStrictEqual((await api('/tasks?id=eq.'+task+'&select=*')).value[0].subtasks,baseline));
  assert.equal((await api('/tasks?id=eq.'+task,{method:'PATCH',body:{title:'Changed remotely while closed'}})).status,204);
  const getRead=async structural=>{const r=await api('/rpc/'+(structural?'taskfold_read_child_structure':'taskfold_read_child_tasks'),{method:'POST',body:{_id:task,_generation:source.task_generation}});assert.equal(r.status,200);return r.value};
  let read=await getRead(false);
  async function edit(key,changes){const node=read.records.find(x=>x.node_key===key);const body={protocol:1,account,request_id:randomUUID(),task_id:task,task_generation:source.task_generation,project_id:project,node_key:node.node_key,incarnation:node.incarnation,revision:node.revision,changes};assert.equal((await api('/rpc/taskfold_edit_child_task',{method:'POST',body:{_body:body}})).status,200);read=await getRead(false)}
  await edit(sibling,{title:'Remote sibling edit'});
  if(hierarchy){
   const current=await getRead(true),node=current.records.find(x=>x.node_key===sibling);
   const body={protocol:1,account,request_id:randomUUID(),task_id:task,task_generation:source.task_generation,project_id:project,structure_revision:current.structure_revision,action:'move',node_key:node.node_key,incarnation:node.incarnation,parent_key:null,index:0};
   assert.equal((await api('/rpc/taskfold_edit_child_structure',{method:'POST',body:{_body:body}})).status,200);
  }else await edit(child,{description:'Remote description',priority:1});
  const remote=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];
  const refused=await phase(prefix+'refuse');
  check('stale actual request is retained for review without confirmation',refused.history.length===1&&refused.history[0].phase==='attempted'&&!refused.history[0].receipt&&refused.originalFingerprint===queued.originalFingerprint&&isDeepStrictEqual(refused.history[0].command,queued.history[0].command)&&refused.notice.includes('review'));
  check('stale refusal preserves the competing remote tree',isDeepStrictEqual((await api('/tasks?id=eq.'+task+'&select=*')).value[0].subtasks,remote.subtasks));
  const reviewed=await phase(prefix+'save'),closed=reviewed.history[0],replacement=reviewed.history[1];
  if(!hierarchy)check('field review joins an actual held background workspace read',reviewed.joinedExistingRead===true);
  check('original is durably closed before saving a new request',reviewed.history.length===2&&closed.phase==='closed'&&closed.resolution.raw.outcome==='closed'&&isDeepStrictEqual(closed.command,queued.history[0].command)&&reviewed.originalFingerprint===queued.originalFingerprint);
  check('review saves a fresh queued identity without sending',replacement.phase==='queued'&&replacement.command.body.request_id!==original.request_id&&isDeepStrictEqual((await api('/tasks?id=eq.'+task+'&select=*')).value[0].subtasks,remote.subtasks));
  if(hierarchy)check('hierarchy replacement captures the current structure version',replacement.command.body.structure_revision===original.structure_revision+1&&replacement.command.body.parent_key===sibling&&replacement.command.body.node_key===child);
  else check('field review selects description and preserves remote priority',isDeepStrictEqual(replacement.command.body.changes,{description:'Reviewed local description'})&&replacement.command.body.revision>original.revision&&replacement.before.values.description==='Remote description');
  const sent=await phase(prefix+'send'),verified=await phase(prefix+'verify');
  check('reviewed request confirms and survives an offline cold return',sent.history[1].phase==='confirmed'&&sent.history[1].receipt.raw.replayed===false&&sent.history[1].receipt.raw.request_id===replacement.command.body.request_id&&sameReviewHistory(sent.history,verified.history)&&verified.originalFingerprint===queued.originalFingerprint);
  check('original closure proof and immutable action survive replacement',isDeepStrictEqual(reviewEntry(verified.history[0]),reviewEntry(closed)));
  const disk=await json(cache),saved=disk.tables.tasks.find(x=>x.id===task),server=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];
  const expected=hierarchy?[{...baseline[1],title:'Remote sibling edit',subtasks:[baseline[0]]}]:[{...baseline[0],description:'Reviewed local description',priority:1},{...baseline[1],title:'Remote sibling edit'}];
  check('final cache and server contain exactly the reviewed changes',isDeepStrictEqual(saved.subtasks,expected)&&isDeepStrictEqual(server.subtasks,expected)&&saved.title==='Changed remotely while closed'&&saved.description===source.description&&saved.task_generation===source.task_generation&&disk.pending.length===0);
  if(hierarchy){const current=await getRead(true);check('only competing reorder and reviewed move advance hierarchy',current.structure_revision===original.structure_revision+2&&current.records.length===3&&new Set(current.records.map(x=>x.node_key)).size===3)}
  check('record authority survives actual conflict review',await runtime.raw(`select count(*) from taskfold_private.child_task_record_authority where task_id=${lit(task)} and task_generation=${lit(source.task_generation)}::uuid`)==='1');
 }else if(mode==='structure'){
  const baseline=(await api('/tasks?id=eq.'+task+'&select=*')).value[0].subtasks;
  check('synthetic branch contains its nested descendant',baseline.length===2&&baseline[0].subtasks.length===1);
  const queued=await phase('structure-queue');report.actualAppBackendStore=true;
  check('offline hierarchy action stays out of root queue',queued.journalPhase==='queued'&&queued.pending===0&&queued.history.length===1);
  config.queuedFingerprint=queued.commandFingerprint;await writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});
  check('offline hierarchy queue leaves server unchanged',isDeepStrictEqual((await api('/tasks?id=eq.'+task+'&select=*')).value[0].subtasks,baseline));
  assert.equal((await api('/tasks?id=eq.'+task,{method:'PATCH',body:{title:'Changed remotely while closed'}})).status,204);
  const reading=(await api('/rpc/taskfold_read_child_tasks',{method:'POST',body:{_id:task,_generation:source.task_generation}})).value;
  const target=reading.records.find(x=>x.node_key===sibling);
  const body={protocol:1,account,request_id:randomUUID(),task_id:task,task_generation:source.task_generation,project_id:project,node_key:target.node_key,incarnation:target.incarnation,revision:target.revision,changes:{title:'Remote sibling edit'}};
  assert.equal((await api('/rpc/taskfold_edit_child_task',{method:'POST',body:{_body:body}})).status,200);
  const restored=[baseline[0],{...baseline[1],title:'Remote sibling edit'}];
  const moved=[{...baseline[1],title:'Remote sibling edit',subtasks:[baseline[0]]}];
  const structure=async()=>{const r=await api('/rpc/taskfold_read_child_structure',{method:'POST',body:{_id:task,_generation:source.task_generation}});assert.equal(r.status,200);return r.value};
  const initialRevision=queued.history[0].command.structure_revision;
  const loss=await phase('structure-loss');
  check('lost move reply retains the exact attempted action',loss.journalPhase==='attempted'&&loss.commandFingerprint===queued.commandFingerprint&&isDeepStrictEqual(loss.history[0].command,queued.history[0].command)&&loss.droppedReplies===1);
  const committed=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];
  check('lost move reply followed one committed whole-branch move',isDeepStrictEqual(committed.subtasks,moved)&&(await structure()).structure_revision===initialRevision+1);
  const replay=await phase('structure-replay'),verified=await phase('structure-verify');
  check('cold move retry returns the original replay receipt',replay.history[0].receipt.replayed===true&&replay.history[0].receipt.request_id===queued.history[0].command.request_id&&replay.commandFingerprint===queued.commandFingerprint);
  check('confirmed move receipt survives offline reopening',isDeepStrictEqual(verified.history,replay.history)&&verified.journalPhase==='confirmed');
  async function projection(name,expected,revision){
   const disk=await json(cache),saved=disk.tables.tasks.find(x=>x.id===task),server=(await api('/tasks?id=eq.'+task+'&select=*')).value[0],read=await structure();
   check(name+' cache and server retain exact tree',isDeepStrictEqual(saved.subtasks,expected)&&isDeepStrictEqual(server.subtasks,expected)&&saved.title==='Changed remotely while closed'&&saved.description===source.description&&saved.task_generation===source.task_generation&&disk.pending.length===0);
   check(name+' has exactly three original nodes and one revision advance',read.records.length===3&&new Set(read.records.map(x=>x.node_key)).size===3&&read.structure_revision===revision);
  }
  await projection('replayed move',moved,initialRevision+1);
  const undo=await phase('structure-undo'),undoVerified=await phase('structure-undo-verify');
  check('Undo is a fresh confirmed action bound to original move',undo.history.length===2&&undo.history[1].command.action==='undo'&&undo.history[1].command.undo_of===queued.history[0].command.request_id&&undo.history[1].receipt.replayed===false&&isDeepStrictEqual(undo.history,undoVerified.history));
  await projection('cold Undo',restored,initialRevision+2);
  const redo=await phase('structure-redo'),redoVerified=await phase('structure-redo-verify');
  check('Redo is a fresh confirmed move bound to Undo',redo.history.length===3&&redo.history[2].command.action==='move'&&redo.history[2].redoOf===undo.history[1].command.request_id&&redo.history[2].receipt.replayed===false&&new Set(redo.history.map(x=>x.command.request_id)).size===3&&isDeepStrictEqual(redo.history,redoVerified.history));
  await projection('cold Redo',moved,initialRevision+3);
  check('original move identity remains unchanged through history',redoVerified.commandFingerprint===queued.commandFingerprint&&isDeepStrictEqual(redoVerified.history[0].command,queued.history[0].command));
  check('record authority survives hierarchy recovery and history',await runtime.raw(`select count(*) from taskfold_private.child_task_record_authority where task_id=${lit(task)} and task_generation=${lit(source.task_generation)}::uuid`)==='1');
 }else if(mode==='child'){
  const queued=await phase('child-queue');report.actualAppBackendStore=true;
  const before=await json(cache);check('child save does not use the root mutation queue',before.pending.length===0&&queued.journalPhase==='queued');
  config.queuedFingerprint=queued.commandFingerprint;await writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});
  const beforeRemote=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];check('offline child journal did not touch server',beforeRemote.subtasks[0].description===undefined&&beforeRemote.description===source.description);
  assert.equal((await api('/tasks?id=eq.'+task,{method:'PATCH',body:{title:'Changed remotely while closed'}})).status,204);
  const reading=(await api('/rpc/taskfold_read_child_tasks',{method:'POST',body:{_id:task,_generation:source.task_generation}})).value;
  const target=reading.records.find(x=>x.node_key===sibling);
  const body={protocol:1,account,request_id:randomUUID(),task_id:task,task_generation:source.task_generation,project_id:project,node_key:target.node_key,incarnation:target.incarnation,revision:target.revision,changes:{title:'Remote sibling edit'}};
  assert.equal((await api('/rpc/taskfold_edit_child_task',{method:'POST',body:{_body:body}})).status,200);
  const loss=await phase('child-loss');check('lost child reply preserves original command and baseline',loss.journalPhase==='attempted'&&loss.commandFingerprint===queued.commandFingerprint&&isDeepStrictEqual(loss.journalCommand,queued.journalCommand)&&loss.droppedReplies===1);
  const committed=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];check('dropped child reply followed a real committed edit',committed.subtasks[0].description==='Child edit saved offline');
  const replay=await phase('child-replay'),verified=await phase('child-verify');
  check('child retry confirms the original request as replay',replay.journalPhase==='confirmed'&&replay.receipt.replayed===true&&replay.receipt.request_id===queued.journalCommand.request_id&&isDeepStrictEqual(replay.journalCommand,queued.journalCommand));
  check('confirmed receipt and baseline survive offline cold reopening',verified.commandFingerprint===queued.commandFingerprint&&isDeepStrictEqual(verified.receipt,replay.receipt)&&verified.journalPhase==='confirmed');
  const final=await json(cache),saved=final.tables.tasks.find(x=>x.id===task),server=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];
  check('actual cache preserves child edit and remote sibling and title',saved.title===server.title&&saved.title==='Changed remotely while closed'&&isDeepStrictEqual(saved.subtasks,server.subtasks)&&saved.subtasks[0].description==='Child edit saved offline'&&saved.subtasks[1].title==='Remote sibling edit');
  check('child journal never rewrites root fields or opaque values',saved.description===source.description&&JSON.stringify(server.subtasks[0].future)===JSON.stringify(children[0].future)&&server.task_generation===source.task_generation&&final.pending.length===0);
  check('record authority survives native child recovery',await runtime.raw(`select count(*) from taskfold_private.child_task_record_authority where task_id=${lit(task)} and task_generation=${lit(source.task_generation)}::uuid`)==='1');
 }else{
 await phase('initial');report.actualAppBackendStore=true;const initial=await json(cache);check('real account cache has the genuine task',initial.tables.tasks.some(x=>x.id===task));
 const queued=await phase('queue');const before=await json(cache);check('offline queue is on disk',before.pending.length===1);config.queuedFingerprint=queued.pendingFingerprint;await writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});
 const beforeRemote=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];check('offline save did not touch server',beforeRemote.description===source.description);
 assert.equal((await api('/tasks?id=eq.'+task,{method:'PATCH',body:{title:'Changed remotely while closed'}})).status,204);
 const reading=(await api('/rpc/taskfold_read_child_tasks',{method:'POST',body:{_id:task,_generation:source.task_generation}})).value;
 const target=reading.records.find(x=>x.node_key===sibling);
 const body={protocol:1,account,request_id:randomUUID(),task_id:task,task_generation:source.task_generation,project_id:project,node_key:target.node_key,incarnation:target.incarnation,revision:target.revision,changes:{title:'Remote sibling edit'}};
 assert.equal((await api('/rpc/taskfold_edit_child_task',{method:'POST',body:{_body:body}})).status,200);
 await phase('loss');const uncertain=await json(cache);check('lost response preserves the exact disk queue',isDeepStrictEqual(uncertain.pending,before.pending));
 const committed=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];check('dropped response followed a real committed write',committed.description==='Saved offline by the actual Store');
 await phase('replay');await phase('verify');const final=await json(cache),saved=final.tables.tasks.find(x=>x.id===task),server=(await api('/tasks?id=eq.'+task+'&select=*')).value[0];
 check('queue is cleared only after retry confirmation',final.pending.length===0);
 check('actual cache preserves local and remote edits',saved.description===server.description&&saved.title===server.title&&isDeepStrictEqual(saved.subtasks,server.subtasks));
 check('opaque data and generation preserved',JSON.stringify(server.subtasks[0].future)===JSON.stringify(children[0].future)&&server.task_generation===source.task_generation);
 check('record authority survives actual Store sync',await runtime.raw(`select count(*) from taskfold_private.child_task_record_authority where task_id=${lit(task)} and task_generation=${lit(source.task_generation)}::uuid`)==='1');
 }
 report.cacheSHA256=createHash('sha256').update(await readFile(cache)).digest('hex');report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code};process.exitCode=1}
finally{
 try{await stop();report.appClosed=true}catch(e){report.cleanupError=e.message;process.exitCode=1}
 if(root)for(const file of ['config.json','session.json'])await rm(join(root,file),{force:true});
 if(runtime)report.servicesRemoved=await runtime.close();
 if(platform==='ios'&&initialDevice){if(initialDevice==='Shutdown'&&await deviceState()==='Booted')await command('xcrun','simctl','shutdown',device);report.simulatorRestored=await deviceState()===initialDevice}
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,error:report.error,checkCount:report.checkCount,appClosed:report.appClosed,servicesRemoved:report.servicesRemoved}));
}
