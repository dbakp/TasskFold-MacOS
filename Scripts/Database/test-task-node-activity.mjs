// Owned synthetic PostgreSQL only. No hosted URL, user task or credential is read.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
const migration='20261026095807_task_node_activity_history.sql';
const source=await readFile(process.env.TASKFOLD_NODE_ACTIVITY_DRAFT ?? new URL('../../supabase/migrations/'+migration,import.meta.url),'utf8');
const report={checks:{},migration,migrationSHA256:createHash('sha256').update(source).digest('hex'),hostedChanged:false};
const check=(name,a,b=true)=>{assert.deepEqual(a,b,name);report.checks[name]=true};
const json=x=>lit(JSON.stringify(x))+'::jsonb';
const users={owner:'11111111-1111-4111-8111-111111111111',member:'11111111-1111-4111-8111-111111111112',outsider:'11111111-1111-4111-8111-111111111113',next:'11111111-1111-4111-8111-111111111114'};
const root='22222222-2222-4222-8222-222222222222',project=randomUUID();
const node=(id,fields={})=>({id,title:'Private title '+id,completed:false,subtasks:[],...fields});
let pg,step='start';
try {
 pg=await createPostgresFixture({advisors:true});report.serverVersion=pg.serverVersion;
 await pg.raw(await readFile(new URL('./task-node-activity-bootstrap.sql',import.meta.url),'utf8'));
 for(const name of ['20261006100647_task_activity_history.sql','20261006100920_task_activity_cascade_authorization.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
 await pg.raw(source);check('schema loaded',true);
 const as=(who,sql)=>pg.raw(`set role authenticated;set request.jwt.claim.sub=${lit(users[who])};${sql}`);
 const visible=who=>pg.scalar(`set role authenticated;set request.jwt.claim.sub=${lit(users[who])};select coalesce(jsonb_agg(to_jsonb(a) order by sequence),'[]') from public.task_node_activity a`);
 const ledger=()=>pg.scalar('select coalesce(jsonb_agg(to_jsonb(a) order by sequence),\'[]\') from public.task_node_activity a');
 const count=()=>pg.scalar('select count(*) from public.task_node_activity');
 const save=tree=>as('owner',`update public.tasks set subtasks=${json(tree)} where id=${lit(root)}`);
 await pg.raw(`insert into auth.users(id) values${Object.values(users).map(id=>'('+lit(id)+')').join(',')};insert into public.projects(id,user_id,name) values(${lit(project)},${lit(users.owner)},'Synthetic project');insert into public.project_collaborators(id,project_id,user_id,status) values(${lit(randomUUID())},${lit(project)},${lit(users.member)},'accepted'),(${lit(randomUUID())},${lit(project)},${lit(users.next)},'accepted')`);
 let tree=[node('a',{description:'Private description',labels:['private-label'],attachments:[{secret:'do not store'}]}),node('phase',{is_heading:true,children_unused:'opaque',subtasks:[node('b',{completed:true})]}),node('parent',{subtasks:[node('checklist')]})];
 step='create';await as('owner',`insert into public.tasks(id,user_id,is_heading,subtasks) values(${lit(root)},auth.uid(),true,${json(tree)})`);
 let events=await ledger();check('creation per stable child including heading context',events.length,5);check('creation never invents a completion',events.every(e=>JSON.stringify(e.kinds)==='["created"]'));
 check('nearest ordinary work only',events.filter(e=>e.work_after).map(e=>e.node_key).sort(),['a','b','parent']);
 check('ordinary checklist not counted as work',events.find(e=>e.node_key==='checklist').work_after,false);
 check('no titles notes labels or attachments persisted',/Private|private-label|do not store|children_unused/.test(JSON.stringify(events)),false);
 check('legacy parent ledger remains independent',await pg.scalar('select count(*) from public.task_activity'),1);
 step='completion';tree[0].completed=true;tree[0].completed_at='2026-10-20T09:00:00Z';await save(tree);
 events=await ledger();let complete=events.at(-1);check('actual independent child completion',complete.kinds,['completed']);check('actor is actual DML caller',complete.actor_id,users.owner);check('chosen offline completion time retained',new Date(complete.effective_at).toISOString(),'2026-10-20T09:00:00.000Z');check('received and effective times separate',new Date(complete.recorded_at)>=new Date(complete.effective_at));
 let n=await count();await save(tree);check('equivalent DML retry emits nothing',await count(),n);
 tree[0].completed_at='2026-10-20T11:00:00+02:00';await save(tree);check('equivalent timezone spelling emits nothing',await count(),n);
 tree[0].title='Changed private title';tree[0].description='Changed private notes';tree[0].priority=1;await save(tree);check('untracked edits emit nothing',await count(),n);
 step='multi';tree[1].subtasks[0].completed=false;tree[2].subtasks[0].completed=true;tree[2].subtasks[0].completed_at='2026-10-20T10:00:00Z';await save(tree);events=await ledger();check('compound sibling transitions recorded separately',events.slice(n).map(e=>[e.node_key,e.kinds[0]]).sort(),[['b','reopened'],['checklist','completed']]);
 check('checklist completion remains non-work',events.findLast(e=>e.node_key==='checklist').work_after,false);
 step='move';const a=tree.shift();tree[0].subtasks.push(a);await save(tree);events=await ledger();const moved=events.findLast(e=>e.node_key==='a');check('path move does not change node identity',moved.before_path,['a']);check('new current path retained',moved.after_path,['phase','a']);check('within-root move not a completion',moved.kinds,['moved']);
 step='scope';await as('owner',`update public.tasks set is_heading=false where id=${lit(root)}`);events=await ledger();check('grouping change recorded without invented completion',events.filter(e=>e.kinds.includes('scope_changed')).every(e=>!e.kinds.includes('completed')));check('ordinary root makes descendants checklist work',events.filter(e=>e.kinds.includes('scope_changed')).every(e=>!e.work_after));
 await as('owner',`update public.tasks set is_heading=true where id=${lit(root)}`);
 step='type';tree[1].is_heading=true;await save(tree);events=await ledger();check('type conversion has explicit type event',events.findLast(e=>e.node_key==='parent').kinds,['type_changed']);check('descendant promotion is grouping only',events.findLast(e=>e.node_key==='checklist').kinds,['scope_changed']);
 step='rls';check('private history hidden from collaborator',await visible('member'),[]);check('history hidden from outsider',await visible('outsider'),[]);
 await as('owner',`update public.tasks set project_id=${lit(project)} where id=${lit(root)}`);check('private-to-shared prior metadata not disclosed',await visible('member'),[]);
 tree[0].subtasks[0].completed=true;tree[0].subtasks[0].completed_at='2026-10-20T12:00:00Z';await save(tree);
 check('collaborator sees only same-project transition',(await visible('member')).map(e=>e.node_key),['b']);
 await pg.raw(`delete from public.project_collaborators where user_id=${lit(users.member)}`);check('revoked collaborator loses history',await visible('member'),[]);
 check('authenticated cannot write ledger',await pg.scalar("select to_json(has_table_privilege('authenticated','public.task_node_activity','INSERT,UPDATE,DELETE'))"),false);
 check('anonymous cannot read ledger',await pg.scalar("select to_json(has_table_privilege('anon','public.task_node_activity','SELECT'))"),false);
 check('no callable writer API',await pg.scalar("select to_json(has_function_privilege('authenticated','taskfold_private.capture_task_node_activity()','EXECUTE'))"),false);
 check('table RLS enabled',await pg.scalar("select to_json(relrowsecurity) from pg_class where oid='public.task_node_activity'::regclass"));
 step='generation';const oldGen=(await ledger())[0].task_generation,newGen=randomUUID();await as('owner',`update public.tasks set task_generation=${lit(newGen)} where id=${lit(root)}`);events=await ledger();check('new incarnation gets distinct created subjects',events.filter(e=>e.task_generation===newGen).every(e=>JSON.stringify(e.kinds)==='["created"]'));check('old incarnation gets deletion records',events.filter(e=>e.task_generation===oldGen&&e.kinds.includes('deleted')).length,5);
 step='owner transfer';const transferGen=randomUUID();await as('owner',`update public.tasks set user_id=${lit(users.next)},task_generation=${lit(transferGen)} where id=${lit(root)}`);events=await ledger();check('new occurrence attributed to new owner',events.filter(e=>e.task_generation===transferGen).every(e=>e.user_id===users.next));
 check('prior owner history is not reassigned',(await visible('next')).every(e=>e.user_id===users.next&&e.task_generation===transferGen));
 step='delete';const beforeDelete=await count();await as('next',`delete from public.tasks where id=${lit(root)}`);check('root deletion records every actual child',await count(),beforeDelete+5);
 step='gap';const gapRoot=randomUUID();await as('owner',`insert into public.tasks(id,user_id,is_heading,subtasks) values(${lit(gapRoot)},auth.uid(),true,${json([node('duplicate'),node('duplicate')])})`);events=await ledger();let gaps=events.filter(e=>e.task_id===gapRoot);check('ambiguous tree emits one explicit gap',gaps.map(e=>e.kinds),[['coverage_gap']]);
 await as('owner',`update public.tasks set subtasks=${json([node('recovered')])} where id=${lit(gapRoot)}`);events=await ledger();gaps=events.filter(e=>e.task_id===gapRoot);check('repair never backfills fictional history',gaps.map(e=>e.kinds),[['coverage_gap'],['coverage_gap']]);
 await as('owner',`update public.tasks set subtasks=${json([node('recovered',{completed:true,completed_at:'2026-10-20T12:00:00Z'})])} where id=${lit(gapRoot)}`);events=await ledger();check('recording resumes on known real transition',events.findLast(e=>e.task_id===gapRoot).kinds,['completed']);
 step='unsupported trees';
 for (const [name,children] of [
  ['future type',[node('future',{is_heading:'future'})]],
  ['invalid completion boolean',[node('boolean',{completed:'yes'})]],
  ['invalid revision',[node('revision',{completion_version:-1})]],
  ['invalid date',[node('date',{due_date:'not-a-day'})]],
  ['legacy string',['Legacy private title']],
 ]) {
  const id=randomUUID();await as('owner',`insert into public.tasks(id,user_id,is_heading,subtasks) values(${lit(id)},auth.uid(),true,${json(children)})`);
  const actual=await pg.scalar(`select jsonb_agg(kinds) from public.task_node_activity where task_id=${lit(id)}`);
  check(name+' records gap without rejecting task preservation',actual,[['coverage_gap']]);
 }
 step='actor deletion';await as('owner',`update public.tasks set project_id=${lit(project)} where id=${lit(gapRoot)}`);await as('next',`update public.tasks set subtasks=${json([node('recovered')])} where id=${lit(gapRoot)}`);const actorEvent=(await ledger()).at(-1).id;
 await pg.raw(`delete from auth.users where id=${lit(users.next)}`);events=await ledger();check('account deletion cascades without ledger resurrection',events.some(e=>e.user_id===users.next),false);check('deleted actor becomes unknown without lost history',events.find(e=>e.id===actorEvent).actor_id,null);
 step='large tree';const wideRoot=randomUUID();let started=performance.now();await as('owner',`insert into public.tasks(id,user_id,is_heading,subtasks) select ${lit(wideRoot)},auth.uid(),true,jsonb_agg(jsonb_build_object('id','wide-'||i,'title','Synthetic wide task','completed',false,'subtasks','[]'::jsonb) order by i) from generate_series(0,9999) i`);report.create10000ms=Math.round(performance.now()-started);started=performance.now();await as('owner',`update public.tasks set subtasks=jsonb_set(jsonb_set(subtasks,'{5000,completed}','true'),'{5000,completed_at}','"2026-10-20T13:00:00Z"') where id=${lit(wideRoot)}`);report.update10000ms=Math.round(performance.now()-started);check('large tree records only actual changed child',await pg.scalar(`select count(*) from public.task_node_activity where task_id=${lit(wideRoot)} and kinds=array['completed']`),1);
 const parity=await pg.scalar(`select coalesce(jsonb_agg(to_jsonb(a) order by sequence),'[]') from public.task_node_activity a where task_id<>${lit(wideRoot)}`);if(process.env.TASKFOLD_NODE_ACTIVITY_ROWS)await writeFile(process.env.TASKFOLD_NODE_ACTIVITY_ROWS,JSON.stringify(parity,null,2)+'\n');
 step='advisors';report.advisors=await pg.advisors();check('official advisors ran',report.advisors.ran);check('no advisor finding on new child-history objects',report.advisors.result.filter(f=>/task_node_activity|node_activity/.test(JSON.stringify(f))),[]);
 console.log('PASS '+Object.keys(report.checks).length+' child-ledger database checks');
}catch(error){report.failedStep=step;report.error={name:error.name,code:error.code,message:error.message};process.exitCode=1;console.error('FAIL '+step+': '+error.message+' '+(error.code??''));}
finally{if(pg)report.ownedFixtureRemoved=await pg.close();const i=process.argv.indexOf('--report');if(i>=0)await writeFile(process.argv[i+1],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:Object.keys(report.checks).length,ownedFixtureRemoved:report.ownedFixtureRemoved,create10000ms:report.create10000ms,update10000ms:report.update10000ms,failedStep:report.failedStep}));}
