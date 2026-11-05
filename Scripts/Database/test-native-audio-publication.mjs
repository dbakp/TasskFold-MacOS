import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify,isDeepStrictEqual} from 'node:util';
import {randomUUID,randomBytes,createHash} from 'node:crypto';
import {readFile as fsReadFile,writeFile as fsWriteFile,mkdir as fsMkdir,rm as fsRm,stat as fsStat,realpath,readdir as fsReaddir} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {createFullSchemaAudioFixture} from './full-schema-audio-fixture.mjs';
const exec=promisify(execFile),[platform,output]=process.argv.slice(2),repo=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
assert(['ios','mac'].includes(platform));assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));assert(!(await fsStat(output).catch(()=>null)));
const device='F2ACCCB5-E5B3-426F-B962-955A113D4EF4',bundle=platform==='ios'?'com.dbakp.taskfold.workflowteststeameditbridge':'com.dbakp.taskfold.mac.workflowteststeameditbridge';
const product=platform==='ios'?'/tmp/taskfold-source-native-ios-products/Debug-iphonesimulator/Taskfold.app':'/tmp/taskfold-workflow-native-mac-build/Build/Products/Debug/Taskfold.app';
const host=platform==='ios'?'/tmp/taskfold-source-selection-ios-host':'/tmp/taskfold-owner-review-mac-host';
const report={platform,actualAppPublicationFlow:true,genuineLocalAuthRESTStorage:true,scopedAudioTLS:true,protectedKeychainOrReleaseTrustAccepted:false,normalGatesChanged:false,hostedChanges:false,checks:{},phases:{}};
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

