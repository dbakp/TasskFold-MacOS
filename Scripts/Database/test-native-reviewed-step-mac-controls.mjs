// Production Store/Backend/UndoManager against an isolated genuine Auth/REST stack.
// This does not substitute for interacting with the review screen or real inference.
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify,isDeepStrictEqual} from 'node:util';
import {randomUUID,randomBytes,createHash} from 'node:crypto';
import {readFile,writeFile,mkdir,rm,stat,realpath} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const exec=promisify(execFile),[platform,output]=process.argv.slice(2),repo=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
assert(platform==='mac');assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));assert(!await stat(output).catch(()=>null),'Preserve previous evidence');
const device='F2ACCCB5-E5B3-426F-B962-955A113D4EF4',bundle=platform==='ios'?'com.dbakp.taskfold.workflowteststeameditbridge':'com.dbakp.taskfold.mac.workflowteststeameditbridge';
const host=platform==='ios'?'/tmp/taskfold-source-selection-ios-host':'/tmp/taskfold-owner-review-mac-host';
const product=platform==='ios'?'/tmp/taskfold-source-native-ios-products/Debug-iphonesimulator/Taskfold.app':'/tmp/taskfold-workflow-native-mac-build/Build/Products/Debug/Taskfold.app';
const phases=['step-ui','step-queue','step-loss','step-replay','step-verify','step-history','step-history-verify','step-close-queue','step-close','step-close-verify'];
const report={platform,actualAppBackendStore:false,genuineLocalAuthREST:false,actualNativeUndoManagerBridge:false,reviewScreenAccepted:false,realGenerationAccepted:false,genuineTLSOrKeychainAcceptance:false,hostedChanges:false,checks:{},phases:{}};
let runtime,initialDevice,root,home,config,pid,cache;
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),hash=b=>createHash('sha256').update(b).digest('hex');
const command=async(...a)=>(await exec(a[0],a.slice(1),{timeout:60000,maxBuffer:1024*1024})).stdout.trim();
const lit=v=>"'"+String(v).replaceAll("'","''")+"'";
const check=(name,v)=>{assert.equal(v,true,name);report.checks[name]=true;console.log('passed',name)};
async function state(){const d=JSON.parse(await command('xcrun','simctl','list','devices','--json'));return Object.values(d.devices).flat().find(x=>x.udid===device).state}
async function stop(){
 if(!pid)return;
 if(platform==='ios')await command('xcrun','simctl','terminate',device,bundle).catch(()=>{});
 else {const comm=await command('ps','-p',String(pid),'-o','comm=').catch(()=>null);if(comm){assert(await realpath(comm)===await realpath(product+'/Contents/MacOS/Taskfold'));process.kill(pid,'SIGTERM')}}
 for(let i=0;i<40;i++){try{process.kill(pid,0)}catch(e){if(e.code==='ESRCH'){pid=null;return}throw e}await sleep(100)}throw Error('Owned app did not quit');
}
async function phase(name){
 await stop();const flags=['--team-editor-testing','--full-schema-native-testing','--full-schema-phase='+name,...(name==='step-ui'?['--reviewed-steps-seed']:[])];
 if(platform==='ios'){const t=await command('xcrun','simctl','launch',device,bundle,...flags);pid=Number(t.match(/: (\d+)$/)?.[1]);assert(pid)}
 else {await command('open','-n',product,'--args',...flags);for(let i=0;i<50;i++){const rows=(await command('ps','-axo','pid=,comm=')).split('\n').filter(x=>x.trim().endsWith(product+'/Contents/MacOS/Taskfold'));if(rows.length===1){pid=Number(rows[0].trim().split(/\s/)[0]);break}await sleep(100)}assert(pid)}
 const deadline=Date.now()+110000;
 while(Date.now()<deadline){const p=join(root,name+'.json');try{const r=JSON.parse(await readFile(p,'utf8'));if(r.nonce===config.nonce&&r.phase===name){report.phases[name]=r;check('actual Store '+name,r.accepted===true);if(name!=='step-ui')await stop();return r}}catch(e){if(e.code!=='ENOENT'&&!(e instanceof SyntaxError))throw e}await sleep(150)}
 throw Error('Actual step phase exceeded its deadline: '+name);
}
function prepared(p,bytes){let s=bytes.toString('utf8').replaceAll('backupcanceltests','workflowteststeameditbridge');if(p.endsWith('/Backend.swift'))s=s.replaceAll('com.taskfold.ios.session','com.taskfold.workflowteststeameditbridge.session').replaceAll('com.taskfold.mac.session','com.taskfold.workflowteststeameditbridge.session');if(p.endsWith('/Backend.swift')||p.endsWith('/Backups.swift'))s=s.replaceAll('com.taskfold.recovery.v1','com.taskfold.workflowteststeameditbridge.recovery');if(p.endsWith('/Store.swift'))s=s.replaceAll('group.com.dbakp.taskfold','group.com.dbakp.taskfold.workflowteststeameditbridge');return s}
try{
 await command('python3',join(repo,'Scripts/check_test_storage.py'),'--path','/tmp');await command('codesign','--verify','--deep','--strict',product);
 const info=JSON.parse(await command('plutil','-convert','json','-o','-',join(product,platform==='ios'?'':'Contents','Info.plist')));assert.equal(info.CFBundleIdentifier,bundle);
 for(const k of ['TaskfoldChildRecordReadsEnabled','TaskfoldChildRecordWritesEnabled','TaskfoldChildRecordCompletionsEnabled','TaskfoldChildStructureReadsEnabled','TaskfoldChildStructureWritesEnabled'])assert.equal(info[k],true,k+' only in isolated host');
 const executable=join(product,platform==='ios'?'':'Contents/MacOS','Taskfold.debug.dylib'),compiled=await stat(executable);report.sourceSHA256={};
 for(const p of ['Taskfold/Core/Store.swift','Taskfold/Core/Backend.swift','Taskfold/Core/ReviewedTaskSteps.swift','Taskfold/Core/ChildTaskTransfers.swift','Taskfold/Core/ChildTaskCompletionCommands.swift','Taskfold/TeamTemplateNativeFixture.swift','Taskfold/Views/ReviewedTaskStepsView.swift','Taskfold/Core/NoteMarkup.swift']){const b=await readFile(join(repo,p));assert.equal(await readFile(join(host,p),'utf8'),prepared(p,b),'Prepared '+p);assert(compiled.mtimeMs>=(await stat(join(host,p))).mtimeMs);report.sourceSHA256[p]=hash(b)}
 report.binarySHA256=hash(await readFile(executable));
 if(platform==='ios'){initialDevice=await state();if(initialDevice==='Shutdown'){await command('xcrun','simctl','boot',device);await command('xcrun','simctl','bootstatus',device,'-b')}await exec('xcrun',['simctl','install',device,product],{timeout:120000});home=await command('xcrun','simctl','get_app_container',device,bundle,'data');assert(home.includes('/'+device+'/data/Containers/Data/Application/'))}
 else {home=join(homedir(),'Library/Containers',bundle,'Data');assert(await stat(home),'Reuse established isolated Mac container')}
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;
 const nonce=randomUUID(),password=randomBytes(24).toString('base64url'),task=randomUUID(),child=randomUUID(),sibling=randomUUID(),project=randomUUID(),email='native-steps-'+nonce+'@example.invalid';
 const auth=await runtime.request('auth','/signup',{method:'POST',body:{email,password}});assert.equal(auth.status,200);const account=auth.value.user.id,authorization=auth.value.access_token;
 const api=(p,o={})=>runtime.request('rest',p,{authorization,...o});
 assert.equal((await api('/projects',{method:'POST',body:{id:project,user_id:account,name:'Native step workshop'}})).status,201);
 const children=[{id:child,title:'Original child',subtasks:null,future:{keep:[null,false,'exact']}},{id:sibling,title:'Original sibling',subtasks:[]}];
 const created=await api('/tasks',{method:'POST',headers:{Prefer:'return=representation'},body:{id:task,user_id:account,project_id:project,title:'Prepare the workshop',description:'Original server notes',subtasks:children}});assert.equal(created.status,201);const source=created.value[0];
 await runtime.raw(`update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,step_batches_enabled=true;select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(task)}`);
 root=join(home,'Library/Application Support/TaskfoldFullSchemaNative-workflowteststeameditbridge');await mkdir(root,{recursive:true,mode:0o700});
 for(const f of ['config.json','session.json',...phases.map(x=>x+'.json')])await rm(join(root,f),{force:true});
 config={version:1,nonce,account,task,sibling,child,origin:new URL(runtime.urls.rest).origin,key:runtime.anon,email,password,queuedFingerprint:null};
 await writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});cache=join(home,'Library/Application Support/Taskfold',account+'.json');
 const row=async()=>(await api('/tasks?id=eq.'+task+'&select=*')).value[0];const before=await row();
 const stateFile=output.replace(/\.json$/,'.state.json'),finishFile=output.replace(/\.json$/,'.finish');
 const expected=['Tomorrow #work @Pat','Review workshop layout'];
 async function stateReport(phase){await writeFile(stateFile,JSON.stringify({nonce,phase,pid,task,account,finishFile},null,2)+'\n',{mode:0o600});console.log('Screen phase:',phase)}
 async function until(label,predicate){const end=Date.now()+240000;while(Date.now()<end){const current=await row();if(predicate(current))return current;await sleep(250)}throw Error('Native controls did not finish '+label)}
 await phase('step-ui');report.actualAppBackendStore=true;report.genuineLocalAuthREST=true;
 await stateReport('ready-for-edited-selected-add');
 const added=await until('selected Add',r=>r.subtasks.length===4);
 check('only selected edited literal steps added',isDeepStrictEqual(added.subtasks.slice(2).map(x=>x.title),expected));
 check('Add preserves original children notes and generation',isDeepStrictEqual(added.subtasks.slice(0,2),children)&&added.description===source.description&&added.task_generation===source.task_generation);
 await stateReport('added-ready-for-undo');
 const undone=await until('Undo',r=>r.subtasks.length===2);
 check('Undo restores exact original children',isDeepStrictEqual(undone.subtasks,children)&&undone.description===source.description);
 await stateReport('undone-ready-for-redo');
 const redone=await until('Redo',r=>r.subtasks.length===4);
 check('Redo restores selected literal titles',isDeepStrictEqual(redone.subtasks.slice(2).map(x=>x.title),expected));
 check('Redo uses fresh child identities',redone.subtasks.slice(2).every(x=>!added.subtasks.slice(2).some(y=>x.id===y.id)));
 check('exactly three original Add Undo Redo receipts',await runtime.raw(`select count(*) from taskfold_private.child_task_step_receipts where task_id=${lit(task)}`)==='3');
 await stateReport('redone-awaiting-saved-cache');
 let disk,saved;const cacheStarted=Date.now();
 while(Date.now()-cacheStarted<30000){
  disk=JSON.parse(await readFile(cache,'utf8'));saved=disk.tables.tasks.find(x=>x.id===task);
  if(disk.pending.length===0&&isDeepStrictEqual(saved?.subtasks,redone.subtasks))break;
  await sleep(100);
 }
 report.savedCacheWaitMilliseconds=Date.now()-cacheStarted;
 check('saved cache agrees without root edits',disk.pending.length===0&&isDeepStrictEqual(saved?.subtasks,redone.subtasks));
 await stateReport('redone-ready-for-inspection');
 const end=Date.now()+120000;while(Date.now()<end){try{if(await readFile(finishFile,'utf8')===nonce)break}catch(e){if(e.code!=='ENOENT')throw e}await sleep(250)}
 assert.equal(await readFile(finishFile,'utf8'),nonce,'Controller must finish the observed UI check');
 report.reviewScreenAccepted=false;report.controllerObservationRequired=true;report.selectedAddUndoRedoDataAccepted=true;
 report.cacheSHA256=hash(await readFile(cache));report.accepted=true;report.checkCount=Object.keys(report.checks).length;
}catch(error){report.error={message:error.message,code:error.code};process.exitCode=1}
finally{
 try{await stop();report.appClosed=true}catch(e){report.cleanupError=e.message;process.exitCode=1}
 if(root)for(const f of ['config.json','session.json'])await rm(join(root,f),{force:true});
 if(runtime)report.servicesRemoved=await runtime.close();
 if(platform==='ios'&&initialDevice){if(initialDevice==='Shutdown'&&await state()==='Booted')await command('xcrun','simctl','shutdown',device);report.simulatorRestored=await state()===initialDevice}
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,error:report.error,checkCount:report.checkCount,appClosed:report.appClosed,servicesRemoved:report.servicesRemoved}));
}
