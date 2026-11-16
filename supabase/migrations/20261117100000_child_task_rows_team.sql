-- Migration T for child task rows (design-review/child-tasks-plan.md, phase T): team-project subtasks become real
-- child rows (`tasks.parent_id`/`child_order`), like personal and shared ones since Migration B.
--  1. The team write path (closed to direct writes by guard_closed_team_content) accepts and enforces parent_id and
--     child_order: lifecycle create/restore/delete, saved edits (re-parenting, re-ordering, section moves), task moves,
--     batch delete/restore and completion. Structure rules stay in taskfold_private.guard_task_parent (same project,
--     at most 10 levels, no cycles); every RPC keeps the role checks it already had for the parent.
--  2. Team JSON trees deferred by Migration B (status 'deferred', reason 'team, phase T') are converted with B's own
--     conversion function (same deterministic ids, same archive).
--  3. Team producers emit rows: lifecycle create/restore (and so team workflow runs and team template runs, which
--     create through it), saved-draft copies and recurring completions. A JSON tree sent by an older client is
--     converted into rows on the server; it is never stored.
--  4. The subtasks freeze is universal: no request may write a non-empty `subtasks` anywhere.
-- Client contract: docs/TEAM_CHILD_ROWS.md. Idempotent: every patch is marked and skipped once applied.
--
-- SECURITY DECISION (cascades inside team projects). guard_closed_team_content is NOT relaxed and there is no
-- pg_trigger_depth() exception. A nested-trigger exception ("allow a delete when the parent is gone") would admit
-- every FK cascade, including ones started by a path that never checked the caller's role on the children, and would
-- skip each child's custody (files, recordings, discussion archive, Undo record). Instead the RPCs handle children
-- explicitly and admit each child write with the same per-task, per-transaction scopes they already use for the parent:
--  * delete: team_task_lifecycle('delete') deletes descendants deepest first, each with its own team_task_edits record
--    (restoration hash, discussion archive, file/recording custody, detached repeat links) under a 'delete' scope, and
--    returns them so the client can restore them parent-first with the ordinary 'restore' action.
--  * section move (saved edit): a 'patch' scope per descendant lets the AFTER cascade of Migration A move them.
--  * project move (team_task_move): a move scope per descendant, bound to the exact before/after row hash, admits the
--    cascade; discussions, files and recordings follow under the same scopes, and the review token covers them.
-- Descendants always share the parent's project (guard_task_parent), so the caller's role on the parent's project is
-- exactly their role on every descendant: nobody can reach a task through a child they could not reach directly.
-- guard_team_parent_delete (Migration A) still refuses any other delete of a team parent with children, except inside
-- a team-wide operation scope (team deletion), where guard_closed_team_content already admits every team task.
-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

set local lock_timeout = '10s';

-- 0. Shared helpers. Private: no grants.
create or replace function taskfold_private.task_descendants(root uuid) returns table(id uuid, parent_id uuid, depth integer)
language sql stable set search_path = '' as $$
 with recursive d(id, parent_id, depth) as (
  select t.id, t.parent_id, 1 from public.tasks t where t.parent_id = root
  union all
  select t.id, t.parent_id, d.depth + 1 from public.tasks t join d on t.parent_id = d.id where d.depth < 64)
 select d.id, d.parent_id, d.depth from d
$$;

-- A digest of every descendant row; NULL for a task without subtasks (so leaf-only hashes are unchanged).
create or replace function taskfold_private.team_descendant_digest(root uuid) returns text
language sql stable set search_path = '' as $$
 select case when pg_catalog.count(*) = 0 then null else pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
  pg_catalog.jsonb_agg(pg_catalog.to_jsonb(t) order by t.id)::text, 'UTF8'), 'sha256'), 'hex') end
 from public.tasks t where t.id in (select d.id from taskfold_private.task_descendants(root) d)
$$;

create or replace function taskfold_private.team_descendant_audio_inventory(root uuid) returns jsonb
language sql set search_path = '' as $$
 select coalesce(pg_catalog.jsonb_agg(e.value), '[]'::jsonb)
 from public.tasks t cross join lateral pg_catalog.jsonb_array_elements(taskfold_private.team_task_audio_inventory(t)) e(value)
 where t.id in (select d.id from taskfold_private.task_descendants(root) d)
$$;

create or replace function taskfold_private.team_descendant_file_inventory(root uuid) returns jsonb
language sql set search_path = '' as $$
 select coalesce(pg_catalog.jsonb_agg(e.value), '[]'::jsonb)
 from public.tasks t cross join lateral pg_catalog.jsonb_array_elements(taskfold_private.team_task_file_inventory(t)) e(value)
 where t.id in (select d.id from taskfold_private.task_descendants(root) d)
