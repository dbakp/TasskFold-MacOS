// Genuine isolated Auth/REST and complete owned schema. Never hosted/user work.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {writeFile,readFile} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
const report={sourceSHA256:createHash('sha256').update(await readFile(new URL(import.meta.url))).digest('hex'),checks:{},hostedChanges:false,normalGatesChanged:false};let runtime;
const lit=x=>"'"+String(x).replaceAll("'","''")+"'";
const json=x=>lit(JSON.stringify(x))+'::jsonb';
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
const ok=(name,r,status=200)=>{if(r.status!==status)report.lastFailure={name,status:r.status,code:r.value?.code,message:r.value?.message};check(name,r.status===status);return r.value};
const keys=['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest'];
try{
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;report.images=runtime.images;
 const owner=ok('owner signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'restore-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const other=ok('other signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'restore-other-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const account=owner.user.id,authorization=owner.access_token;
 const api=(path,body,token=authorization)=>runtime.request('rest',path,{authorization:token,method:'POST',body,includeText:true});
 const patch=(id,body,token=authorization)=>runtime.request('rest','/tasks?id=eq.'+id,{authorization:token,method:'PATCH',body});
 const project=randomUUID();ok('create project',await api('/projects',{id:project,user_id:account,name:'Restoration workshop'}),201);
 const project2=randomUUID();ok('create second project',await api('/projects',{id:project2,user_id:account,name:'Do not move a held copy'}),201);
 check('restoration gates default off',await runtime.raw('select not archive_restore_enabled and not archive_restore_reversals_enabled from taskfold_private.child_task_record_config')==='t');
 await runtime.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true');
 const state=()=>runtime.raw("select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'records',(select jsonb_agg(to_jsonb(r) order by task_id,node_key) from taskfold_private.child_task_records r),'projections',(select jsonb_agg(to_jsonb(p) order by task_id) from taskfold_private.child_task_projections p),'authority',(select jsonb_agg(to_jsonb(a) order by task_id) from taskfold_private.child_task_record_authority a),'originals',(select jsonb_agg(to_jsonb(o) order by id) from taskfold_private.child_task_repair_originals o),'repairs',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_task_repairs r),'restorations',(select jsonb_agg(to_jsonb(s) order by restore_id) from taskfold_private.child_repair_restorations s),'payloads',(select jsonb_agg(to_jsonb(p) order by restore_id) from taskfold_private.child_repair_restore_payloads p),'requests',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_repair_restore_requests r),'file_fences',(select jsonb_agg(to_jsonb(f) order by actor_id,restore_id,object_id) from taskfold_private.child_repair_restore_files f),'scopes',(select jsonb_agg(to_jsonb(s)) from taskfold_private.child_repair_restore_scope s),'root_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_activity h),'child_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h),'comments',(select jsonb_agg(to_jsonb(c) order by id) from public.task_comments c),'files',(select jsonb_agg(to_jsonb(f) order by object_id) from taskfold_private.team_content_files f))::text");
 const exactTree=id=>runtime.raw(`select coalesce(subtasks,'null'::jsonb)::text from public.tasks where id=${lit(id)}`);
 const records=id=>runtime.raw(`select coalesce(jsonb_agg(to_jsonb(r)-'incarnation'-'revision' order by node_key),'[]')::text from taskfold_private.child_task_records r where task_id=${lit(id)}`);
 const incarnations=async id=>JSON.parse(await runtime.raw(`select coalesce(jsonb_object_agg(node_key,incarnation::text),'{}')::text from taskfold_private.child_task_records where task_id=${lit(id)}`));
 const histories=async()=>JSON.parse(await runtime.raw("select jsonb_build_object('root',(select coalesce(jsonb_object_agg(id::text,encode(sha256(convert_to(to_jsonb(h)::text,'UTF8')),'hex')),'{}') from public.task_activity h),'child',(select coalesce(jsonb_object_agg(id::text,encode(sha256(convert_to(to_jsonb(h)::text,'UTF8')),'hex')),'{}') from public.task_node_activity h))::text"));
 const preserveHistory=(name,before,after)=>check(name,Object.entries(before.root).every(([k,v])=>after.root[k]===v)&&Object.entries(before.child).every(([k,v])=>after.child[k]===v));
 async function repairSource(label,kind='array',pid=project,user=account){
  const node=randomUUID(),task=ok('create '+label,await runtime.request('rest','/tasks',{authorization,method:'POST',headers:{Prefer:'return=representation'},body:{id:randomUUID(),user_id:user,project_id:pid,title:label,description:'Keep current root notes',priority:2,subtasks:kind==='array'?[{id:node,title:'Keep parent',completed:false,taskfold_completion_v1:{epoch:randomUUID(),version:0},subtasks:['Original instruction'],future:{text:'Café 🪴'}}]:null}}),201)[0];
  if(kind==='array')await runtime.raw(`update public.tasks set subtasks=jsonb_set(subtasks,'{0,future}', '{"exact":9007199254740993,"huge":1e500,"é":1,"é":2}'::jsonb) where id=${lit(task.id)}`);
  else await runtime.raw(`update public.tasks set subtasks=${kind==='sql-null'?'null':kind==='json-null'?"'null'::jsonb":kind==='scalar'?json('Original scalar 🪴'):json({title:'Original object',future:'Retain unknown fields'})} where id=${lit(task.id)}`);
  const oldTree=await exactTree(task.id),oldNull=await runtime.raw(`select subtasks is null from public.tasks where id=${lit(task.id)}`);
  const review=ok('adoption review '+label,await api('/rpc/taskfold_review_child_adoption',{_id:task.id,_generation:task.task_generation}));
  const body=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,review[k]]));
  body.changes=kind==='array'?[{kind:'wrap_item',path:[0,0],reference:randomUUID(),title:'Repaired instruction'}]:[{kind:'make_root_list',path:[]},...(kind==='object'?[{kind:'assign_reference',path:[0],reference:randomUUID()}]:[{kind:'wrap_item',path:[0],reference:randomUUID(),title:'Repaired scalar'}])];
  const preview=ok('repair preview '+label,await api('/rpc/taskfold_preview_child_repair',{_body:body}));
  const command={...body,request_id:randomUUID(),repair_digest:preview.repair_digest};
  const receipt=ok('real repair '+label,await api('/rpc/taskfold_repair_children',{_operation:'send',_body:command}));
  check('real applied repair '+label,receipt.state==='applied');return {task,receipt,command,oldTree,oldNull};
 }
 const review=(f,mode='restore',restore=null,token=authorization)=>api('/rpc/taskfold_review_child_restore',{_mode:mode,_repair:f.receipt.request_id,_archive:f.receipt.archive_id,_restore:restore},token);
 const command=preview=>({...Object.fromEntries(keys.map(k=>[k,preview[k]])),request_id:randomUUID()});
 const send=(body,operation='send',token=authorization)=>api('/rpc/taskfold_restore_child_original',{_operation:operation,_body:body},token);
 const f=await repairSource('Exact malformed nested original');const currentTree=await exactTree(f.task.id),currentRecords=await records(f.task.id),oldInc=await incarnations(f.task.id),oldHistory=await histories();
 const before=await state(),paused=ok('paused restore review',await review(f));check('review independent of write gate',paused.enabled===false&&paused.mode==='restore'&&paused.restore_id===null&&paused.revision===0);
 check('review no writes',await state()===before);ok('paused send refused',await send(command(paused)),503);check('paused refusal preserves all rows',await state()===before);
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_enabled=true');check('Undo prerequisite required',ok('authoring without Undo review',await review(f)).enabled===false);
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_reversals_enabled=true');
 const prepared=ok('enabled full restore review',await review(f)),body=command(prepared);check('preview has no private history counts',!('__history_counts'in prepared));
 for(const [name,change,status] of [['bad digest',{review_digest:'a'.repeat(64)},409],['wrong archive digest',{archive_digest:'a'.repeat(64)},409],['wrong context',{project_id:project2},409],['unknown field',{extra:true},400],['fractional revision',{revision:0.5},400],['negative revision',{revision:-1},400],['string revision',{revision:'0'},400],['unsafe revision',{revision:9007199254740991},400],['wrong phase',{restore_id:randomUUID()},400],['foreign account',{account:other.user.id},403]]){
  const baseline=await state();ok(name,await send({...body,...change,request_id:randomUUID()}),status);check(name+' atomic',await state()===baseline);
 }
 ok('other actor cannot review original',await review(f,'restore',null,other.access_token),403);
 // Root metadata can change after review without being overwritten by restore.
 ok('edit root after review',await patch(f.task.id,{description:'New root notes survive restoration',priority:1}),204);
 const applied=ok('restore exact older structure',await send(body));check('restore receipt binds same request',applied.request_id===body.request_id&&applied.restoration_id===body.request_id&&applied.next_revision===1&&applied.phase==='restored'&&applied.state==='applied'&&!applied.replayed);
 const restoreID=applied.restoration_id;check('old source exact including numeric spelling',await exactTree(f.task.id)===f.oldTree);check('all current record content retained',await records(f.task.id)===currentRecords);
 const newInc=await incarnations(f.task.id);check('all stale child identities invalidated',Object.keys(oldInc).length>0&&Object.entries(oldInc).every(([k,v])=>newInc[k]!==v));
 check('authority paused rather than records erased',await runtime.raw(`select not exists(select 1 from taskfold_private.child_task_record_authority where task_id=${lit(f.task.id)}) and exists(select 1 from taskfold_private.child_task_projections where task_id=${lit(f.task.id)} and state='review')`)==='t');
 check('root notes and priority preserved',await runtime.raw(`select description='New root notes survive restoration' and priority=1 from public.tasks where id=${lit(f.task.id)}`)==='t');preserveHistory('earlier history exact after restore',oldHistory,await histories());
 const active=await state();ok('ordinary child replacement fenced',await patch(f.task.id,{subtasks:[]}),409);check('ordinary refusal retained every copy',await state()===active);ok('realm move fenced while old source is active',await patch(f.task.id,{project_id:project2}),409);check('realm refusal retained every copy',await state()===active);
 const replay=ok('lost reply retry original',await send(body));check('retry confirms only original decision',replay.replayed&&replay.restoration_id===restoreID&&replay.next_revision===1);check('replay does not reset source or history',await state()===active);
 const unknown=ok('unknown check',await send({...body,request_id:randomUUID()},'check'));check('check does not create work',unknown.state==='unknown'&&await state()===active);
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_enabled=false');
 const captures=[{review:prepared,command:body,reply:applied,wire:(await review(f,'undo',restoreID)).text}];const cycles=[];let previousInc=newInc;
 for(const [index,mode] of ['undo','redo','undo','redo','undo'].entries()){
  if(index===0)ok('unrelated edit while restored',await patch(f.task.id,{description:'More recent root notes stay',priority:3}),204);
  const p=ok(mode+' review '+index,await review(f,mode,restoreID));check(mode+' remains available while new restores paused '+index,p.enabled&&p.revision===index+1);
  const b=command(p),r=ok(mode+' apply '+index,await send(b));check('monotonic cycle '+index,r.next_revision===index+2&&r.phase===(mode==='undo'?'undone':'restored'));
  check('exact selected source '+index,await exactTree(f.task.id)===(mode==='undo'?currentTree:f.oldTree));check('record content stays exact '+index,await records(f.task.id)===currentRecords);
  const inc=await incarnations(f.task.id);check('new incarnations across every boundary '+index,Object.entries(previousInc).every(([k,v])=>inc[k]!==v));previousInc=inc;
  check('unrelated root edits stay '+index,await runtime.raw(`select description='More recent root notes stay' and priority=3 from public.tasks where id=${lit(f.task.id)}`)==='t');
  preserveHistory('history never rewritten '+index,oldHistory,await histories());cycles.push({command:b,reply:r});
 }
 check('Undo restores independent authoring authority',await runtime.raw(`select exists(select 1 from taskfold_private.child_task_record_authority where task_id=${lit(f.task.id)}) and exists(select 1 from taskfold_private.child_task_projections where task_id=${lit(f.task.id)} and state='ready')`)==='t');
 const afterCycles=await state();for(const c of [body,...cycles.map(x=>x.command)])ok('immutable prior receipt '+c.request_id,await send(c,'check'));check('older checks do not revert latest cycle',await state()===afterCycles);
 const stale=cycles[0].command;ok('nonce cannot change mode or data',await send({...stale,review_digest:'b'.repeat(64)}),409);check('nonce conflict preserves work',await state()===afterCycles);
 // A closed request cannot turn into a later write, even after gates resume.
 const redoReview=ok('prepare next Redo',await review(f,'redo',restoreID)),closedBody=command(redoReview),closed=ok('close unsent restoration',await send(closedBody,'close'));
 check('closed decision contains no new restoration',closed.state==='closed'&&closed.restoration_id===null);const afterClose=await state();check('closed send remains closed',ok('send a stopped decision',await send(closedBody)).state==='closed');check('closed replay no mutation',await state()===afterClose);
 // Reciprocal identity guards cover older protocols too.
 ok('old repair nonce cannot become restore close',await send({...closedBody,request_id:f.command.request_id},'close'),409);
 ok('restore nonce cannot become old repair closure',await api('/rpc/taskfold_repair_children',{_operation:'close',_body:{...f.command,request_id:closedBody.request_id}}),409);
 // Old completion baseline cannot reappear after a restore/Undo cycle.
 const row=JSON.parse(await runtime.raw(`select to_jsonb(r)::text from taskfold_private.child_task_records r where task_id=${lit(f.task.id)} and node_key=${lit(Object.keys(oldInc)[0])}`));
 const completion={protocol:1,account,request_id:randomUUID(),task_id:f.task.id,task_generation:f.task.task_generation,project_id:project,node_key:row.node_key,incarnation:oldInc[row.node_key],revision:1,action:'complete',baseline:{completed:false}};
 const preStale=await state();ok('pre-restoration child command refuses',await api('/rpc/taskfold_complete_child_task',{_body:completion}),409);check('old command cannot affect restored version',await state()===preStale);
 const baseline=JSON.parse(await runtime.raw(`select taskfold_private.child_task_completion_state(fields)::text from taskfold_private.child_task_records where task_id=${lit(f.task.id)} and node_key=${lit(row.node_key)}`));
 ok('fresh current child command works',await api('/rpc/taskfold_complete_child_task',{_body:{...completion,request_id:randomUUID(),incarnation:row.incarnation,revision:row.revision,baseline}}));
 const newWork=await state();ok('Redo review preserves later subtask edits',await review(f,'redo',restoreID),409);ok('stale prepared Redo also refuses',await send(command(redoReview)),409);check('later subtask work never overwritten',await state()===newWork);
 // Unsupported scalar/object roots restore exactly through genuine repair archives.
 // SQL NULL and JSON null cannot currently produce a repair archive; do not fake one.
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_enabled=true');
 for(const kind of ['scalar','object']){
  const sample=await repairSource('Original '+kind,kind),newTree=await exactTree(sample.task.id),p=ok('review '+kind,await review(sample)),b=command(p),r=ok('restore '+kind,await send(b));
  check('exact root kind '+kind,await exactTree(sample.task.id)===sample.oldTree&&await runtime.raw(`select subtasks is null from public.tasks where id=${lit(sample.task.id)}`)===sample.oldNull);
  const undo=command(ok('review Undo '+kind,await review(sample,'undo',r.restoration_id)));ok('Undo '+kind,await send(undo));check('Undo editable source '+kind,await exactTree(sample.task.id)===newTree);
 }
 // Real statement rollback after inverse/record preparation and a late root fault.
 const fault=await repairSource('Atomic late failure'),faultBody=command(ok('fault review',await review(fault)));
 await runtime.raw(`create function public.restore_fixture_fault() returns trigger language plpgsql as $$begin if new.id=${lit(fault.task.id)}::uuid then raise exception using errcode='PT409',message='Synthetic late failure';end if;return new;end$$;create trigger zz_restore_fixture_fault after update of subtasks on public.tasks for each row execute function public.restore_fixture_fault()`);
 const faultBefore=await state();ok('late failure refuses entire restore',await send(faultBody),409);check('late failure rolls back inverse and every row',await state()===faultBefore);
 await runtime.raw('drop trigger zz_restore_fixture_fault on public.tasks;drop function public.restore_fixture_fault()');
 // Caller restrictions remain authoritative even when private admission passes.
 for(const table of ['tasks','task_activity','task_node_activity']){
  const policy='restore_fixture_'+table;await runtime.raw(`create policy ${policy} on public.${table} as restrictive for select to authenticated using(false)`);const saved=await state();
  ok('caller '+table+' RLS refuses review',await review(fault),403);ok('caller '+table+' RLS rolls back send',await send(faultBody),403);check(table+' RLS no partial source/archive/receipt',await state()===saved);await runtime.raw(`drop policy ${policy} on public.${table}`);
 }
 // Actual private Storage bytes and a genuine shared repair; retained versions
 // pin the binding/object rather than relying on a JSON reference as proof.
 const team=randomUUID(),tp=randomUUID(),tid=randomUUID(),gen=randomUUID();
 await runtime.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(other.user.id)},'Restore file workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(other.user.id)},'admin'),(${lit(team)},${lit(account)},'admin');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true;insert into public.projects(id,user_id,name) values(${lit(tp)},${lit(other.user.id)},'Shared restoration');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(tp)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(tp)},${lit(team)},${lit(account)},'editor');insert into public.tasks(id,task_generation,user_id,project_id,title,subtasks) values(${lit(tid)},${lit(gen)},${lit(other.user.id)},${lit(tp)},'Shared original','["Legacy instruction"]');insert into storage.buckets(id,name,public) values('task-attachments','task-attachments',false) on conflict(id) do update set public=false`);
 const tr=ok('shared repair review',await api('/rpc/taskfold_review_child_adoption',{_id:tid,_generation:gen}));
 const tb=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,tr[k]]));tb.changes=[{kind:'wrap_item',path:[0],reference:randomUUID(),title:'Shared instruction'}];
 const tv=ok('shared repair preview',await api('/rpc/taskfold_preview_child_repair',{_body:tb}));
 const treceipt=ok('shared repair applies',await api('/rpc/taskfold_repair_children',{_operation:'send',_body:{...tb,request_id:randomUUID(),repair_digest:tv.repair_digest}}));
 const objectName=account+'/restore-proof.txt',fileBytes=Buffer.from('Retain real file bytes 🪴');
 const storage=(path,method='GET',body)=>fetch(runtime.urls.storage+path,{method,headers:{apikey:runtime.anon,Authorization:'Bearer '+runtime.service,...(body?{'Content-Type':'text/plain'}:{})},...(body?{body}:{}),signal:AbortSignal.timeout(30000)});
 check('actual private file uploaded',(await storage('/object/task-attachments/'+objectName,'POST',fileBytes)).status===200);
 const object=await runtime.raw(`select id from storage.objects where bucket_id='task-attachments' and name=${lit(objectName)}`);
 await runtime.raw(`update storage.objects set owner=${lit(account)},owner_id=${lit(account)} where id=${lit(object)};insert into taskfold_private.team_content_files(object_id,project_id,task_id,task_generation) values(${lit(object)},${lit(tp)},${lit(tid)},${lit(gen)});update public.tasks set attachments=${json([{id:randomUUID(),storage_object_id:object,name:'Retained proof',url:'https://example.invalid/proof'}])} where id=${lit(tid)}`);
 const tf={receipt:treceipt},tpv=ok('shared file restoration review',await review(tf));check('review includes retained file',tpv.file_count===1&&tpv.enabled);
 const tres=ok('shared file restoration applies',await send(command(tpv)));
 check('shared file fence retained',await runtime.raw(`select exists(select 1 from taskfold_private.child_repair_restore_files where restore_id=${lit(tres.restoration_id)} and object_id=${lit(object)})`)==='t');
 const pinned=await state();
 for(const [name,sql] of [['binding removal',`delete from taskfold_private.team_content_files where object_id=${lit(object)}`],['object mutation',`update storage.objects set name='changed' where id=${lit(object)}`]]){
  let refused=false;try{await runtime.raw(sql)}catch(e){refused=e.code==='PT409'}check('retained '+name+' refused',refused);check(name+' atomic',await state()===pinned);
 }
 const providerDelete=await fetch(runtime.urls.storage+'/object/task-attachments',{method:'DELETE',headers:{apikey:runtime.anon,Authorization:'Bearer '+runtime.service,'Content-Type':'application/json'},body:JSON.stringify({prefixes:[objectName]}),signal:AbortSignal.timeout(30000)});check('provider deletion cannot remove retained object',providerDelete.status>=400);check('provider refusal preserves retained binding',await state()===pinned);
 const tu=ok('shared file Undo review',await review(tf,'undo',tres.restoration_id));ok('shared file Undo applies',await send(command(tu)));
 const downloaded=await storage('/object/authenticated/task-attachments/'+objectName);check('actual bytes survive restore and Undo',downloaded.status===200&&Buffer.from(await downloaded.arrayBuffer()).equals(fileBytes));
 check('transaction restore scopes empty',await runtime.raw('select not exists(select 1 from taskfold_private.child_repair_restore_scope)')==='t');
 // Retained current versions are independently charged.
 const budget=JSON.parse(await runtime.raw(`select payload::text from taskfold_private.child_repair_restore_payloads where actor_id=${lit(account)} order by restore_id limit 1`));check('current versions retained separately',Object.keys(budget).sort().join(',')==='before,files,target,target_sql_null');
 check('no direct retained-state access',await runtime.raw("select not has_table_privilege('authenticated','taskfold_private.child_repair_restore_payloads','SELECT,INSERT,UPDATE,DELETE')")==='t');
 check('public restoration endpoints invoker',await runtime.raw("select bool_and(not prosecdef) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('taskfold_review_child_restore','taskfold_restore_child_original')")==='t');
 check('anonymous restoration refused',await runtime.raw("select not has_function_privilege('anon','public.taskfold_restore_child_original(text,jsonb)','EXECUTE') and not has_function_privilege('anon','public.taskfold_review_child_restore(text,uuid,uuid,uuid)','EXECUTE')")==='t');

 // Finish after Undo: an explicit, separately paused disposal of only the
 // inverse payload. Later current edits remain current, not a stale Redo.
 check('finish gate defaults off',await runtime.raw('select not archive_restore_finish_enabled from taskfold_private.child_task_record_config')==='t');
 const finishBefore=await state(),finishPaused=ok('finish paused review after later child work',await review(f,'finish',restoreID));
 check('finish read binds current version without restoring',!finishPaused.enabled&&finishPaused.mode==='finish'&&JSON.stringify(finishPaused.current_source)===JSON.stringify(finishPaused.target_source));
 check('finish review no writes',await state()===finishBefore);ok('paused finish send refuses',await send(command(finishPaused)),503);check('paused finish atomic',await state()===finishBefore);
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_finish_enabled=true');
 ok('fresh restore for wrong-phase finish',await send(faultBody));const activeFinish=await state();ok('finish cannot discard active older version',await review(fault,'finish',faultBody.request_id),409);check('active older copy remains exact',await state()===activeFinish);
 const stoppedFinish=command(ok('review stoppable finish',await review(f,'finish',restoreID)));
 ok('check unknown finish',await send(stoppedFinish,'check'));const stopProof=ok('stop unsent finish',await send(stoppedFinish,'close'));check('stop finish records no disposal',stopProof.state==='closed');
 const afterStopFinish=await state();check('stopped finish cannot revive',ok('send stopped finish',await send(stoppedFinish)).state==='closed');check('stopped finish no writes',await state()===afterStopFinish);
 const staleFinish=command(ok('prepare stale finish',await review(f,'finish',restoreID)));
 const later=JSON.parse(await runtime.raw(`select to_jsonb(r)::text from taskfold_private.child_task_records r where task_id=${lit(f.task.id)} and node_key=${lit(row.node_key)}`));
 const reopenBaseline=JSON.parse(await runtime.raw(`select taskfold_private.child_task_completion_state(fields)::text from taskfold_private.child_task_records where task_id=${lit(f.task.id)} and node_key=${lit(row.node_key)}`));
 ok('later ordinary child work before finish',await api('/rpc/taskfold_complete_child_task',{_body:{...completion,request_id:randomUUID(),incarnation:later.incarnation,revision:later.revision,action:'reopen',baseline:reopenBaseline}}));
 const afterLater=await state();ok('stale finish preserves changed editable source',await send(staleFinish),409);check('stale finish cannot drop inverse payload',await state()===afterLater);
 const finishReview=ok('review latest finish',await review(f,'finish',restoreID)),finishBody=command(finishReview);
 ok('foreign actor cannot finish',await send(finishBody,'send',other.access_token),403);ok('finish rejects changed request body',await send({...finishBody,review_digest:'a'.repeat(64),request_id:randomUUID()}),409);
 await runtime.raw(`create function public.finish_fixture_fault() returns trigger language plpgsql as $$begin if new.restore_id=${lit(restoreID)}::uuid and new.phase='finished' then raise exception using errcode='PT409',message='Synthetic late finish failure';end if;return new;end$$;create trigger zz_finish_fixture_fault before update on taskfold_private.child_repair_restorations for each row execute function public.finish_fixture_fault()`);
 const beforeFinishFault=await state();ok('late finish failure rolls back',await send(finishBody),409);check('late finish keeps payload pins and decisions',await state()===beforeFinishFault);
 await runtime.raw('drop trigger zz_finish_fixture_fault on taskfold_private.child_repair_restorations;drop function public.finish_fixture_fault()');
 for(const table of ['tasks','task_activity','task_node_activity']){
  const policy='finish_fixture_'+table;await runtime.raw(`create policy ${policy} on public.${table} as restrictive for select to authenticated using(false)`);const saved=await state();
  ok('finish caller '+table+' RLS refuses review',await review(f,'finish',restoreID),403);ok('finish caller '+table+' RLS rolls back send',await send(finishBody),403);check('finish '+table+' RLS preserves all rows',await state()===saved);await runtime.raw(`drop policy ${policy} on public.${table}`);
 }
 const protectedWork=async()=>runtime.raw(`select (${lit(await state())}::jsonb - array['restorations','payloads','requests','file_fences'])::text`);
 const protectedBeforeFinish=await protectedWork();
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_enabled=false,archive_restore_reversals_enabled=false');
 const finished=ok('finish with other restoration gates paused',await send(finishBody));
 check('finish receipt terminal and bound',finished.phase==='finished'&&finished.restoration_id===restoreID&&finished.next_revision===finishBody.revision+1&&finished.request_id===finishBody.request_id);
 check('finish keeps every current authored value history file and original exact',await protectedWork()===protectedBeforeFinish);
 check('finish removes only selected inverse payload',await runtime.raw(`select not exists(select 1 from taskfold_private.child_repair_restore_payloads where actor_id=${lit(account)} and restore_id=${lit(restoreID)}) and exists(select 1 from taskfold_private.child_task_repair_originals where id=${lit(f.receipt.archive_id)})`)==='t');
 const afterFinished=await state();await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_finish_enabled=false');
 check('lost finish reply recovers while paused',ok('check finished request',await send(finishBody,'check')).replayed===true);
 check('exact finish retry cannot dispose again',ok('retry finished request',await send(finishBody)).phase==='finished');
 ok('finished recovery cannot redo',await review(f,'redo',restoreID),409);ok('finished recovery cannot finish twice with new nonce',await send({...finishBody,request_id:randomUUID()}),409);check('finish replay refusal leaves all work exact',await state()===afterFinished);
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_finish_enabled=true');
 const sharedFinish=command(ok('shared retained file finish review',await review(tf,'finish',tres.restoration_id)));
 await runtime.raw(`update taskfold_private.team_members set role='member' where team_id=${lit(team)} and user_id=${lit(account)}`);
 const nonadminFinish=await state();ok('shared editor cannot retire workspace retained recovery',await review(tf,'finish',tres.restoration_id),403);ok('admin demotion fences prepared finish',await send(sharedFinish),403);check('demotion preserves copy and file pins',await state()===nonadminFinish);
 await runtime.raw(`update taskfold_private.team_members set role='admin' where team_id=${lit(team)} and user_id=${lit(account)}`);
 const sharedProtected=await protectedWork();ok('shared admin finishes reviewed recovery',await send(sharedFinish));
 check('shared finish preserves current work and live file binding',await protectedWork()===sharedProtected);
 check('shared finish releases inverse file retention pins',await runtime.raw(`select not exists(select 1 from taskfold_private.child_repair_restore_files where actor_id=${lit(account)} and restore_id=${lit(tres.restoration_id)}) and not exists(select 1 from taskfold_private.child_repair_restore_payloads where actor_id=${lit(account)} and restore_id=${lit(tres.restoration_id)})`)==='t');
 const afterFinishDownload=await storage('/object/authenticated/task-attachments/'+objectName);check('finish leaves actual private Storage bytes intact',afterFinishDownload.status===200&&Buffer.from(await afterFinishDownload.arrayBuffer()).equals(fileBytes));
 check('finish creates no transaction scope',await runtime.raw('select not exists(select 1 from taskfold_private.child_repair_restore_scope)')==='t');
 report.finishContract={review:finishReview,command:finishBody,reply:finished};
 const beforeExpiry=await state();await runtime.raw(`delete from auth.sessions where user_id=${lit(account)}`);const expired=await send(body,'check');check('expired session cannot recover decisions',expired.status>=400&&expired.value?.code==='28000');check('expired session leaves data unchanged',await state()===beforeExpiry);
 report.contract={review:prepared,command:body,reply:applied,cycles};report.advisors=await runtime.advisors();report.passed=true;
}catch(e){report.failure={message:e.message,migration:e.migration,startupCleanup:e.cleanedUp,stack:e.stack?.split('\n').slice(0,4)};process.exitCode=1;}finally{if(runtime)report.cleanup=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed??false,checks:Object.keys(report.checks).length,failure:report.failure,lastFailure:report.lastFailure,cleanup:report.cleanup}));}
