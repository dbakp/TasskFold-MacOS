-- Server-owned revision protects native offline completion/reopen baselines.
alter table public.tasks add column completion_version bigint not null default 0
 check (completion_version >= 0);

-- Preserve an explicitly supplied completion instant so a lost-response retry is
-- equivalent. Older clients that send only completed retain the server-time default.
create or replace function public.update_completed_at()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
 if coalesce(new.completed,false) and not coalesce(old.completed,false) then
  if new.completed_at is null or new.completed_at is not distinct from old.completed_at then
   new.completed_at := now();
  end if;
 elsif not coalesce(new.completed,false) and coalesce(old.completed,false) then
  new.completed_at := null;
 end if;
 return new;
end $$;
revoke all on function public.update_completed_at() from public, anon, authenticated;

create or replace function taskfold_private.advance_completion_revision()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
 if tg_op = 'INSERT' then new.completion_version := 0;
 elsif coalesce(new.completed,false) is distinct from coalesce(old.completed,false)
       or new.completed_at is distinct from old.completed_at then
  new.completion_version := old.completion_version + 1;
 else new.completion_version := old.completion_version;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.advance_completion_revision() from public, anon, authenticated;
-- BEFORE triggers run by name. Count the final state after the timestamp normalizer.
create trigger zz_taskfold_completion_revision before insert or update on public.tasks
 for each row execute function taskfold_private.advance_completion_revision();

CREATE OR REPLACE FUNCTION public.taskfold_patch_task(_id uuid, _base jsonb, _changes jsonb)
 RETURNS tasks
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t public.tasks; merged jsonb; k text; base_value jsonb; desired_value jsonb; remote_value jsonb; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if _changes is null or _base is null or jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 merged := to_jsonb(t);
 -- Completion revisions detect an intervening complete/reopen cycle even when
 -- the visible values returned to their baseline. Old clients remain compatible;
 -- new native queues require the revision and send it only in the baseline.
 if _changes ?| array['completed','completed_at'] and _base ? 'completion_version' then
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
      or (_changes ? 'completed_at' and t.completed_at is distinct from (_changes->>'completed_at')::timestamptz) then
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
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(base_value, desired_value, remote_value), 'null'));
 end loop;
 t := jsonb_populate_record(t, merged);
 update public.tasks set title=t.title,description=t.description,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to,deadline_date=t.deadline_date,duration_minutes=t.duration_minutes,time_zone=t.time_zone,reminder_specs=t.reminder_specs,source_metadata=t.source_metadata,scheduled_at=t.scheduled_at where id=_id returning * into t;
 return t;
end $function$;

revoke all on function public.taskfold_patch_task(uuid,jsonb,jsonb) from public, anon;
grant execute on function public.taskfold_patch_task(uuid,jsonb,jsonb) to authenticated;

-- Older whole-task baselines have the initial revision; newer cycles still conflict.
-- Native deletion and undo preserve tasks changed after the local action.
-- This API adds a check without weakening existing row-level permissions.
create or replace function public.taskfold_delete_task(_id uuid, _base jsonb)
returns boolean language plpgsql security invoker set search_path = '' as $$
declare t public.tasks; expected public.tasks; current_json jsonb; expected_json jsonb; k text;
begin
 if auth.uid() is null then raise exception 'Sign in to delete tasks'; end if;
 if _base is null or jsonb_typeof(_base) <> 'object' or not (_base ?& array['id','user_id','title']) then
  raise exception 'TASKFOLD_CONFLICT: Review this older deletion before removing a synced task';
 end if;
 if (_base->>'id')::uuid is distinct from _id then raise exception 'Invalid deletion identity'; end if;
 select * into t from public.tasks where id = _id for update;
 -- Already deleted or no longer visible: an idempotent success never reveals another account's row.
 if not found then return true; end if;
 -- Defaults match missing=default inserts from the native queue. Populate the typed record
 -- to canonicalize UUIDs, dates, clocks and timestamps before comparing the whole task.
 expected := jsonb_populate_record(null::public.tasks,
  '{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}'::jsonb || _base);
 current_json := to_jsonb(t); expected_json := to_jsonb(expected);
 for k in select jsonb_object_keys(current_json) loop
  -- The server assigns created_at when an ordinary new-task insert omits it.
  if k = 'created_at' and not (_base ? k) then continue; end if;
  if current_json->k is distinct from expected_json->k then
   raise exception 'TASKFOLD_CONFLICT: This task changed before deletion. Review the synced version';
  end if;
 end loop;
 delete from public.tasks where id = _id;
 if not found then raise exception 'This task could not be deleted. Your change is saved locally.'; end if;
 return true;
end $$;
revoke all on function public.taskfold_delete_task(uuid,jsonb) from public, anon;
grant execute on function public.taskfold_delete_task(uuid,jsonb) to authenticated;
