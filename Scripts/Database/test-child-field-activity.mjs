// Actual task/receipt/history transactions in an owned PostgreSQL fixture.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
const candidate=process.env.TASKFOLD_FIELD_ACTIVITY_SQL;
assert(candidate,'Select the local field-activity SQL candidate explicitly');
const report={checks:{},deployed:false};let pg;
const json=x=>lit(JSON.stringify(x))+'::jsonb';
const check=(name,actual,expected)=>{assert.deepEqual(actual,expected,name);report.checks[name]=true;};
try {
 pg=await createPostgresFixture({advisors:true});await loadChildAuthorityDependencies(pg);
 for(const file of [childAuthorityMigration,'20261031180359_child_field_history_removals.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 report.baselineAdvisors=await pg.advisors();const sql=await readFile(candidate,'utf8');await pg.raw(sql);report.candidateSHA256=createHash('sha256').update(sql).digest('hex');
 const owner={id:randomUUID(),session:randomUUID()},editor={id:randomUUID(),session:randomUUID()},viewer={id:randomUUID(),session:randomUUID()},outsider={id:randomUUID(),session:randomUUID()};
 for(const who of [owner,editor,viewer,outsider])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(who.id)},${lit(who.id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(who.id)});insert into auth.sessions(id,user_id) values(${lit(who.session)},${lit(who.id)});`);
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true;update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
 const claims=who=>`set local role authenticated;set local request.jwt.claim.sub=${lit(who.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:who.id,session_id:who.session}))};`;
 const call=(body,who)=>pg.scalar(`begin;create temp table result(value jsonb,code text,reason text,context text) on commit drop;grant all on result to authenticated;${claims(who)}do $op$declare c text;begin begin insert into result values(public.taskfold_edit_child_task(${json(body)}),null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into result values(null,sqlstate,sqlerrm,c);end;end$op$;reset role;select to_jsonb(r) from result r;commit;`);
 const collected=[];
 for(const shared of [false,true]) {
  const tag=shared?'team editor':'personal owner',task=randomUUID(),project=randomUUID(),team=randomUUID(),who=shared?editor:owner;report.stage=tag;
  const privateText='Private title and notes must stay out of the ledger';
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic activity project');`);
  if(shared)await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Synthetic activity team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(editor.id)},'member'),(${lit(team)},${lit(viewer.id)},'member');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(project)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(project)},${lit(team)},${lit(editor.id)},'editor'),(${lit(project)},${lit(team)},${lit(viewer.id)},'viewer');`);
  const tree=[{id:'first',title:privateText,description:privateText,priority:4,duration_minutes:30,completed:false,future:{private:privateText}},{id:'sibling',title:privateText,subtasks:null}];
  await pg.raw(`insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(task)},${lit(owner.id)},${lit(project)},'Synthetic activity root',true,${json(tree)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(task)};`);
  const root=()=>pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`),node=()=>pg.scalar(`select to_jsonb(n) from taskfold_private.child_task_records n where task_id=${lit(task)} and node_key='first'`),history=()=>pg.scalar(`select coalesce(jsonb_agg(to_jsonb(h) order by sequence),'[]') from public.task_node_activity h where task_id=${lit(task)}`);
  const body=async(changes,remove=[])=>({protocol:remove.length?2:1,account:who.id,request_id:randomUUID(),task_id:task,task_generation:(await root()).task_generation,project_id:project,node_key:'first',incarnation:(await node()).incarnation,revision:(await node()).revision,changes,...(remove.length?{remove_fields:remove}:{})});
  const baseline=await history();check(tag+' existing creation format stays v1',baseline.every(e=>e.format_version===1&&e.changed_fields.length===0),true);
  const command=await body({title:privateText+' updated',description:privateText+' updated',priority:1});let reply=await call(command,who);report.lastDiagnostic=reply;check(tag+' real field RPC succeeds',reply.code,null);
  let events=await history(),event=events.at(-1);check(tag+' one entry for combined field changes',events.length,baseline.length+1);check(tag+' typed field entry is readable v2',event.format_version,2);check(tag+' only actual field names retained',event.changed_fields,['description','priority','title']);check(tag+' field event does not invent planning or completion',event.kinds,['edited']);check(tag+' actor is the real caller',event.actor_id,who.id);check(tag+' custody stays with original owner',event.user_id,owner.id);check(tag+' field effective time is the server recorded time',event.effective_at,event.recorded_at);check(tag+' planning/completion metadata is unchanged',event.before_state,event.after_state);
  const saved=events;reply=await call(command,who);check(tag+' retry is receipt replay',reply.value.replayed,true);check(tag+' retry does not append history',await history(),saved);
  check(tag+' equal notes command succeeds',(await call(await body({description:privateText+' updated'}),who)).code,null);check(tag+' no-op does not append a fictional edit',await history(),saved);
  check(tag+' notes and real date change succeed',(await call(await body({description:privateText+' latest',due_date:'2026-11-02'}),who)).code,null);event=(await history()).at(-1);check(tag+' date and edit share one event',event.kinds,['rescheduled','edited']);check(tag+' values are never stored as field details',event.changed_fields,['description']);check(tag+' chosen day survives metadata capture',event.after_state.due_date,'2026-11-02');
  check(tag+' removing optional estimate succeeds',(await call(await body({},['duration_minutes']),who)).code,null);event=(await history()).at(-1);check(tag+' removal names the estimate without a value',event.changed_fields,['duration_minutes']);check(tag+' optional estimate is actually absent','duration_minutes' in (await node()).fields,false);
  const beforeFailure=await history(),taskBefore=await root(),nodeBefore=await node();
  await pg.raw(`create function taskfold_private.fail_field_activity() returns trigger language plpgsql as $$begin if new.task_id=${lit(task)}::uuid and 'priority'=any(new.changed_fields) then raise exception using errcode='PT409',message='Synthetic activity refusal';end if;return new;end$$;create trigger zz_field_activity_failure after insert on public.task_node_activity for each row execute function taskfold_private.fail_field_activity();`);
  const refused=await body({priority:2});check(tag+' history failure refuses the RPC',(await call(refused,who)).code,'PT409');check(tag+' history failure rolls back root',await root(),taskBefore);check(tag+' history failure rolls back independent node',await node(),nodeBefore);check(tag+' history failure retains exact ledger',await history(),beforeFailure);check(tag+' history failure leaves no receipt',await pg.scalar(`select count(*) from taskfold_private.child_task_edit_receipts where actor_id=${lit(who.id)} and request_id=${lit(refused.request_id)}`),0);
  await pg.raw('drop trigger zz_field_activity_failure on public.task_node_activity;drop function taskfold_private.fail_field_activity()');
  const stale={...command,request_id:randomUUID(),changes:{title:'A stale overwrite'}};check(tag+' stale field write is refused',(await call(stale,who)).code,'PT409');check(tag+' stale refusal has no activity',await history(),beforeFailure);
  if(shared){const denied=await body({priority:2});denied.account=viewer.id;check(tag+' current viewer cannot manufacture edit activity',(await call(denied,viewer)).code,'42501');}
  for(const actor of [who,outsider]) {
   const read=await pg.scalar(`begin;${claims(actor)}select count(*) from public.task_node_activity where task_id=${lit(task)};commit;`);check(tag+(actor===who?' authorized reader sees real history':' outsider cannot read history'),read,actor===who?(await history()).length:0);
  }
  const serialized=JSON.stringify(await history());check(tag+' private content never appears in ledger',serialized.includes(privateText),false);check(tag+' opaque fields never appear in ledger',serialized.includes('future'),false);
  collected.push(...await history());
 }
 for(const role of ['anon','authenticated','service_role']) {
  check(role+' cannot append node history',await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},'public.task_node_activity','INSERT'))`),false);
  check(role+' cannot invoke private capture',await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},'taskfold_private.capture_task_node_activity()','EXECUTE'))`),false);
 }
 const epoch=await pg.scalar('select jsonb_agg(to_jsonb(e)) from public.task_node_activity_epoch e');check('new field coverage does not replace older history coverage',Date.parse(epoch[0].field_recorded_from)>=Date.parse(epoch[0].recorded_from),true);
 report.advisors=await pg.advisors();const oldFindings=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no added advisor findings',report.advisors.result.filter(x=>!oldFindings.has(x.cache_key)),[]);report.status='passed';
 if(process.env.TASKFOLD_FIELD_ACTIVITY_ROWS)await writeFile(process.env.TASKFOLD_FIELD_ACTIVITY_ROWS,JSON.stringify({epoch,events:collected},null,2)+'\n');
} catch(error){report.status='failed';report.error=error.message;process.exitCode=1;}
finally{if(pg)report.containerRemoved=await pg.close();report.checkCount=Object.keys(report.checks).length;if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({status:report.status,checks:report.checkCount,stage:report.stage,error:report.error,containerRemoved:report.containerRemoved}));}
