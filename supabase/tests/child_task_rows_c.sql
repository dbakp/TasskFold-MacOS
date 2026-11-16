-- Child task rows, Migration C (20261117110000_child_task_rows_c.sql): the legacy JSON subtask storage is gone.
-- Run as postgres against the full Taskfold schema after the migration (local `supabase db reset`, then
-- `psql -v ON_ERROR_STOP=1 -f supabase/tests/child_task_rows_c.sql`). One rolled-back transaction; skips itself on a
-- schema before Migration C. Reserved UUID prefix c41d0c0e-; example.invalid identities only.
select exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.tasks'::regclass and attname = 'subtasks' and not attisdropped) as before_child_rows_c \gset
\if :before_child_rows_c
\echo 'child_task_rows_c: skipped (Migration C is not applied)'
\q
\endif
begin;

create function public.zz_u(n integer) returns uuid language sql immutable as
$$ select ('c41d0c0e-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid $$;
create function public.zz_check(ok boolean, label text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'Check failed: %', label; end if; end $$;
create function public.zz_expect(sql text, expected_state text, fragment text default '') returns void language plpgsql as $$
begin
 begin execute sql;
 exception when others then
  if sqlstate <> expected_state or position(fragment in sqlerrm) = 0 then raise exception 'Wrong failure for [%]: % %', sql, sqlstate, sqlerrm; end if;
  return;
 end;
 raise exception 'Expected % for [%]', expected_state, sql;
end $$;
create function public.zz_base(n integer) returns jsonb language sql stable as $$ select to_jsonb(t) from public.tasks t where id=public.zz_u(n) $$;
grant execute on function public.zz_u(integer), public.zz_check(boolean,text), public.zz_expect(text,text,text), public.zz_base(integer) to authenticated;

-- 1. Schema: no `subtasks`, no legacy child system; the archive and the deterministic ids stay.
select public.zz_check(not exists (select 1 from pg_attribute where attrelid='public.tasks'::regclass and attname='subtasks' and not attisdropped), 'subtasks column dropped');
select public.zz_check(not exists (select 1 from pg_class where relnamespace='taskfold_private'::regnamespace and relname like 'child\_%'), 'child_* tables dropped');
select public.zz_check(not exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname in
 ('taskfold_read_child_tasks','taskfold_edit_child_task','taskfold_complete_child_task','taskfold_edit_child_structure','taskfold_transfer_child',
  'taskfold_adopt_child_records','taskfold_complete_mixed_tasks','taskfold_repair_children','taskfold_child_steps','taskfold_restore_child_original')), 'legacy child RPCs dropped');
select public.zz_check(not exists (select 1 from pg_proc where pronamespace='taskfold_private'::regnamespace and proname in
 ('materialize_child_task_records','sync_child_task_records','refresh_child_task_records','read_child_task_records','prepare_child_record_tree',
  'guard_frozen_subtasks','convert_json_subtasks','capture_task_node_activity','child_copy_update_admitted','child_rows_b_patch')), 'materialize/projection/freeze functions dropped');
select public.zz_check(not exists (select 1 from pg_trigger t where not tgisinternal and (t.tgname in ('aaa_taskfold_subtasks_frozen','taskfold_refresh_child_task_records',
 'taskfold_child_record_scope','taskfold_capture_node_activity') or t.tgname like 'child\_%')), 'legacy triggers dropped');
select public.zz_check(not exists (select 1 from pg_proc p where p.pronamespace in ('public'::regnamespace,'taskfold_private'::regnamespace)
 and p.prosrc ~* '(^|[^a-z0-9_''>])[a-z_][a-z0-9_]*\.subtasks\M'), 'no function reads the subtasks column');
select public.zz_check(not exists (select 1 from pg_policy where pg_get_expr(polqual,polrelid) ~ 'child_copy' or pg_get_expr(polwithcheck,polrelid) ~ 'child_copy'), 'policies cleaned');
select public.zz_check(to_regclass('taskfold_private.json_subtask_conversions') is not null and to_regprocedure('taskfold_private.legacy_child_id(text,text[])') is not null
 and to_regclass('taskfold_private.team_task_child_deletions') is not null, 'archive, legacy ids and team deletions kept');
select public.zz_check(strpos(pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure), 'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1') > 0
 and strpos(pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure), 'TASKFOLD_CHILD_PARENT_CONFLICT_V1') > 0, 'scoped assignment marker and parent rule kept');
select public.zz_check(not exists (select 1 from pg_trigger where tgname='taskfold_guard_task_file_reference' and pg_get_triggerdef(oid) ~ 'subtasks'), 'file reference trigger no longer watches subtasks');

