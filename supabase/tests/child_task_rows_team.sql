-- Child task rows, phase T (20261117100000_child_task_rows_team.sql): team-project subtasks as rows.
-- Run as postgres against the full Taskfold schema after the migration (local `supabase db reset`, then
-- `psql -v ON_ERROR_STOP=1 -f supabase/tests/child_task_rows_team.sql`). One rolled-back transaction;
-- reserved UUID prefix c41d0c0d-; example.invalid identities only.
-- Cast: O owns team T (manager), E is a member (editor on team-visible projects), V is a member with a viewer grant
-- on TP1, X is an outsider. TP1 and TP2 are team projects, P is O's personal project.
-- Sections that need the JSON `subtasks` column (the deferred-root conversion, the personal freeze) run only before
-- Migration C; everything else holds before and after C.
select exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.tasks'::regclass and attname = 'subtasks' and not attisdropped) as has_json_subtasks \gset
begin;

create function public.zz_u(n integer) returns uuid language sql immutable as
$$ select ('c41d0c0d-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid $$;
create function public.zz_s(n integer) returns uuid language sql immutable as
$$ select ('c41d0c0d-0000-4000-9000-' || lpad(to_hex(n), 12, '0'))::uuid $$;

insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
 (public.zz_u(1),'taskfold-team-rows-owner@example.invalid',now(),'{}'),
 (public.zz_u(2),'taskfold-team-rows-editor@example.invalid',now(),'{}'),
 (public.zz_u(3),'taskfold-team-rows-viewer@example.invalid',now(),'{}'),
 (public.zz_u(4),'taskfold-team-rows-outsider@example.invalid',now(),'{}');
insert into auth.sessions(id,user_id) select public.zz_s(n), public.zz_u(n) from generate_series(1,4) n;

update taskfold_private.team_config set enabled=true where singleton;
update taskfold_private.team_project_config set native_reads_enabled=true, native_task_edits_enabled=true where singleton;
insert into taskfold_private.teams(id,owner_id,name) values (public.zz_u(130),public.zz_u(1),'Synthetic team');
insert into taskfold_private.team_members(team_id,user_id,role) values
 (public.zz_u(130),public.zz_u(1),'admin'),(public.zz_u(130),public.zz_u(2),'member'),(public.zz_u(130),public.zz_u(3),'member');
insert into public.projects(id,user_id,name) values
 (public.zz_u(101),public.zz_u(1),'TP1'),(public.zz_u(102),public.zz_u(1),'TP2'),(public.zz_u(103),public.zz_u(1),'P personal');
insert into taskfold_private.team_content_projects(project_id,team_id) values (public.zz_u(101),public.zz_u(130)),(public.zz_u(102),public.zz_u(130));
insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values (public.zz_u(101),public.zz_u(130),public.zz_u(3),'viewer');
insert into public.sections(id,user_id,project_id,name) values
 (public.zz_u(111),public.zz_u(1),public.zz_u(101),'TP1 A'),(public.zz_u(112),public.zz_u(1),public.zz_u(101),'TP1 B');

-- Runs `sql` as person n (authenticated, with a session) and returns its jsonb result.
create function public.zz_as(n integer, sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
 perform set_config('request.jwt.claims', jsonb_build_object('sub',public.zz_u(n),'role','authenticated','session_id',public.zz_s(n))::text, true);
 perform set_config('request.jwt.claim.sub', public.zz_u(n)::text, true);
 begin
  set local role authenticated;
  execute sql into v;
  reset role;
 exception when others then
  reset role;
  perform set_config('request.jwt.claims','',true); perform set_config('request.jwt.claim.sub','',true);
  raise;
 end;
 perform set_config('request.jwt.claims','',true); perform set_config('request.jwt.claim.sub','',true);
 return v;
end $$;
grant execute on function public.zz_as(integer,text), public.zz_u(integer), public.zz_s(integer) to authenticated;

create function public.zz_expect(n integer, sql text, expected_state text, fragment text default '') returns void language plpgsql as $$
begin
 begin perform public.zz_as(n, sql);
 exception when others then
  if sqlstate <> expected_state or position(fragment in sqlerrm) = 0 then
   raise exception 'Wrong failure for [%]: % %', sql, sqlstate, sqlerrm; end if;
  return;
 end;
 raise exception 'Expected % for [%]', expected_state, sql;
end $$;

create function public.zz_check(ok boolean, label text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'Check failed: %', label; end if; end $$;

-- The lifecycle keys of a live task (the record a client sends to delete it).
create function public.zz_record(task uuid) returns jsonb language sql as $$
 select to_jsonb(t) - array['waiting_on'] - case when t.is_heading is null then 'is_heading' else '' end from public.tasks t where t.id = task $$;

create function public.zz_life(n integer, action text, rec jsonb, extra jsonb default '{}') returns text language sql as $$
 select format('select public.taskfold_team_task_lifecycle(%L,%L::jsonb)', action, (jsonb_build_object(
  'team_id',public.zz_u(130),'project_id',rec->'project_id','task_id',rec->'id','request_id',gen_random_uuid(),
  'task_generation',rec->'task_generation','record',rec) || extra)::text) $$;

create function public.zz_new(n integer, id uuid, project uuid, title text, extra jsonb default '{}') returns jsonb language sql as $$
 select public.zz_as(n, public.zz_life(n, 'create', jsonb_build_object('id',id,'user_id',public.zz_u(n),'title',title,'project_id',project,
  'task_generation',gen_random_uuid()) || extra)) $$;

create function public.zz_edit(n integer, task uuid, changes jsonb) returns text language sql as $$
 select format('select public.taskfold_edit_team_task(%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
  'project_id',(select t.project_id from public.tasks t where t.id=task),'task_id',task,'request_id',gen_random_uuid(),
  'task_generation',(select t.task_generation from public.tasks t where t.id=task),
  'base',public.zz_record(task),'changes',changes)::text) $$;

-- 1. Create: root, child and grandchild through the team lifecycle; parent_id and child_order are enforced.
select public.zz_new(2, public.zz_u(200), public.zz_u(101), 'Root');
select public.zz_new(2, public.zz_u(201), public.zz_u(101), 'Child one', jsonb_build_object('parent_id',public.zz_u(200)));
select public.zz_new(2, public.zz_u(202), public.zz_u(101), 'Child two', jsonb_build_object('parent_id',public.zz_u(200)));
select public.zz_new(1, public.zz_u(203), public.zz_u(101), 'Grandchild', jsonb_build_object('parent_id',public.zz_u(201),'child_order',5));
select public.zz_check((select array_agg(child_order order by id) from public.tasks where id in (public.zz_u(201),public.zz_u(202),public.zz_u(203)))
 = array[1,2,5]::float8[], 'child_order defaults to max+1 and keeps an explicit value');
select public.zz_check((select count(*) from taskfold_private.team_content_tasks c where c.task_id in (public.zz_u(201),public.zz_u(202),public.zz_u(203))) = 3,
 'team custody recorded for each child');
select public.zz_check(jsonb_array_length(public.zz_as(2, public.zz_life(2,'create',jsonb_build_object('id',public.zz_u(204),'user_id',public.zz_u(2),
 'title','Child three','project_id',public.zz_u(101),'task_generation',gen_random_uuid(),'parent_id',public.zz_u(200))))->'children') = 0,
 'create reply carries the (empty) children of the new task');

-- Viewer, outsider: no child rows; no direct writes for anyone.
select public.zz_expect(3, public.zz_life(3,'create',jsonb_build_object('id',public.zz_u(210),'user_id',public.zz_u(3),'title','V','project_id',public.zz_u(101),
 'task_generation',gen_random_uuid(),'parent_id',public.zz_u(200))), '42501');
select public.zz_expect(4, public.zz_life(4,'create',jsonb_build_object('id',public.zz_u(211),'user_id',public.zz_u(4),'title','X','project_id',public.zz_u(101),
 'task_generation',gen_random_uuid(),'parent_id',public.zz_u(200))), '42501');
select public.zz_expect(2, format('insert into public.tasks(id,user_id,title,project_id,parent_id) values (%L,%L,''direct'',%L,%L) returning to_jsonb(id)',
 public.zz_u(212),public.zz_u(2),public.zz_u(101),public.zz_u(200)), 'PT503');
select public.zz_check(public.zz_as(2, format('with u as (update public.tasks set parent_id=%L where id=%L returning 1) select to_jsonb(count(*)) from u',
 public.zz_u(201),public.zz_u(202))) = '0'::jsonb, 'a direct re-parent of a team task changes nothing');
select public.zz_check(public.zz_as(2, format('with d as (delete from public.tasks where id=%L returning 1) select to_jsonb(count(*)) from d',
 public.zz_u(203))) = '0'::jsonb, 'a direct delete of a team child changes nothing');
select public.zz_check(public.zz_as(3, format('select to_jsonb(count(*)) from public.tasks where parent_id=%L', public.zz_u(200))) = '3'::jsonb,
 'the viewer reads the child rows');
select public.zz_check(public.zz_as(4, format('select to_jsonb(count(*)) from public.tasks where parent_id=%L', public.zz_u(200))) = '0'::jsonb,
 'the outsider reads nothing');
-- Cross-project parent, and a parent the caller cannot read.
select public.zz_expect(2, public.zz_life(2,'create',jsonb_build_object('id',public.zz_u(213),'user_id',public.zz_u(2),'title','Elsewhere','project_id',public.zz_u(102),
 'task_generation',gen_random_uuid(),'parent_id',public.zz_u(200))), '23514', 'same project');
insert into public.tasks(id,user_id,title,project_id) values (public.zz_u(300),public.zz_u(1),'Personal',public.zz_u(103));
select public.zz_expect(2, public.zz_life(2,'create',jsonb_build_object('id',public.zz_u(214),'user_id',public.zz_u(2),'title','Probe','project_id',public.zz_u(101),
 'task_generation',gen_random_uuid(),'parent_id',public.zz_u(300))), '23503');

-- 2. Edits: re-order, re-parent, depth and cycles via the saved-edit RPC; viewers cannot.
select public.zz_as(2, public.zz_edit(2, public.zz_u(202), jsonb_build_object('child_order',0.5)));
select public.zz_check((select child_order from public.tasks where id=public.zz_u(202)) = 0.5, 'child_order edit');
select public.zz_as(2, public.zz_edit(2, public.zz_u(203), jsonb_build_object('parent_id',public.zz_u(202))));
select public.zz_check((select parent_id from public.tasks where id=public.zz_u(203)) = public.zz_u(202), 're-parent edit');
select public.zz_expect(3, public.zz_edit(3, public.zz_u(203), jsonb_build_object('parent_id',public.zz_u(201))), '42501');
select public.zz_expect(2, public.zz_edit(2, public.zz_u(200), jsonb_build_object('parent_id',public.zz_u(203))), '23514', 'own subtask');
do $$ declare i integer; begin
 perform public.zz_new(2, public.zz_u(400), public.zz_u(101), 'Level 1');
 for i in 2..10 loop perform public.zz_new(2, public.zz_u(399+i), public.zz_u(101), 'Level '||i, jsonb_build_object('parent_id',public.zz_u(398+i))); end loop;
end $$;
-- A root plus ten levels of subtasks is the limit (guard_task_parent counts at most 10 ancestors).
select public.zz_new(2, public.zz_u(420), public.zz_u(101), 'Level 11', jsonb_build_object('parent_id',public.zz_u(409)));
select public.zz_expect(2, public.zz_life(2,'create',jsonb_build_object('id',public.zz_u(421),'user_id',public.zz_u(2),'title','Level 12','project_id',public.zz_u(101),
 'task_generation',gen_random_uuid(),'parent_id',public.zz_u(420))), '54000');
-- A concurrent re-parent conflict is reported, not merged.
select public.zz_expect(2, format('select public.taskfold_edit_team_task(%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),'project_id',public.zz_u(101),
 'task_id',public.zz_u(203),'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=public.zz_u(203)),
 'base',public.zz_record(public.zz_u(203))||jsonb_build_object('parent_id',public.zz_u(200)),'changes',jsonb_build_object('parent_id',public.zz_u(201)))::text),
 'PT409', 'different parent');

-- 3. Section move of a parent cascades to its subtasks under team guards.
select public.zz_as(2, public.zz_edit(2, public.zz_u(200), jsonb_build_object('section_id',public.zz_u(112))));
select public.zz_check((select bool_and(section_id = public.zz_u(112)) from public.tasks where id in (public.zz_u(200),public.zz_u(201),public.zz_u(202),public.zz_u(203))),
 'section move cascades to every subtask');
select public.zz_check(not exists (select 1 from taskfold_private.team_task_edit_scope), 'edit scopes cleared');

-- 4. Project move of a parent takes the subtasks along (reviewed and scoped); Undo brings them back.
insert into public.task_comments(id,task_id,author_id,body,project_id,task_generation)
select public.zz_u(500), public.zz_u(203), public.zz_u(2), 'On a grandchild', public.zz_u(101), task_generation from public.tasks where id=public.zz_u(203);
create temp table zz_move(review jsonb, moved jsonb);
insert into zz_move(review) select public.zz_as(2, format('select public.taskfold_team_task_move(''review'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(200),'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),
 'source_project_id',public.zz_u(101),'destination_project_id',public.zz_u(102))::text));
