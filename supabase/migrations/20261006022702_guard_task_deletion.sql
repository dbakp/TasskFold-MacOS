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
  '{"completed":false,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}'::jsonb || _base);
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