-- 2. Rows CRUD through the patch and delete RPCs, as a signed-in owner.
insert into auth.users(id,email) values (public.zz_u(1),'taskfold-c-owner@example.invalid'),(public.zz_u(2),'taskfold-c-outsider@example.invalid');
insert into public.projects(id,user_id,name) values (public.zz_u(100),public.zz_u(1),'P'),(public.zz_u(101),public.zz_u(1),'Q');
select set_config('request.jwt.claim.sub', public.zz_u(1)::text, true);
select set_config('request.jwt.claims', jsonb_build_object('sub',public.zz_u(1),'role','authenticated')::text, true);
set local role authenticated;
insert into public.tasks(id,user_id,title,project_id) values (public.zz_u(10),public.zz_u(1),'Root',public.zz_u(100));
insert into public.tasks(id,user_id,title,project_id,parent_id) values (public.zz_u(11),public.zz_u(1),'Child',public.zz_u(100),public.zz_u(10));
insert into public.tasks(id,user_id,title,project_id,parent_id) values (public.zz_u(12),public.zz_u(1),'Grandchild',public.zz_u(100),public.zz_u(11));
insert into public.tasks(id,user_id,title,project_id) values (public.zz_u(13),public.zz_u(1),'Other root',public.zz_u(100));
select public.zz_check((select child_order from public.tasks where id=public.zz_u(11)) = 1, 'insert defaults child_order');
select public.taskfold_patch_task(public.zz_u(12), public.zz_base(12), jsonb_build_object('parent_id',public.zz_u(13),'child_order',4));
select public.zz_check((select parent_id = public.zz_u(13) and child_order = 4 from public.tasks where id=public.zz_u(12)), 'patch re-parents and re-orders');
select public.taskfold_patch_task(public.zz_u(11), public.zz_base(11), jsonb_build_object('title','Child, renamed','completed',true));
select public.zz_check((select title = 'Child, renamed' and completed from public.tasks where id=public.zz_u(11)), 'patch edits a child row');
select public.zz_expect(format('select public.taskfold_patch_task(%L, %L::jsonb, %L::jsonb)', public.zz_u(10), public.zz_base(10)::text,
 jsonb_build_object('parent_id',public.zz_u(11))::text), '23514');
-- Old builds: an empty `subtasks` in a PATCH is tolerated, a tree is refused with the update hint.
select public.taskfold_patch_task(public.zz_u(13), public.zz_base(13)||'{"subtasks":[]}', '{"subtasks":[],"title":"Old build edit"}');
select public.zz_check((select title from public.tasks where id=public.zz_u(13)) = 'Old build edit', 'old-build PATCH with an empty tree');
select public.zz_expect(format('select public.taskfold_patch_task(%L, %L::jsonb, %L::jsonb)', public.zz_u(13), (public.zz_base(13)||'{"subtasks":[]}')::text,
 '{"subtasks":[{"title":"x"}]}'), 'PT409', 'Subtasks are now tasks');
-- A project move takes the subtasks along.
select public.taskfold_patch_task(public.zz_u(10), public.zz_base(10), jsonb_build_object('project_id',public.zz_u(101),'section_id',null));
select public.zz_check((select project_id from public.tasks where id=public.zz_u(11)) = public.zz_u(101), 'project move cascades');
-- Delete: deepest first with full baselines, then the parent.
select public.zz_check(public.taskfold_delete_task(public.zz_u(12), public.zz_base(12)), 'delete a child row');
select public.zz_check(public.taskfold_delete_task(public.zz_u(11), public.zz_base(11)), 'delete a child row');
select public.zz_check(public.taskfold_delete_task(public.zz_u(10), public.zz_base(10)), 'delete the parent');
select public.zz_check(not exists (select 1 from public.tasks where id in (public.zz_u(10),public.zz_u(11),public.zz_u(12))), 'all deleted');
-- Old-client DELETE baselines that still carry an empty `subtasks` keep working.
select public.zz_check(public.taskfold_delete_task(public.zz_u(13), public.zz_base(13)||'{"subtasks":[]}'), 'old-build DELETE baseline');
-- The outsider cannot touch someone else's rows.
insert into public.tasks(id,user_id,title,project_id) values (public.zz_u(20),public.zz_u(1),'Owner task',public.zz_u(100));
select set_config('request.jwt.claim.sub', public.zz_u(2)::text, true);
select set_config('request.jwt.claims', jsonb_build_object('sub',public.zz_u(2),'role','authenticated')::text, true);
select public.zz_check((select count(*) from public.tasks where id=public.zz_u(20)) = 0, 'outsider reads nothing');
select public.zz_expect(format('insert into public.tasks(id,user_id,title,project_id,parent_id) values (%L,%L,''probe'',null,%L)', public.zz_u(21), public.zz_u(2), public.zz_u(20)), '23503');
reset role;
select set_config('request.jwt.claims','',true); select set_config('request.jwt.claim.sub','',true);

do $$ begin raise notice 'child_task_rows_c: ok'; end $$;
rollback;
