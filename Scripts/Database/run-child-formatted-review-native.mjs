// Synthetic native review fixture; no hosted data or normal app is involved.
import assert from 'node:assert/strict';
import {mkdir,readdir,readFile,writeFile,lstat} from 'node:fs/promises';
import {resolve,basename} from 'node:path';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {literal as lit} from './postgres-fixture.mjs';
import {identity,atomicFile,createMappingSQLChannel,relocatedSimulatorChannel} from './child-mapping-native-channel.mjs';
const smoke=process.argv.includes('--smoke'),pos=process.argv.indexOf('--directory'),output=process.argv.indexOf('--report'),contract=process.argv.indexOf('--contract');
let directory=pos>=0?resolve(process.argv[pos+1]):null;
if(!smoke&&(!directory||basename(directory)!=='Child mapping SQL native peer'))throw Error('Use the reserved native peer directory');
if(directory){await mkdir(directory,{recursive:true,mode:0o700});assert((await lstat(directory)).isDirectory());assert(!(await lstat(directory)).isSymbolicLink());assert.equal((await readdir(directory)).length,0);}
let runtime,stopping=false;process.once('SIGTERM',()=>stopping=true);process.once('SIGINT',()=>stopping=true);
const report={passed:false,scope:'Synthetic real PostgreSQL actor/session native channel; native HTTP authentication is separate',checks:[]};
const json=x=>lit(JSON.stringify(x))+'::jsonb';
try{
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;
 const pg={raw:runtime.raw,scalar:async sql=>JSON.parse(await runtime.raw(sql))};
 const session=randomUUID(),nonce=randomUUID();
 await runtime.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(identity.account)},'native-format@example.invalid',now());insert into auth.sessions(id,user_id) values(${lit(session)},${lit(identity.account)});update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,copy_reconciliation_enabled=true,mapping_reconciliation_enabled=true`);
 const tree=[{id:'concept',title:'Prepare the review',completed:false,subtasks:[{id:'nested',title:'Collect supporting notes',completed:false}]},{id:'review',title:'Publish the summary',completed:false}];
 await runtime.raw(`insert into public.tasks(id,user_id,task_generation,title,is_heading,subtasks) values(${lit(identity.root)},${lit(identity.account)},${lit(identity.generation)},'Native history mapping workshop',true,${json(tree)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(identity.root)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(identity.root)}`);
 // Commit the valid authority first; deferred source guards must not see
 // synthetic legacy corruption queued in the same transaction.
 await runtime.raw(`alter table public.tasks disable trigger user;update public.tasks set subtasks=jsonb_set(subtasks,'{0,subtasks}','["Original instruction"]') where id=${lit(identity.root)};alter table public.tasks enable trigger user`);
 const stateSQL=`select jsonb_build_object('root',(select to_jsonb(t) from public.tasks t where id=${lit(identity.root)}),'records',(select jsonb_agg(to_jsonb(r) order by node_key) from taskfold_private.child_task_records r),'projection',(select jsonb_agg(to_jsonb(p)) from taskfold_private.child_task_projections p),'authority',(select jsonb_agg(to_jsonb(a)) from taskfold_private.child_task_record_authority a),'repairs',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from taskfold_private.child_task_repairs r),'originals',(select coalesce(jsonb_agg(jsonb_build_object('row',to_jsonb(o)-'original','original_text',o.original::text)),'[]') from taskfold_private.child_task_repair_originals o),'history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h),'scopes',(select count(*) from taskfold_private.child_mapping_scope))::text`;
 const baseline=await runtime.raw(stateSQL);report.baselineSHA256=(await import('node:crypto')).createHash('sha256').update(baseline).digest('hex');
 let trace=[];
 const publish=async()=>{if(!directory)return;const s=JSON.parse(await runtime.raw(stateSQL));await atomicFile(directory+'/database-state.json',JSON.stringify(s));await atomicFile(directory+'/trace.json',JSON.stringify(trace));await atomicFile(directory+'/server.json',JSON.stringify({root:s.root,receipts:{},versions:{concept:1,review:1},writes:s.repairs.length,requests:trace.length,lost:trace.some(t=>t.reply.lose)}));};
 const channel=createMappingSQLChannel(pg,{session,nonce,loseFirstSave:true,beforeReply:async(request,reply)=>{trace.push({request,reply});await publish();}});
 const dispatch=async(path,body)=>{
  const reply=await channel.dispatch({protocol:1,nonce,id:randomUUID(),path:'/rest/v1/rpc/'+path,body:Buffer.from(JSON.stringify(body)).toString('base64')});assert.equal(reply.code,null,reply.message);return Buffer.from(reply.data,'base64').toString();
 };
 const reviewText=await dispatch('taskfold_review_child_adoption',{_id:identity.root,_generation:identity.generation}),review=JSON.parse(reviewText);
 const base=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,review[k]]));
 const copies=await dispatch('taskfold_review_child_copies',{_body:base});
 const changes=[{kind:'wrap_item',path:[0,0],reference:'recovered-original',title:'Original instruction'}];
 const prepared=await dispatch('taskfold_preview_child_repair',{_body:{...base,changes}});
 assert.equal(JSON.parse(prepared).proposal_valid,true);assert.equal(JSON.parse(prepared).mutation_available,false);assert.equal(await runtime.raw(stateSQL),baseline);
 if(contract>=0)await writeFile(process.argv[contract+1],'{"root":'+JSON.stringify(JSON.parse(baseline).root)+',"review":'+reviewText+',"copies":'+copies+',"preparation":'+prepared+'}\n');
 report.checks.push('real prepared format/copy contract is read-only');trace=[];
 if(smoke){report.passed=true;}else{
  await atomicFile(directory+'/baseline.json',baseline);await publish();await atomicFile(directory+'/channel.json',JSON.stringify({protocol:1,nonce,...identity}));
  console.log(JSON.stringify({ready:true,directory}));const until=Date.now()+15*60*1000;
  while(!stopping&&Date.now()<until){try{if((await readdir(directory)).includes('stop'))break;await channel.drain(directory);}catch(e){if(e.code!=='ENOENT')throw e;directory=await relocatedSimulatorChannel(directory,nonce);}await delay(100);}
  const final=JSON.parse(await runtime.raw(stateSQL));report.final={repairs:final.repairs.length,originals:final.originals.length,scopeCount:final.scopes};
  assert.equal(final.repairs.length,1);assert.equal(final.originals.length,1);assert.equal(final.scopes,0);
  assert.equal(final.root.subtasks[0].subtasks[0].legacy_original,'Original instruction');
  const choice=final.originals[0].original_text;assert(JSON.parse(choice).copy_choice.format_changes.length===1);
  const prior=JSON.parse(baseline);assert.equal(JSON.stringify(JSON.parse(choice).root),JSON.stringify(prior.root));
  assert(prior.history.every(h=>final.history.some(n=>JSON.stringify(n)===JSON.stringify(h))));
  report.checks.push('one exact formatted mapping save, original and prior history retained');report.trace=trace;report.passed=true;
 }
 report.advisors=await runtime.advisors();
}catch(e){report.failure={message:e.message,stack:e.stack};process.exitCode=1;}finally{if(runtime){try{await runtime.close();report.fixtureRemoved=true;}catch(e){report.cleanupFailure=e.message;process.exitCode=1;}}if(output>=0)await writeFile(process.argv[output+1],JSON.stringify(report,null,2)+'\n');}
