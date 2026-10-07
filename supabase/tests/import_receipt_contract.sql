-- Native receipt contract; isolated fixture, simulated JWT and actual SQL roles.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f0740000-1000-4000-8000-000000000001','taskfold-receipt-owner@example.invalid','{}'),
 ('f0740000-1000-4000-8000-000000000002','taskfold-receipt-outsider@example.invalid','{}');
select set_config('request.jwt.claim.sub','f0740000-1000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare bundle jsonb; receipt jsonb; key text; begin
 bundle := '{"projects":[{"source_id":"p","record":{"id":"f0740000-1000-4000-8000-000000000010","name":"Receipt project"}}],"sections":[],"labels":[],"tasks":[{"source_id":"t","subtask_count":1,"comment_count":1,"record":{"id":"f0740000-1000-4000-8000-000000000030","title":"Receipt task","project_id":"f0740000-1000-4000-8000-000000000010","subtasks":[{"id":"child","title":"Receipt child"}],"comments":[{"id":"c","text":"Fixture comment"}]}}]}';
 receipt := public.taskfold_import_todoist('receipt-source',bundle);
 if receipt->'success' is distinct from 'true'::jsonb then raise exception 'Receipt not confirmed'; end if;
 foreach key in array array['projectsImported','sectionsImported','labelsImported','tasksImported','subtasksImported','commentsImported','projectsSkipped','sectionsSkipped','labelsSkipped','tasksSkipped'] loop
  if jsonb_typeof(receipt->key) is distinct from 'number' or (receipt->>key)::numeric < 0 or (receipt->>key)::numeric <> trunc((receipt->>key)::numeric) then raise exception 'Invalid first receipt field %',key; end if;
 end loop;
 if receipt->>'tasksImported'<>'1' or receipt->>'tasksSkipped'<>'0' or receipt->>'subtasksImported'<>'1' or receipt->>'commentsImported'<>'1' then raise exception 'Incorrect first receipt'; end if;
 -- Owner edit isolates replay preservation from the separately tested task-generation RPC contract.
 update public.tasks set title='Local user edit' where id='f0740000-1000-4000-8000-000000000030';
 receipt := public.taskfold_import_todoist('receipt-source',bundle);
 if receipt->'success' is distinct from 'true'::jsonb or receipt->>'tasksImported'<>'0' or receipt->>'tasksSkipped'<>'1' or receipt->>'projectsSkipped'<>'1' or receipt->>'subtasksImported'<>'0' or receipt->>'commentsImported'<>'0' then raise exception 'Incorrect replay receipt'; end if;
 foreach key in array array['projectsImported','sectionsImported','labelsImported','tasksImported','subtasksImported','commentsImported','projectsSkipped','sectionsSkipped','labelsSkipped','tasksSkipped'] loop
  if jsonb_typeof(receipt->key) is distinct from 'number' or (receipt->>key)::numeric < 0 then raise exception 'Invalid replay receipt field %',key; end if;
 end loop;
 if not exists(select 1 from public.tasks where id='f0740000-1000-4000-8000-000000000030' and title='Local user edit') then raise exception 'Retry lost local edit'; end if;
 if (select count(*) from public.tasks where id='f0740000-1000-4000-8000-000000000030')<>1 then raise exception 'Retry duplicated task'; end if;
end $$;
select set_config('request.jwt.claim.sub','f0740000-1000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.tasks where id='f0740000-1000-4000-8000-000000000030') or exists(select 1 from public.import_sources where source_account='receipt-source') then raise exception 'Receipt fixture leaked across accounts'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
 if has_function_privilege(current_user,'public.taskfold_import_todoist(text,jsonb)','execute') then raise exception 'Anonymous import is exposed'; end if;
end $$;
reset role;
rollback;
select (select count(*) from auth.users where id in('f0740000-1000-4000-8000-000000000001','f0740000-1000-4000-8000-000000000002')) as fixture_users,
       (select count(*) from public.tasks where id='f0740000-1000-4000-8000-000000000030') as fixture_tasks,
       (select count(*) from public.import_sources where user_id in('f0740000-1000-4000-8000-000000000001','f0740000-1000-4000-8000-000000000002')) as fixture_sources;
