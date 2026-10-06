-- Isolated fixture; no user task data or authentication records survive rollback.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f01dcafe-3000-4000-8000-000000000001','taskfold-revision-owner@example.invalid','{}'),
 ('f01dcafe-3000-4000-8000-000000000002','taskfold-revision-outsider@example.invalid','{}');
select set_config('request.jwt.claim.sub','f01dcafe-3000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare t public.tasks; base jsonb; changes jsonb; task_id uuid := 'f01dcafe-3000-4000-8000-000000000010'; begin
 insert into public.tasks(id,user_id,title,completed,completion_version)
 values(task_id,auth.uid(),'Completion revision fixture',false,99) returning * into t;
 if t.completion_version <> 0 then raise exception 'Client supplied insert revision'; end if;
 base := '{"completed":false,"completed_at":null,"completion_version":0}';
 changes := '{"completed":true,"completed_at":"2026-09-01T12:00:00Z"}';
 t := public.taskfold_patch_task(task_id,base,changes);
 if t.completion_version <> 1 or t.completed_at <> '2026-09-01T12:00:00Z'::timestamptz then raise exception 'Offline instant/revision not saved'; end if;
 t := public.taskfold_patch_task(task_id,base,changes);
 if t.completion_version <> 1 then raise exception 'Lost-response retry advanced twice'; end if;
 t := public.taskfold_patch_task(task_id,'{"description":null}','{"description":"Independent notes"}');
 if t.completion_version <> 1 then raise exception 'Unrelated edit invalidated revision'; end if;
 -- An older client uses a direct update. It still advances the server revision.
 update public.tasks set completed=false where id=task_id returning * into t;
 if t.completion_version <> 2 or t.completed_at is not null then raise exception 'Reopen revision failed'; end if;
 update public.tasks set completion_version=0 where id=task_id returning * into t;
 if t.completion_version <> 2 then raise exception 'Client reset server revision'; end if;
 begin
  perform public.taskfold_patch_task(task_id,base,changes);
  raise exception 'Expected unseen cycle conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 if not exists(select 1 from public.tasks where id=task_id and completed=false and description='Independent notes' and completion_version=2) then raise exception 'Old completion replaced newer choice'; end if;
 -- Explicit review rebases the baseline; equivalent timestamp spellings can retry.
 base := '{"completed":false,"completed_at":null,"completion_version":2}';
 t := public.taskfold_patch_task(task_id,base,changes);
 t := public.taskfold_patch_task(task_id,base,'{"completed":true,"completed_at":"2026-09-01T14:00:00+02:00"}');
 if t.completion_version <> 3 then raise exception 'Reviewed/retried revision failed'; end if;
 update public.tasks set completed=false where id=task_id;
 update public.tasks set completed=true,completed_at='2026-09-01T12:00:00Z' where id=task_id;
 begin
  perform public.taskfold_patch_task(task_id,base,changes);
  raise exception 'Expected same-visible-state later-cycle conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 -- Whole-task deletion also detects the cycle; an older initial baseline works at zero.
 insert into public.tasks(id,user_id,title) values('f01dcafe-3000-4000-8000-000000000011',auth.uid(),'Old deletion baseline');
 if not public.taskfold_delete_task('f01dcafe-3000-4000-8000-000000000011',jsonb_build_object('id','f01dcafe-3000-4000-8000-000000000011','user_id',auth.uid(),'title','Old deletion baseline')) then raise exception 'Legacy initial deletion failed'; end if;
 select to_jsonb(tasks) into base from public.tasks where id=task_id;
 update public.tasks set completed=false where id=task_id;
 update public.tasks set completed=true,completed_at='2026-09-01T12:00:00Z' where id=task_id;
 begin
  perform public.taskfold_delete_task(task_id,base);
  raise exception 'Expected stale deletion revision conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 -- Native old queued revisions are blocked by the client; old deployed clients remain compatible.
 t := public.taskfold_patch_task(task_id,'{"completed":true}','{"completed":false}');
 if t.completion_version <> 8 or t.completed_at is not null then raise exception 'Legacy patch compatibility failed'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-3000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.tasks where id='f01dcafe-3000-4000-8000-000000000010') then raise exception 'Outsider read task'; end if;
 begin
  perform public.taskfold_patch_task('f01dcafe-3000-4000-8000-000000000010','{"completed":false,"completion_version":8}','{"completed":true}');
  raise exception 'Expected outsider rejection';
 exception when others then if sqlerrm not like 'This task is no longer available%' then raise; end if; end;
 update public.tasks set completed=true where id='f01dcafe-3000-4000-8000-000000000010';
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.tasks where id='f01dcafe-3000-4000-8000-000000000010' and completed=false and completion_version=8) then raise exception 'Outsider modified row'; end if;
 if has_function_privilege('anon','public.taskfold_patch_task(uuid,jsonb,jsonb)','execute') or has_function_privilege('anon','public.update_completed_at()','execute') then raise exception 'Anonymous function exposed'; end if;
 if exists(select 1 from pg_proc where oid in ('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure,'taskfold_private.advance_completion_revision()'::regprocedure,'public.update_completed_at()'::regprocedure) and prosecdef) then raise exception 'Revision bypasses RLS'; end if;
end $$;
rollback;