$$;

-- What a cascaded team delete removed, for replies (including replays) and parent-first Undo.
create table if not exists taskfold_private.team_task_child_deletions (
 team_id uuid not null,
 request_id uuid not null,
 child_request_id uuid not null,
 task_id uuid not null,
 generation uuid not null,
 parent_id uuid,
 depth integer not null,
 task jsonb not null,
 primary key (team_id, child_request_id),
 foreign key (team_id, child_request_id) references taskfold_private.team_task_edits(team_id, request_id) on delete cascade
);
create index if not exists team_task_child_deletions_request on taskfold_private.team_task_child_deletions(team_id, request_id);
alter table taskfold_private.team_task_child_deletions enable row level security;
revoke all on taskfold_private.team_task_child_deletions from public, anon, authenticated, service_role;

-- 1. Server-side producers: a JSON tree (an older client, a workflow template document, a pre-T deleted task being
-- restored) becomes rows under `root`, with LegacySubtaskConversion ids (legacy_child_id(root, path)) and generations
-- derived from the root's generation. Each insert is admitted by its own 'create' scope; fresh content only
-- (no history, files or discussion); assignees who are not current project editors are dropped.
create or replace function taskfold_private.team_emit_child_rows(team uuid, p uuid, root public.tasks, tree jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare a uuid := auth.uid(); plan jsonb; item jsonb; r jsonb; rec public.tasks; ids uuid[] := '{}'; path text[]; dropped integer := 0;
begin
 if pg_catalog.jsonb_typeof(tree) is distinct from 'array' or tree = '[]'::jsonb then
  return pg_catalog.jsonb_build_object('rows', '[]'::jsonb, 'skipped', '[]'::jsonb);
 end if;
 plan := taskfold_private.legacy_child_plan(pg_catalog.to_jsonb(root), tree);
 for item in select value from pg_catalog.jsonb_array_elements(plan -> 'rows') loop
  r := item -> 'row';
  select coalesce(pg_catalog.array_agg(x.v order by x.o), '{}') into path from pg_catalog.jsonb_array_elements_text(item -> 'path') with ordinality x(v, o);
  if (r ->> 'parent_id')::uuid <> root.id and not (r ->> 'parent_id')::uuid = any(ids) then dropped := dropped + 1; continue; end if;
  r := r || pg_catalog.jsonb_build_object('user_id', root.user_id, 'project_id', root.project_id, 'section_id', root.section_id,
        'task_generation', taskfold_private.legacy_child_id(root.task_generation::text, path || 'generation'::text),
        'comments', '[]'::jsonb, 'attachments', '[]'::jsonb, 'source_metadata', '{}'::jsonb, 'notification_sent_at', null,
        'completion_version', 0, 'recurrence_parent_id', null);
  if r -> 'completed' = 'true'::jsonb then
   r := r || pg_catalog.jsonb_build_object('completed_at', coalesce(r -> 'completed_at', pg_catalog.to_jsonb(pg_catalog.clock_timestamp())));
  else
   r := r || '{"completed_at":null}'::jsonb;
  end if;
  if coalesce(r ->> 'assigned_to', '') <> '' and coalesce(taskfold_private.team_project_role((r ->> 'assigned_to')::uuid, p), '') not in ('manager', 'editor') then
   r := r || '{"assigned_to":null}'::jsonb;
  end if;
  rec := pg_catalog.jsonb_populate_record(null::public.tasks, r);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(rec.id::text, 78137));
  if exists (select 1 from public.tasks x where x.id = rec.id) or exists (select 1 from taskfold_private.task_generations g where g.task_id = rec.id)
     or exists (select 1 from taskfold_private.team_content_tasks c where c.task_id = rec.id) then
   raise exception using errcode = 'PT409', message = 'TASKFOLD_CONFLICT: A subtask identity is already used';
  end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id, team_id, project_id, task_id, generation, actor_id, operation)
  values (pg_catalog.txid_current(), team, p, rec.id, rec.task_generation, a, 'create');
  insert into public.tasks select rec.*;
  delete from taskfold_private.team_task_edit_scope s where s.transaction_id = pg_catalog.txid_current() and s.task_id = rec.id;
  ids := ids || rec.id;
 end loop;
 return pg_catalog.jsonb_build_object('rows', pg_catalog.to_jsonb(ids), 'skipped', plan -> 'skipped', 'dropped', dropped);
end $$;

