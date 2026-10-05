-- Execute as one transaction and ROLLBACK. Isolated fixtures; no outbound email.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f01dcafe-1000-4000-8000-000000000001','taskfold-import-owner@example.invalid','{}'),
 ('f01dcafe-1000-4000-8000-000000000002','taskfold-import-outsider@example.invalid','{}');
select set_config('request.jwt.claim.sub','f01dcafe-1000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare bundle jsonb; result jsonb; task_id uuid := 'f01dcafe-1000-4000-8000-000000000030'; begin
 bundle := '{"projects":[{"source_id":"p","record":{"id":"f01dcafe-1000-4000-8000-000000000010","name":"Same"}}],"sections":[{"source_id":"s","record":{"id":"f01dcafe-1000-4000-8000-000000000020","name":"Section","project_id":"f01dcafe-1000-4000-8000-000000000010"}}],"labels":[{"source_id":"l","record":{"id":"f01dcafe-1000-4000-8000-000000000040","name":"Label"}}],"tasks":[{"source_id":"a","subtask_count":2,"comment_count":1,"record":{"id":"f01dcafe-1000-4000-8000-000000000030","user_id":"f01dcafe-1000-4000-8000-000000000002","title":"Same","project_id":"f01dcafe-1000-4000-8000-000000000010","section_id":"f01dcafe-1000-4000-8000-000000000020","due_date":"2026-10-06","due_time":"09:00","deadline_date":"2026-10-09","duration_minutes":30,"time_zone":"Europe/Copenhagen","subtasks":[{"id":"child","title":"Child","subtasks":[{"id":"grand","title":"Grand","comments":[{"id":"c","text":"Retained"}]}]}]}},{"source_id":"b","record":{"id":"f01dcafe-1000-4000-8000-000000000031","title":"Same","project_id":"f01dcafe-1000-4000-8000-000000000010"}}]}';
 result := public.taskfold_import_todoist('source-account',bundle);
 if result->>'tasksImported'<>'2' or result->>'subtasksImported'<>'2' or result->>'commentsImported'<>'1' then raise exception 'Import counts incorrect: %',result; end if;
 if (select count(*) from public.tasks where id in(task_id,'f01dcafe-1000-4000-8000-000000000031') and title='Same' and user_id=auth.uid())<>2 then raise exception 'Distinct titles or enforced account ownership failed'; end if;
 if not exists(select 1 from public.tasks where id=task_id and deadline_date='2026-10-09' and duration_minutes=30 and due_date='2026-10-06' and time_zone='Europe/Copenhagen' and subtasks#>>'{0,subtasks,0,comments,0,text}'='Retained') then raise exception 'Planning or nested fields lost'; end if;
 perform public.taskfold_patch_task(task_id,'{"title":"Same","deadline_date":"2026-10-09","duration_minutes":30}','{"title":"User edit","deadline_date":"2026-10-10","duration_minutes":45}');
 result := public.taskfold_import_todoist('source-account',bundle);
 if result->>'tasksImported'<>'0' or result->>'tasksSkipped'<>'2' or result->>'projectsSkipped'<>'1' then raise exception 'Replay counts incorrect'; end if;
 if not exists(select 1 from public.tasks where id=task_id and title='User edit' and deadline_date='2026-10-10' and duration_minutes=45) then raise exception 'Replay overwrote user edits'; end if;
 delete from public.tasks where id='f01dcafe-1000-4000-8000-000000000031';
 result := public.taskfold_import_todoist('source-account',bundle);
 if exists(select 1 from public.tasks where id='f01dcafe-1000-4000-8000-000000000031') or result->>'tasksSkipped'<>'2' then raise exception 'Replay resurrected deleted task'; end if;
 begin
  perform public.taskfold_patch_task(task_id,'{"duration_minutes":30}','{"duration_minutes":60}');
  raise exception 'Expected stale estimate conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 begin
  perform public.taskfold_import_todoist('invalid','{"projects":[{"source_id":"rollback","record":{"id":"f01dcafe-1000-4000-8000-000000000011","name":"Rollback"}}],"sections":[],"labels":[],"tasks":[{"source_id":"bad","record":{"id":"f01dcafe-1000-4000-8000-000000000032","title":"Bad","duration_minutes":-1}}]}');
  raise exception 'Expected invalid duration rejection';
 exception when check_violation then null; end;
 if exists(select 1 from public.projects where id='f01dcafe-1000-4000-8000-000000000011') or exists(select 1 from public.import_sources where source_account='invalid') then raise exception 'Failed import partially committed'; end if;
 begin
  perform public.taskfold_import_todoist('invalid','{}'); raise exception 'Expected invalid bundle rejection';
 exception when others then if sqlerrm <> 'Invalid or oversized import collection' then raise; end if; end;
end $$;
insert into public.tasks(id,user_id,title,due_date,due_time,time_zone,scheduled_at,deadline_date) values
 ('f01dcafe-1000-4000-8000-000000000035',auth.uid(),'DST first fold','2026-10-25','02:30','Europe/Copenhagen','2026-10-25T00:30:00Z','2026-10-30'),
 ('f01dcafe-1000-4000-8000-000000000036',auth.uid(),'DST second fold','2026-10-25','02:30','Europe/Copenhagen','2026-10-25T01:30:00Z','2026-10-30');
do $$ begin
 if not exists(select 1 from public.tasks where id='f01dcafe-1000-4000-8000-000000000035' and scheduled_at='2026-10-25T00:30:00Z') or not exists(select 1 from public.tasks where id='f01dcafe-1000-4000-8000-000000000036' and scheduled_at='2026-10-25T01:30:00Z') then raise exception 'DST fold identity lost'; end if;
end $$;
-- Older clients send only the new planned date. The canonical instant must follow it.
update public.tasks set due_date='2026-10-26' where id='f01dcafe-1000-4000-8000-000000000036';
do $$ begin
 if not exists(select 1 from public.tasks where id='f01dcafe-1000-4000-8000-000000000036' and scheduled_at='2026-10-26T01:30:00Z' and deadline_date='2026-10-30') then raise exception 'Old-client reschedule left a stale instant or moved deadline'; end if;
 begin
  update public.tasks set time_zone='Invalid/Zone' where id='f01dcafe-1000-4000-8000-000000000036';
  raise exception 'Expected invalid time zone rejection';
 exception when others then if sqlerrm <> 'Choose a valid time zone' then raise; end if; end;
end $$;
-- Consecutive offline native edits use Z and HH:mm, while PostgREST returns offsets/seconds.
do $$ declare t public.tasks; begin
 t := public.taskfold_patch_task('f01dcafe-1000-4000-8000-000000000035',
  '{"due_time":"02:30","scheduled_at":"2026-10-25T00:30:00Z"}',
  '{"due_time":"02:45","scheduled_at":"2026-10-25T00:45:00Z"}');
 t := public.taskfold_patch_task(t.id,
  '{"due_time":"02:45","scheduled_at":"2026-10-25T02:45:00+02:00"}',
  '{"due_time":"03:00","scheduled_at":"2026-10-25T02:00:00Z"}');
 if t.scheduled_at<>'2026-10-25T02:00:00Z'::timestamptz or t.due_time<>'03:00'::time or t.deadline_date<>'2026-10-30' then raise exception 'Equivalent native temporal baselines falsely conflicted or lost deadline'; end if;
 begin
  perform public.taskfold_patch_task(t.id,'{"scheduled_at":"2026-10-25T00:30:00Z"}','{"scheduled_at":"2026-10-25T01:30:00Z"}');
  raise exception 'Expected real instant conflict';
 exception when others then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
 t := public.taskfold_patch_task(t.id,'{"completed_at":null}','{"completed_at":"2026-10-05T12:00:00Z"}');
 t := public.taskfold_patch_task(t.id,'{"completed_at":"2026-10-05T14:00:00+02:00"}','{"completed_at":null}');
 if t.completed_at is not null then raise exception 'Completion timestamp could not be cleared'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-1000-4000-8000-000000000002',true);
do $$ begin
 if public.get_user_email_by_id('f01dcafe-1000-4000-8000-000000000001') is not null then raise exception 'Unrelated account email leaked'; end if;
 if public.get_user_email_by_id(auth.uid()) is distinct from 'taskfold-import-outsider@example.invalid' then raise exception 'Own-account email lookup regressed'; end if;
 if has_function_privilege(current_user,'public.get_user_id_by_email(text)','execute') then raise exception 'Account existence lookup exposed'; end if;
 if exists(select 1 from public.import_sources) then raise exception 'Source mapping leaked across accounts'; end if;
 if exists(select 1 from public.tasks where id='f01dcafe-1000-4000-8000-000000000030') then raise exception 'Imported tasks leaked across accounts'; end if;
 begin
  perform public.taskfold_import_todoist('outsider','{"projects":[],"sections":[],"labels":[],"tasks":[{"source_id":"bad","record":{"id":"f01dcafe-1000-4000-8000-000000000033","title":"Bad","project_id":"f01dcafe-1000-4000-8000-000000000010"}}]}');
  raise exception 'Expected owned project rejection';
 exception when others then if sqlerrm <> 'Imported task requires an owned project' then raise; end if; end;
end $$;
reset role;
set local role anon;
do $$ begin
 if has_function_privilege(current_user,'public.get_user_email_by_id(uuid)','execute') or has_function_privilege(current_user,'public.get_user_id_by_email(text)','execute') then raise exception 'Anonymous email lookup exposed'; end if;
 if has_function_privilege(current_user,'public.taskfold_import_todoist(text,jsonb)','execute') or has_table_privilege(current_user,'public.import_sources','select') then raise exception 'Anonymous import privilege leaked'; end if;
end $$;
reset role;
rollback;
