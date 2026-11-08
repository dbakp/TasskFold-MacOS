// Complete owned schema plus the reserved DEBUG PostgreSQL channel. This does
// not claim native HTTP authentication or touch hosted/user data.
import assert from 'node:assert/strict';
import {readFile,mkdir,readdir,unlink,rm,mkdtemp,lstat,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,basename} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {identity,atomicFile,createMappingSQLChannel,relocatedSimulatorChannel} from './child-mapping-native-channel.mjs';
const finishJourney=process.argv.includes('--finish'),liveAdoption=process.argv.includes('--live-adoption'),newerVersion=process.argv.includes('--newer-version');
assert(!newerVersion||(!liveAdoption&&!finishJourney));
const smoke=process.argv.includes('--smoke'),at=process.argv.indexOf('--directory'),reportAt=process.argv.indexOf('--report');
assert(smoke||at>=0);const reportPath=reportAt>=0?resolve(process.argv[reportAt+1]):null;
assert(!reportPath||/^\/tmp\/taskfold-[^/]+\.json$/.test(reportPath));
let directory=smoke?await mkdtemp(tmpdir()+'/taskfold-restore-channel-'):resolve(process.argv[at+1]);
assert(smoke||basename(directory)==='Child archives SQL native peer');await mkdir(directory,{recursive:true,mode:0o700});
const info=await lstat(directory);assert(info.isDirectory()&&!info.isSymbolicLink());assert.equal((await readdir(directory)).length,0,'Preserve existing fixture evidence first');
let runtime,stopping=false;process.once('SIGTERM',()=>stopping=true);process.once('SIGINT',()=>stopping=true);
const report={passed:false,scope:'Genuine local complete schema; reserved native SQL role/session channel, not native HTTP Auth',checks:[],hostedChanges:false,normalAppChanged:false};
const lit=x=>"'"+String(x).replaceAll("'","''")+"'",json=x=>lit(JSON.stringify(x))+'::jsonb';
try{
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;
 const session=randomUUID(),nonce=randomUUID();
 await runtime.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(identity.account)},'restore-native@example.invalid',now());insert into auth.sessions(id,user_id) values(${lit(session)},${lit(identity.account)});update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true;insert into public.tasks(id,user_id,task_generation,title,description,priority,subtasks) values(${lit(identity.root)},${lit(identity.account)},${lit(identity.generation)},'Restoration workshop','Keep current root notes',2,'["Keep original instructions"]')`);
 const invoke=async expression=>JSON.parse(await runtime.raw(`set local request.jwt.claim.sub=${lit(identity.account)};set local request.jwt.claims=${lit(JSON.stringify({sub:identity.account,session_id:session}))};set local role authenticated;select (${expression})::text`));
 const read=await invoke(`public.taskfold_review_child_adoption(${lit(identity.root)},${lit(identity.generation)})`);
 const body=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,read[k]]));body.changes=[{kind:'wrap_item',path:[0],reference:randomUUID(),title:'Recovered instructions'}];
 const preview=await invoke(`public.taskfold_preview_child_repair(${json(body)})`);
 const receipt=await invoke(`public.taskfold_repair_children('send',${json({...body,request_id:randomUUID(),repair_digest:preview.repair_digest})})`);assert.equal(receipt.state,'applied');
 await runtime.raw('update taskfold_private.child_task_record_config set adoption_enabled=false,repair_reviews_enabled=false,repair_writes_enabled=false,archive_restore_enabled=true,archive_restore_reversals_enabled=true,archive_restore_finish_enabled=true');
 const state=async()=>JSON.parse(await runtime.raw(`select jsonb_build_object('root',(select to_jsonb(t) from public.tasks t where id=${lit(identity.root)}),'records',(select jsonb_agg(to_jsonb(r) order by node_key) from taskfold_private.child_task_records r),'originals',(select jsonb_agg(jsonb_build_object('metadata',to_jsonb(o)-'original','original_text',o.original::text) order by id) from taskfold_private.child_task_repair_originals o),'root_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_activity h),'child_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h),'restorations',(select jsonb_agg(to_jsonb(s) order by restore_id) from taskfold_private.child_repair_restorations s),'requests',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_repair_restore_requests r),'projections',(select jsonb_agg(to_jsonb(p) order by task_id) from taskfold_private.child_task_projections p),'authority',(select jsonb_agg(to_jsonb(a) order by task_id) from taskfold_private.child_task_record_authority a),'payload_count',(select count(*) from taskfold_private.child_repair_restore_payloads),'scopes',(select count(*) from taskfold_private.child_repair_restore_scope))::text`));
 let baseline=await state();const trace=[];let sourceReceipt=receipt;let entries=(await invoke('public.taskfold_child_repair_archives(null,50)')).entries;assert.equal(entries.length,1);
 const publish=async()=>{const current=await state();await atomicFile(directory+'/database-state.json',JSON.stringify(current));await atomicFile(directory+'/trace.json',JSON.stringify(trace));await atomicFile(directory+'/server.json',JSON.stringify({root:current.root,receipts:{},versions:{},writes:(current.requests??[]).length,requests:trace.length,lost:trace.some(x=>x.reply.lose)}));};
 let lostFinish=false,beforeFinish=null;
 const channel=createMappingSQLChannel(runtime,{session,nonce,loseFirstSave:true,beforeReply:async(request,reply)=>{
  const body=JSON.parse(Buffer.from(request.body,'base64'));
  if(finishJourney&&request.path.endsWith('/taskfold_restore_child_original')&&body._operation==='send'&&!reply.code){
   if(body._body.mode==='undo'&&(await state()).restorations[0].revision===4)beforeFinish=await state();
   if(body._body.mode==='finish'&&!lostFinish){reply.lose=true;lostFinish=true;}
  }
  trace.push({request,reply});await publish();
 }});
 async function adoptExternally(){
  await runtime.raw('update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,copy_reconciliation_enabled=true,mapping_reconciliation_enabled=true,archive_restore_adoption_enabled=true');
  const now=await state(),restoration=now.restorations[0];assert.equal(restoration.phase,'restored');
  const read=await invoke(`public.taskfold_review_child_adoption(${lit(identity.root)},${lit(identity.generation)})`),base=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,read[k]]));
  const held=await invoke(`public.taskfold_review_restored_child_copies(${json(base)},${lit(identity.account)},${lit(restoration.restore_id)})`);
  const records=now.records;assert.equal(records.length,1);
  const changes=[{kind:'choose_copy',path:[],source:'task',copy_digest:held.copies.copy_digest,restoration:held.restoration,format_changes:[{kind:'wrap_item',path:[0],reference:'live-recovered',title:'Keep original instructions'}],mapping:{version:1,nodes:[{source_key:'live-recovered',history_key:records[0].node_key,incarnation:records[0].incarnation,lifecycle:'recorded'}],retire:[]}}];
  const preview=await invoke(`public.taskfold_preview_child_repair(${json({...base,changes})})`);assert(preview.mutation_available);
  const saved=await invoke(`public.taskfold_repair_children('send',${json({...base,changes,request_id:randomUUID(),repair_digest:preview.repair_digest})})`);assert.equal(saved.state,'applied');
  await runtime.raw('update taskfold_private.child_task_record_config set adoption_enabled=false,repair_reviews_enabled=false,repair_writes_enabled=false,archive_restore_adoption_enabled=false');
  report.externalAdoption=saved;await publish();
 }
 if(newerVersion){
  const review=await invoke(`public.taskfold_review_child_restore('restore',${lit(receipt.request_id)},${lit(receipt.archive_id)},null)`);
  const bootstrap={...Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest'].map(k=>[k,review[k]])),request_id:randomUUID()};
  assert.equal((await invoke(`public.taskfold_restore_child_original('send',${json(bootstrap)})`)).state,'applied');
  await adoptExternally();sourceReceipt=report.externalAdoption;
  baseline=await state();entries=(await invoke('public.taskfold_child_repair_archives(null,50)')).entries.filter(e=>e.receipt.archive_id===sourceReceipt.archive_id);assert.equal(entries.length,1);
 }
 await atomicFile(directory+'/baseline.json',JSON.stringify(baseline));await atomicFile(directory+'/expected.json',JSON.stringify({entries,...identity}));await publish();await atomicFile(directory+'/channel.json',JSON.stringify({protocol:1,nonce,...identity}));
 if(smoke){
  const call=async(path,body)=>{const request={protocol:1,nonce,id:randomUUID(),path:'/rest/v1/rpc/'+path,body:Buffer.from(JSON.stringify(body)).toString('base64')};const reply=await channel.dispatch(request);trace.push({request,reply});await publish();await atomicFile(directory+'/last-smoke-reply.json',JSON.stringify(reply));assert.equal(reply.code,null);return {reply,value:JSON.parse(Buffer.from(reply.data,'base64'))};};
  let restoration=null;
  for(const mode of liveAdoption?['restore']:newerVersion?['restore_newer','undo','redo','undo']:finishJourney?['restore','undo','redo','undo','finish']:['restore','undo','redo','undo']){
   const p=(await call('taskfold_review_child_restore',{_mode:mode,_repair:sourceReceipt.request_id,_archive:sourceReceipt.archive_id,_restore:restoration})).value;assert(p.enabled);
   const command={...Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest'].map(k=>[k,p[k]])),request_id:randomUUID()};
   const applied=await call('taskfold_restore_child_original',{_operation:'send',_body:command});assert.equal(applied.value.state,'applied');if(['restore','restore_newer'].includes(mode))assert(applied.reply.lose);restoration=applied.value.restoration_id;
   const checked=await call('taskfold_restore_child_original',{_operation:'check',_body:command});assert.equal(checked.value.restoration_id,restoration);assert(checked.value.replayed);report.checks.push(mode+' genuine decision and exact status');
  }
  if(liveAdoption){
   const identityBody=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest'].map(k=>[k,k==='repair_request_id'?receipt.request_id:k==='archive_id'?receipt.archive_id:k==='archive_digest'?receipt.archive_digest:k==='workspace_id'?null:body[k]]));
   const request={_body:identityBody,_actor:identity.account,_restore:restoration};
   const active=await call('taskfold_child_restore_status',request);assert.equal(active.value.phase,'restored');
   await adoptExternally();
   for(let i=0;i<2;i++){const adopted=await call('taskfold_child_restore_status',request);assert.equal(adopted.value.phase,'adopted');}
  }
 }else{
  console.log(JSON.stringify({ready:true,directory}));const deadline=Date.now()+15*60*1000;
  while(!stopping&&Date.now()<deadline){try{const names=await readdir(directory);if(names.includes('stop'))break;if(liveAdoption&&names.includes('adopt-current')&&!report.externalAdoption)await adoptExternally();await channel.drain(directory);}catch(e){if(e.code!=='ENOENT'||!process.argv.includes('--follow-simulator-container'))throw e;directory=await relocatedSimulatorChannel(directory,nonce);}await delay(100);}
  assert((await readdir(directory)).includes('stop'),'Native journey did not request final verification');
  const writes=trace.filter(x=>x.request.path.endsWith('/taskfold_restore_child_original')&&JSON.parse(Buffer.from(x.request.body,'base64'))._operation==='send');
  assert.deepEqual(writes.map(x=>JSON.parse(Buffer.from(x.request.body,'base64'))._body.mode),liveAdoption?['restore']:newerVersion?['restore_newer','undo','redo','undo']:finishJourney?['restore','undo','redo','undo','finish']:['restore','undo','redo','undo']);
  assert.equal(writes.filter(x=>x.reply.lose).length,finishJourney?2:1);assert(trace.some(x=>x.request.path.endsWith('/taskfold_restore_child_original')&&JSON.parse(Buffer.from(x.request.body,'base64'))._operation==='check'));
  report.checks.push(liveAdoption?'one lost Restore confirmed before a separate external adoption':finishJourney?'five reviewed native writes; lost restore and finish replies recover through exact status':'four reviewed native writes; lost initial reply resolved through actual status');
 }
 if(liveAdoption){
  const final=await state();assert(report.externalAdoption);assert.equal(final.restorations[0].phase,'adopted');assert.equal(final.restorations[0].revision,2);assert.equal(final.payload_count,0);assert.equal(final.requests.length,1);assert.equal(final.requests[0].reply.phase,'restored');assert.equal(final.originals.length,baseline.originals.length+1);assert.equal(final.root.description,baseline.root.description);assert.equal(final.root.priority,baseline.root.priority);assert.equal(final.scopes,0);
  const reads=trace.filter(x=>x.request.path.endsWith('/taskfold_child_restore_status')&&!x.reply.code).map(x=>JSON.parse(Buffer.from(x.reply.data,'base64')));assert(reads.some(x=>x.phase==='restored'));assert(reads.filter(x=>x.phase==='adopted').length>=2);
  if(!smoke)assert((await readdir(directory)).includes('native-live-status-result.txt'));
  report.checks.push(smoke?'direct current-status smoke observes external adoption without changing the old event':'live card refresh and cold return show external adoption while the original event remains restored',smoke?'adopted state has no reversible payload':'ended cycle offers no Undo, Redo, Finish or keep-older action','one external adoption retains newer original and current root notes/priority');report.final={phase:'adopted',revision:2,immutableEvent:'restored',liveReads:reads.length};
 }else if(newerVersion){
  const final=await state(),cycle=final.restorations.find(r=>!baseline.restorations.some(b=>b.restore_id===r.restore_id));
  assert(cycle);assert.equal(cycle.phase,'undone');assert.equal(cycle.revision,4);assert.equal(final.restorations.length,baseline.restorations.length+1);assert.equal(final.requests.length,baseline.requests.length+4);assert.equal(final.scopes,0);
  const rootContent=({updated_at,...r})=>r;assert.deepEqual(rootContent(final.root),rootContent(baseline.root));assert.deepEqual(final.originals,baseline.originals);
  const authored=rows=>rows.map(({incarnation,revision,...r})=>r);assert.deepEqual(authored(final.records),authored(baseline.records));
  for(const key of ['root_history','child_history'])for(const prior of baseline[key]??[])assert.deepEqual(final[key].find(x=>x.id===prior.id),prior);
  const choices=trace.filter(x=>x.request.path.endsWith('/taskfold_review_child_restore')).map(x=>JSON.parse(Buffer.from(x.request.body,'base64'))._mode);
  assert(choices.includes('restore')&&choices.includes('restore_newer'));
  report.checks.push('named newer version selected through fresh review; consent reset; lost reply checked; cold Undo Redo return to preceding editable work; originals and prior history preserved');report.final={phase:cycle.phase,revision:cycle.revision,source:'restore_newer',requests:4};
 }else{
 const final=await state();const rootContent=({updated_at,...root})=>root;assert.deepEqual(rootContent(final.root),rootContent(baseline.root));assert.deepEqual(final.root.subtasks,baseline.root.subtasks);assert.equal(final.root.description,baseline.root.description);assert.equal(final.root.priority,baseline.root.priority);assert.deepEqual(final.originals,baseline.originals);
 const authored=rows=>rows.map(({incarnation,revision,...row})=>row);assert.deepEqual(authored(final.records),authored(baseline.records));assert.equal(final.restorations.length,1);assert.equal(final.restorations[0].revision,finishJourney?5:4);assert.equal(final.restorations[0].phase,finishJourney?'finished':'undone');assert.equal(final.requests.length,finishJourney?5:4);assert.equal(final.scopes,0);
 if(finishJourney){
  assert.equal(final.payload_count,0);
  if(!smoke){assert(beforeFinish);for(const key of ['root','records','projections','authority','originals','root_history','child_history'])assert.deepEqual(final[key],beforeFinish[key]);}
  report.checks.push('finish removes only inverse retention; current editable work/projection/authority/history/originals stay exact');
 }
 for(const key of ['root_history','child_history'])for(const prior of baseline[key]??[])assert.deepEqual(final[key].find(x=>x.id===prior.id),prior);
 await publish();report.checks.push('exact editable source and authored records returned; notes/priority/originals/history preserved; decision receipts and no leaked scope');report.final={revision:finishJourney?5:4,phase:finishJourney?'finished':'undone',requests:finishJourney?5:4};report.baselineSHA256=createHash('sha256').update(JSON.stringify(baseline)).digest('hex');}
 report.advisors=await runtime.advisors();report.trace=trace;report.nativeUIObserved=!smoke;report.passed=true;
}catch(e){report.failure={message:e.message,code:e.code,stack:e.stack?.split('\n').slice(0,4)};process.exitCode=1;}finally{await unlink(directory+'/channel.json').catch(()=>{});if(runtime)report.fixtureRemoved=await runtime.close();if(smoke)await rm(directory,{recursive:true,force:true});if(reportPath)await writeFile(reportPath,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed,checks:report.checks,failure:report.failure,fixtureRemoved:report.fixtureRemoved}));}