-- 2. Cascade delete, RPC side: descendants deepest first, each a full certified team deletion (see the header).
-- A descendant with published recordings while recording restoration is on needs its own reviewed deletion first
-- (record_audio_task_deletion refuses without that task's acknowledgement), so nothing is deleted unreviewed.
create or replace function taskfold_private.team_delete_child_rows(team uuid, p uuid, root uuid, q uuid) returns integer
language plpgsql set search_path = '' as $$
declare a uuid := auth.uid(); d record; r public.tasks; o public.tasks; dq uuid; h text; pg uuid; fp text; n integer := 0;
begin
 for d in select x.id, x.depth from taskfold_private.task_descendants(root) x order by x.depth desc, x.id loop
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(d.id::text, 78137));
  select * into r from public.tasks t where t.id = d.id for update;
  if not found then continue; end if;
  if r.project_id is distinct from p or not exists (select 1 from taskfold_private.team_content_tasks c
     where c.task_id = r.id and c.generation = r.task_generation and c.team_id = team and c.project_id = p) then
   raise exception using errcode = 'PT409', message = 'TASKFOLD_CONFLICT: Review the subtasks before deleting';
  end if;
  dq := pg_catalog.md5('taskfold.team-child-delete.v1|' || q::text || '|' || r.id::text)::uuid;
  pg := null;
  if r.recurrence_parent_id is not null then
   select t.task_generation into pg from public.tasks t where t.id = r.recurrence_parent_id for key share;
  end if;
  h := taskfold_private.team_task_restoration_hash(r);
  select pg_catalog.encode(extensions.hmac(pg_catalog.convert_to(pg_catalog.jsonb_build_array(a, 'team_child_delete_v1', q, r.id)::text, 'UTF8'), s.secret, 'sha256'), 'hex')
   into fp from taskfold_private.automation_revision_secret s where s.singleton;
  insert into taskfold_private.team_task_edits(team_id, request_id, actor_id, fingerprint, task_id, generation, operation, restoration_hash, parent_generation)
  values (team, dq, a, fp, r.id, r.task_generation, 'delete', h, pg);
  perform taskfold_private.archive_team_conversation(team, p, r.id, r.task_generation, dq);
  for o in select * from public.tasks t where t.recurrence_parent_id = r.id order by t.id for update loop
   if not exists (select 1 from taskfold_private.team_content_projects b where b.project_id = o.project_id and b.team_id = team) then
    raise exception using errcode = 'PT409', message = 'TASKFOLD_CONFLICT: Review linked work before deleting';
   end if;
   insert into taskfold_private.team_task_edit_scope(transaction_id, team_id, project_id, task_id, generation, actor_id, operation, related_id)
   values (pg_catalog.txid_current(), team, o.project_id, o.id, o.task_generation, a, 'detach', r.id);
   update public.tasks t set recurrence_parent_id = null where t.id = o.id returning * into o;
   delete from taskfold_private.team_task_edit_scope s where s.transaction_id = pg_catalog.txid_current() and s.task_id = o.id;
   insert into taskfold_private.team_task_deleted_links values (team, dq, o.id, o.task_generation, o.project_id, taskfold_private.automation_task_revision(o));
  end loop;
  insert into taskfold_private.team_task_edit_scope(transaction_id, team_id, project_id, task_id, generation, actor_id, operation)
  values (pg_catalog.txid_current(), team, p, r.id, r.task_generation, a, 'delete');
  perform taskfold_private.record_task_file_deletion(r, team, dq);
  perform taskfold_private.record_audio_task_deletion(r, team, dq, '{}'::jsonb);
  delete from public.tasks t where t.id = r.id;
  delete from taskfold_private.team_task_edit_scope s where s.transaction_id = pg_catalog.txid_current() and s.task_id = r.id;
  delete from taskfold_private.team_conversation_scope s where s.transaction_id = pg_catalog.txid_current() and s.request_id = dq;
  insert into taskfold_private.team_task_child_deletions(team_id, request_id, child_request_id, task_id, generation, parent_id, depth, task)
  values (team, q, dq, r.id, r.task_generation, r.parent_id, d.depth, pg_catalog.to_jsonb(r));
  n := n + 1;
 end loop;
 return n;
end $$;

