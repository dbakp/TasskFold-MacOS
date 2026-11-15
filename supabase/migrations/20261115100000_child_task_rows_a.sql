-- Migration A for child task rows (design-review/child-tasks-plan.md). Additive and backward compatible:
-- old builds neither send nor need the new columns, and root tasks keep them NULL.
-- Also fixes `waiting_on`, which existed as a column but was missing from the taskfold_patch_task allowlist.
-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- 1. Columns, checks, index.
alter table public.tasks add column if not exists parent_id uuid null references public.tasks(id) on delete cascade;
alter table public.tasks add column if not exists child_order double precision null;

do $migration$ begin
 if not exists (select 1 from pg_catalog.pg_constraint where conrelid='public.tasks'::regclass and conname='tasks_parent_not_self') then
  alter table public.tasks add constraint tasks_parent_not_self check (parent_id is distinct from id);
 end if;
 -- NaN sorts above Infinity in PostgreSQL, so the upper bound also rejects NaN.
 if not exists (select 1 from pg_catalog.pg_constraint where conrelid='public.tasks'::regclass and conname='tasks_child_order_finite') then
  alter table public.tasks add constraint tasks_child_order_finite check (child_order is null or (child_order > '-Infinity'::float8 and child_order < 'Infinity'::float8));
 end if;
end $migration$;

create index if not exists tasks_children on public.tasks(parent_id, child_order, created_at, id) where parent_id is not null;

-- 2. Structure guard. Deliberately a trigger and not an RLS policy: policies that read public.tasks recurse.
-- SECURITY DEFINER so it can read the parent row and the ancestor chain regardless of the caller's policies;
-- access to the parent is re-checked explicitly with can_access_task. A missing parent and an inaccessible
-- parent raise the same error, so the check cannot be used to probe for task ids.
create or replace function taskfold_private.guard_task_parent() returns trigger
language plpgsql security definer set search_path='' as $$
declare
 p public.tasks;
 up_chain integer;
 cyclic boolean;
 below integer;
 uid uuid := auth.uid();
begin
 -- `update of` fires whenever a column is merely named in the SET list (taskfold_patch_task names all of them),
 -- so exit before taking any lock when nothing structural changed.
 if tg_op='UPDATE' and new.parent_id is not distinct from old.parent_id
    and new.project_id is not distinct from old.project_id and new.section_id is not distinct from old.section_id
    and new.user_id is not distinct from old.user_id and new.child_order is not distinct from old.child_order then
  return new;
 end if;
 if new.parent_id is null then
  -- Roots carry no order. A detach (parent_id -> NULL) clears the stale order.
  new.child_order := null;
  return new;
 end if;

 perform pg_advisory_xact_lock(hashtextextended('taskfold_task_tree',0));
 select * into p from public.tasks where id=new.parent_id;
 if not found or (uid is not null and not taskfold_private.can_access_task(uid,new.parent_id)) then
  raise exception using errcode='23503',message='The parent task is not available';
 end if;

 -- Deleting a project sets tasks.project_id to NULL one row at a time, in no particular order.
 -- That must not be blocked by a parent that has not been updated yet.
 if tg_op='UPDATE' and old.project_id is not null and new.project_id is null
    and not exists (select 1 from public.projects where id=old.project_id) then
  if p.user_id is distinct from new.user_id then
   -- The two tasks end up personal tasks of different owners: they cannot stay linked.
   new.parent_id := null; new.child_order := null;
  end if;
  return new;
 end if;

 if new.project_id is distinct from p.project_id or (new.project_id is null and new.user_id is distinct from p.user_id) then
  raise exception using errcode='23514',message='A subtask must stay in the same project as its parent';
 end if;

 if tg_op='INSERT' or new.parent_id is distinct from old.parent_id then
  -- Ancestor chain, nearest first: includes the parent and the root. Bounded, so corrupt data cannot loop.
  with recursive up(id, parent_id, depth) as (
   select t.id, t.parent_id, 1 from public.tasks t where t.id=new.parent_id
   union all
   select t.id, t.parent_id, up.depth+1 from public.tasks t join up on t.id=up.parent_id where up.depth<64)
  select coalesce(max(depth),0), coalesce(bool_or(id=new.id),false) into up_chain, cyclic from up;
  if cyclic then raise exception using errcode='23514',message='A task cannot become a subtask of its own subtask'; end if;
  -- Levels below the moved task (0 for a leaf), so a moved subtree cannot push its deepest node past the limit.
  with recursive down(id, depth) as (
   select t.id, 1 from public.tasks t where t.parent_id=new.id and tg_op='UPDATE'
   union all
   select t.id, down.depth+1 from public.tasks t join down on t.parent_id=down.id where down.depth<64)
  select coalesce(max(depth),0) into below from down;
  if up_chain + below > 10 then
   raise exception using errcode='54000',message='Subtasks can be at most 10 levels deep';
  end if;
  if new.child_order is null then
   select coalesce(max(child_order),0)+1 into new.child_order from public.tasks where parent_id=new.parent_id and id<>new.id;
  end if;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_task_parent() from public,anon,authenticated,service_role;

drop trigger if exists taskfold_guard_task_parent on public.tasks;
create trigger taskfold_guard_task_parent before insert or update of parent_id, project_id, section_id, user_id, child_order
 on public.tasks for each row execute function taskfold_private.guard_task_parent();

