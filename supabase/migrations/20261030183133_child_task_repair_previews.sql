-- Preview only. No source mutation, adoption, archive, receipt or automatic repair.
alter table taskfold_private.child_task_record_config add column repair_reviews_enabled boolean not null default false;

-- Positional paths address the explicitly reviewed proposal, never an ambiguous
-- legacy reference. Validate every ancestor before using PostgreSQL JSON setters.
create function taskfold_private.child_repair_path(tree jsonb,indices jsonb) returns text[]
language plpgsql immutable security invoker set search_path='' as $$
declare parts text[]:=array[]::text[];current_value jsonb:=tree;value jsonb;position integer;ordinal integer:=0;
begin
 if jsonb_typeof(indices) is distinct from 'array' or jsonb_array_length(indices)>64 then
  raise exception using errcode='22023',message='Choose a positional path with at most 64 levels';end if;
 for value in select * from jsonb_array_elements(indices) loop
  if jsonb_typeof(value) is distinct from 'number' or value::text!~'^(0|[1-9][0-9]{0,2})$' then
   raise exception using errcode='22023',message='Choose a whole position between 0 and 999';end if;
  position:=(value::text)::integer;
  if ordinal>0 then
   if jsonb_typeof(current_value) is distinct from 'object' then raise exception using errcode='22023',message='A parent is not a task object';end if;
   parts:=parts||'subtasks'::text;current_value:=current_value->'subtasks';
  end if;
  if jsonb_typeof(current_value) is distinct from 'array' then raise exception using errcode='22023',message='A parent is not a task list';end if;
  if position>=jsonb_array_length(current_value) then raise exception using errcode='22023',message='This position is not in the reviewed list';end if;
  parts:=parts||position::text;current_value:=current_value->position;ordinal:=ordinal+1;
 end loop;
 return parts;
end$$;