-- Reply fragment of team_task_lifecycle: `deleted_children` (parents first, ready for 'restore') or the live `children`.
create or replace function taskfold_private.team_child_rows_reply(action text, team uuid, q uuid, root uuid, unavailable boolean) returns jsonb
language sql stable set search_path = '' as $$
 select case
  when action = 'delete' then pg_catalog.jsonb_build_object('deleted_children', coalesce((
   select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('request_id', c.child_request_id, 'task_id', c.task_id, 'task_generation', c.generation,
          'parent_id', c.parent_id, 'task', c.task) order by c.depth, c.task_id)
   from taskfold_private.team_task_child_deletions c where c.team_id = team and c.request_id = q), '[]'::jsonb))
  when not unavailable then pg_catalog.jsonb_build_object('children', coalesce((
   select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(t) order by d.depth, t.child_order, t.created_at, t.id)
   from taskfold_private.task_descendants(root) d join public.tasks t on t.id = d.id), '[]'::jsonb))
  else '{}'::jsonb end
$$;

-- 3. Cascade move, RPC side: a move scope per descendant bound to its exact before/after state (the AFTER cascade of
-- Migration A changes only project_id and section_id), then the descendants' discussions, files and recordings follow.
create or replace function taskfold_private.team_move_child_scopes(team uuid, root uuid, p uuid, dest uuid, section uuid) returns void
language plpgsql set search_path = '' as $$
declare a uuid := auth.uid(); x public.tasks;
begin
 for x in select t.* from public.tasks t where t.id in (select d.id from taskfold_private.task_descendants(root) d) order by t.id for update loop
  if x.project_id is distinct from p or not exists (select 1 from taskfold_private.team_content_tasks c
     where c.task_id = x.id and c.generation = x.task_generation and c.team_id = team and c.project_id = p) then
   raise exception using errcode = 'PT409', message = 'TASKFOLD_CONFLICT: Review the subtasks before moving';
  end if;
  insert into taskfold_private.team_task_move_scope values (pg_catalog.txid_current(), a, team, x.id, x.task_generation, p, dest,
   pg_catalog.encode(extensions.digest(pg_catalog.convert_to(pg_catalog.to_jsonb(x)::text, 'UTF8'), 'sha256'), 'hex'),
   pg_catalog.encode(extensions.digest(pg_catalog.convert_to(pg_catalog.to_jsonb(pg_catalog.jsonb_populate_record(x,
    pg_catalog.jsonb_build_object('project_id', dest, 'section_id', section)))::text, 'UTF8'), 'sha256'), 'hex'));
 end loop;
end $$;

create or replace function taskfold_private.team_move_child_custody(root uuid, dest uuid) returns void
language plpgsql set search_path = '' as $$
begin
 update public.task_comments c set project_id = dest, revision = c.revision + 1
  where c.task_id in (select d.id from taskfold_private.task_descendants(root) d);
 update taskfold_private.team_content_files f set project_id = dest
  where exists (select 1 from public.tasks t where t.id = f.task_id and t.task_generation = f.task_generation
                and t.id in (select d.id from taskfold_private.task_descendants(root) d));
 update taskfold_private.audio_comment_custody c set project_id = dest
  where exists (select 1 from public.tasks t where t.id = c.task_id and t.task_generation = c.task_generation
                and t.id in (select d.id from taskfold_private.task_descendants(root) d))
    and exists (select 1 from taskfold_private.audio_comment_publications r where r.operation_id = c.operation_id and r.state = 'published');
end $$;

