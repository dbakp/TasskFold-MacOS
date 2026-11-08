// Reserved synthetic native channel. Real schema/session, no hosted service.
import assert from 'node:assert/strict';
import {mkdir,readdir,lstat,writeFile,unlink} from 'node:fs/promises';
import {resolve,basename} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {literal as lit} from './postgres-fixture.mjs';
import {identity,atomicFile,createMappingSQLChannel,relocatedSimulatorChannel} from './child-mapping-native-channel.mjs';
const smoke=process.argv.includes('--smoke'),at=process.argv.indexOf('--directory'),out=process.argv.indexOf('--report');
const directory0=at>=0?resolve(process.argv[at+1]):null;
assert(smoke||directory0&&basename(directory0)==='Child mapping SQL native peer');
let directory=directory0,runtime,stopping=false;
process.once('SIGTERM',()=>stopping=true);process.once('SIGINT',()=>stopping=true);
const report={passed:false,scope:'Native bound adoption with genuine complete-schema PostgreSQL role/session; HTTP Auth and wider platforms separate',checks:[],hostedChanges:false,normalAppChanged:false};
const json=x=>lit(JSON.stringify(x))+'::jsonb';
try{
 if(directory){await mkdir(directory,{recursive:true,mode:0o700});const s=await lstat(directory);assert(s.isDirectory()&&!s.isSymbolicLink());assert.equal((await readdir(directory)).length,0);}
 runtime=await createFullSchemaRuntime();const session=randomUUID(),nonce=randomUUID();report.migrations=runtime.migrations;
 await runtime.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(identity.account)},'native-keep@example.invalid',now());insert into auth.sessions(id,user_id) values(${lit(session)},${lit(identity.account)});update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,copy_reconciliation_enabled=true,mapping_reconciliation_enabled=true,archive_restore_enabled=true,archive_restore_reversals_enabled=true,archive_restore_adoption_enabled=true`);
 const tree=[{id:'concept',title:'Prepare the review',completed:false,subtasks:[{id:'nested',title:'Collect supporting notes',completed:false}]},{id:'review',title:'Publish the summary',completed:false}];
 await runtime.raw(`insert into public.tasks(id,user_id,task_generation,title,description,priority,is_heading,subtasks) values(${lit(identity.root)},${lit(identity.account)},${lit(identity.generation)},'Keep older workshop','Preserve current notes',2,true,${json(tree)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(identity.root)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(identity.root)}`);
 await runtime.raw(`alter table public.tasks disable trigger user;update public.tasks set subtasks=jsonb_set(subtasks,'{0,subtasks}','["Original instruction"]') where id=${lit(identity.root)};alter table public.tasks enable trigger user`);
 let channel=createMappingSQLChannel(runtime,{session,nonce});
 const call=async(path,body)=>{const reply=await channel.dispatch({protocol:1,nonce,id:randomUUID(),path:'/rest/v1/rpc/'+path,body:Buffer.from(JSON.stringify(body)).toString('base64')});assert.equal(reply.code,null,path+': '+reply.code);return JSON.parse(Buffer.from(reply.data,'base64'));};
 const id=read=>Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,read[k]]));
 let read=await call('taskfold_review_child_adoption',{_id:identity.root,_generation:identity.generation}),base=id(read),copies=await call('taskfold_review_child_copies',{_body:base});
 const rows=JSON.parse(await runtime.raw('select jsonb_agg(to_jsonb(r) order by node_key)::text from taskfold_private.child_task_records r'));
 const mapping={version:1,nodes:rows.map(r=>({source_key:r.node_key==='nested'?'recovered-original':r.node_key,history_key:r.node_key,incarnation:r.incarnation,lifecycle:'recorded'})),retire:[]};
 const changes=[{kind:'choose_copy',path:[],source:'task',copy_digest:copies.copy_digest,mapping,format_changes:[{kind:'wrap_item',path:[0,0],reference:'recovered-original',title:'Original instruction'}]}];
 const p=await call('taskfold_preview_child_repair',{_body:{...base,changes}});assert(p.mutation_available);
 const first=await call('taskfold_repair_children',{_operation:'send',_body:{...base,changes,request_id:randomUUID(),repair_digest:p.repair_digest}});assert.equal(first.state,'applied');
 const review=await call('taskfold_review_child_restore',{_mode:'restore',_repair:first.request_id,_archive:first.archive_id,_restore:null});assert(review.enabled);
 const restored=await call('taskfold_restore_child_original',{_operation:'send',_body:{...Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest'].map(k=>[k,review[k]])),request_id:randomUUID()}});assert.equal(restored.phase,'restored');
 read=await call('taskfold_review_child_adoption',{_id:identity.root,_generation:identity.generation});base=id(read);
 const held=await call('taskfold_review_restored_child_copies',{_body:base,_actor:identity.account,_restore:restored.restoration_id});
 const state=()=>runtime.raw(`select jsonb_build_object('root',(select to_jsonb(t) from public.tasks t where id=${lit(identity.root)}),'repairs',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_task_repairs r),'originals',(select jsonb_agg(jsonb_build_object('row',to_jsonb(o)-'original','original_text',o.original::text) order by id) from taskfold_private.child_task_repair_originals o),'history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h),'restorations',(select jsonb_agg(to_jsonb(s) order by restore_id) from taskfold_private.child_repair_restorations s),'payloads',(select count(*) from taskfold_private.child_repair_restore_payloads),'scopes',(select count(*) from taskfold_private.child_mapping_scope))::text`);
 const baselineText=await state(),baseline=JSON.parse(baselineText),trace=[];report.baselineSHA256=createHash('sha256').update(baselineText).digest('hex');
 const publish=async()=>{if(!directory)return;const s=JSON.parse(await state());await atomicFile(directory+'/database-state.json',JSON.stringify(s));await atomicFile(directory+'/server.json',JSON.stringify({root:s.root,restoration:held.restoration,receipts:{},versions:{},writes:s.repairs.length-baseline.repairs.length,requests:trace.length,lost:trace.some(x=>x.reply.lose)}));await atomicFile(directory+'/trace.json',JSON.stringify(trace));};
 channel=createMappingSQLChannel(runtime,{session,nonce,loseFirstSave:true,beforeReply:async(request,reply)=>{trace.push({request,reply});await publish();}});
 if(smoke){assert.equal(await state(),baselineText);report.checks.push('active restoration, matching bound comparison and newer inverse prepared without another write');}
 else{
  await atomicFile(directory+'/baseline.json',baselineText);await publish();await atomicFile(directory+'/channel.json',JSON.stringify({protocol:1,nonce,...identity}));console.log(JSON.stringify({ready:true,directory}));const until=Date.now()+15*60*1000;
  while(!stopping&&Date.now()<until){try{if((await readdir(directory)).includes('stop'))break;await channel.drain(directory);}catch(e){if(e.code!=='ENOENT')throw e;directory=await relocatedSimulatorChannel(directory,nonce);}await delay(100);}
  assert((await readdir(directory)).includes('native-adoption-result.txt'),'Native flow did not confirm acceptance');
  const final=JSON.parse(await state());assert.equal(final.repairs.length,baseline.repairs.length+1);assert.equal(final.originals.length,baseline.originals.length+1);assert.equal(final.scopes,0);assert.equal(final.payloads,0);assert.equal(final.restorations[0].phase,'adopted');assert.equal(final.restorations[0].revision,2);
  assert.equal(final.root.description,baseline.root.description);assert.equal(final.root.priority,baseline.root.priority);assert.equal(final.root.subtasks[0].subtasks[0].legacy_original,'Original instruction');
  for(const h of baseline.history)assert.deepEqual(final.history.find(n=>n.id===h.id),h);
  const newer=final.originals.find(o=>JSON.parse(o.original_text).retained_restoration);assert(newer);assert.equal(JSON.parse(newer.original_text).retained_restoration.binding.digest,held.restoration.digest);
  const sends=trace.filter(x=>x.request.path.endsWith('/taskfold_repair_children')&&JSON.parse(Buffer.from(x.request.body,'base64'))._operation==='send');assert.equal(sends.length,1);assert(sends[0].reply.lose);assert(trace.some(x=>x.request.path.endsWith('/taskfold_repair_children')&&JSON.parse(Buffer.from(x.request.body,'base64'))._operation==='check'));
  report.checks.push('native format/history/cold review and consent produce one bound save','lost reply recovers through cold exact status','adopted state, transferred inverse, original root notes/priority and earlier history preserved');report.final={repairs:final.repairs.length,originals:final.originals.length,restoration:final.restorations[0].phase};report.trace=trace;
 }
 report.advisors=await runtime.advisors();report.passed=true;
}catch(e){report.failure={message:e.message,stack:e.stack?.split('\n').slice(0,5)};process.exitCode=1;}
finally{if(directory)await unlink(directory+'/channel.json').catch(()=>{});if(runtime){await runtime.close();report.fixtureRemoved=true;}if(out>=0)await writeFile(resolve(process.argv[out+1]),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed,failure:report.failure,fixtureRemoved:report.fixtureRemoved}));}
