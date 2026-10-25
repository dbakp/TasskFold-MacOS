import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadProjectOwnershipSchema,projectOwnershipMigration} from './project-ownership-schema.mjs';
const report={checks:{},hostedChanges:false,adoptionAPIEnabled:false,realUserDataChanged:false};
const check=(n,a,b=true)=>{assert.deepEqual(a,b,n);report.checks[n]=true};
const json=v=>lit(JSON.stringify(v))+'::jsonb';
const owner=randomUUID(),member=randomUUID(),outside=randomUUID(),team=randomUUID(),sessions=Object.fromEntries([owner,member,outside].map(id=>[id,randomUUID()]));
let pg;
try {
 pg=await createPostgresFixture({advisors:true});await loadProjectOwnershipSchema(pg.raw);
 report.migrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+projectOwnershipMigration,import.meta.url))).digest('hex');
 for(const id of [owner,member,outside])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(id)},${lit(id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(id)});insert into auth.sessions(id,user_id) values(${lit(sessions[id])},${lit(id)});`);
 await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner)},'Ownership workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner)},'admin'),(${lit(team)},${lit(member)},'member');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true;`);
 const identity=id=>`set local request.jwt.claim.sub=${lit(id)};set local request.jwt.claims=${lit(JSON.stringify({sub:id,session_id:sessions[id]}))};`;
 const project=async(parent=null)=>{const id=randomUUID();await pg.raw(`insert into public.projects(id,user_id,name,parent_id) values(${lit(id)},${lit(owner)},'Personal workshop',${parent?lit(parent):'null'});`);return id};
 const insertTask=(id,p,title='Cutover proof',parent=null)=>`insert into public.tasks(id,user_id,project_id,title,recurrence_parent_id) values(${lit(id)},${lit(owner)},${lit(p)},${lit(title)},${parent?lit(parent):'null'});`;
 const row=id=>pg.scalar(`select coalesce((select to_jsonb(t) from public.tasks t where id=${lit(id)}),'null'::jsonb)`);
 const bind=p=>`insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(p)},${lit(team)});`;
 const expect=async(name,fn,code)=>{try{await fn();assert.fail(name+' unexpectedly succeeded')}catch(e){check(name,e.code,code)}};
 const tickets=()=>pg.scalar('select to_jsonb(count(*)) from taskfold_private.project_realm_writes');
 const epoch=(table,id)=>pg.scalar(`select coalesce((select to_jsonb(revision) from taskfold_private.project_content_epochs where table_name=${lit(table)} and row_id=${lit(id)}),'0')`);
 const p=await project(),id=randomUUID();await pg.raw(insertTask(id,p));const original=await row(id),before=await epoch('tasks',id);
 await pg.raw(`update public.tasks set description='New authored text' where id=${lit(id)}`);await pg.raw(`update public.tasks set description=null where id=${lit(id)}`);
 check('content edit and revert advances epoch',await epoch('tasks',id),before+2);check('reverted task remains exact',await row(id),original);check('ordinary writes consume all tickets',await tickets(),0);
 const projectEpoch=await epoch('projects',p);await pg.raw(`delete from public.tasks where id=${lit(id)};delete from public.projects where id=${lit(p)};insert into public.projects(id,user_id,name) values(${lit(p)},${lit(owner)},'Personal workshop');`);
 check('project delete recreate advances epoch',await epoch('projects',p),projectEpoch+2);
 check('epoch table private',await pg.scalar("select to_jsonb(not has_table_privilege('authenticated','taskfold_private.project_content_epochs','SELECT') and not has_table_privilege('service_role','taskfold_private.project_realm_writes','INSERT'))"));
 await expect('no client fence authority',()=>pg.raw(`set role authenticated;select taskfold_private.try_project_adoption_fences(array[${lit(p)}::uuid]);`),'42501');
 await expect('no client scope authority',()=>pg.raw(`set role authenticated;insert into taskfold_private.team_project_adoption_scope values(txid_current(),${lit(owner)},${lit(team)},${lit(p)},${lit(p)},null,'team',null);`),'42501');
 const ghost=await project(),ghostID=randomUUID();
 const old=await pg.hold(`${identity(owner)}set local role authenticated;${insertTask(ghostID,ghost)}`);
 await pg.raw(`begin;select taskfold_private.try_project_adoption_fences(array[${lit(ghost)}::uuid]);${bind(ghost)}commit;`);
 await expect('pre-cutover insertion cannot commit afterward',()=>old.release('commit'),'PT409');
 check('ghost task rolled back',await row(ghostID),null);check('ghost task custody not invented',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_content_tasks where task_id=${lit(ghostID)}`),0);
 check('ghost epoch rolls back',await epoch('tasks',ghostID),0);check('failed cutover write leaves no tickets',await tickets(),0);
 // A child project and a discussion insertion can pass their original
 // personal checks too. The same commit barrier covers those phantoms.
 const tree=await project(),newChild=randomUUID();
 const childWriter=await pg.hold(`${identity(owner)}set local role authenticated;insert into public.projects(id,user_id,name,parent_id) values(${lit(newChild)},${lit(owner)},'Late subproject',${lit(tree)});`);
 await pg.raw(bind(tree));await expect('pre-cutover subproject cannot join team afterward',()=>childWriter.release('commit'),'PT409');
 check('late subproject rolled back',await pg.scalar(`select to_jsonb(count(*)) from public.projects where id=${lit(newChild)}`),0);
 const discussionProject=await project(),discussionTask=randomUUID(),lateComment=randomUUID();await pg.raw(insertTask(discussionTask,discussionProject));
 const commentWriter=await pg.hold(`${identity(owner)}insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) select ${lit(lateComment)},id,task_generation,project_id,${lit(owner)},'Late private discussion' from public.tasks where id=${lit(discussionTask)};`);
 await pg.raw(bind(discussionProject));await expect('pre-cutover discussion cannot commit afterward',()=>commentWriter.release('commit'),'PT409');
 check('late discussion rolled back',await pg.scalar(`select to_jsonb(count(*)) from public.task_comments where id=${lit(lateComment)}`),0);
 const edited=await project(),editedTask=randomUUID();await pg.raw(insertTask(editedTask,edited));const beforeEdit=await row(editedTask);
 const editWriter=await pg.hold(`${identity(owner)}set local role authenticated;update public.tasks set description='Late private edit' where id=${lit(editedTask)};`);
 await pg.raw(bind(edited));await expect('pre-cutover existing edit cannot commit afterward',()=>editWriter.release('commit'),'PT409');check('late edit leaves exact original',await row(editedTask),beforeEdit);
 const inviteProject=await project(),invitation=randomUUID();
 await pg.raw(`begin;${identity(owner)}insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(${lit(invitation)},${lit(inviteProject)},${lit(member+'@example.invalid')},${lit(owner)});commit;`);
 const acceptance=await pg.hold(`${identity(member)}update public.project_collaborators set status='accepted' where id=${lit(invitation)};`);
 await pg.raw(bind(inviteProject));await expect('pre-cutover invitation acceptance cannot commit afterward',()=>acceptance.release('commit'),'PT409');
 check('late acceptance remains pending',await pg.scalar(`select to_jsonb(status) from public.project_collaborators where id=${lit(invitation)}`),'pending');
 await expect('fresh legacy acceptance against team remains closed',()=>pg.raw(`begin;${identity(member)}update public.project_collaborators set status='accepted' where id=${lit(invitation)};commit;`),'42501');
 const held=await project(),heldID=randomUUID();
 const writer=await pg.hold(`${identity(owner)}set local role authenticated;${insertTask(heldID,held)}set constraints taskfold_private.project_ownership_at_commit immediate`);
 await expect('finishing old transaction refuses adoption fence',()=>pg.raw(`select taskfold_private.try_project_adoption_fences(array[${lit(held)}::uuid])`),'PT409');
 await writer.release();check('old writer remains intact',!!(await row(heldID)));await pg.raw(bind(held));check('later binding captures finished task',await pg.scalar(`select to_jsonb(team_id) from taskfold_private.team_content_tasks where task_id=${lit(heldID)}`),team);
 const fenceProject=await project(),otherProject=await project();
 const fence=await pg.hold(`select taskfold_private.try_project_adoption_fences(array[${lit(fenceProject)}::uuid])`);
 const blockedID=randomUUID();await expect('writer refuses active transfer without waiting',()=>pg.raw(`begin;${identity(owner)}set local role authenticated;${insertTask(blockedID,fenceProject)}commit;`),'PT409');
 check('refused writer changes no task',await row(blockedID),null);const otherID=randomUUID();await pg.raw(insertTask(otherID,otherProject));check('unrelated project still writes',!!(await row(otherID)));await fence.release('rollback');
 const cross=await pg.hold(`${identity(owner)}set local role authenticated;${insertTask(randomUUID(),otherProject)}set constraints taskfold_private.project_ownership_at_commit immediate`);
 const gate=await pg.hold(`select taskfold_private.try_project_adoption_fences(array[${lit(fenceProject)}::uuid])`);
 const crossID=randomUUID();await expect('early constraint transaction cannot wait in a lock cycle',()=>cross.release('commit',insertTask(crossID,fenceProject)),'PT409');await gate.release('rollback');check('cross-project rollback is atomic',await row(crossID),null);
 // Captured original personal participants survive planned binding; a scope is
 // never an authenticated client's shortcut for inventing a transfer.
 const root=await project(),child=await project(root),parentTask=randomUUID(),childTask=randomUUID(),collab=randomUUID();
 await pg.raw(`${insertTask(parentTask,root)}${insertTask(childTask,child,'Linked occurrence',parentTask)}`);
 await pg.raw(`begin;${identity(owner)}insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(${lit(collab)},${lit(root)},${lit(member+'@example.invalid')},${lit(owner)});update public.project_collaborators set status='accepted' where id=${lit(collab)};update public.tasks set assigned_to=${lit(member)},subtasks=${json([{id:randomUUID(),title:'Keep provenance',completed:false,assigned_to:member,subtasks:[]}])} where id=${lit(parentTask)};commit;`);
 const assigned=await row(parentTask),provenance=await pg.scalar(`select jsonb_agg(to_jsonb(p) order by p.node_key) from public.task_assignment_provenance p where task_id=${lit(parentTask)}`);
 await expect('unreviewed branch binding remains refused',()=>pg.raw(bind(root)),'22023');
 await pg.raw(`begin;${identity(owner)}insert into taskfold_private.team_project_adoption_scope values(txid_current(),${lit(owner)},${lit(team)},${lit(root)},${lit(root)},null,'team',null),(txid_current(),${lit(owner)},${lit(team)},${lit(child)},${lit(root)},${lit(root)},'team',null);delete from public.project_collaborators where id=${lit(collab)};${bind(child)}${bind(root)}delete from taskfold_private.team_project_adoption_scope where transaction_id=txid_current();commit;`);
 check('reviewed forest retains exact assigned task',await row(parentTask),assigned);check('reviewed forest retains linked occurrence',(await row(childTask)).recurrence_parent_id,parentTask);
 check('reviewed forest retains assignment provenance',await pg.scalar(`select jsonb_agg(to_jsonb(p) order by p.node_key) from public.task_assignment_provenance p where task_id=${lit(parentTask)}`),provenance);
 check('reviewed forest has both custody rows',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_content_tasks where task_id=any(array[${lit(parentTask)}::uuid,${lit(childTask)}::uuid])`),2);
 check('obsolete personal collaboration retired',await pg.scalar(`select to_jsonb(count(*)) from public.project_collaborators where project_id=${lit(root)}`),0);check('successful scope erased',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_project_adoption_scope'),0);check('successful cutover consumes all tickets',await tickets(),0);
 const oldParent=await project(),detach=await project(oldParent);
 await expect('final planned parent enforced after scope erased',()=>pg.raw(`begin;${identity(owner)}insert into taskfold_private.team_project_adoption_scope values(txid_current(),${lit(owner)},${lit(team)},${lit(detach)},${lit(detach)},null,'team',null);${bind(detach)}delete from taskfold_private.team_project_adoption_scope where transaction_id=txid_current();commit;`),'PT409');
 check('incomplete placement rolls back binding',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_content_projects where project_id=${lit(detach)}`),0);
 check('incomplete placement rolls back identity',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_project_identities where project_id=${lit(detach)}`),0);
 // Source collaboration retirement outside a reviewed transfer is unchanged.
 const personal=await project(),task=randomUUID(),inv=randomUUID();await pg.raw(insertTask(task,personal));
 await pg.raw(`begin;${identity(owner)}insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(${lit(inv)},${lit(personal)},${lit(member+'@example.invalid')},${lit(owner)});update public.project_collaborators set status='accepted' where id=${lit(inv)};update public.tasks set assigned_to=${lit(member)} where id=${lit(task)};delete from public.project_collaborators where id=${lit(inv)};commit;`);
 check('normal departed assignee still cleared',(await row(task)).assigned_to,null);
 // Existing ordinary team creation deliberately changes its own new row realm.
 for(const actor of [owner,member]){
  const projectID=randomUUID(),body={team_id:team,project_id:projectID,team_revision:1,request_id:randomUUID(),issued_at:new Date().toISOString(),name:'Native create regression',visibility:'private',folder_id:null};
  const result=await pg.scalar(`begin;${identity(actor)}set local role authenticated;select public.taskfold_team_projects('create',${json(body)});commit;`);
  check('existing native team creation '+(actor===owner?'owner':'member'),result.id,projectID);
 }
 check('all native creation tickets consumed',await tickets(),0);
 // Read acknowledgements keep their original contents-review epoch.
 const mentionProject=await project(),mentionTask=randomUUID(),mentionComment=randomUUID(),mentionID=randomUUID(),mentionInvite=randomUUID();await pg.raw(insertTask(mentionTask,mentionProject));
 await pg.raw(`begin;${identity(owner)}insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(${lit(mentionInvite)},${lit(mentionProject)},${lit(member+'@example.invalid')},${lit(owner)});update public.project_collaborators set status='accepted' where id=${lit(mentionInvite)};insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body,mention_ids) select ${lit(mentionComment)},id,task_generation,project_id,${lit(owner)},'Read history proof',array[${lit(member)}::uuid] from public.tasks where id=${lit(mentionTask)};insert into public.task_mentions(id,comment_id,recipient_id) values(${lit(mentionID)},${lit(mentionComment)},${lit(member)});commit;`);
 const mentionEpoch=await epoch('task_mentions',mentionID);
 await pg.raw(`begin;${identity(member)}set local role authenticated;select public.taskfold_mark_mention(${lit(randomUUID())},${lit(mentionID)},1,true);commit;`);
 check('native mention read keeps content epoch',await epoch('task_mentions',mentionID),mentionEpoch);check('native mention read still saved',await pg.scalar(`select to_jsonb(read_at is not null) from public.task_mentions where id=${lit(mentionID)}`));
 const outsideProject=randomUUID(),outsideTask=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(outsideProject)},${lit(outside)},'Disposable personal data');insert into public.tasks(id,user_id,project_id,title) values(${lit(outsideTask)},${lit(outside)},${lit(outsideProject)},'Disposable removal proof');delete from auth.users where id=${lit(outside)};`);
 check('personal Auth cleanup still removes owned task',await row(outsideTask),null);check('personal Auth cleanup still removes owned project',await pg.scalar(`select to_jsonb(count(*)) from public.projects where id=${lit(outsideProject)}`),0);check('Auth cleanup leaves no tickets',await tickets(),0);
 await expect('control SQL failure reports original state and releases holder',()=>pg.hold('select missing_ownership_fixture_column from public.projects'),'42703');check('fixture remains usable after failed control session',await pg.scalar('select to_jsonb(1)'),1);
 report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
 report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
 if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close()}
