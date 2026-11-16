-- Migration B for child task rows (design-review/child-tasks-plan.md): the cutover.
-- Converts every personal or shared JSON `tasks.subtasks` tree into real child rows (`parent_id`/`child_order`),
-- archives the original trees, freezes `subtasks` against user edits, retires the 12 November JSON child-record
-- system (config flags off, client RPCs revoked) and moves the server producers (Todoist import, automation API)
-- to child rows. Team-project trees stay JSON until phase T and are recorded as deferred.
-- Idempotent: a second run converts nothing and changes nothing. Back-out: Scripts/Database/child_rows_b_backout.sql.
-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Fail fast instead of queueing behind long client transactions; the operator retries.
set local lock_timeout = '10s';

-- 1. Archive and cutover state. Private: RLS on, no grants, no foreign keys (the archive must outlive a deleted root).
create table if not exists taskfold_private.json_subtask_conversions (
 root_id uuid primary key,
 original jsonb,
 child_ids uuid[] not null default '{}',
 skipped jsonb not null default '{}'::jsonb,
 converted_at timestamptz,
 status text not null default 'converted' check (status in ('converted','deferred')),
 root_user_id uuid,
 root_project_id uuid
);
alter table taskfold_private.json_subtask_conversions enable row level security;
revoke all on taskfold_private.json_subtask_conversions from public, anon, authenticated, service_role;

create table if not exists taskfold_private.json_subtask_view_order_remaps (
 user_id uuid not null,
 view_id text not null,
 original jsonb not null,
 remapped jsonb not null,
 remapped_at timestamptz not null default now(),
 primary key (user_id, view_id)
);
alter table taskfold_private.json_subtask_view_order_remaps enable row level security;
revoke all on taskfold_private.json_subtask_view_order_remaps from public, anon, authenticated, service_role;

-- What the back-out script restores: the JSON child-record config and the revoked client grants.
create table if not exists taskfold_private.child_rows_cutover (
 singleton boolean primary key default true check (singleton),
 config_before jsonb not null,
 revoked_functions text[] not null,
 cut_over_at timestamptz not null default now()
);
alter table taskfold_private.child_rows_cutover enable row level security;
revoke all on taskfold_private.child_rows_cutover from public, anon, authenticated, service_role;

-- 2. Deterministic identity, identical to Taskfold/Core/LegacySubtaskConversion.swift and
-- Scripts/legacy_subtasks_fixture.py (proven by supabase/tests/child_task_rows_b.sql with the shared fixture).
create or replace function taskfold_private.legacy_child_id(root text, path text[]) returns uuid
language sql immutable strict parallel safe set search_path = '' as $$
 select pg_catalog.md5('taskfold.child-row.v1|' || pg_catalog.lower(root) || '|' || pg_catalog.array_to_string(path, E'\x1f'))::uuid
$$;

-- The path segment of every node of one sibling array: the node's non-empty string `id`, else `@index`;
-- a key shared by several siblings becomes `@index` for each of them (SubtaskTree.childKey).
create or replace function taskfold_private.legacy_child_segments(siblings jsonb) returns text[]
language sql immutable parallel safe set search_path = '' as $$
 select coalesce(pg_catalog.array_agg(case when x.uses = 1 then x.k else '@' || (x.o - 1) end order by x.o), '{}')
 from (select k.o, k.k, pg_catalog.count(*) over (partition by k.k) as uses
       from (select e.o, case when pg_catalog.jsonb_typeof(e.v -> 'id') = 'string' and e.v ->> 'id' <> '' then e.v ->> 'id' else '@' || (e.o - 1) end as k
             from pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(siblings) = 'array' then siblings else '[]'::jsonb end) with ordinality e(v, o)) k) x
$$;

-- Nodes below a node (the `descendants` of a skipped node).
create or replace function taskfold_private.legacy_child_below(node jsonb) returns integer
language plpgsql immutable set search_path = '' as $$
declare total integer := 0; child jsonb;
begin
 if pg_catalog.jsonb_typeof(node) <> 'object' or pg_catalog.jsonb_typeof(node -> 'subtasks') is distinct from 'array' then return 0; end if;
 for child in select value from pg_catalog.jsonb_array_elements(node -> 'subtasks') loop
  total := total + 1 + taskfold_private.legacy_child_below(child);
 end loop;
 return total;
end $$;