-- 4. Recurring team parents: the next occurrence gets fresh open copies of the subtasks (dates shifted like the parent's).
-- Undo removes them with the occurrence only while none of them was touched since; otherwise the occurrence is kept,
-- like an occurrence with a discussion.
create or replace function taskfold_private.team_clone_successor_children(team uuid, p uuid, source public.tasks, successor public.tasks) returns integer
language plpgsql set search_path = '' as $$
declare a uuid := auth.uid(); d record; x public.tasks; rec public.tasks; delta integer := 0; n integer := 0;
begin
 if source.due_date is not null and successor.due_date is not null then delta := successor.due_date - source.due_date; end if;
 for d in select y.id, y.depth from taskfold_private.task_descendants(source.id) y order by y.depth, y.id loop
  select * into x from public.tasks t where t.id = d.id;
  if not found then continue; end if;
  rec := x;
  rec.id := pg_catalog.md5('taskfold.team-successor-child.v1|' || successor.id::text || '|' || x.id::text)::uuid;
  rec.task_generation := pg_catalog.md5('taskfold.team-successor-child-generation.v1|' || successor.task_generation::text || '|' || x.id::text)::uuid;
  rec.parent_id := case when x.parent_id = source.id then successor.id
                   else pg_catalog.md5('taskfold.team-successor-child.v1|' || successor.id::text || '|' || x.parent_id::text)::uuid end;
  rec.user_id := a; rec.project_id := successor.project_id; rec.section_id := successor.section_id;
  rec.completed := false; rec.completed_at := null; rec.completion_version := 0; rec.notification_sent_at := null;
  rec.comments := '[]'; rec.attachments := '[]'; rec.subtasks := '[]'; rec.recurrence_parent_id := null; rec.created_at := successor.created_at;
  rec.source_metadata := coalesce(x.source_metadata, '{}'::jsonb) - 'taskfold_recurrence_v1';
  rec.due_date := rec.due_date + delta; rec.deadline_date := rec.deadline_date + delta;
  rec.scheduled_at := rec.scheduled_at + pg_catalog.make_interval(days => delta);
  if rec.assigned_to is not null and coalesce(taskfold_private.team_project_role(rec.assigned_to, p), '') not in ('manager', 'editor') then rec.assigned_to := null; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(rec.id::text, 78137));
  if exists (select 1 from public.tasks t where t.id = rec.id) then continue; end if;
  if exists (select 1 from taskfold_private.task_generations g where g.task_id = rec.id and g.generation = rec.task_generation) then
   raise exception using errcode = 'PT409', message = 'TASKFOLD_CONFLICT: Use a fresh occurrence identity';
  end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id, team_id, project_id, task_id, generation, actor_id, operation)
  values (pg_catalog.txid_current(), team, p, rec.id, rec.task_generation, a, 'create');
  insert into public.tasks select rec.*;
  delete from taskfold_private.team_task_edit_scope s where s.transaction_id = pg_catalog.txid_current() and s.task_id = rec.id;
  n := n + 1;
 end loop;
 return n;
end $$;

create or replace function taskfold_private.team_successor_children_removable(root uuid) returns boolean
language sql stable set search_path = '' as $$
 select not exists (select 1 from taskfold_private.task_descendants(root) d join public.tasks t on t.id = d.id
  where t.completed or exists (select 1 from public.task_comments c where c.task_id = t.id)
     or exists (select 1 from public.tasks r where r.recurrence_parent_id = t.id)
     or exists (select 1 from taskfold_private.team_content_files f where f.task_id = t.id)
     or coalesce((select e.revision from taskfold_private.team_task_write_epochs e where e.task_id = t.id and e.generation = t.task_generation), 0) <> 0)
$$;

create or replace function taskfold_private.team_remove_successor_children(team uuid, p uuid, root uuid) returns void
language plpgsql set search_path = '' as $$
declare a uuid := auth.uid(); d record; x public.tasks;
begin
 for d in select y.id from taskfold_private.task_descendants(root) y order by y.depth desc, y.id loop
  select * into x from public.tasks t where t.id = d.id for update;
  if not found then continue; end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id, team_id, project_id, task_id, generation, actor_id, operation)
  values (pg_catalog.txid_current(), team, p, x.id, x.task_generation, a, 'delete');
  delete from public.tasks t where t.id = x.id;
  delete from taskfold_private.team_task_edit_scope s where s.transaction_id = pg_catalog.txid_current() and s.task_id = x.id;
 end loop;
end $$;

revoke all on function taskfold_private.task_descendants(uuid), taskfold_private.team_descendant_digest(uuid),
 taskfold_private.team_descendant_audio_inventory(uuid), taskfold_private.team_descendant_file_inventory(uuid),
 taskfold_private.team_emit_child_rows(uuid,uuid,public.tasks,jsonb), taskfold_private.team_delete_child_rows(uuid,uuid,uuid,uuid),
 taskfold_private.team_child_rows_reply(text,uuid,uuid,uuid,boolean), taskfold_private.team_move_child_scopes(uuid,uuid,uuid,uuid,uuid),
 taskfold_private.team_move_child_custody(uuid,uuid), taskfold_private.team_clone_successor_children(uuid,uuid,public.tasks,public.tasks),
 taskfold_private.team_successor_children_removable(uuid), taskfold_private.team_remove_successor_children(uuid,uuid,uuid)
 from public, anon, authenticated, service_role;

-- 5. Migration A's team delete guard: still refuses a team parent with children, except inside a team-wide operation
-- scope (team deletion), where guard_closed_team_content admits every task of the team and the FK cascade is expected.
create or replace function taskfold_private.guard_team_parent_delete() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is not null and old.project_id is not null and taskfold_private.is_team_content_project(old.project_id)
    and exists (select 1 from public.tasks c where c.parent_id=old.id)
    and not exists (select 1 from taskfold_private.team_content_operations o join taskfold_private.team_content_projects b on b.team_id=o.team_id
                    where o.transaction_id=pg_catalog.txid_current() and b.project_id=old.project_id) then
  raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Delete this team task with a supported Taskfold app so its subtasks are removed with it';
 end if;
 return old;
