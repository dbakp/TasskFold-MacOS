-- Back-out for Migration B (20261116100000_child_task_rows_b.sql). NOT a migration; never run it automatically.
-- Operator only (postgres, no request role), after a data dump of tasks, view_orders and taskfold_private.json_subtask_*.
-- Valid until phase 7 (legacy code deletion). Run with: psql -v ON_ERROR_STOP=1 -f Scripts/Database/child_rows_b_backout.sql
--
-- What it does, in one transaction:
--  1. Exports every converted child row and its current descendants (as they are now, with later edits) into
--     taskfold_private.json_subtask_backout_rows, then deletes those rows (children first, by cascade from the top).
--  2. Restores each converted root's original `subtasks` tree from the archive (roots deleted since are reported).
--  3. Reverses the view_orders remap where the list is still exactly what the remap wrote.
--  4. Drops the freeze trigger, restores child_task_record_config and re-grants the revoked RPCs to authenticated.
-- It leaves the archive, the helper functions and the producer patches in place (harmless with the JSON system back on;
-- the edge functions must be rolled back to their previous versions separately, before or right after this script).
-- Subtasks added in new builds under converted rows are exported too (they go with their parent). Child rows under
-- roots that never had a JSON tree are left as rows and counted in the NOTICE output; review them by hand.
begin;
set local lock_timeout = '10s';

create table if not exists taskfold_private.json_subtask_backout_rows (
 id uuid primary key, root_id uuid not null, row_data jsonb not null, exported_at timestamptz not null default now());
alter table taskfold_private.json_subtask_backout_rows enable row level security;
revoke all on taskfold_private.json_subtask_backout_rows from public, anon, authenticated, service_role;

do $backout$
declare
 c taskfold_private.json_subtask_conversions; s taskfold_private.child_rows_cutover; fn text; flags text;
 restored integer := 0; missing integer := 0; exported integer := 0; views integer := 0; extra integer;
begin
 if auth.uid() is not null or coalesce(auth.role(), '') <> '' then raise exception 'Run the back-out as the SQL operator, not as a request role'; end if;
 select * into s from taskfold_private.child_rows_cutover where singleton;
 if not found then raise exception 'Migration B has not run here: nothing to back out'; end if;

 -- The freeze would refuse nothing here (operator), but drop it first so the restore reads clearly.
 drop trigger if exists aaa_taskfold_subtasks_frozen on public.tasks;
 alter table public.tasks disable trigger zz_taskfold_webhook_capture, disable trigger taskfold_capture_node_activity, disable trigger taskfold_capture_activity;

 for c in select * from taskfold_private.json_subtask_conversions where status = 'converted' order by converted_at, root_id for update loop
  -- Export the converted rows and everything now below them (subtasks added in new builds would go by cascade).
  insert into taskfold_private.json_subtask_backout_rows(id, root_id, row_data)
  with recursive below(id) as (select t.id from public.tasks t where t.id = any(c.child_ids)
   union select t.id from public.tasks t join below b on t.parent_id = b.id)
  select t.id, c.root_id, pg_catalog.to_jsonb(t) from public.tasks t where t.id in (select id from below)
  on conflict (id) do nothing;
  get diagnostics extra = row_count; exported := exported + extra;
  -- on delete cascade removes the descendants with them.
  delete from public.tasks t where t.id = any(c.child_ids);
  if exists (select 1 from public.tasks where id = c.root_id) then
   update public.tasks set subtasks = c.original where id = c.root_id;
   restored := restored + 1;
  else
   missing := missing + 1;
   raise notice 'root % was deleted after the cutover; its tree stays in the archive only', c.root_id;
  end if;
 end loop;

 alter table public.tasks enable trigger zz_taskfold_webhook_capture, enable trigger taskfold_capture_node_activity, enable trigger taskfold_capture_activity;

 -- view_orders: only where the list is still what the remap wrote (later client reorders win).
 update public.view_orders v set ids = r.original
 from taskfold_private.json_subtask_view_order_remaps r
 where v.user_id = r.user_id and v.id = r.view_id and v.ids = r.remapped;
 get diagnostics views = row_count;

 -- Config and grants back to the state captured by the first run of Migration B.
 select pg_catalog.string_agg(pg_catalog.format('%I = %L::boolean', e.key, e.value #>> '{}'), ', ') into flags
 from pg_catalog.jsonb_each(s.config_before) e where e.key like '%\_enabled';
 execute pg_catalog.format('update taskfold_private.child_task_record_config set %s where singleton', flags);
 foreach fn in array s.revoked_functions loop
  if pg_catalog.to_regprocedure(fn) is not null then execute pg_catalog.format('grant execute on function %s to authenticated', fn); end if;
 end loop;

 select count(*) into extra from public.tasks where parent_id is not null;
 raise notice 'child_rows_b back-out: % roots restored, % roots missing, % rows exported, % view orders reverted, % child rows remain (created after the cutover; review by hand)',
  restored, missing, exported, views, extra;
 delete from taskfold_private.child_rows_cutover where singleton;
 -- Archive rows stay (status kept) so a later re-run of Migration B would skip these roots: clear them deliberately
 -- (delete from taskfold_private.json_subtask_conversions) only when you intend to convert again.
end
$backout$;

notify pgrst, 'reload schema';
commit;