select public.zz_check((select (review->>'child_row_count')::integer from zz_move) = 4, 'move review counts the subtasks');
-- A subtask edited after the review invalidates it.
select public.zz_as(2, public.zz_edit(2, public.zz_u(201), jsonb_build_object('title','Child one, edited')));
select public.zz_expect(2, format('select public.taskfold_team_task_move(''move'',%L::jsonb)', (select jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(200),'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),'source_project_id',public.zz_u(101),
 'destination_project_id',public.zz_u(102),'request_id',gen_random_uuid(),'expires_at',review->'expires_at','review_token',review->'review_token') from zz_move)::text),
 'PT409', 'after review');
update zz_move set review = public.zz_as(2, format('select public.taskfold_team_task_move(''review'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(200),'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),
 'source_project_id',public.zz_u(101),'destination_project_id',public.zz_u(102))::text));
update zz_move set moved = public.zz_as(2, format('select public.taskfold_team_task_move(''move'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(200),'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),'source_project_id',public.zz_u(101),
 'destination_project_id',public.zz_u(102),'request_id',gen_random_uuid(),'expires_at',review->'expires_at','review_token',review->'review_token')::text));
select public.zz_check((select bool_and(project_id = public.zz_u(102) and section_id is null) from public.tasks
 where id in (public.zz_u(200),public.zz_u(201),public.zz_u(202),public.zz_u(203))), 'project move cascades to every subtask');
