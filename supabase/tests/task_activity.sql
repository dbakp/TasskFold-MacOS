begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f01dcafe-7000-4000-8000-000000000001','taskfold-activity-owner@example.invalid','{}'),
 ('f01dcafe-7000-4000-8000-000000000002','taskfold-activity-member@example.invalid','{}'),
 ('f01dcafe-7000-4000-8000-000000000003','taskfold-activity-outsider@example.invalid','{}');
select set_config('request.jwt.claim.sub','f01dcafe-7000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare task uuid := 'f01dcafe-7000-4000-8000-000000000010'; n integer; t public.tasks; begin
 insert into public.projects(id,user_id,name) values('f01dcafe-7000-4000-8000-000000000020',auth.uid(),'Activity shared fixture');
 insert into public.tasks(id,user_id,title,description) values(task,auth.uid(),'Activity fixture','Never in the ledger');
 if (select count(*) from public.task_activity where task_id=task) <> 1 then raise exception 'Creation missing'; end if;
 update public.tasks set title='Renamed',description='Other private notes' where id=task;
 if (select count(*) from public.task_activity where task_id=task) <> 1 then raise exception 'Unrelated edit invented activity'; end if;
 t := public.taskfold_patch_task(task,'{"completed":false,"completed_at":null,"completion_version":0}','{"completed":true,"completed_at":"2026-10-01T12:00:00Z"}');
 t := public.taskfold_patch_task(task,'{"completed":false,"completed_at":null,"completion_version":0}','{"completed":true,"completed_at":"2026-10-01T14:00:00+02:00"}');
 if (select count(*) from public.task_activity where task_id=task) <> 2 then raise exception 'Retry duplicated completion'; end if;
 if not exists(select 1 from public.task_activity where task_id=task and kinds=array['completed'] and completion_version=1 and effective_at='2026-10-01T12:00:00Z'::timestamptz and recorded_at>=effective_at) then raise exception 'Offline completion instant or revision missing'; end if;
 update public.tasks set completed=false where id=task;
 update public.tasks set due_date='2026-10-08',due_time='10:00',deadline_date='2026-10-10',project_id='f01dcafe-7000-4000-8000-000000000020' where id=task;
 if not exists(select 1 from public.task_activity where task_id=task and kinds=array['reopened'] and after_state->>'completed'='false') then raise exception 'Reopen missing'; end if;
 if not exists(select 1 from public.task_activity where task_id=task and kinds=array['moved','rescheduled'] and before_state->'project_id'='null'::jsonb and after_state->>'due_date'='2026-10-08') then raise exception 'Scope/planning event missing'; end if;
 select count(*) into n from public.task_activity where task_id=task;
 update public.tasks set due_date='2026-10-08',due_time='10:00',deadline_date='2026-10-10' where id=task;
 if (select count(*) from public.task_activity where task_id=task) <> n then raise exception 'Equivalent retry invented reschedule'; end if;
 if exists(select 1 from public.task_activity where task_id=task and (before_state ?| array['title','description','comments','attachments'] or after_state ?| array['title','description','comments','attachments'])) then raise exception 'Private content copied'; end if;
 begin
  insert into public.task_activity(user_id,task_id,effective_at,completion_version,kinds,before_state,after_state) values(auth.uid(),task,now(),0,array['completed'],'{}','{}');
  raise exception 'Expected fake activity rejection';
 exception when insufficient_privilege then null; end;
 begin
  update public.task_activity set kinds=array['completed'] where task_id=task;
  raise exception 'Expected history edit rejection';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Grant the isolated second user accepted access without sending an invitation.
insert into public.project_collaborators(project_id,user_id,invited_email,role,status,invited_by)
 values('f01dcafe-7000-4000-8000-000000000020','f01dcafe-7000-4000-8000-000000000002','taskfold-activity-member@example.invalid','collaborator','pending','f01dcafe-7000-4000-8000-000000000001');
select set_config('request.jwt.claim.sub','f01dcafe-7000-4000-8000-000000000002',true);
set local role authenticated;
update public.project_collaborators set status='accepted' where user_id=auth.uid() and project_id='f01dcafe-7000-4000-8000-000000000020';
do $$ begin
 insert into public.tasks(id,user_id,title,project_id) values('f01dcafe-7000-4000-8000-000000000012',auth.uid(),'Member-owned shared fixture','f01dcafe-7000-4000-8000-000000000020');
 -- Before sharing, this task lived in another user's private Inbox.
 if exists(select 1 from public.task_activity where task_id='f01dcafe-7000-4000-8000-000000000010') then raise exception 'Member read private prior scope'; end if;
 update public.tasks set completed=true where id='f01dcafe-7000-4000-8000-000000000010';
 if not exists(select 1 from public.task_activity where task_id='f01dcafe-7000-4000-8000-000000000010' and kinds=array['completed'] and actor_id=auth.uid()) then raise exception 'Member transition/actor missing'; end if;
end $$;
reset role;
delete from public.project_collaborators where user_id='f01dcafe-7000-4000-8000-000000000002' and project_id='f01dcafe-7000-4000-8000-000000000020';
set local role authenticated;
do $$ begin
 if exists(select 1 from public.task_activity where task_id in ('f01dcafe-7000-4000-8000-000000000010','f01dcafe-7000-4000-8000-000000000012')) then raise exception 'Revoked member/creator retained history access'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-7000-4000-8000-000000000003',true);
do $$ begin
 if exists(select 1 from public.task_activity where task_id='f01dcafe-7000-4000-8000-000000000010') then raise exception 'Outsider read history'; end if;
end $$;
select set_config('request.jwt.claim.sub','f01dcafe-7000-4000-8000-000000000001',true);
do $$ begin
 delete from public.tasks where id='f01dcafe-7000-4000-8000-000000000010';
 if (select count(*) from public.task_activity where task_id='f01dcafe-7000-4000-8000-000000000010') <> 6 then raise exception 'Delete lost historical transitions'; end if;
 if not exists(select 1 from public.task_activity where task_id='f01dcafe-7000-4000-8000-000000000010' and kinds=array['deleted']) then raise exception 'Delete event missing'; end if;
 -- Reusing an ID after deletion is a creation, not a fictional old completion.
 insert into public.tasks(id,user_id,title,completed,completed_at) values('f01dcafe-7000-4000-8000-000000000010',auth.uid(),'Restored completed fixture',true,'2026-09-01T12:00:00Z');
 if (select count(*) from public.task_activity where task_id='f01dcafe-7000-4000-8000-000000000010') <> 7 then raise exception 'Restore duplicate or artificial completion'; end if;
end $$;
reset role;
-- Project/account cascades cannot be blocked by the new writer or leave owner history behind.
select set_config('request.jwt.claim.sub','f01dcafe-7000-4000-8000-000000000001',true);
set local role authenticated;
insert into public.tasks(id,user_id,title,project_id) values('f01dcafe-7000-4000-8000-000000000011',auth.uid(),'Cascade fixture','f01dcafe-7000-4000-8000-000000000020');
delete from public.projects where id='f01dcafe-7000-4000-8000-000000000020';
do $$ begin
 if not exists(select 1 from public.task_activity where task_id='f01dcafe-7000-4000-8000-000000000011' and kinds=array['moved'] and after_state->'project_id'='null'::jsonb) then raise exception 'Project cascade scope event missing'; end if;
end $$;
reset role;
delete from auth.users where id='f01dcafe-7000-4000-8000-000000000001';
do $$ begin
 if exists(select 1 from public.task_activity where user_id='f01dcafe-7000-4000-8000-000000000001') then raise exception 'Account removal left history'; end if;
end $$;
do $$ begin
 if has_table_privilege('anon','public.task_activity','select') or has_table_privilege('authenticated','public.task_activity','insert') or has_table_privilege('authenticated','public.task_activity','delete') or has_function_privilege('authenticated','taskfold_private.capture_task_activity()','execute') then raise exception 'Public writer exposed'; end if;
 if not (select relrowsecurity from pg_class where oid='public.task_activity'::regclass) then raise exception 'Activity RLS missing'; end if;
 if (select count(*) from public.task_activity_epoch) <> 1 then raise exception 'Epoch missing'; end if;
end $$;
rollback;
