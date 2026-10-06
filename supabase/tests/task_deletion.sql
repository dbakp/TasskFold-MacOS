-- Disposable accounts and rows; run as one transaction. Every fixture is rolled back.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f01dcafe-2000-4000-8000-000000000001','taskfold-delete-owner@example.invalid','{}'),
 ('f01dcafe-2000-4000-8000-000000000002','taskfold-delete-outsider@example.invalid','{}');
select set_config('request.jwt.claim.sub','f01dcafe-2000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare t public.tasks; base jsonb; after_review jsonb; task_id uuid := 'f01dcafe-2000-4000-8000-000000000010'; begin
 insert into public.tasks(id,user_id,title,due_date,due_time,time_zone,scheduled_at,created_at,source_metadata)
 values(task_id,auth.uid(),'Next occurrence','2026-10-25','09:00','Europe/Copenhagen','2026-10-25T08:00:00Z','2026-10-24T12:00:00Z','{"taskfold_recurrence_v1":{"action_id":"first-device"}}') returning * into t;
 base := to_jsonb(t);
 -- Same-second completions have distinct provenance even when every user-visible field agrees.
 begin
  perform public.taskfold_delete_task(task_id,jsonb_set(base,'{source_metadata,taskfold_recurrence_v1,action_id}','"second-device"'));
  raise exception 'Expected independent-creator conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 update public.tasks set comments='[{"id":"c","text":"Independent device comment"}]',duration_minutes=25 where id=task_id;
 begin
  perform public.taskfold_delete_task(task_id,base); raise exception 'Expected newer-work conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 if not exists(select 1 from public.tasks where id=task_id and duration_minutes=25 and comments#>>'{0,text}'='Independent device comment') then raise exception 'Conflict lost newer work'; end if;
 select to_jsonb(tasks) into after_review from public.tasks where id=task_id;
 update public.tasks set title='Changed while review was open' where id=task_id;
 begin
  perform public.taskfold_delete_task(task_id,after_review); raise exception 'Expected changed-during-review conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 select to_jsonb(tasks) into after_review from public.tasks where id=task_id;
 -- Equivalent native/PostgREST spellings do not create a false conflict.
 after_review := after_review || jsonb_build_object('id',upper(task_id::text),'due_time','09:00','scheduled_at','2026-10-25T09:00:00+01:00','created_at','2026-10-24T14:00:00+02:00');
 if not public.taskfold_delete_task(task_id,after_review) then raise exception 'Reviewed deletion unconfirmed'; end if;
 if exists(select 1 from public.tasks where id=task_id) then raise exception 'Reviewed task was not deleted'; end if;
 if not public.taskfold_delete_task(task_id,after_review) then raise exception 'Deletion retry failed'; end if;
 insert into public.tasks(id,user_id,title) values(task_id,auth.uid(),'Defaults');
 base := jsonb_build_object('id',task_id,'user_id',auth.uid(),'title','Defaults');
 if not public.taskfold_delete_task(task_id,base) then raise exception 'Native defaults falsely conflicted'; end if;
 insert into public.tasks(id,user_id,title) values(task_id,auth.uid(),'Old queue');
 begin
  perform public.taskfold_delete_task(task_id,'{}'); raise exception 'Expected legacy-baseline conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-2000-4000-8000-000000000002',true);
do $$ begin
 if not public.taskfold_delete_task('f01dcafe-2000-4000-8000-000000000010','{"id":"f01dcafe-2000-4000-8000-000000000010","user_id":"f01dcafe-2000-4000-8000-000000000001","title":"Old queue"}') then raise exception 'Inaccessible retry behavior changed'; end if;
 if exists(select 1 from public.tasks where id='f01dcafe-2000-4000-8000-000000000010') then raise exception 'Task visibility leaked'; end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.tasks where id='f01dcafe-2000-4000-8000-000000000010' and title='Old queue') then raise exception 'Another account deleted the task'; end if;
 if has_function_privilege('anon','public.taskfold_delete_task(uuid,jsonb)','execute') then raise exception 'Anonymous deletion exposed'; end if;
 if exists(select 1 from pg_proc where oid='public.taskfold_delete_task(uuid,jsonb)'::regprocedure and prosecdef) then raise exception 'Deletion bypasses RLS'; end if;
end $$;
rollback;