select public.zz_check((select bool_and(project_id = public.zz_u(102)) from taskfold_private.team_content_tasks
 where task_id in (public.zz_u(201),public.zz_u(202),public.zz_u(203))), 'custody follows the subtasks');
select public.zz_check((select project_id = public.zz_u(102) and revision = 2 from public.task_comments where id=public.zz_u(500)), 'a subtask discussion follows');
select public.zz_check(not exists (select 1 from taskfold_private.team_task_move_scope), 'move scopes cleared');
-- Viewer has no access to TP2's sibling project TP1 rights; outsider cannot review at all.
select public.zz_expect(4, format('select public.taskfold_team_task_move(''review'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(200),'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),
 'source_project_id',public.zz_u(102),'destination_project_id',public.zz_u(101))::text), '42501');
update zz_move set review = public.zz_as(2, format('select public.taskfold_team_task_move(''review_undo'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(200),'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),
 'source_project_id',public.zz_u(102),'destination_project_id',public.zz_u(101),'undoes',moved->'request_id')::text));
select public.zz_as(2, format('select public.taskfold_team_task_move(''undo'',%L::jsonb)', (select jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(200),'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),'source_project_id',public.zz_u(102),
 'destination_project_id',public.zz_u(101),'undoes',moved->'request_id','request_id',gen_random_uuid(),'expires_at',review->'expires_at',
 'review_token',review->'review_token') from zz_move)::text));
