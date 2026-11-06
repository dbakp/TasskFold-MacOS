import {randomUUID} from 'node:crypto';
export async function completionBatchRecoveryChecks({pg,lit,json,check,run,rpc:single,row,create,body,users,team,project}) {
 const verify=(n,a,b=true)=>check('completion group recovery: '+n,a,b);
 const group=async(rows,extra={})=>({team_id:team,request_id:randomUUID(),items:(await Promise.all(rows.map(r=>body(r,{project_id:r.project_id})))).sort((a,b)=>a.task_id.localeCompare(b.task_id)),...extra});
 const call=async(mode,b,who='editor',action='complete',opts={})=>{const r=await run(who,`public.taskfold_${mode}_team_completion_batch(${lit(action)},${json(b)})`,opts);if(r.code==='42702')throw new Error('Ambiguous recovery SQL: '+r.reason);return r;};
 const complete=(b,who='editor',action='complete',opts={})=>run(who,`public.taskfold_complete_team_tasks(${lit(action)},${json(b)})`,opts);
 const count=(table,b)=>pg.scalar(`select to_jsonb(count(*)) from taskfold_private.${table} where team_id=${lit(team)} and request_id=${lit(b.request_id)}`);
 const rows=await Promise.all([create({is_recurring:false,title:'Recovery root one'}),create({is_recurring:false,title:'Recovery root two'})]);const pending=await group(rows);
 const read=await call('review',pending);verify('unrecorded selection is observed',(read.value||{}).state,'unrecorded');
 verify('whole review has versioned contract',read.value.group_review_protocol,1);verify('review returns every selected identity',read.value.items.map(i=>i.task_id),pending.items.map(i=>i.task_id));verify('unrecorded has no fabricated receipt',read.value.receipt,null);
 verify('read creates no group receipt',await count('team_task_batches',pending),0);
 for(const mode of ['review','cancel']) {
  for(const role of ['anon','service_role'])verify(mode+' '+role+' denied',(await call(mode,pending,'editor','complete',{role})).code,'42501');
  verify(mode+' outsider denied',(await call(mode,pending,'outsider')).code,'42501');
  verify(mode+' expired session denied',(await call(mode,pending,'editor','complete',{session:randomUUID()})).code,'28000');
 }
 for(const [name,mutate] of [['empty',b=>b.items=[]],['too many',b=>b.items=Array(101).fill({})],['duplicate identity',b=>b.items[1]=b.items[0]],['changed team',b=>b.items[1].team_id=randomUUID()],['extra member key',b=>b.items[0].extra=true],['extra group key',b=>b.extra=true],['group member nonce',b=>b.items[0].request_id=b.request_id],['source mismatch',b=>b.items[0].record.id=randomUUID()]]) {
  const value=structuredClone(pending);mutate(value);for(const mode of ['review','cancel'])verify(mode+' rejects '+name,(await call(mode,value)).code,'22023');
 }
 await pg.raw(`update public.tasks set title='Remote edited root' where id=${lit(rows[1].id)}`);
 const latest=await call('review',pending);verify('review shows changed current source',latest.value.items.find(i=>i.task_id===rows[1].id).task.title,'Remote edited root');
 const before=await Promise.all(rows.map(r=>row(r.id)));const cancelled=await call('cancel',pending);
 verify('whole unrecorded selection cancelled',cancelled.value.state,'cancelled');verify('every member has cancellation proof',cancelled.value.items.map(i=>i.state),['cancelled','cancelled']);
 verify('cancellation leaves all current task content intact',await Promise.all(rows.map(r=>row(r.id))),before);
 verify('group has one cancellation marker',await count('team_completion_batch_cancellations',pending),1);
 verify('group has both member links',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_batch_items where team_id=${lit(team)} and request_id=${lit(pending.request_id)}`),2);
 verify('lost cancellation reply reads same proof',(await call('review',pending)).value,cancelled.value);
 verify('exact cancellation retry reads same proof',(await call('cancel',pending)).value,cancelled.value);
 verify('cancelled group cannot execute later',(await complete(pending)).code,'PT409');
 verify('cancelled member cannot escape group',(await single('complete',pending.items[0])).code,'PT409');
 verify('another reader cannot adopt cancellation',(await call('review',pending,'owner')).code,'PT409');
 const changed=structuredClone(pending);changed.items[0].input_zone='UTC';verify('changed intent cannot reuse cancellation',(await call('cancel',changed)).code,'PT409');
 const stolen=structuredClone(pending);stolen.request_id=randomUUID();verify('cancelled member cannot move to another group',(await call('cancel',stolen)).code,'PT409');
 const subset=structuredClone(pending);subset.items.pop();verify('partial cancellation review refused',(await call('review',subset)).code,'PT409');
 // Read access is sufficient to retire one's own intent; it never grants editing.
 const viewed=await group([await create({is_recurring:false})]);await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer')`);
 verify('viewer can inspect own unrecorded action',(await call('review',viewed)).value?.state,'unrecorded');
 verify('viewer can retire own unrecorded action',(await call('cancel',viewed)).value?.state,'cancelled');
 verify('viewer gets no editing capability',(await call('review',viewed)).value?.items[0].can_edit_current,false);
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)}`);
 // Already-recorded completion / Undo / Redo can only be acknowledged, not cancelled.
 const written=await group([await create({is_recurring:false}),await create({is_recurring:false})]);const applied=await complete(written);verify('recorded fixture applies',applied.code,null);
 const recorded=await call('review',written);verify('recorded group recognized',recorded.value.state,'recorded');
 verify('recorded group receipt exactly matches replay',recorded.value.receipt,(await complete(written)).value);
 verify('cancelling recorded group returns recorded proof',(await call('cancel',written)).value,recorded.value);
 verify('recorded group has no cancellation marker',await count('team_completion_batch_cancellations',written),0);
 verify('recorded cancellation never reopens tasks',(await Promise.all(written.items.map(i=>row(i.task_id)))).map(r=>r.completed),[true,true]);
 const undo={team_id:team,request_id:randomUUID(),related_request:written.request_id,items:written.items.map(i=>({...i,request_id:randomUUID(),undoes:i.request_id}))};
 verify('unrecorded linked Undo review',(await call('review',undo,'editor','undo')).value?.state,'unrecorded');
 verify('linked Undo can be retired',(await call('cancel',undo,'editor','undo')).value?.state,'cancelled');
 verify('cancelled Undo cannot execute',(await complete(undo,'editor','undo')).code,'PT409');
 const realUndo={...undo,request_id:randomUUID(),items:undo.items.map(i=>({...i,request_id:randomUUID()}))};verify('cancellation does not consume original Undo link',(await complete(realUndo,'editor','undo')).code,null);
 verify('recorded Undo observed',(await call('review',realUndo,'editor','undo')).value?.state,'recorded');
 const redo={team_id:team,request_id:randomUUID(),related_request:realUndo.request_id,items:written.items.map((i,n)=>({...i,record:{...i.record,completion_version:2},request_id:randomUUID(),redo_of:realUndo.items[n].request_id}))};
 verify('Redo fixture applies',(await complete(redo)).code,null);verify('recorded Redo observed',(await call('review',redo)).value?.state,'recorded');
 const badHistory={...undo,request_id:randomUUID(),items:undo.items.map(i=>({...i,request_id:randomUUID(),undoes:randomUUID()}))};verify('forged history member refused',(await call('cancel',badHistory,'editor','undo')).code,'PT409');
 // Inject a late receipt failure: no partial nonce/tombstone is allowed to persist.
 const faulty=await group([await create({is_recurring:false}),await create({is_recurring:false})]);
 await pg.raw(`create function public.recovery_cancel_fault() returns trigger language plpgsql as $$begin if new.request_id=${lit(faulty.items[1].request_id)}::uuid then raise exception 'Synthetic late cancellation fault';end if;return new;end$$;create trigger recovery_cancel_fault before insert on taskfold_private.team_task_completion_cancellations for each row execute function public.recovery_cancel_fault()`);
 verify('late cancellation failure surfaces',(await call('cancel',faulty)).code,'P0001');verify('late failure leaves no group header',await count('team_task_batches',faulty),0);
 verify('late failure leaves no first member cancellation',await count('team_task_edits',{request_id:faulty.items[0].request_id}),0);
 verify('late failure keeps both tasks open',(await Promise.all(faulty.items.map(i=>row(i.task_id)))).map(r=>r.completed),[false,false]);
 await pg.raw('drop trigger recovery_cancel_fault on taskfold_private.team_task_completion_cancellations;drop function public.recovery_cancel_fault()');
 // Genuine contention: completion versus cancellation, and exact cancellation retries.
 const race=await group([await create({is_recurring:false}),await create({is_recurring:false})]);
 let gate=await pg.hold(`select pg_advisory_xact_lock(hashtextextended(${lit(team+':'+race.request_id)},79241))`);
 let a=complete(race,'editor','complete',{app:'recover-write'}),c=call('cancel',race,'editor','complete',{app:'recover-cancel'});
 await Promise.all([pg.waitForLock('recover-write'),pg.waitForLock('recover-cancel')]);await gate.release();const [ra,rc]=await Promise.all([a,c]);
 verify('race has one coherent winner',rc.code,null);verify('race winner has terminal proof',['recorded','cancelled'].includes(rc.value.state));
 verify('race writes match terminal proof',(await Promise.all(race.items.map(i=>row(i.task_id)))).map(r=>r.completed),[rc.value.state==='recorded',rc.value.state==='recorded']);
 verify('late completion cannot pass cancelled group',ra.code,rc.value.state==='recorded'?null:'PT409');
 const retries=await group([await create({is_recurring:false}),await create({is_recurring:false})]);gate=await pg.hold(`select pg_advisory_xact_lock(hashtextextended(${lit(team+':'+retries.request_id)},79241))`);
 a=call('cancel',retries,'editor','complete',{app:'recover-retry-a'});c=call('cancel',retries,'editor','complete',{app:'recover-retry-b'});
 await Promise.all([pg.waitForLock('recover-retry-a'),pg.waitForLock('recover-retry-b')]);await gate.release();const retry=await Promise.all([a,c]);
 verify('concurrent cancellation replies identical',retry[0].value,retry[1].value);verify('concurrent cancellation terminal proof',retry.map(r=>r.value?.state),['cancelled','cancelled']);verify('concurrent cancellation has one marker',await count('team_completion_batch_cancellations',retries),1);
 const pruned=await group([await create({is_recurring:false}),await create({is_recurring:false})]);await call('cancel',pruned);await pg.raw(`delete from taskfold_private.team_task_edits where team_id=${lit(team)} and request_id=${lit(pruned.items[1].request_id)}`);
 verify('pruned cancellation cannot fabricate whole review',(await call('review',pruned)).code,'PT409');verify('pruned cancellation still cannot execute',(await complete(pruned)).code,'PT409');
 // Recovery needs read authority across every selected project, including after waiting.
 const extraProject=randomUUID();await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(extraProject)},${lit(users.owner.id)},'Private recovery project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(extraProject)},${lit(team)},'private')`);
 const mixed=await group([await create({is_recurring:false}),await create({is_recurring:false,project_id:extraProject})]);
 for(const mode of ['review','cancel']) {const denied=await call(mode,mixed);verify(mode+' refuses inaccessible second project',denied.code,'42501');verify(mode+' returns no partial task content',denied.value,null);}
 verify('inaccessible selection has no cancelled header',await count('team_task_batches',mixed),0);
 await pg.raw(`update taskfold_private.team_content_projects set visibility='team' where project_id=${lit(extraProject)};update public.projects set is_archived=true where id=${lit(extraProject)}`);
 const archived=await call('review',mixed);verify('archived work remains reviewable',archived.value?.state,'unrecorded');verify('archived project offers no editing',archived.value?.items.find(i=>i.project_id===extraProject).can_edit_current,false);
 verify('archived unrecorded intent can be retired',(await call('cancel',mixed)).value?.state,'cancelled');
 await pg.raw(`update public.projects set is_archived=false where id=${lit(extraProject)}`);
 const editPaused=await group([await create({is_recurring:false})]);await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=false');
 verify('write pause still permits status review',(await call('review',editPaused)).value?.items[0].can_edit_current,false);verify('write pause permits retiring old intent',(await call('cancel',editPaused)).value?.state,'cancelled');await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=true');
 const waitingAccess=await group([await create({is_recurring:false,project_id:extraProject})]);
 gate=await pg.hold(`select id from taskfold_private.teams where id=${lit(team)} for update`);
 const waiting=call('cancel',waitingAccess,'editor','complete',{app:'recover-access-wait'});await pg.waitForLock('recover-access-wait',gate.pid);
 await gate.release('commit',`update taskfold_private.team_content_projects set visibility='private' where project_id=${lit(extraProject)}`);
 verify('read access loss during wait denies cancellation',(await waiting).code,'42501');verify('access loss leaves no cancellation ledger',await count('team_task_batches',waitingAccess),0);
 await pg.raw(`update taskfold_private.team_content_projects set visibility='team' where project_id=${lit(extraProject)}`);
 // Bound the aggregate as well as each member; an oversized cancellation rolls
 // back its tombstones just like a late task/permission failure.
 const large=await group(await Promise.all(Array.from({length:14},()=>create({is_recurring:false}))));
 await pg.raw(`update public.tasks set description=repeat('x',300000) where id in (${large.items.map(i=>lit(i.task_id)).join(',')})`);
 verify('aggregate review response is bounded',(await call('review',large)).code,'54000');verify('oversized cancellation result is refused',(await call('cancel',large)).code,'54000');verify('oversized cancellation rolls back header',await count('team_task_batches',large),0);
 verify('oversized cancellation leaves every task open',await pg.scalar(`select to_jsonb(count(*)) from public.tasks where id in (${large.items.map(i=>lit(i.task_id)).join(',')}) and completed`),0);
 for(const mode of ['review','cancel'])verify(mode+' bounds request bytes',(await run('editor',`public.taskfold_${mode}_team_completion_batch('complete',${json(pending)}||jsonb_build_object('extra',repeat('x',2000001)))`)).code,'22023');
 const privateTable='taskfold_private.team_completion_batch_cancellations';verify('cancellation table RLS',await pg.scalar(`select to_jsonb(relrowsecurity) from pg_class where oid=${lit(privateTable)}::regclass`),true);
 for(const role of ['anon','authenticated','service_role'])for(const privilege of ['SELECT','INSERT','UPDATE','DELETE'])verify(role+' cannot '+privilege+' cancellation table',await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},${lit(privateTable)},${lit(privilege)}))`),false);
 return {account:users.editor.id,unrecorded_body:pending,unrecorded_review:read.value,cancelled_review:cancelled.value,recorded_body:written,recorded_review:recorded.value,undo_body:realUndo,undo_review:(await call('review',realUndo,'editor','undo')).value,redo_body:redo,redo_review:(await call('review',redo)).value};
}
