// Synthetic PostgreSQL with catalog-only legacy columns and current access predicates.
// No hosted rows, credentials, native UI or real Auth HTTP acceptance is implied.
import assert from 'node:assert/strict';
import {readFile,readdir,writeFile} from 'node:fs/promises';
import {randomUUID,createHash} from 'node:crypto';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
const baseline=JSON.parse(await readFile(new URL('./fixtures/personal-workflow-service-baseline.json',import.meta.url),'utf8'));
const file=(await readdir(new URL('../../supabase/migrations/',import.meta.url))).find(x=>x.endsWith('_personal_workflow_undo_service.sql'));
const sql=await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8');
const deployment=await readFile(new URL('./fixtures/personal-workflow-service-deploy.sql',import.meta.url),'utf8');
const rollback=await readFile(new URL('./fixtures/personal-workflow-service-rollback.sql',import.meta.url),'utf8');
const report={scope:baseline.scope,migration:file,migrationSHA256:createHash('sha256').update(sql).digest('hex'),checks:{},deployed:false};
const check=(n,a,b=true)=>{assert.deepEqual(a,b,n);report.checks[n]=true;};const json=v=>lit(JSON.stringify(v))+'::jsonb';let pg;
try{
 pg=await createPostgresFixture();
 const raw=pg.raw;pg.raw=async query=>{try{return await raw(query);}catch(e){report.failedQuery=query.slice(0,220);report.sqlState=e.code;throw e;}};
 await pg.raw(`create role authenticated;create role anon;create role service_role;create schema auth;create schema taskfold_private;
 create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,banned_until timestamptz);
 create table auth.sessions(id uuid primary key,user_id uuid references auth.users on delete cascade,not_after timestamptz);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select current_setting('request.jwt.claims',true)::jsonb$$;
 create table taskfold_private.account_removal_receipts(account_id uuid,created_at timestamptz default clock_timestamp());
 grant usage on schema auth,public,taskfold_private to authenticated;`);
 for(const [name,values] of Object.entries(baseline.enumTypes)) {assert(/^[a-z_][a-z_0-9]*$/.test(name));await pg.raw('create type public.'+name+' as enum('+values.map(lit).join(',')+')');}
 const ident=x=>{assert(/^[a-z_][a-z_0-9]*$/.test(x));return '"'+x+'"';};
 for(const t of baseline.tables)await pg.raw('create table public.'+ident(t.table_name)+'('+t.columns.map(c=>ident(c.name)+' '+c.type+(c.default_expression?' default '+c.default_expression:'')+(c.not_null?' not null':'')).join(',')+',primary key(id));');
 await pg.raw(baseline.projectAccess);
 for(const t of baseline.tables)await pg.raw(`alter table public.${ident(t.table_name)} enable row level security;grant select,insert,update,delete on public.${ident(t.table_name)} to authenticated;`);
 for(const p of baseline.policies)await pg.raw('create policy '+('"'+p.policyname.replaceAll('"','""')+'"')+' on public.'+ident(p.tablename)+' for '+p.cmd+' to '+(p.roles==='{public}'?'public':'authenticated')+(p.qual?' using('+p.qual+')':'')+(p.with_check?' with check('+p.with_check+')':'')+';');
 await pg.raw(`alter table public.sections add foreign key(project_id) references public.projects on delete cascade;
 alter table public.tasks add foreign key(project_id) references public.projects on delete set null;
 alter table public.tasks add foreign key(section_id) references public.sections on delete set null;
 alter table public.project_collaborators add foreign key(project_id) references public.projects on delete cascade;
 create table public.fixture_later_notes(id uuid primary key,user_id uuid,task_id uuid references public.tasks on delete cascade);alter table public.fixture_later_notes enable row level security;`);
 await pg.raw(deployment);
 const owner=randomUUID(),other=randomUUID();for(const id of [owner,other])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(id)},${lit(id+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(id)},${lit(id)})`);
 const identity=(who=owner,sid=who,role='authenticated')=>`set local request.jwt.claim.sub=${lit(who)};set local request.jwt.claims=${lit(JSON.stringify({sub:who,session_id:sid}))};set local role ${role};`;
 const run=async(expr,{who=owner,sid=who,role='authenticated',app='workflow-service-test'}={})=>pg.scalar(`begin;set local application_name=${lit(app)};create temp table result(value jsonb,code text) on commit drop;grant all on result to ${role};${identity(who,sid,role)}do $r$begin begin insert into result values(to_jsonb(${expr}),null);exception when others then insert into result values(null,sqlstate);end;end$r$;select to_jsonb(r) from result r;commit;`);
 const call=(request,body,opts)=>run(`public.taskfold_undo_private_workflow(${lit(request)},${json(body)})`,opts);
 const fixture=async()=>{
  const p=randomUUID(),s=randomUUID(),l='a'+randomUUID().slice(1),t=randomUUID(),v='group:'+p+':'+s;
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(p)},${lit(owner)},'Workflow workshop');insert into public.sections(id,user_id,project_id,name) values(${lit(s)},${lit(owner)},${lit(p)},'Prepare');insert into public.labels(id,user_id,name) values(${lit(l)},${lit(owner)},'Studio');insert into public.tasks(id,user_id,project_id,section_id,title,labels) values(${lit(t)},${lit(owner)},${lit(p)},${lit(s)},'Prepared work',array[${lit(l)}]);insert into public.view_orders(id,user_id,ids) values(${lit(v)},${lit(owner)},${json([t])});`);
  const items=[];for(const [table,id] of [['view_orders',v],['tasks',t],['labels',l],['sections',s],['projects',p]])items.push({table,id,base:await pg.scalar(`select to_jsonb(t)-'created_at'-'updated_at' from public.${table} t where id::text=${lit(id)}`)});
  return {p,s,l,t,v,body:{user_id:owner,items}};
 };
 const rows=body=>pg.scalar('select jsonb_build_array('+body.items.map(i=>`(select to_jsonb(t) from public.${ident(i.table)} t where id::text=${lit(i.id)})`).join(',')+')');
 check('capability independent of all team tables',(await run('public.taskfold_workflow_undo_capabilities()')).value,{protocol:1,account:owner,undo_protocol:1,bulk_protocol:1});
 check('no workspace boundary or team endpoint installed',await pg.scalar("select to_jsonb(to_regprocedure('public.taskfold_workspace_boundary()') is null and to_regprocedure('public.taskfold_teams()') is null)"));
 check('private receipts have RLS and no client read',await pg.scalar("select to_jsonb(relrowsecurity and not has_table_privilege('authenticated',oid,'select')) from pg_class where oid='taskfold_private.private_workflow_undos'::regclass"));
 check('public entry points are invokers',await pg.scalar("select to_jsonb(bool_and(not prosecdef and not has_function_privilege('anon',oid,'execute'))) from pg_proc where oid in('public.taskfold_undo_private_workflow(uuid,jsonb)'::regprocedure,'public.taskfold_workflow_undo_capabilities()'::regprocedure)"));
 const fresh=await fixture(),request=randomUUID(),success=await call(request,fresh.body);check('whole fresh workflow is atomically removed',success.value?.applied);check('all five record types are removed',(await rows(fresh.body)).every(x=>x===null));
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(fresh.p)},${lit(owner)},'Recreated work')`);
 check('lost-reply retry returns the exact original confirmation',await call(request,fresh.body),success);check('receipt never deletes a recreated identity',await pg.scalar(`select to_jsonb(name) from public.projects where id=${lit(fresh.p)}`),'Recreated work');
 const altered=structuredClone(fresh.body);altered.items[0].base.ids=[];check('same request cannot change its body',(await call(request,altered)).code,'22023');
 for(const table of ['projects','sections','labels','tasks','view_orders']){
  const f=await fixture(),item=f.body.items.find(x=>x.table===table);await pg.raw(`update public.${table} set ${table==='tasks'?"title='Later task'":table==='view_orders'?"ids='[]'":"name='Later work'"} where id::text=${lit(item.id)}`);
  const before=await rows(f.body),reply=await call(randomUUID(),f.body);check(table+' changed record refuses whole Undo',reply.value?.applied,false);check(table+' refusal preserves every record',await rows(f.body),before);
 }
 for(const kind of ['incoming-task','incoming-section','incoming-project','hidden-note','hidden-label']){
  const f=await fixture(),id=randomUUID();
  if(kind==='incoming-task')await pg.raw(`insert into public.tasks(id,user_id,project_id,title) values(${lit(id)},${lit(other)},${lit(f.p)},'Hidden later task')`);
  if(kind==='incoming-section')await pg.raw(`insert into public.sections(id,user_id,project_id,name) values(${lit(id)},${lit(other)},${lit(f.p)},'Later section')`);
  if(kind==='incoming-project')await pg.raw(`insert into public.projects(id,user_id,parent_id,name) values(${lit(id)},${lit(other)},${lit(f.p)},'Later project')`);
  if(kind==='hidden-note')await pg.raw(`insert into public.fixture_later_notes values(${lit(id)},${lit(other)},${lit(f.t)})`);
  if(kind==='hidden-label')await pg.raw(`insert into public.tasks(id,user_id,title,subtasks) values(${lit(id)},${lit(other)},'Other work',${json([{id:'child',labels:[f.l]}])})`);
  const before=await rows(f.body);check(kind+' refuses Undo',(await call(randomUUID(),f.body)).value?.applied,false);check(kind+' preserves original records',await rows(f.body),before);
 }
 // Owning an authored task/section is insufficient after project access is revoked.
 const p=randomUUID(),t=randomUUID(),s=randomUUID(),invite=randomUUID();await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(p)},${lit(other)},'Shared workspace');insert into public.project_collaborators(id,project_id,user_id,invited_email,status) values(${lit(invite)},${lit(p)},${lit(owner)},'workshop@example.invalid','accepted');insert into public.sections(id,user_id,project_id,name) values(${lit(s)},${lit(owner)},${lit(p)},'Own section');insert into public.tasks(id,user_id,project_id,section_id,title) values(${lit(t)},${lit(owner)},${lit(p)},${lit(s)},'Own authored task')`);
 const scoped={user_id:owner,items:[]};for(const [table,id] of [['tasks',t],['sections',s]])scoped.items.push({table,id,base:await pg.scalar(`select to_jsonb(t)-'created_at'-'updated_at' from public.${table} t where id=${lit(id)}`)});
 const holder=await pg.hold(`update public.project_collaborators set status='declined' where id=${lit(invite)}`),pending=call(randomUUID(),scoped,{app:'workflow-revoke-race'});await pg.waitForLock('workflow-revoke-race',holder.pid);check('Undo waits for an in-flight access revocation',true);await holder.release();const refused=await pending;
 check('committed access revocation refuses Undo',refused.value?.applied,false);check('refusal does not reveal inaccessible task or section',refused.value?.rows,[]);check('inaccessible authored work is preserved',(await rows(scoped)).every(Boolean));
 const later=await fixture(),rid=randomUUID();await pg.raw(`update public.tasks set title='First later edit' where id=${lit(later.t)}`);check('first changed-record refusal is recorded',(await call(rid,later.body)).value?.applied,false);await pg.raw(`update public.tasks set title='Newest later edit' where id=${lit(later.t)}`);check('refusal retry returns current owned state',(await call(rid,later.body)).value.rows.find(x=>x.table==='tasks').row.title,'Newest later edit');
 const f=await fixture();check('foreign account cannot Undo this workflow',(await call(randomUUID(),f.body,{who:other})).code,'22023');check('revoked session cannot Undo',(await call(randomUUID(),f.body,{sid:randomUUID()})).code,'28000');check('anonymous cannot invoke Undo',(await call(randomUUID(),f.body,{role:'anon'})).code,'42501');check('anonymous cannot discover capability',(await run('public.taskfold_workflow_undo_capabilities()',{role:'anon'})).code,'42501');
 const duplicate=structuredClone(f.body);duplicate.items.push(duplicate.items[0]);check('duplicate identities are refused',(await call(randomUUID(),duplicate)).code,'22023');
 await pg.raw(`insert into public.tasks(id,user_id,title,labels) values(gen_random_uuid(),${lit(other)},'Hidden later label use',array[${lit(f.l)}])`);const identityBefore=await rows(f.body);
 const noncanonical=structuredClone(f.body),label=noncanonical.items.find(x=>x.table==='labels');label.id=label.id.toUpperCase();label.base.id=label.id;check('noncanonical UUID spelling cannot bypass dependency membership',(await call(randomUUID(),noncanonical)).code,'22023');check('noncanonical refusal preserves the whole workflow',await rows(f.body),identityBefore);
 const unknown=structuredClone(f.body);unknown.items[0].table='profiles';check('unsupported tables are refused',(await call(randomUUID(),unknown)).code,'22023');
 await pg.raw(`insert into taskfold_private.account_removal_receipts(account_id) values(${lit(owner)})`);check('account removal blocks Undo',(await call(randomUUID(),f.body)).code,'28000');check('account removal blocks capability discovery',(await run('public.taskfold_workflow_undo_capabilities()')).code,'28000');await pg.raw('delete from taskfold_private.account_removal_receipts');
 const def=await pg.scalar("select to_jsonb(pg_get_functiondef('taskfold_private.undo_private_workflow(uuid,jsonb)'::regprocedure))");await pg.raw(def.replace('TASKFOLD_PERSONAL_WORKFLOW_UNDO_V1','RETIRED_WORKFLOW_GUARD'));
 check('overwritten guarded service stops advertising Undo',(await run('public.taskfold_workflow_undo_capabilities()')).value?.undo_protocol,0);check('overwritten service cannot execute Undo',(await call(randomUUID(),f.body)).code,'PT503');await pg.raw(sql);check('idempotent service install restores support',(await run('public.taskfold_workflow_undo_capabilities()')).value?.undo_protocol,1);
 const receipts=await pg.scalar('select to_jsonb(count(*)) from taskfold_private.private_workflow_undos');
 await pg.raw(rollback);
 check('rollback removes public service routes',await pg.scalar("select to_jsonb(to_regprocedure('public.taskfold_undo_private_workflow(uuid,jsonb)') is null and to_regprocedure('public.taskfold_workflow_undo_capabilities()') is null)"));
 check('rollback disables direct private execution',await pg.scalar("select to_jsonb(has_function_privilege('authenticated','taskfold_private.undo_private_workflow(uuid,jsonb)','execute'))"),false);
 check('rollback retains immutable retry receipts',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.private_workflow_undos'),receipts);
 await pg.raw(sql);check('reinstallation recovers the original successful receipt',(await call(request,fresh.body)).value?.applied);
 check('reinstallation retry still preserves recreated work',await pg.scalar(`select to_jsonb(name) from public.projects where id=${lit(fresh.p)}`),'Recreated work');
 report.deploymentSHA256=createHash('sha256').update(deployment).digest('hex');report.rollbackSHA256=createHash('sha256').update(rollback).digest('hex');
 report.passed=Object.keys(report.checks).length;
}catch(e){report.error=e.message;report.code=e.code;process.exitCode=1;}finally{if(pg)report.fixtureRemoved=await pg.close();await writeFile(new URL('../../docs/daily-use-build/personal-workflow-service-database.json',import.meta.url),JSON.stringify(report,null,2)+'\n');}
console.log(JSON.stringify(report));
