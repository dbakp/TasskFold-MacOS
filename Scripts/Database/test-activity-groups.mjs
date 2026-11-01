// Actual atomic root/child completion, Undo and retry; no hosted writes.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadMixedTaskCompletionDependencies,mixedTaskCompletionMigration} from './mixed-task-completion-schema.mjs';
const candidate=process.env.TASKFOLD_ACTIVITY_GROUP_SQL;assert(candidate,'Choose an explicit local grouping candidate');
const report={checks:{},deployed:false};const check=(name,a,b)=>{assert.deepEqual(a,b,name);report.checks[name]=true;};const json=v=>lit(JSON.stringify(v))+'::jsonb';let pg;
try {
 pg=await createPostgresFixture({advisors:true});await loadMixedTaskCompletionDependencies(pg);
 for(const name of [mixedTaskCompletionMigration,'20261031050018_mixed_task_completion_undo.sql','20261031180359_child_field_history_removals.sql','20261031204437_child_field_activity_details.sql','20261101041509_child_order_activity.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
 report.baselineAdvisors=await pg.advisors();const sql=await readFile(candidate,'utf8');
 const schema=await pg.scalar(`create temp table schema_result(code text,reason text,context text);do $load$declare c text;begin begin execute ${lit(sql)};insert into schema_result values(null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into schema_result values(sqlstate,sqlerrm,c);end;end$load$;select to_jsonb(r) from schema_result r;`);
 report.schemaDiagnostic=schema;check('candidate applies',schema.code,null);report.candidateSHA256=createHash('sha256').update(sql).digest('hex');
 const people=Object.fromEntries(['owner','editor','viewer','outside'].map(k=>[k,{id:randomUUID(),session:randomUUID()}]));
 for(const u of Object.values(people))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(u.id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(u.id)});insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});`);
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,mixed_completions_enabled=true,mixed_completion_writes_enabled=true;update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true');
 const claims=who=>`set local role authenticated;set local request.jwt.claim.sub=${lit(who.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:who.id,session_id:who.session}))};`;
 const run=(b,who,fn='public.taskfold_complete_mixed_tasks')=>pg.scalar(`begin;create temp table result(value jsonb,code text,reason text,context text) on commit drop;grant all on result to authenticated;${claims(who)}do $op$declare c text;begin begin insert into result values(${fn}(${json(b)}),null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into result values(null,sqlstate,sqlerrm,c);end;end$op$;reset role;select to_jsonb(r) from result r;commit;`);
 const collected={roots:[],children:[]};
 for(const shared of [false,true]){
  const tag=shared?'team editor':'personal owner',who=shared?people.editor:people.owner,project=randomUUID(),team=randomUUID();report.stage=tag;
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(people.owner.id)},'Synthetic grouping project');`);
  if(shared)await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(people.owner.id)},'Synthetic grouping team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(people.owner.id)},'admin'),(${lit(team)},${lit(people.editor.id)},'member'),(${lit(team)},${lit(people.viewer.id)},'member');insert into taskfold_private.team_content_projects(team_id,project_id,visibility) values(${lit(team)},${lit(project)},'private');insert into taskfold_private.team_project_grants(team_id,project_id,user_id,role) values(${lit(team)},${lit(project)},${lit(people.editor.id)},'editor'),(${lit(team)},${lit(project)},${lit(people.viewer.id)},'viewer');`);
  const parent=randomUUID(),heading=randomUUID(),privateText='Private grouping task contents';
  for(const [id,isHeading] of [[parent,false],[heading,true]])await pg.raw(`insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(id)},${lit(people.owner.id)},${lit(project)},${lit(privateText)},${isHeading},${isHeading?json([{id:'child',title:privateText,description:privateText,completed:false,completed_at:null}]):"'[]'::jsonb"});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(id)}`);
  const guardRoot=()=>pg.scalar(`select jsonb_build_object('task_id',t.id,'baseline',taskfold_private.completion_selection_root_baseline(t),'source_hash',taskfold_private.completion_selection_root_hash(t)) from public.tasks t where id=${lit(parent)}`);
  const guardChild=()=>pg.scalar(`select jsonb_build_object('task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'node_key',n.node_key,'incarnation',n.incarnation,'revision',n.revision,'baseline',taskfold_private.child_task_completion_state(n.fields)) from public.tasks t join taskfold_private.child_task_records n on n.task_id=t.id where t.id=${lit(heading)} and n.node_key='child'`);
  const histories=()=>pg.scalar(`select jsonb_build_object('roots',(select coalesce(jsonb_agg(to_jsonb(h) order by sequence),'[]') from public.task_activity h where task_id in(${lit(parent)},${lit(heading)})),'children',(select coalesce(jsonb_agg(to_jsonb(h) order by sequence),'[]') from public.task_node_activity h where task_id in(${lit(parent)},${lit(heading)})))`);
  const command=async()=>{const r=await guardRoot(),c=await guardChild();return{protocol:1,account:who.id,batch_id:randomUUID(),action:'complete',completed_at:'2026-10-31T09:00:00Z',input_zone:'Europe/Copenhagen',roots:[r],children:[c],items:[{kind:'root',request_id:randomUUID(),task_id:parent},{kind:'child',command:{protocol:1,account:who.id,request_id:randomUUID(),...c,action:'complete'}}]};};
  const initial=await histories();check(tag+' old/system seed stays ungrouped',[...initial.roots,...initial.children].every(e=>e.operation_context===null),true);
  const b=await command();
  // Changing the session timezone between the root and child captures must not
  // split one real transaction or change any completion instant.
  await pg.raw("create function taskfold_private.fixture_group_timezone() returns trigger language plpgsql set search_path='' as $$begin if new.actor_id is not null then perform set_config('TimeZone','Pacific/Auckland',true);end if;return new;end$$;create trigger zz_group_timezone after insert on public.task_activity for each row execute function taskfold_private.fixture_group_timezone()");
  let reply=await run(b,who);
  await pg.raw('drop trigger zz_group_timezone on public.task_activity;drop function taskfold_private.fixture_group_timezone()');report.lastDiagnostic=reply;check(tag+' actual mixed action succeeds',reply.code,null);
  let history=await histories(),events=[...history.roots,...history.children].filter(e=>e.operation_context);
  check(tag+' exactly two actual changes share one group',events.length,2);check(tag+' one transaction identity',new Set(events.map(e=>e.operation_context.id)).size,1);
  check(tag+' server origin and version',events.map(e=>[e.operation_context.origin,e.operation_context.version]),[['server_transaction',1],['server_transaction',1]]);
  check(tag+' both caller identities retained',events.every(e=>e.actor_id===who.id),true);check(tag+' parent chosen completion time retained',Date.parse(events.find(e=>e.task_id===parent).effective_at),Date.parse('2026-10-31T09:00:00Z'));
  check(tag+' every event keeps its own persisted completion instant',events.every(e=>Date.parse(e.effective_at)===Date.parse(e.after_state.completed_at)),true);
  const childProof=reply.value.receipts.find(e=>e.kind==='child').receipt;
  check(tag+' child server event time matches its exact receipt',Date.parse(events.find(e=>e.node_key==='child').effective_at),Date.parse(childProof.after.completed_at));
  const firstID=events[0].operation_context.id,saved=history;
  check(tag+' exact retry is replay',(await run(b,who)).value.replayed,true);check(tag+' retry keeps exact ledger and group',await histories(),saved);
  const undo={protocol:1,account:who.id,batch_id:randomUUID(),undo_of:b.batch_id,items:await Promise.all(reply.value.receipts.map(async proof=>{if(proof.kind==='root')return{kind:'root',request_id:randomUUID(),task_id:proof.task_id};const c={protocol:1,account:who.id,request_id:randomUUID(),...await guardChild(),action:'undo',undo_of:proof.request_id};delete c.baseline;return{kind:'child',command:c};}))};
  reply=await run(undo,who,'public.taskfold_undo_mixed_completion');report.lastDiagnostic=reply;check(tag+' actual whole-action Undo succeeds',reply.code,null);
  history=await histories();const inverse=[...history.roots,...history.children].filter(e=>e.operation_context&&e.operation_context.id!==firstID);
  check(tag+' Undo has two changes',inverse.length,2);check(tag+' Undo has its own shared identity',new Set(inverse.map(e=>e.operation_context.id)).size,1);check(tag+' Undo retains reopen kinds',inverse.every(e=>e.kinds.includes('reopened')),true);
  const afterUndo=history;check(tag+' Undo retry is replay',(await run(undo,who,'public.taskfold_undo_mixed_completion')).value.replayed,true);check(tag+' Undo retry keeps history',await histories(),afterUndo);
  const fresh=await command();
  await pg.raw(`create function taskfold_private.fixture_group_failure() returns trigger language plpgsql set search_path='' as $$begin if new.task_id=${lit(heading)}::uuid and 'completed'=any(new.kinds) then raise exception using errcode='PT409',message='Synthetic late history refusal';end if;return new;end$$;create trigger zz_group_failure after insert on public.task_node_activity for each row execute function taskfold_private.fixture_group_failure()`);
  check(tag+' late child history failure refuses whole action',(await run(fresh,who)).code,'PT409');check(tag+' failed group leaves exact history',await histories(),afterUndo);
  check(tag+' failed group leaves no receipt',await pg.scalar(`select count(*) from taskfold_private.mixed_completion_batches where actor_id=${lit(who.id)} and batch_id=${lit(fresh.batch_id)}`),0);
  await pg.raw('drop trigger zz_group_failure on public.task_node_activity;drop function taskfold_private.fixture_group_failure()');
  check(tag+' fresh completion succeeds',(await run(fresh,who)).code,null);history=await histories();events=[...history.roots,...history.children].filter(e=>e.operation_context);
  check(tag+' three operations stay distinct',new Set(events.map(e=>e.operation_context.id)).size,3);check(tag+' no field contents in metadata',JSON.stringify(events.map(e=>e.operation_context)).includes(privateText),false);
  // An invalid same-state/stale request cannot add a correlation entry.
  const stale={...b,batch_id:randomUUID()};check(tag+' stale source refuses',(await run(stale,who)).code,'PT409');check(tag+' stale request leaves exact history',await histories(),history);
  if(shared){const denied=await command();denied.account=people.viewer.id;denied.action='reopen';denied.items[1].command.account=people.viewer.id;denied.items[1].command.action='reopen';check(tag+' viewer cannot create a group',(await run(denied,people.viewer)).code,'42501');}
  for(const actor of [who,people.outside]){
   const visible=await pg.scalar(`begin;${claims(actor)}select (select count(*) from public.task_activity where task_id in(${lit(parent)},${lit(heading)}))+(select count(*) from public.task_node_activity where task_id in(${lit(parent)},${lit(heading)}));commit;`);
   check(tag+(actor===who?' authorized history remains readable':' outsider sees no group or history'),visible,actor===who?history.roots.length+history.children.length:0);
  }
  collected.roots.push(...history.roots);collected.children.push(...history.children);
 }
 for(const role of ['anon','authenticated','service_role']){
  check(role+' cannot execute tagging directly',await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},'taskfold_private.tag_activity_operation()','EXECUTE'))`),false);
  for(const table of ['task_activity','task_node_activity'])check(role+' cannot append '+table,await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},${lit('public.'+table)},'INSERT'))`),false);
 }
 check('tagging does not elevate privileges',await pg.scalar("select to_jsonb(not prosecdef) from pg_proc where oid='taskfold_private.tag_activity_operation()'::regprocedure"),true);
 report.advisors=await pg.advisors();const before=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no added advisor findings',report.advisors.result.filter(x=>!before.has(x.cache_key)),[]);report.status='passed';
 if(process.env.TASKFOLD_ACTIVITY_GROUP_ROWS)await writeFile(process.env.TASKFOLD_ACTIVITY_GROUP_ROWS,JSON.stringify(collected,null,2)+'\n');
}catch(e){report.status='failed';report.error={message:e.message,code:e.code};process.exitCode=1;}
finally{if(pg)report.containerRemoved=await pg.close();report.checkCount=Object.keys(report.checks).length;if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({status:report.status,checks:report.checkCount,stage:report.stage,error:report.error,containerRemoved:report.containerRemoved}));}