-- True when a correctly typed legacy value also fits its column; a value that would make the row insert fail
-- is kept in source_metadata instead (a server-only safety rule; it never applies to readable data).
create or replace function taskfold_private.legacy_child_value_fits(k text, v jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare n numeric;
begin
 case k
 when 'completed_at', 'scheduled_at', 'created_at' then return pg_catalog.isfinite((v #>> '{}')::timestamptz);
 when 'due_date', 'deadline_date' then return pg_catalog.isfinite((v #>> '{}')::date);
 when 'due_time' then perform (v #>> '{}')::time; return true;
 when 'time_zone' then return pg_catalog.length(v #>> '{}') between 1 and 100;
 when 'priority', 'duration_minutes' then
  n := (v #>> '{}')::numeric;
  return n = pg_catalog.trunc(n) and ((k = 'priority' and n between 1 and 4) or (k = 'duration_minutes' and n between 1 and 10080));
 when 'labels' then return not exists (select 1 from pg_catalog.jsonb_array_elements(v) e where pg_catalog.jsonb_typeof(e) <> 'string');
 when 'reminder_specs' then return pg_catalog.jsonb_array_length(v) <= 20;
 else return true;
 end case;
exception when others then return false;
end $$;

-- One child row (as jsonb ready for jsonb_populate_record) from one legacy node.
create or replace function taskfold_private.legacy_child_row(root jsonb, node jsonb, child_id uuid, parent text, ord double precision, path text[])
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
 text_fields constant text[] := array['title','description','completed_at','due_date','due_time','time_zone','scheduled_at','deadline_date','created_at','assigned_to'];
 flag_fields constant text[] := array['completed','is_heading'];
 number_fields constant text[] := array['priority','duration_minutes'];
 list_fields constant text[] := array['labels','comments','attachments','reminder_specs'];
 r jsonb := '{}'::jsonb; extra jsonb := '{}'::jsonb; k text; v jsonb; typed boolean;
begin
 if pg_catalog.jsonb_typeof(node) = 'string' then
  r := pg_catalog.jsonb_build_object('title', node);
 else
  for k, v in select e.key, e.value from pg_catalog.jsonb_each(node) e order by e.key loop
   continue when v = 'null'::jsonb;
   if k = any(text_fields) or k = any(flag_fields) or k = any(number_fields) or k = any(list_fields) then
    typed := case when k = any(text_fields) then pg_catalog.jsonb_typeof(v) = 'string'
                  when k = any(flag_fields) then pg_catalog.jsonb_typeof(v) = 'boolean'
                  when k = any(number_fields) then pg_catalog.jsonb_typeof(v) = 'number'
                  else pg_catalog.jsonb_typeof(v) = 'array' end;
    if typed and taskfold_private.legacy_child_value_fits(k, v) then
     r := r || pg_catalog.jsonb_build_object(k, case when k = any(number_fields) then pg_catalog.to_jsonb((v #>> '{}')::numeric::integer) else v end);
    else
     extra := extra || pg_catalog.jsonb_build_object(k, v);
    end if;
   elsif k = 'subtasks' then
    if pg_catalog.jsonb_typeof(v) <> 'array' then extra := extra || pg_catalog.jsonb_build_object(k, v); end if;
   elsif k <> 'id' then
    extra := extra || pg_catalog.jsonb_build_object(k, v);
   end if;
  end loop;
 end if;
 -- Headings stay open (guard_task_headings): a completed legacy heading keeps its state in source_metadata.
 if r -> 'is_heading' = 'true'::jsonb and (r -> 'completed' = 'true'::jsonb or r ? 'completed_at') then
  extra := extra || pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object('completed', r -> 'completed', 'completed_at', r -> 'completed_at'));
  r := r - 'completed' - 'completed_at';
 end if;
 r := pg_catalog.jsonb_build_object('description', '', 'completed', false, 'priority', 4, 'labels', '[]'::jsonb,
       'comments', '[]'::jsonb, 'attachments', '[]'::jsonb, 'reminder_specs', '[]'::jsonb) || r;
 if not r ? 'created_at' then r := r || pg_catalog.jsonb_build_object('created_at', root -> 'created_at'); end if;
 return r || pg_catalog.jsonb_build_object(
  'id', child_id, 'parent_id', parent, 'child_order', ord,
  'user_id', root -> 'user_id', 'project_id', root -> 'project_id', 'section_id', root -> 'section_id',
  'is_recurring', false, 'reminders', '[]'::jsonb, 'subtasks', '[]'::jsonb, 'completion_version', 0,
  'task_generation', taskfold_private.legacy_child_id(root ->> 'id', path || 'generation'::text),
  'source_metadata', case when extra = '{}'::jsonb then '{}'::jsonb else pg_catalog.jsonb_build_object('taskfold_legacy_child', extra) end);
end $$;

create or replace function taskfold_private.legacy_child_skip(st jsonb, path text[], reason text, node jsonb) returns jsonb
language sql immutable set search_path = '' as $$
 select pg_catalog.jsonb_set(st, '{skipped}', (st -> 'skipped') || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
  'path', pg_catalog.to_jsonb(path), 'reason', reason, 'descendants', taskfold_private.legacy_child_below(node))))
$$;

-- The pre-order walk of LegacySubtaskConversion.convert. Stateful (used ids, the re-parent counter), so it is a
-- bounded recursive function rather than a recursive CTE: the walk stops at level 33.
create or replace function taskfold_private.legacy_child_walk(st jsonb, root jsonb, siblings jsonb, parent text, lvl integer, path text[], anchor text)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
 names text[] := taskfold_private.legacy_child_segments(siblings);
 node jsonb; here text[]; nid uuid; pid text; pos double precision; title text; i integer;
begin
 for i in 0 .. pg_catalog.jsonb_array_length(siblings) - 1 loop
  node := siblings -> i;
  here := path || names[i + 1];
  nid := taskfold_private.legacy_child_id(root ->> 'id', here);
  if lvl > 32 then st := taskfold_private.legacy_child_skip(st, here, 'depth_over_32', node); continue; end if;
  pid := parent; pos := i + 1;
  if lvl > 10 then
   pid := anchor;
   st := pg_catalog.jsonb_set(st, '{counter}', pg_catalog.to_jsonb((st ->> 'counter')::integer + 1));
   pos := 1000 + (st ->> 'counter')::integer;
  end if;
  if pg_catalog.jsonb_typeof(node) = 'string' then title := node #>> '{}';
  elsif pg_catalog.jsonb_typeof(node) = 'object' and pg_catalog.jsonb_typeof(node -> 'title') = 'string' then title := node ->> 'title';
  else
   st := taskfold_private.legacy_child_skip(st, here, case when pg_catalog.jsonb_typeof(node) = 'object' then 'missing_title' else 'not_an_object' end, node);
   continue;
  end if;
  if title ~ '^[ \t\n\r\f\v\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]*$' then
   st := taskfold_private.legacy_child_skip(st, here, 'empty_title', node); continue;
  end if;
  if st -> 'used' ? nid::text then st := taskfold_private.legacy_child_skip(st, here, 'id_collision', node); continue; end if;
  st := pg_catalog.jsonb_set(st, '{used}', (st -> 'used') || pg_catalog.jsonb_build_object(nid::text, true));
  st := pg_catalog.jsonb_set(st, '{rows}', (st -> 'rows') || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
         'row', taskfold_private.legacy_child_row(root, node, nid, pid, pos, here), 'path', pg_catalog.to_jsonb(here), 'level', lvl)));
  if lvl > 10 then
   st := pg_catalog.jsonb_set(st, '{reparented}', (st -> 'reparented') || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'id', nid, 'path', pg_catalog.to_jsonb(here), 'level', lvl, 'parent', pid)));
  end if;
  if pg_catalog.jsonb_typeof(node) = 'object' and pg_catalog.jsonb_typeof(node -> 'subtasks') = 'array' then
   -- Children of a node at level 10 or deeper hang from the level-9 anchor, never from a level-10 node.
   st := taskfold_private.legacy_child_walk(st, root, node -> 'subtasks', nid::text, lvl + 1, here, case when lvl = 10 then parent else anchor end);
  end if;
 end loop;
 return st;
end $$;

-- The whole conversion plan of one root, without touching any table:
-- {rows: [{row, path, level}] parents first, skipped: [{path, reason, descendants}], reparented: [{id, path, level, parent}]}.
-- `root` needs id, user_id, project_id, section_id and created_at. Assignees are copied as found; the caller checks them.
create or replace function taskfold_private.legacy_child_plan(root jsonb, tree jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare st jsonb := '{"rows":[],"skipped":[],"reparented":[],"counter":0}'::jsonb;
begin
 if coalesce(root ->> 'id', '') = '' or pg_catalog.jsonb_typeof(tree) is distinct from 'array' then return st - 'counter'; end if;
 st := st || pg_catalog.jsonb_build_object('used', pg_catalog.jsonb_build_object(pg_catalog.lower(root ->> 'id'), true));
 st := taskfold_private.legacy_child_walk(st, root, tree, root ->> 'id', 1, '{}'::text[], root ->> 'id');
 return st - 'used' - 'counter';
end $$;

-- A persisted `subtask:<base64 JSON [root, key, ...]>` reference to its row id (LegacySubtaskConversion.newID).
-- NULL when the reference is malformed. Callers check that the row was really converted.
create or replace function taskfold_private.legacy_reference_child_id(reference text) returns uuid
language plpgsql immutable set search_path = '' as $$
declare p jsonb;
begin
 if reference is null or pg_catalog.left(reference, 8) <> 'subtask:' then return null; end if;
 p := pg_catalog.convert_from(pg_catalog.decode(pg_catalog.substr(reference, 9), 'base64'), 'UTF8')::jsonb;
 if pg_catalog.jsonb_typeof(p) <> 'array' or pg_catalog.jsonb_array_length(p) not between 2 and 33
    or exists (select 1 from pg_catalog.jsonb_array_elements(p) e where pg_catalog.jsonb_typeof(e) <> 'string' or e #>> '{}' = '') then
  return null;
 end if;
 return taskfold_private.legacy_child_id(p ->> 0, array(select e.v from pg_catalog.jsonb_array_elements_text(p) with ordinality e(v, o) where e.o > 1 order by e.o));
exception when others then return null;
end $$;

-- 3. The conversion. Idempotent: archived roots are never read again, inserts are `on conflict do nothing`.
create or replace function taskfold_private.convert_json_subtasks() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
 quiet constant text[] := array['zz_taskfold_webhook_capture','taskfold_capture_node_activity','taskfold_capture_activity'];
 trig text; t public.tasks; a record; actual jsonb; plan jsonb; item jsonb; r jsonb; rec public.tasks; n integer;
 ids uuid[]; failed text[]; rejected jsonb; dropped jsonb; present jsonb;
 roots integer := 0; deferred integer := 0; inserted integer := 0; skipped_nodes integer := 0; reparented_nodes integer := 0; rejected_nodes integer := 0;
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('taskfold_task_tree', 0));
 foreach trig in array quiet loop
  if not exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.tasks'::regclass and tgname = trig and not tgisinternal and tgenabled = 'O') then
   raise exception using errcode = '55000', message = pg_catalog.format('Expected the enabled trigger %s on public.tasks; review the conversion before running it', trig);
  end if;
 end loop;

 -- Roots under JSON child-record authority must still materialize to exactly their tree before it is replaced.
 for a in select c.task_id, c.root_kind, x.subtasks from taskfold_private.child_task_record_authority c join public.tasks x on x.id = c.task_id
          where coalesce(x.subtasks, 'null'::jsonb) not in ('null'::jsonb, '[]'::jsonb)
            and not exists (select 1 from taskfold_private.json_subtask_conversions j where j.root_id = c.task_id) loop
  begin
   actual := taskfold_private.materialize_child_task_records(a.task_id, a.root_kind);
  exception when others then
   raise exception using errcode = '55000', message = pg_catalog.format('Child records of task %s no longer materialize (%s); review them before converting', a.task_id, sqlerrm);
  end;
  if actual is distinct from coalesce(a.subtasks, 'null'::jsonb) then
   raise exception using errcode = '55000', message = pg_catalog.format('Child records of task %s differ from its saved tree; review them before converting', a.task_id);
  end if;
 end loop;

 -- Bulk inserts must not emit webhooks or per-node/per-task activity. Disabled by name, never via session_replication_role,
 -- so every guard (structure, team content, generations, headings) still runs.
 alter table public.tasks disable trigger zz_taskfold_webhook_capture, disable trigger taskfold_capture_node_activity, disable trigger taskfold_capture_activity;

 for t in select * from public.tasks x
          where coalesce(x.subtasks, 'null'::jsonb) not in ('null'::jsonb, '[]'::jsonb)
            and not exists (select 1 from taskfold_private.json_subtask_conversions j where j.root_id = x.id)
          order by x.created_at, x.id for update loop
  -- Team content stays JSON until phase T (decision 5).
  if (t.project_id is not null and taskfold_private.is_team_content_project(t.project_id)) or taskfold_private.is_team_content_task(t.id) then
   insert into taskfold_private.json_subtask_conversions(root_id, original, child_ids, skipped, converted_at, status, root_user_id, root_project_id)
   values (t.id, t.subtasks, '{}', pg_catalog.jsonb_build_object('reason', 'team, phase T'), null, 'deferred', t.user_id, t.project_id)
   on conflict (root_id) do nothing;
   deferred := deferred + 1;
   continue;
  end if;

  plan := taskfold_private.legacy_child_plan(pg_catalog.to_jsonb(t), t.subtasks);
  ids := '{}'; failed := '{}'; rejected := '[]'; dropped := '[]'; present := '[]';
  for item in select value from pg_catalog.jsonb_array_elements(plan -> 'rows') loop
   r := item -> 'row';
   if r ->> 'parent_id' = any(failed) then
    rejected := rejected || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('path', item -> 'path', 'reason', 'parent_rejected'));
    failed := failed || (r ->> 'id');
    continue;
   end if;
   if r ? 'assigned_to' then
    begin
     perform taskfold_private.check_task_assignment(r ->> 'assigned_to', t.project_id, t.user_id);
    exception when others then
     dropped := dropped || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('id', r -> 'id', 'path', item -> 'path', 'assigned_to', r -> 'assigned_to'));
     r := r - 'assigned_to';
    end;
   end if;
   begin
    rec := pg_catalog.jsonb_populate_record(null::public.tasks, r);
    insert into public.tasks select rec.* on conflict (id) do nothing;
    get diagnostics n = row_count;
    if n = 1 then ids := ids || rec.id; inserted := inserted + 1;
    else present := present || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('id', rec.id, 'path', item -> 'path')); end if;
   exception when others then
    rejected := rejected || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('path', item -> 'path', 'reason', 'insert_rejected', 'sqlstate', sqlstate, 'message', sqlerrm));
    failed := failed || (r ->> 'id');
   end;
  end loop;

  insert into taskfold_private.json_subtask_conversions(root_id, original, child_ids, skipped, converted_at, status, root_user_id, root_project_id)
  values (t.id, t.subtasks, ids,
          pg_catalog.jsonb_build_object('skipped', plan -> 'skipped', 'reparented', plan -> 'reparented', 'rejected', rejected,
                                        'assignees_dropped', dropped, 'already_present', present)
          || case when pg_catalog.jsonb_typeof(t.subtasks) <> 'array' then '{"reason":"not_a_list"}'::jsonb else '{}'::jsonb end,
          pg_catalog.clock_timestamp(), 'converted', t.user_id, t.project_id)
  on conflict (root_id) do nothing;
  update public.tasks set subtasks = '[]'::jsonb where id = t.id;
  roots := roots + 1;
  skipped_nodes := skipped_nodes + pg_catalog.jsonb_array_length(plan -> 'skipped');
  reparented_nodes := reparented_nodes + pg_catalog.jsonb_array_length(plan -> 'reparented');
  rejected_nodes := rejected_nodes + pg_catalog.jsonb_array_length(rejected);
 end loop;

 alter table public.tasks enable trigger zz_taskfold_webhook_capture, enable trigger taskfold_capture_node_activity, enable trigger taskfold_capture_activity;
 return pg_catalog.jsonb_build_object('roots', roots, 'rows', inserted, 'skipped', skipped_nodes, 'reparented', reparented_nodes,
                                      'rejected', rejected_nodes, 'deferred_team_roots', deferred);
end $$;

-- 4. Persisted `subtask:` references in view orders point at the converted rows. Unresolvable references are kept;
-- a reference whose row id is already in the list is dropped (first occurrence wins).
create or replace function taskfold_private.remap_subtask_view_orders() returns integer
language plpgsql security definer set search_path = '' as $$
declare v public.view_orders; mapped jsonb; changed integer := 0;
begin
 for v in select * from public.view_orders where ids::text like '%"subtask:%' for update loop
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(m.value) order by m.o), '[]'::jsonb) into mapped
  from (select x.value, x.o, pg_catalog.row_number() over (partition by x.value order by x.o) as nth
        from (select coalesce((select c.id::text from (select taskfold_private.legacy_reference_child_id(e.value) as id) c
                               where c.id is not null and exists (select 1 from taskfold_private.json_subtask_conversions j
                                                                   where j.status = 'converted' and c.id = any(j.child_ids))), e.value) as value, e.o
              from pg_catalog.jsonb_array_elements_text(v.ids) with ordinality e(value, o)) x) m
  where m.nth = 1;
  if mapped is distinct from v.ids then
   insert into taskfold_private.json_subtask_view_order_remaps(user_id, view_id, original, remapped)
   values (v.user_id, v.id, v.ids, mapped) on conflict (user_id, view_id) do update set remapped = excluded.remapped;
   update public.view_orders set ids = mapped where user_id = v.user_id and id = v.id;
   changed := changed + 1;
  end if;
 end loop;
 return changed;
