-- Migration C for child task rows (design-review/child-tasks-plan.md, phase 8): drop the legacy JSON subtask storage.
-- DO NOT DEPLOY before the app PR that stops sending/reading `subtasks` and stops calling the legacy child RPCs is
-- installed on every device (docs/TEAM_CHILD_ROWS.md, "Before C"). Deploy Migration T first (this file checks it).
--  1. Preconditions: T is applied and no task still holds a non-empty JSON tree.
--  2. Drops the legacy triggers (JSON child records, their nonce fences, node-activity capture, the subtasks freeze).
--  3. Policies stop admitting updates through saved JSON-subtask copies.
--  4. Removes every reference to the `subtasks` column and the child_* tables from the functions that stay
--     (anchor-replace, each anchor counted; taskfold_patch_task keeps TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1).
--  5. Drops the legacy functions (the 34 RPCs Migration B revoked, the materialize/projection/repair/adoption machinery).
--  6. Drops the taskfold_private.child_* tables. Keeps taskfold_private.json_subtask_conversions (the archive of every
--     converted tree) and legacy_child_id (and the conversion planner the team producers still use for template trees).
--  7. Drops public.tasks.subtasks.
-- The function and trigger lists were generated from the catalog of a fully migrated local database (all migrations
-- through 20261117100000), so they match hosted exactly; any drift aborts the migration instead of half-applying.
-- Idempotent: a second run finds everything done and changes nothing. Back-out: restore from the pre-deploy dump only.
-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

set local lock_timeout = '10s';

-- 1. Preconditions.
do $migration$
declare remaining bigint;
begin
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef('taskfold_private.team_task_lifecycle(text,jsonb)'::regprocedure), 'TASKFOLD_TEAM_CHILD_ROWS_V1') = 0 then
  raise exception using errcode = '55000', message = 'Deploy Migration T (20261117100000_child_task_rows_team) before Migration C';
 end if;
 if exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.tasks'::regclass and attname = 'subtasks' and not attisdropped) then
  execute 'select count(*) from public.tasks where coalesce(subtasks, ''null''::jsonb) not in (''null''::jsonb, ''[]''::jsonb)' into remaining;
  if remaining > 0 then
   raise exception using errcode = '55000', message = pg_catalog.format('%s tasks still hold JSON subtasks; convert them before Migration C', remaining);
  end if;
 end if;
end
$migration$;

-- Anchor-replace for this migration only (session-local).
create function pg_temp.child_rows_c_patch(fn regprocedure, anchors text[], replacements text[], counts integer[]) returns void
language plpgsql as $$
declare d text := pg_catalog.pg_get_functiondef(fn); i integer; c integer;
begin
 if pg_catalog.strpos(d, 'TASKFOLD_CHILD_ROWS_C_V1') > 0 then return; end if;
 for i in 1 .. pg_catalog.array_length(anchors, 1) loop
  c := (pg_catalog.length(d) - pg_catalog.length(pg_catalog.replace(d, anchors[i], ''))) / pg_catalog.length(anchors[i]);
  if c <> counts[i] then
   raise exception using errcode = '55000', message = pg_catalog.format('%s no longer matches the expected shape (anchor %s found %s times); review it before Migration C', fn, i, c);
  end if;
  d := pg_catalog.replace(d, anchors[i], replacements[i]);
 end loop;
 d := pg_catalog.regexp_replace(d, 'AS \$function\$', 'AS $function$/* TASKFOLD_CHILD_ROWS_C_V1 */ ');
 execute d;
end $$;


