import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,readdir,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadWorkflowRunSchema} from './team-workflow-run-schema.mjs';
const report={checks:{},timings:[],hostedChanges:false,realDataChanged:false};
const check=(n,v,e=true)=>{assert.deepEqual(v,e,n);report.checks[n]=true};
const owner=randomUUID(),other=randomUUID();let pg;
async function initialize(){
 pg=await createPostgresFixture({advisors:true});await loadWorkflowRunSchema(pg.raw,{taskTypes:true});
 await pg.raw(`create table public.labels(id uuid primary key,user_id uuid not null references auth.users on delete cascade,name text,color text default '#e31e4b',order_index integer default 0);alter table public.labels enable row level security;create policy owner_labels on public.labels to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));grant select,insert,update,delete on public.labels to authenticated;
 create table taskfold_private.workflow_benchmark(id uuid primary key,user_id uuid,body jsonb);alter table taskfold_private.workflow_benchmark enable row level security;grant select on taskfold_private.workflow_benchmark to authenticated;create policy owner_input on taskfold_private.workflow_benchmark to authenticated using(user_id=(select auth.uid()));`);
 for(const id of [owner,other])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(id)},${lit(id+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(id)},${lit(id)});`);
}
try {
 await initialize();
 const files=await readdir(new URL('../../supabase/migrations/',import.meta.url)),legacy=files.find(x=>x.endsWith('_guarded_workflow_undo.sql')),bulk=files.find(x=>x.endsWith('_workflow_undo_bulk.sql'));
 const legacySQL=await readFile(new URL('../../supabase/migrations/'+legacy,import.meta.url),'utf8'),bulkSQL=await readFile(new URL('../../supabase/migrations/'+bulk,import.meta.url),'utf8');await pg.raw(legacySQL);
 report.sources={[legacy]:createHash('sha256').update(legacySQL).digest('hex'),[bulk]:createHash('sha256').update(bulkSQL).digest('hex')};
 const identity=`set local role authenticated;set local request.jwt.claim.sub=${lit(owner)};set local request.jwt.claims=${lit(JSON.stringify({sub:owner,session_id:owner}))};`;
 async function seed(count,sectioned){
  const id=randomUUID();
  await pg.raw(`begin;create temp table ids(n int,task uuid,section uuid,label uuid) on commit drop;insert into ids select n,gen_random_uuid(),gen_random_uuid(),gen_random_uuid() from generate_series(1,${count}) n;
 insert into public.projects(id,user_id,name) values(${lit(id)},${lit(owner)},'Synthetic scale workflow');
 ${sectioned?`insert into public.sections(id,user_id,project_id,name,order_index) select section,${lit(owner)},${lit(id)},'Section '||n,n from ids;insert into public.labels(id,user_id,name) select label,${lit(owner)},'Label '||n from ids;`:''}
 insert into public.tasks(id,user_id,project_id,section_id,title,labels) select task,${lit(owner)},${lit(id)},${sectioned?'section':'null::uuid'},'Task '||n,${sectioned?'array[label::text]':"'{}'::text[]"} from ids;
 ${sectioned?`insert into public.view_orders(id,user_id,ids) select 'group:'||${lit(id)}||':'||section,${lit(owner)},jsonb_build_array(task::text) from ids;`:''}
 insert into taskfold_private.workflow_benchmark select ${lit(id)},${lit(owner)},jsonb_build_object('user_id',${lit(owner)},'items',(
 select jsonb_agg(jsonb_build_object('table',table_name,'id',record->>'id','base',record-'created_at'-'updated_at') order by rank,record->>'id') from (
 select 'tasks' table_name,to_jsonb(t) record,1 rank from public.tasks t join ids on t.id=ids.task
 union all select 'projects',to_jsonb(p),4 from public.projects p where p.id=${lit(id)}
 ${sectioned?`union all select 'view_orders',to_jsonb(o),0 from public.view_orders o join ids on o.id='group:'||${lit(id)}||':'||ids.section and o.user_id=${lit(owner)}
 union all select 'labels',to_jsonb(l),2 from public.labels l join ids on l.id=ids.label
 union all select 'sections',to_jsonb(s),3 from public.sections s join ids on s.id=ids.section`:''}
 ) records));commit;`);
  const meta=await pg.scalar(`select jsonb_build_object('items',jsonb_array_length(body->'items'),'bodyBytes',octet_length(body::text)) from taskfold_private.workflow_benchmark where id=${lit(id)}`);
  return {id,...meta};
 }
 async function call(fixture,tag,budget=10000){
  const request=randomUUID();
  await pg.raw('analyze public.tasks;analyze public.projects;analyze public.sections;analyze public.labels;analyze public.view_orders');
  const outsideTasks=await pg.scalar(`select to_jsonb(count(*)) from public.tasks where project_id is distinct from ${lit(fixture.id)}::uuid`);
  const value=await pg.scalar(`begin;set local statement_timeout='${budget}ms';create temp table result(value jsonb) on commit drop;grant all on result to authenticated;${identity}
 do $r$declare started timestamptz:=clock_timestamp();r jsonb;begin begin
  r:=public.taskfold_undo_private_workflow(${lit(request)},(select body from taskfold_private.workflow_benchmark where id=${lit(fixture.id)}));
  insert into result values(jsonb_build_object('code',null,'milliseconds',extract(epoch from clock_timestamp()-started)*1000,'applied',r->'applied','returnedRows',jsonb_array_length(r->'rows')));
 exception when query_canceled then insert into result values(jsonb_build_object('code','57014','milliseconds',extract(epoch from clock_timestamp()-started)*1000));when others then insert into result values(jsonb_build_object('code',sqlstate,'milliseconds',extract(epoch from clock_timestamp()-started)*1000));end;end$r$;
 select value from result;commit;`);
  report.timings.push({tag,...fixture,...value,outsideTasks,budgetMS:budget});console.log(JSON.stringify(report.timings.at(-1)));return value;
 }
 const count=(f)=>pg.scalar(`select to_jsonb((select count(*) from public.tasks where project_id=${lit(f.id)})+(select count(*) from public.sections where project_id=${lit(f.id)})+(select count(*) from public.projects where id=${lit(f.id)})+(select count(*) from public.view_orders where id like 'group:'||${lit(f.id)}||':%')+(select count(*) from public.labels l where exists(select 1 from taskfold_private.workflow_benchmark b,jsonb_array_elements(b.body->'items') x where b.id=${lit(f.id)} and x->>'table'='labels' and x->>'id'=l.id::text)))`);
 const oldLarge=await seed(5000,true);check('full structured run has 20001 rows',oldLarge.items,20001);check('full structured run fits existing byte budget',oldLarge.bodyBytes<=16800000);
 const oldRefusal=await call(oldLarge,'legacy-structured-5000');check('legacy count cap rejects valid large run',oldRefusal.code,'22023');check('legacy refusal keeps all rows',await count(oldLarge),oldLarge.items);
 const oldSimple=await seed(1000,false);await call(oldSimple,'legacy-simple-1000',5000);
 const beforeACL=await pg.scalar("select to_jsonb(proacl::text) from pg_proc where oid='taskfold_private.undo_private_workflow(uuid,jsonb)'::regprocedure");await pg.raw(bulkSQL);
 check('replacement preserves private function ACL',await pg.scalar("select to_jsonb(proacl::text) from pg_proc where oid='taskfold_private.undo_private_workflow(uuid,jsonb)'::regprocedure"),beforeACL);
 const simple=await seed(1000,false),simpleResult=await call(simple,'bulk-simple-1000');check('bulk simple undo succeeds',simpleResult.code,null);check('bulk simple undo applied',simpleResult.applied);

 const after=await call(oldLarge,'bulk-structured-5000');check('bulk full structured undo succeeds',after.code,null);check('bulk full structured undo applied',after.applied);check('bulk full structured removes complete set',await count(oldLarge),0);
 check('small-run comparison keeps identical outside task count',report.timings.find(x=>x.tag==='legacy-simple-1000').outsideTasks,report.timings.find(x=>x.tag==='bulk-simple-1000').outsideTasks);
 check('small-run comparison keeps identical input size',report.timings.find(x=>x.tag==='legacy-simple-1000').bodyBytes,report.timings.find(x=>x.tag==='bulk-simple-1000').bodyBytes);
 const conflict=await seed(5000,true);await pg.raw(`update public.tasks set title='Later edited work' where id=(select (x->>'id')::uuid from taskfold_private.workflow_benchmark b,jsonb_array_elements(b.body->'items') x where b.id=${lit(conflict.id)} and x->>'table'='tasks' limit 1)`);
 const refused=await call(conflict,'bulk-structured-5000-edited');check('bulk edited run is wholly refused',refused.applied,false);check('bulk refusal confirms current owned rows',refused.returnedRows,conflict.items);check('bulk refusal keeps complete set',await count(conflict),conflict.items);
 // Many unrelated rows, including an RLS-hidden nested label reference. The
 // catalog check must scan outside tasks once, not once for every copied label.
 report.firstContextRemoved=await pg.close();pg=null;await initialize();await pg.raw(legacySQL);await pg.raw(bulkSQL);
 const hidden=await seed(5000,true);
 // Seed existing unrelated work in separate transactions, like normal native
 // inserts. One giant insert holds thousands of per-task advisory locks and
 // measures the fixture's lock table instead of Undo.
 for(let batch=0;batch<20;batch++)await pg.raw(`insert into public.tasks(id,user_id,title,subtasks) select gen_random_uuid(),${lit(other)},'Unrelated work',case when ${batch}=0 and n=1 then jsonb_build_array(jsonb_build_object('id','child','title','Later child','labels',jsonb_build_array((select x->>'id' from taskfold_private.workflow_benchmark b,jsonb_array_elements(b.body->'items') x where b.id=${lit(hidden.id)} and x->>'table'='labels' limit 1)))) else '[]' end from generate_series(1,1000) n;`);

 const hiddenResult=await call(hidden,'bulk-structured-5000-hidden-nested-label');check('large hidden nested reference refuses undo',hiddenResult.applied,false);check('large hidden refusal exposes only owned targets',hiddenResult.returnedRows,hidden.items);check('large hidden refusal keeps complete set',await count(hidden),hidden.items);
 report.advisors=await pg.advisors();check('no new warning/error findings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
 report.checkCount=Object.keys(report.checks).length;report.containerRemoved=await pg.close();pg=null;if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,timings:report.timings,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close()}