const servicePaths=['Scripts/Database/test-native-audio-publication.mjs','Scripts/Database/full-schema-runtime.mjs','Scripts/Database/full-schema-gateway.mjs','Scripts/Database/full-schema-audio-fixture.mjs','Scripts/Database/full-schema-audio-server.ts','supabase/functions/audio-comments/handler.ts','supabase/functions/audio-comments/wire.ts'];
report.serviceSourceSHA256=Object.fromEntries(await Promise.all(servicePaths.map(async path=>[path,hash(await readFile(join(repo,path)))])));
let runtime,audio,initialDevice,root,home,config,mediaFolder,mediaFile,cache,pid,untrustedDir,activePhase;
async function deviceState(){const d=JSON.parse(await command('xcrun','simctl','list','devices','--json'));return Object.values(d.devices).flat().find(x=>x.udid===device).state}
async function stop(){
 if(platform==='ios'){try{await command('xcrun','simctl','terminate',device,bundle)}catch{};if(pid){for(let i=0;i<30;i++){try{process.kill(pid,0)}catch(error){if(error.code==='ESRCH'){pid=null;return}throw error}await sleep(100)}throw Error('Owned iPhone app did not close')}return}
 if(!pid&&activePhase){const rows=(await command('ps','-axo','pid=,command=')).split('\n').filter(line=>line.includes(product+'/Contents/MacOS/Taskfold')&&line.includes('--full-schema-phase='+activePhase));assert(rows.length<=1,'Ambiguous reserved Mac process');if(rows.length)pid=Number(rows[0].trim().split(/\s/)[0])}
 if(pid){try{const comm=await command('ps','-p',String(pid),'-o','comm=');assert(await realpath(comm)===await realpath(product+'/Contents/MacOS/Taskfold'));process.kill(pid,'SIGTERM');for(let i=0;i<30;i++){try{process.kill(pid,0)}catch{pid=null;return}await sleep(100)}throw Error('Owned Mac app did not close')}catch(error){if(error.code===1){pid=null;return}throw error}}
}
async function launch(name){
 await stop();activePhase=name;const flags=['--team-editor-testing','--full-schema-native-testing','--full-schema-phase='+name];
 if(platform==='ios'){const text=await command('xcrun','simctl','launch',device,bundle,...flags);pid=Number(text.match(/: (\d+)$/)?.[1]);assert(pid)}
 else{await command('open','-n',product,'--args',...flags);for(let i=0;i<50;i++){const rows=(await command('ps','-axo','pid=,comm=')).split('\n').filter(s=>s.trim().endsWith(product+'/Contents/MacOS/Taskfold'));if(rows.length===1){pid=Number(rows[0].trim().split(/\s/)[0]);break}await sleep(100)}assert(pid)}
}
async function files(path){let result=[];for(const entry of await readdir(path,{withFileTypes:true})){const p=join(path,entry.name);if(entry.isDirectory())result.push(...await files(p));else if(entry.isFile())result.push(p)}return result}
async function phase(name){
 const path=join(root,name+'.json');await rm(path,{force:true});await launch(name);const deadline=Date.now()+90000;
 while(Date.now()<deadline){try{const data=JSON.parse(await readFile(path,'utf8'));if(data.nonce===config.nonce&&data.phase===name){report.phases[name]=data;check('actual native phase '+name,data.accepted===true);await stop();return data}}catch(error){if(error.code!=='ENOENT'&&!(error instanceof SyntaxError))throw error}await sleep(150)}throw Error('Actual native '+name+' exceeded deadline');
}
try{
 await command('python3',join(repo,'Scripts/check_test_storage.py'),'--path','/tmp');await command('codesign','--verify','--deep','--strict',product);
 const paths=['Taskfold/Core/Store.swift','Taskfold/Core/Backend.swift','Taskfold/Core/Models.swift','Taskfold/Core/AudioComments.swift','Taskfold/Core/AudioCommentVault.swift','Taskfold/Core/AudioCommentPublishing.swift','Taskfold/Core/AudioCommentPending.swift','Taskfold/Core/AudioCommentDecoding.swift','Taskfold/TeamTemplateNativeFixture.swift'];
 const binary=join(product,platform==='ios'?'':'Contents/MacOS','Taskfold.debug.dylib'),compiled=await stat(binary);report.sourceSHA256={};
 for(const path of paths){const source=await readFile(join(repo,path),'utf8');let scoped=source;
  const mapping=path==='Taskfold/Core/Backend.swift'?{'com.taskfold.ios.session':'com.taskfold.workflowteststeameditbridge.session','com.dbakp.taskfold.mac.backupcanceltests':'com.dbakp.taskfold.mac.workflowteststeameditbridge','com.dbakp.taskfold.backupcanceltests':'com.dbakp.taskfold.workflowteststeameditbridge'}:path==='Taskfold/Core/Store.swift'?{'group.com.dbakp.taskfold':'group.com.dbakp.taskfold.workflowteststeameditbridge'}:{};
  for(const [from,to] of Object.entries(mapping))scoped=scoped.replaceAll(from,to);
  assert.equal(await readFile(join(host,path),'utf8'),scoped,'Prepared native source differs: '+path);assert(compiled.mtimeMs>=(await stat(join(host,path))).mtimeMs,'Rebuild current '+path);report.sourceSHA256[path]=hash(source);
 }
 report.binarySHA256=hash(await readFile(binary));
 if(platform==='ios'){
  initialDevice=await deviceState();if(initialDevice==='Shutdown'){await command('xcrun','simctl','boot',device);await command('xcrun','simctl','bootstatus',device,'-b')}
  await command('xcrun','simctl','install',device,product);home=await command('xcrun','simctl','get_app_container',device,bundle,'data');assert(home.includes('/'+device+'/data/Containers/Data/Application/'));
 }else{
  home=join(homedir(),'Library/Containers',bundle,'Data');assert(await stat(home),'Existing reserved Mac sandbox is required');
 }
 runtime=await createFullSchemaRuntime();audio=await createFullSchemaAudioFixture(runtime);report.migrations=runtime.migrations;report.images=runtime.images;
 const nonce=randomUUID(),password=randomBytes(24).toString('base64url'),email='native-audio-'+nonce+'@example.invalid';
 const signup=await runtime.request('auth','/signup',{method:'POST',body:{email,password}});assert.equal(signup.status,200);const account=signup.value.user.id,authorization=signup.value.access_token,task=randomUUID(),project=randomUUID();
 const api=(path,body)=>runtime.request('rest',path,{method:'POST',authorization,body,headers:{Prefer:'return=representation'}});
 assert.equal((await api('/projects',{id:project,user_id:account,name:'Native audio workshop'})).status,201);
 const source=await api('/tasks',{id:task,user_id:account,project_id:project,title:'Native audio publication proof',description:'Keep unrelated task content',subtasks:[]});assert.equal(source.status,201);
 await runtime.raw('update taskfold_private.audio_comment_config set enabled=true,audience_review_enabled=true');
 root=join(home,'Library/Application Support/TaskfoldFullSchemaNative-workflowteststeameditbridge');await mkdir(root,{recursive:true,mode:0o700});
 mediaFolder=join(root,'audio-'+nonce);mediaFile=join(root,'audio-media-'+nonce+'.m4a');
 const media=await readFile(new URL('../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a',import.meta.url));await writeFile(mediaFile,media,{mode:0o600});
 const der=pem=>Buffer.from(pem.replace(/-----[^\n]+-----/g,'').replace(/\s/g,''),'base64').toString('base64');
 config={version:1,nonce,account,task,sibling:randomUUID(),origin:new URL(runtime.urls.auth).origin,key:runtime.anon,email,password,audioOrigin:audio.endpoint,audioCA:der(audio.certificateAuthority)};
 cache=join(home,'Library/Application Support/Taskfold',account+'.json');
 const save=()=>writeFile(join(root,'config.json'),JSON.stringify(config),{mode:0o600});await save();await rm(join(root,'session.json'),{force:true});
 const created=await phase('audio-create');check('app used the genuine account and original clip',created.account===account&&created.clipSHA256===hash(media));
 const draftPaths=(await files(mediaFolder)).filter(p=>/\/draft-[a-f0-9-]+\.bin$/.test(p));assert.equal(draftPaths.length,1);const originalDraft=hash(await readFile(draftPaths[0]));report.originalDraftDiskSHA256=originalDraft;
 const originalTask=(await runtime.request('rest','/tasks?id=eq.'+task+'&select=*',{authorization})).value[0];
 // A different, well-formed CA must fail; no system trust changes or trust-all delegate.
 untrustedDir=join(root,'wrong-ca-'+nonce);await mkdir(untrustedDir,{mode:0o700});await exec('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',join(untrustedDir,'key'),'-out',join(untrustedDir,'cert'),'-days','1','-subj','/CN=Unrelated disposable CA','-addext','basicConstraints=critical,CA:TRUE']);
 const trusted=config.audioCA;config.audioCA=der(await readFile(join(untrustedDir,'cert'),'utf8'));await save();
 const denied=await phase('audio-deny');check('native URLSession rejects the unrelated CA and preserves the source',denied.rejectedUntrustedTLS&&audio.state.authRequests===0&&hash(await readFile(draftPaths[0]))===originalDraft);
 config.audioCA=trusted;await save();
 const loss=await phase('audio-loss');check('one real upload committed before native reply loss',loss.pending&&loss.approvalSaved&&loss.droppedReplies===1&&audio.state.uploads===1);
 check('original native intent was not regenerated after failed TLS review',loss.intentFingerprint===denied.intentFingerprint&&loss.operation===denied.operation);
 const publication=JSON.parse(await runtime.raw(`select to_jsonb(p) from taskfold_private.audio_comment_publications p where operation_id=${lit(loss.operation)}`));check('actual database contains the committed native publication',publication.state==='published');
 const recovered=await phase('audio-check');check('cold original confirmation and download use the published receipt',!recovered.pending&&recovered.receipt?.operation_id===loss.operation&&recovered.downloadedExactBytes&&recovered.intentFingerprint===loss.intentFingerprint);
 check('confirmation and reading do not upload a second recording',audio.state.uploads===1);
 const beforeOffline={auth:audio.state.authRequests,rpc:audio.state.rpcRequests,downloads:audio.state.downloads};
 const verified=await phase('audio-verify');check('published journal survives offline cold reopening',verified.offline&&!verified.pending&&isDeepStrictEqual(verified.receipt,recovered.receipt)&&verified.intentFingerprint===loss.intentFingerprint);
 check('offline cold verification performs no requests',isDeepStrictEqual(beforeOffline,{auth:audio.state.authRequests,rpc:audio.state.rpcRequests,downloads:audio.state.downloads}));
 report.finalDraftDiskSHA256=hash(await readFile(draftPaths[0]));check('original private recording file remains byte exact',report.finalDraftDiskSHA256===originalDraft);check('one original object and one publication exist',await runtime.raw("select (select count(*) from storage.objects where bucket_id='taskfold-audio-v1')=1 and (select count(*) from taskfold_private.audio_comment_publications)=1")==='t');
 const finalTask=(await runtime.request('rest','/tasks?id=eq.'+task+'&select=*',{authorization})).value[0];check('publication preserves unrelated canonical task data',isDeepStrictEqual(finalTask,originalTask));
 for(const path of paths)assert.equal(hash(await readFile(join(repo,path))),report.sourceSHA256[path],path+' changed during native acceptance');
 for(const path of servicePaths)assert.equal(hash(await readFile(join(repo,path))),report.serviceSourceSHA256[path],path+' changed during native acceptance');report.sourceUnchanged=true;report.handlerCounters={auth:audio.state.authRequests,rpc:audio.state.rpcRequests,uploads:audio.state.uploads,downloads:audio.state.downloads};report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code};process.exitCode=1}
