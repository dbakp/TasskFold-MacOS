// Owned PostgreSQL acceptance for the unchanged production SQL below.
// No hosted calls, real accounts, task edits, rollout changes or deployment.
import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadTeamProjectSchema} from './team-project-schema.mjs';
const report={checks:{},deployed:false,nativeRolloutEnabled:false,realDataChanged:false,hostedAcceptanceClaimed:false};
const check=(name,actual,expected)=>{assert.deepEqual(actual,expected,name);report.checks[name]=true;};
const json=x=>lit(JSON.stringify(x))+'::jsonb';
const migration='20261024172109_team_project_archiving.sql';
const people=Object.fromEntries(['owner','admin','creator','member','guest','outsider'].map(k=>[k,{id:randomUUID(),session:randomUUID()}]));
const team=randomUUID(),otherTeam=randomUUID(),root=randomUUID(),child=randomUUID(),closed=randomUUID(),leaf=randomUUID(),other=randomUUID(),personal=randomUUID();
const commands=[],reviews=[];
let pg;
try {
 pg=await createPostgresFixture({advisors:true});
 report.postgresVersion=pg.serverVersion;
 await loadTeamProjectSchema(pg.raw);
 const source=await readFile(new URL('../../supabase/migrations/'+migration,import.meta.url),'utf8');
 const hierarchy=await readFile(new URL('../../supabase/migrations/20261020174132_project_workflow_foundation.sql',import.meta.url),'utf8');
 const dependency=hierarchy.slice(hierarchy.indexOf('create function taskfold_private.guard_project_organization()'),hierarchy.indexOf('create table public.project_templates'));
 await pg.raw(dependency);
 report.inspectedHierarchyDependencySHA256=createHash('sha256').update(dependency).digest('hex');
 await pg.raw(await readFile(new URL('../../supabase/migrations/20261024163752_team_project_presentation.sql',import.meta.url),'utf8'));
 await pg.raw(source);
 report.migrationSHA256=createHash('sha256').update(source).digest('hex');
 // Minimal field that the real boundary expects from the later task-edit migration.
 // Task edits stay disabled; the actual access epoch/boundary SQL is unchanged.
 await pg.raw('alter table taskfold_private.team_project_config add column native_task_edits_enabled boolean not null default false');
 await pg.raw(await readFile(new URL('../../supabase/migrations/20261024094010_team_workspace_boundary.sql',import.meta.url),'utf8'));
 for(const [name,u] of Object.entries(people)) await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(name+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});insert into public.profiles(user_id,display_name) values(${lit(u.id)},${lit('Synthetic '+name)})`);
 await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(people.owner.id)},'Synthetic team'),(${lit(otherTeam)},${lit(people.outsider.id)},'Other team');`+Object.entries(people).map(([k,u])=>`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(k==='outsider'?otherTeam:team)},${lit(u.id)},${lit(['owner','admin','outsider'].includes(k)?'admin':k==='guest'?'guest':'member')});`).join(''));
 for(const id of [root,child,closed,leaf,other,personal]) await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(id)},${lit(people.creator.id)},'Project ${id.slice(0,8)}')`);
 for(const id of [root,child,closed,leaf,other]) await pg.raw(`insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(id)},${lit(id===other?otherTeam:team)},'private')`);
 await pg.raw(`update public.projects set parent_id=${lit(root)} where id in(${lit(child)},${lit(closed)});update public.projects set parent_id=${lit(closed)} where id=${lit(leaf)};update public.projects set is_archived=true where id=${lit(closed)};`+[root,child,closed,leaf].map(id=>`insert into taskfold_private.team_project_grants values(${lit(id)},${lit(team)},${lit(people.creator.id)},'manager');`).join(''));
 const task=randomUUID(),section=randomUUID(),comment=randomUUID(),object=randomUUID();
 await pg.raw(`insert into public.tasks(id,user_id,project_id,title) values(${lit(task)},${lit(people.creator.id)},${lit(child)},'Preserve every task field');insert into public.sections(id,user_id,project_id,name) values(${lit(section)},${lit(people.creator.id)},${lit(child)},'Preserve section');insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) select ${lit(comment)},id,task_generation,project_id,user_id,'Preserve discussion' from public.tasks where id=${lit(task)};insert into storage.objects(id,bucket_id,name,owner,owner_id) values(${lit(object)},'task-attachments',${lit(people.creator.id+'/archive-proof')},${lit(people.creator.id)},${lit(people.creator.id)});insert into taskfold_private.team_content_files values(${lit(object)},${lit(child)})`);
 const run=(who,expression,opts={})=>{
  const u=people[who];return pg.scalar(`begin;set application_name=${lit(opts.app??'archive-'+randomUUID().slice(0,8))};create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;${opts.statement?`create function pg_temp.probe() returns jsonb language plpgsql security invoker as $probe$declare n integer;begin ${opts.statement};get diagnostics n=row_count;return to_jsonb(n);end$probe$;`:""}set local role ${opts.role??'authenticated'};set local request.jwt.claim.sub=${lit(u.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:u.id,session_id:opts.session===undefined?u.session:opts.session}))};do $r$begin begin insert into result values((${expression}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,150));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`);
 };
 const dml=(who,statement,opts={})=>run(who,'pg_temp.probe()',{...opts,statement});
 const rpc=async(who,action,body,opts)=>{
  const r=await run(who,`public.taskfold_team_projects(${lit(action)},${json(body)})`,opts);
  if(!r.code && ['rename','archive','unarchive'].includes(action))commands.push({account:people[who].id,action,body,result:r.value});
  if(!r.code && action==='review_structure')reviews.push({account:people[who].id,body,result:r.value});
  return r;
 };
 const review=(who='owner',operation='archive',p=root)=>rpc(who,'review_structure',{team_id:team,project_id:p,operation});
 const request=async(action,p=root,who='owner',extra={})=>{
  const body={team_id:team,project_id:p,request_id:randomUUID(),issued_at:new Date().toISOString(),team_revision:await pg.scalar(`select to_jsonb(revision) from taskfold_private.teams where id=${lit(team)}`),revision:await pg.scalar(`select to_jsonb(revision) from taskfold_private.team_content_projects where project_id=${lit(p)}`)};
  if(action==='rename')body.name='Renamed design workshop';
  else {const r=await review(who,action,p);assert.equal(r.code,null,JSON.stringify(r));body.tree_token=r.value.tree_token;body.affected_count=r.value.affected_count;}
  return {...body,...extra};
 };
 const succeed=async(name,who,action,body)=>{const r=await rpc(who,action,body);check(name,r.code,null);return r.value;};
 const state=()=>pg.scalar(`select jsonb_agg(jsonb_build_object('id',p.id,'parent',p.parent_id,'own',p.is_archived,'inherited',p.ancestor_archived,'name',p.name,'revision',c.revision) order by p.id) from public.projects p join taskfold_private.team_content_projects c on c.project_id=p.id where c.team_id=${lit(team)}`);
 const content=()=>pg.scalar(`select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(x) order by id) from public.tasks x),'sections',(select jsonb_agg(to_jsonb(x) order by id) from public.sections x),'comments',(select jsonb_agg(to_jsonb(x) order by id) from public.task_comments x),'files',(select jsonb_agg(to_jsonb(x) order by id) from storage.objects x),'custody',(select jsonb_agg(to_jsonb(x) order by task_id) from taskfold_private.team_content_tasks x),'grants',(select jsonb_agg(to_jsonb(x) order by project_id,user_id) from taskfold_private.team_project_grants x))`);
 const preserved=await content();
 check('reads default off',(await review()).code,'PT503');
 await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true;update taskfold_private.team_config set enabled=true');
 const baseline=await state();
 const usage=()=>pg.scalar(`select jsonb_build_array(day_operations,(select count(*) from taskfold_private.team_project_commands)) from taskfold_private.teams where id=${lit(team)}`);
 const used=await usage();
 const reviewed=await review();check('owner reviews entire four-project branch',reviewed.value?.affected_count,4);check('review root and protocol',[reviewed.value.id,reviewed.value.project_state_protocol],[root,1]);
 check('review preserves project data',await state(),baseline);check('review has no receipt or budget change',await usage(),used);
 for(const who of ['member','guest','outsider'])check(who+' cannot review branch',(await review(who)).code,who==='outsider'?'PT404':'42501');
 check('admin can review',(await review('admin')).code,null);check('explicit manager can review',(await review('creator')).code,null);
 const pending=await request('archive');
 for(const [label,patch,code] of [['extra key',{surprise:true},'22023'],['stale revision',{revision:0},'PT409'],['stale team revision',{team_revision:0},'PT409'],['fractional revision',{revision:1.5},'PT409'],['string revision',{revision:'1'},'PT409'],['wrong branch',{tree_token:'a'.repeat(64)},'PT409'],['wrong count',{affected_count:3},'PT409'],['fraction count',{affected_count:4.1},'PT409'],['string count',{affected_count:'4'},'PT409'],['expired',{issued_at:new Date(Date.now()-16*60e3).toISOString()},'PT409'],['future',{issued_at:new Date(Date.now()+2*60e3).toISOString()},'PT409'],['bad date',{issued_at:'yesterday'},'22023']])check(label,(await rpc('owner','archive',{...pending,...patch})).code,code);
 check('missing field',(await rpc('owner','archive',Object.fromEntries(Object.entries(pending).filter(([k])=>k!=='tree_token')))).code,'22023');
 check('revoked session',(await rpc('owner','archive',pending,{session:randomUUID()})).code,'28000');
 check('anonymous denied',(await rpc('owner','archive',pending,{role:'anon'})).code,'42501');
 check('service role cannot call public RPC',(await rpc('owner','archive',pending,{role:'service_role'})).code,'42501');
 check('invalid review operation',(await rpc('owner','review_structure',{team_id:team,project_id:root,operation:'delete'})).code,'22023');
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(child)} and user_id=${lit(people.creator.id)}`);
 check('inaccessible child denies complete review',(await review('creator')).code,'42501');
 check('inaccessible child denies mutation',(await rpc('creator','archive',pending)).code,'42501');
 await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(child)},${lit(team)},${lit(people.creator.id)},'manager')`);
 const renamed=await request('rename');const renameReceipt=await succeed('rename accepted','creator','rename',renamed);
 check('rename changes only root name',(await state()).filter(x=>x.id!==root),baseline.filter(x=>x.id!==root));
 check('root name saved',(await state()).find(x=>x.id===root).name,renamed.name);
 check('rename receipt replay',(await rpc('creator','rename',renamed)).value,renameReceipt);
 check('rename nonce body cannot change',(await rpc('creator','rename',{...renamed,name:'Other'})).code,'PT409');
 check('rename rejects no-op',(await rpc('owner','rename',await request('rename'))).code,'PT409');
 check('rename rejects multiline',(await rpc('owner','rename',await request('rename',root,'owner',{name:'Bad\nname'}))).code,'22023');
 check('stale branch rename invalidates archive',(await rpc('owner','archive',pending)).code,'PT409');
 const beforeArchive=await state();
 const boundary=()=>run('owner','public.taskfold_workspace_boundary()');
 const beforeBoundary=(await boundary()).value.token;
 const archive=await request('archive');const archiveReceipt=await succeed('archive accepted','owner','archive',archive);
 check('archive acknowledges complete branch',[archiveReceipt.is_archived,archiveReceipt.affected_count,archiveReceipt.revision],[true,4,archive.revision+1]);
 const archived=await state();
 check('root archived',archived.find(x=>x.id===root).own,true);
 check('all descendants inherit archive',archived.filter(x=>x.id!==root).every(x=>x.inherited),true);
 check('all own child archive flags preserved',archived.filter(x=>x.id!==root).map(x=>[x.id,x.own]),beforeArchive.filter(x=>x.id!==root).map(x=>[x.id,x.own]));
 check('branch revisions each increment exactly once',archived.every(x=>x.revision===beforeArchive.find(y=>x.id===y.id).revision+1),true);
 check('boundary changes after archive',(await boundary()).value.token!==beforeBoundary,true);
 check('boundary projects are all archived',(await boundary()).value.projects.filter(x=>[root,child,closed,leaf].includes(x.id)).every(x=>x.archived),true);
 check('lost archive response replays original receipt',(await rpc('owner','archive',archive)).value,archiveReceipt);
 check('replay leaves branch unchanged',await state(),archived);
 check('replay cannot use another actor',(await rpc('admin','archive',archive)).code,'PT409');
 const get=await rpc('owner','get',{team_id:team,project_id:root});check('detail publishes own/inherited metadata',[get.value.project_state_protocol,get.value.is_archived,get.value.ancestor_archived],[1,true,false]);
 const list=await rpc('owner','list',{team_id:team});check('catalog keeps archived projects visible',list.value.projects.length,4);check('catalog carries project state protocol',list.value.projects.every(x=>x.project_state_protocol===1),true);
 check('child cannot reopen under archived parent',(await review('owner','unarchive',closed)).code,'PT409');
 const reopen=await request('unarchive');const reopenReceipt=await succeed('reopen accepted','owner','unarchive',reopen);
 const restored=await state();check('reopen restores original archive projections',restored.map(x=>[x.id,x.own,x.inherited]),beforeArchive.map(x=>[x.id,x.own,x.inherited]));
 check('reopen acknowledges branch',[reopenReceipt.is_archived,reopenReceipt.affected_count],[false,4]);
 check('reopen replay',(await rpc('owner','unarchive',reopen)).value,reopenReceipt);
 check('archive replay after later reopen returns only original receipt',(await rpc('owner','archive',archive)).value,archiveReceipt);
 check('old archive replay does not reapply',await state(),restored);
 check('all tasks discussions files and grants preserved',await content(),preserved);
 // Lost review: a new child cannot be silently included in an already reviewed request.
 const stale=await request('archive');const newChild=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(newChild)},${lit(people.creator.id)},'New child');insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(newChild)},${lit(team)});update public.projects set parent_id=${lit(root)} where id=${lit(newChild)}`);
 check('added descendant invalidates review token',(await rpc('owner','archive',stale)).code,'PT409');
 // A private/foreign or personal descendant injected by trusted operator is rejected in full.
 await pg.raw(`alter table public.projects disable trigger aa_taskfold_workspace_link;update public.projects set parent_id=${lit(root)} where id=${lit(personal)};alter table public.projects enable trigger aa_taskfold_workspace_link`);
 check('personal descendant blocks review',(await review()).code,'42501');
 await pg.raw(`alter table public.projects disable trigger aa_taskfold_workspace_link;update public.projects set parent_id=null where id=${lit(personal)};update public.projects set parent_id=${lit(root)} where id=${lit(other)};alter table public.projects enable trigger aa_taskfold_workspace_link`);
 check('foreign descendant blocks review',(await review()).code,'42501');
 await pg.raw(`update public.projects set parent_id=null where id=${lit(other)}`);
 // Corrupt old data is not traversed indefinitely. Trusted fixture bypass only.
 await pg.raw(`alter table public.projects disable trigger taskfold_project_organization;update public.projects set parent_id=${lit(child)} where id=${lit(root)};alter table public.projects enable trigger taskfold_project_organization`);
 check('corrupt cycle fails bounded review',(await review()).code,'54000');
 await pg.raw(`alter table public.projects disable trigger taskfold_project_organization;update public.projects set parent_id=null where id=${lit(root)};alter table public.projects enable trigger taskfold_project_organization`);
 // Archive is narrowing/recovery even with setup paused, team archived and budget full.
 const recovery=await request('archive');
 await pg.raw(`update taskfold_private.team_config set enabled=false;update taskfold_private.teams set state='archived',usage_day=current_date,day_operations=2000 where id=${lit(team)}`);
 // Team revision is intentionally current; unrelated team transitions require a fresh review.
 recovery.team_revision=await pg.scalar(`select to_jsonb(revision) from taskfold_private.teams where id=${lit(team)}`);
 await succeed('archive allowed while paused archived quota full','owner','archive',recovery);
 check('reopen denied while setup paused',(await review('owner','unarchive')).code,'PT503');
 check('rename denied while setup paused',(await rpc('owner','rename',await request('rename',root,'owner',{name:'New name'}))).code,'PT503');
 await pg.raw('update taskfold_private.team_config set enabled=true');
 check('reopen denied for archived team',(await review('owner','unarchive')).code,'PT409');
 await pg.raw(`update taskfold_private.teams set state='active' where id=${lit(team)}`);
 const quotaRequest=await request('unarchive');check('reopen obeys quota',(await rpc('owner','unarchive',quotaRequest)).code,'PT429');
 await pg.raw(`update taskfold_private.teams set day_operations=0 where id=${lit(team)}`);
 await succeed('reopen recovers after pause lifted','owner','unarchive',await request('unarchive'));
 check('no metadata scopes remain',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_project_metadata_operations'),0);
 for(const role of ['authenticated','anon','service_role'])check(role+' cannot inject metadata scope',(await dml('owner',`insert into taskfold_private.team_project_metadata_operations values(txid_current(),${lit(people.owner.id)},${lit(team)},${lit(root)},${lit(root)},'rename')`,{role})).code,'42501');
 // Native RLS returns zero rows; a service caller with a user subject reaches the
 // trigger but still cannot bypass it. Personal legacy updates remain possible.
 check('native direct project write closed',(await dml('owner',`update public.projects set name='Bypass' where id=${lit(root)}`)).value,0);
 check('service direct project write closed',(await dml('owner',`update public.projects set name='Bypass' where id=${lit(root)}`,{role:'service_role'})).code,'42501');
 check('service delete still closed',(await dml('owner',`delete from public.projects where id=${lit(root)}`,{role:'service_role'})).code,'42501');
 check('task writes remain closed',(await dml('owner',`update public.tasks set title='Bypass' where id=${lit(task)}`,{role:'service_role'})).code,'42501');
 check('comment writes remain closed',(await dml('owner',`update public.task_comments set body='Bypass' where id=${lit(comment)}`,{role:'service_role'})).code,'42501');
 check('personal project edit unaffected',(await dml('creator',`update public.projects set name='Personal rename' where id=${lit(personal)}`)).value,1);
 // Concurrent genuine requests serialize on the team lock; one wins, the other
 // must be reviewed again. A task read/write lock also blocks metadata mutation.
 const parallel=await request('archive');const twin={...parallel,request_id:randomUUID()};
 const results=await Promise.all([rpc('owner','archive',parallel),rpc('admin','archive',twin)]);
 check('concurrent branch commands have one winner',results.map(x=>x.code).sort(),[null,'PT409'].sort());
 await succeed('reopen after concurrent archive','owner','unarchive',await request('unarchive'));
 const blocked=await request('archive');const holder=await pg.hold(`begin;select 1 from public.projects where id=${lit(child)} for share;`);
 const waiting=rpc('owner','archive',blocked,{app:'archive-task-lock'});
 await pg.waitForLock('archive-task-lock',holder.pid);
 await holder.release('commit');
 check('archive waits for task project lock then succeeds',(await waiting).code,null);
 await succeed('final reopen','owner','unarchive',await request('unarchive'));
 check('content preserved through concurrency',await content(),preserved);
 // Scope strictness: even a trusted injected private scope cannot change custody,
 // hierarchy, own archive flag of a descendant, or delete a project.
 for(const [label,operation,p,sql] of [
  ['rename cannot move project','rename',root,`update public.projects set parent_id=${lit(child)} where id=${lit(root)}`],
  ['archive cannot rename descendant','archive',child,`update public.projects set name='Smuggled' where id=${lit(child)}`],
  ['archive cannot set child own flag','archive',child,`update public.projects set is_archived=true where id=${lit(child)}`],
  ['rename cannot delete','rename',newChild,`delete from public.projects where id=${lit(newChild)}`]
 ]) {
  const u=people.owner;
  const result=await pg.scalar(`begin;insert into taskfold_private.team_project_metadata_operations values(txid_current(),${lit(u.id)},${lit(team)},${lit(p)},${lit(operation==='rename'?p:root)},${lit(operation)});create temp table proof(code text) on commit drop;grant all on proof to service_role;set local role service_role;set local request.jwt.claim.sub=${lit(u.id)};do $r$begin begin ${sql};insert into proof values(null);exception when others then insert into proof values(sqlstate);end;end$r$;select to_jsonb(code) from proof;rollback;`);
  check(label,result,'42501');
 }
 // Production hierarchy already bounds normal writes. Prove the reviewed
 // handler also rejects a pre-existing over-deep branch without partial edits.
 const deep=Array.from({length:21},()=>randomUUID());
 await pg.raw('begin;alter table public.projects disable trigger taskfold_project_organization;'+deep.map(id=>`insert into public.projects(id,user_id,name) values(${lit(id)},${lit(people.creator.id)},'Depth proof');insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(id)},${lit(team)});`).join('')+deep.slice(1).map((id,i)=>`update public.projects set parent_id=${lit(deep[i])} where id=${lit(id)};`).join('')+'alter table public.projects enable trigger taskfold_project_organization;commit;');
 check('over-deep existing branch is rejected',(await review('owner','archive',deep[0])).code,'54000');
 // Existing whole-team cleanup keeps its distinct trusted transaction scope.
 // Empty synthetic project only: no retained task/file custody to clean here.
 const cleanupTeam=randomUUID(),cleanupProject=randomUUID();
 await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(cleanupTeam)},${lit(people.owner.id)},'Cleanup proof');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(cleanupTeam)},${lit(people.owner.id)},'admin');insert into public.projects(id,user_id,name) values(${lit(cleanupProject)},${lit(people.creator.id)},'Empty cleanup proof');insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(cleanupProject)},${lit(cleanupTeam)})`);
 const cleanupBody={team_id:cleanupTeam,request_id:randomUUID(),issued_at:new Date().toISOString(),revision:1};
 const cleanup=await run('owner',`public.taskfold_teams('delete',${json(cleanupBody)})`);
 check('existing empty whole-team cleanup remains authorized',cleanup.code,null);
 check('cleanup removed only its empty project',await pg.scalar(`select to_jsonb(count(*)) from public.projects where id=${lit(cleanupProject)}`),0);
 check('whole-team transaction scope removed',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_content_operations'),0);
 report.advisors=await pg.advisors();
 check('no new security or performance warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
 report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
 if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');
 if(process.argv[3])await writeFile(process.argv[3],JSON.stringify({reviews,commands},null,2)+'\n');
 console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
} finally {if(pg)await pg.close();}