select public.zz_check((select bool_and(project_id = public.zz_u(101) and section_id = public.zz_u(112)) from public.tasks
 where id in (public.zz_u(200),public.zz_u(201),public.zz_u(202),public.zz_u(203))), 'move Undo brings the subtasks back');
-- Moving a subtask alone to another project makes it a top-level task there.
update zz_move set review = public.zz_as(2, format('select public.taskfold_team_task_move(''review'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(409),'task_generation',(select task_generation from public.tasks where id=public.zz_u(409)),
 'source_project_id',public.zz_u(101),'destination_project_id',public.zz_u(102))::text));
select public.zz_as(2, format('select public.taskfold_team_task_move(''move'',%L::jsonb)', (select jsonb_build_object('team_id',public.zz_u(130),
 'task_id',public.zz_u(409),'task_generation',(select task_generation from public.tasks where id=public.zz_u(409)),'source_project_id',public.zz_u(101),
 'destination_project_id',public.zz_u(102),'request_id',gen_random_uuid(),'expires_at',review->'expires_at','review_token',review->'review_token') from zz_move)::text));
select public.zz_check((select project_id = public.zz_u(102) and parent_id is null and child_order is null from public.tasks where id=public.zz_u(409)),
 'a moved subtask is detached');

-- 5. Delete: the parent takes its subtasks along, each certified and restorable parent-first.
select public.zz_expect(3, public.zz_life(3,'delete',public.zz_record(public.zz_u(200))), '42501');
select public.zz_expect(4, public.zz_life(4,'delete',public.zz_record(public.zz_u(200))), '42501');
create temp table zz_del(body jsonb, reply jsonb);
insert into zz_del(body) select jsonb_build_object('team_id',public.zz_u(130),'project_id',public.zz_u(101),'task_id',public.zz_u(200),'request_id',gen_random_uuid(),
 'task_generation',(select task_generation from public.tasks where id=public.zz_u(200)),'record',public.zz_record(public.zz_u(200)));
