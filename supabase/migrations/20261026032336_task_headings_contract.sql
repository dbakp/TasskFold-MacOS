-- Source only: heading creation remains unexposed until native and rollout gates pass.
-- NULL preserves every pre-heading row/default and typed legacy baseline.
alter table public.tasks add column is_heading boolean default null;

create or replace function taskfold_private.guard_task_headings()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare node jsonb; old_headings jsonb := '{}'::jsonb;
begin
 if tg_op = 'UPDATE' and old.is_heading is true and new.is_heading is null then
  raise exception using errcode='23514', message='TASKFOLD_HEADING: Choose the task type explicitly before replacing this heading';
 end if;
 if new.is_heading is true and (new.completed is distinct from false or new.completed_at is not null) then
  raise exception using errcode='23514', message='TASKFOLD_HEADING: Headings stay open. Make this a task before completing it';
 end if;
 if tg_op = 'INSERT' or new.subtasks is distinct from old.subtasks then
  if tg_op = 'UPDATE' then
   with recursive nodes(value) as (
    select value from pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(old.subtasks)='array' then old.subtasks else '[]'::jsonb end)
    union all
    select child.value from nodes cross join lateral pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(nodes.value->'subtasks')='array' then nodes.value->'subtasks' else '[]'::jsonb end) child(value)
   ) select coalesce(pg_catalog.jsonb_object_agg(value->>'id','true'::jsonb) filter(where value->'is_heading'='true'::jsonb and pg_catalog.jsonb_typeof(value->'id')='string'),'{}'::jsonb) into old_headings from nodes;
  end if;
  for node in
   with recursive nodes(value) as (
    select value from pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(new.subtasks)='array' then new.subtasks else '[]'::jsonb end)
    union all
    select child.value from nodes cross join lateral pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(nodes.value->'subtasks')='array' then nodes.value->'subtasks' else '[]'::jsonb end) child(value)
   ) select value from nodes where pg_catalog.jsonb_typeof(value)='object'
  loop
   if node ? 'is_heading' and node->'is_heading' <> 'null'::jsonb and pg_catalog.jsonb_typeof(node->'is_heading') <> 'boolean' then
    raise exception using errcode='23514', message='TASKFOLD_HEADING: This checklist task type needs review';
   end if;
   if node->'is_heading' = 'true'::jsonb and
      (node->'completed' is distinct from 'false'::jsonb or coalesce(node->'completed_at','null'::jsonb) <> 'null'::jsonb
       or pg_catalog.jsonb_typeof(node->'id') is distinct from 'string' or coalesce(pg_catalog.length(node->>'id'),0) not between 1 and 400) then
    raise exception using errcode='23514', message='TASKFOLD_HEADING: Checklist headings need an open state and stable identity';
   end if;
   if old_headings ? (node->>'id') and pg_catalog.jsonb_typeof(node->'is_heading') is distinct from 'boolean' then
    raise exception using errcode='23514', message='TASKFOLD_HEADING: A checklist writer cannot discard the heading type';
   end if;
  end loop;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_task_headings() from public,anon,authenticated;
create trigger taskfold_guard_task_headings before insert or update on public.tasks
 for each row execute function taskfold_private.guard_task_headings();

