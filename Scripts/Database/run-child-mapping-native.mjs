// Run --smoke for automatic channel/transaction acceptance; --directory PATH for native controls.
import assert from 'node:assert/strict';
import {readFile,mkdir,readdir,unlink,rm,mkdtemp,lstat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,basename} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
import {identity,atomicFile,boundedFile,createMappingSQLChannel,relocatedSimulatorChannel} from './child-mapping-native-channel.mjs';
const migrations=["20261030093035_child_record_reviewed_team_transfers.sql", "20261030102036_child_record_project_adoption_custody.sql", "20261030104147_personal_child_record_task_moves.sql", "20261030114138_cross_root_child_task_transfers.sql", "20261030134132_reviewed_child_record_adoption.sql", "20261030170753_child_adoption_metadata_discovery.sql", "20261030183133_child_task_repair_previews.sql", "20261030184402_child_task_repair_commits.sql", "20261030192638_child_repair_original_history_access.sql", "20261030204000_child_repair_bounded_originals.sql", "20261101062555_activity_operation_groups.sql", "20261101071304_reviewed_duplicate_history_preservation.sql"];
migrations.push("20261106173430_child_adoption_global_search.sql");
const smoke=process.argv.includes('--smoke'),position=process.argv.indexOf('--directory');
if(!smoke&&(position<0||!process.argv[position+1]))throw new Error('Use --smoke or --directory PATH');
let directory=smoke?await mkdtemp(tmpdir()+'/taskfold-mapping-channel-'):resolve(process.argv[position+1]);
if(!smoke&&basename(directory)!=='Child mapping SQL native peer')throw new Error('Use the reserved app-support subfolder');
await mkdir(directory,{recursive:true,mode:0o700});const info=await lstat(directory);
if(!info.isDirectory()||info.isSymbolicLink()||(await readdir(directory)).length)throw new Error('Channel directory must be empty and not a symlink');
const report={passed:false,scope:'owned local PostgreSQL and file channel; not native-control or hosted acceptance',checks:[]};
let pg,stopping=false;process.once('SIGTERM',()=>{stopping=true;});process.once('SIGINT',()=>{stopping=true;});
const json=v=>lit(JSON.stringify(v))+'::jsonb';
try {
 pg=await createPostgresFixture();await loadChildAuthorityDependencies(pg);
 for(const name of [childAuthorityMigration,...migrations,'20261101091417_reviewed_child_copy_comparison.sql','20261031204437_child_field_activity_details.sql','20261101041509_child_order_activity.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
 await pg.raw('alter policy fixture_automation_task_update on public.tasks rename to "Users can update accessible tasks"');
 for(const name of ['20261101101059_reviewed_saved_copy_reconciliation.sql','20261101123154_reviewed_child_history_reconciliation.sql','20261101124928_atomic_child_copy_mapping.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
 const session=randomUUID(),nonce=randomUUID();
 await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(identity.account)},'native-mapping@example.invalid',now());insert into auth.sessions(id,user_id) values(${lit(session)},${lit(identity.account)});insert into public.profiles(user_id) values(${lit(identity.account)});update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,copy_reconciliation_enabled=true,mapping_reconciliation_enabled=true`);
 const tree=[{id:'concept',title:'Prepare the review',description:'Original saved notes',completed:false,subtasks:[{id:'nested',title:'Collect supporting notes',completed:false}]},{id:'review',title:'Publish the summary',completed:false}];
 await pg.raw(`insert into public.tasks(id,user_id,task_generation,title,subtasks) values(${lit(identity.root)},${lit(identity.account)},${lit(identity.generation)},'Native history mapping workshop',${json(tree)});update public.tasks set is_heading=true where id=${lit(identity.root)};select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(identity.root)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(identity.root)}`);
 await pg.raw(`alter table taskfold_private.child_task_records disable trigger user;alter table taskfold_private.child_task_projections disable trigger user;update taskfold_private.child_task_records set fields=fields||'{"description":"Recorded task instructions"}' where task_id=${lit(identity.root)} and node_key='concept';update taskfold_private.child_task_projections set source_tree=jsonb_set(source_tree,'{0,description}','"Snapshot task instructions"') where task_id=${lit(identity.root)};alter table taskfold_private.child_task_records enable trigger user;alter table taskfold_private.child_task_projections enable trigger user`);
 const trace=[];
 const databaseState=()=>pg.scalar(`select jsonb_build_object(
 'root',(select to_jsonb(t) from public.tasks t where id=${lit(identity.root)}),
 'records',(select coalesce(jsonb_agg(to_jsonb(r) order by node_key),'[]') from taskfold_private.child_task_records r where task_id=${lit(identity.root)}),
 'root_history',(select coalesce(jsonb_agg(to_jsonb(h) order by sequence),'[]') from public.task_activity h where task_id=${lit(identity.root)}),
 'child_history',(select coalesce(jsonb_agg(to_jsonb(h) order by sequence),'[]') from public.task_node_activity h where task_id=${lit(identity.root)}),
 'repairs',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from taskfold_private.child_task_repairs r),
 'originals',(select coalesce(jsonb_agg(jsonb_build_object('row',to_jsonb(o)-'original','original_text',original::text)),'[]') from taskfold_private.child_task_repair_originals o),
 'mapping_scope_count',(select count(*) from taskfold_private.child_mapping_scope))`);
 await atomicFile(directory+'/baseline.json',JSON.stringify(await databaseState()));
 const publish=async()=>{
  const root=await pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(identity.root)}`),history=await pg.scalar(`select coalesce(jsonb_agg(to_jsonb(h) order by sequence),'[]') from public.task_node_activity h where task_id=${lit(identity.root)}`);
  await atomicFile(directory+'/database-state.json',JSON.stringify(await databaseState()));
  await atomicFile(directory+'/trace.json',JSON.stringify(trace));
  await atomicFile(directory+'/server.json',JSON.stringify({root,repairHistory:history,receipts:{},versions:{concept:1,review:1},writes:0,requests:0,lost:false}));
 };
 const channel=createMappingSQLChannel(pg,{session,nonce,loseFirstSave:smoke||process.argv.includes('--lose-first-save'),beforeReply:async(request,reply)=>{trace.push({request,reply});await publish();}});
 await publish();await atomicFile(directory+'/channel.json',JSON.stringify({protocol:1,nonce,...identity}));
 if(smoke){
  const call=async(path,body)=>{
   const id=randomUUID(),request={protocol:1,nonce,id,path:'/rest/v1/rpc/'+path,body:Buffer.from(JSON.stringify(body)).toString('base64')};
   await atomicFile(directory+'/'+id+'.request',JSON.stringify(request));await channel.drain(directory);
   const response=JSON.parse(await boundedFile(directory+'/'+id+'.reply',14000000));await unlink(directory+'/'+id+'.reply');assert.equal(response.id,id);return {...response,value:JSON.parse(Buffer.from(response.data,'base64'))};
  };
  const targets=await call('taskfold_child_adoption_targets',{_after:null,_limit:1,_id:identity.root});assert.equal(targets.code,null);assert.equal(targets.value.items.length,1);assert.equal(targets.value.items[0].task_id,identity.root);report.checks.push('live native target discovery uses actual SQL');
  const searched=await call('taskfold_search_child_adoption_targets',{_query:'Native',_after:null,_limit:100});assert.equal(searched.code,null);assert.equal(searched.value.protocol,2);assert.equal(searched.value.query,'Native');assert.equal(searched.value.items[0].task_id,identity.root);report.checks.push('query-bound native search channel uses actual SQL without changing saved work');
  const review=(await call('taskfold_review_child_adoption',{_id:identity.root,_generation:identity.generation})).value;
  const body=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,review[k]]));
  const copies=(await call('taskfold_review_child_copies',{_body:body})).value;
  assert.equal(copies.protocol,1);report.checks.push('real scoped comparison through file channel');
  const rows=await pg.scalar(`select jsonb_agg(to_jsonb(r) order by node_key) from taskfold_private.child_task_records r where task_id=${lit(identity.root)}`);
  const choice={kind:'choose_copy',path:[],source:'projection',copy_digest:copies.copy_digest,mapping:{version:1,nodes:rows.map(r=>({source_key:r.node_key,history_key:r.node_key,incarnation:r.incarnation,lifecycle:'recorded'})),retire:[]}};
  const preview=await call('taskfold_preview_child_repair',{_body:{...body,changes:[choice]}});assert.equal(preview.code,null);assert.equal(preview.value.mapping_plan.protocol,1);report.checks.push('real mapped preview');
  const command={...body,changes:[choice],request_id:randomUUID(),repair_digest:preview.value.repair_digest};
  const applied=await call('taskfold_repair_children',{_operation:'send',_body:command});assert.equal(applied.code,null);assert.equal(applied.lose,true);assert.equal(applied.value.state,'applied');report.checks.push('lost reply occurs after actual committed save');
  await pg.raw('update taskfold_private.child_task_record_config set mapping_reconciliation_enabled=false,copy_reconciliation_enabled=false,repair_writes_enabled=false');
  const checked=await call('taskfold_repair_children',{_operation:'check',_body:command});assert.equal(checked.value.archive_id,applied.value.archive_id);
  const replay=await call('taskfold_repair_children',{_operation:'send',_body:command});assert.equal(replay.lose,false);assert.equal(replay.value.replayed,true);report.checks.push('status recovery and exact request replay with write gates closed');
  const published=JSON.parse(await readFile(directory+'/server.json','utf8'));assert.equal(published.root.subtasks[0].description,'Snapshot task instructions');report.checks.push('committed root published before response becomes visible');
  const exported=await call('taskfold_repair_children',{_operation:'original',_body:command});assert.equal(exported.code,null);
  const original=await pg.raw(`select original::text from taskfold_private.child_task_repair_originals where id=${lit(applied.value.archive_id)}`);
  assert.equal(createHash('sha256').update(original).digest('hex'),applied.value.archive_digest);assert.ok(Buffer.from(exported.data,'base64').includes(Buffer.from(original)));report.checks.push('original canonical bytes survive channel unchanged');
  const foreign=await call('taskfold_preview_child_repair',{_body:{...body,account:randomUUID(),changes:[choice]}});assert.equal(foreign.code,'PT503');
  const unsupported=await call('not_a_function',{});assert.equal(unsupported.code,'PT503');report.checks.push('foreign scope and arbitrary SQL routes fail closed');
  await assert.rejects(channel.dispatch({protocol:1,id:randomUUID(),nonce:randomUUID(),body:'e30='}));report.checks.push('stale channel nonce rejected');
  const total=await pg.scalar('select to_jsonb(count(*)) from taskfold_private.child_task_repairs');assert.equal(total,1);report.checks.push('one receipt after replay and refused requests');
  const events=await pg.scalar(`select coalesce(jsonb_agg(kinds),'[]') from public.task_node_activity where task_id=${lit(identity.root)} and format_version=4`);assert.deepEqual(events,[['reconciled']]);report.checks.push('one neutral reconciliation event from real transaction');
  report.passed=true;
 }else{
  console.log(JSON.stringify({ready:true,directory,account:identity.account,root:identity.root,stop:'Create a stop file here or send SIGTERM; owned database is removed.'}));
  const deadline=Date.now()+15*60*1000;
  while(!stopping&&Date.now()<deadline){
   try {if((await readdir(directory)).includes('stop'))break;await channel.drain(directory);}
   catch(error){
    if(error.code!=='ENOENT'||!process.argv.includes('--follow-simulator-container'))throw error;
    directory=await relocatedSimulatorChannel(directory,nonce);
    console.log(JSON.stringify({relocatedTo:directory,ownedNonceMatched:true}));
   }
   await delay(100);
  }
  report.passed=true;
 }
}catch(error){report.failure={message:error.message,code:error.code};process.exitCode=1;}
finally{
 await unlink(directory+'/channel.json').catch(()=>{});
 if(pg)report.fixtureRemoved=await pg.close();
 if(smoke)await rm(directory,{recursive:true,force:true});
 console.log(JSON.stringify(report));
}
