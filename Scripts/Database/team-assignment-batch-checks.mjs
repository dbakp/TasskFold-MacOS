import {randomUUID} from 'node:crypto';
export async function assignmentBatchChecks({pg,lit,check,body,rpc,row,ids,projects,users,team}) {
 users.recipient={id:randomUUID(),session:randomUUID()};
 await pg.raw(`insert into auth.users(id,email,email_confirmed_at)values(${lit(users.recipient.id)},'recipient@example.invalid',now());insert into auth.sessions(id,user_id)values(${lit(users.recipient.session)},${lit(users.recipient.id)});insert into taskfold_private.team_members(team_id,user_id,role)values(${lit(team)},${lit(users.recipient.id)},'member');`);
 const original=await Promise.all(ids.map(row));
 const b=await body({assigned_to:users.recipient.id});
 check('assignment batch saves every project',(await rpc(b)).code,null);
 for(const id of ids) {
  const before=original.find(x=>x.id===id), current=await row(id);
  check('assignment changes only chosen field '+id,current,{...before,assigned_to:users.recipient.id});
 }
 const expected=await Promise.all(ids.map(row));
 await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(projects[1])},${lit(team)},${lit(users.recipient.id)},'viewer')on conflict(project_id,user_id)do update set role='viewer';`);
 check('recorded assignment replay acknowledges departed recipient',(await rpc(b)).value.replayed,true);
 check('replay never repeats assignment',await Promise.all(ids.map(row)),expected);
 // This actor remains an editor; only the chosen recipient loses eligibility.
 const refused=await body({assigned_to:users.recipient.id});
 check('recipient missing editing access in one project refuses whole group',(await rpc(refused)).code,'42501');
 check('ineligible last member leaves every task unchanged',await Promise.all(ids.map(row)),expected);
 check('recipient failure leaves no group receipt',await pg.scalar(`select to_jsonb(count(*))from taskfold_private.team_task_batches where request_id=${lit(refused.request_id)}`),0);
 await pg.raw(`delete from taskfold_private.team_project_grants where user_id=${lit(users.recipient.id)};`);
 const cleared=await body({assigned_to:null});check('clear assignment saves whole cohort',(await rpc(cleared)).code,null);
 check('clear assignments only',await Promise.all(ids.map(row)),expected.map(x=>({...x,assigned_to:null})));
 // Simulate the linked inverse with the current full rows, then redo separately.
 const undone=await body({assigned_to:users.recipient.id});check('assignment inverse restores recipients',(await rpc(undone)).code,null);
 check('inverse keeps unrelated fields',await Promise.all(ids.map(row)),expected);
 for(const [name,value] of [['viewer',users.viewer.id],['outsider',users.outsider.id],['missing',randomUUID()]]) {
  const before=await Promise.all(ids.map(row));check(name+' recipient refused for whole cohort',(await rpc(await body({assigned_to:value}))).code,'42501');
  check(name+' refusal keeps cohort unchanged',await Promise.all(ids.map(row)),before);
 }
 for(const value of ['invalid',false,3,[],{}]) check('malformed recipient rejected '+JSON.stringify(value),(await rpc(await body({assigned_to:value}))).code,'22023');
 await pg.raw(`update auth.users set banned_until=now()+interval '1 day' where id=${lit(users.recipient.id)}`);
 check('banned recipient new assignment refused',(await rpc(await body({assigned_to:users.recipient.id}))).code,'42501');
 check('banned recipient old receipt still acknowledged',(await rpc(b)).value.replayed,true);
 await pg.raw(`update auth.users set banned_until=null where id=${lit(users.recipient.id)}`);
 // Canonical recipient locks recheck Auth after a waiting ban commits.
 const waiting=await body({assigned_to:users.recipient.id});
 const holder=await pg.hold(`update auth.users set banned_until=now()+interval '1 day' where id=${lit(users.recipient.id)}`);
 let pending;
 try {
  pending=rpc(waiting,{app:'assignment-auth-wait'});
  await pg.waitForLock('assignment-auth-wait',holder.pid);
  await holder.release('commit');
  check('waiting assignment rechecks committed recipient ban',(await pending).code,'42501');
  check('waiting ban never partially changes cohort',await Promise.all(ids.map(row)),expected);
 } finally {await holder.release('rollback'); if(pending)await pending;}
 await pg.raw(`update auth.users set banned_until=null where id=${lit(users.recipient.id)}`);
 const late=await body({assigned_to:users.editor.id});
 await pg.raw(`create function public.assignment_test_fault()returns trigger language plpgsql as $$begin if new.id=${lit(ids[1])}::uuid and new.assigned_to=${lit(users.editor.id)}::uuid then raise exception 'Synthetic assignment fault';end if;return new;end$$;create trigger assignment_test_fault before update on public.tasks for each row execute function public.assignment_test_fault();`);
 check('late assignment failure rolls back whole group',(await rpc(late)).code,'P0001');
 check('late assignment fault leaves all task rows exact',await Promise.all(ids.map(row)),expected);
 check('late assignment fault leaves no receipt',await pg.scalar(`select to_jsonb(count(*))from taskfold_private.team_task_batches where request_id=${lit(late.request_id)}`),0);
 await pg.raw('drop trigger assignment_test_fault on public.tasks;drop function public.assignment_test_fault();');
}
