-- Down script for 20261115100000_child_task_rows_a.sql. NOT a migration: never place it in supabase/migrations.
-- Operator use only, valid until Migration B has converted JSON subtasks into rows.
-- Refuses to run once any child row exists, because dropping parent_id would silently flatten the tree.
-- Keeps the `waiting_on` fix: that was a bug fix, and removing it would bring the rejected-sync bug back.
-- Run with: supabase db query --remote --yes -f Scripts/Database/child_rows_a_down.sql   (only after the user's go)
begin;

do $down$
begin
 if exists (select 1 from public.tasks where parent_id is not null or child_order is not null) then
  raise exception using errcode='55000',message='Child task rows exist. Export and remove them (the Migration B back-out) before running the down script';
 end if;
end
$down$;

drop trigger if exists taskfold_guard_team_parent_delete on public.tasks;
drop trigger if exists taskfold_cascade_task_parent_move on public.tasks;
drop trigger if exists taskfold_guard_task_parent on public.tasks;
drop function if exists taskfold_private.guard_team_parent_delete();
drop function if exists taskfold_private.cascade_task_parent_move();
drop function if exists taskfold_private.guard_task_parent();

-- Reverse the anchor patch of taskfold_patch_task: allowlist, update list and the parent conflict rule.
-- The scoped-assignment guard and the waiting_on allowlist entry stay.
do $down$
declare
 definition text;
 patched text;
 marker constant text := 'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1';
 conflict_marker constant text := 'TASKFOLD_CHILD_PARENT_CONFLICT_V1';
 allow_new constant text := ',''is_heading'',''parent_id'',''child_order'',''waiting_on''];';
 allow_old constant text := ',''is_heading'',''waiting_on''];';
 set_new constant text := 'scheduled_at=t.scheduled_at,parent_id=t.parent_id,child_order=t.child_order,waiting_on=t.waiting_on where id=_id';
 set_old constant text := 'scheduled_at=t.scheduled_at,waiting_on=t.waiting_on where id=_id';
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
 if pg_catalog.strpos(definition,conflict_marker) = 0 then return; end if;
 if (pg_catalog.length(definition)-pg_catalog.length(pg_catalog.replace(definition,allow_new,''))) / pg_catalog.length(allow_new) <> 1
  or (pg_catalog.length(definition)-pg_catalog.length(pg_catalog.replace(definition,set_new,''))) / pg_catalog.length(set_new) <> 1
  or (pg_catalog.length(definition)-pg_catalog.length(pg_catalog.replace(definition,conflict_sql,''))) / pg_catalog.length(conflict_sql) <> 1 then
  raise exception using errcode='55000',message='taskfold_patch_task no longer matches the expected shape; review it before reverting';
 end if;
 patched := pg_catalog.replace(definition,allow_new,allow_old);
 patched := pg_catalog.replace(patched,set_new,set_old);
 patched := pg_catalog.replace(patched,conflict_sql,'');
 execute patched;
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef(function),marker) = 0
  or pg_catalog.strpos(pg_catalog.pg_get_functiondef(function),conflict_marker) > 0
  or pg_catalog.strpos(pg_catalog.pg_get_functiondef(function),'''parent_id''') > 0 then
  raise exception using errcode='55000',message='taskfold_patch_task revert did not apply cleanly';
 end if;
end
$down$;

drop index if exists public.tasks_children;
alter table public.tasks drop constraint if exists tasks_child_order_finite;
alter table public.tasks drop constraint if exists tasks_parent_not_self;
alter table public.tasks drop column if exists child_order;
alter table public.tasks drop column if exists parent_id;

notify pgrst, 'reload schema';

commit;
