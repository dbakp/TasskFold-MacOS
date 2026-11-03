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
const exec=promisify(execFile),[platform,output]=process.argv.slice(2);
assert(['ios','mac'].includes(platform));assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
try{await stat(output);throw Error('Preserve previous result')}catch(e){if(e.code!=='ENOENT')throw e}
const repo=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const device='F2ACCCB5-E5B3-426F-B962-955A113D4EF4';
const bundle=platform==='ios'?'com.dbakp.taskfold.workflowteststeameditbridge':'com.dbakp.taskfold.mac.workflowteststeameditbridge';
const product=platform==='ios'?'/tmp/taskfold-prepared-undo-signed-ios-build/Build/Products/Debug-iphonesimulator/Taskfold.app':'/tmp/taskfold-workflow-native-mac-build/Build/Products/Debug/Taskfold.app';
const report={platform,actualAppBackendStore:false,genuineLocalAuthREST:false,transportIsTestOnly:true,genuineTLSOrKeychainAcceptance:false,hostedChanges:false,checks:{},phases:{}};
let runtime,initialDevice,root,home,config,pid,cache;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const command=async(...args)=>(await exec(args[0],args.slice(1),{timeout:60000,maxBuffer:1024*1024})).stdout.trim();
const lit=v=>"'"+String(v).replaceAll("'","''")+"'";
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
async function deviceState(){const devices=JSON.parse(await command('xcrun','simctl','list','devices','--json'));return Object.values(devices.devices).flat().find(d=>d.udid===device).state}
async function stop(){
 if(platform==='ios'){try{await command('xcrun','simctl','terminate',device,bundle)}catch{};return}
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
try{
 await command('python3',join(repo,'Scripts/check_test_storage.py'),'--path','/tmp');
 await command('codesign','--verify','--deep','--strict',product);
 const host=platform==='ios'?'/tmp/taskfold-owner-review-ios-host':'/tmp/taskfold-owner-review-mac-host';
 const mapping={'com.dbakp.taskfold.task':'com.dbakp.taskfold.workflowteststeameditbridge.task','com.taskfold.ios.session':'com.taskfold.workflowteststeameditbridge.session','com.taskfold.recovery.v1':'com.taskfold.workflowteststeameditbridge.recovery','group.com.dbakp.taskfold':'group.com.dbakp.taskfold.workflowteststeameditbridge'};
 const paths=['Taskfold/Core/Store.swift','Taskfold/Core/Backend.swift','Taskfold/Core/Models.swift','Taskfold/Core/TeamWorkspace.swift','Taskfold/TeamTemplateNativeFixture.swift',platform==='ios'?'Taskfold/Views/TaskEditor.swift':'Taskfold/Views/TaskInspector.swift'];
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
 const taskResponse=await api('/tasks',{method:'POST',headers:{Prefer:'return=representation'},body:{id:task,user_id:account,project_id:project,title:'Original task title',description:'Original server description',subtasks:children}});assert.equal(taskResponse.status,201);const source=taskResponse.value[0];report.genuineLocalAuthREST=true;
 const promotion=await runtime.raw(`update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true;select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(task)}`);
 check('synthetic root is explicitly record-authoritative',promotion.split('\n').at(-1)==='records');
 root=join(home,'Library/Application Support/TaskfoldFullSchemaNative-workflowteststeameditbridge');await mkdir(root,{recursive:true,mode:0o700});
 for(const file of ['config.json','session.json','initial.json','queue.json','loss.json','replay.json','verify.json'])await rm(join(root,file),{force:true});
 config={version:1,nonce,account,task,sibling,origin:new URL(runtime.urls.rest).origin,key:runtime.anon,email:'native-store-'+nonce+'@example.invalid',password,queuedFingerprint:null};
 await writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});cache=join(home,'Library/Application Support/Taskfold',account+'.json');
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
 report.cacheSHA256=createHash('sha256').update(await readFile(cache)).digest('hex');report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code};process.exitCode=1}
finally{
 try{await stop();report.appClosed=true}catch(e){report.cleanupError=e.message;process.exitCode=1}
 if(root)for(const file of ['config.json','session.json'])await rm(join(root,file),{force:true});
 if(runtime)report.servicesRemoved=await runtime.close();
 if(platform==='ios'&&initialDevice){if(initialDevice==='Shutdown'&&await deviceState()==='Booted')await command('xcrun','simctl','shutdown',device);report.simulatorRestored=await deviceState()===initialDevice}
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,error:report.error,checkCount:report.checkCount,appClosed:report.appClosed,servicesRemoved:report.servicesRemoved}));
}
