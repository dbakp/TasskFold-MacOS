-- Recheck task visibility on Resume, including a paused session on a revoked project.
create or replace function public.taskfold_set_focus_session(_base jsonb, _action uuid, _state jsonb)
returns public.focus_sessions language plpgsql security invoker set search_path = '' as $$
declare current_row public.focus_sessions; owner uuid := auth.uid(); base_revision numeric;
begin
  if owner is null then raise insufficient_privilege using message = 'Sign in to change a Focus session.'; end if;
  if _base is null or jsonb_typeof(_base) <> 'object' or not (_base ?& array['revision','action_id'])
     or (_base - array['revision','action_id']) <> '{}'::jsonb or jsonb_typeof(_base->'revision') <> 'number' then
    raise exception 'TASKFOLD_FOCUS_CONFLICT: This session needs a revision baseline.';
  end if;
  base_revision := (_base->>'revision')::numeric;
  if trunc(base_revision) <> base_revision or base_revision < 0 or base_revision >= 9007199254740991
     or (base_revision = 0 and _base->'action_id' <> 'null'::jsonb)
     or (base_revision > 0 and (jsonb_typeof(_base->'action_id') <> 'string' or (_base->>'action_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) then
    raise exception 'TASKFOLD_FOCUS_CONFLICT: Invalid session revision baseline.';
  end if;
  _state := nullif(_state, 'null'::jsonb);
  if _action is null or not taskfold_private.valid_focus_state(_state) then
    raise exception 'Invalid Focus session document.';
  end if;
  -- The unique insert also serializes two first starts. A row lock serializes later commands.
  insert into public.focus_sessions(user_id,id) values(owner,'current') on conflict(user_id,id) do nothing;
  select * into strict current_row from public.focus_sessions where user_id = owner and id = 'current' for update;
  current_row.state := nullif(current_row.state, 'null'::jsonb);
  if current_row.action_id = _action and current_row.state is not distinct from _state then return current_row; end if;
  if current_row.revision <> base_revision or coalesce(to_jsonb(current_row.action_id),'null'::jsonb) <> _base->'action_id'
     or current_row.action_id = _action then
    raise exception 'TASKFOLD_FOCUS_CONFLICT: Focus changed on another device. Review the current session.';
  end if;
  if _state is not null and current_row.state is not null and current_row.state->>'session_id' = _state->>'session_id'
     and current_row.state->>'task_id' <> _state->>'task_id' then
    raise exception 'TASKFOLD_FOCUS_CONFLICT: Start a new Focus session when choosing another task.';
  end if;
  if _state is not null and (current_row.state is null or current_row.state->>'session_id' <> _state->>'session_id'
     or (_state->>'status' = 'running' and current_row.state->>'status' is distinct from 'running')) then
    if not exists(select 1 from public.tasks where id = (_state->>'task_id')::uuid and (not completed or _state->>'status' <> 'running')) then
      raise exception 'TASKFOLD_FOCUS_CONFLICT: This Focus task is no longer open or available in your workspace.';
    end if;
  end if;
  update public.focus_sessions set revision = current_row.revision + 1, action_id = _action, state = _state
  where user_id = owner and id = 'current' returning * into current_row;
  return current_row;
end $$;
revoke all on function public.taskfold_set_focus_session(jsonb,uuid,jsonb) from public, anon;
grant execute on function public.taskfold_set_focus_session(jsonb,uuid,jsonb) to authenticated;
