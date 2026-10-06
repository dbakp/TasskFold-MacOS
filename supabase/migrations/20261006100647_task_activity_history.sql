-- Actual transitions only. Existing completion timestamps are not fictional past events.
create table public.task_activity_epoch (
 id text primary key check (id = 'current'),
 recorded_from timestamptz not null default statement_timestamp()
);
insert into public.task_activity_epoch(id) values ('current');
alter table public.task_activity_epoch enable row level security;
revoke all on public.task_activity_epoch from public, anon, authenticated;
grant select on public.task_activity_epoch to authenticated;
create policy task_activity_epoch_read on public.task_activity_epoch for select to authenticated using (true);

create table public.task_activity (
 id uuid primary key default gen_random_uuid(),
 sequence bigint generated always as identity unique,
 user_id uuid not null references auth.users(id) on delete cascade,
 task_id uuid not null,
 actor_id uuid references auth.users(id) on delete set null,
 recorded_at timestamptz not null default statement_timestamp(),
 effective_at timestamptz not null,
 completion_version bigint not null check (completion_version >= 0),
 kinds text[] not null check (cardinality(kinds) > 0 and kinds <@ array['created','completed','reopened','completion_time','rescheduled','moved','deleted']::text[]),
 before_state jsonb not null check (jsonb_typeof(before_state) = 'object'),
 after_state jsonb not null check (jsonb_typeof(after_state) = 'object')
);
create index task_activity_owner_sequence on public.task_activity(user_id, sequence);
create index task_activity_task_sequence on public.task_activity(task_id, sequence);
create index task_activity_actor on public.task_activity(actor_id) where actor_id is not null;
alter table public.task_activity enable row level security;
revoke all on public.task_activity from public, anon, authenticated;
grant select on public.task_activity to authenticated;

-- A private lookup distinguishes a deleted task from a task now hidden by RLS.
-- Owners lose access to future events when their task moves to a revoked project.
-- Collaborators never receive state from a different, private prior/next project.
create function taskfold_private.can_read_task_activity(_owner uuid, _task uuid, _before jsonb, _after jsonb)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare caller uuid := auth.uid(); t public.tasks; before_project uuid := (_before->>'project_id')::uuid; after_project uuid := (_after->>'project_id')::uuid; p uuid;
begin
 if caller is null then return false; end if;
 select * into t from public.tasks where id = _task;
 if found then
  if t.user_id <> _owner then return false; end if;
  if t.project_id is null then return caller = _owner; end if;
  if not public.has_project_access(caller,t.project_id) then return false; end if;
  if caller = _owner then return true; end if;
  return (_before = '{}'::jsonb or before_project = t.project_id)
     and (_after = '{}'::jsonb or after_project = t.project_id);
 end if;
 if caller = _owner then return true; end if;
 p := coalesce(before_project,after_project);
 return p is not null and public.has_project_access(caller,p)
    and (_before = '{}'::jsonb or before_project = p)
    and (_after = '{}'::jsonb or after_project = p);
end $$;
revoke all on function taskfold_private.can_read_task_activity(uuid,uuid,jsonb,jsonb) from public, anon;
grant usage on schema taskfold_private to authenticated;
grant execute on function taskfold_private.can_read_task_activity(uuid,uuid,jsonb,jsonb) to authenticated;
create policy task_activity_read on public.task_activity for select to authenticated
 using (taskfold_private.can_read_task_activity(user_id,task_id,before_state,after_state));

-- Bounded planning/completion metadata only: never notes, attachments or task titles.
create function taskfold_private.activity_state(t public.tasks)
returns jsonb language sql immutable security invoker set search_path = '' as $$
 select jsonb_build_object('project_id',t.project_id,'section_id',t.section_id,
  'completed',coalesce(t.completed,false),'completed_at',t.completed_at,
  'due_date',t.due_date,'due_time',t.due_time,'scheduled_at',t.scheduled_at,
  'time_zone',t.time_zone,'deadline_date',t.deadline_date,'recurrence_parent_id',t.recurrence_parent_id)
$$;
revoke all on function taskfold_private.activity_state(public.tasks) from public, anon, authenticated;

-- Definer is restricted to this table trigger; it writes the otherwise read-only ledger.
-- Table RLS authorizes the original write. A second caller check protects the private writer.
create function taskfold_private.capture_task_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare caller uuid := auth.uid(); t public.tasks; b jsonb := '{}'; a jsonb := '{}'; kinds text[] := '{}'; instant timestamptz := statement_timestamp();
begin
 if tg_table_schema <> 'public' or tg_table_name <> 'tasks' then raise exception 'Invalid activity source'; end if;
 if tg_op = 'INSERT' then t := new; else t := old; end if;
 -- Cascading account deletion must not recreate data for an owner being removed.
 if not exists(select 1 from auth.users where id=t.user_id) then
  if tg_op = 'DELETE' then return old; else return new; end if;
 end if;
 -- Nested FK cascades inherit authorization from the original project/account write.
 if caller is not null and pg_trigger_depth() = 1 and not ((t.project_id is null and t.user_id = caller) or public.has_project_access(caller,t.project_id)) then
  raise exception 'Task activity source is not accessible';
 end if;
 if tg_op <> 'INSERT' then b := taskfold_private.activity_state(old); end if;
 if tg_op <> 'DELETE' then a := taskfold_private.activity_state(new); t := new; end if;
 if tg_op = 'INSERT' then kinds := array['created'];
 elsif tg_op = 'DELETE' then kinds := array['deleted'];
 else
  if coalesce(old.completed,false) is distinct from coalesce(new.completed,false) then
   kinds := array_append(kinds,case when coalesce(new.completed,false) then 'completed' else 'reopened' end);
  elsif old.completed_at is distinct from new.completed_at then kinds := array_append(kinds,'completion_time'); end if;
  if old.project_id is distinct from new.project_id or old.section_id is distinct from new.section_id then kinds := array_append(kinds,'moved'); end if;
  if (b - array['project_id','section_id','completed','completed_at','recurrence_parent_id']) is distinct from (a - array['project_id','section_id','completed','completed_at','recurrence_parent_id']) then
   kinds := array_append(kinds,'rescheduled');
  end if;
 end if;
 if cardinality(kinds) > 0 then
  if 'completed' = any(kinds) and t.completed_at is not null then instant := t.completed_at; end if;
  insert into public.task_activity(user_id,task_id,actor_id,effective_at,completion_version,kinds,before_state,after_state)
   values(t.user_id,t.id,caller,instant,t.completion_version,kinds,b,a);
 end if;
 if tg_op = 'DELETE' then return old; else return new; end if;
end $$;
revoke all on function taskfold_private.capture_task_activity() from public, anon, authenticated;
create trigger taskfold_capture_activity after insert or update or delete on public.tasks
 for each row execute function taskfold_private.capture_task_activity();
-- Task changes already trigger native refresh. Activity is read in the same account-bound sync.
