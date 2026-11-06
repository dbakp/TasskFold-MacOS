// Synthetic owned PostgreSQL only: no hosted configuration, tokens or real work.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadTeamProjectSchema} from './team-project-schema.mjs';
const migration='20261026113556_task_node_activity_custody.sql';
const sql=await readFile(process.env.TASKFOLD_NODE_CUSTODY_DRAFT ?? new URL('../../supabase/migrations/'+migration,import.meta.url),'utf8');
const report={migration,migrationSHA256:createHash('sha256').update(sql).digest('hex'),checks:{},hostedChanged:false,realDataChanged:false};
const check=(name,value,expected=true)=>{assert.deepEqual(value,expected,name);report.checks[name]=true};
const json=value=>lit(JSON.stringify(value))+'::jsonb';
const people=Object.fromEntries(['owner','creator','member','viewer','guest','outsider'].map(name=>[name,{id:randomUUID(),session:randomUUID()}]));
const team=randomUUID(),project=randomUUID(),secret=randomUUID(),personal=randomUUID(),teamTask=randomUUID(),secretTask=randomUUID(),privateTask=randomUUID(),foreignTask=randomUUID(),deletedTask=randomUUID();
const tree=(done=false)=>[{id:'child',title:'Private child text',completed:done,completed_at:done?'2026-10-26T10:00:00Z':null,subtasks:[]}];
const source=path=>readFile(new URL('../../'+path,import.meta.url),'utf8');
function definition(text,name) {
 const positions=['create function taskfold_private.','create or replace function taskfold_private.'].map(prefix=>text.indexOf(prefix+name+'()')).filter(i=>i>=0);
 assert(positions.length===1);const start=positions[0],match=/end\s*\$\$;/.exec(text.slice(start));assert(match);
 return text.slice(start,start+match.index+match[0].length).replace('create or replace function','create function');
}
const baseCustody=await source('supabase/migrations/20261024022352_team_content_custody.sql'),baseNodes=await source('supabase/migrations/20261026095807_task_node_activity_history.sql');
for(const name of ['capture_task_node_activity','remove_content_identity','delete_team_content']) {
 let actual=definition(sql,name);const expected=definition(name==='capture_task_node_activity'?baseNodes:baseCustody,name);
 if(name==='capture_task_node_activity')actual=actual.replace(' and not taskfold_private.is_team_content_task(t.id) and not taskfold_private.is_team_content_project(t.project_id)','');
 else actual=actual.split('\n').filter(line=>!line.includes('delete from public.task_node_activity')).join('\n');
 check('preserved original writer body '+name,actual,expected);
}
let pg,step='start';
try {
 pg=await createPostgresFixture({advisors:true});report.serverVersion=pg.serverVersion;await loadTeamProjectSchema(pg.raw);
 await pg.raw('alter table public.tasks add column is_heading boolean');
 await pg.raw(await source('supabase/migrations/20261026095807_task_node_activity_history.sql'));
 await pg.raw(await source('supabase/migrations/20261026104450_task_activity_root_context.sql'));
 for(const [name,u] of Object.entries(people))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit('synthetic-'+name+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});insert into public.profiles(user_id,display_name) values(${lit(u.id)},${lit('Synthetic '+name)})`);
 await pg.raw(`begin;insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(people.owner.id)},'Synthetic team');${Object.entries(people).filter(([k])=>k!=='outsider').map(([name,u])=>`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(u.id)},${lit(name==='owner'?'admin':name==='guest'?'guest':'member')});`).join('')}commit;`);
 for(const [id,visibility] of [[project,'team'],[secret,'private']])await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(id)},${lit(people.creator.id)},'Synthetic team project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(id)},${lit(team)},${lit(visibility)});insert into taskfold_private.team_project_grants values(${lit(id)},${lit(team)},${lit(people.creator.id)},'manager')`);
 await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(people.viewer.id)},'viewer');insert into public.projects(id,user_id,name) values(${lit(personal)},${lit(people.creator.id)},'Synthetic personal project')`);
 for(const [id,p,owner] of [[teamTask,project,people.creator.id],[secretTask,secret,people.creator.id],[privateTask,personal,people.creator.id],[foreignTask,project,people.owner.id],[deletedTask,project,people.creator.id]])await pg.raw(`insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(id)},${lit(owner)},${lit(p)},'Synthetic heading',true,${json(tree())})`);
 const ledger=()=>pg.scalar("select coalesce(jsonb_agg(to_jsonb(a) order by sequence),'[]') from public.task_node_activity a");
 const before=await ledger(),oldEpoch=await pg.scalar("select to_json(recorded_from) from public.task_node_activity_epoch where id='current'");step='upgrade';await pg.raw('begin;'+sql+';commit');check('coverage starts at reliable custody upgrade',new Date(await pg.scalar("select to_json(recorded_from) from public.task_node_activity_epoch where id='current'"))>new Date(oldEpoch));
 const policy=(table,name)=>pg.scalar(`select to_json(pg_get_expr(polqual,polrelid)) from pg_policy where polrelid=${lit('public.'+table)}::regclass and polname=${lit(name)}`);
 check('child permissive read exactly mirrors parent',await policy('task_node_activity','task_node_activity_read'),await policy('task_activity','task_activity_read'));
 check('child restrictive read exactly mirrors parent',await policy('task_node_activity','team_node_activity_native_read'),await policy('task_activity','team_activity_native_read'));
check('upgrade preserves every existing child event',await ledger(),before);
 check('creator FK uses stable content identity',await pg.scalar("select to_json(confrelid::regclass::text) from pg_constraint where conrelid='public.task_node_activity'::regclass and conname='task_node_activity_user_id_fkey'"),'taskfold_private.content_identities');
 const claims=(who,session)=>({sub:people[who].id,session_id:session===undefined?people[who].session:session});
 const read=(who,table,id,session)=>pg.scalar(`set role authenticated;set request.jwt.claim.sub=${lit(people[who].id)};set request.jwt.claims=${lit(JSON.stringify(claims(who,session)))};select count(*) from public.${table} where task_id=${lit(id)}`);
 const count=(who,id,session)=>read(who,'task_node_activity',id,session);
 // Trusted recording fixture: the same private transaction scope used by
 // authorized team commands. This does not claim RPC/HTTP authorization delivery.
 const actor=(who,statement)=>pg.raw(`begin;insert into taskfold_private.team_content_operations values(txid_current(),${lit(team)});set local request.jwt.claim.sub=${lit(people[who].id)};set local request.jwt.claims=${lit(JSON.stringify(claims(who)))};${statement};delete from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=${lit(team)};commit`);
 step='role gates';for(const who of ['owner','creator','member','viewer','guest','outsider'])check('disabled rollout hides team child history from '+who,await count(who,teamTask),0);
 await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true;update taskfold_private.team_config set enabled=true');
 for(const [who,visible] of [['owner',true],['creator',true],['member',true],['viewer',true],['guest',false],['outsider',false]]) {
  check('team read role '+who,(await count(who,teamTask))>0,visible);
  check('matches parent read role '+who,(await count(who,teamTask))>0,(await read(who,'task_activity',teamTask))>0);
 }
 await pg.raw(`insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(project)},${lit(team)},${lit(people.guest.id)},'viewer')`);check('explicit guest grant permits child history',(await count('guest',teamTask))>0);await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(people.guest.id)}`);check('guest grant removal revokes history',await count('guest',teamTask),0);
 check('ungranted member cannot read private project history',await count('member',secretTask),0);check('owner can read private project history',(await count('owner',secretTask))>0);
 check('session is required even for creator',await count('creator',teamTask,null),0);
 await pg.raw(`update auth.sessions set not_after=now()-interval '1 minute' where id=${lit(people.member.session)}`);check('expired session loses metadata',await count('member',teamTask),0);await pg.raw(`update auth.sessions set not_after=null where id=${lit(people.member.session)}`);
 await pg.raw(`update auth.users set banned_until=now()+interval '1 hour' where id=${lit(people.member.id)}`);check('banned member loses metadata',await count('member',teamTask),0);await pg.raw(`update auth.users set banned_until=null where id=${lit(people.member.id)}`);
 await pg.raw(`delete from taskfold_private.team_members where team_id=${lit(team)} and user_id=${lit(people.member.id)}`);check('revoked member loses history',await count('member',teamTask),0);await pg.raw(`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(people.member.id)},'member')`);
 step='closed writes';const beforeDirect=await ledger();let directError=null;
 try {await pg.raw(`set role authenticated;set request.jwt.claim.sub=${lit(people.creator.id)};set request.jwt.claims=${lit(JSON.stringify(claims('creator')))};update public.tasks set subtasks=${json(tree(true))} where id=${lit(teamTask)}`);}catch(error){directError=error.code;}
 check('direct native write cannot change child history',await ledger(),beforeDirect);check('direct write either filtered or explicitly rejected',[null,'PT503','42501'].includes(directError));
 check('private transaction authority cannot be forged by client',await pg.scalar("select to_json(has_table_privilege('authenticated','taskfold_private.team_content_operations','INSERT'))"),false);
 step='scope transitions';await pg.raw(`update public.tasks set project_id=${lit(project)} where id=${lit(secretTask)}`);check('private prior state never leaks after move',await count('member',secretTask),0);await pg.raw(`update public.tasks set subtasks=${json(tree(true))} where id=${lit(secretTask)}`);check('known subsequent shared transition becomes visible',await count('member',secretTask),1);
 await actor('creator',`update public.tasks set subtasks=${json(tree(true))} where id=${lit(foreignTask)}`);const foreignEvent=(await ledger()).findLast(e=>e.task_id===foreignTask).id;
 step='author removal';const teamCount=(await ledger()).filter(e=>e.task_id===teamTask).length;await pg.raw(`delete from auth.users where id=${lit(people.creator.id)}`);
 check('personal history physically removed',(await ledger()).some(e=>e.task_id===privateTask),false);check('team history retained exactly',(await ledger()).filter(e=>e.task_id===teamTask).length,teamCount);check('retained author ID stays stable',(await ledger()).find(e=>e.task_id===teamTask).user_id,people.creator.id);
 check('removed author token grants no team history',await count('creator',teamTask),0);check('remaining member still reads retained history',(await count('member',teamTask))>0);
 check('other creator history survives actor removal',(await ledger()).find(e=>e.id===foreignEvent).actor_id,null);
 await actor('member',`update public.tasks set subtasks=${json(tree(true))} where id=${lit(teamTask)}`);let latest=(await ledger()).findLast(e=>e.task_id===teamTask);check('child recording continues after author removal',latest.kinds,['completed']);check('actual surviving actor recorded',latest.actor_id,people.member.id);check('retained owner is not substituted for actor',latest.user_id,people.creator.id);
 const successor=randomUUID();await actor('member',`insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(successor)},${lit(people.creator.id)},${lit(project)},'Synthetic retained-author successor',true,${json(tree())})`);check('new retained-author successor gets child history',(await ledger()).some(e=>e.task_id===successor));
 step='deleted roots';await pg.raw(`delete from public.tasks where id=${lit(deletedTask)}`);check('deleted root retains real child deletion event',(await ledger()).findLast(e=>e.task_id===deletedTask).kinds,['deleted']);check('deleted root history remains role-gated',(await count('member',deletedTask))>0);check('outsider cannot read deleted root history',await count('outsider',deletedTask),0);
 step='read only';check('authenticated has no ledger writes',await pg.scalar("select to_json(has_table_privilege('authenticated','public.task_node_activity','INSERT,UPDATE,DELETE'))"),false);check('anonymous has no ledger reads',await pg.scalar("select to_json(has_table_privilege('anon','public.task_node_activity','SELECT'))"),false);
 for(const name of ['capture_task_node_activity','remove_content_identity','delete_team_content'])check('no callable writer '+name,await pg.scalar(`select to_json(has_function_privilege('authenticated','taskfold_private.${name}()','EXECUTE'))`),false);
 if(process.env.TASKFOLD_NODE_CUSTODY_ROWS)await writeFile(process.env.TASKFOLD_NODE_CUSTODY_ROWS,JSON.stringify(await ledger(),null,2)+'\n');
 step='team deletion';const run=async expression=>pg.scalar(`begin;create temp table result(value jsonb,code text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${lit(people.owner.id)};set local request.jwt.claims=${lit(JSON.stringify(claims('owner')))};do $r$begin begin insert into result values((${expression}),null);exception when others then insert into result values(null,sqlstate);end;end$r$;select jsonb_build_object('value',value,'code',code) from result;commit`);
 const revision=await pg.scalar(`select revision from taskfold_private.teams where id=${lit(team)}`),command={team_id:team,revision,request_id:randomUUID(),issued_at:new Date().toISOString()};
 const object=randomUUID();await pg.raw(`insert into storage.objects(id,bucket_id,name,owner,owner_id) values(${lit(object)},'task-attachments',${lit(people.owner.id+'/synthetic-node-history-block')},${lit(people.owner.id)},${lit(people.owner.id)});insert into taskfold_private.team_content_files(object_id,project_id) values(${lit(object)},${lit(project)})`);
 const beforeBlocked=await ledger();const blocked=await run(`public.taskfold_teams('delete',${json(command)})`);check('file guard still blocks team deletion',blocked.code,'PT409');check('failed deletion retains every child event',await ledger(),beforeBlocked);
 // Metadata-only owned fixture, not an upload or Storage-provider delivery test.
 await pg.raw(`delete from taskfold_private.team_content_files where object_id=${lit(object)};delete from storage.objects where id=${lit(object)}`);
 const deleted=await run(`public.taskfold_teams('delete',${json(command)})`);check('authorized team deletion succeeds',deleted.code,null);check('all team child history physically removed',await pg.scalar(`select count(*) from public.task_node_activity a join taskfold_private.team_content_tasks c on c.task_id=a.task_id where c.team_id=${lit(team)}`),0);check('all child rows gone after personal and team deletion',(await ledger()).length,0);
 step='advisors';report.advisors=await pg.advisors();check('official advisors ran',report.advisors.ran);check('no new ledger or writer advisor findings',report.advisors.result.filter(f=>/task_node_activity|capture_task_node_activity|remove_content_identity|delete_team_content/.test(JSON.stringify(f))),[]);
 console.log('PASS '+Object.keys(report.checks).length+' child-custody checks');
}catch(error){report.failedStep=step;report.error={name:error.name,message:error.message,code:error.code};process.exitCode=1;console.error('FAIL '+step+': '+error.message+' '+(error.code??''));}
finally {if(pg)report.ownedFixtureRemoved=await pg.close();const index=process.argv.indexOf('--report');if(index>=0)await writeFile(process.argv[index+1],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:Object.keys(report.checks).length,failedStep:report.failedStep,ownedFixtureRemoved:report.ownedFixtureRemoved}));}