create function taskfold_private.plan_child_repair(original jsonb,changes jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare proposed jsonb:=coalesce(original,'null'::jsonb);change jsonb;kind text;allowed text[];indices jsonb;parts text[];
 node jsonb;replacement jsonb;before_tree jsonb;reference text;title text;summary jsonb:='[]';decoded jsonb;position integer;
 parent_indices jsonb;parent_parts text[];parent_node jsonb;list_parts text[];list_value jsonb;removed jsonb;
 prefix_length integer;source_index integer;destination_index integer;
begin
 if octet_length(proposed::text)>2000000 then raise exception using errcode='22023',message='This source needs a larger-work repair workflow';end if;
 if jsonb_typeof(changes) is distinct from 'array' or octet_length(changes::text)>65536
  or jsonb_array_length(changes) not between 1 and 64 then raise exception using errcode='22023',message='Review between 1 and 64 explicit changes';end if;
 for change in select * from jsonb_array_elements(changes) loop
  if jsonb_typeof(change) is distinct from 'object' or jsonb_typeof(change->'kind') is distinct from 'string' then
   raise exception using errcode='22023',message='Review each repair operation';end if;
  before_tree:=proposed;kind:=change->>'kind';
  allowed:=case kind when 'make_root_list' then array['kind','path'] when 'assign_reference' then array['kind','path','reference']
   when 'make_children_list' then array['kind','path'] when 'wrap_item' then array['kind','path','reference','title']
   when 'move_item' then array['kind','path','parent','index'] else null end;
  if allowed is null or not change ?& allowed or exists(select 1 from jsonb_object_keys(change) k where not k=any(allowed)) then
   raise exception using errcode='22023',message='Use only the reviewed operation fields';end if;
  indices:=change->'path';parts:=taskfold_private.child_repair_path(proposed,indices);
  if kind='make_root_list' then
   if indices<>'[]'::jsonb or proposed='null'::jsonb or jsonb_typeof(proposed)='array' then
    raise exception using errcode='22023',message='Only a non-list legacy root needs this change';end if;
   node:=proposed;replacement:=jsonb_build_array(node);proposed:=replacement;
  else
   if indices='[]'::jsonb then raise exception using errcode='22023',message='Choose a task position';end if;
   node:=proposed#>parts;
   if kind in('assign_reference','wrap_item') then
    if jsonb_typeof(change->'reference') is distinct from 'string' then raise exception using errcode='22023',message='Choose an explicit task reference';end if;
    reference:=change->>'reference';
    if octet_length(reference) not between 1 and 128 or octet_length(normalize(reference,NFC)) not between 1 and 128 then
     raise exception using errcode='22023',message='Choose a reference of at most 128 bytes';end if;
   end if;
   if kind='assign_reference' then
    if jsonb_typeof(node) is distinct from 'object' or node->'id'=to_jsonb(reference) then
     raise exception using errcode='22023',message='Choose an object and a changed reference';end if;
    replacement:=jsonb_set(node,array['id'],to_jsonb(reference),true);proposed:=jsonb_set(proposed,parts,replacement,false);
   elsif kind='make_children_list' then
    if jsonb_typeof(node) is distinct from 'object' or not node ? 'subtasks' or node->'subtasks'='null'::jsonb or jsonb_typeof(node->'subtasks')='array' then
     raise exception using errcode='22023',message='Only a malformed child list needs this change';end if;
    replacement:=jsonb_set(node,array['subtasks'],jsonb_build_array(node->'subtasks'),false);proposed:=jsonb_set(proposed,parts,replacement,false);
   elsif kind='wrap_item' then
    if jsonb_typeof(node)='object' or jsonb_typeof(change->'title') is distinct from 'string' then
     raise exception using errcode='22023',message='Choose a legacy value and an explicit title';end if;
    title:=change->>'title';
    if title!~'[^[:space:]]' or char_length(title)>500 or octet_length(title)>1000 then raise exception using errcode='22023',message='Choose a title of at most 500 characters and 1000 bytes';end if;
    replacement:=jsonb_build_object('id',reference,'title',title,'legacy_original',node);proposed:=jsonb_set(proposed,parts,replacement,false);
   else
    parent_indices:=change->'parent';parent_parts:=taskfold_private.child_repair_path(proposed,parent_indices);
    if jsonb_typeof(change->'index') is distinct from 'number' or (change->'index')::text!~'^(0|[1-9][0-9]{0,3})$' then
     raise exception using errcode='22023',message='Choose a whole insertion position';end if;
    position:=(change->>'index')::integer;
    if position>1000 then raise exception using errcode='22023',message='Choose an insertion position of at most 1000';end if;
    -- A destination inside the moving branch cannot be resolved after removal.
    if jsonb_array_length(parent_indices)>=jsonb_array_length(indices) and
     not exists(select 1 from generate_series(0,jsonb_array_length(indices)-1) i where parent_indices->i is distinct from indices->i) then
     raise exception using errcode='22023',message='A task cannot move into its own branch';end if;
    removed:=proposed#-parts;
    -- Sibling positions shift when the source is removed before the destination.
    prefix_length:=jsonb_array_length(indices)-1;
    if jsonb_array_length(parent_indices)>prefix_length and not exists(
     select 1 from generate_series(0,prefix_length-1) i where parent_indices->i is distinct from indices->i) then
     source_index:=(indices->>prefix_length)::integer;destination_index:=(parent_indices->>prefix_length)::integer;
     if source_index<destination_index then parent_indices:=jsonb_set(parent_indices,array[prefix_length::text],to_jsonb(destination_index-1),false);end if;
    end if;
    parent_parts:=taskfold_private.child_repair_path(removed,parent_indices);
    if parent_indices='[]'::jsonb then list_parts:=array[]::text[];list_value:=removed;
    else
     parent_node:=removed#>parent_parts;
     if jsonb_typeof(parent_node) is distinct from 'object' then raise exception using errcode='22023',message='Choose a parent task object';end if;
     list_parts:=parent_parts||'subtasks'::text;list_value:=parent_node->'subtasks';
     if list_value is null or list_value='null'::jsonb then list_value:='[]';removed:=jsonb_set(removed,list_parts,list_value,true);end if;
    end if;
    if jsonb_typeof(list_value) is distinct from 'array' then raise exception using errcode='22023',message='Repair the destination child list first';end if;
    if position>jsonb_array_length(list_value) then raise exception using errcode='22023',message='Choose a position in the list after removal';end if;
    proposed:=jsonb_insert(removed,list_parts||position::text,node,false);replacement:=node;
    if proposed is not distinct from before_tree then
     raise exception using errcode='22023',message='Choose a changed position';end if;
   end if;
  end if;
  if octet_length(proposed::text)>2000000 then raise exception using errcode='22023',message='The proposed source needs a larger-work repair workflow';end if;
  summary:=summary||jsonb_build_array(jsonb_build_object('ordinal',jsonb_array_length(summary)+1,'kind',kind,'path',indices,
   'before_kind',jsonb_typeof(node),'after_kind',jsonb_typeof(replacement)));
 end loop;
 decoded:=taskfold_private.decode_child_task_tree(proposed);
 return jsonb_build_object('proposed_tree',proposed,'proposal_valid',decoded->>'state'='ready','remaining_issue',decoded->>'issue',
  'node_count',case when decoded->>'state'='ready' then jsonb_array_length(decoded->'nodes') else null end,'steps',summary);
end$$;

-- The public wrapper preserves caller RLS. The private entry point additionally
-- checks the live session, current custody and independent read rollout gates.
create function taskfold_private.preview_child_repair(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();root_id uuid;generation uuid;project_id uuid;workspace_id uuid;t public.tasks;review jsonb;plan jsonb;digest text;blocker text;
begin
 perform taskfold_private.team_actor();
 if jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>68000 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes')) then
  raise exception using errcode='22023',message='Review this repair preview request';end if;
 if taskfold_private.team_uuid(b,'account')<>actor then raise exception using errcode='42501',message='This review belongs to another account';end if;
 root_id:=taskfold_private.team_uuid(b,'task_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if b->'workspace_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'workspace_id');end if;
 if jsonb_typeof(b->'review_digest') is distinct from 'string' or (b->>'review_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the current source first';end if;
 generation:=(b->>'task_generation')::uuid;project_id:=(b->>'project_id')::uuid;workspace_id:=(b->>'workspace_id')::uuid;
 perform 1 from taskfold_private.child_task_record_config where singleton and adoption_enabled and repair_reviews_enabled for share;
 if not found then raise exception using errcode='PT503',message='Repair previews are not enabled';end if;
 t:=taskfold_private.child_adoption_root(root_id,generation,false);review:=taskfold_private.child_adoption_snapshot(t);
 if t.project_id is distinct from project_id or (review->>'workspace_id')::uuid is distinct from workspace_id or review->>'review_digest'<>b->>'review_digest' then
  raise exception using errcode='PT409',message='This source changed; review it again';end if;
 plan:=taskfold_private.plan_child_repair(t.subtasks,b->'changes');
 -- A structurally valid proposal is not proof that indexed copies/history can
 -- be reconciled. Those need a separate reviewed custody and archive workflow.
 if exists(select 1 from taskfold_private.child_task_projections where task_id=root_id)
  or exists(select 1 from taskfold_private.child_task_records where task_id=root_id)
  or exists(select 1 from taskfold_private.child_task_record_authority where task_id=root_id) then blocker:='indexed_custody';end if;
 digest:=encode(extensions.digest(convert_to(jsonb_build_object('protocol',1,'account',actor,'root',to_jsonb(t),
  'review_digest',review->'review_digest','changes',b->'changes','proposed_tree',plan->'proposed_tree')::text,'UTF8'),'sha256'),'hex');
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',actor,'task_id',root_id,'task_generation',generation,'project_id',project_id,'workspace_id',workspace_id,
  'review_digest',review->'review_digest','repair_digest',digest,'original_tree',coalesce(t.subtasks,'null'::jsonb),'original_sql_null',t.subtasks is null,
  'changes',b->'changes','proposal_valid',plan->'proposal_valid','remaining_issue',plan->'remaining_issue','node_count',plan->'node_count',
  'proposed_tree',plan->'proposed_tree','steps',plan->'steps','custody_blocker',blocker,'mutation_available',false);
end$$;
create function public.taskfold_preview_child_repair(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$begin
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid
  and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return taskfold_private.preview_child_repair(_body);
end$$;
revoke all on function taskfold_private.child_repair_path(jsonb,jsonb),taskfold_private.plan_child_repair(jsonb,jsonb),
 taskfold_private.preview_child_repair(jsonb),public.taskfold_preview_child_repair(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.preview_child_repair(jsonb),public.taskfold_preview_child_repair(jsonb) to authenticated;
