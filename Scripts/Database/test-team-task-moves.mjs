import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {randomUUID,createHash} from 'node:crypto';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadTeamWorkspaceSchema} from './team-workspace-schema.mjs';
const migration='20261025000653_team_task_moves.sql', report={checks:{},deployed:false,realDataChanged:false};
const check=(name,a,b=true)=>{assert.deepEqual(a,b,name);report.checks[name]=true};
const json=v=>lit(JSON.stringify(v))+'::jsonb';
const users=Object.fromEntries(['owner','editor','viewer','outsider'].map(x=>[x,{id:randomUUID(),session:randomUUID()}]));
const team=randomUUID(),p=randomUUID(),dest=randomUUID(),foreign=randomUUID(),foreignTeam=randomUUID(),personal=randomUUID(),section=randomUUID();
let pg;
try {
 pg=await createPostgresFixture({advisors:true});
 const sql=await readFile(new URL('../../supabase/migrations/'+migration,import.meta.url),'utf8');
 if(process.env.TASKFOLD_CHILD_TRANSFER_SQL){
  const {loadChildAuthorityDependencies,childAuthorityMigration}=await import('./child-task-authority-schema.mjs');await loadChildAuthorityDependencies(pg);
  const authority=await readFile(new URL('../../supabase/migrations/'+childAuthorityMigration,import.meta.url),'utf8');await pg.raw(authority);
  const transfer=await readFile(process.env.TASKFOLD_CHILD_TRANSFER_SQL,'utf8');await pg.raw(transfer);
  report.authorityMigrationSHA256=createHash('sha256').update(authority).digest('hex');report.transferMigrationSHA256=createHash('sha256').update(transfer).digest('hex');
 }else{await loadTeamWorkspaceSchema(pg.raw);await pg.raw(sql);}
 report.migrationSHA256=createHash('sha256').update(sql).digest('hex');
 if(process.env.TASKFOLD_PROJECT_OWNERSHIP_REGRESSION==='1'){const {loadProjectOwnershipSchema,projectOwnershipMigration}=await import('./project-ownership-schema.mjs');await loadProjectOwnershipSchema(pg.raw,{base:false});report.ownershipMigration=projectOwnershipMigration;}
 for(const [name,u] of Object.entries(users))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(name+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});`);
 for(const t of [team,foreignTeam])await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(t)},${lit(users.owner.id)},'Move workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(t)},${lit(users.owner.id)},'admin');`);
 for(const [name,u] of Object.entries(users).filter(([x])=>x!=='outsider'&&x!=='owner'))await pg.raw(`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(u.id)},${lit(name==='owner'?'admin':'member')});`);
 for(const id of [p,dest,foreign,personal]){await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(id)},${lit(users.owner.id)},${lit('Project '+id.slice(0,4))});`);if(id!==personal)await pg.raw(`insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(id)},${lit(id===foreign?foreignTeam:team)});`);}
 await pg.raw(`insert into public.sections(id,user_id,project_id,name) values(${lit(section)},${lit(users.owner.id)},${lit(p)},'Original section');insert into taskfold_private.team_project_grants values(${lit(p)},${lit(team)},${lit(users.viewer.id)},'viewer');insert into taskfold_private.team_project_grants values(${lit(dest)},${lit(team)},${lit(users.viewer.id)},'viewer');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true;`);
 const run=(who,expr,opts={})=>{const u=users[who];return pg.scalar(`begin;set local application_name=${lit(opts.app??'taskfold-move-check')};create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;set local role ${opts.role??'authenticated'};set local request.jwt.claim.sub=${lit(u.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:u.id,session_id:opts.session??u.session}))};do $r$begin begin ${opts.statement??`insert into result values((${expr}),null,null);`}exception when others then insert into result values(null,sqlstate,left(sqlerrm,240));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`)};
 const rpc=(who,op,b,opts)=>run(who,`public.taskfold_team_task_move(${lit(op)},${json(b)})`,opts);
 const row=id=>pg.scalar(`select (select to_jsonb(t) from public.tasks t where id=${lit(id)})`);
 const seed=async(title='Move proof')=>{const id=randomUUID(),child=randomUUID(),comment=randomUUID(),mention=randomUUID();await pg.raw(`insert into public.tasks(id,user_id,project_id,section_id,title,description,assigned_to,labels,subtasks) values(${lit(id)},${lit(users.owner.id)},${lit(p)},${lit(section)},${lit(title)},'Keep all authored notes',${lit(users.editor.id)},array['Shared design'],${json([{id:child,title:'Check the layout',completed:false,assigned_to:users.editor.id,description:'Child notes',subtasks:[]}])});insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body,mention_ids)select ${lit(comment)},id,task_generation,project_id,${lit(users.editor.id)},'Keep the discussion',array[${lit(users.viewer.id)}::uuid] from public.tasks where id=${lit(id)};insert into public.task_mentions(id,comment_id,recipient_id,read_at) values(${lit(mention)},${lit(comment)},${lit(users.viewer.id)},now());`);return {id,child,comment,mention,row:await row(id)}};
 const scope=t=>({team_id:team,task_id:t.id,task_generation:t.row.task_generation,source_project_id:p,destination_project_id:dest});
 const command=(b,review)=>({...b,request_id:randomUUID(),expires_at:review.expires_at,review_token:review.review_token});
 const t=await seed(),b=scope(t),before=t.row;
 const reviewed=await rpc('editor','review',b);check('review success '+(reviewed.reason??''),reviewed.code,null);const review=reviewed.value;
 check('review no mutation',await row(t.id),before);check('review assignment count',review.cleared_assignments,2);check('review discussion count',review.discussion_count,1);check('review literal task',review.task,before);check('review token bounded',/^[0-9a-f]{64}$/.test(review.review_token));
 const cmd=command(b,review),moved=await rpc('editor','move',cmd);check('move success',moved.code,null);check('move not replayed',moved.value.replayed,false);
 const after=await row(t.id);check('same identity/generation/creator',[after.id,after.task_generation,after.user_id],[before.id,before.task_generation,before.user_id]);check('destination',after.project_id,dest);check('assignments cleared',[after.assigned_to,after.subtasks[0].assigned_to??null],[null,null]);check('section cleared',after.section_id,null);
 for(const k of ['title','description','labels','reminder_specs','recurrence_pattern','created_at'])check('keep '+k,after[k],before[k]);
 const discussion=await pg.scalar(`select to_jsonb(c) from public.task_comments c where id=${lit(t.comment)}`);check('discussion moved with revision',[discussion.project_id,discussion.revision,discussion.body],[dest,2,'Keep the discussion']);
 const mention=await pg.scalar(`select to_jsonb(m) from public.task_mentions m where id=${lit(t.mention)}`);check('mention read state kept',mention.read_at!==null);check('custody follows',await pg.scalar(`select to_jsonb(project_id) from taskfold_private.team_content_tasks where task_id=${lit(t.id)} and generation=${lit(before.task_generation)}`),dest);
 check('scope cleared',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_task_move_scope'),0);
 check('replay success',(await rpc('editor','move',cmd)).value.replayed);check('replay no mutation',await row(t.id),after);
 check('journal contains no notes',await pg.scalar(`select to_jsonb(not exists(select 1 from taskfold_private.team_task_edits where request_id=${lit(cmd.request_id)} and to_jsonb(team_task_edits)::text like '%Keep all authored notes%'))`));
 const undoBase={...b,source_project_id:dest,destination_project_id:p,undoes:cmd.request_id};const ur=await rpc('editor','review_undo',undoBase);check('Undo review',ur.code,null);check('Undo restores assignments',ur.value.restored_assignments,2);
 const undo=command(undoBase,ur.value),undone=await rpc('editor','undo',undo);check('Undo success',undone.code,null);const restored=await row(t.id);check('Undo original task exact',restored,before);check('Undo comment revision',await pg.scalar(`select to_jsonb(revision) from public.task_comments where id=${lit(t.comment)}`),3);check('Undo mention exact',await pg.scalar(`select to_jsonb(m) from public.task_mentions m where id=${lit(t.mention)}`),mention);
 check('old key erased',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_conversation_keys where request_id=${lit(cmd.request_id)}`),0);check('Undo retry',(await rpc('editor','undo',undo)).value.replayed);
 const redoBase={...b,undoes:undo.request_id};const rr=await rpc('editor','review_undo',redoBase);check('Redo review',rr.code,null);const redo=command(redoBase,rr.value),redone=await rpc('editor','undo',redo);check('Redo success',redone.code,null);check('Redo exact moved task',await row(t.id),after);
 for(const who of ['viewer','outsider'])check(who+' cannot review',(await rpc(who,'review',b)).code,'42501');
 const second=await seed('Changed proof'),sb=scope(second),sr=(await rpc('editor','review',sb)).value,sc=command(sb,sr);
 await pg.raw(`update public.tasks set description='A newer note' where id=${lit(second.id)}`);check('changed task rejected',(await rpc('editor','move',sc)).code,'PT409');check('changed task not moved',(await row(second.id)).project_id,p);
 const tr=(await rpc('editor','review',sb)).value,tc=command(sb,tr);await pg.raw(`update public.task_comments set body='A newer discussion',revision=revision+1 where id=${lit(second.comment)}`);check('changed discussion rejected',(await rpc('editor','move',tc)).code,'PT409');
 const ar=(await rpc('editor','review',sb)).value,ac=command(sb,ar);await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(dest)},${lit(team)},${lit(users.editor.id)},'viewer')`);check('role loss rejected',(await rpc('editor','move',ac)).code,'42501');await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(dest)} and user_id=${lit(users.editor.id)}`);check('role ABA review rejected',(await rpc('editor','move',ac)).code,'PT409');
 check('cross team refused',(await rpc('owner','review',{...sb,destination_project_id:foreign})).code,'42501');check('personal destination refused',(await rpc('owner','review',{...sb,destination_project_id:personal})).code,'42501');check('stale session refused',(await rpc('editor','review',sb,{session:randomUUID()})).code,'28000');
 const fresh=(await rpc('editor','review',sb)).value;check('forged proof refused',(await rpc('editor','move',{...command(sb,fresh),review_token:'f'.repeat(64)})).code,'PT409');
 const conflict=await rpc('editor','move',{...cmd,task_id:second.id});check('nonce collision refused',conflict.code,'PT409');
 check('no client private scope',await pg.scalar("select to_jsonb(not has_table_privilege('authenticated','taskfold_private.team_task_move_scope','INSERT') and not has_table_privilege('service_role','taskfold_private.team_task_move_undo','SELECT'))"));
 const direct=await run('owner','null',{statement:`update public.tasks set project_id=${lit(dest)} where id=${lit(second.id)};insert into result values('true'::jsonb,null,null);`});check('direct update remains closed',(await row(second.id)).project_id,p);check('direct update no syntax failure',direct.code===null||direct.code==='PT503');

 const privilegedDirect=await run('owner','null',{role:'postgres',statement:`update public.tasks set project_id=${lit(dest)} where id=${lit(second.id)};insert into result values('true'::jsonb,null,null);`});
 check('subject-bearing RLS bypass remains closed',privilegedDirect.code,'PT503');
 // Failure after the task write must roll back custody, discussion, journal,
 // encrypted recovery and private scopes in the same transaction.
 const fault=await seed('Atomic rollback proof'),fb=scope(fault),fc=command(fb,(await rpc('editor','review',fb)).value);
 const journalCount=await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_task_edits');
 await pg.raw(`create function public.move_fixture_fault() returns trigger language plpgsql as $$begin raise exception using errcode='P0001',message='Synthetic discussion failure';end$$;create trigger move_fixture_fault before update of project_id on public.task_comments for each row execute function public.move_fixture_fault();`);
 check('mid-write failure surfaced',(await rpc('editor','move',fc)).code,'P0001');
 check('rollback exact original task',await row(fault.id),fault.row);
 check('rollback discussion',await pg.scalar(`select to_jsonb(project_id) from public.task_comments where id=${lit(fault.comment)}`),p);
 check('rollback custody',await pg.scalar(`select to_jsonb(project_id) from taskfold_private.team_content_tasks where task_id=${lit(fault.id)}`),p);
 check('rollback journal',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_task_edits'),journalCount);
 for(const table of ['team_task_move_scope','team_task_move_undo','team_conversation_keys'])check('rollback no '+table,await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.${table}${table==='team_task_move_scope'?'':` where request_id=${lit(fc.request_id)}`}`),0);
 await pg.raw('drop trigger move_fixture_fault on public.task_comments;drop function public.move_fixture_fault();');
 check('same saved request recovers after rollback',(await rpc('editor','move',fc)).code,null);
 const inverse={...fb,source_project_id:dest,destination_project_id:p,undoes:fc.request_id};
 // Reading a mention after the move must not prevent Undo or roll back reading.
 await pg.raw(`update public.task_mentions set read_at=now()+interval '1 minute',revision=revision+1 where id=${lit(fault.mention)}`);
 const readMention=await pg.scalar(`select to_jsonb(m) from public.task_mentions m where id=${lit(fault.mention)}`);
 const readUndo=await rpc('editor','review_undo',inverse);check('mention reading permits Undo review',readUndo.code,null);
 check('mention reading permits Undo',(await rpc('editor','undo',command(inverse,readUndo.value))).code,null);
 check('Undo preserves newer read state',await pg.scalar(`select to_jsonb(m) from public.task_mentions m where id=${lit(fault.mention)}`),readMention);
 const expired={...command(fb,(await rpc('editor','review',fb)).value),expires_at:'2000-01-01T00:00:00Z'};
 check('expired review refused',(await rpc('editor','move',expired)).code,'PT409');
 check('same project refused',(await rpc('editor','review',{...fb,destination_project_id:p})).code,'22023');
 check('unknown fields refused',(await rpc('editor','review',{...fb,force:true})).code,'22023');
 check('wrong generation refused',(await rpc('editor','review',{...fb,task_generation:randomUUID()})).code,'PT409');
 await pg.raw(`update public.projects set is_archived=true where id=${lit(dest)}`);
 check('archived destination refused',(await rpc('editor','review',fb)).code,'PT409');
 await pg.raw(`update public.projects set is_archived=false where id=${lit(dest)}`);
 await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=false');
 check('disabled edits refused',(await rpc('editor','review',fb)).code,'PT503');
 await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=true');
 // Two callers racing the same reviewed task serialize; one wins and the
 // other must review again rather than moving a stale source.
 const race=await seed('Concurrent move proof'),rb=scope(race),rv=(await rpc('editor','review',rb)).value;
 const gate=await pg.hold(`select pg_advisory_xact_lock(hashtextextended(${lit(race.id)},78137))`);
 const first=rpc('editor','move',command(rb,rv),{app:'taskfold-move-race-a'});
 await pg.waitForLock('taskfold-move-race-a',gate.pid);
 const next=rpc('editor','move',command(rb,rv),{app:'taskfold-move-race-b'});
 await pg.waitForLock('taskfold-move-race-b',gate.pid);await gate.release();
 const races=await Promise.all([first,next]);check('concurrent moves exactly one winner',races.map(x=>x.code??'ok').sort(),['PT409','ok']);
 check('concurrent move custody',await pg.scalar(`select to_jsonb(project_id) from taskfold_private.team_content_tasks where task_id=${lit(race.id)}`),dest);
 // A concurrent exact retry is acknowledged, without writing twice.
 const replayRace=await seed('Concurrent retry proof'),replayBase=scope(replayRace),replayCommand=command(replayBase,(await rpc('editor','review',replayBase)).value);
 const replies=await Promise.all([rpc('editor','move',replayCommand),rpc('editor','move',replayCommand)]);
 check('concurrent retry both confirmed',replies.map(x=>x.code),[null,null]);
 check('concurrent retry one replay',replies.map(x=>x.value.replayed).sort(),[false,true]);
 // Ordinary personal moves still clear assignment without needing access to
 // private scope tables. This catches a trigger privilege regression.
 const personalDest=randomUUID(),personalTask=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(personalDest)},${lit(users.owner.id)},'Personal destination');insert into public.tasks(id,user_id,project_id,title) values(${lit(personalTask)},${lit(users.owner.id)},${lit(personal)},'Personal move proof');`);
 const personalMove=await run('owner','null',{statement:`update public.tasks set project_id=${lit(personalDest)} where id=${lit(personalTask)};insert into result values('true'::jsonb,null,null);`});
 check('ordinary personal move succeeds',personalMove.code,null);check('ordinary personal move destination',(await row(personalTask)).project_id,personalDest);
 // Recovery payload is bounded by the existing 30-day key lifecycle.
 const expiredMove=await seed('Recovery expiry proof'),eb=scope(expiredMove),ec=command(eb,(await rpc('editor','review',eb)).value);
 check('expiry fixture moved',(await rpc('editor','move',ec)).code,null);
 await pg.raw(`update taskfold_private.team_conversation_keys set expires_at=now()-interval '1 second' where request_id=${lit(ec.request_id)}`);
 const expiredInverse={...eb,source_project_id:dest,destination_project_id:p,undoes:ec.request_id};
 check('expired Undo refused',(await rpc('editor','review_undo',expiredInverse)).code,'PT409');
 await pg.raw('select taskfold_private.expire_team_conversations(1000)');
 check('expired ciphertext purged',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_move_undo where request_id=${lit(ec.request_id)}`),0);
 check('expiry preserves moved task',(await row(expiredMove.id)).project_id,dest);
 // Expiry/key erasure while Undo waits for its receipt lock invalidates
 // the already decrypted preliminary copy. Cleanup and Undo cannot both win.
 const expiryRace=await seed('Expiry race proof'),xb=scope(expiryRace),xc=command(xb,(await rpc('editor','review',xb)).value);
 check('expiry race moved',(await rpc('editor','move',xc)).code,null);
 const expiryInverse={...xb,source_project_id:dest,destination_project_id:p,undoes:xc.request_id};
 const keyGate=await pg.hold(`select 1 from taskfold_private.team_task_edits where team_id=${lit(team)} and request_id=${lit(xc.request_id)} for update`);
 const expiryWorker=rpc('editor','review_undo',expiryInverse,{app:'taskfold-move-expiry-race'});
 await pg.waitForLock('taskfold-move-expiry-race',keyGate.pid);
 await keyGate.release('commit',`delete from taskfold_private.team_conversation_keys where team_id=${lit(team)} and request_id=${lit(xc.request_id)}`);
 check('concurrent key erasure refuses Undo',(await expiryWorker).code,'PT409');
 check('key erasure preserves moved task',(await row(expiryRace.id)).project_id,dest);
 const files=await seed('Provider-bound file proof'),fileID=randomUUID();
 await pg.raw(`insert into storage.objects(id,bucket_id,name,owner,owner_id) values(${lit(fileID)},'task-attachments',${lit(users.owner.id+'/move-proof')},${lit(users.owner.id)},${lit(users.owner.id)});insert into taskfold_private.team_content_files values(${lit(fileID)},${lit(p)});update public.tasks set attachments=${json([{id:fileID,name:'Synthetic design.txt'}])} where id=${lit(files.id)}`);
 check('provider-bound attachments need separate review',(await rpc('editor','review',scope(files))).code,'PT409');
 check('provider-bound task stays put',(await row(files.id)).project_id,p);
 check('file custody stays put',await pg.scalar(`select to_jsonb(project_id) from taskfold_private.team_content_files where object_id=${lit(fileID)}`),p);
 const contract={account:users.editor.id,origin:'https://backend.example',samples:[{review,body:cmd,reply:moved.value},{review:ur.value,body:undo,reply:undone.value},{review:rr.value,body:redo,reply:redone.value}]};
 if(process.argv[3])await writeFile(process.argv[3],JSON.stringify(contract,null,2)+'\n');
 // Account removal cascades the journal and key, erasing move recovery
 // while shared task custody remains with the team.
 await pg.raw(`delete from auth.users where id=${lit(users.editor.id)}`);
 check('removed actor move receipts purged',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_moves where actor_id=${lit(users.editor.id)}`),0);
 check('removed actor encrypted recovery purged',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_task_move_undo'),0);
 check('actor removal retains shared task',(await row(t.id)).project_id,dest);
 report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
 report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
 if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close()}
