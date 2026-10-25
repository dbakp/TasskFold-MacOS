import { randomUUID } from 'node:crypto';
export async function completionBatchChecks({pg,lit,json,check,run,rpc:single,row,create,body,users,team,project}) {
 const verify=(n,a,b=true)=>check('completion batch: '+n,a,b);
 const rpc=async(action,b,who='editor',opts={})=>{const r=await run(who,`public.taskfold_complete_team_tasks(${lit(action)},${json(b)})`,opts);if(r.code==='42702')throw new Error('SQL name ambiguity: '+r.reason);return r;};
 const group=async(rows,extra={})=>({team_id:team,request_id:randomUUID(),items:(await Promise.all(rows.map(r=>body(r,{project_id:r.project_id})))).sort((a,b)=>a.task_id.localeCompare(b.task_id)),...extra});
 const inverse=b=>({team_id:team,request_id:randomUUID(),related_request:b.request_id,items:b.items.map(i=>({...i,request_id:randomUUID(),undoes:i.request_id}))});
 const rows=await Promise.all([create({is_recurring:false,recurrence_pattern:null,title:'Batch task one'}),create({is_recurring:false,recurrence_pattern:null,title:'Batch task two'})]);
 const originals=await group(rows);
 await pg.raw('update taskfold_private.team_config set enabled=false');
 verify('disabled rollout refuses whole selection',(await rpc('complete',originals)).code,'PT503');
 await pg.raw('update taskfold_private.team_config set enabled=true');
 for(const who of ['viewer','outsider'])verify(who+' denied',(await rpc('complete',originals,who)).code,'42501');
 for(const role of ['anon','service_role'])verify(role+' denied',(await rpc('complete',originals,'editor',{role})).code,'42501');
 verify('expired session denied',(await rpc('complete',originals,'editor',{session:randomUUID()})).code,'28000');
 for(const [name,mutate] of [
  ['empty selection',b=>b.items=[]],['oversized selection',b=>b.items=Array(101).fill({})],
  ['duplicate task',b=>b.items[1].task_id=b.items[0].task_id],['duplicate nonce',b=>b.items[1].request_id=b.items[0].request_id],
  ['batch nonce as member',b=>b.items[0].request_id=b.request_id],['extra envelope key',b=>b.extra=true],
  ['extra member key',b=>b.items[0].extra=true],['cross-team member',b=>b.items[1].team_id=randomUUID()],
  ['missing member',b=>b.items[1]=null],['malformed source',b=>b.items[1].record=[]],
  ['unbound single history',b=>b.items[0].redo_of=randomUUID()]
 ]) {const b=structuredClone(originals);b.request_id=randomUUID();mutate(b);verify(name+' refused',(await rpc('complete',b)).code,'22023');}
 verify('unsupported operation refused',(await rpc('delete',originals)).code,'22023');
 verify('Undo needs original group',(await rpc('undo',originals)).code,'22023');
 const ordered=originals.items.map(i=>i.task_id),first=ordered[0],last=ordered[1];
 await pg.raw(`update public.tasks set title='Newer title' where id=${lit(last)}`);
 verify('late stale member aborts entire group',(await rpc('complete',originals)).code,'PT409');
 verify('stale group leaves first task open',(await row(first)).completed,false);
 verify('stale group has no durable receipt',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_batches where request_id=${lit(originals.request_id)}`),0);
 await pg.raw(`update public.tasks set title=${lit(rows.find(r=>r.id===last).title)} where id=${lit(last)}`);
 const invalid=structuredClone(originals);invalid.request_id=randomUUID();invalid.items[1].task_generation=randomUUID();
 verify('recreated task refused',(await rpc('complete',invalid)).code,'22023');
 const fault=await group(rows);
 await pg.raw(`create function public.batch_completion_fault() returns trigger language plpgsql as $$begin if new.id=${lit(last)}::uuid and new.completed then raise exception 'Synthetic second task failure';end if;return new;end$$;create trigger batch_completion_fault after update on public.tasks for each row execute function public.batch_completion_fault()`);
 verify('second task interruption rolls back entire RPC',(await rpc('complete',fault)).code,'P0001');
 verify('late interruption preserves first task',(await row(first)).completed,false);
 verify('late interruption rolls back all group/member receipts',await pg.scalar(`select to_jsonb((select count(*) from taskfold_private.team_task_batches where request_id=${lit(fault.request_id)})+(select count(*) from taskfold_private.team_task_edits where request_id in(${fault.items.map(i=>lit(i.request_id)).join(',')})))`),0);
 await pg.raw('drop trigger batch_completion_fault on public.tasks;drop function public.batch_completion_fault()');
 const hold=await pg.hold(`select id from public.tasks where id=${lit(last)} for update`);
 try {verify('busy member returns retryable conflict',(await rpc('complete',fault)).code,'PT409');verify('busy member leaves first task open',(await row(first)).completed,false)} finally {await hold.release('rollback')}
 const saved=await rpc('complete',originals);verify('complete succeeds',saved.code,null);verify('complete confirms every item',saved.value.items.length,2);
 verify('receipt echoes group identity',saved.value.request_id,originals.request_id);verify('receipt has explicit protocol',saved.value.batch_protocol,1);
 verify('original response is not replay',saved.value.replayed,false);
 verify('receipt belongs to original actor',saved.value.account,users.editor.id);verify('receipt belongs to original team',saved.value.team_id,team);verify('receipt names exact operation',saved.value.operation,'complete');
 verify('another editor cannot acknowledge actor-bound group',(await rpc('complete',originals,'owner')).code,'PT409');
 verify('both source tasks complete',(await Promise.all(ordered.map(row))).map(r=>r.completed),[true,true]);
 verify('group contains both private links',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edits where batch_request_id=${lit(originals.request_id)}`),2);
 verify('exact replay confirms group',(await rpc('complete',originals)).value?.replayed,true);
 verify('single RPC cannot replay one batch member',(await single('complete',originals.items[0])).code,'PT409');
 verify('outsider member lookup is denied before private batch inspection',(await single('complete',originals.items[0],'outsider')).code,'42501');
 verify('viewer member lookup is denied before private batch inspection',(await single('complete',originals.items[0],'viewer')).code,'42501');
 const undo=inverse(originals);
 verify('another editor cannot Undo actor-bound group',(await rpc('undo',undo,'owner')).code,'PT409');
 verify('private helper cannot replay isolated member',(await run('editor',`taskfold_private.team_complete_task('complete',${json(originals.items[0])})`)).code,'PT409');
 verify('single RPC cannot undo one batch member',(await single('undo',undo.items[0])).code,'PT409');
 const subset=structuredClone(undo);subset.items.pop();verify('subset Undo refused',(await rpc('undo',subset)).code,'PT409');
 const wrong=structuredClone(undo);wrong.items[1].undoes=randomUUID();verify('wrong member history refused',(await rpc('undo',wrong)).code,'PT409');
 const changed=structuredClone(originals);changed.items[0].input_zone='UTC';verify('changed intent cannot reuse group identity',(await rpc('complete',changed)).code,'PT409');
 const stolen=await group(rows);stolen.items[0].request_id=originals.items[0].request_id;verify('member identity cannot move to another group',(await rpc('complete',stolen)).code,'PT409');
 const stolenGroup=await group(rows);stolenGroup.items[0].request_id=originals.request_id;verify('group identity cannot become member',(await rpc('complete',stolenGroup)).code,'PT409');
 await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer')`);
 verify('role loss denies replay acknowledgement',(await rpc('complete',originals)).code,'42501');
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)}`);
 await pg.raw(`create function public.batch_undo_fault() returns trigger language plpgsql as $$begin if new.id=${lit(last)}::uuid and not new.completed then raise exception 'Synthetic second Undo failure';end if;return new;end$$;create trigger batch_undo_fault after update on public.tasks for each row execute function public.batch_undo_fault()`);
 verify('late Undo interruption rolls back whole inverse',(await rpc('undo',undo)).code,'P0001');
 verify('late Undo preserves both completed tasks',(await Promise.all(ordered.map(row))).map(r=>r.completed),[true,true]);
 await pg.raw('drop trigger batch_undo_fault on public.tasks;drop function public.batch_undo_fault()');
 const undone=await rpc('undo',undo);verify('whole Undo succeeds',undone.code,null);verify('Undo returns both member receipts',undone.value.items.length,2);
 verify('whole Undo restores both tasks',(await Promise.all(ordered.map(row))).map(r=>r.completed),[false,false]);
 verify('exact Undo replay does not reapply',(await rpc('undo',undo)).value?.replayed,true);
 verify('second independent Undo refused',(await rpc('undo',inverse(originals))).code,'PT409');
 const redo=await group(await Promise.all(ordered.map(row)),{related_request:undo.request_id});
 for(const i of redo.items)i.redo_of=undo.items.find(x=>x.task_id===i.task_id).request_id;
 verify('single RPC cannot Redo one member',(await single('complete',redo.items[0])).code,'PT409');
 const redone=await rpc('complete',redo);verify('whole Redo succeeds',redone.code,null);verify('Redo keeps one linked action',redone.value.related_request,undo.request_id);
 verify('Redo completes both again',(await Promise.all(ordered.map(row))).map(r=>r.completed),[true,true]);
 const retry=await rpc('complete',redo);verify('Redo retry returns exact history',retry.value.replayed,true);
 const recurringRows=await Promise.all([create({title:'Batch repeat one'}),create({title:'Batch repeat two'})]);
 const recurring=await group(recurringRows);const rs=await rpc('complete',recurring);verify('recurring batch succeeds',rs.code,null);
 verify('both successors created',rs.value.items.map(x=>x.created_successor),[true,true]);
 const recUndo=inverse(recurring);const ru=await rpc('undo',recUndo);verify('recurring Undo succeeds',ru.code,null);
 verify('both unchanged owned successors removed',ru.value.items.map(x=>x.removed_successor),[true,true]);
 const recRedo=await group(await Promise.all(recurring.items.map(i=>row(i.task_id))),{related_request:recUndo.request_id});
 for(const i of recRedo.items)i.redo_of=recUndo.items.find(x=>x.task_id===i.task_id).request_id;
 const rr=await rpc('complete',recRedo);verify('recurring Redo succeeds',rr.code,null);
 verify('Redo uses fresh successor incarnations',rr.value.items.every(x=>x.successor_generation!==rs.value.items.find(y=>y.task_id===x.task_id).successor_generation),true);
 // Recurring sources converging on one future occurrence remain one selection.
 const parent=await create({due_date:'2026-10-23'}),children=await Promise.all([create({recurrence_parent_id:parent.id}),create({recurrence_parent_id:parent.id})]);
 const converged=await group(children),cv=await rpc('complete',converged);verify('converging batch succeeds',cv.code,null);
 verify('converged successor is created only once',cv.value.items.filter(x=>x.created_successor).length,1);
 verify('converged members share an actual successor',new Set(cv.value.items.map(x=>x.successor_id)).size,1);
 // Permission loss committed while waiting is revalidated before any task writes.
 const pendingRows=await Promise.all([create({is_recurring:false}),create({is_recurring:false})]);const pendingBody=await group(pendingRows);
 let gate=await pg.hold(`select id from taskfold_private.teams where id=${lit(team)} for update`);const app='batch-role-'+randomUUID().slice(0,8),waiting=rpc('complete',pendingBody,'editor',{app});
 await pg.waitForLock(app,gate.pid);await gate.release('commit',`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer')`);
 verify('waiting role loss denies whole group',(await waiting).code,'42501');verify('waiting role loss preserves both sources',(await Promise.all(pendingRows.map(r=>row(r.id)))).map(r=>r.completed),[false,false]);
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)}`);
 gate=await pg.hold(`select pg_advisory_xact_lock(hashtextextended(${lit(pendingRows[0].id)},78137))`);
 const one='batch-overlap-one',two='batch-overlap-two',pa=rpc('complete',pendingBody,'editor',{app:one}),pb=rpc('complete',structuredClone(pendingBody),'editor',{app:two});
 const waits=await Promise.all([pg.waitForLock(one),pg.waitForLock(two)]);verify('concurrent callers reached real lock chain',waits.some(x=>x.blockers.includes(gate.pid)),true);await gate.release();const concurrent=await Promise.all([pa,pb]);
 verify('concurrent exact retries both succeed',concurrent.map(x=>x.code),[null,null]);verify('one concurrent caller applies effects',concurrent.filter(x=>!x.value.replayed).length,1);
 verify('one concurrent caller is exact replay',concurrent.filter(x=>x.value.replayed).length,1);
 // Different overlapping selections lock all task identities in canonical order.
 const overlapRows=await Promise.all([create({is_recurring:false}),create({is_recurring:false})]);
 const overlapA=await group(overlapRows),overlapB=await group([...overlapRows].reverse());
 gate=await pg.hold(`select pg_advisory_xact_lock(hashtextextended(${lit(overlapRows[0].id)},78137))`);
 const oa=rpc('complete',overlapA,'editor',{app:'batch-distinct-a'}),ob=rpc('complete',overlapB,'editor',{app:'batch-distinct-b'});
 const distinctWaits=await Promise.all([pg.waitForLock('batch-distinct-a'),pg.waitForLock('batch-distinct-b')]);verify('distinct overlapping callers reached real lock chain',distinctWaits.some(x=>x.blockers.includes(gate.pid)),true);await gate.release();
 const overlaps=await Promise.all([oa,ob]);verify('overlapping distinct groups have one winner',overlaps.filter(x=>x.code===null).length,1);verify('overlapping loser is whole-group conflict',overlaps.filter(x=>x.code==='PT409').length,1);
 // Each selected project is checked even if an earlier member is still writable.
 const otherProject=randomUUID();await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(otherProject)},${lit(users.owner.id)},'Other batch project');insert into taskfold_private.team_content_projects(project_id,team_id) values(${lit(otherProject)},${lit(team)});insert into taskfold_private.team_project_grants values(${lit(otherProject)},${lit(team)},${lit(users.editor.id)},'viewer')`);
 const mixedRows=await Promise.all([create({is_recurring:false}),create({is_recurring:false,project_id:otherProject})]),mixed=await group(mixedRows);
 verify('one denied project stops whole selection',(await rpc('complete',mixed)).code,'42501');verify('denied project leaves allowed member untouched',(await row(mixedRows[0].id)).completed,false);
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(otherProject)} and user_id=${lit(users.editor.id)};update public.projects set is_archived=true where id=${lit(otherProject)}`);
 verify('one archived project stops whole selection',(await rpc('complete',mixed)).code,'PT409');
 await pg.raw(`update public.projects set is_archived=false where id=${lit(otherProject)}`);
 const mixedReply=await rpc('complete',mixed);verify('multiple editable projects succeed together',mixedReply.code,null);verify('receipt preserves both project scopes',new Set(mixedReply.value.items.map(i=>i.project_id)).size,2);
 // A stale second inverse cannot leave the first member reopened.
 const staleUndoRows=await Promise.all([create({is_recurring:false}),create({is_recurring:false})]),staleBatch=await group(staleUndoRows);verify('stale Undo fixture completes',(await rpc('complete',staleBatch)).code,null);
 const staleIDs=staleBatch.items.map(i=>i.task_id);await pg.raw(`update public.tasks set completed_at='2026-10-24T13:00:00Z' where id=${lit(staleIDs[1])}`);
 verify('changed second completion rejects whole Undo',(await rpc('undo',inverse(staleBatch))).code,'PT409');verify('failed stale inverse preserves first completion',(await row(staleIDs[0])).completed,true);
 const pruned=await group([await create({is_recurring:false})]);verify('prune fixture applies',(await rpc('complete',pruned)).code,null);
 await pg.raw(`delete from taskfold_private.team_task_edits where team_id=${lit(team)} and request_id=${lit(pruned.items[0].request_id)}`);
 verify('pruned member never reexecutes recorded group',(await rpc('complete',pruned)).code,'PT409');
 for(const bytes of [128001,2000001]) {
  const expr=`public.taskfold_complete_team_tasks('complete',${json(originals)}||jsonb_build_object('items',jsonb_build_array(${json(originals.items[0])}||jsonb_build_object('record',${json(originals.items[0].record)}||jsonb_build_object('description',repeat('x',${bytes}))))))`;
  verify('server bounds request bytes '+bytes,(await run('editor',expr)).code,'22023');
 }
 verify('private transaction scopes cleaned',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_completion_batch_scope'),0);
 verify('private transaction scope RLS',await pg.scalar("select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.team_completion_batch_scope'::regclass"),true);
 for(const role of ['anon','authenticated','service_role'])for(const access of ['SELECT','INSERT','UPDATE','DELETE'])verify(role+' cannot '+access+' private transaction scope',await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},'taskfold_private.team_completion_batch_scope',${lit(access)}))`),false);
 // Replacing a scope with a caller-defined setting cannot authorize member actions.
 verify('setting cannot forge native group authority',(await run('editor',`(select public.taskfold_complete_team_task('complete',${json(originals.items[0])}) from (select set_config('taskfold.completion_batch',${lit(originals.request_id)},true)) s)`)).code,'PT409');
 const singleGroup=await group([await create({is_recurring:false})]);verify('one selected task uses same atomic endpoint',(await rpc('complete',singleGroup)).code,null);
 return {account:users.editor.id,body:originals,reply:saved.value,undo_body:undo,undo_reply:undone.value,redo_body:redo,redo_reply:redone.value,recurring_body:recurring,recurring_reply:rs.value};
}
