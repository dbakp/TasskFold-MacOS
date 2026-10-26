// Real reviewed adoption and SQL RLS; synthetic owned PostgreSQL only.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadProjectAdoptionSchema} from './project-adoption-schema.mjs';
const migration='20261026122805_reviewed_history_custody.sql',source=async file=>readFile(new URL('../../'+file,import.meta.url),'utf8');
const sql=await source('supabase/migrations/'+migration),json=x=>lit(JSON.stringify(x))+'::jsonb';
const report={checks:{},hostedChanges:false,realUserDataChanged:false,migrationSHA256:createHash('sha256').update(sql).digest('hex')};
const check=(n,a,b=true)=>{assert.deepEqual(a,b,n);report.checks[n]=true};
const users=Object.fromEntries(['creator','ownerA','memberA','ownerB','memberB','both','outsider'].map(n=>[n,{id:randomUUID(),session:randomUUID()}]));
function definition(text,name){const match=new RegExp('create (?:or replace )?function taskfold_private\\.'+name+'\\(').exec(text);assert(match);const start=match.index,end=text.indexOf('$$;',text.indexOf('as $$',start))+3;return text.slice(start,end).replace('create or replace function','create function');}
for(const [name,file] of [['project_adoption_review','20261026121332_task_node_project_adoption_review.sql'],['project_adoption_commit','20261025033903_team_project_adoption_connection_policy.sql'],['remove_content_identity','20261026113556_task_node_activity_custody.sql'],['delete_team_content','20261026113556_task_node_activity_custody.sql']]){
 let actual=definition(sql,name),expected=definition(await source('supabase/migrations/'+file),name);
 if(name==='project_adoption_review')actual=actual.replace("'history_custody_protocol',1,",'');
 if(name==='project_adoption_commit')actual=actual.replace('folder_id,history_custody_version)','folder_id)').replace('visibility,folder,1 from','visibility,folder from').split('\n').filter(l=>!l.includes('perform taskfold_private.register_reviewed_history_custody')).join('\n');
 if(name==='remove_content_identity')actual=actual.replaceAll('history_root_has_live_custody(task_id)','is_team_content_task(task_id)').replace(/ and not taskfold_private.history_has_live_custody\('[^']+',id,null\)/g,'');
 if(name==='delete_team_content')actual=actual.replace(/  -- Drain concurrent reviewed transfers[\s\S]*?  insert into taskfold_private.team_content_operations/, '  insert into taskfold_private.team_content_operations');
 if(name==='delete_team_content')for(const table of ['task_activity','task_node_activity']){const changed=actual.split('\n').find(l=>l.includes('delete from public.'+table+' where'));const original=expected.split('\n').find(l=>l.includes('delete from public.'+table+' where'));assert(changed&&original);actual=actual.replace(changed,original);}
 check('preserved existing '+name,actual,expected);
}
let pg,step='load';
try{
 pg=await createPostgresFixture({advisors:true});await loadProjectAdoptionSchema(pg.raw,{nodes:true,historyCustody:false});
 for(const [n,u] of Object.entries(users))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(n+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});insert into public.profiles(user_id) values(${lit(u.id)})`);
 const identity=n=>`set local request.jwt.claim.sub=${lit(users[n].id)};set local request.jwt.claims=${lit(JSON.stringify({sub:users[n].id,session_id:users[n].session}))};`;
 const call=(n,op,b)=>pg.scalar(`begin;${identity(n)}set local role authenticated;select public.taskfold_team_project_adoption(${lit(op)},${json(b)});commit`);
 const expect=async(n,fn,code)=>{try{await fn();assert.fail(n+' unexpectedly succeeded')}catch(e){check(n,e.code,code)}};
 const teams={A:randomUUID(),B:randomUUID()};
 for(const k of ['A','B'])await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(teams[k])},${lit(users['owner'+k].id)},'Synthetic team ${k}');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(teams[k])},${lit(users['owner'+k].id)},'admin'),(${lit(teams[k])},${lit(users.creator.id)},'member'),(${lit(teams[k])},${lit(users['member'+k].id)},'member'),(${lit(teams[k])},${lit(users.both.id)},'member')`);
 await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true');
 const p=randomUUID(),q=randomUUID(),root=randomUUID(),deleted=randomUUID(),personal=randomUUID(),node=randomUUID();
 const tree=done=>[{id:node,title:'Synthetic private child',completed:done,...(done?{completed_at:new Date().toISOString()}:{}),subtasks:[]}];
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(p)},${lit(users.creator.id)},'Selected past scope'),(${lit(q)},${lit(users.creator.id)},'Current separate scope');begin;${identity('creator')}insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(root)},${lit(users.creator.id)},${lit(p)},'Synthetic moving heading',true,${json(tree(false))}),(${lit(deleted)},${lit(users.creator.id)},${lit(p)},'Synthetic deleted heading',true,${json(tree(false))}),(${lit(personal)},${lit(users.creator.id)},null,'Synthetic private Inbox',true,${json(tree(false))});update public.tasks set subtasks=${json(tree(true))} where id=${lit(root)};delete from public.tasks where id=${lit(deleted)};update public.tasks set project_id=${lit(q)} where id=${lit(root)};update public.tasks set subtasks=${json(tree(false))} where id=${lit(root)};update public.tasks set due_date='2026-10-27' where id=${lit(root)};commit`);
 const scope=(team,project)=>({team_id:team,roots:[project],visibility:'team',folder_id:null,parent_id:null});
 const baseA=scope(teams.A,p),baseB=scope(teams.B,q);
 const inspect=async base=>call('creator','inspect',base);
 const review=async base=>{const i=await inspect(base);return call('creator','review',{...base,inspection_token:i.inspection_token,decisions:[]})};
 const command=(base,r)=>({...base,inspection_token:r.inspection_token,decisions:[],review_token:r.review_token,expires_at:r.expires_at,request_id:randomUUID()});
 const ledgers=()=>pg.scalar("select jsonb_build_object('root',(select jsonb_agg(to_jsonb(x) order by sequence) from public.task_activity x),'child',(select jsonb_agg(to_jsonb(x) order by sequence) from public.task_node_activity x))");
 // UUIDs are independent across the two feeds; a child binding must not
 // authorize an unrelated parent record with the same event UUID.
 const collision=await pg.scalar(`select to_json(id) from public.task_activity where task_id=${lit(personal)} limit 1`);
 await pg.raw(`update public.task_node_activity set id=${lit(collision)} where id=(select id from public.task_node_activity where task_id=${lit(deleted)} order by sequence limit 1)`);
 const oldReview=await review(baseA),before=await ledgers();
 const oldEpochs=await pg.scalar("select jsonb_build_array((select recorded_from from public.task_activity_epoch where id='current'),(select recorded_from from public.task_node_activity_epoch where id='current'))");
 step='upgrade';const oldTransferHold=await pg.hold(`${identity('creator')}set local role authenticated;select public.taskfold_team_project_adoption('adopt',${json(command(baseA,oldReview))});reset role;`);
 try{await expect('upgrade refuses in-flight old adoption without waiting',()=>pg.raw('begin;'+sql+';commit'),'55P03')}finally{await oldTransferHold.release('rollback')}
 check('failed upgrade exposes no partial registry',await pg.scalar("select coalesce(to_json(to_regclass('taskfold_private.reviewed_history_custody')),'null'::json)"),null);
 await pg.raw('begin;'+sql+';commit');check('upgrade preserves every recorded event',await ledgers(),before);
 const newEpochs=await pg.scalar("select jsonb_build_array((select recorded_from from public.task_activity_epoch where id='current'),(select recorded_from from public.task_node_activity_epoch where id='current'))");check('coverage does not certify pre-upgrade loss',newEpochs.every((date,i)=>new Date(date)>new Date(oldEpochs[i])));
 await expect('pre-upgrade controller cannot insert stale scope',()=>pg.raw(`insert into taskfold_private.team_project_adoption_scope(transaction_id,actor_id,team_id,project_id,root_id,visibility) values(txid_current(),${lit(users.creator.id)},${lit(teams.A)},${lit(p)},${lit(p)},'team')`),'PT409');
 check('no unreviewed historical backfill',await pg.scalar('select count(*) from taskfold_private.reviewed_history_custody'),0);
 await expect('pre-custody review cannot authorize transfer',()=>call('creator','adopt',command(baseA,oldReview)),'PT409');
 const a=await review(baseA),bBeforeA=await review(baseB);check('custody contract advertised',a.history_custody_protocol,1);
 await pg.raw(`create function public.fixture_reject_history_cutover() returns trigger language plpgsql as $$begin raise exception using errcode='PT409',message='Synthetic late cutover failure';end$$;create trigger fixture_reject_history_cutover after insert on taskfold_private.team_content_projects for each row execute function public.fixture_reject_history_cutover()`);
 await expect('late cutover failure is atomic',()=>call('creator','adopt',command(baseA,a)),'PT409');
 check('failed cutover leaves no history custody',await pg.scalar('select count(*) from taskfold_private.reviewed_history_custody'),0);
 check('failed cutover leaves recorded work unchanged',await ledgers(),before);
 await pg.raw('drop trigger fixture_reject_history_cutover on taskfold_private.team_content_projects;drop function public.fixture_reject_history_cutover()');
 const aCommand=command(baseA,a);check('actual reviewed adoption succeeds',(await call('creator','adopt',aCommand)).applied);
 const custodyBeforeReplay=await pg.scalar('select jsonb_agg(to_jsonb(x) order by feed,event_id,team_id) from taskfold_private.reviewed_history_custody x');
 check('applied custody receipt retries safely',(await call('creator','adopt',aCommand)).replayed);
 check('receipt retry does not mint or rewrite custody',await pg.scalar('select jsonb_agg(to_jsonb(x) order by feed,event_id,team_id) from taskfold_private.reviewed_history_custody x'),custodyBeforeReplay);
 check('feed identity prevents UUID collision leak',await pg.scalar(`select jsonb_build_array(taskfold_private.history_is_custodied('root',${lit(collision)}),taskfold_private.history_is_custodied('child',${lit(collision)}))`),[false,true]);
 await expect('new joint custody invalidates other pending review',()=>call('creator','adopt',command(baseB,bBeforeA)),'PT409');
 check('moving root remains personal',await pg.scalar(`select to_json(taskfold_private.is_team_content_task(${lit(root)}))`),false);
 check('deleted root never acquires task authority',await pg.scalar(`select to_json(taskfold_private.is_team_content_task(${lit(deleted)}))`),false);
 const read=(n,table)=>pg.scalar(`begin;${identity(n)}set local role authenticated;select coalesce(jsonb_agg(to_jsonb(x) order by sequence),'[]') from public.${table} x;commit`);
 const tables=[['root','task_activity'],['child','task_node_activity']];
 step='scoped reads';for(const [feed,table] of tables){
  const visible=await read('memberA',table);
  check(feed+' deleted-root history remains readable',visible.some(e=>e.task_id===deleted));
  check(feed+' old selected-project intervals remain readable',visible.some(e=>e.task_id===root&&e.after_state.project_id===p));
  check(feed+' private current-project intervals never leak',visible.every(e=>[e.before_state.project_id,e.after_state.project_id].filter(Boolean).every(x=>x===p)));
  check(feed+' unrelated Inbox history never leaks',visible.some(e=>e.task_id===personal),false);
  check(feed+' no outsider read',(await read('outsider',table)).length,0);
  check(feed+' other team has no read',(await read('memberB',table)).length,0);
 }
 await pg.raw(`update taskfold_private.team_project_config set native_reads_enabled=false`);check('disabled rollout hides reviewed history',(await read('creator','task_node_activity')).some(e=>e.task_id===deleted),false);await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true');
 await pg.raw(`update auth.sessions set not_after=now()-interval '1 minute' where id=${lit(users.memberA.session)}`);check('expired session hides retained history',(await read('memberA','task_activity')).length,0);await pg.raw(`update auth.sessions set not_after=null where id=${lit(users.memberA.session)}`);
 await pg.raw(`delete from taskfold_private.team_members where team_id=${lit(teams.A)} and user_id=${lit(users.memberA.id)}`);check('member removal hides retained history',(await read('memberA','task_node_activity')).length,0);await pg.raw(`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(teams.A)},${lit(users.memberA.id)},'member')`);
 const deleteTeam=async k=>{const revision=await pg.scalar(`select revision from taskfold_private.teams where id=${lit(teams[k])}`);return pg.scalar(`begin;${identity(k==='C'?'ownerA':'owner'+k)}set local role authenticated;select public.taskfold_teams('delete',${json({team_id:teams[k],revision,request_id:randomUUID(),issued_at:new Date().toISOString()})});commit`)};
 step='joint custody';const heldReview=await review(baseB),heldCommand=command(baseB,heldReview);
 const transferHold=await pg.hold(`${identity('creator')}set local role authenticated;select public.taskfold_team_project_adoption('adopt',${json(heldCommand)});reset role;`);
 try{await expect('team deletion never waits behind unseen custody',()=>deleteTeam('A'),'PT409')}finally{await transferHold.release('rollback')}
 check('failed concurrent team deletion preserves source history',await ledgers(),before);
 const b=await review(baseB);check('second separately reviewed adoption succeeds',(await call('creator','adopt',command(baseB,b))).applied);
 const links=await pg.scalar('select jsonb_agg(to_jsonb(x)) from taskfold_private.reviewed_history_custody x');check('some observed events have joint custody',links.some(x=>links.some(y=>x.feed===y.feed&&x.event_id===y.event_id&&x.team_id!==y.team_id)));
 for(const [feed,table] of tables){const visible=await read('both',table);check(feed+' cross-scope event readable with both current permissions',visible.some(e=>e.before_state.project_id===p&&e.after_state.project_id===q));check(feed+' single-team user never sees other scope',(await read('memberB',table)).every(e=>[e.before_state.project_id,e.after_state.project_id].filter(Boolean).every(x=>x===q)));}
 step='personal counterpart';teams.C=randomUUID();
 await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(teams.C)},${lit(users.ownerA.id)},'Synthetic personal counterpart');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(teams.C)},${lit(users.ownerA.id)},'admin'),(${lit(teams.C)},${lit(users.creator.id)},'member')`);
 const past=randomUUID(),stillPersonal=randomUUID(),personalRoot=randomUUID(),oldInbox=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(past)},${lit(users.creator.id)},'Past shared branch'),(${lit(stillPersonal)},${lit(users.creator.id)},'Still personal');begin;${identity('creator')}insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(personalRoot)},${lit(users.creator.id)},${lit(past)},'Synthetic personal counterpart',true,${json(tree(false))});update public.tasks set project_id=${lit(stillPersonal)} where id=${lit(personalRoot)};commit`);
 await pg.raw(`begin;${identity('creator')}insert into public.tasks(id,user_id,title,is_heading,subtasks) values(${lit(oldInbox)},${lit(users.creator.id)},'Synthetic prior Inbox',true,${json(tree(false))});update public.tasks set project_id=${lit(past)} where id=${lit(oldInbox)};commit`);
 const cBase=scope(teams.C,past),cReview=await review(cBase);await call('creator','adopt',command(cBase,cReview));
 for(const [feed,table] of tables)check(feed+' authorized personal owner can read cross-scope history',(await read('creator',table)).some(e=>e.task_id===personalRoot&&e.before_state.project_id===past&&e.after_state.project_id===stillPersonal));
 await deleteTeam('C');check('deleting historical team preserves personal live root',await pg.scalar(`select count(*) from public.tasks where id=${lit(personalRoot)}`),1);
 for(const [feed,table] of tables){const records=(await ledgers())[feed]??[];check(feed+' personal counterpart record is retained',records.some(e=>e.task_id===personalRoot&&e.before_state.project_id===past&&e.after_state.project_id===stillPersonal));check(feed+' exclusively deleted-project record is removed',records.some(e=>e.task_id===personalRoot&&e.kinds.includes('created')),false);check(feed+' deleted team state stays hidden from personal creator',(await read('creator',table)).some(e=>e.task_id===personalRoot),false);}
 for(const [feed,table] of tables)check(feed+' personal Inbox archive stays with its active owner',(await read('creator',table)).some(e=>e.task_id===oldInbox&&e.after_state.project_id===null));
 step='author removal';const beforeRemoval=await ledgers();await pg.raw(`delete from auth.users where id=${lit(users.creator.id)}`);
 for(const [feed,table] of tables){
  const afterRemoval=(await ledgers())[feed]??[];const retained=(beforeRemoval[feed]??[]).filter(e=>links.some(h=>h.feed===feed&&h.event_id===e.id));
  check(feed+' reviewed events survive author removal exactly',afterRemoval.filter(e=>retained.some(x=>x.id===e.id)),retained.map(e=>({...e,actor_id:e.actor_id===users.creator.id?null:e.actor_id})));
  check(feed+' personal history physically removed',afterRemoval.some(e=>e.task_id===personal||e.task_id===personalRoot||e.task_id===oldInbox),false);
  check(feed+' creator never substitutes for removed actor',afterRemoval.filter(e=>retained.some(x=>x.id===e.id)).every(e=>e.user_id===users.creator.id&&e.actor_id===null));
  check(feed+' surviving member reads deleted-root history',(await read('memberA',table)).some(e=>e.task_id===deleted));
  check(feed+' removed author token grants no history',(await read('creator',table)).length,0);
 }
 if(process.env.TASKFOLD_HISTORY_CUSTODY_ROWS)await writeFile(process.env.TASKFOLD_HISTORY_CUSTODY_ROWS,JSON.stringify({root:await read('memberA','task_activity'),child:await read('memberA','task_node_activity')},null,2)+'\n');
 step='closed authority';for(const role of ['anon','authenticated','service_role'])check('custody registry closed to '+role,await pg.scalar(`select to_json(has_table_privilege(${lit(role)},'taskfold_private.reviewed_history_custody','SELECT,INSERT,UPDATE,DELETE'))`),false);
 check('no callable history registration',await pg.scalar("select to_json(has_function_privilege('authenticated','taskfold_private.register_reviewed_history_custody(uuid,uuid[])','EXECUTE'))"),false);
 await expect('missing reviewed scope cannot mint custody',()=>pg.raw(`select taskfold_private.register_reviewed_history_custody(${lit(teams.A)},array[${lit(p)}::uuid])`),'42501');

 const object=randomUUID();await pg.raw(`insert into storage.objects(id,bucket_id,name,owner,owner_id) values(${lit(object)},'task-attachments',${lit(users.ownerA.id+'/synthetic-history-guard')},${lit(users.ownerA.id)},${lit(users.ownerA.id)});insert into taskfold_private.team_content_files(object_id,project_id) values(${lit(object)},${lit(p)})`);
 const beforeBlocked=await ledgers();await expect('storage guard blocks history cleanup',()=>deleteTeam('A'),'PT409');check('failed deletion retains all source history',await ledgers(),beforeBlocked);await pg.raw(`delete from taskfold_private.team_content_files where object_id=${lit(object)};delete from storage.objects where id=${lit(object)}`);
 step='team cleanup';await deleteTeam('A');
 for(const [feed,table] of tables){const remaining=(await ledgers())[feed]??[];check(feed+' exclusively owned deleted-root events removed',remaining.some(e=>e.task_id===deleted),false);check(feed+' jointly owned history retained',remaining.some(e=>links.some(h=>h.feed===feed&&h.event_id===e.id&&h.team_id===teams.A)));check(feed+' deleting old team never deletes current other-team task',await pg.scalar(`select count(*) from public.tasks where id=${lit(root)}`),1);check(feed+' deleted-project metadata inaccessible after team deletion',(await read('both',table)).every(e=>![e.before_state.project_id,e.after_state.project_id].includes(p)));check(feed+' remaining team work history still readable',(await read('memberB',table)).some(e=>e.after_state.project_id===q));}
 await deleteTeam('B');for(const [feed] of tables)check(feed+' last custodian deletion removes all recorded events',((await ledgers())[feed]??[]).length,0);
 check('UUID-only custody tombstones remain',await pg.scalar('select count(*) from taskfold_private.reviewed_history_custody')>0);
 step='advisors';report.advisors=await pg.advisors();check('official advisors ran',report.advisors.ran);check('no new custody advisor finding',report.advisors.result.filter(f=>/reviewed_history_custody|history_native_read|history_has_live_custody/.test(JSON.stringify(f))),[]);
 console.log('PASS '+Object.keys(report.checks).length+' reviewed history custody checks');
}catch(error){report.failedStep=step;report.error={message:error.message,code:error.code};process.exitCode=1;console.error('FAIL '+step+': '+error.message+' '+(error.code??''))}
finally{if(pg)report.ownedFixtureRemoved=await pg.close();const i=process.argv.indexOf('--report');if(i>=0)await writeFile(process.argv[i+1],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:Object.keys(report.checks).length,failedStep:report.failedStep,ownedFixtureRemoved:report.ownedFixtureRemoved}))}