update zz_del set reply = public.zz_as(2, format('select public.taskfold_team_task_lifecycle(''delete'',%L::jsonb)', body::text));
select public.zz_check(not exists (select 1 from public.tasks where id in (public.zz_u(200),public.zz_u(201),public.zz_u(202),public.zz_u(203),public.zz_u(204))),
 'the parent and every subtask are deleted');
select public.zz_check((select jsonb_array_length(reply->'deleted_children') from zz_del) = 4, 'reply lists the deleted subtasks');
select public.zz_check((select bool_and(e.restoration_hash is not null and e.operation='delete' and e.actor_id=public.zz_u(2)) from zz_del z
 cross join lateral jsonb_array_elements(z.reply->'deleted_children') c join taskfold_private.team_task_edits e
 on e.team_id=public.zz_u(130) and e.request_id=(c->>'request_id')::uuid), 'each subtask deletion is certified');
select public.zz_check((select (reply->'deleted_children'->0->>'parent_id')::uuid = public.zz_u(200) from zz_del), 'deleted subtasks are listed parents first');
select public.zz_check(exists (select 1 from taskfold_private.team_conversation_archive a join zz_del z on true
 where a.request_id = md5('taskfold.team-child-delete.v1|' || (z.body->>'request_id') || '|' || public.zz_u(203)::text)::uuid), 'a subtask discussion is archived');
select public.zz_check((select public.zz_as(2, format('select public.taskfold_team_task_lifecycle(''delete'',%L::jsonb)', body::text))->'deleted_children' = reply->'deleted_children'
 from zz_del), 'a replayed delete returns the same subtasks');
