// Reserved synthetic PostgreSQL/channel. Never reads hosted credentials or real work.
import assert from 'node:assert/strict';
import {readFile,mkdir,readdir,unlink,rm,mkdtemp,lstat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,basename} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
import {identity,atomicFile,boundedFile,createMappingSQLChannel,relocatedSimulatorChannel} from './child-mapping-native-channel.mjs';
const migrations=["20261030093035_child_record_reviewed_team_transfers.sql", "20261030102036_child_record_project_adoption_custody.sql", "20261030104147_personal_child_record_task_moves.sql", "20261030114138_cross_root_child_task_transfers.sql", "20261030134132_reviewed_child_record_adoption.sql", "20261030170753_child_adoption_metadata_discovery.sql", "20261030183133_child_task_repair_previews.sql", "20261030184402_child_task_repair_commits.sql", "20261030192638_child_repair_original_history_access.sql", "20261030204000_child_repair_bounded_originals.sql", "20261107051702_child_repair_archive_discovery.sql", "20261107070845_child_repair_original_cleanup.sql"];
const smoke=process.argv.includes('--smoke'),position=process.argv.indexOf('--directory'),cleanupMode=process.argv.includes('--allow-cleanup');
if(smoke&&cleanupMode)throw Error('Use the separate native cleanup journey');
if(!smoke&&(position<0||!process.argv[position+1]))throw Error('Use --smoke or --directory PATH');
let directory=smoke?await mkdtemp(tmpdir()+'/taskfold-archive-channel-'):resolve(process.argv[position+1]);
if(!smoke&&basename(directory)!=='Child archives SQL native peer')throw Error('Reserved archive subfolder required');
await mkdir(directory,{recursive:true,mode:0o700});const info=await lstat(directory);if(!info.isDirectory()||info.isSymbolicLink()||(await readdir(directory)).length)throw Error('Fresh owned channel required');
let pg,stopping=false;process.once('SIGTERM',()=>stopping=true);process.once('SIGINT',()=>stopping=true);
const report={passed:false,scope:'Owned local PostgreSQL/channel; not hosted or genuine Auth HTTP',checks:[]};
const json=v=>lit(JSON.stringify(v))+'::jsonb';
try{
 pg=await createPostgresFixture();await loadChildAuthorityDependencies(pg);
 for(const name of [childAuthorityMigration,...migrations])await pg.raw(await readFile(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
 const session=randomUUID(),nonce=randomUUID();
 await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(identity.account)},'native-archives@example.invalid',now());insert into auth.sessions(id,user_id) values(${lit(session)},${lit(identity.account)});insert into public.profiles(user_id) values(${lit(identity.account)});update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true`);
 const invoke=async expression=>{
  const text=await pg.raw(`begin;set local request.jwt.claim.sub=${lit(identity.account)};set local request.jwt.claims=${lit(JSON.stringify({sub:identity.account,session_id:session}))};set local role authenticated;select (${expression})::text;commit;`);return JSON.parse(text);
 };
 const saved=[];
 for(let i=0;i<3;i++){
  const id=i===0?identity.root:randomUUID(),generation=i===0?identity.generation:randomUUID();
  await pg.raw(`insert into public.tasks(id,user_id,task_generation,title,subtasks) values(${lit(id)},${lit(identity.account)},${lit(generation)},${lit('Archive workshop '+(i+1))},${json(['Keep original instructions '+(i+1)])})`);
  const review=await invoke(`public.taskfold_review_child_adoption(${lit(id)},${lit(generation)})`),body=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,review[k]]));
  body.changes=[{kind:'wrap_item',path:[0],reference:randomUUID(),title:'Recovered instructions '+(i+1)}];
  const preview=await invoke(`public.taskfold_preview_child_repair(${json(body)})`),command={...body,request_id:randomUUID(),repair_digest:preview.repair_digest};
  const receipt=await invoke(`public.taskfold_repair_children('send',${json(command)})`);assert.equal(receipt.state,'applied');saved.push(receipt);
 }
 await pg.raw('update taskfold_private.child_task_record_config set adoption_enabled=false,repair_reviews_enabled=false,repair_writes_enabled=false,reads_enabled=false,edits_enabled=false,completions_enabled=false,structure_reads_enabled=false,structure_edits_enabled=false');
 if(cleanupMode)await pg.raw('update taskfold_private.child_task_record_config set archive_cleanup_enabled=true');
 const state=()=>pg.scalar(`select jsonb_build_object('roots',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'records',(select jsonb_agg(to_jsonb(r) order by task_id,node_key) from taskfold_private.child_task_records r),'projections',(select jsonb_agg(to_jsonb(p) order by task_id) from taskfold_private.child_task_projections p),'history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h),'root_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_activity h),'repairs',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_task_repairs r),'originals',(select jsonb_agg(jsonb_build_object('metadata',to_jsonb(o)-'original','original_text',o.original::text) order by request_id) from taskfold_private.child_task_repair_originals o),'authority',(select jsonb_agg(to_jsonb(a) order by task_id) from taskfold_private.child_task_record_authority a))`);
 const baseline=await state(),trace=[];await atomicFile(directory+'/baseline.json',JSON.stringify(baseline));
 const entries=(await invoke('public.taskfold_child_repair_archives(null,50)')).entries;
 assert.equal(entries.length,3);await atomicFile(directory+'/expected.json',JSON.stringify({entries,account:identity.account,root:identity.root}));
 const publish=async()=>{
  const current=await state();await atomicFile(directory+'/database-state.json',JSON.stringify(current));await atomicFile(directory+'/trace.json',JSON.stringify(trace));
  await atomicFile(directory+'/server.json',JSON.stringify({root:current.roots.find(r=>r.id===identity.root),receipts:{},versions:{},writes:0,requests:0,lost:false}));
 };
 let lostCleanup=false;
 const channel=createMappingSQLChannel(pg,{session,nonce,beforeReply:async(request,reply)=>{
  const body=JSON.parse(Buffer.from(request.body,'base64'));
  if(cleanupMode&&request.path==='/rest/v1/rpc/taskfold_child_repair_original_cleanup'&&body._operation==='remove'&&!reply.code&&!lostCleanup){reply.lose=true;lostCleanup=true;}
  trace.push({request,reply});await publish();
 }});
 await publish();await atomicFile(directory+'/channel.json',JSON.stringify({protocol:1,nonce,...identity}));
 if(smoke){
  const call=async(path,body)=>{const response=await channel.dispatch({protocol:1,nonce,id:randomUUID(),path:'/rest/v1/rpc/'+path,body:Buffer.from(JSON.stringify(body)).toString('base64')});assert.equal(response.code,null);return {raw:Buffer.from(response.data,'base64'),value:JSON.parse(Buffer.from(response.data,'base64'))};};
  const first=await call('taskfold_child_repair_archives',{_after:null,_limit:2});assert.equal(first.value.entries.length,2);assert.equal(first.value.next,first.value.entries[1].receipt.request_id);report.checks.push('real first page has two archives');
  const second=await call('taskfold_child_repair_archives',{_after:first.value.next,_limit:2});assert.equal(second.value.entries.length,1);assert.equal(second.value.next,null);report.checks.push('real final page has remaining archive');
  for(const e of entries){const original=await call('taskfold_child_repair_original',{_request:e.receipt.request_id,_archive:e.receipt.archive_id});const exact=baseline.originals.find(o=>o.metadata.id===e.receipt.archive_id).original_text;assert(original.raw.includes(Buffer.from(exact)));assert.equal(createHash('sha256').update(exact).digest('hex'),e.receipt.archive_digest);report.checks.push('exact original '+e.receipt.archive_id);}
  assert.deepEqual(await state(),baseline);report.checks.push('all stored work and originals unchanged');report.passed=true;
 }else{
  console.log(JSON.stringify({ready:true,directory,entries:entries.length}));const deadline=Date.now()+15*60*1000;
  while(!stopping&&Date.now()<deadline){try{if((await readdir(directory)).includes('stop'))break;await channel.drain(directory);}catch(e){if(e.code!=='ENOENT'||!process.argv.includes('--follow-simulator-container'))throw e;directory=await relocatedSimulatorChannel(directory,nonce);}await delay(100);}
  await publish();
  if(cleanupMode){
   const removes=trace.filter(x=>x.request.path==='/rest/v1/rpc/taskfold_child_repair_original_cleanup'&&JSON.parse(Buffer.from(x.request.body,'base64'))._operation==='remove');
   assert.equal(removes.length,2);assert.deepEqual(JSON.parse(Buffer.from(removes[0].request.body,'base64')),JSON.parse(Buffer.from(removes[1].request.body,'base64')));assert.equal(removes.filter(x=>x.reply.lose).length,1);
   const selected=JSON.parse(Buffer.from(removes[0].request.body,'base64'))._archive;
   assert(baseline.originals.some(o=>o.metadata.id===selected));
   assert.deepEqual(await state(),{...baseline,originals:baseline.originals.filter(o=>o.metadata.id!==selected)});
   report.checks.push('only reviewed original removed; exact lost-reply retry preserves all current work and receipts');report.removedArchive=selected;
  }else {assert.deepEqual(await state(),baseline);report.checks.push('native reads leave complete database unchanged');}
  report.passed=true;
 }
}catch(e){report.failure={message:e.message,code:e.code};process.exitCode=1;}finally{await unlink(directory+'/channel.json').catch(()=>{});if(pg)report.fixtureRemoved=await pg.close();if(smoke)await rm(directory,{recursive:true,force:true});console.log(JSON.stringify(report));}
