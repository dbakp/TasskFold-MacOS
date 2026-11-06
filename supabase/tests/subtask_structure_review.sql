-- Actual-role fixture. All accounts and task writes are rolled back.
begin;
insert into auth.users(id,email) values
 ('f1711000-0000-4000-8000-000000000001','taskfold-subtask-owner@example.invalid'),
 ('f1711000-0000-4000-8000-000000000002','taskfold-subtask-outsider@example.invalid');
set local request.jwt.claim.sub='f1711000-0000-4000-8000-000000000001';
set local role authenticated;
insert into public.tasks(id,user_id,title,subtasks) values
 ('f1711000-0000-4000-8000-000000000011',auth.uid(),'Synthetic checklist guard',
  '[{"id":"a","title":"Parent","subtasks":[{"id":"b","title":"Child","description":"Original notes","subtasks":[]}]},{"id":"c","title":"Sibling","subtasks":[]}]');
do $test$
declare t public.tasks; baseline jsonb; remote jsonb; desired jsonb; saved public.tasks;
begin
 select * into t from public.tasks where id='f1711000-0000-4000-8000-000000000011';
 baseline := t.subtasks;
 remote := jsonb_set(baseline,'{0,subtasks,0,description}','"Other client notes"');
 saved := public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'subtasks',baseline),jsonb_build_object('subtasks',remote));
 desired := jsonb_build_array(((baseline->0) - 'subtasks') || '{"subtasks":[]}'::jsonb,baseline->0->'subtasks'->0,baseline->1);
 begin
  perform public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'subtasks',baseline),jsonb_build_object('subtasks',desired));
  raise exception 'A concurrent branch move was acknowledged';
 exception when others then
  if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if;
 end;
 -- Independent field edits with unchanged hierarchy retain automatic merging.
 desired := jsonb_set(baseline,'{1,title}','"Renamed sibling"');
 saved := public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'subtasks',baseline),jsonb_build_object('subtasks',desired));
 if saved.subtasks->0->'subtasks'->0->>'description' <> 'Other client notes'
    or saved.subtasks->1->>'title' <> 'Renamed sibling' then raise exception 'Independent fields did not merge'; end if;
 baseline := saved.subtasks;
 remote := baseline || '[{"id":"remote","title":"Remote addition"}]';
 saved := public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'subtasks',baseline),jsonb_build_object('subtasks',remote));
 desired := jsonb_build_array(baseline->1,baseline->0);
 begin
  perform public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'subtasks',baseline),jsonb_build_object('subtasks',desired));
  raise exception 'A concurrent reorder was acknowledged';
 exception when others then
  if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if;
 end;
 -- A reviewed current baseline applies the complete layout and is retry-safe.
 desired := desired || jsonb_build_array(remote->2);
 saved := public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'subtasks',remote),jsonb_build_object('subtasks',desired));
 saved := public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'subtasks',remote),jsonb_build_object('subtasks',desired));
 if saved.subtasks <> desired then raise exception 'Reviewed layout was lost on retry'; end if;
 if taskfold_private.subtask_layout('null') <> taskfold_private.subtask_layout('[]') then raise exception 'Known empty collections differ'; end if;
end $test$;
set local request.jwt.claim.sub='f1711000-0000-4000-8000-000000000002';
do $test$ begin
 if exists(select 1 from public.tasks where id='f1711000-0000-4000-8000-000000000011') then raise exception 'Outsider can read the task'; end if;
 begin
  perform public.taskfold_patch_task('f1711000-0000-4000-8000-000000000011','{}','{"title":"Outsider"}');
  raise exception 'Outsider can edit the task';
 exception when others then
  if sqlerrm not like '%no longer available%' then raise; end if;
 end;
end $test$;
rollback;
select (select count(*) from auth.users where id in ('f1711000-0000-4000-8000-000000000001','f1711000-0000-4000-8000-000000000002')) as fixture_users_remaining,
 has_function_privilege('anon','taskfold_private.subtask_layout(jsonb,integer)','execute') as anon_helper_execute,
 (select prosecdef from pg_proc where oid='public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure) as patch_security_definer,
 (select prosecdef from pg_proc where oid='taskfold_private.subtask_layout(jsonb,integer)'::regprocedure) as helper_security_definer;