-- Restore: the parent first, then each subtask with its own request, parents first.
select public.zz_as(2, format('select public.taskfold_team_task_lifecycle(''restore'',%L::jsonb)', (select jsonb_build_object('team_id',public.zz_u(130),
 'project_id',public.zz_u(101),'task_id',public.zz_u(200),'request_id',gen_random_uuid(),'task_generation','c41d0c0d-0000-4000-a000-000000000200','restore_from',body->'request_id',
 'record',(body->'record')||'{"task_generation":"c41d0c0d-0000-4000-a000-000000000200"}'::jsonb) from zz_del)::text));
do $$ declare c jsonb; g uuid; begin
 for c in select value from zz_del, jsonb_array_elements(reply->'deleted_children') loop
  g := gen_random_uuid();
  perform public.zz_as(2, format('select public.taskfold_team_task_lifecycle(''restore'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),
   'project_id',public.zz_u(101),'task_id',c->'task_id','request_id',gen_random_uuid(),'task_generation',g,'restore_from',c->'request_id',
   'record',((c->'task')-array['waiting_on','is_heading'])||jsonb_build_object('task_generation',g))::text));
 end loop;
end $$;
select public.zz_check((select count(*) from public.tasks where id in (public.zz_u(200),public.zz_u(201),public.zz_u(202),public.zz_u(203),public.zz_u(204))) = 5
 and (select parent_id from public.tasks where id=public.zz_u(203)) = public.zz_u(202), 'parent and subtasks restored with their structure');
select public.zz_check(exists (select 1 from public.task_comments where task_id=public.zz_u(203) and body='On a grandchild' and project_id=public.zz_u(101)), 'the subtask discussion is restored');
-- Defence in depth: a path that certifies only the parent (no per-child scopes) is refused by guard_team_parent_delete.
select set_config('request.jwt.claim.sub', public.zz_u(1)::text, true);
select public.zz_check(exists (select 1 from public.tasks where parent_id=public.zz_u(200)), 'precondition');
do $$ begin
 insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation)
 select txid_current(), public.zz_u(130), project_id, id, task_generation, public.zz_u(1), 'delete' from public.tasks where id=public.zz_u(200);
 begin delete from public.tasks where id=public.zz_u(200); raise exception 'deleted';
 exception when sqlstate 'PT409' then null; end;
 delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current();
 begin delete from public.tasks where id=public.zz_u(201); raise exception 'deleted';
 exception when sqlstate 'PT503' then null; end;
end $$;
select set_config('request.jwt.claim.sub', '', true);

-- 6. Batch delete with a parent and its subtask in one selection: subtasks first, both restorable together.
select public.zz_new(2, public.zz_u(600), public.zz_u(101), 'Batch root');
select public.zz_new(2, public.zz_u(601), public.zz_u(101), 'Batch child', jsonb_build_object('parent_id',public.zz_u(600)));
select public.zz_as(2, format('select public.taskfold_team_task_batch(''delete'',%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),'request_id',gen_random_uuid(),
 'items',jsonb_build_array(
  jsonb_build_object('team_id',public.zz_u(130),'project_id',public.zz_u(101),'task_id',public.zz_u(600),'request_id',gen_random_uuid(),
   'task_generation',(select task_generation from public.tasks where id=public.zz_u(600)),'record',public.zz_record(public.zz_u(600))),
  jsonb_build_object('team_id',public.zz_u(130),'project_id',public.zz_u(101),'task_id',public.zz_u(601),'request_id',gen_random_uuid(),
   'task_generation',(select task_generation from public.tasks where id=public.zz_u(601)),'record',public.zz_record(public.zz_u(601)))))::text));
select public.zz_check(not exists (select 1 from public.tasks where id in (public.zz_u(600),public.zz_u(601))), 'batch delete of parent and subtask');
select public.zz_check((select count(*) from taskfold_private.team_task_edits where task_id in (public.zz_u(600),public.zz_u(601)) and restoration_hash is not null) = 2,
 'both batch members restorable');