end $$;
revoke all on function taskfold_private.guard_team_parent_delete() from public,anon,authenticated,service_role;

-- 6. Batch delete/restore order: subtasks before their parent on delete, parents first on restore (like repeat links).
create or replace function taskfold_private.team_batch_order(items jsonb, operation text) returns uuid[]
language plpgsql immutable set search_path to '' as $$
declare ids uuid[];done uuid[]:='{}';item jsonb;id uuid;parent uuid;owner uuid;progress boolean;begin
 select array_agg((value->>'task_id')::uuid) into ids from jsonb_array_elements(items);
 while cardinality(done)<cardinality(ids) loop
  progress=false;
  for item in select value from jsonb_array_elements(items) order by value->>'task_id' loop
   id=(item->>'task_id')::uuid;if id=any(done) then continue;end if;
   parent=(item->'record'->>'recurrence_parent_id')::uuid;
   owner=(item->'record'->>'parent_id')::uuid; -- TASKFOLD_TEAM_CHILD_ROWS_V1
   if operation='restore' then
    if parent=any(ids) and not parent=any(done) then continue;end if;
    if owner=any(ids) and not owner=any(done) then continue;end if;
   elsif exists(select 1 from jsonb_array_elements(items) child where ((child->'record'->>'recurrence_parent_id')::uuid=id
     or (child->'record'->>'parent_id')::uuid=id) and not (child->>'task_id')::uuid=any(done)) then continue;
   end if;
   done=array_append(done,id);progress=true;
  end loop;
  if not progress then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the linked task structure';end if;
 end loop;
 return done;
end$$;

