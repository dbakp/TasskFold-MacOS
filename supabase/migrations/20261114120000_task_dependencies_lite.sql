-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Dependencies lite (14 November 2026): "blocked by" links between tasks and a short
-- "Waiting on" note. No existing table fits (no task_relations/links table exists).
--
-- Design notes
-- * The note is a nullable, length-capped column on public.tasks, like time_zone and
--   the other single-value task fields. It describes the task, not a relationship
--   (a task can wait on a person with no blocker), and it rides the task's own RLS,
--   realtime and activity paths with no new access surface.
-- * Access reuses the task policy predicate: personal tasks belong to their owner and
--   project tasks need public.has_project_access, which already closes team-content
--   projects centrally. A row is readable/writable only when the caller can access
--   BOTH tasks, so a collaborator never receives a row naming a task they cannot see.
-- * Rows are immutable (insert/delete only). The unique pair plus client-derived row
--   IDs make a dependency added on two devices converge on one row.

alter table public.tasks add column waiting_on text
 check (waiting_on is null or char_length(waiting_on) between 1 and 140);

create table public.task_dependencies (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 task_id uuid not null references public.tasks(id) on delete cascade,
 blocked_by_task_id uuid not null references public.tasks(id) on delete cascade,
 created_at timestamptz not null default now(),
 constraint task_dependencies_no_self_block check (task_id <> blocked_by_task_id),
 constraint task_dependencies_unique_pair unique (task_id, blocked_by_task_id)
);
create index task_dependencies_blocker on public.task_dependencies(blocked_by_task_id);
create index task_dependencies_user on public.task_dependencies(user_id);

-- Same predicate as the "Users can view accessible tasks" policy. SECURITY DEFINER so the
-- check reads the task row itself; the caller is passed in and compared to auth.uid() by
-- the policies, never trusted from the row.
create function taskfold_private.can_access_task(_user_id uuid, _task_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(
  select 1 from public.tasks t
  where t.id = _task_id
    and ((t.project_id is null and t.user_id = _user_id) or public.has_project_access(_user_id, t.project_id)))
$$;
revoke all on function taskfold_private.can_access_task(uuid, uuid) from public, anon, authenticated;
grant execute on function taskfold_private.can_access_task(uuid, uuid) to authenticated, service_role;
grant usage on schema taskfold_private to authenticated;

-- Server-side backstops for the client rules: at most 10 blockers per task, and no loops.
-- SECURITY DEFINER so the walk sees every row regardless of the writer's RLS view; the
-- transaction lock serialises concurrent inserts so two opposite edges cannot both pass.
create function taskfold_private.guard_task_dependency() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 -- A self-link is the CHECK constraint's to refuse, with its own clear error.
 if new.task_id = new.blocked_by_task_id then return new; end if;
 -- Refuse callers who cannot access both tasks before looking at any graph data, so the
 -- cap and loop errors cannot be used to probe tasks the caller cannot see. RLS repeats
 -- this check for every row; operators without a request identity (auth.uid() is null) skip it.
 if auth.uid() is not null and not (taskfold_private.can_access_task(auth.uid(), new.task_id)
    and taskfold_private.can_access_task(auth.uid(), new.blocked_by_task_id)) then
  raise exception using errcode = '42501', message = 'new row violates row-level security policy for table "task_dependencies"';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('taskfold_task_dependencies', 0));
 if (select count(*) from public.task_dependencies where task_id = new.task_id) >= 10 then
  raise exception using errcode = '54000', message = 'A task can be blocked by at most 10 tasks';
 end if;
 if exists(
  with recursive walk(id) as (
   select new.blocked_by_task_id
   union
   select d.blocked_by_task_id from public.task_dependencies d join walk w on d.task_id = w.id)
  select 1 from walk where id = new.task_id) then
  raise exception using errcode = '23514', message = 'This dependency would create a loop';
 end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_task_dependency() from public, anon, authenticated;
create trigger task_dependencies_guard before insert on public.task_dependencies
 for each row execute function taskfold_private.guard_task_dependency();

alter table public.task_dependencies enable row level security;
create policy task_dependencies_read on public.task_dependencies for select to authenticated
 using (taskfold_private.can_access_task((select auth.uid()), task_id)
        and taskfold_private.can_access_task((select auth.uid()), blocked_by_task_id));
create policy task_dependencies_insert on public.task_dependencies for insert to authenticated
 with check (user_id = (select auth.uid())
        and taskfold_private.can_access_task((select auth.uid()), task_id)
        and taskfold_private.can_access_task((select auth.uid()), blocked_by_task_id));
create policy task_dependencies_delete on public.task_dependencies for delete to authenticated
 using (taskfold_private.can_access_task((select auth.uid()), task_id)
        and taskfold_private.can_access_task((select auth.uid()), blocked_by_task_id));
revoke all on public.task_dependencies from public, anon, authenticated;
grant select, insert, delete on public.task_dependencies to authenticated;

-- Other task tables are published for Realtime; RLS still filters every delivered change.
do $$ begin
 if exists(select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists(select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'task_dependencies') then
  alter publication supabase_realtime add table public.task_dependencies;
 end if;
end $$;

commit;