-- 3. Moving a parent moves its children. AFTER trigger, one level per call: each child update fires this trigger
-- again for its own children, so the structure guard always sees the parent already in its new place.
-- The child updates run the ordinary per-row triggers: guard_task clears a child's assignee on a project change
-- (the personal/team move scopes authorise only the moved parent), taskfold_audio_task_move refuses a move while a
-- child has live recordings (the whole move rolls back), and guard_task_file_reference / guard_closed_team_content
-- fail closed for team content.
create or replace function taskfold_private.cascade_task_parent_move() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.project_id is not distinct from old.project_id and new.section_id is not distinct from old.section_id then return new; end if;
 update public.tasks c set project_id=new.project_id, section_id=new.section_id
  where c.parent_id=new.id and (c.project_id is distinct from new.project_id or c.section_id is distinct from new.section_id);
 return new;
end $$;
revoke all on function taskfold_private.cascade_task_parent_move() from public,anon,authenticated,service_role;

drop trigger if exists taskfold_cascade_task_parent_move on public.tasks;
create trigger taskfold_cascade_task_parent_move after update of project_id, section_id
 on public.tasks for each row execute function taskfold_private.cascade_task_parent_move();

-- 4. Team cascade delete: the SAFER option. guard_closed_team_content is left exactly as it is (no relaxation, no
-- pg_trigger_depth() exception). Deleting a task is refused while it still has children when it lives in a team
-- project and the caller has a subject (SQL operators without one stay trusted, like everywhere else in the guard).
-- The client must remove team children first (phase T). Nothing creates team child rows before phase T, so this
-- changes no current behaviour; it keeps a cascade from deleting team children without their per-task custody
-- (files, recordings, activity) even inside an unrelated team operation window.
create or replace function taskfold_private.guard_team_parent_delete() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is not null and old.project_id is not null and taskfold_private.is_team_content_project(old.project_id)
    and exists (select 1 from public.tasks c where c.parent_id=old.id) then
  raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Remove the subtasks of this team task in a supported Taskfold app first';
 end if;
 return old;
end $$;
revoke all on function taskfold_private.guard_team_parent_delete() from public,anon,authenticated,service_role;

drop trigger if exists taskfold_guard_team_parent_delete on public.tasks;
create trigger taskfold_guard_team_parent_delete before delete
 on public.tasks for each row execute function taskfold_private.guard_team_parent_delete();

-- 5. taskfold_patch_task: anchor-replace (never a full redefinition), so the scoped-assignment guard that earlier
-- migrations injected stays in place. Each anchor must occur exactly once; the marker is asserted afterwards.
do $migration$
declare
 definition text;
 patched text;
 marker constant text := 'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1';
 conflict_marker constant text := 'TASKFOLD_CHILD_PARENT_CONFLICT_V1';
 allow_new constant text := ',''is_heading'',''parent_id'',''child_order'',''waiting_on''];';
 set_new constant text := 'scheduled_at=t.scheduled_at,parent_id=t.parent_id,child_order=t.child_order,waiting_on=t.waiting_on where id=_id';
 allow_old text := ',''is_heading''];';
 set_old text := 'scheduled_at=t.scheduled_at where id=_id';
 merge_old constant text := 'merged := jsonb_set(merged, array[k]';
 conflict_sql constant text := $rule$
   -- TASKFOLD_CHILD_PARENT_CONFLICT_V1
   if k = 'parent_id' and desired_value is distinct from base_value
      and remote_value is distinct from base_value and remote_value is distinct from desired_value then
     raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This task was moved under a different parent on another device. Review the synced version';
   end if;
   $rule$;
 function constant regprocedure := 'public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure;
begin
 definition := pg_catalog.pg_get_functiondef(function);
 if pg_catalog.strpos(definition,marker) = 0 then
  raise exception using errcode='55000',message='taskfold_patch_task has lost the scoped assignment guard; refusing to patch it';
 end if;
 if pg_catalog.strpos(definition,conflict_marker) > 0 then return; end if;
 -- Re-applying after Scripts/Database/child_rows_a_down.sql: that script keeps the waiting_on fix in place.
 if pg_catalog.strpos(definition,',''is_heading'',''waiting_on''];') > 0 then
  allow_old := ',''is_heading'',''waiting_on''];';
  set_old := 'scheduled_at=t.scheduled_at,waiting_on=t.waiting_on where id=_id';
 end if;
 if (pg_catalog.length(definition)-pg_catalog.length(pg_catalog.replace(definition,allow_old,''))) / pg_catalog.length(allow_old) <> 1
  or (pg_catalog.length(definition)-pg_catalog.length(pg_catalog.replace(definition,set_old,''))) / pg_catalog.length(set_old) <> 1
  or (pg_catalog.length(definition)-pg_catalog.length(pg_catalog.replace(definition,merge_old,''))) / pg_catalog.length(merge_old) <> 1 then
  raise exception using errcode='55000',message='taskfold_patch_task no longer matches the expected shape; review it before patching';
 end if;
 patched := pg_catalog.replace(definition,allow_old,allow_new);
 patched := pg_catalog.replace(patched,set_old,set_new);
 patched := pg_catalog.replace(patched,merge_old,conflict_sql || merge_old);
 execute patched;
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef(function),marker) = 0
  or pg_catalog.strpos(pg_catalog.pg_get_functiondef(function),conflict_marker) = 0
  or pg_catalog.strpos(pg_catalog.pg_get_functiondef(function),'''waiting_on''') = 0 then
  raise exception using errcode='55000',message='taskfold_patch_task patch did not apply cleanly';
 end if;
end
$migration$;

notify pgrst, 'reload schema';

commit;
