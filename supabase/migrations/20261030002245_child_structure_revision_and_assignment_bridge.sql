-- Independent structural fence. Private preparation only: v1 reads stay exact,
-- no command endpoint or automatic adoption is enabled by this migration.
-- Keep the existing creator/project/recipient checks while traversing every
-- actual child array. Sparse/null/opaque containers are preserved, not fed to
-- jsonb_array_elements. This replaces the legacy two-level assignment scan.
create or replace function taskfold_private.guard_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare child jsonb;
begin
 if tg_op='UPDATE' and new.user_id<>old.user_id then raise exception 'Task creator cannot be changed';end if;
 if tg_op='UPDATE' and new.project_id is distinct from old.project_id then
  new.assigned_to:=null;new.subtasks:=taskfold_private.clear_assignee(new.subtasks,null);
 end if;
 if tg_op='INSERT' or new.assigned_to is distinct from old.assigned_to or new.project_id is distinct from old.project_id then
  perform taskfold_private.check_task_assignment(new.assigned_to::text,new.project_id,new.user_id);
 end if;
 if tg_op='INSERT' or new.subtasks is distinct from old.subtasks or new.project_id is distinct from old.project_id then
  for child in
   with recursive nodes(value) as (
    select value from jsonb_array_elements(case when jsonb_typeof(new.subtasks)='array' then new.subtasks else '[]'::jsonb end)
    union all
    select c.value from nodes cross join lateral jsonb_array_elements(case when jsonb_typeof(nodes.value->'subtasks')='array' then nodes.value->'subtasks' else '[]'::jsonb end) c(value)
   ) select value from nodes
  loop perform taskfold_private.check_task_assignment(child->>'assigned_to',new.project_id,new.user_id);end loop;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_task() from public,anon,authenticated,service_role;

alter table taskfold_private.child_task_projections
 add column structure_revision bigint not null default 1 check(structure_revision > 0);

-- The bounded existing decoder owns validation and Unicode identity rules.
-- Exclude editable fields so notes/completion/custody changes do not invalidate
-- a pending structural baseline. Preserve raw paths and all container shapes.
create function taskfold_private.child_task_topology(tree jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare decoded jsonb;nodes jsonb;
begin
 decoded:=taskfold_private.decode_child_task_tree(tree);
 if decoded->>'state'<>'ready' then return null;end if;
 select coalesce(jsonb_agg(n-'fields' order by n->>'key' collate "C"),'[]') into nodes
 from jsonb_array_elements(decoded->'nodes') n;
 return jsonb_build_object('root_kind',case when tree is null or tree='null'::jsonb then 'null' else 'array' end,'nodes',nodes);
end $$;

create function taskfold_private.advance_child_task_structure() returns trigger
language plpgsql security invoker set search_path='' as $$
declare before_shape jsonb;after_shape jsonb;
begin
 -- Root lock precedes projection lock in the existing bridge. This trigger
 -- participates in that transaction, including rollback and concurrent edits.
 new.structure_revision:=old.structure_revision;
 if new.task_generation is distinct from old.task_generation or new.state<>'ready' or old.state<>'ready' then
  new.structure_revision:=old.structure_revision+1;
 elsif new.source_tree is distinct from old.source_tree then
  before_shape:=taskfold_private.child_task_topology(old.source_tree);
  after_shape:=taskfold_private.child_task_topology(new.source_tree);
  if before_shape is null or after_shape is null or before_shape is distinct from after_shape then
   new.structure_revision:=old.structure_revision+1;
  end if;
 end if;
 return new;
end $$;
create trigger taskfold_advance_child_task_structure before update on taskfold_private.child_task_projections
 for each row execute function taskfold_private.advance_child_task_structure();
revoke all on function taskfold_private.child_task_topology(jsonb),taskfold_private.advance_child_task_structure()
 from public,anon,authenticated,service_role;