-- Task type changes invalidate completion intentions just like a complete/reopen.
create or replace function taskfold_private.advance_completion_revision()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
 if tg_op = 'INSERT' then new.completion_version := 0;
 elsif coalesce(new.completed,false) is distinct from coalesce(old.completed,false)
       or new.completed_at is distinct from old.completed_at
       or coalesce(new.is_heading,false) is distinct from coalesce(old.is_heading,false) then
  new.completion_version := old.completion_version + 1;
 else new.completion_version := old.completion_version;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.advance_completion_revision() from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.taskfold_patch_task(_id uuid, _base jsonb, _changes jsonb)
 RETURNS tasks
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t public.tasks; merged jsonb; k text; base_value jsonb; desired_value jsonb; remote_value jsonb; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at','is_heading'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 if taskfold_private.is_team_content_task(_id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this team action in a supported Taskfold app';end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if _changes is null or _base is null or jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 if t.task_generation is distinct from (_base->>'task_generation')::uuid then
  raise exception 'TASKFOLD_CONFLICT: This edit belongs to an earlier task. Review the synced version';
 end if;
 merged := to_jsonb(t);
 -- Completion revisions detect an intervening complete/reopen cycle even when
 -- the visible values returned to their baseline. Old clients remain compatible;
 -- new native queues require the revision and send it only in the baseline.
 if _changes ? 'is_heading' then
  if jsonb_typeof(_changes->'is_heading') <> 'boolean' or not (_base ?& array['is_heading','completed','completed_at','completion_version']) then
   raise exception 'TASKFOLD_CONFLICT: Review the task type before changing it';
  end if;
  if (_base->'is_heading' <> 'null'::jsonb and jsonb_typeof(_base->'is_heading') <> 'boolean')
     or _base->'completed' is distinct from to_jsonb(t.completed)
     or (case when _base->'completed_at'='null'::jsonb then null else (_base->>'completed_at')::timestamptz end) is distinct from t.completed_at then
   raise exception 'TASKFOLD_CONFLICT: Completion changed before the task type was saved';
  end if;
 end if;
 if _changes ?| array['completed','completed_at','is_heading'] and _base ? 'completion_version' then
  if jsonb_typeof(_base->'completion_version') <> 'number'
     or (_base->>'completion_version')::numeric <> trunc((_base->>'completion_version')::numeric)
     or (_base->>'completion_version')::numeric < 0 then
   raise exception 'TASKFOLD_CONFLICT: Review this completion before replacing synced state';
  end if;
  if t.completion_version <> (_base->>'completion_version')::bigint then
   -- Only the immediately following revision with identical desired completion
   -- values is a lost-response retry. A later cycle can never be mistaken for it.
   if t.completion_version <> (_base->>'completion_version')::bigint + 1
      or (_changes ? 'completed' and t.completed is distinct from (_changes->>'completed')::boolean)
      or (_changes ? 'completed_at' and t.completed_at is distinct from (_changes->>'completed_at')::timestamptz)
      or (_changes ? 'is_heading' and t.is_heading is distinct from (_changes->>'is_heading')::boolean) then
    raise exception 'TASKFOLD_CONFLICT: Completion changed on another device. Review the synced task';
   end if;
  end if;
 end if;

 for k in select jsonb_object_keys(_changes) loop
   if not k = any(allowed) then raise exception 'This task field cannot be edited'; end if;
   if not _base ? k then raise exception 'An edit baseline is required'; end if;
   base_value := _base->k; desired_value := _changes->k; remote_value := merged->k;
   -- Native queues use Z, PostgREST returns +00:00. Compare instants, not JSON spelling.
   -- Real concurrent changes (including different DST folds) must still conflict.
   if k = any(array['scheduled_at','completed_at','notification_sent_at']) then
    if jsonb_typeof(base_value) = 'string' then base_value := to_jsonb((base_value#>>'{}')::timestamptz); end if;
    if jsonb_typeof(desired_value) = 'string' then desired_value := to_jsonb((desired_value#>>'{}')::timestamptz); end if;
    if jsonb_typeof(remote_value) = 'string' then remote_value := to_jsonb((remote_value#>>'{}')::timestamptz); end if;
   elsif k = 'due_time' then
    if jsonb_typeof(base_value) = 'string' then base_value := to_jsonb((base_value#>>'{}')::time); end if;
    if jsonb_typeof(desired_value) = 'string' then desired_value := to_jsonb((desired_value#>>'{}')::time); end if;
    if jsonb_typeof(remote_value) = 'string' then remote_value := to_jsonb((remote_value#>>'{}')::time); end if;
   end if;
   if k = 'subtasks' and desired_value is distinct from base_value
      and remote_value is distinct from base_value and remote_value is distinct from desired_value
      and (taskfold_private.subtask_layout(desired_value) is distinct from taskfold_private.subtask_layout(base_value)
        or taskfold_private.subtask_layout(remote_value) is distinct from taskfold_private.subtask_layout(base_value)) then
     raise exception 'TASKFOLD_CONFLICT: The checklist structure changed on another device. Review the layout and saved edits.';
   end if;
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(base_value, desired_value, remote_value), 'null'));
 end loop;
 t := jsonb_populate_record(t, merged);
 update public.tasks set title=t.title,description=t.description,is_heading=t.is_heading,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to,deadline_date=t.deadline_date,duration_minutes=t.duration_minutes,time_zone=t.time_zone,reminder_specs=t.reminder_specs,source_metadata=t.source_metadata,scheduled_at=t.scheduled_at where id=_id returning * into t;
 return t;
end $function$;

revoke all on function public.taskfold_patch_task(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.taskfold_patch_task(uuid,jsonb,jsonb) to authenticated;