-- 2. Legacy triggers (JSON child records, their nonce fences, node activity capture, restored-child guards, the freeze).
drop trigger if exists "child_restore_object_identity" on storage.objects;
drop trigger if exists "task_node_activity_transfer_context" on task_node_activity;
drop trigger if exists "child_restore_nonce" on taskfold_private.audio_restore_closures;
drop trigger if exists "child_restore_nonce" on taskfold_private.audio_selection_restore_closures;
drop trigger if exists "child_restore_nonce" on taskfold_private.audio_task_deletions;
drop trigger if exists "child_restore_nonce" on taskfold_private.mixed_completion_members;
drop trigger if exists "child_restore_nonce" on taskfold_private.mixed_completion_scope;
drop trigger if exists "child_restore_nonce" on taskfold_private.personal_task_move_preparations;
drop trigger if exists "mixed_selection_identity" on taskfold_private.personal_task_move_preparations;
drop trigger if exists "child_adoption_nonce" on taskfold_private.personal_task_moves;
drop trigger if exists "child_repair_nonce" on taskfold_private.personal_task_moves;
drop trigger if exists "child_restore_nonce" on taskfold_private.personal_task_moves;
drop trigger if exists "child_transfer_nonce" on taskfold_private.personal_task_moves;
drop trigger if exists "child_restore_nonce" on taskfold_private.project_adoption_receipts;
drop trigger if exists "child_restore_nonce" on taskfold_private.project_file_preparations;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_commands;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_completion_batch_scope;
drop trigger if exists "child_restore_file_binding" on taskfold_private.team_content_files;
drop trigger if exists "a0_child_record_project_transfer" on taskfold_private.team_content_projects;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_conversation_scope;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_project_commands;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_task_batch_scope;
drop trigger if exists "child_adoption_nonce" on taskfold_private.team_task_batches;
drop trigger if exists "child_completion_terminal_team_batch" on taskfold_private.team_task_batches;
drop trigger if exists "child_field_identity_team_batch" on taskfold_private.team_task_batches;
drop trigger if exists "child_repair_nonce" on taskfold_private.team_task_batches;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_task_batches;
drop trigger if exists "child_step_identity_fence" on taskfold_private.team_task_batches;
drop trigger if exists "child_structure_fence_team_batch" on taskfold_private.team_task_batches;
drop trigger if exists "child_transfer_nonce" on taskfold_private.team_task_batches;
drop trigger if exists "mixed_selection_identity" on taskfold_private.team_task_batches;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_task_edit_scope;
drop trigger if exists "child_adoption_nonce" on taskfold_private.team_task_edits;
drop trigger if exists "child_completion_terminal_team_edit" on taskfold_private.team_task_edits;
drop trigger if exists "child_field_identity_team_edit" on taskfold_private.team_task_edits;
drop trigger if exists "child_repair_nonce" on taskfold_private.team_task_edits;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_task_edits;
drop trigger if exists "child_step_identity_fence" on taskfold_private.team_task_edits;
drop trigger if exists "child_structure_fence_team_edit" on taskfold_private.team_task_edits;
drop trigger if exists "child_transfer_nonce" on taskfold_private.team_task_edits;
drop trigger if exists "mixed_selection_identity" on taskfold_private.team_task_edits;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_task_file_deletions;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_task_moves;
drop trigger if exists "child_restore_nonce" on taskfold_private.team_template_commands;
drop trigger if exists "taskfold_purge_team_child_restore" on taskfold_private.teams;
drop trigger if exists "taskfold_purge_team_repair_originals" on taskfold_private.teams;
drop trigger if exists "child_restore_nonce" on taskfold_private.workflow_runs;
drop trigger if exists "aaa_taskfold_restored_child_content" on tasks;
drop trigger if exists "aaa_taskfold_restored_child_realm" on tasks;
drop trigger if exists "aaa_taskfold_subtasks_frozen" on tasks;
drop trigger if exists "taskfold_capture_node_activity" on tasks;
drop trigger if exists "taskfold_child_record_scope" on tasks;
drop trigger if exists "taskfold_purge_child_structure_archives" on tasks;
drop trigger if exists "taskfold_refresh_child_task_records" on tasks;
do $migration$ begin
 if pg_catalog.to_regclass('taskfold_private.child_mapping_scope') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_mapping_scope'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_repair_restore_requests') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_repair_restore_requests'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_adoptions') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_adoptions'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_adoptions') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_adoptions'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_adoptions') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_adoptions'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_closures') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_completion_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_closures') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_completion_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_closures') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_completion_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_closures') is not null then execute 'drop trigger if exists "child_step_identity_fence" on taskfold_private.child_task_completion_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_closures') is not null then execute 'drop trigger if exists "child_structure_fence_completion_close" on taskfold_private.child_task_completion_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_closures') is not null then execute 'drop trigger if exists "child_transfer_nonce" on taskfold_private.child_task_completion_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_closures') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_completion_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "child_completion_terminal_receipt" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "child_step_identity_fence" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "child_structure_fence_completion_receipt" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "child_transfer_nonce" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_completion_receipts') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_completion_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_close_completion_identity" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_field_identity_close" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_step_identity_fence" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_structure_fence_field_close" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "child_transfer_nonce" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_closures') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_edit_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "child_edit_completion_identity" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "child_step_identity_fence" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "child_structure_fence_field_prepare" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "child_transfer_nonce" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_preparations') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_edit_preparations'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_field_identity_receipt" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_receipt_completion_identity" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_step_identity_fence" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_structure_fence_field_receipt" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "child_transfer_nonce" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_edit_receipts') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_edit_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_projections') is not null then execute 'drop trigger if exists "taskfold_advance_child_task_structure" on taskfold_private.child_task_projections'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_projections') is not null then execute 'drop trigger if exists "taskfold_child_record_mirror" on taskfold_private.child_task_projections'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_record_authority') is not null then execute 'drop trigger if exists "taskfold_child_record_promotion" on taskfold_private.child_task_record_authority'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_repair_originals') is not null then execute 'drop trigger if exists "child_adoption_complete" on taskfold_private.child_task_repair_originals'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_repair_originals') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_repair_originals'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_repair_originals') is not null then execute 'drop trigger if exists "child_restore_original_budget" on taskfold_private.child_task_repair_originals'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_repairs') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_repairs'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_repairs') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_repairs'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_repairs') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_repairs'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_step_closures') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_step_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_step_receipts') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_step_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_archives') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_structure_archives'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_closures') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_structure_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_closures') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_structure_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_closures') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_structure_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_closures') is not null then execute 'drop trigger if exists "child_step_identity_fence" on taskfold_private.child_task_structure_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_closures') is not null then execute 'drop trigger if exists "child_transfer_nonce" on taskfold_private.child_task_structure_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_closures') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_structure_closures'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_receipts') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_structure_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_receipts') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_structure_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_receipts') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_structure_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_receipts') is not null then execute 'drop trigger if exists "child_step_identity_fence" on taskfold_private.child_task_structure_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_receipts') is not null then execute 'drop trigger if exists "child_transfer_nonce" on taskfold_private.child_task_structure_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_structure_receipts') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_structure_receipts'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_transfers') is not null then execute 'drop trigger if exists "child_adoption_nonce" on taskfold_private.child_task_transfers'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_transfers') is not null then execute 'drop trigger if exists "child_repair_nonce" on taskfold_private.child_task_transfers'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_transfers') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_task_transfers'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_task_transfers') is not null then execute 'drop trigger if exists "mixed_selection_identity" on taskfold_private.child_task_transfers'; end if;
 if pg_catalog.to_regclass('taskfold_private.child_transfer_history_scope') is not null then execute 'drop trigger if exists "child_restore_nonce" on taskfold_private.child_transfer_history_scope'; end if;