end $$;

revoke all on function taskfold_private.legacy_child_id(text,text[]), taskfold_private.legacy_child_segments(jsonb),
 taskfold_private.legacy_child_below(jsonb), taskfold_private.legacy_child_value_fits(text,jsonb),
 taskfold_private.legacy_child_row(jsonb,jsonb,uuid,text,double precision,text[]), taskfold_private.legacy_child_skip(jsonb,text[],text,jsonb),
 taskfold_private.legacy_child_walk(jsonb,jsonb,jsonb,text,integer,text[],text), taskfold_private.legacy_child_plan(jsonb,jsonb),
 taskfold_private.legacy_reference_child_id(text), taskfold_private.convert_json_subtasks(), taskfold_private.remap_subtask_view_orders()
 from public, anon, authenticated, service_role;

-- 5. Freeze: after the cutover no request may write a non-empty JSON tree (inserts included), except in team
-- projects (phase T). SQL operators without a request role (migrations, operator scripts) stay trusted.
create or replace function taskfold_private.guard_frozen_subtasks() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if coalesce(new.subtasks, 'null'::jsonb) in ('null'::jsonb, '[]'::jsonb) then return new; end if;
 if tg_op = 'UPDATE' and new.subtasks is not distinct from old.subtasks then return new; end if;
 if auth.uid() is null and coalesce(auth.role(), '') not in ('anon', 'authenticated', 'service_role') then return new; end if;
 if (new.project_id is not null and taskfold_private.is_team_content_project(new.project_id))
    or (tg_op = 'UPDATE' and taskfold_private.is_team_content_task(old.id)) then return new; end if;
 raise exception using errcode = 'PT409', message = 'TASKFOLD_CONFLICT: Subtasks are now tasks. Update Taskfold to edit them.';