-- 7. Producers: a JSON tree sent to the lifecycle (old clients, workflow runs, templates) becomes rows; never stored.
select public.zz_new(2, public.zz_u(700), public.zz_u(101), 'From a template', jsonb_build_object('subtasks',
 '[{"id":"a","title":"Step A","subtasks":[{"id":"a1","title":"Step A1"}]},{"id":"b","title":"Step B"}]'::jsonb));
select public.zz_check((select coalesce(to_jsonb(t)->'subtasks','[]'::jsonb) = '[]'::jsonb from public.tasks t where t.id=public.zz_u(700)), 'the JSON tree is not stored');
select public.zz_check((select array_agg(id order by child_order, id) from public.tasks where parent_id=public.zz_u(700))
 = array[taskfold_private.legacy_child_id(public.zz_u(700)::text, array['a']), taskfold_private.legacy_child_id(public.zz_u(700)::text, array['b'])]
 and exists (select 1 from public.tasks where id=taskfold_private.legacy_child_id(public.zz_u(700)::text, array['a','a1'])
             and parent_id=taskfold_private.legacy_child_id(public.zz_u(700)::text, array['a'])), 'tree rows use the legacy ids');
select public.zz_check((select bool_and(project_id=public.zz_u(101) and user_id=public.zz_u(2)) from public.tasks t
 where t.id in (select d.id from taskfold_private.task_descendants(public.zz_u(700)) d)), 'emitted rows belong to the project and the actor');
-- Recurring completion: the next occurrence gets open copies of the subtasks; Undo removes them while untouched.
select public.zz_new(2, public.zz_u(800), public.zz_u(101), 'Weekly', jsonb_build_object('is_recurring',true,'due_date','2026-11-20',
 'recurrence_pattern','{"type":"daily","interval":1}'::jsonb));
select public.zz_new(2, public.zz_u(801), public.zz_u(101), 'Weekly step', jsonb_build_object('parent_id',public.zz_u(800),'due_date','2026-11-20'));
create temp table zz_done(body jsonb, reply jsonb);
insert into zz_done(body) select jsonb_build_object('team_id',public.zz_u(130),'project_id',public.zz_u(101),'task_id',public.zz_u(800),
 'task_generation',t.task_generation,'request_id',gen_random_uuid(),'record',to_jsonb(t),'completed_at','2026-11-20T12:00:00Z','input_zone','Europe/Copenhagen',
 'next_generation',gen_random_uuid(),'planned_next_id',taskfold_private.automation_recurrence_plan(to_jsonb(t),'2026-11-20T12:00:00Z','Europe/Copenhagen')->>'id',
 'series_id',t.id,'series_generation',t.task_generation,'series_project_id',t.project_id) from public.tasks t where t.id=public.zz_u(800);
update zz_done set reply = public.zz_as(2, format('select public.taskfold_complete_team_task(''complete'',%L::jsonb)', body::text));
select public.zz_check((select count(*) = 1 and bool_and(not t.completed and t.due_date = '2026-11-21') from public.tasks t
 where t.parent_id = (select (body->>'planned_next_id')::uuid from zz_done)), 'the next occurrence has an open, shifted copy of the subtask');
select public.zz_as(2, format('select public.taskfold_complete_team_task(''undo'',%L::jsonb)', (select body || jsonb_build_object('request_id',gen_random_uuid(),
 'undoes',body->'request_id') from zz_done)::text));
select public.zz_check(not exists (select 1 from public.tasks where id = (select (body->>'planned_next_id')::uuid from zz_done))
 and not exists (select 1 from public.tasks where parent_id = (select (body->>'planned_next_id')::uuid from zz_done)), 'Undo removes the untouched occurrence and its subtasks');

-- 8. Conversion of a deferred team root with Migration B's function and ids (before Migration C only).
\if :has_json_subtasks
-- Legacy data predates today's assignment rules: insert it the way old trees were stored, without guard_task.
alter table public.tasks disable trigger taskfold_guard_task;
insert into public.tasks(id,user_id,title,project_id,subtasks) values
 (public.zz_u(900),public.zz_u(1),'Deferred',public.zz_u(101),'[{"id":"x","title":"Kept","assigned_to":"c41d0c0d-0000-4000-8000-000000000002"},{"id":"y","title":"Unassigned","assigned_to":"c41d0c0d-0000-4000-8000-000000000004"}]');