end $migration$;
-- File references no longer watch the JSON tree.
drop trigger if exists taskfold_guard_task_file_reference on public.tasks;
create trigger taskfold_guard_task_file_reference before insert or update of attachments, comments, project_id, task_generation
 on public.tasks for each row execute function taskfold_private.guard_task_file_reference();

-- 3. Policies: saved JSON-subtask copies no longer admit updates.
alter policy "Users can update accessible tasks" on public.tasks
 using (((project_id is null) and (user_id = (select auth.uid()))) or public.has_project_access((select auth.uid()), project_id))
 with check (((project_id is null) and (user_id = (select auth.uid()))) or public.has_project_access((select auth.uid()), project_id));
alter policy team_native_update_closed on public.tasks
 using ((not taskfold_private.is_team_content_project(project_id)) and (not taskfold_private.is_team_content_task(id)))
 with check ((not taskfold_private.is_team_content_project(project_id)) and (not taskfold_private.is_team_content_task(id)));

-- 4. Live functions: every reference to the JSON tree and the legacy child records removed (anchor-replace, each anchor counted).
select pg_temp.child_rows_c_patch('taskfold_private.team_task_batch(text,jsonb)'::regprocedure,
 array['coalesce(expected.subtasks,''[]'')']::text[],
 array['coalesce(item->''record''->''subtasks'',''[]'')']::text[],
 array[1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.team_completion_batch(text,jsonb)'::regprocedure,
 array['coalesce(expected.subtasks,''[]'')']::text[],
 array['''[]''::jsonb']::text[],
 array[1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.team_task_lifecycle(text,jsonb)'::regprocedure,
 array['nodes=taskfold_private.automation_tree_index(coalesce(desired.subtasks,''[]''));','desired.subtasks=taskfold_private.clear_assignee(desired.subtasks,recipient);','desired.subtasks=taskfold_private.team_task_tree(coalesce(desired.subtasks,''[]''),''{}'',p,a,clock_timestamp());','child_tree:=coalesce(desired.subtasks,''[]'');desired.subtasks:=''[]'';']::text[],
 array['child_tree:=coalesce(payload->''subtasks'',''[]'');nodes=taskfold_private.automation_tree_index(child_tree);','child_tree=taskfold_private.clear_assignee(child_tree,recipient);','child_tree=taskfold_private.team_task_tree(child_tree,''{}'',p,a,clock_timestamp());','']::text[],
 array[1,1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.guard_task()'::regprocedure,
 array['new.assigned_to:=null;new.subtasks:=taskfold_private.clear_assignee(new.subtasks,null);','if tg_op=''INSERT'' or new.subtasks is distinct from old.subtasks or new.project_id is distinct from old.project_id then','case when jsonb_typeof(new.subtasks)=''array'' then new.subtasks else ''[]''::jsonb end']::text[],
 array['new.assigned_to:=null;','if false then','''[]''::jsonb']::text[],
 array[1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.guard_task_headings()'::regprocedure,
 array['if tg_op = ''INSERT'' or new.subtasks is distinct from old.subtasks then','case when pg_catalog.jsonb_typeof(old.subtasks)=''array'' then old.subtasks else ''[]''::jsonb end','case when pg_catalog.jsonb_typeof(new.subtasks)=''array'' then new.subtasks else ''[]''::jsonb end']::text[],
 array['if false then','''[]''::jsonb','''[]''::jsonb']::text[],
 array[1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.capture_assignment_provenance()'::regprocedure,
 array['if tg_op=''UPDATE'' and new.subtasks is not distinct from old.subtasks then return new; end if;','before_nodes:=taskfold_private.assignment_nodes(old.subtasks);','after_nodes:=taskfold_private.assignment_nodes(new.subtasks);']::text[],
 array['return new;','before_nodes:=''{}''::jsonb;','after_nodes:=''{}''::jsonb;']::text[],
 array[1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.clear_departed_assignments()'::regprocedure,
 array['assigned_to = case when assigned_to=old.user_id then null else assigned_to end,
       subtasks = taskfold_private.clear_assignee(subtasks,old.user_id)','(assigned_to=old.user_id or subtasks::text like ''%'' || old.user_id::text || ''%'')']::text[],
 array['assigned_to = case when assigned_to=old.user_id then null else assigned_to end','assigned_to=old.user_id']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('public.taskfold_import_todoist(text,jsonb)'::regprocedure,
 array['labels,subtasks,reminders,','coalesce(t.subtasks,''[]''),']::text[],
 array['labels,reminders,','']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.email_deliver_v2(text,text,text,text,timestamp with time zone,text,jsonb)'::regprocedure,
 array['priority,labels,subtasks,reminders,','false,4,''{}'',''[]'',''{}'',''[]'',''[]'',''[]'',false,''{}'');']::text[],
 array['priority,labels,reminders,','false,4,''{}'',''{}'',''[]'',''[]'',''[]'',false,''{}'');']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure,
 array['   if k = ''subtasks'' and desired_value is distinct from base_value
','labels=t.labels,subtasks=t.subtasks,reminders=t.reminders']::text[],
 array['   if k = ''subtasks'' and coalesce(desired_value,''[]''::jsonb) not in (''[]''::jsonb,''null''::jsonb) then
     raise exception using errcode=''PT409'',message=''TASKFOLD_CONFLICT: Subtasks are now tasks. Update Taskfold to edit them.'';
   end if;
   if k = ''subtasks'' and desired_value is distinct from base_value
','labels=t.labels,reminders=t.reminders']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('public.taskfold_delete_task(uuid,jsonb)'::regprocedure,
 array['"labels":[],"subtasks":[],"reminders":[]']::text[],
 array['"labels":[],"reminders":[]']::text[],
 array[1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.team_task_merge(uuid,jsonb,jsonb)'::regprocedure,
 array['old_nodes=taskfold_private.automation_tree_index(coalesce(t.subtasks,''[]''));','labels=t.labels,subtasks=t.subtasks,reminders=t.reminders',' perform taskfold_private.team_type_review(_base,_changes,to_jsonb(t));']::text[],
 array['old_nodes=''{}''::jsonb;','labels=t.labels,reminders=t.reminders',' if _changes ? ''subtasks'' and coalesce(_changes->''subtasks'',''[]''::jsonb) not in (''[]''::jsonb,''null''::jsonb) then
  raise exception using errcode=''PT409'',message=''TASKFOLD_CONFLICT: Subtasks are now tasks. Update Taskfold to edit them.'';
 end if;
 perform taskfold_private.team_type_review(_base,_changes,to_jsonb(t));']::text[],
 array[1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.team_complete_task(text,jsonb)'::regprocedure,
 array['nodes=taskfold_private.automation_tree_index(coalesce(expected.subtasks,''[]''));','taskfold_private.team_completion_tree_base(coalesce(source.subtasks,''[]'')) is distinct from taskfold_private.team_completion_tree_base(coalesce(expected.subtasks,''[]''))','payload=jsonb_set(payload,array[''subtasks''],taskfold_private.team_completion_children(payload->''subtasks'',p,q));']::text[],
 array['nodes=taskfold_private.automation_tree_index(coalesce(payload->''subtasks'',''[]''));','false','payload=payload-''subtasks'';']::text[],
 array[1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.copy_team_draft(jsonb,boolean,boolean)'::regprocedure,
 array['nodes=taskfold_private.automation_tree_index(coalesce(saved.subtasks,''[]''));','nodes=taskfold_private.automation_tree_index(coalesce(expected.subtasks,''[]''));','desired.subtasks=taskfold_private.team_draft_copy_tree(coalesce(desired.subtasks,''[]''),','child_tree:=coalesce(desired.subtasks,''[]'');desired.subtasks:=''[]'';']::text[],
 array['nodes=taskfold_private.automation_tree_index(coalesce(payload->''subtasks'',''[]''));','nodes=taskfold_private.automation_tree_index(coalesce(original->''record''->''subtasks'',''[]''));','child_tree=taskfold_private.team_draft_copy_tree(coalesce(payload->''subtasks'',''[]''),','']::text[],
 array[1,1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.team_task_move(text,jsonb)'::regprocedure,
 array['coalesce(root_task.subtasks,''[]'')','coalesce(original.subtasks,''[]'')','coalesce(t.subtasks,''[]'')','coalesce(desired.subtasks,''[]'')','desired.subtasks=original.subtasks;','desired.subtasks=taskfold_private.child_record_move_clear(desired.subtasks);','assigned_to=desired.assigned_to,subtasks=desired.subtasks,','''subtask_undo_count'',(select count(*) from taskfold_private.child_task_structure_archives ar where ar.task_id=id and ar.actor_id=a)']::text[],
 array['''[]''::jsonb','''[]''::jsonb','''[]''::jsonb','''[]''::jsonb','','','assigned_to=desired.assigned_to,','''subtask_undo_count'',0']::text[],
 array[1,1,2,3,1,1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.project_adoption_people(uuid[],uuid)'::regprocedure,
 array['jsonb_each(taskfold_private.assignment_nodes(t.subtasks))']::text[],
 array['jsonb_each(''{}''::jsonb)']::text[],
 array[1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure,
 array['taskfold_private.assignment_nodes(subtasks) is null','jsonb_each(taskfold_private.assignment_nodes(t.subtasks))']::text[],
 array['false','jsonb_each(''{}''::jsonb)']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.project_adoption_commit(jsonb)'::regprocedure,
 array['desired=t.subtasks;recipient=t.assigned_to;','jsonb_each(taskfold_private.assignment_nodes(t.subtasks))','if recipient is distinct from t.assigned_to or desired is distinct from t.subtasks then
   desired:=taskfold_private.prepare_child_record_tree(t.id,t.task_generation,desired);
   update public.tasks set assigned_to=recipient,subtasks=desired where id=t.id;end if;']::text[],
 array['desired=''[]''::jsonb;recipient=t.assigned_to;','jsonb_each(''{}''::jsonb)','if recipient is distinct from t.assigned_to then
   update public.tasks set assigned_to=recipient where id=t.id;end if;']::text[],
 array[1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.finish_project_adoption_files(uuid,uuid[],jsonb,jsonb)'::regprocedure,
 array['  desired:=jsonb_set(desired,''{subtasks}'',taskfold_private.prepare_child_record_tree(t.id,t.task_generation,desired->''subtasks''));
',',comments=desired->''comments'',subtasks=desired->''subtasks'' where id=t.id;']::text[],
 array['',',comments=desired->''comments'' where id=t.id;']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.project_adoption_contents(uuid[])'::regprocedure,
 array['for child_item in select * from(values(''child_task_projections''),(''child_task_record_authority''),(''child_task_records''),(''child_task_structure_archives'')) x(rel) loop','select count(*) into own_archives from taskfold_private.child_task_structure_archives where actor_id=auth.uid() and task_id in(select id from public.tasks where project_id=any(ids));']::text[],
 array['for child_item in select * from(values('''')) x(rel) where false loop','own_archives:=0;']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.stage_personal_task_move(uuid,jsonb,jsonb,public.tasks,public.tasks)'::regprocedure,
 array[' perform taskfold_private.child_record_move_index(proposed.subtasks);
 desired:=taskfold_private.child_record_move_clear(proposed.subtasks);
 if exists(select 1 from taskfold_private.child_task_record_authority where task_id=id) and coalesce(desired,''null''::jsonb) is distinct from coalesce(taskfold_private.child_record_move_clear(previous.subtasks),''null''::jsonb) then
  raise exception using errcode=''PT409'',message=''Save separate subtask edits before moving this task'';end if;
','proposed.assigned_to:=null;proposed.subtasks:=desired;']::text[],
 array['','proposed.assigned_to:=null;']::text[],
 array[1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.prepare_personal_task_move(jsonb,boolean)'::regprocedure,
 array[' perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled for share;
 if not found then raise exception']::text[],
 array[' if true then raise exception']::text[],
 array[1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.automation_task_write(uuid,text,text,jsonb)'::regprocedure,
 array['  if fields ? ''subtasks'' then
   perform taskfold_private.automation_tree_index(fields->''subtasks'');
   proposed.subtasks:=taskfold_private.automation_tree(fields->''subtasks'',''{}'',new_project,account,at_time);
','   if taskfold_private.automation_tree_progress(proposed.subtasks)<>''{}''::jsonb then perform taskfold_private.automation_require_scope(_key,account,''tasks:complete'');end if;
','    fields:=fields||jsonb_build_object(''subtasks'',taskfold_private.automation_clear_assignees(coalesce(fields->''subtasks'',base->''subtasks'',''[]'')));
','   if fields ? ''subtasks'' then
    perform taskfold_private.automation_tree_index(fields->''subtasks'');
    fields:=fields||jsonb_build_object(''subtasks'',taskfold_private.automation_tree(fields->''subtasks'',taskfold_private.automation_tree_index(coalesce(base->''subtasks'',''[]'')),new_project,before.user_id,at_time));
    if taskfold_private.automation_tree_progress(fields->''subtasks'') is distinct from taskfold_private.automation_tree_progress(coalesce(base->''subtasks'',''[]'')) then perform taskfold_private.automation_require_scope(_key,account,''tasks:complete'');end if;
   end if;
']::text[],
 array['  if coalesce(fields->''subtasks'',''[]''::jsonb) not in (''[]''::jsonb,''null''::jsonb) then
   raise exception using errcode=''22023'',message=''Subtasks are tasks: create each one with parent_id'';
','','','   if coalesce(fields->''subtasks'',''[]''::jsonb) not in (''[]''::jsonb,''null''::jsonb) then raise exception using errcode=''22023'',message=''Subtasks are tasks: create each one with parent_id'';end if;
   fields:=fields-''subtasks'';
']::text[],
 array[1,1,1,1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.automation_task_projection(public.tasks)'::regprocedure,
 array['''subtasks'',t.subtasks,']::text[],
 array['']::text[],
 array[1]::integer[]);
select pg_temp.child_rows_c_patch('taskfold_private.team_clone_successor_children(uuid,uuid,public.tasks,public.tasks)'::regprocedure,
 array[' rec.subtasks := ''[]'';']::text[],
 array['']::text[],
 array[1]::integer[]);
create or replace function taskfold_private.finish_child_adoption_custody(team uuid, ids uuid[]) returns void
language plpgsql set search_path to '' as $function$
/* TASKFOLD_CHILD_ROWS_C_V1: subtasks are rows that move with their project; only the reviewed scope is confirmed. */
begin
 if cardinality(ids) not between 1 and 1000 or exists(select 1 from unnest(ids) id where not exists(
  select 1 from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=id and s.child_custody_version=1 and not s.child_custody_ready)) then
  raise exception using errcode='42501',message='Subtask custody requires the reviewed project transfer';end if;
 update taskfold_private.team_project_adoption_scope set child_custody_ready=true where transaction_id=txid_current() and actor_id=auth.uid() and team_id=team and project_id=any(ids);
end$function$;
create or replace function taskfold_private.lock_child_adoption_custody(ids uuid[]) returns void
language plpgsql set search_path to '' as $function$
/* TASKFOLD_CHILD_ROWS_C_V1: no JSON child-record custody remains to lock. */
begin
 return;
end$function$;
-- 5. Legacy functions: the JSON child-record system (incl. the RPCs Migration B revoked), its projections and fences.
-- Functions taking a child_* row type go first; those names only resolve while the tables exist.
do $migration$ begin
 if pg_catalog.to_regprocedure('taskfold_private.child_adoption_reply(taskfold_private.child_task_adoptions,boolean)') is not null then execute 'drop function taskfold_private.child_adoption_reply(taskfold_private.child_task_adoptions,boolean)'; end if;
 if pg_catalog.to_regprocedure('taskfold_private.child_completion_batch_receipt(taskfold_private.child_task_completion_batches,boolean)') is not null then execute 'drop function taskfold_private.child_completion_batch_receipt(taskfold_private.child_task_completion_batches,boolean)'; end if;
 if pg_catalog.to_regprocedure('taskfold_private.child_repair_reply(taskfold_private.child_task_repairs,boolean)') is not null then execute 'drop function taskfold_private.child_repair_reply(taskfold_private.child_task_repairs,boolean)'; end if;
 if pg_catalog.to_regprocedure('taskfold_private.child_step_receipt(taskfold_private.child_task_step_receipts,boolean)') is not null then execute 'drop function taskfold_private.child_step_receipt(taskfold_private.child_task_step_receipts,boolean)'; end if;
 if pg_catalog.to_regprocedure('taskfold_private.child_structure_receipt(taskfold_private.child_task_structure_receipts,boolean)') is not null then execute 'drop function taskfold_private.child_structure_receipt(taskfold_private.child_task_structure_receipts,boolean)'; end if;
 if pg_catalog.to_regprocedure('taskfold_private.child_task_completion_receipt(taskfold_private.child_task_completion_receipts,boolean)') is not null then execute 'drop function taskfold_private.child_task_completion_receipt(taskfold_private.child_task_completion_receipts,boolean)'; end if;
 if pg_catalog.to_regprocedure('taskfold_private.child_transfer_reply(taskfold_private.child_task_transfers,boolean)') is not null then execute 'drop function taskfold_private.child_transfer_reply(taskfold_private.child_task_transfers,boolean)'; end if;
end $migration$;
drop function if exists taskfold_adopt_child_records(text,jsonb);
drop function if exists taskfold_child_adoption_targets(uuid,integer,uuid);
drop function if exists taskfold_child_repair_archives(uuid,integer);
drop function if exists taskfold_child_repair_original(uuid,uuid);
drop function if exists taskfold_child_repair_original_cleanup(text,uuid,uuid,text,integer);
drop function if exists taskfold_child_restore_status(jsonb,uuid,uuid);
drop function if exists taskfold_child_steps(text,jsonb);
drop function if exists taskfold_child_steps_available(uuid,uuid);
drop function if exists taskfold_child_structure_undo_archives();
drop function if exists taskfold_close_child_completion(jsonb);
drop function if exists taskfold_close_child_completion_batch(jsonb);
drop function if exists taskfold_close_child_structure(jsonb);
drop function if exists taskfold_close_child_task_edit(jsonb);
drop function if exists taskfold_close_mixed_completion(jsonb);
drop function if exists taskfold_compare_child_repair_original(uuid,uuid);
drop function if exists taskfold_complete_child_task(jsonb);
drop function if exists taskfold_complete_child_tasks(jsonb);
drop function if exists taskfold_complete_mixed_tasks(jsonb);
drop function if exists taskfold_edit_child_structure(jsonb);
drop function if exists taskfold_edit_child_task(jsonb);
drop function if exists taskfold_forget_child_structure_undo(uuid);
drop function if exists taskfold_preview_child_repair(jsonb);
drop function if exists taskfold_private.adopt_child_task_records(uuid,uuid,jsonb);
drop function if exists taskfold_private.adopt_reviewed_children(text,jsonb);
drop function if exists taskfold_private.advance_child_task_structure();
drop function if exists taskfold_private.apply_mixed_completion_root(jsonb,jsonb,jsonb);
drop function if exists taskfold_private.apply_prepared_team_child_field(jsonb);
drop function if exists taskfold_private.capture_child_mapping(tasks,tasks);
drop function if exists taskfold_private.capture_task_node_activity();
drop function if exists taskfold_private.check_child_record_mirror();
drop function if exists taskfold_private.child_adoption_discovery_actor();
drop function if exists taskfold_private.child_adoption_mirror(tasks,tasks);
drop function if exists taskfold_private.child_adoption_root(uuid,uuid,boolean);
drop function if exists taskfold_private.child_adoption_snapshot(tasks);
drop function if exists taskfold_private.child_copy_history(uuid);
drop function if exists taskfold_private.child_copy_history_digest(uuid);
drop function if exists taskfold_private.child_copy_summary(text,jsonb,text,text);
drop function if exists taskfold_private.child_copy_update_admitted(tasks,boolean);
drop function if exists taskfold_private.child_field_removals(jsonb);
drop function if exists taskfold_private.child_field_validation(jsonb);
drop function if exists taskfold_private.child_record_move_clear(jsonb);
drop function if exists taskfold_private.child_repair_archives(uuid,integer);
drop function if exists taskfold_private.child_repair_comparison_current(uuid,uuid);
drop function if exists taskfold_private.child_repair_history_conflict(tasks,jsonb);
drop function if exists taskfold_private.child_repair_history_visible(task_node_activity);
drop function if exists taskfold_private.child_repair_original_bounded(tasks,text,text);
drop function if exists taskfold_private.child_repair_original_cleanup(text,uuid,uuid,text,integer);
drop function if exists taskfold_private.child_repair_path(jsonb,jsonb);
drop function if exists taskfold_private.child_restore_digest(jsonb);
drop function if exists taskfold_private.child_restore_history_counts(uuid);
drop function if exists taskfold_private.child_restore_root(uuid,uuid,uuid,uuid);
drop function if exists taskfold_private.child_restore_snapshot(tasks);
drop function if exists taskfold_private.child_restore_status(jsonb,uuid,uuid);
drop function if exists taskfold_private.child_rows_b_patch(regprocedure,text,text[],text[]);
drop function if exists taskfold_private.child_step_request(text,jsonb);
drop function if exists taskfold_private.child_steps_available(uuid,uuid);
drop function if exists taskfold_private.child_structure_digest(uuid,text);
drop function if exists taskfold_private.child_structure_extract(jsonb,text);
drop function if exists taskfold_private.child_structure_fresh_node(jsonb,boolean);
drop function if exists taskfold_private.child_structure_insert(jsonb,text,integer,jsonb);
drop function if exists taskfold_private.child_structure_remove(jsonb,text);
drop function if exists taskfold_private.child_structure_restore_container(jsonb,text,text);
drop function if exists taskfold_private.child_structure_splice(jsonb,integer,jsonb);
drop function if exists taskfold_private.child_structure_undo_archives();
drop function if exists taskfold_private.child_structure_versions(uuid,text);
drop function if exists taskfold_private.child_task_completion_state(jsonb);
drop function if exists taskfold_private.child_task_completion_tree(jsonb,text,jsonb);
drop function if exists taskfold_private.child_task_edit_finish(jsonb);
drop function if exists taskfold_private.child_task_edit_prepare(jsonb);
drop function if exists taskfold_private.child_task_field_tree(jsonb,text,jsonb);
drop function if exists taskfold_private.child_task_field_tree_v2(jsonb,text,jsonb,text[]);
drop function if exists taskfold_private.child_task_topology(jsonb);
drop function if exists taskfold_private.child_transfer_assign(jsonb,text,boolean,jsonb);
drop function if exists taskfold_private.close_child_completion(jsonb);
drop function if exists taskfold_private.close_child_structure(jsonb);
drop function if exists taskfold_private.close_child_task_batch(jsonb);
drop function if exists taskfold_private.close_child_task_edit(jsonb);
drop function if exists taskfold_private.commit_child_repair(text,jsonb);
drop function if exists taskfold_private.commit_child_repair_before_copy_choice(text,jsonb);
drop function if exists taskfold_private.commit_child_repair_before_history_access(text,jsonb);
drop function if exists taskfold_private.commit_child_repair_before_mapping(text,jsonb);
drop function if exists taskfold_private.commit_child_restore(text,jsonb);
drop function if exists taskfold_private.complete_child_task(jsonb);
drop function if exists taskfold_private.complete_child_task_batch(jsonb);
drop function if exists taskfold_private.completion_selection_root(uuid);
drop function if exists taskfold_private.completion_selection_task(uuid,boolean);
drop function if exists taskfold_private.convert_json_subtasks();
drop function if exists taskfold_private.discovered_child_repair_original(uuid,uuid);
drop function if exists taskfold_private.edit_child_step_batch(jsonb);
drop function if exists taskfold_private.edit_child_structure(jsonb);
drop function if exists taskfold_private.finish_child_adoption(jsonb,jsonb);
drop function if exists taskfold_private.finish_child_copy_choice(jsonb,jsonb);
drop function if exists taskfold_private.forget_child_structure_undo(uuid);
drop function if exists taskfold_private.format_child_copy_for_mapping(jsonb,jsonb);
drop function if exists taskfold_private.guard_child_adoption_nonce();
drop function if exists taskfold_private.guard_child_completion_identity();
drop function if exists taskfold_private.guard_child_completion_terminal();
drop function if exists taskfold_private.guard_child_field_close_identity();
drop function if exists taskfold_private.guard_child_field_receipt_identity();
drop function if exists taskfold_private.guard_child_field_team_identity();
drop function if exists taskfold_private.guard_child_record_project_transfer();
drop function if exists taskfold_private.guard_child_record_scope();
drop function if exists taskfold_private.guard_child_repair_nonce();
drop function if exists taskfold_private.guard_child_restore_file();
drop function if exists taskfold_private.guard_child_restore_nonce();
drop function if exists taskfold_private.guard_child_restore_object();
drop function if exists taskfold_private.guard_child_restore_original_budget();
drop function if exists taskfold_private.guard_child_step_identity();
drop function if exists taskfold_private.guard_child_structure_identity();
drop function if exists taskfold_private.guard_child_transfer_nonce();
drop function if exists taskfold_private.guard_completion_selection_roots(jsonb);
drop function if exists taskfold_private.guard_frozen_subtasks();
drop function if exists taskfold_private.guard_mixed_completion_children(jsonb);
drop function if exists taskfold_private.guard_restored_child_content();
drop function if exists taskfold_private.guard_restored_child_realm();
drop function if exists taskfold_private.materialize_child_task_records(uuid,text);
drop function if exists taskfold_private.mixed_completion(jsonb,boolean);
drop function if exists taskfold_private.mixed_completion_legacy_identity(uuid,uuid);
drop function if exists taskfold_private.mixed_completion_successor_children(jsonb,uuid,uuid,uuid,uuid);
drop function if exists taskfold_private.node_activity_nodes(tasks);
drop function if exists taskfold_private.pin_child_adoption(uuid,jsonb);
drop function if exists taskfold_private.plan_child_copy_mapping(tasks,jsonb,jsonb,jsonb,text,text[],uuid[]);
drop function if exists taskfold_private.plan_child_repair(jsonb,jsonb);
drop function if exists taskfold_private.plan_child_repair_before_history_choice(jsonb,jsonb);
drop function if exists taskfold_private.prepare_child_copy_mapping(tasks,jsonb,jsonb,jsonb,text,text[],uuid[]);
drop function if exists taskfold_private.prepare_child_record_tree(uuid,uuid,jsonb);
drop function if exists taskfold_private.preview_child_copy_choice(jsonb);
drop function if exists taskfold_private.preview_child_copy_choice_before_mapping(jsonb);
drop function if exists taskfold_private.preview_child_repair(jsonb);
drop function if exists taskfold_private.preview_child_repair_before_copy_choice(jsonb);
drop function if exists taskfold_private.preview_child_repair_before_history_choice(jsonb);
drop function if exists taskfold_private.promote_child_task_records(uuid,uuid,uuid,bigint,jsonb);
drop function if exists taskfold_private.purge_child_structure_archives();
drop function if exists taskfold_private.purge_team_child_restore_payloads();
drop function if exists taskfold_private.purge_team_repair_originals();
drop function if exists taskfold_private.read_child_task_records(uuid,uuid);
drop function if exists taskfold_private.read_child_task_structure(uuid,uuid);
drop function if exists taskfold_private.read_completion_selection_roots(jsonb);
drop function if exists taskfold_private.refresh_child_task_records();
drop function if exists taskfold_private.repair_child_copies(jsonb);
drop function if exists taskfold_private.require_child_adoption_custodian(tasks,uuid);
drop function if exists taskfold_private.require_complete_child_adoption();
drop function if exists taskfold_private.require_unused_child_completion_items(jsonb,uuid);
drop function if exists taskfold_private.retained_child_adoption(jsonb);
drop function if exists taskfold_private.review_child_adoption(uuid,uuid);
drop function if exists taskfold_private.review_child_copies(jsonb);
drop function if exists taskfold_private.review_child_restore(text,uuid,uuid,uuid);
drop function if exists taskfold_private.review_restored_child_copies(jsonb,uuid,uuid);
drop function if exists taskfold_private.stage_prepared_child_records(jsonb);
drop function if exists taskfold_private.sync_child_task_records(uuid,uuid,jsonb);
drop function if exists taskfold_private.sync_child_task_records_legacy(uuid,uuid,jsonb);
drop function if exists taskfold_private.tag_child_transfer_history();
drop function if exists taskfold_private.taskfold_preview_child_repair_before_copy_choice(jsonb);
drop function if exists taskfold_private.taskfold_repair_children_before_copy_choice(text,jsonb);
drop function if exists taskfold_private.taskfold_repair_children_before_restored_adoption(text,jsonb);
drop function if exists taskfold_private.team_completion_children(jsonb,uuid,uuid);
drop function if exists taskfold_private.transfer_child(text,jsonb);
drop function if exists taskfold_private.undo_mixed_completion(jsonb,boolean);
drop function if exists taskfold_private.validate_child_completion_batch(jsonb,uuid);
drop function if exists taskfold_private.validate_child_completion_request(jsonb,uuid);
drop function if exists taskfold_private.validate_child_restore_files(jsonb);
drop function if exists taskfold_private.validate_child_step_request(jsonb,uuid);
drop function if exists taskfold_private.validate_child_structure_request(jsonb,uuid);
drop function if exists taskfold_private.validate_mixed_completion(jsonb,uuid);
drop function if exists taskfold_read_child_structure(uuid,uuid);
drop function if exists taskfold_read_child_tasks(uuid,uuid);
drop function if exists taskfold_read_completion_selection_roots(jsonb);
drop function if exists taskfold_repair_children(text,jsonb);
drop function if exists taskfold_restore_child_original(text,jsonb);
drop function if exists taskfold_review_child_adoption(uuid,uuid);
drop function if exists taskfold_review_child_copies(jsonb);
drop function if exists taskfold_review_child_restore(text,uuid,uuid,uuid);
drop function if exists taskfold_review_restored_child_copies(jsonb,uuid,uuid);
drop function if exists taskfold_search_child_adoption_targets(text,uuid,integer);
drop function if exists taskfold_transfer_child(text,jsonb);
drop function if exists taskfold_undo_mixed_completion(jsonb);
-- 6. Legacy tables (taskfold_private.child_*). The JSON archive and the deterministic-id function stay.
drop table if exists taskfold_private.child_adoption_archive_files, taskfold_private.child_mapping_scope, taskfold_private.child_repair_restorations, taskfold_private.child_repair_restore_files, taskfold_private.child_repair_restore_payloads, taskfold_private.child_repair_restore_requests, taskfold_private.child_repair_restore_scope, taskfold_private.child_rows_cutover, taskfold_private.child_task_adoptions, taskfold_private.child_task_completion_batches, taskfold_private.child_task_completion_closures, taskfold_private.child_task_completion_receipts, taskfold_private.child_task_edit_closures, taskfold_private.child_task_edit_preparations, taskfold_private.child_task_edit_receipts, taskfold_private.child_task_projections, taskfold_private.child_task_record_authority, taskfold_private.child_task_record_config, taskfold_private.child_task_records, taskfold_private.child_task_repair_originals, taskfold_private.child_task_repairs, taskfold_private.child_task_step_closures, taskfold_private.child_task_step_receipts, taskfold_private.child_task_structure_archives, taskfold_private.child_task_structure_closures, taskfold_private.child_task_structure_receipts, taskfold_private.child_task_transfers, taskfold_private.child_transfer_history_scope;

-- 7. The column. Its default goes with it; the realtime publication has no column list.
alter table public.tasks drop column if exists subtasks;

-- 8. Assertions.
do $migration$ begin
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure), 'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1') = 0 then
  raise exception using errcode = '55000', message = 'taskfold_patch_task has lost the scoped assignment guard';
 end if;
 if exists (select 1 from pg_catalog.pg_proc p where p.pronamespace in ('public'::regnamespace, 'taskfold_private'::regnamespace)
            and p.prosrc ~* '(^|[^a-z0-9_''>])[a-z_][a-z0-9_]*\.subtasks\M') then
  raise exception using errcode = '55000', message = 'A function still reads the subtasks column';
 end if;
 if exists (select 1 from pg_catalog.pg_class where relnamespace = 'taskfold_private'::regnamespace and relname like 'child\_%') then
  raise exception using errcode = '55000', message = 'A legacy child table survived';
 end if;
end
$migration$;

notify pgrst, 'reload schema';

commit;