end $$;
revoke all on function taskfold_private.guard_frozen_subtasks() from public, anon, authenticated, service_role;

-- 6. Run the conversion and the remap now. The freeze trigger is created afterwards and is inert for operators anyway.
do $migration$
declare summary jsonb; remapped integer;
begin
 summary := taskfold_private.convert_json_subtasks();
 remapped := taskfold_private.remap_subtask_view_orders();
 raise notice 'child_task_rows_b: % view orders remapped %', summary, remapped;
end
$migration$;

do $migration$ begin
 if not exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.tasks'::regclass and tgname = 'aaa_taskfold_subtasks_frozen') then
  create trigger aaa_taskfold_subtasks_frozen before insert or update of subtasks
   on public.tasks for each row execute function taskfold_private.guard_frozen_subtasks();
 end if;
end $migration$;

-- 7. Retire the 12 November JSON child-record system: every config flag off, client RPCs revoked.
-- The snapshot of the config and the revoked list are taken once (the first run), for the back-out script.
do $migration$
declare
 legacy constant text[] := array[
  'public.taskfold_read_child_tasks(uuid,uuid)', 'public.taskfold_edit_child_task(jsonb)', 'public.taskfold_close_child_task_edit(jsonb)',
  'public.taskfold_complete_child_task(jsonb)', 'public.taskfold_close_child_completion(jsonb)', 'public.taskfold_read_child_structure(uuid,uuid)',
  'public.taskfold_close_child_structure(jsonb)', 'public.taskfold_edit_child_structure(jsonb)', 'public.taskfold_forget_child_structure_undo(uuid)',
  'public.taskfold_child_structure_undo_archives()', 'public.taskfold_transfer_child(text,jsonb)', 'public.taskfold_review_child_adoption(uuid,uuid)',
  'public.taskfold_adopt_child_records(text,jsonb)', 'public.taskfold_child_adoption_targets(uuid,integer,uuid)', 'public.taskfold_complete_child_tasks(jsonb)',
  'public.taskfold_close_child_completion_batch(jsonb)', 'public.taskfold_read_completion_selection_roots(jsonb)', 'public.taskfold_complete_mixed_tasks(jsonb)',
  'public.taskfold_close_mixed_completion(jsonb)', 'public.taskfold_undo_mixed_completion(jsonb)', 'public.taskfold_review_child_copies(jsonb)',
  'public.taskfold_preview_child_repair(jsonb)', 'public.taskfold_child_steps(text,jsonb)', 'public.taskfold_child_steps_available(uuid,uuid)',
  'public.taskfold_search_child_adoption_targets(text,uuid,integer)', 'public.taskfold_child_repair_archives(uuid,integer)',
  'public.taskfold_child_repair_original(uuid,uuid)', 'public.taskfold_child_repair_original_cleanup(text,uuid,uuid,text,integer)',
  'public.taskfold_compare_child_repair_original(uuid,uuid)', 'public.taskfold_review_child_restore(text,uuid,uuid,uuid)',
  'public.taskfold_restore_child_original(text,jsonb)', 'public.taskfold_review_restored_child_copies(jsonb,uuid,uuid)',
  'public.taskfold_repair_children(text,jsonb)', 'public.taskfold_child_restore_status(jsonb,uuid,uuid)'];
 fn text; flags text;
