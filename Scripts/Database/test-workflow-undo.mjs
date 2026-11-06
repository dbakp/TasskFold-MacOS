import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,readdir,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadWorkflowRunSchema} from './team-workflow-run-schema.mjs';
const report={checks:{},hostedChanges:false,realDataChanged:false};
const check=(name,actual,expected=true)=>{assert.deepEqual(actual,expected,name);report.checks[name]=true},json=v=>lit(JSON.stringify(v))+'::jsonb';
const owner=randomUUID(),other=randomUUID();let pg;
try {
 pg=await createPostgresFixture({advisors:true});await loadWorkflowRunSchema(pg.raw,{taskTypes:true});
 await pg.raw(`create table public.labels(id uuid primary key,user_id uuid not null references auth.users on delete cascade,name text,color text default '#e31e4b',order_index integer default 0);alter table public.labels enable row level security;create policy owner_labels on public.labels to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));grant select,insert,update,delete on public.labels to authenticated;`);
 for(const id of [owner,other])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(id)},${lit(id+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(id)},${lit(id)});`);
 const migration=(await readdir(new URL('../../supabase/migrations/',import.meta.url))).find(x=>x.endsWith('_guarded_workflow_undo.sql'));
 const sql=await readFile(new URL('../../supabase/migrations/'+migration,import.meta.url),'utf8');await pg.raw(sql);
 const bulk=(await readdir(new URL('../../supabase/migrations/',import.meta.url))).find(x=>x.endsWith('_workflow_undo_bulk.sql'));
 if(bulk && process.env.TASKFOLD_TEST_WORKFLOW_UNDO_LEGACY!=='1'){const bulkSQL=await readFile(new URL('../../supabase/migrations/'+bulk,import.meta.url),'utf8');await pg.raw(bulkSQL);report.bulkMigration=bulk;report.bulkSHA256=createHash('sha256').update(bulkSQL).digest('hex');}
 report.migration=migration;report.migrationSHA256=createHash('sha256').update(sql).digest('hex');
 const identity=(actor=owner,role='authenticated',session=actor)=>`set local role ${role};set local request.jwt.claim.sub=${lit(actor)};set local request.jwt.claims=${lit(JSON.stringify({sub:actor,session_id:session}))};`;
 const call=(request,body,{actor=owner,role='authenticated',session=actor,app='workflow-undo-check'}={})=>pg.scalar(`begin;set local application_name=${lit(app)};create temp table result(value jsonb,code text) on commit drop;grant all on result to authenticated,anon;${identity(actor,role,session)}do $r$begin begin insert into result values(public.taskfold_undo_private_workflow(${lit(request)},${json(body)}),null);exception when others then insert into result values(null,sqlstate);end;end$r$;select jsonb_build_object('value',value,'code',code) from result;commit`);
 const fixture=async()=>{
  const project=randomUUID(),section=randomUUID(),label=randomUUID(),task=randomUUID(),order='group:'+project+':'+section;
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner)},'Synthetic workflow');insert into public.sections(id,user_id,project_id,name) values(${lit(section)},${lit(owner)},${lit(project)},'Prepare');insert into public.labels(id,user_id,name) values(${lit(label)},${lit(owner)},'Studio');insert into public.tasks(id,user_id,project_id,section_id,title,labels,is_heading,subtasks) values(${lit(task)},${lit(owner)},${lit(project)},${lit(section)},'Reference',array[${lit(label)}],true,'[{"id":"child","title":"Productive child","completed":false,"subtasks":[]}]');insert into public.view_orders(id,user_id,ids) values(${lit(order)},${lit(owner)},${json([task])});`);
  const items=[];for(const [table,id] of [['view_orders',order],['tasks',task],['labels',label],['sections',section],['projects',project]]){
   const row=await pg.scalar(`select to_jsonb(t)-'created_at'-'updated_at' from public.${table} t where id::text=${lit(id)}`);items.push({table,id,base:row});
  }
  return {project,section,label,task,order,body:{user_id:owner,items}};
 };
 const rows=body=>pg.scalar(`select jsonb_agg(jsonb_build_object('table',x->>'table','row',case x->>'table' when 'projects' then(select to_jsonb(t) from public.projects t where id::text=x->>'id') when 'sections' then(select to_jsonb(t) from public.sections t where id::text=x->>'id') when 'labels' then(select to_jsonb(t) from public.labels t where id::text=x->>'id') when 'tasks' then(select to_jsonb(t) from public.tasks t where id::text=x->>'id') when 'view_orders' then(select to_jsonb(t) from public.view_orders t where user_id=${lit(owner)} and id=x->>'id') end)) from jsonb_array_elements(${json(body.items)}) x`);
 check('public wrapper is invoker',await pg.scalar("select to_jsonb(prosecdef) from pg_proc where oid='public.taskfold_undo_private_workflow(uuid,jsonb)'::regprocedure"),false);
 check('private receipt table has RLS',await pg.scalar("select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.private_workflow_undos'::regclass"));
 check('authenticated cannot read receipts',await pg.scalar("select to_jsonb(has_table_privilege('authenticated','taskfold_private.private_workflow_undos','select'))"),false);
 const boundary=await pg.scalar(`begin;${identity()}select public.taskfold_workspace_boundary();commit`);
 check('boundary advertises exact workflow compatibility',boundary.personal_workflow_undo_protocol,1);check('compatibility does not enable team editing',boundary.native_team_reads_enabled,false);
 if(report.bulkMigration){check('bulk compatibility is additive',boundary.personal_workflow_undo_bulk_protocol,1);check('small-run compatibility retained',boundary.personal_workflow_undo_protocol,1);}
 if(report.bulkMigration){
  const budget=await fixture(),beforeBudget=await rows(budget.body);
  const tooBig=await pg.scalar(`begin;create temp table result(code text) on commit drop;grant all on result to authenticated;${identity()}
   do $b$begin begin perform public.taskfold_undo_private_workflow(${lit(randomUUID())},${json(budget.body)}||jsonb_build_object('budget_probe',(select jsonb_agg(1e308::numeric) from generate_series(1,60000))));insert into result values(null);exception when others then insert into result values(sqlstate);end;end$b$;select to_jsonb(code) from result;commit`);
  check('expanded numbers cannot bypass byte quota',tooBig,'22023');check('byte refusal leaves complete workflow intact',await rows(budget.body),beforeBudget);
  check('expanded-array budget agrees with client',await pg.scalar(`select to_jsonb(octet_length(jsonb_build_object('n',(select jsonb_agg(1e308::numeric) from generate_series(1,60000)))::text))`),18660007);
 }
 const sparse=await fixture();for(const item of sparse.body.items)for(const [key,value] of Object.entries(item.base))if(value===null&&key!=='id'&&key!=='user_id')delete item.base[key];check('omitted insert defaults canonicalize safely',(await call(randomUUID(),sparse.body)).value?.applied);
 const clean=await fixture(),request=randomUUID(),done=await call(request,clean.body);check('authenticated atomic undo succeeds',done.code,null);check('unchanged workflow is removed',done.value?.applied);check('all five row types removed',(await rows(clean.body)).every(x=>x.row===null));
 // A reply retry must not delete recreated rows, even with identical IDs/content.
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(clean.project)},${lit(owner)},'Restored copy');`);
 check('lost reply uses exact recorded result',await call(request,clean.body),done);check('reply retry leaves restored incarnation',await pg.scalar(`select to_jsonb(name) from public.projects where id=${lit(clean.project)}`),'Restored copy');
 const reused=structuredClone(clean.body);reused.items[0].base.ids=[];check('request identity cannot change body',(await call(request,reused)).code,'22023');
 // Verify multi-row hierarchy deletion with the real parent FK as well as
 // the older logical-column contract used by the remaining fixtures.
 const nested=await fixture(),childProject=randomUUID(),childTask=randomUUID();
 await pg.raw(`alter table public.projects add constraint fixture_workflow_parent foreign key(parent_id) references public.projects(id) on delete set null;insert into public.projects(id,user_id,parent_id,name) values(${lit(childProject)},${lit(owner)},${lit(nested.project)},'Child project');insert into public.tasks(id,user_id,project_id,title) values(${lit(childTask)},${lit(owner)},${lit(childProject)},'Child project task');`);
 const childRow=await pg.scalar(`select to_jsonb(t)-'created_at'-'updated_at' from public.projects t where id=${lit(childProject)}`),childWork=await pg.scalar(`select to_jsonb(t)-'created_at'-'updated_at' from public.tasks t where id=${lit(childTask)}`);
 nested.body.items.unshift({table:'tasks',id:childTask,base:childWork});nested.body.items.splice(nested.body.items.length-1,0,{table:'projects',id:childProject,base:childRow});
 check('whole nested hierarchy undo succeeds',(await call(randomUUID(),nested.body)).value?.applied);check('both nested projects removed',await pg.scalar(`select to_jsonb(count(*)) from public.projects where id in(${lit(childProject)},${lit(nested.project)})`),0);check('both nested tasks removed',await pg.scalar(`select to_jsonb(count(*)) from public.tasks where id in(${lit(childTask)},${lit(nested.task)})`),0);
 await pg.raw('alter table public.projects drop constraint fixture_workflow_parent');
 for(const table of ['projects','sections','labels','tasks','view_orders']){
  const f=await fixture(),item=f.body.items.find(x=>x.table===table);
  await pg.raw(`update public.${table} set ${table==='tasks'?"title='Later edit'":table==='view_orders'?"ids='[]'":"name='Later edit'"} where id::text=${lit(item.id)}`);
  const before=await rows(f.body),result=await call(randomUUID(),f.body);check(table+' edit refuses whole undo',result.value?.applied,false);check(table+' refusal changes no row',await rows(f.body),before);check(table+' refusal returns all surviving owned rows',result.value.rows.length,5);
 }
 for(const dependent of ['task','section','subproject','nested-label','hidden-task','comment']){
  const f=await fixture(),id=randomUUID();
  if(dependent==='task'||dependent==='hidden-task')await pg.raw(`insert into public.tasks(id,user_id,project_id,title) values(${lit(id)},${lit(dependent==='hidden-task'?other:owner)},${lit(f.project)},'Later work');`);
  if(dependent==='section')await pg.raw(`insert into public.sections(id,user_id,project_id,name) values(${lit(id)},${lit(owner)},${lit(f.project)},'Later section');`);
  if(dependent==='subproject')await pg.raw(`insert into public.projects(id,user_id,parent_id,name) values(${lit(id)},${lit(owner)},${lit(f.project)},'Later subproject');`);
  if(dependent==='nested-label')await pg.raw(`insert into public.tasks(id,user_id,title,subtasks) values(${lit(id)},${lit(other)},'Other work',${json([{id:'new-child',title:'Child',labels:[f.label],subtasks:[]}])});`);
  if(dependent==='comment'){
   // An unknown future FK-dependent feature must fail closed too.
   await pg.raw(`create table if not exists public.fixture_workflow_notes(id uuid primary key,user_id uuid,task_id uuid references public.tasks on delete cascade);alter table public.fixture_workflow_notes enable row level security;insert into public.fixture_workflow_notes values(${lit(id)},${lit(other)},${lit(f.task)});`);
  }
  const before=await rows(f.body),result=await call(randomUUID(),f.body);check(dependent+' dependency refuses undo',result.value?.applied,false);check(dependent+' dependency preserves all created rows',await rows(f.body),before);
 }
 const sectionOnly=await fixture(),incomingSectionTask=randomUUID();await pg.raw(`insert into public.tasks(id,user_id,section_id,title) values(${lit(incomingSectionTask)},${lit(other)},${lit(sectionOnly.section)},'Non-FK section work');`);check('logical section dependency without FK blocks undo',(await call(randomUUID(),sectionOnly.body)).value?.applied,false);
 const denied=await fixture(),deniedRequest=randomUUID();await pg.raw(`update public.projects set name='First revision' where id=${lit(denied.project)}`);check('changed record first refuses undo',(await call(deniedRequest,denied.body)).value?.applied,false);await pg.raw(`update public.projects set name='Newer revision' where id=${lit(denied.project)}`);const fresh=await call(deniedRequest,denied.body);check('refusal retry keeps refusal',fresh.value?.applied,false);check('refusal retry returns fresh owned state',fresh.value.rows.find(x=>x.table==='projects').row.name,'Newer revision');
 const team=randomUUID();await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner)},'Synthetic custody');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner)},'admin');insert into taskfold_private.team_project_identities(project_id,team_id) values(${lit(denied.project)},${lit(team)})`);const adopted=await call(deniedRequest,denied.body);check('receipt retry cannot expose adopted project',adopted.value.rows.some(x=>x.table==='projects'),false);check('adopted content cannot be deleted by new personal undo',(await call(randomUUID(),denied.body)).value?.applied,false);
 const f=await fixture();check('anonymous cannot invoke',(await call(randomUUID(),f.body,{role:'anon'})).code,'42501');check('wrong actor cannot undo',(await call(randomUUID(),f.body,{actor:other})).code,'22023');check('revoked session cannot undo',(await call(randomUUID(),f.body,{session:randomUUID()})).code,'28000');
 const duplicate=structuredClone(f.body);duplicate.items.push(duplicate.items[0]);check('duplicate targets rejected',(await call(randomUUID(),duplicate)).code,'22023');
 const malformed=structuredClone(f.body);malformed.items[0].table='profiles';check('table whitelist enforced',(await call(randomUUID(),malformed)).code,'22023');
 // A concurrent writer holds the task relation. Undo waits, then checks the
 // committed new dependency rather than using a pre-lock observation.
 const race=await fixture(),later=randomUUID(),holder=await pg.hold(`insert into public.tasks(id,user_id,project_id,title) values(${lit(later)},${lit(owner)},${lit(race.project)},'Concurrent incoming task')`);
 const pending=call(randomUUID(),race.body,{app:'workflow-undo-race'});await pg.waitForLock('workflow-undo-race',holder.pid);check('undo waits for live incoming writer',true);await holder.release();check('committed incoming task refuses undo',(await pending).value?.applied,false);check('incoming task remains',await pg.scalar(`select to_jsonb(exists(select 1 from public.tasks where id=${lit(later)}))`));
 report.advisors=await pg.advisors();check('no new warning/error advisor findings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
 report.checkCount=Object.keys(report.checks).length;report.containerRemoved=await pg.close();pg=null;if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
} finally {if(pg)await pg.close()}