finally{
 try{await stop();report.appClosed=true}catch(error){report.cleanupError=error.message;process.exitCode=1}
 // Stop services before touching potentially protected host-side app files.
 if(audio){try{await audio.close();report.handlerClosed=true}catch(error){report.handlerCleanupError=error.message;process.exitCode=1}}
 if(runtime){try{report.servicesRemoved=await runtime.close()}catch(error){report.serviceCleanupError=error.message;process.exitCode=1}}
 report.pendingPrivateFiles=[];
 const cleanup=[...(root?['config.json','session.json'].map(path=>join(root,path)):[]),mediaFolder,mediaFile,untrustedDir,cache].filter(Boolean);
 for(const path of cleanup){try{await rm(path,{recursive:true,force:true})}catch(error){report.pendingPrivateFiles.push(path);report.privateCleanupError=error.code??error.message;process.exitCode=1}}
 if(platform==='ios'&&initialDevice){if(initialDevice==='Shutdown'&&await deviceState()==='Booted')await command('xcrun','simctl','shutdown',device);report.simulatorRestored=await deviceState()===initialDevice}
 report.privateIOBlocked=privateIOBlocked;
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,error:report.error,checks:report.checkCount,appClosed:report.appClosed,servicesRemoved:report.servicesRemoved,privateIOBlocked}));
 // Outstanding kernel IO requests must not keep a failed private-container
 // check alive after its app/services are closed and its result is retained.
 if(privateIOBlocked)process.exit(1);
}