begin
 insert into taskfold_private.child_rows_cutover(config_before, revoked_functions)
 select pg_catalog.to_jsonb(c), legacy from taskfold_private.child_task_record_config c where c.singleton
 on conflict (singleton) do nothing;
 select pg_catalog.string_agg(pg_catalog.format('%I = false', a.attname), ', ' order by a.attnum) into flags
 from pg_catalog.pg_attribute a
 where a.attrelid = 'taskfold_private.child_task_record_config'::regclass and a.attnum > 0 and not a.attisdropped
   and a.atttypid = 'boolean'::regtype and a.attname like '%\_enabled';
 execute pg_catalog.format('update taskfold_private.child_task_record_config set %s where singleton', flags);
 foreach fn in array legacy loop
  if pg_catalog.to_regprocedure(fn) is null then continue; end if;
  execute pg_catalog.format('revoke execute on function %s from public, anon, authenticated', fn);
 end loop;
end
$migration$;

-- 8. Producers. Anchor-replace (never full redefinitions), each anchor exactly once, each patch marked and skipped
-- once applied, so a second run is a no-op.
create or replace function taskfold_private.child_rows_b_patch(function regprocedure, marker text, anchors text[], replacements text[]) returns void
language plpgsql set search_path = '' as $$
declare definition text := pg_catalog.pg_get_functiondef(function); i integer;
begin
 if pg_catalog.strpos(definition, marker) > 0 then return; end if;
 for i in 1 .. pg_catalog.array_length(anchors, 1) loop
  if (pg_catalog.length(definition) - pg_catalog.length(pg_catalog.replace(definition, anchors[i], ''))) / pg_catalog.length(anchors[i]) <> 1 then
   raise exception using errcode = '55000', message = pg_catalog.format('%s no longer matches the expected shape (anchor %s); review it before patching', function, i);
  end if;
  definition := pg_catalog.replace(definition, anchors[i], replacements[i]);
 end loop;
 execute definition;
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef(function), marker) = 0 then
  raise exception using errcode = '55000', message = pg_catalog.format('%s patch did not apply cleanly', function);
 end if;
