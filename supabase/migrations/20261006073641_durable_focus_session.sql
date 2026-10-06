-- A retained account-owned slot prevents old offline starts from replacing a newer cycle.
create or replace function taskfold_private.valid_focus_state(s jsonb)
returns boolean language plpgsql immutable security invoker set search_path = '' as $$
declare k text; duration numeric; elapsed numeric; started numeric; changed numeric; running numeric;
begin
  if s is null or s = 'null'::jsonb then return true; end if;
  if jsonb_typeof(s) <> 'object' or not (s ?& array['session_id','task_id','duration_seconds','elapsed_ms','started_at_ms','changed_at_ms','running_since_ms','status'])
     or (s - array['session_id','task_id','duration_seconds','elapsed_ms','started_at_ms','changed_at_ms','running_since_ms','status']) <> '{}'::jsonb then return false; end if;
  foreach k in array array['session_id','task_id'] loop
    if jsonb_typeof(s->k) <> 'string' or (s->>k) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  end loop;
  foreach k in array array['duration_seconds','elapsed_ms','started_at_ms','changed_at_ms'] loop
    if jsonb_typeof(s->k) <> 'number' or trunc((s->>k)::numeric) <> (s->>k)::numeric then return false; end if;
  end loop;
  duration := (s->>'duration_seconds')::numeric;
  elapsed := (s->>'elapsed_ms')::numeric;
  started := (s->>'started_at_ms')::numeric;
  changed := (s->>'changed_at_ms')::numeric;
  if duration < 60 or duration > 10800 or mod(duration,60) <> 0 or elapsed < 0 or elapsed > duration * 1000
     or started < 0 or started > 4133980800000 or changed < started or changed > 4133980800000 then return false; end if;
  if jsonb_typeof(s->'status') <> 'string' or (s->>'status') not in ('running','paused','stopped') then return false; end if;
  if s->>'status' = 'running' then
    if jsonb_typeof(s->'running_since_ms') <> 'number' then return false; end if;
    running := (s->>'running_since_ms')::numeric;
    return trunc(running) = running and running >= started and running <= changed;
  end if;
  return s->'running_since_ms' = 'null'::jsonb;
end $$;
revoke all on function taskfold_private.valid_focus_state(jsonb) from public, anon;
grant usage on schema taskfold_private to authenticated;
grant execute on function taskfold_private.valid_focus_state(jsonb) to authenticated;

create table public.focus_sessions (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null default 'current' check (id = 'current'),
  revision bigint not null default 0 check (revision between 0 and 9007199254740991),
  action_id uuid,
  state jsonb check (taskfold_private.valid_focus_state(state)),
  updated_at timestamptz not null default now(),
  primary key (user_id,id),
  constraint focus_revision_state check ((revision = 0 and action_id is null and state is null) or (revision > 0 and action_id is not null))
);
alter table public.focus_sessions enable row level security;
create policy account_owner on public.focus_sessions for all to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.focus_sessions from public, anon, authenticated;
-- Invoker RPCs use these privileges under RLS. DELETE is deliberately unavailable:
-- Stop clears the state through a revision, never by resetting the slot.
grant select, insert, update on public.focus_sessions to authenticated;

create or replace function taskfold_private.guard_focus_revision()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.revision <> 0 or new.action_id is not null or new.state is not null then
      raise exception 'TASKFOLD_FOCUS_CONFLICT: Create the empty slot before setting its guarded state.';
    end if;
  else
    if new.user_id <> old.user_id or new.id <> old.id or new.revision <> old.revision + 1
       or new.action_id is null or new.action_id is not distinct from old.action_id then
      raise exception 'TASKFOLD_FOCUS_CONFLICT: Focus state requires a new action and revision.';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke all on function taskfold_private.guard_focus_revision() from public, anon, authenticated;
create trigger focus_revision_guard before insert or update on public.focus_sessions
for each row execute function taskfold_private.guard_focus_revision();

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
  if current_row.action_id = _action and current_row.state is not distinct from _state then return current_row; end if;
  if current_row.revision <> base_revision or coalesce(to_jsonb(current_row.action_id),'null'::jsonb) <> _base->'action_id'
     or current_row.action_id = _action then
    raise exception 'TASKFOLD_FOCUS_CONFLICT: Focus changed on another device. Review the current session.';
  end if;
  if _state is not null and (current_row.state is null or current_row.state->>'session_id' <> _state->>'session_id') then
    if not exists(select 1 from public.tasks where id = (_state->>'task_id')::uuid and (not completed or _state->>'status' <> 'running')) then
      raise exception 'TASKFOLD_FOCUS_CONFLICT: This Focus task is no longer open or available in your workspace.';
    end if;
  elsif _state is not null and current_row.state->>'task_id' <> _state->>'task_id' then
    raise exception 'Start a new Focus session when choosing another task.';
  end if;
  update public.focus_sessions set revision = current_row.revision + 1, action_id = _action, state = _state
  where user_id = owner and id = 'current' returning * into current_row;
  return current_row;
end $$;
revoke all on function public.taskfold_set_focus_session(jsonb,uuid,jsonb) from public, anon;
grant execute on function public.taskfold_set_focus_session(jsonb,uuid,jsonb) to authenticated;

do $$ begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.focus_sessions;
  end if;
end $$;
