// Real owned PostgreSQL. No hosted schema, rollout flags or user data changes.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadTeamProjectSchema} from './team-project-schema.mjs';
const migration='20261024182336_team_project_hierarchy.sql';
const report={checks:{},deployed:false,nativeRolloutEnabled:false,realDataChanged:false};
const check=(name,actual,expected)=>{assert.deepEqual(actual,expected,name);report.checks[name]=true;};
const json=x=>lit(JSON.stringify(x))+'::jsonb';
const users=Object.fromEntries(['owner','manager','member','guest','outside'].map(x=>[x,{id:randomUUID(),session:randomUUID()}]));
const team=randomUUID(),otherTeam=randomUUID(),root=randomUUID(),child=randomUUID(),leaf=randomUUID(),destination=randomUUID(),foreign=randomUUID();
const reviews=[],commands=[];
let pg;
try {
 pg=await createPostgresFixture({advisors:true});report.postgresVersion=pg.serverVersion;await loadTeamProjectSchema(pg.raw);
 const original=await readFile(new URL('../../supabase/migrations/20261020174132_project_workflow_foundation.sql',import.meta.url),'utf8');
 await pg.raw(original.slice(original.indexOf('create function taskfold_private.guard_project_organization()'),original.indexOf('create table public.project_templates')));
 for(const file of ['20261024163752_team_project_presentation.sql','20261024172109_team_project_archiving.sql',migration]) {
  const source=await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8');await pg.raw(source);
  (report.migrationSHA256??={})[file]=createHash('sha256').update(source).digest('hex');
 }
 await pg.raw('alter table taskfold_private.team_project_config add column native_task_edits_enabled boolean not null default false');
 await pg.raw(await readFile(new URL('../../supabase/migrations/20261024094010_team_workspace_boundary.sql',import.meta.url),'utf8'));
 for(const [name,u] of Object.entries(users)) await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(name+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});insert into public.profiles(user_id,display_name) values(${lit(u.id)},${lit('Synthetic '+name)})`);
 await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(users.owner.id)},'Hierarchy workshop'),(${lit(otherTeam)},${lit(users.outside.id)},'Other team');`+Object.entries(users).map(([name,u])=>`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(name==='outside'?otherTeam:team)},${lit(u.id)},${lit(['owner','outside'].includes(name)?'admin':name==='guest'?'guest':'member')});`).join(''));
 for(const [id,creator] of [[root,'owner'],[child,'member'],[leaf,'manager'],[destination,'member'],[foreign,'outside']]) {
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(id)},${lit(users[creator].id)},${lit('Project '+id.slice(0,8))});insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(id)},${lit(id===foreign?otherTeam:team)},'private')`);
 }
 await pg.raw(`update public.projects set parent_id=${lit(root)} where id=${lit(child)};update public.projects set parent_id=${lit(child)} where id=${lit(leaf)};update public.projects set is_archived=true where id in(${lit(child)},${lit(destination)})`);
 for(const p of [root,child,leaf,destination])await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(p)},${lit(team)},${lit(users.manager.id)},'manager')`);
 const task=randomUUID(),section=randomUUID(),comment=randomUUID(),object=randomUUID();
 await pg.raw(`insert into public.tasks(id,user_id,project_id,title) values(${lit(task)},${lit(users.member.id)},${lit(leaf)},'Preserve all task fields');insert into public.sections(id,user_id,project_id,name) values(${lit(section)},${lit(users.member.id)},${lit(child)},'Preserve section');insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) select ${lit(comment)},id,task_generation,project_id,user_id,'Preserve discussion' from public.tasks where id=${lit(task)}`);
 await pg.raw(`insert into storage.objects(id,bucket_id,name,owner,owner_id) values(${lit(object)},'task-attachments',${lit(users.member.id+'/hierarchy-proof')},${lit(users.member.id)},${lit(users.member.id)});insert into taskfold_private.team_content_files values(${lit(object)},${lit(leaf)})`);
 const run=(who,expression,options={})=>{const u=users[who];return pg.scalar(`begin;set application_name=${lit(options.app??'hierarchy-'+randomUUID().slice(0,8))};create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;${options.statement?`create function pg_temp.probe() returns jsonb language plpgsql security invoker as $p$declare n integer;begin ${options.statement};get diagnostics n=row_count;return to_jsonb(n);end$p$;`:''}set local role ${options.role??'authenticated'};set local request.jwt.claim.sub=${lit(u.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:u.id,session_id:options.session??u.session}))};do $r$begin begin insert into result values((${expression}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,180));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`);};
 const rpc=async(who,action,body,options)=>{const r=await run(who,`public.taskfold_team_projects(${lit(action)},${json(body)})`,options);if(!r.code&&['move','create_subproject'].includes(action))commands.push({account:users[who].id,action,body,result:r.value});if(!r.code&&action==='review_hierarchy')reviews.push({account:users[who].id,body,result:r.value});return r;};
 const review=(who='manager',operation='move',p=root,parent=destination)=>rpc(who,'review_hierarchy',{team_id:team,project_id:p,parent_id:parent,operation});
 const request=async(operation,p=root,parent=destination,who='manager',extra={})=>{
  const r=await review(who,operation,p,parent);assert.equal(r.code,null,JSON.stringify(r));
  const body={team_id:team,project_id:p,parent_id:parent,parent_revision:r.value.parent_revision,team_revision:r.value.team_revision,request_id:randomUUID(),issued_at:new Date().toISOString(),tree_token:r.value.tree_token,affected_count:r.value.affected_count,destination_archived:r.value.destination_archived,is_archived:r.value.is_archived};
  if(operation==='move')body.revision=r.value.revision;else Object.assign(body,{name:'New design branch',visibility:'private',folder_id:null});return {...body,...extra};
 };
 const success=async(name,who,action,b)=>{const r=await rpc(who,action,b);check(name,r.code,null);return r.value;};
 const content=()=>pg.scalar(`select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(x) order by id) from public.tasks x),'sections',(select jsonb_agg(to_jsonb(x) order by id) from public.sections x),'comments',(select jsonb_agg(to_jsonb(x) order by id) from public.task_comments x),'custody',(select jsonb_agg(to_jsonb(x) order by task_id) from taskfold_private.team_content_tasks x),'files',(select jsonb_agg(to_jsonb(x) order by id) from storage.objects x),'fileCustody',(select jsonb_agg(to_jsonb(x) order by object_id) from taskfold_private.team_content_files x),'grants',(select jsonb_agg(to_jsonb(x) order by project_id,user_id) from taskfold_private.team_project_grants x where project_id in(${[root,child,leaf].map(lit).join(',')})))`);
 const state=()=>pg.scalar(`select jsonb_agg(jsonb_build_object('id',p.id,'creator',p.user_id,'parent',p.parent_id,'own',p.is_archived,'inherited',p.ancestor_archived,'revision',c.revision) order by p.id) from public.projects p join taskfold_private.team_content_projects c on c.project_id=p.id where p.id in(${[root,child,leaf].map(lit).join(',')})`);
 check('read flag defaults closed',(await review()).code,'PT503');
 await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true;update taskfold_private.team_config set enabled=true');
 const baseline=await state(),preserved=await content();
 const reviewed=await review();check('full mixed-creator branch can be reviewed',reviewed.value?.affected_count,3);check('archived destination disclosed',reviewed.value.destination_archived,true);
 check('review writes no receipt',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_project_commands'),0);check('review does not mutate branch',await state(),baseline);
 for(const who of ['member','guest','outside'])check(who+' cannot move manager branch',(await review(who)).code,who==='outside'?'PT404':'42501');
 const created=randomUUID(),creation=await request('create_subproject',created,destination);
 const createReceipt=await success('cross-creator subproject created','manager','create_subproject',creation);
 check('child created once with original actor and chosen parent',(await pg.scalar(`select jsonb_build_array(user_id,parent_id,is_archived,ancestor_archived) from public.projects where id=${lit(created)}`)),[users.manager.id,destination,false,true]);
 check('create response revision and inherited archive',[createReceipt.revision,createReceipt.is_archived,createReceipt.ancestor_archived],[1,false,true]);
 check('new child remains independently private',await pg.scalar(`select coalesce(to_jsonb(taskfold_private.team_project_role(${lit(users.member.id)},${lit(created)})),'null'::jsonb)`),null);
 check('creator has explicit manager grant',await pg.scalar(`select to_jsonb(taskfold_private.team_project_role(${lit(users.manager.id)},${lit(created)}))`),'manager');
 check('lost create reply replays identical receipt',(await rpc('manager','create_subproject',creation)).value,createReceipt);
 check('same nonce cannot change created name',(await rpc('manager','create_subproject',{...creation,name:'Changed'})).code,'PT409');
 const move=await request('move');const moved=await success('branch moved into archived destination','manager','move',move);
 const after=await state();check('branch root has exact destination',after.find(x=>x.id===root).parent,destination);check('all descendants derive inherited archive',after.every(x=>x.inherited),true);
 check('own archive settings and creators unchanged',after.map(x=>[x.id,x.own,x.creator]),baseline.map(x=>[x.id,x.own,x.creator]));check('every moved project revision increments once',after.every(x=>x.revision===baseline.find(y=>x.id===y.id).revision+1),true);
 check('lost move reply replays identical receipt',(await rpc('manager','move',move)).value,moved);check('move replay leaves all project states unchanged',await state(),after);
 const top=await request('move',root,null);await success('branch returned to team level','manager','move',top);const restored=await state();check('top-level move restores original archive projections',restored.map(x=>[x.id,x.own,x.inherited]),baseline.map(x=>[x.id,x.own,x.inherited]));
 check('tasks sections discussions and custody unchanged',await content(),preserved);
 check('source descendant is not a valid parent',(await review('manager','move',root,leaf)).code,'22023');check('self is not a valid parent',(await review('manager','move',root,root)).code,'22023');check('cross-team destination denied',(await review('owner','move',root,foreign)).code,'42501');
 const current=await request('move');
 for(const [name,patch,expected] of [['stale root revision',{revision:0},'PT409'],['stale team revision',{team_revision:0},'PT409'],['stale parent revision',{parent_revision:0},'PT409'],['altered branch token',{tree_token:'a'.repeat(64)},'PT409'],['altered branch count',{affected_count:2},'PT409'],['altered destination state',{destination_archived:false},'PT409'],['altered own state',{is_archived:true},'PT409'],['expired request',{issued_at:new Date(Date.now()-16*60000).toISOString()},'PT409'],['extra field',{creator_id:users.owner.id},'22023']])check(name,(await rpc('manager','move',{...current,...patch})).code,expected);
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(leaf)} and user_id=${lit(users.manager.id)}`);
 check('hidden child denies whole branch review',(await review()).code,'42501');check('hidden child denies mutation',(await rpc('manager','move',current)).code,'42501');
 await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(leaf)},${lit(team)},${lit(users.manager.id)},'manager')`);
 // Current parent identity is withheld when the caller cannot read that parent.
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(destination)} and user_id=${lit(users.manager.id)}`);
 const detail=await rpc('manager','get',{team_id:team,project_id:created});check('inaccessible parent ID withheld',[detail.value.parent_id,detail.value.parent_unavailable],[null,true]);
 check('destination permission rechecked after review',(await rpc('manager','move',current)).code,'42501');check('created receipt can replay without exposing new parent information',(await rpc('manager','create_subproject',creation)).value,createReceipt);
 await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(destination)},${lit(team)},${lit(users.manager.id)},'manager')`);
 const visible=await rpc('manager','get',{team_id:team,project_id:created});check('readable parent projection is explicit',[visible.value.project_hierarchy_protocol,visible.value.parent_id,visible.value.parent_unavailable],[1,destination,false]);

 // Reviews fail rather than silently repairing corrupt or changed hierarchies.
 const corrupt = async (id,field,value) => pg.raw(`alter table public.projects disable trigger taskfold_team_project_organization;update public.projects set ${field}=${value} where id=${lit(id)};alter table public.projects enable trigger taskfold_team_project_organization`);
 await corrupt(root,'ancestor_archived','true');check('corrupt source projection rejected',(await review()).code,'PT409');await corrupt(root,'ancestor_archived','false');
 await corrupt(destination,'ancestor_archived','true');check('corrupt destination projection rejected',(await review()).code,'PT409');await corrupt(destination,'ancestor_archived','false');
 const staleBranch=await request('move'),newChild=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(newChild)},${lit(users.member.id)},'New reviewed descendant');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(newChild)},${lit(team)},'private');insert into taskfold_private.team_project_grants values(${lit(newChild)},${lit(team)},${lit(users.manager.id)},'manager');update public.projects set parent_id=${lit(root)} where id=${lit(newChild)}`);
 check('new descendant invalidates existing review',(await rpc('manager','move',staleBranch)).code,'PT409');
 await pg.raw(`update public.projects set parent_id=null where id=${lit(newChild)}`);
 const staleParent=await request('move');await pg.raw(`update taskfold_private.team_content_projects set revision=revision+1 where project_id=${lit(destination)}`);
 check('destination changed after review rejected',(await rpc('manager','move',staleParent)).code,'PT409');
 const staleAncestor=await request('move');await pg.raw(`update public.projects set parent_id=${lit(newChild)} where id=${lit(destination)}`);
 check('destination ancestry change invalidates review',(await rpc('manager','move',staleAncestor)).code,'PT409');
 await pg.raw(`update public.projects set parent_id=null where id=${lit(destination)}`);
 const topRequest=await request('move',child,null);
 check('top level cannot carry nonnull parent revision',(await rpc('manager','move',{...topRequest,parent_revision:1})).code,'PT409');
 check('future request rejected',(await rpc('manager','move',{...topRequest,issued_at:new Date(Date.now()+120000).toISOString()})).code,'PT409');
 check('creation must have a parent',(await review('manager','create_subproject',randomUUID(),null)).code,'22023');
 check('creation cannot reuse project identity',(await review('manager','create_subproject',created,destination)).code,'PT409');
 const pending=await request('move');
 await pg.raw('update taskfold_private.team_config set enabled=false');
 check('paused setup denies hierarchy review',(await review()).code,'PT503');check('paused setup denies fresh move',(await rpc('manager','move',pending)).code,'PT503');
 check('paused setup permits exact previously accepted receipt',(await rpc('manager','create_subproject',creation)).value,createReceipt);
 await pg.raw('update taskfold_private.team_config set enabled=true');
 await pg.raw(`update taskfold_private.teams set state='archived' where id=${lit(team)}`);check('archived team denies fresh move',(await rpc('manager','move',pending)).code,'PT409');
 await pg.raw(`update taskfold_private.teams set state='active',usage_day=(clock_timestamp() at time zone 'UTC')::date,day_operations=2000 where id=${lit(team)}`);
 check('budget exhausted denies new move',(await rpc('manager','move',await request('move'))).code,'PT429');
 await pg.raw(`update taskfold_private.teams set day_operations=0 where id=${lit(team)}`);
 // The original personal guard still forbids mixed-creator parent links.
 const personalA=randomUUID(),personalB=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(personalA)},${lit(users.manager.id)},'Personal A'),(${lit(personalB)},${lit(users.member.id)},'Personal B')`);
 try { await pg.raw(`update public.projects set parent_id=${lit(personalB)} where id=${lit(personalA)}`);throw new Error('Personal cross-creator move succeeded'); }
 catch(error) {check('personal creator isolation unchanged',error.code,'P0001');}
 // Trusted fixture can seed a bad graph, but the API must remain bounded.
 await pg.raw('alter table public.projects disable trigger taskfold_project_organization;alter table public.projects disable trigger taskfold_team_project_organization;alter table public.projects disable trigger taskfold_project_archive_descendants');
 const deep=Array.from({length:21},()=>randomUUID());
 await pg.raw(deep.map(id=>`insert into public.projects(id,user_id,name) values(${lit(id)},${lit(users.member.id)},'Depth proof');insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(id)},${lit(team)});insert into taskfold_private.team_project_grants values(${lit(id)},${lit(team)},${lit(users.manager.id)},'manager');`).join('')+deep.slice(1).map((id,i)=>`update public.projects set parent_id=${lit(deep[i])} where id=${lit(id)};`).join(''));
 await pg.raw('alter table public.projects enable trigger taskfold_project_organization;alter table public.projects enable trigger taskfold_team_project_organization;alter table public.projects enable trigger taskfold_project_archive_descendants');
 check('preexisting source over depth rejected',(await review('manager','move',deep[0],destination)).code,'54000');
 check('destination at depth twenty cannot fit branch',(await review('manager','move',root,deep[19])).code,'54000');
 check('new child cannot exceed depth twenty',(await review('manager','create_subproject',randomUUID(),deep[19])).code,'54000');
 await pg.raw(`alter table public.projects disable trigger taskfold_team_project_organization;alter table public.projects disable trigger taskfold_project_archive_descendants;update public.projects set parent_id=${lit(leaf)} where id=${lit(root)};alter table public.projects enable trigger taskfold_team_project_organization;alter table public.projects enable trigger taskfold_project_archive_descendants`);
 check('cyclic source rejected without unbounded recursion',(await review()).code,'54000');
 await pg.raw(`alter table public.projects disable trigger taskfold_team_project_organization;alter table public.projects disable trigger taskfold_project_archive_descendants;update public.projects set parent_id=null where id=${lit(root)};alter table public.projects enable trigger taskfold_team_project_organization;alter table public.projects enable trigger taskfold_project_archive_descendants`);
 // Per-project exact operation scope is not a general metadata write capability.
 for(const [label,p,scopedParent,sql] of [
  ['scope cannot substitute destination',root,destination,`update public.projects set parent_id=${lit(newChild)} where id=${lit(root)}`],
  ['scope cannot rename root',root,destination,`update public.projects set name='Smuggled' where id=${lit(root)}`],
  ['scope cannot archive descendant',child,root,`update public.projects set is_archived=false where id=${lit(child)}`],
  ['scope cannot reparent descendant',child,root,`update public.projects set parent_id=${lit(destination)} where id=${lit(child)}`],
  ['scope cannot transfer creator',root,destination,`update public.projects set user_id=${lit(users.member.id)} where id=${lit(root)}`],
  ['scope cannot delete project',newChild,null,`delete from public.projects where id=${lit(newChild)}`]
 ]) {
  const u=users.manager;const outcome=await pg.scalar(`begin;insert into taskfold_private.team_project_hierarchy_operations values(txid_current(),${lit(u.id)},${lit(team)},${lit(p)},${lit(root)},${scopedParent===null?'null':lit(scopedParent)},'move');create temp table proof(code text) on commit drop;grant all on proof to service_role;set local role service_role;set local request.jwt.claim.sub=${lit(u.id)};do $r$begin begin ${sql};insert into proof values(null);exception when others then insert into proof values(sqlstate);end;end$r$;select coalesce(to_jsonb(code),'null'::jsonb) from proof;rollback;`);check(label,outcome,'42501');
 }
 // A failure after the actual root mutation rolls back all project/scope/receipt changes.
 const failMove=await request('move'),beforeFail=await state(),receiptCount=await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_project_commands');
 await pg.raw(`create function taskfold_private.fixture_fail_hierarchy() returns trigger language plpgsql as $$begin if new.id=${lit(root)}::uuid and new.parent_id is distinct from old.parent_id then raise exception using errcode='P0001',message='Synthetic failure';end if;return new;end$$;create trigger zz_fixture_fail_hierarchy after update on public.projects for each row execute function taskfold_private.fixture_fail_hierarchy()`);
 check('failure after root change rolls back',(await rpc('manager','move',failMove)).code,'P0001');check('failure preserves all branch rows',await state(),beforeFail);check('failure saves no receipt',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_project_commands'),receiptCount);check('failure leaks no operation scope',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_project_hierarchy_operations'),0);
 await pg.raw('drop trigger zz_fixture_fail_hierarchy on public.projects;drop function taskfold_private.fixture_fail_hierarchy()');
 // Supported commands serialize at the team boundary, then recheck live rights.
 const lock=await pg.hold(`select 1 from taskfold_private.teams where id=${lit(team)} for update`);
 const waiting=rpc('manager','move',failMove,{app:'hierarchy-revocation-wait'});await pg.waitForLock('hierarchy-revocation-wait',lock.pid);
 await lock.release('commit',`delete from taskfold_private.team_project_grants where project_id=${lit(destination)} and user_id=${lit(users.manager.id)}`);
 check('waiting move observes committed destination revocation',(await waiting).code,'42501');check('revoked waiting move makes no changes',await state(),beforeFail);
 await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(destination)},${lit(team)},${lit(users.manager.id)},'manager')`);
 const one=await request('move'),two=await request('move');
 const outcomes=await Promise.all([rpc('manager','move',one),rpc('manager','move',two)]);
 check('concurrent reviewed moves accept exactly one',outcomes.filter(x=>x.code===null).length,1);check('other concurrent move requires fresh review',outcomes.find(x=>x.code!==null)?.code,'PT409');
 await success('restore after concurrent move','manager','move',await request('move',root,null));
 check('content files grants and custody survive hierarchy stress',await content(),preserved);
 const archive={team_id:team,project_id:root,request_id:randomUUID(),issued_at:new Date().toISOString(),team_revision:1,revision:restored.find(x=>x.id===root).revision};
 const ar=await rpc('manager','review_structure',{team_id:team,project_id:root,operation:'archive'});assert.equal(ar.code,null,JSON.stringify(ar));Object.assign(archive,{revision:ar.value.revision,tree_token:ar.value.tree_token,affected_count:ar.value.affected_count});check('mixed-creator archive remains supported',(await rpc('manager','archive',archive)).code,null);
 check('mixed-creator archive still preserves content',await content(),preserved);
 // Team authority remains valid after a project creator leaves the team.
 await pg.raw(`delete from taskfold_private.team_members where team_id=${lit(team)} and user_id=${lit(users.member.id)}`);
 const archivedMove=await request('move');const archivedReceipt=await success('departed creator branch can still move','manager','move',archivedMove);
 check('moving an archived root preserves its own flag',[archivedReceipt.is_archived,archivedReceipt.ancestor_archived],[true,true]);
 await success('archived branch returns to team level','manager','move',await request('move',root,null));
 check('own archive survives returning to team level',(await state()).find(x=>x.id===root).own,true);
 check('creator departure and archived moves preserve all work',await content(),preserved);
 // Real bounded branch and team-cap checks, rather than forged counts alone.
 const crowdedParent=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(crowdedParent)},${lit(users.owner.id)},'Crowded root');insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(crowdedParent)},${lit(team)});alter table public.projects disable trigger taskfold_team_project_organization;with added as(insert into public.projects(id,user_id,name) select gen_random_uuid(),${lit(users.owner.id)},'Crowded child' from generate_series(1,1000) returning id) insert into taskfold_private.team_content_projects(project_id,team_id) select id,${lit(team)} from added;update public.projects set parent_id=${lit(crowdedParent)} where name='Crowded child';alter table public.projects enable trigger taskfold_team_project_organization`);
 check('branch larger than one thousand rejected',(await review('owner','move',crowdedParent,destination)).code,'54000');
 const cappedChild=await request('create_subproject',randomUUID(),destination);
 check('team project cap rejects new subproject',(await rpc('manager','create_subproject',cappedChild)).code,'54000');
 check('team-cap failure creates no partial project',await pg.scalar(`select to_jsonb(count(*)) from public.projects where id=${lit(cappedChild.project_id)}`),0);
 await pg.raw(`delete from public.projects where name='Crowded child';delete from public.projects where id=${lit(crowdedParent)}`);

 check('revoked session cannot review',(await rpc('manager','review_hierarchy',{team_id:team,project_id:root,parent_id:destination,operation:'move'},{session:randomUUID()})).code,'28000');
 const dml=(who,statement,options={})=>run(who,'pg_temp.probe()',{...options,statement});
 check('legacy direct team move is still closed',(await dml('manager',`update public.projects set parent_id=${lit(destination)} where id=${lit(root)}`,{role:'service_role'})).code,'42501');
 for(const role of ['authenticated','anon','service_role'])check(role+' cannot create hierarchy scope',(await dml('manager',`insert into taskfold_private.team_project_hierarchy_operations values(txid_current(),${lit(users.manager.id)},${lit(team)},${lit(root)},${lit(root)},${lit(destination)},'move')`,{role})).code,'42501');
 check('no private hierarchy scope remains',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_project_hierarchy_operations'),0);
 report.advisors=await pg.advisors();check('no new security or performance warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
 report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
 if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');if(process.argv[3])await writeFile(process.argv[3],JSON.stringify({reviews,commands},null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
} finally {if(pg)await pg.close();}