end $$;
revoke all on function taskfold_private.child_rows_b_patch(regprocedure,text,text[],text[]) from public, anon, authenticated, service_role;

-- 8a. Todoist import: children arrive as separate bundle tasks with `parent_source_id` and `child_order`.
-- The parent is resolved through import_sources (or a parent that was imported as JSON and converted above);
-- an unavailable parent leaves the child a standalone task. Children already imported as JSON are not duplicated.
select taskfold_private.child_rows_b_patch('public.taskfold_import_todoist(text,jsonb)'::regprocedure, 'TASKFOLD_IMPORT_CHILD_ROWS_V1',
 array[
  'dest := (row_data->>''id'')::uuid;',
  'insert into public.tasks(id,user_id,title,description,completed,priority,due_date,due_time,project_id,section_id,labels,subtasks,reminders,attachments,comments,created_at,completed_at,recurrence_pattern,is_recurring,deadline_date,duration_minutes,time_zone,source_metadata,scheduled_at,is_heading)',
  't.scheduled_at,t.is_heading);'],
 array[
  $patch$-- TASKFOLD_IMPORT_CHILD_ROWS_V1: a child imported before the cutover was converted from JSON; never import it twice.
   if kind='tasks' and exists(select 1 from public.tasks x where x.user_id=u and x.parent_id is not null
      and x.source_metadata->'taskfold_legacy_child'->'source_metadata'->>'provider'='todoist'
      and x.source_metadata->'taskfold_legacy_child'->'source_metadata'->>'account'=_account
      and x.source_metadata->'taskfold_legacy_child'->'source_metadata'->'original'->>'id'=source) then
    skipped := skipped + 1; continue;
   end if;
   dest := (row_data->>'id')::uuid;$patch$,
  $patch$t.parent_id := null;
    if jsonb_typeof(item->'parent_source_id')='string' then
     t.parent_id := (select x.record_id from public.import_sources x where x.user_id=u and x.provider='todoist' and x.source_account=_account and x.entity='tasks' and x.source_id=item->>'parent_source_id');
     if t.parent_id is null then
      t.parent_id := (select x.id from public.tasks x where x.user_id=u and x.parent_id is not null
       and x.source_metadata->'taskfold_legacy_child'->'source_metadata'->>'provider'='todoist'
       and x.source_metadata->'taskfold_legacy_child'->'source_metadata'->>'account'=_account
       and x.source_metadata->'taskfold_legacy_child'->'source_metadata'->'original'->>'id'=item->>'parent_source_id' order by x.id limit 1);
     end if;
     if t.parent_id is not null and not exists(select 1 from public.tasks x where x.id=t.parent_id and x.user_id=u and x.project_id is not distinct from t.project_id) then
      t.parent_id := null;
     end if;
    end if;
    if t.parent_id is null then t.child_order := null; end if;
    insert into public.tasks(id,user_id,title,description,completed,priority,due_date,due_time,project_id,section_id,labels,subtasks,reminders,attachments,comments,created_at,completed_at,recurrence_pattern,is_recurring,deadline_date,duration_minutes,time_zone,source_metadata,scheduled_at,is_heading,parent_id,child_order)$patch$,
  't.scheduled_at,t.is_heading,t.parent_id,t.child_order);']);

