// Exercise fresh typed actions after Undo using the real existing SQL authority.
// No hosted deployment, server schema change or real account is used.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
const report={checks:{},deployed:false,wireProtocolUnchanged:true};let pg;
const json=x=>lit(JSON.stringify(x))+'::jsonb';
const check=(name,actual,expected)=>{assert.deepEqual(actual,expected,name);report.checks[name]=true;};
try {
 pg=await createPostgresFixture({advisors:true});await loadChildAuthorityDependencies(pg);
 for(const file of [childAuthorityMigration,'20261031180359_child_field_history_removals.sql']) {
  const sql=await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8');await pg.raw(sql);(report.loadedSQLSHA256??={})[file]=createHash('sha256').update(sql).digest('hex');
 }
 report.baselineAdvisors=await pg.advisors();
 const owner={id:randomUUID(),session:randomUUID()},editor={id:randomUUID(),session:randomUUID()},viewer={id:randomUUID(),session:randomUUID()};
 for(const who of [owner,editor,viewer])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(who.id)},${lit(who.id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(who.id)});insert into auth.sessions(id,user_id) values(${lit(who.session)},${lit(who.id)});`);
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true;update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
 const call=(fn,body,who)=>pg.scalar(`begin;create temp table result(value jsonb,code text,reason text,context text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${lit(who.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:who.id,session_id:who.session}))};do $op$declare c text;begin begin insert into result values(${fn}(${json(body)}),null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into result values(null,sqlstate,sqlerrm,c);end;end$op$;reset role;select to_jsonb(r) from result r;commit;`);
 for(const teamMode of [false,true]) {
  const label=teamMode?'team editor':'personal',task=randomUUID(),project=randomUUID(),team=randomUUID(),who=teamMode?editor:owner;
  report.stage=label;
  const initial=[{id:'branch',title:'Keep authored branch',description:'Keep original notes',completed:false,completed_at:null,taskfold_completion_v1:{epoch:randomUUID(),version:0},future:{keep:[false,null,'Café']},comments:[{id:'discussion',text:'Keep discussion'}],attachments:[{id:'file',url:'https://example.invalid/file'}],subtasks:[{id:'nested',title:'Keep nested work',completed:true,completed_at:'2026-10-01T09:00:00Z',taskfold_completion_v1:{epoch:randomUUID(),version:2},subtasks:null}]},{id:'destination',title:'Destination',subtasks:null}];
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic history project');`);
  if(teamMode)await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Synthetic history team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(editor.id)},'member'),(${lit(team)},${lit(viewer.id)},'member');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(project)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(project)},${lit(team)},${lit(editor.id)},'editor'),(${lit(project)},${lit(team)},${lit(viewer.id)},'viewer');`);
  await pg.raw(`insert into public.tasks(id,user_id,project_id,title,subtasks) values(${lit(task)},${lit(owner.id)},${lit(project)},'Synthetic hierarchy history',${json(initial)});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(task)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(task)};`);
  const row=()=>pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`),nodes=()=>pg.scalar(`select jsonb_agg(to_jsonb(n) order by node_key) from taskfold_private.child_task_records n where task_id=${lit(task)}`),node=async key=>(await nodes()).find(n=>n.node_key===key);
  const archiveCount=()=>pg.scalar(`select count(*) from taskfold_private.child_task_structure_archives where task_id=${lit(task)}`);
  const body=async(action,extra,revision)=>({protocol:1,account:who.id,request_id:randomUUID(),task_id:task,task_generation:(await row()).task_generation,project_id:project,structure_revision:revision??await pg.scalar(`select structure_revision from taskfold_private.child_task_projections where task_id=${lit(task)}`),action,...extra});
  const send=async (command,name)=>{const reply=await call('public.taskfold_edit_child_structure',command,who);report.lastDiagnostic=reply;check(label+' '+name,reply.code,null);return reply.value;};
  const undo=async(command,receipt,name)=>{const action=await body('undo',{undo_of:command.request_id},receipt.after_revision);return [action,await send(action,name)];};
  const insertNode={id:'fresh',title:'Authored addition',description:'Exact inserted notes',subtasks:[{id:'fresh-nested',title:'Authored nested addition',subtasks:[]}]};
  const insertion=await body('insert',{node:insertNode,parent_key:null,index:0}),inserted=await send(insertion,'insert applies');
  const [,insertUndone]=await undo(insertion,inserted,'insert Undo applies');check(label+' added branch is absent after Undo',await node('fresh'),undefined);
  const redoInsert=await body('insert',{node:insertNode,parent_key:null,index:0},insertUndone.after_revision),insertRedone=await send(redoInsert,'fresh insert Redo applies');check(label+' insert Redo has a fresh incarnation',insertRedone.incarnation!==inserted.incarnation,true);
  await undo(redoInsert,insertRedone,'insert Undo after Redo applies');check(label+' insert cycle keeps exact existing tree',(await row()).subtasks,initial);
  const branchInc=(await node('branch')).incarnation;
  const move=await body('move',{node_key:'branch',incarnation:branchInc,parent_key:'destination',index:0}),moved=await send(move,'move applies');
  const [,moveUndone]=await undo(move,moved,'move Undo applies');
  const field=async(key,changes)=>{const n=await node(key);return call('public.taskfold_edit_child_task',{protocol:1,account:who.id,request_id:randomUUID(),task_id:task,task_generation:(await row()).task_generation,project_id:project,node_key:key,incarnation:n.incarnation,revision:n.revision,changes},who);};
  check(label+' unrelated field edit after move Undo succeeds',(await field('branch',{description:'Later notes stay with the branch'})).code,null);
  const redoMove=await body('move',{node_key:'branch',incarnation:branchInc,parent_key:'destination',index:0},moveUndone.after_revision),moveRedone=await send(redoMove,'fresh move Redo keeps later field edits');check(label+' moved later notes retained',(await node('branch')).fields.description,'Later notes stay with the branch');
  await undo(redoMove,moveRedone,'move Undo after Redo applies');check(label+' null destination container restored',(await row()).subtasks[1].subtasks,null);
  const versions=async()=>Object.fromEntries((await nodes()).filter(n=>n.identity_path[0]==='branch').map(n=>[n.node_key,{incarnation:n.incarnation,revision:n.revision}]));
  const deletion=await body('delete',{node_key:'branch',incarnation:(await node('branch')).incarnation,subtree_versions:await versions()}),deleted=await send(deletion,'delete applies');
  const [,restored]=await undo(deletion,deleted,'delete Undo restores archive');check(label+' every restored branch node starts at revision one',Object.values(await versions()).every(v=>v.revision===1),true);check(label+' restored root gets new incarnation',(await node('branch')).incarnation!==branchInc,true);
  const redoDelete=await body('delete',{node_key:'branch',incarnation:restored.incarnation,subtree_versions:await versions()},restored.after_revision),deletedAgain=await send(redoDelete,'fresh delete Redo applies');check(label+' latest Redo owns one archive',await archiveCount(),1);
  const immutable=await row();check(label+' Redo retry is exact metadata replay',(await send(redoDelete,'delete Redo retry succeeds')).replayed,true);check(label+' Redo retry has no second root write',await row(),immutable);
  const [,restoredAgain]=await undo(redoDelete,deletedAgain,'delete Undo after Redo restores archive');check(label+' final Undo consumes the latest archive',await archiveCount(),0);
  const tree=(await row()).subtasks;check(label+' opaque fields retained',tree[0].future,initial[0].future);check(label+' discussion retained',tree[0].comments,initial[0].comments);check(label+' file references retained',tree[0].attachments,initial[0].attachments);check(label+' historical completion retained',tree[0].subtasks[0].completed,true);check(label+' authored later notes retained',tree[0].description,'Later notes stay with the branch');check(label+' sibling exact',tree[1],initial[1]);
  const frozenDelete=await body('delete',{node_key:'branch',incarnation:restoredAgain.incarnation,subtree_versions:await versions()},restoredAgain.after_revision);
  check(label+' nested later edit succeeds',(await field('nested',{title:'A newer nested intent'})).code,null);check(label+' nested equal-looking restoration is a newer edit',(await field('nested',{title:initial[0].subtasks[0].title})).code,null);
  const preserved=await row();check(label+' frozen Redo refuses later nested edits',(await call('public.taskfold_edit_child_structure',frozenDelete,who)).code,'PT409');check(label+' refused Redo preserves entire current task',await row(),preserved);check(label+' refused Redo does not create archive',await archiveCount(),0);
  const actor=teamMode?viewer:editor;check(label+' non-editor cannot submit history',(await call('public.taskfold_edit_child_structure',{...frozenDelete,request_id:randomUUID(),account:actor.id},actor)).code,'42501');
 }
 report.advisors=await pg.advisors();const baseline=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no added advisor findings',report.advisors.result.filter(x=>!baseline.has(x.cache_key)),[]);report.status='passed';
} catch(error){report.status='failed';report.error=error.message;throw error;}
finally {if(pg)report.containerRemoved=await pg.close();report.checkCount=Object.keys(report.checks).length;if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({status:report.status,checks:report.checkCount,stage:report.stage,containerRemoved:report.containerRemoved}));}
