// Real structure commands, receipt replay and Undo in an owned local database.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
const candidate=process.env.TASKFOLD_ORDER_ACTIVITY_SQL;
assert(candidate,'Select an ordering-activity candidate explicitly');
const report={checks:{},deployed:false};let pg;
const json=x=>lit(JSON.stringify(x))+'::jsonb';
const check=(name,a,b)=>{assert.deepEqual(a,b,name);report.checks[name]=true;};
try {
 pg=await createPostgresFixture({advisors:true});await loadChildAuthorityDependencies(pg);
 for(const file of [childAuthorityMigration,'20261031180359_child_field_history_removals.sql','20261031204437_child_field_activity_details.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 report.baselineAdvisors=await pg.advisors();const sql=await readFile(candidate,'utf8');
 const loaded=await pg.scalar(`create temp table schema_result(code text,reason text,context text);do $load$declare c text;begin begin execute ${lit(sql)};insert into schema_result values(null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into schema_result values(sqlstate,sqlerrm,c);end;end$load$;select to_jsonb(r) from schema_result r;`);
 report.schemaDiagnostic=loaded;check('candidate applies',loaded.code,null);report.candidateSHA256=createHash('sha256').update(sql).digest('hex');
 // Keep exact synthetic SQL diagnostics instead of losing the primary failure.
 pg.raw=async statement=>{
  const d=await pg.scalar(`create temp table diagnostic(code text,reason text,context text);do $diagnostic$declare c text;begin begin execute ${lit(statement)};insert into diagnostic values(null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into diagnostic values(sqlstate,sqlerrm,c);end;end$diagnostic$;select to_jsonb(d) from diagnostic d;`);
  if(d.code){report.sqlDiagnostic=d;throw new Error(d.reason);}
 };
 const malformed=[null,false,"not metadata",{},[],{before:[],after:[]},{before:['a','b'],after:['a','b']},{before:['a','a'],after:['a','b']},{before:['a','b'],after:['b','x']},{before:['a','b'],after:['b','a'],private_text:'No values'},{before:['a','b'],after:['b',{}]},{before:['a','b'],after:['b','\\n']}];
 for(const [i,value] of malformed.entries())check('strict SQL context rejects malformed '+i,await pg.scalar(`select to_jsonb(taskfold_private.valid_node_order_context(${json(value)}))`),false);
 const people=Object.fromEntries(['owner','editor','viewer','outside'].map(k=>[k,{id:randomUUID(),session:randomUUID()}]));
 for(const who of Object.values(people))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(who.id)},${lit(who.id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(who.id)});insert into auth.sessions(id,user_id) values(${lit(who.session)},${lit(who.id)});`);
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true;update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
 const claims=who=>`set local role authenticated;set local request.jwt.claim.sub=${lit(who.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:who.id,session_id:who.session}))};`;
 const run=(body,who)=>pg.scalar(`begin;create temp table result(value jsonb,code text,reason text,context text) on commit drop;grant all on result to authenticated;${claims(who)}do $run$declare c text;begin begin insert into result values(public.taskfold_edit_child_structure(${json(body)}),null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into result values(null,sqlstate,sqlerrm,c);end;end$run$;reset role;select to_jsonb(r) from result r;commit;`);
 const collected=[];
 for(const shared of [false,true]) {
  const tag=shared?'team editor':'personal owner',who=shared?people.editor:people.owner,owner=people.owner,project=randomUUID(),team=randomUUID(),task=randomUUID();report.stage=tag;
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic order project');`);
  if(shared)await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Synthetic order team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(people.editor.id)},'member'),(${lit(team)},${lit(people.viewer.id)},'guest');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(project)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(project)},${lit(team)},${lit(people.editor.id)},'editor'),(${lit(project)},${lit(team)},${lit(people.viewer.id)},'viewer');`);
  const privateText='Private ordering titles and notes';const node=id=>({id,title:privateText,description:privateText,completed:false});
  const tree=[node('a'),node('b'),node('c'),{...node('h'),is_heading:true,subtasks:[node('x'),node('y')]}];
  await pg.raw(`insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(task)},${lit(owner.id)},${lit(project)},'Synthetic order root',true,${json(tree)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(task)};`);
  const root=()=>pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`),projection=()=>pg.scalar(`select to_jsonb(p) from taskfold_private.child_task_projections p where task_id=${lit(task)}`),nodeRow=key=>pg.scalar(`select to_jsonb(n) from taskfold_private.child_task_records n where task_id=${lit(task)} and node_key=${lit(key)}`),history=()=>pg.scalar(`select coalesce(jsonb_agg(to_jsonb(h) order by sequence),'[]') from public.task_node_activity h where task_id=${lit(task)}`);
  const command=async(action,extra={})=>({protocol:1,account:who.id,request_id:randomUUID(),task_id:task,task_generation:(await root()).task_generation,project_id:project,structure_revision:(await projection()).structure_revision,action,...extra});
  const move=async(key,parent,index)=>command('move',{node_key:key,incarnation:(await nodeRow(key)).incarnation,parent_key:parent,index});
  const apply=async(name,body)=>{const r=await run(body,who);report.lastDiagnostic=r;check(tag+' '+name,r.code,null);return r.value;};
  const baseline=(await history()).length;check(tag+' unchanged slot is refused',(await run(await move('a',null,0),who)).code,'22023');check(tag+' no-op placement adds no history',(await history()).length,baseline);const original=await move('c',null,0);await apply('real root reorder succeeds',original);
  let events=await history(),e=events.at(-1);check(tag+' root reorder produces one list entry',events.length,baseline+1);check(tag+' v3 ordering kind',e.kinds,['reordered']);check(tag+' v3 format',e.format_version,3);check(tag+' no field value metadata',e.changed_fields,[]);check(tag+' root parent has empty path',e.before_path,[]);check(tag+' root parent key',e.node_key,'');check(tag+' actual common sibling order',e.order_context,{before:['a','b','c','h'],after:['c','a','b','h']});check(tag+' real caller',e.actor_id,who.id);check(tag+' existing custody',e.user_id,owner.id);check(tag+' no work credit flags',[e.work_before,e.work_after,e.completion_version],[false,false,0]);check(tag+' ordering effective time is receipt time',e.effective_at,e.recorded_at);
  const saved=events;check(tag+' retry is receipt replay',(await run(original,who)).value.replayed,true);check(tag+' retry adds no entry',await history(),saved);
  await apply('Undo uses normal guarded structure command',await command('undo',{undo_of:original.request_id}));e=(await history()).at(-1);check(tag+' Undo records inverse order',e.order_context,{before:['c','a','b','h'],after:['a','b','c','h']});
  await apply('nested reorder succeeds',await move('y','h',0));e=(await history()).at(-1);check(tag+' nested parent path',e.before_path,['h']);check(tag+' one nested list not each shifted child',e.order_context,{before:['x','y'],after:['y','x']});
  const beforeInsert=(await history()).length;await apply('insertion succeeds',await command('insert',{parent_key:null,index:0,node:node('new')}));events=await history();check(tag+' insertion produces only creation',events.slice(beforeInsert).map(e=>e.kinds),[['created']]);
  const beforeMove=(await history()).length;await apply('reparent succeeds',await move('a','h',0));check(tag+' reparent does not claim shifted peers reordered',(await history()).slice(beforeMove).some(e=>e.kinds.includes('reordered')),false);
  const removedNode=await nodeRow('new'),versions=await pg.scalar(`select taskfold_private.child_structure_versions(${lit(task)},'new')`),beforeDelete=(await history()).length;
  await apply('removal succeeds',await command('delete',{node_key:'new',incarnation:removedNode.incarnation,subtree_versions:versions}));check(tag+' removal does not reorder peers',(await history()).slice(beforeDelete).map(e=>e.kinds),[['deleted']]);
  const beforeFailure=await history(),rootBefore=await root(),projectionBefore=await projection();
  await pg.raw(`create function taskfold_private.fail_order_history() returns trigger language plpgsql set search_path='' as $$begin if new.task_id=${lit(task)}::uuid and new.format_version=3 then raise exception using errcode='PT409',message='Synthetic order refusal';end if;return new;end$$;create trigger zz_order_failure after insert on public.task_node_activity for each row execute function taskfold_private.fail_order_history();`);
  const refused=await move('c',null,0);check(tag+' activity failure refuses command',(await run(refused,who)).code,'PT409');check(tag+' rollback root',await root(),rootBefore);check(tag+' rollback projection',await projection(),projectionBefore);check(tag+' rollback exact history',await history(),beforeFailure);check(tag+' rollback receipt',await pg.scalar(`select count(*) from taskfold_private.child_task_structure_receipts where actor_id=${lit(who.id)} and request_id=${lit(refused.request_id)}`),0);
  await pg.raw('drop trigger zz_order_failure on public.task_node_activity;drop function taskfold_private.fail_order_history()');
  const stale={...original,request_id:randomUUID()};check(tag+' stale reorder refuses without history',(await run(stale,who)).code,'PT409');check(tag+' stale keeps history',await history(),beforeFailure);
  if(shared){const denied=await move('c',null,0);denied.account=people.viewer.id;check(tag+' viewer cannot append reorder',(await run(denied,people.viewer)).code,'42501');}
  for(const actor of [who,people.outside])check(tag+(actor===who?' authorized history read':' outsider history refusal'),await pg.scalar(`begin;${claims(actor)}select count(*) from public.task_node_activity where task_id=${lit(task)};commit;`),actor===who?(await history()).length:0);
  check(tag+' no private content in history',JSON.stringify(await history()).includes(privateText),false);
  collected.push(...await history());
 }
 for(const role of ['anon','authenticated','service_role']){
  check(role+' cannot append history',await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},'public.task_node_activity','INSERT'))`),false);
  for(const fn of ['valid_node_order_context(jsonb)','node_activity_order_changes(jsonb,jsonb)'])check(role+' cannot call '+fn,await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},${lit('taskfold_private.'+fn)},'EXECUTE'))`),false);
 }
 const epoch=await pg.scalar('select jsonb_agg(to_jsonb(e)) from public.task_node_activity_epoch e');check('ordering coverage starts after existing field history',Date.parse(epoch[0].order_recorded_from)>=Date.parse(epoch[0].field_recorded_from),true);
 report.advisors=await pg.advisors();const old=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no added advisors',report.advisors.result.filter(x=>!old.has(x.cache_key)),[]);report.status='passed';
 if(process.env.TASKFOLD_ORDER_ACTIVITY_ROWS)await writeFile(process.env.TASKFOLD_ORDER_ACTIVITY_ROWS,JSON.stringify({epoch,events:collected},null,2)+'\n');
}catch(e){report.status='failed';report.error=e.message;process.exitCode=1;}
finally{if(pg)report.containerRemoved=await pg.close();report.checkCount=Object.keys(report.checks).length;if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({status:report.status,checks:report.checkCount,stage:report.stage,error:report.error,containerRemoved:report.containerRemoved}));}