-- 8b. Automation API: `parent_id`/`child_order` are task fields, the read projection carries them, project moves no
-- longer need a `subtasks` baseline (the API stopped exposing it), and deleting a task that still has subtasks is
-- refused instead of cascading past the reviewed deletion.
select taskfold_private.child_rows_b_patch('taskfold_private.automation_validate_fields(jsonb,jsonb)'::regprocedure, 'TASKFOLD_AUTOMATION_CHILD_ROWS_V1',
 array['''time_zone'',''scheduled_at''];', 'elsif k=''time_zone'' then'],
 array['''time_zone'',''scheduled_at'',''parent_id'',''child_order'']; -- TASKFOLD_AUTOMATION_CHILD_ROWS_V1',
       $patch$elsif k='parent_id' then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or (v#>>'{}')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') then raise exception using errcode='22023',message='Use a valid parent task';end if;
  elsif k='child_order' then
   if v<>'null'::jsonb and jsonb_typeof(v)<>'number' then raise exception using errcode='22023',message='Use a numeric subtask order';end if;
  elsif k='time_zone' then$patch$]);

select taskfold_private.child_rows_b_patch('taskfold_private.automation_task_projection(public.tasks)'::regprocedure, 'TASKFOLD_AUTOMATION_CHILD_ROWS_V1',
 array['''subtasks'',t.subtasks,'],
 array['''subtasks'',t.subtasks,''parent_id'',t.parent_id,''child_order'',t.child_order, -- TASKFOLD_AUTOMATION_CHILD_ROWS_V1
']);

do $migration$
declare
 function constant regprocedure := 'taskfold_private.automation_task_write(uuid,text,text,jsonb)'::regprocedure;
 definition text := pg_catalog.pg_get_functiondef(function);
 anchor constant text := 'base ?& array[''assigned_to'',''subtasks'',''section_id'']';
begin
 if pg_catalog.strpos(definition, 'TASKFOLD_AUTOMATION_CHILD_ROWS_V1') > 0 then return; end if;
 if (pg_catalog.length(definition) - pg_catalog.length(pg_catalog.replace(definition, anchor, ''))) / pg_catalog.length(anchor) <> 2 then
  raise exception using errcode = '55000', message = 'automation_task_write no longer matches the expected shape; review it before patching';
 end if;
 definition := pg_catalog.replace(definition, anchor, 'base ?& array[''assigned_to'',''section_id'']');
 definition := pg_catalog.replace(definition, 'begin
 if _action is null', 'begin
 -- TASKFOLD_AUTOMATION_CHILD_ROWS_V1: moves no longer require a subtasks baseline.
 if _action is null');
 execute definition;
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef(function), 'TASKFOLD_AUTOMATION_CHILD_ROWS_V1') = 0 then
  raise exception using errcode = '55000', message = 'automation_task_write patch did not apply cleanly';
 end if;
end
$migration$;

select taskfold_private.child_rows_b_patch('taskfold_private.automation_review_delete(uuid,uuid,text,jsonb)'::regprocedure, 'TASKFOLD_AUTOMATION_CHILD_ROWS_V1',
 array[' -- Root FOR UPDATE excludes new direct descendants'],
 array[$patch$ -- TASKFOLD_AUTOMATION_CHILD_ROWS_V1: a parent would delete its subtasks by cascade, outside this review.
 if exists(select 1 from public.tasks c where c.parent_id=_root) then raise exception using errcode='PT409',message='Delete or move this task''s subtasks first';end if;
 -- Root FOR UPDATE excludes new direct descendants$patch$]);

-- The scoped-assignment guard of taskfold_patch_task is untouched by this migration; assert it anyway.
do $migration$ begin
 if pg_catalog.strpos(pg_catalog.pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure), 'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1') = 0 then
  raise exception using errcode = '55000', message = 'taskfold_patch_task has lost the scoped assignment guard';
 end if;
end $migration$;

notify pgrst, 'reload schema';

commit;
