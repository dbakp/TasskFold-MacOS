// Isolated synthetic schema upgrade. Never reads hosted configuration or tokens.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
const migration='20261026104450_task_activity_root_context.sql';
const source=await readFile(process.env.TASKFOLD_ROOT_CONTEXT_DRAFT ?? new URL('../../supabase/migrations/'+migration,import.meta.url),'utf8');
const report={migration,migrationSHA256:createHash('sha256').update(source).digest('hex'),checks:{},hostedChanged:false};
const check=(name,value,expected=true)=>{assert.deepEqual(value,expected,name);report.checks[name]=true};
const owner='11111111-1111-4111-8111-111111111111',member='11111111-1111-4111-8111-111111111112',outsider='11111111-1111-4111-8111-111111111113',task=randomUUID(),project=randomUUID(),heading=randomUUID();
const custodySource=await readFile(new URL('../../supabase/migrations/20261024022352_team_content_custody.sql',import.meta.url),'utf8');
const writerStart='create or replace function taskfold_private.capture_task_activity()';
const oldWriter=custodySource.slice(custodySource.indexOf(writerStart),custodySource.indexOf('end $$;',custodySource.indexOf(writerStart))+7);
let stripped=source.slice(source.indexOf(writerStart),source.indexOf('end $$;',source.indexOf(writerStart))+7);
stripped=stripped.replace('; meta jsonb;',';');
const annotationStart=stripped.indexOf(' -- Classify only the actual observed occurrence.');
const annotationEnd=stripped.indexOf(' if cardinality(kinds) > 0 then',annotationStart);
assert(annotationStart>=0 && annotationEnd>annotationStart);
stripped=stripped.slice(0,annotationStart)+stripped.slice(annotationEnd);
stripped=stripped.replace('before_state,after_state,root_context)','before_state,after_state)').replace('t.completion_version,kinds,b,a,meta);','t.completion_version,kinds,b,a);');
check('new writer preserves entire existing custody body',stripped,oldWriter);
let pg,step='start';
try {
 pg=await createPostgresFixture({advisors:true});report.serverVersion=pg.serverVersion;
 await pg.raw(await readFile(new URL('./task-node-activity-bootstrap.sql',import.meta.url),'utf8'));
 for(const name of ['20261006100647_task_activity_history.sql','20261006100920_task_activity_cascade_authorization.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
 // Minimal non-team bindings for this small upgrade fixture. The separate
 // custody regression loads the actual identity/cleanup schema and retained teams.
 await pg.raw('create table taskfold_private.team_content_projects(project_id uuid primary key);create table taskfold_private.team_content_tasks(task_id uuid primary key);alter table taskfold_private.team_content_projects enable row level security;alter table taskfold_private.team_content_tasks enable row level security;revoke all on taskfold_private.team_content_projects,taskfold_private.team_content_tasks from public,anon,authenticated');
 const custody=await readFile(new URL('../../supabase/migrations/20261024022352_team_content_custody.sql',import.meta.url),'utf8');
 for(const name of ['is_team_content_project','is_team_content_task']) {
  const start=custody.indexOf('create function taskfold_private.'+name+'('),end=custody.indexOf('$$;',start)+3;
  assert(start>=0 && end>start);await pg.raw(custody.slice(start,end));
  await pg.raw(`revoke all on function taskfold_private.${name}(uuid) from public,anon,authenticated`);
 }
 await pg.raw(await readFile(new URL('../../supabase/migrations/20261026095807_task_node_activity_history.sql',import.meta.url),'utf8'));
 await pg.raw(`insert into auth.users(id) values(${lit(owner)}),(${lit(member)}),(${lit(outsider)});insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner)},'Synthetic project');insert into public.project_collaborators(id,project_id,user_id,status) values(${lit(randomUUID())},${lit(project)},${lit(member)},'accepted')`);
 const as=(who,sql)=>pg.raw(`set role authenticated;set request.jwt.claim.sub=${lit(who)};${sql}`);
 const rows=()=>pg.scalar("select coalesce(jsonb_agg(to_jsonb(a) order by sequence),'[]') from public.task_activity a");
 const count=()=>pg.scalar('select count(*) from public.task_activity');
 await as(owner,`insert into public.tasks(id,user_id,title,description) values(${lit(task)},auth.uid(),'Private title','Private notes')`);
 const old=(await rows())[0];step='upgrade';await pg.raw(source);
 const preserved=(await rows())[0];check('old event has no invented type',preserved.root_context,null);delete preserved.root_context;check('upgrade preserves every existing event field',preserved,old);
 step='completion';await as(owner,`update public.tasks set completed=true,completed_at='2026-10-26T09:00:00Z',completion_version=1 where id=${lit(task)}`);
 let events=await rows(),event=events.at(-1);const generation=event.root_context.after_generation;
 check('ordinary completion keeps original event kind',event.kinds,['completed']);check('actual observed root types',event.root_context,{version:1,before_type:'task',after_type:'task',before_generation:generation,after_generation:generation});check('only bounded classification metadata',Object.keys(event.root_context).sort(),['after_generation','after_type','before_generation','before_type','version']);check('private content absent from context',/Private|title|notes/.test(JSON.stringify(event.root_context)),false);
 let n=await count();await as(owner,`update public.tasks set title='Renamed private title',description='Updated private notes' where id=${lit(task)}`);check('untracked edit invents no event',await count(),n);
 step='heading';await as(owner,`insert into public.tasks(id,user_id,is_heading,title) values(${lit(heading)},auth.uid(),true,'Private heading')`);event=(await rows()).at(-1);check('heading creation remains creation for old clients',event.kinds,['created']);check('heading classified at creation',event.root_context.after_type,'heading');check('creation has no prior occurrence',event.root_context.before_type,null);check('creation has no prior generation',event.root_context.before_generation,null);
 await as(owner,`update public.tasks set subtasks='[{"id":"child","title":"Private child","completed":false,"subtasks":[]}]'::jsonb where id=${lit(heading)}`);check('independent child trigger still records real child',await pg.scalar("select count(*) from public.task_node_activity where node_key='child' and kinds=array['created'] and work_after"),1);
 // A legacy writer can submit a bad heading completion; retain the real event
 // while its explicit classification prevents newer readers awarding work.
 await as(owner,`update public.tasks set completed=true,completed_at='2026-10-26T09:01:00Z' where id=${lit(heading)}`);event=(await rows()).at(-1);check('legacy bad heading write stays visibly classified',event.root_context.after_type,'heading');check('legacy event kind not rewritten',event.kinds,['completed']);
 await as(owner,`update public.tasks set completed=false,completed_at=null where id=${lit(heading)}`);n=await count();await as(owner,`update public.tasks set is_heading=false where id=${lit(heading)}`);check('type-only edit does not fabricate an old event kind',await count(),n);
 step='privacy';await as(owner,`update public.tasks set project_id=${lit(project)} where id=${lit(task)}`);
 const visible=who=>pg.scalar(`set role authenticated;set request.jwt.claim.sub=${lit(who)};select count(*) from public.task_activity`);
 check('private prior scope not exposed by new metadata',await visible(member),0);check('outsider cannot read metadata',await visible(outsider),0);
 await as(member,`update public.tasks set completed=false,completed_at=null,completion_version=2 where id=${lit(task)}`);event=(await rows()).at(-1);const memberEvent=event.id;check('actual caller remains actor',event.actor_id,member);check('collaborator sees same-scope event',await visible(member),1);
 await pg.raw(`delete from public.project_collaborators where user_id=${lit(member)}`);check('revocation still removes read access',await visible(member),0);
 step='incarnation';const next=randomUUID();await as(owner,`update public.tasks set task_generation=${lit(next)},due_date='2026-10-27' where id=${lit(task)}`);event=(await rows()).at(-1);check('prior generation retained independently',event.root_context.before_generation,generation);check('next generation retained independently',event.root_context.after_generation,next);check('generation change invents no completion',event.kinds,['rescheduled']);
 step='delete';await as(owner,`delete from public.tasks where id=${lit(heading)}`);event=(await rows()).at(-1);check('delete retains actual prior type',event.root_context.before_type,'task');check('delete has no next type or generation',[event.root_context.after_type,event.root_context.after_generation],[null,null]);
 check('client cannot mutate ledger',await pg.scalar("select to_json(has_table_privilege('authenticated','public.task_activity','INSERT,UPDATE,DELETE'))"),false);check('private writer not callable',await pg.scalar("select to_json(has_function_privilege('authenticated','taskfold_private.capture_task_activity()','EXECUTE'))"),false);
 step='cascade';await as(owner,`delete from public.projects where id=${lit(project)}`);event=(await rows()).at(-1);check('authorized project cascade preserves type annotation',event.root_context.after_type,'task');check('project cascade still records real move',event.kinds,['moved']);
 if(process.env.TASKFOLD_ROOT_HISTORY_ROWS)await writeFile(process.env.TASKFOLD_ROOT_HISTORY_ROWS,JSON.stringify(await rows(),null,2)+'\n');
 step='actor deletion';const beforeActorDelete=await count();await pg.raw(`delete from auth.users where id=${lit(member)}`);event=(await rows()).find(e=>e.id===memberEvent);check('deleted actor becomes unknown',event.actor_id,null);check('actor deletion retains every event',await count(),beforeActorDelete);check('actor deletion retains root classification',event.root_context.after_type,'task');
 await pg.raw(`delete from auth.users where id=${lit(owner)}`);check('account cascade never resurrects history',await count(),0);
 step='advisors';report.advisors=await pg.advisors();check('official advisors ran',report.advisors.ran);check('new private trigger has no advisor finding',report.advisors.result.filter(f=>/capture_task_activity|root_context/.test(JSON.stringify(f))),[]);
 console.log('PASS '+Object.keys(report.checks).length+' root-context database checks');
}catch(error){report.failedStep=step;report.error={name:error.name,code:error.code,message:error.message};process.exitCode=1;console.error('FAIL '+step+': '+error.message+' '+(error.code??''));}
finally {if(pg)report.ownedFixtureRemoved=await pg.close();const i=process.argv.indexOf('--report');if(i>=0)await writeFile(process.argv[i+1],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:Object.keys(report.checks).length,ownedFixtureRemoved:report.ownedFixtureRemoved,failedStep:report.failedStep}));}
