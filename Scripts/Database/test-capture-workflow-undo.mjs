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

 const captureFile=(await readdir(new URL('../../supabase/migrations/',import.meta.url))).find(x=>x.endsWith('_capture_workflow_undo.sql'));
 const captureSQL=await readFile(new URL('../../supabase/migrations/'+captureFile,import.meta.url),'utf8');
 const deploy=await readFile(new URL('./fixtures/capture-workflow-undo-deploy.sql',import.meta.url),'utf8'),rollbackCapture=await readFile(new URL('./fixtures/capture-workflow-undo-rollback.sql',import.meta.url),'utf8');
 await pg.raw(deploy);report.captureMigration=captureFile;report.captureSHA256=createHash('sha256').update(captureSQL).digest('hex');
 const captureCall=(request,body,opts)=>run(`public.taskfold_undo_capture_workflow(${lit(request)},${json(body)})`,opts);
 const capture=async()=>{
  const f=await fixture(),old=randomUUID();
  await pg.raw(`insert into public.tasks(id,user_id,project_id,section_id,title) values(${lit(old)},${lit(owner)},${lit(f.p)},${lit(f.s)},'Existing work');update public.view_orders set ids=${json([old,f.t])} where id=${lit(f.v)}`);
  f.body.items=f.body.items.filter(x=>['tasks','labels'].includes(x.table));
  f.body.order_restores=[{id:f.v,base:{id:f.v,user_id:owner,ids:[old,f.t]},restore:{id:f.v,user_id:owner,ids:[old]}}];
  return {...f,old};
 };
 const order=f=>pg.scalar(`select coalesce((select to_jsonb(ids) from public.view_orders where id=${lit(f.v)}),'null'::jsonb)`);
 const remains=(table,id)=>pg.scalar(`select to_jsonb(exists(select 1 from public.${table} where id::text=${lit(id)}))`);
 check('capture support is independent and explicit',(await run('public.taskfold_workflow_undo_capabilities()')).value,{protocol:1,account:owner,undo_protocol:1,bulk_protocol:1,capture_protocol:1});
 check('new capture route is invoker',await pg.scalar("select to_jsonb(not prosecdef) from pg_proc where oid='public.taskfold_undo_capture_workflow(uuid,jsonb)'::regprocedure"));
 const f=await capture(),request=randomUUID(),success=await captureCall(request,f.body);
 check('one capture Undo applies atomically',success.value.applied);check('successful capture does not archive task content',success.value.rows,[]);
 check('capture removes its fresh task',await remains('tasks',f.t),false);check('capture removes its fresh label',await remains('labels',f.l),false);
 check('capture preserves existing task',await remains('tasks',f.old));check('capture preserves existing project',await remains('projects',f.p));
 check('capture restores original manual order',await order(f),[f.old]);
 await pg.raw(`insert into public.tasks(id,user_id,title) values(${lit(f.t)},${lit(owner)},'Recreated after Undo');update public.view_orders set ids=${json([f.old,f.t])} where id=${lit(f.v)}`);
 check('lost reply returns exact first confirmation',(await captureCall(request,f.body)).value,success.value);
 check('lost reply preserves recreated task',await remains('tasks',f.t));check('lost reply preserves later order',await order(f),[f.old,f.t]);
 const changedBody=structuredClone(f.body);changedBody.order_restores[0].restore.ids=[];check('same request cannot change its recorded intention',(await captureCall(request,changedBody)).code,'22023');
 for(const kind of ['task-edit','order-edit','order-removed','foreign-order']){
  const next=await capture();
  if(kind==='task-edit')await pg.raw(`update public.tasks set title='Later edit' where id=${lit(next.t)}`);
  if(kind==='order-edit')await pg.raw(`update public.view_orders set ids=${json([next.t,next.old])} where id=${lit(next.v)}`);
  if(kind==='order-removed')await pg.raw(`delete from public.view_orders where id=${lit(next.v)}`);
  if(kind==='foreign-order')await pg.raw(`update public.view_orders set user_id=${lit(other)} where id=${lit(next.v)}`);
  const current=await order(next),refused=await captureCall(randomUUID(),next.body);
  check(kind+' refuses whole capture Undo',refused.value?.applied,false);
  check(kind+' preserves captured task',await remains('tasks',next.t));check(kind+' preserves label',await remains('labels',next.l));
  check(kind+' keeps current order',await order(next),current);
  if(kind==='order-edit')check('refusal returns the newer owned order',refused.value.rows.find(x=>x.table==='view_orders').row.ids,[next.t,next.old]);
  if(['order-removed','foreign-order'].includes(kind))check(kind+' returns no unavailable order',refused.value.rows.some(x=>x.table==='view_orders'),false);
 }
 const invalid=await capture();
 for(const kind of ['delete-existing-id','duplicate-order','overlap','wrong-owner','pin-key','non-string-id']){
  const body=structuredClone(invalid.body);
  if(kind==='delete-existing-id')body.order_restores[0].restore.ids=[];
  if(kind==='duplicate-order')body.order_restores.push(body.order_restores[0]);
  if(kind==='overlap')body.items.push({table:'view_orders',id:invalid.v,base:body.order_restores[0].base});
  if(kind==='wrong-owner')body.order_restores[0].restore.user_id=other;
  if(kind==='pin-key'){body.order_restores[0].id='pin:private-note';body.order_restores[0].base.id=body.order_restores[0].id;body.order_restores[0].restore.id=body.order_restores[0].id;}
  if(kind==='non-string-id')body.order_restores[0].base.ids.push({id:'not-a-task'});
  check(kind+' is invalid',(await captureCall(randomUUID(),body)).code,'22023');
  check(kind+' never partially removes tasks',await remains('tasks',invalid.t));
 }
 check('old workflow route refuses a capture body',(await call(randomUUID(),invalid.body)).code,'22023');
 check('foreign account cannot use the capture route',(await captureCall(randomUUID(),invalid.body,{who:other})).code,'22023');
 check('anonymous cannot execute capture Undo',(await captureCall(randomUUID(),invalid.body,{role:'anon'})).code,'42501');
 check('revoked session cannot execute capture Undo',(await captureCall(randomUUID(),invalid.body,{sid:randomUUID()})).code,'28000');
 const race=await capture(),holder=await pg.hold(`update public.view_orders set ids=${json([race.t,race.old])} where id=${lit(race.v)}`),pending=captureCall(randomUUID(),race.body,{app:'capture-order-race'});
 await pg.waitForLock('capture-order-race',holder.pid);check('capture waits for an in-flight reorder',true);await holder.release();
 check('committed concurrent reorder refuses capture Undo',(await pending).value?.applied,false);check('concurrent reorder preserves task',await remains('tasks',race.t));
 const def=await pg.scalar("select to_jsonb(pg_get_functiondef('taskfold_private.undo_private_workflow(uuid,jsonb)'::regprocedure))");await pg.raw(def.replace('TASKFOLD_CAPTURE_WORKFLOW_UNDO_V1','RETIRED_CAPTURE_GUARD'));
 check('downgraded service stops advertising capture',(await run('public.taskfold_workflow_undo_capabilities()')).value.capture_protocol,0);
 check('downgraded helper cannot run capture Undo',(await captureCall(randomUUID(),invalid.body)).code,'PT503');
 await pg.raw(captureSQL);check('idempotent install restores capture support',(await run('public.taskfold_workflow_undo_capabilities()')).value.capture_protocol,1);

 const receiptCount=await pg.scalar('select to_jsonb(count(*)) from taskfold_private.private_workflow_undos');
 await pg.raw(rollbackCapture);
 check('reviewed rollback removes the capture route',await pg.scalar("select to_jsonb(to_regprocedure('public.taskfold_undo_capture_workflow(uuid,jsonb)') is null)"));
 check('reviewed rollback retains template Undo',(await run('public.taskfold_workflow_undo_capabilities()')).value.undo_protocol,1);
 check('reviewed rollback retains retry receipts',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.private_workflow_undos'),receiptCount);
 await pg.raw(captureSQL);
 check('reinstallation recovers successful capture receipt',(await captureCall(request,f.body)).value,success.value);
 check('reinstallation retry preserves recreated task',await remains('tasks',f.t));
 check('reinstallation retry preserves current order',await order(f),[f.old,f.t]);
 report.deploymentSHA256=createHash('sha256').update(deploy).digest('hex');report.rollbackSHA256=createHash('sha256').update(rollbackCapture).digest('hex');
 report.passed=Object.keys(report.checks).length;
}catch(e){report.error=e.message;report.code=e.code;process.exitCode=1;}finally{if(pg)report.fixtureRemoved=await pg.close();await writeFile(new URL('../../docs/daily-use-build/capture-workflow-undo-database.json',import.meta.url),JSON.stringify(report,null,2)+'\n');}
console.log(JSON.stringify(report));
