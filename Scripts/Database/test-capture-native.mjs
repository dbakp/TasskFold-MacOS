// Actual Store/Backend capture, Undo, Redo and second Undo against real local Auth/REST.
// Reuses a verified ordinary DEBUG candidate in a disposable, separately sandboxed copy.
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {randomUUID,randomBytes,createHash} from 'node:crypto';
import {readFile,writeFile,mkdir,rm,stat,realpath} from 'node:fs/promises';
import {homedir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const exec=promisify(execFile),[platform,productArg,output,device]=process.argv.slice(2);
assert(['mac','ios'].includes(platform));assert(productArg&&output&&/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
if(platform==='ios')assert(device==='F2ACCCB5-E5B3-426F-B962-955A113D4EF4','Use the existing reserved Taskfold Simulator');
const product=await realpath(productArg),repo=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const bundle=platform==='mac'?'com.dbakp.taskfold.mac.workflowteststeameditbridge':'com.dbakp.taskfold.workflowteststeameditbridge';
const copy='/tmp/taskfold-capture-native-'+platform+'/Taskfold.app',nonce=randomUUID();
const report={date:'2026-11-04',platform,actualStoreBackend:false,genuineLocalAuthREST:false,syntheticOnly:true,hostedChanges:false,sourceProduct:product,testTransportOnly:true,protectedKeychainOrTLSAccepted:false,checks:{}};
const cmd=async(...args)=>(await exec(args[0],args.slice(1),{timeout:60000,maxBuffer:1024*1024})).stdout.trim();
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name);};
let runtime,pid,initialState,home;
async function stop(){
 if(platform==='ios'){
  try{await cmd('xcrun','simctl','terminate',device,bundle)}catch(e){if(pid){try{process.kill(pid,0);throw e;}catch(stopped){if(stopped.code!=='ESRCH')throw stopped;}}}
  if(pid){for(let i=0;i<40;i++){try{process.kill(pid,0)}catch(e){if(e.code==='ESRCH'){pid=null;return;}throw e;}await delay(100);}throw Error('Owned Simulator app has not stopped');}
  return;
 }
 if(pid){try{const comm=await cmd('ps','-p',String(pid),'-o','comm=');assert.equal(await realpath(comm),await realpath(copy+'/Contents/MacOS/Taskfold'));process.kill(pid,'SIGTERM');}catch(e){if(e.code!==1&&e.code!=='ESRCH')throw e;}
  for(let i=0;i<40;i++){try{process.kill(pid,0)}catch{pid=null;return;}await delay(100);}throw Error('Owned test app has not stopped');}
}
try{
 try{await stat(output);throw Error('Preserve the existing result');}catch(e){if(e.code!=='ENOENT')throw e;}
 await cmd('python3',join(repo,'Scripts/check_test_storage.py'),'--path','/tmp');
 const contents=platform==='mac'?'Contents/':'',binary=join(product,contents,'MacOS/Taskfold.debug.dylib');
 const payload=platform==='mac'?binary:join(product,'Taskfold.debug.dylib');
 report.sourceBinarySHA256=createHash('sha256').update(await readFile(payload)).digest('hex');
 // Verify source and ordinary identity before any copy/launch. No source transform is used.
 const info=JSON.parse(await cmd('plutil','-convert','json','-o','-',join(product,contents,'Info.plist')));
 assert.equal(info.CFBundleIdentifier,platform==='mac'?'com.dbakp.taskfold.mac':'com.dbakp.taskfold');
 const appPaths=(await cmd('ps','-axo','comm=')).split('\n');assert(!appPaths.some(x=>x.trim().startsWith(copy+'/')),'Previous capture host still running');
 await rm(dirname(copy),{recursive:true,force:true});await mkdir(dirname(copy),{recursive:true,mode:0o700});await cmd('ditto',product,copy);
 await rm(join(copy,contents,'PlugIns'),{recursive:true,force:true});
 if(platform==='ios')await rm(join(copy,'Watch'),{recursive:true,force:true});
 for(const file of ['embedded.provisionprofile','embedded.mobileprovision'])await rm(join(copy,contents,file),{force:true});
 const infoPath=join(copy,contents,'Info.plist');
 // The disposable host must not register normal Taskfold links or file types.
 for(const key of ['CFBundleURLTypes','CFBundleDocumentTypes','UTExportedTypeDeclarations','UTImportedTypeDeclarations','NSUserActivityTypes'])if(Object.hasOwn(info,key))await cmd('/usr/libexec/PlistBuddy','-c','Delete :'+key,infoPath);
 await cmd('/usr/libexec/PlistBuddy','-c','Set :CFBundleIdentifier '+bundle,infoPath);
 await cmd('/usr/libexec/PlistBuddy','-c','Set :CFBundleDisplayName Taskfold Capture Test',infoPath);
 const entitlements=join(dirname(copy),'sandbox.plist');await writeFile(entitlements,'<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.network.client</key><true/></dict></plist>',{mode:0o600});
 await cmd('codesign','--force','--deep','--sign','-',...(platform==='mac'?['--entitlements',entitlements]:[]),copy);await cmd('codesign','--verify','--deep','--strict',copy);
 if(platform==='ios'&&process.env.TASKFOLD_CAPTURE_SOURCE_ARCHIVE_PROOF){
  const archived=JSON.parse(await readFile(process.env.TASKFOLD_CAPTURE_SOURCE_ARCHIVE_PROOF,'utf8'));
  assert.equal(product,'/private/tmp/taskfold-prepared-undo-signed-ios-build/Build/Products/Debug-iphonesimulator/Taskfold.app');
  assert(archived.simulatorOnly&&archived.archivePayloadVerified);
  assert.equal(archived.sourceProduct,product);assert.equal(archived.sourceBinarySHA256,report.sourceBinarySHA256);
  assert.equal(createHash('sha256').update(await readFile(archived.archive)).digest('hex'),archived.archiveSHA256);
  await rm(product,{recursive:true});report.sourceProductRetiredForStorage=true;report.verifiedSourceArchive=archived.archive;
 }
 if(platform==='ios'){
  const devices=JSON.parse(await cmd('xcrun','simctl','list','devices','--json'));const target=Object.values(devices.devices).flat().find(x=>x.udid===device);assert(target);initialState=target.state;
  if(initialState==='Shutdown'){await cmd('xcrun','simctl','boot',device);await cmd('xcrun','simctl','bootstatus',device,'-b');}
  await cmd('xcrun','simctl','install',device,copy);home=await cmd('xcrun','simctl','get_app_container',device,bundle,'data');
 }else home=join(homedir(),'Library/Containers',bundle,'Data');
 runtime=await createFullSchemaRuntime({onMigration:(_,n)=>{}});report.migrations=runtime.migrations;
 const task=randomUUID(),sibling=randomUUID(),project=randomUUID(),password=randomBytes(24).toString('base64url'),email='capture-native-'+nonce+'@example.invalid';
 const signup=await runtime.request('auth','/signup',{method:'POST',body:{email,password}});assert.equal(signup.status,200);
 const account=signup.value.user.id,authorization=signup.value.access_token;
 const api=(path,options={})=>runtime.request('rest',path,{authorization,...options});
 assert.equal((await api('/projects',{method:'POST',body:{id:project,user_id:account,name:'Native capture workshop'}})).status,201);
 assert.equal((await api('/tasks',{method:'POST',body:{id:task,user_id:account,project_id:project,title:'Existing workshop task'}})).status,201);
 const root=join(home,'Library/Application Support/TaskfoldFullSchemaNative-workflowteststeameditbridge');await mkdir(root,{recursive:true,mode:0o700});
 await writeFile(join(root,'config.json'),JSON.stringify({version:1,nonce,account,task,sibling,origin:new URL(runtime.urls.rest).origin,key:runtime.anon,email,password,queuedFingerprint:null}),{mode:0o600});
 const flags=['--team-editor-testing','--full-schema-native-testing','--full-schema-phase=capture'];
 if(platform==='ios')pid=Number((await cmd('xcrun','simctl','launch',device,bundle,...flags)).match(/: (\d+)$/)?.[1]);
 else {await cmd('open','-n',copy,'--args',...flags);for(let i=0;i<50;i++){const rows=(await cmd('ps','-axo','pid=,comm=')).split('\n').filter(x=>x.trim().endsWith(copy+'/Contents/MacOS/Taskfold'));if(rows.length===1){pid=Number(rows[0].trim().split(/\s/)[0]);break;}await delay(100);}}
 assert(pid,'Isolated capture app did not launch');
 let proof;const deadline=Date.now()+120000;
 while(Date.now()<deadline){try{const value=JSON.parse(await readFile(join(root,'capture.json'),'utf8'));if(value.nonce===nonce&&value.phase==='capture'){proof=value;break;}}catch(e){if(e.code!=='ENOENT'&&!(e instanceof SyntaxError))throw e;}await delay(150);}
 assert(proof,'Actual Store capture proof exceeded deadline');report.native=proof;check('actual Store capture phase succeeds',proof.accepted===true);check('native personal-template creation and Undo succeed',proof.personalTemplateUndo===true);
 check('actual Store preserves Redo and a second Undo',proof.redoPreserved&&proof.createdAndUndoneTwice);
 const tasks=await api('/tasks?select=id,title');check('server retains only original work',tasks.value.length===1&&tasks.value[0].id===task&&tasks.value[0].title==='Existing workshop task');
 const order=await api('/view_orders?id=eq.'+encodeURIComponent(proof.orderKey));check('server order is restored after second Undo',JSON.stringify(order.value[0].ids)===JSON.stringify([task]));
 const receipts=await runtime.raw("select count(*) from taskfold_private.private_workflow_undos where account_id='"+account+"'");check('three distinct successful Undo receipts',receipts==='3');
 report.actualStoreBackend=true;report.genuineLocalAuthREST=true;report.passed=Object.keys(report.checks).length;
}catch(e){report.error=e.message;process.exitCode=1;}finally{
 try{await stop();report.testAppClosed=true;}catch(e){report.stopError=e.message;process.exitCode=1;}
 if(runtime)report.runtimeRemoved=await runtime.close();
 if(report.testAppClosed){await rm(dirname(copy),{recursive:true,force:true});report.temporaryHostRemoved=true;}
 if(platform==='ios'&&initialState==='Shutdown'){await cmd('xcrun','simctl','shutdown',device);report.initialSimulatorStateRestored=true;}
 await writeFile(output,JSON.stringify(report,null,2)+'\n');
}
console.log(JSON.stringify({platform,passed:report.passed,error:report.error,testAppClosed:report.testAppClosed,runtimeRemoved:report.runtimeRemoved}));