-- 7. RPC patches. Anchor-replace via Migration B's helper (each anchor exactly once, marker checked, skipped once applied).
-- 7a. Lifecycle: parent_id/child_order in the record; JSON trees become rows; cascade delete; children in the reply.
select taskfold_private.child_rows_b_patch('taskfold_private.team_task_lifecycle(text,jsonb)'::regprocedure, 'TASKFOLD_TEAM_CHILD_ROWS_V1',
 array[
  'declare a uuid:=auth.uid();team uuid;p uuid;id uuid;q uuid;generation uuid;restore_from uuid;parent_generation uuid;',
  '''task_generation'',''completion_version'',''is_heading''];',
  'insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation) values(txid_current(),team,p,id,generation,a,''delete'');',
  'insert into public.tasks select (desired).* returning * into row;',
  '''unavailable'',unavailable,''replayed'',replay)'],
 array[
  'declare child_tree jsonb:=''[]'';a uuid:=auth.uid();team uuid;p uuid;id uuid;q uuid;generation uuid;restore_from uuid;parent_generation uuid;',
  '''task_generation'',''completion_version'',''is_heading'',''parent_id'',''child_order'']; /* TASKFOLD_TEAM_CHILD_ROWS_V1 */',
  'perform taskfold_private.team_delete_child_rows(team,p,cmd.id,q);
   insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation) values(txid_current(),team,p,id,generation,a,''delete'');',
  'child_tree:=coalesce(desired.subtasks,''[]'');desired.subtasks:=''[]'';
  insert into public.tasks select (desired).* returning * into row;
  if child_tree<>''[]''::jsonb then perform taskfold_private.team_emit_child_rows(team,p,row,child_tree);end if;',
  '''unavailable'',unavailable,''replayed'',replay)||taskfold_private.team_child_rows_reply(action,team,q,id,unavailable)']);

-- 7b. Saved edits: re-parenting/re-ordering, and a section change moves the subtasks (one 'patch' scope each).
select taskfold_private.child_rows_b_patch('taskfold_private.team_task_edit(jsonb)'::regprocedure, 'TASKFOLD_TEAM_CHILD_ROWS_V1',
 array[
  '''recurrence_end_date'',''is_heading''];',
  'where e.k=any(array[''assigned_to'',''section_id'',''labels'',''reminder_specs''])),base);',
  'row=taskfold_private.team_task_merge(id,base,changes);'],
 array[
  '''recurrence_end_date'',''is_heading'',''parent_id'',''child_order'']; /* TASKFOLD_TEAM_CHILD_ROWS_V1 */',
  'where e.k=any(array[''assigned_to'',''section_id'',''labels'',''reminder_specs'',''parent_id'',''child_order''])),base);',
  'if changes ? ''section_id'' then
   insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,related_id)
   select txid_current(),team,p,x.id,x.task_generation,a,''patch'',cmd.id from public.tasks x
    where x.id in(select d.id from taskfold_private.task_descendants(cmd.id) d) and x.project_id=p;
  end if;
  row=taskfold_private.team_task_merge(id,base,changes);
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and related_id=cmd.id and operation=''patch'';']);

select taskfold_private.child_rows_b_patch('taskfold_private.team_task_merge(uuid,jsonb,jsonb)'::regprocedure, 'TASKFOLD_TEAM_CHILD_ROWS_V1',
 array[
  '''scheduled_at'',''is_heading''];',
  'merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(',
  'scheduled_at=t.scheduled_at where id=_id returning * into t;'],
 array[
  '''scheduled_at'',''is_heading'',''parent_id'',''child_order'']; /* TASKFOLD_TEAM_CHILD_ROWS_V1 */',
  'if k = ''parent_id'' and desired_value is distinct from base_value
      and remote_value is distinct from base_value and remote_value is distinct from desired_value then
     raise exception using errcode=''PT409'',message=''TASKFOLD_CONFLICT: This task was moved under a different parent on another device. Review the synced version'';
   end if;
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(',
  'scheduled_at=t.scheduled_at,parent_id=t.parent_id,child_order=t.child_order where id=_id returning * into t;']);

-- 7c. Project moves: a moved subtask leaves its parent; a moved parent takes its subtasks (reviewed, scoped, custody).
select taskfold_private.child_rows_b_patch('taskfold_private.team_task_move(text,jsonb)'::regprocedure, 'TASKFOLD_TEAM_CHILD_ROWS_V1',
 array[
  'stored_audio:=taskfold_private.team_task_audio_inventory(t);',
  'state_hash=taskfold_private.team_task_move_hash(t);',
  'desired=t;desired.project_id=dest;',
  '''subtask_undo_policy'',''kept_private'',',
  'update public.tasks set project_id=desired.project_id,section_id=desired.section_id,assigned_to=desired.assigned_to,subtasks=desired.subtasks where tasks.id=cmd.id;',
  'update public.task_comments set project_id=dest,revision=revision+1 where task_id=cmd.id;',
  'delete from taskfold_private.team_task_move_scope where transaction_id=txid_current() and task_id=cmd.id;',
  'taskfold_private.team_task_move_hash(t)) returning * into receipt;'],
 array[
  'stored_audio:=taskfold_private.team_task_audio_inventory(t)||taskfold_private.team_descendant_audio_inventory(t.id); /* TASKFOLD_TEAM_CHILD_ROWS_V1 */
 stored_files:=stored_files||taskfold_private.team_descendant_file_inventory(t.id);',
  'state_hash=taskfold_private.team_task_move_hash(t)||coalesce('':''||taskfold_private.team_descendant_digest(t.id),'''');',
  'desired=t;desired.project_id=dest;desired.parent_id=null;desired.child_order=null;',
  '''child_row_count'',(select count(*) from taskfold_private.task_descendants(t.id)),''subtask_undo_policy'',''kept_private'',',
  'perform taskfold_private.team_move_child_scopes(team,cmd.id,p,dest,desired.section_id);
 update public.tasks set project_id=desired.project_id,section_id=desired.section_id,assigned_to=desired.assigned_to,subtasks=desired.subtasks,parent_id=desired.parent_id,child_order=desired.child_order where tasks.id=cmd.id;',
  'update public.task_comments set project_id=dest,revision=revision+1 where task_id=cmd.id; perform taskfold_private.team_move_child_custody(cmd.id,dest);',
  'delete from taskfold_private.team_task_move_scope where transaction_id=txid_current() and (task_id=cmd.id or task_id in(select d.id from taskfold_private.task_descendants(cmd.id) d));',
  'taskfold_private.team_task_move_hash(t)||coalesce('':''||taskfold_private.team_descendant_digest(t.id),'''')) returning * into receipt;']);

-- 7d. Recurring completion: subtasks of the next occurrence are rows; Undo removes them only while untouched.
select taskfold_private.child_rows_b_patch('taskfold_private.team_complete_task(text,jsonb)'::regprocedure, 'TASKFOLD_TEAM_CHILD_ROWS_V1',
 array[
  'c.created=true;c.successor_hash=',
  'and not exists(select 1 from public.tasks where recurrence_parent_id=successor.id) then',
  'delete from public.tasks where tasks.id=successor.id;'],
 array[
  'perform taskfold_private.team_clone_successor_children(team,p,source,successor); /* TASKFOLD_TEAM_CHILD_ROWS_V1 */
    c.created=true;c.successor_hash=',
  'and not exists(select 1 from public.tasks where recurrence_parent_id=successor.id) and taskfold_private.team_successor_children_removable(successor.id) then',
  'perform taskfold_private.team_remove_successor_children(team,p,successor.id); delete from public.tasks where tasks.id=successor.id;']);

-- 7e. Saved-draft copies: a JSON tree in the draft becomes rows under the copy.
select taskfold_private.child_rows_b_patch('taskfold_private.copy_team_draft(jsonb,boolean,boolean)'::regprocedure, 'TASKFOLD_TEAM_CHILD_ROWS_V1',
 array[
  'declare a uuid:=auth.uid();team uuid;p uuid;q uuid;original_q uuid;',
  'insert into public.tasks select (desired).* returning * into current_task;'],
 array[
  'declare child_tree jsonb:=''[]'';a uuid:=auth.uid();team uuid;p uuid;q uuid;original_q uuid;',
  'child_tree:=coalesce(desired.subtasks,''[]'');desired.subtasks:=''[]''; /* TASKFOLD_TEAM_CHILD_ROWS_V1 */
   insert into public.tasks select (desired).* returning * into current_task;
   if child_tree<>''[]''::jsonb then perform taskfold_private.team_emit_child_rows(team,p,current_task,child_tree);end if;']);

-- 8. Convert the team trees Migration B deferred, with B's own function: no team deferral any more, and a team
-- assignee is kept only while they are a current project editor (the team rule, instead of check_task_assignment).
select taskfold_private.child_rows_b_patch('taskfold_private.convert_json_subtasks()'::regprocedure, 'TASKFOLD_TEAM_CHILD_ROWS_V1',
 array[
  'if (t.project_id is not null and taskfold_private.is_team_content_project(t.project_id)) or taskfold_private.is_team_content_task(t.id) then',
  'perform taskfold_private.check_task_assignment(r ->> ''assigned_to'', t.project_id, t.user_id);'],
 array[
  'if false then -- TASKFOLD_TEAM_CHILD_ROWS_V1: team trees convert too (phase T); nothing is deferred any more.',
  'if t.project_id is not null and taskfold_private.is_team_content_project(t.project_id) then
      if coalesce(taskfold_private.team_project_role((r ->> ''assigned_to'')::uuid, t.project_id), '''') not in (''manager'', ''editor'') then
       raise exception using errcode = ''42501'', message = ''Not a current project editor'';
      end if;
     else
      perform taskfold_private.check_task_assignment(r ->> ''assigned_to'', t.project_id, t.user_id);
     end if;']);

do $migration$
declare summary jsonb; remapped integer; requeued integer;
begin
 -- A deferred root that still holds a tree is converted now; its deferred record is replaced by the converted one.
 delete from taskfold_private.json_subtask_conversions j where j.status = 'deferred'
  and exists (select 1 from public.tasks x where x.id = j.root_id and coalesce(x.subtasks, 'null'::jsonb) not in ('null'::jsonb, '[]'::jsonb));
 get diagnostics requeued = row_count;
 summary := taskfold_private.convert_json_subtasks();
 remapped := taskfold_private.remap_subtask_view_orders();
 raise notice 'child_task_rows_team: % deferred roots requeued, % view orders remapped %', requeued, summary, remapped;
end
$migration$;

-- 9. The freeze is universal: no request writes a non-empty tree, team projects included. SQL operators without a
-- request role (migrations, operator scripts) stay trusted, as in Migration B.
create or replace function taskfold_private.guard_frozen_subtasks() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if coalesce(new.subtasks, 'null'::jsonb) in ('null'::jsonb, '[]'::jsonb) then return new; end if;
 if tg_op = 'UPDATE' and new.subtasks is not distinct from old.subtasks then return new; end if;
 if auth.uid() is null and coalesce(auth.role(), '') not in ('anon', 'authenticated', 'service_role') then return new; end if;
 raise exception using errcode = 'PT409', message = 'TASKFOLD_CONFLICT: Subtasks are now tasks. Update Taskfold to edit them.';
end $$;
revoke all on function taskfold_private.guard_frozen_subtasks() from public, anon, authenticated, service_role;

-- The scoped-assignment guard of taskfold_patch_task is untouched by this migration; assert it anyway.
do $migration$ begin
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure), 'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1') = 0 then
  raise exception using errcode = '55000', message = 'taskfold_patch_task has lost the scoped assignment guard';
 end if;
end $migration$;

notify pgrst, 'reload schema';

commit;