alter table public.tasks enable trigger taskfold_guard_task;
insert into taskfold_private.json_subtask_conversions(root_id,original,status,skipped,root_user_id,root_project_id)
 select id, subtasks, 'deferred', '{"reason":"team, phase T"}', user_id, project_id from public.tasks where id=public.zz_u(900);
delete from taskfold_private.json_subtask_conversions j where j.status='deferred'
 and exists (select 1 from public.tasks x where x.id=j.root_id and coalesce(x.subtasks,'null'::jsonb) not in ('null'::jsonb,'[]'::jsonb));
select public.zz_check((taskfold_private.convert_json_subtasks()->>'roots')::integer = 1, 'the deferred team root converts');
select public.zz_check((select status='converted' and cardinality(child_ids)=2 and jsonb_array_length(skipped->'assignees_dropped')=1
 from taskfold_private.json_subtask_conversions where root_id=public.zz_u(900)), 'archived as converted; a non-editor assignee is dropped');
select public.zz_check((select assigned_to from public.tasks where id=taskfold_private.legacy_child_id(public.zz_u(900)::text, array['x'])) = public.zz_u(2)
 and (select subtasks from public.tasks where id=public.zz_u(900)) = '[]'::jsonb, 'team rows keep editor assignees, root cleared');
select public.zz_check(exists (select 1 from taskfold_private.team_content_tasks where task_id=taskfold_private.legacy_child_id(public.zz_u(900)::text, array['y'])),
 'converted team rows are team content');
select public.zz_check((taskfold_private.convert_json_subtasks()->>'roots')::integer = 0, 'conversion is idempotent');
\endif

-- 9. The freeze is universal: team edits and team creates may not store a tree.
-- An older team client sends its tree with a `subtasks` baseline.
select public.zz_expect(2, format('select public.taskfold_edit_team_task(%L::jsonb)', jsonb_build_object('team_id',public.zz_u(130),'project_id',public.zz_u(101),
 'task_id',public.zz_u(700),'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=public.zz_u(700)),
 'base',public.zz_record(public.zz_u(700))||'{"subtasks":[]}'::jsonb,'changes',jsonb_build_object('subtasks','[{"id":"z","title":"JSON"}]'::jsonb))::text),
 'PT409', 'Subtasks are now tasks');
\if :has_json_subtasks
select public.zz_expect(1, format('update public.tasks set subtasks=''[{"title":"x"}]'' where id=%L returning to_jsonb(id)', public.zz_u(300)), 'PT409', 'Subtasks are now tasks');
\endif
select public.zz_check(not exists (select 1 from pg_catalog.pg_proc where proname='guard_frozen_subtasks' and prosrc ~ 'team'), 'no team exemption in the freeze');

-- 10. Team deletion: the team-wide operation scope removes parents with subtasks.
select set_config('request.jwt.claim.sub', public.zz_u(1)::text, true);
select set_config('request.jwt.claims', jsonb_build_object('sub',public.zz_u(1),'role','authenticated')::text, true);
update taskfold_private.teams set state='deleted', owner_id=null, name=null where id=public.zz_u(130);
select set_config('request.jwt.claims','',true); select set_config('request.jwt.claim.sub','',true);
select public.zz_check(not exists (select 1 from public.tasks where project_id in (public.zz_u(101),public.zz_u(102))), 'team deletion removes the team subtasks');

-- 11. Migration T is idempotent and keeps the scoped-assignment guard.
select public.zz_check(strpos(pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure), 'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1') > 0, 'scoped assignment marker');
select public.zz_check((select count(*) from pg_proc where prosrc like '%TASKFOLD_TEAM_CHILD_ROWS_V1%') >= 7, 'every T patch is in place');

do $$ begin raise notice 'child_task_rows_team: ok'; end $$;
rollback;
