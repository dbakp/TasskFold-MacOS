-- Match both the permissive and restrictive current child-history policies.
-- Root read access alone never authorizes older/private history in an original.
create function taskfold_private.child_repair_history_visible(h public.task_node_activity) returns boolean
language sql stable security invoker set search_path='' as $$
 select coalesce((taskfold_private.history_is_custodied('child',h.id) or taskfold_private.is_team_content_task(h.task_id)
  or taskfold_private.can_read_task_activity(h.user_id,h.task_id,h.before_state,h.after_state))
 and (case when taskfold_private.history_is_custodied('child',h.id)
  then taskfold_private.history_native_read('child',h.id,h.before_state,h.after_state,h.user_id)
  else not taskfold_private.is_team_content_task(h.task_id) or
   (taskfold_private.team_native_activity_read(h.task_id) and taskfold_private.team_native_activity_states_read(h.before_state,h.after_state)) end),false)
$$;
create or replace function taskfold_private.child_repair_history_conflict(t public.tasks,changes jsonb) returns boolean
language plpgsql stable security invoker set search_path='' as $$
declare current_tree jsonb:=coalesce(t.subtasks,'null'::jsonb);change jsonb;node jsonb;reference text;prior_reference text;
begin
 if exists(select 1 from public.task_node_activity h where h.task_id=t.id and not taskfold_private.child_repair_history_visible(h)) then return true;end if;
 for change in select * from jsonb_array_elements(changes) loop
  if change->>'kind' in('assign_reference','wrap_item') then
   node:=current_tree#>taskfold_private.child_repair_path(current_tree,change->'path');reference:=change->>'reference';prior_reference:=null;
   if change->>'kind'='assign_reference' and jsonb_typeof(node->'id')='string' then prior_reference:=node->>'id';end if;
   if exists(select 1 from public.task_node_activity h where h.task_id=t.id and h.task_generation is not distinct from t.task_generation
    and h.node_key<>'' and (normalize(h.node_key,NFC)=normalize(reference,NFC) or normalize(h.node_key,NFC)=normalize(prior_reference,NFC))) then return true;end if;
  end if;
  current_tree:=taskfold_private.plan_child_repair(current_tree,jsonb_build_array(change))->'proposed_tree';
 end loop;
 return false;
end$$;


-- Keep the original implementation inaccessible. This wrapper checks every
-- archived row again at delivery, including access changes after the save.
alter function taskfold_private.commit_child_repair(text,jsonb) rename to commit_child_repair_before_history_access;
revoke all on function taskfold_private.commit_child_repair_before_history_access(text,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.commit_child_repair(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare reply jsonb;begin
 reply:=taskfold_private.commit_child_repair_before_history_access(operation,b);
 if operation='original' then
  if jsonb_typeof(reply->'original'->'child_history') is distinct from 'array' then raise exception using errcode='PT409',message='This original needs history review';end if;
  if exists(select 1 from jsonb_array_elements(reply->'original'->'child_history') e where not exists(
   select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e and taskfold_private.child_repair_history_visible(h))) then
   raise exception using errcode='42501',message='Original history access changed; the saved original is kept';end if;
 end if;
 return reply;
end$$;
create or replace function public.taskfold_repair_children(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 reply:=taskfold_private.commit_child_repair(_operation,_body);
 if (_operation='original' or (_operation='send' and reply->>'state'='applied' and reply->'replayed'='false'::jsonb))
  and not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 -- Authoritative caller-RLS check in addition to the private explicit policy
 -- check, so changes to future SELECT policies cannot silently widen export.
 if _operation='original' and exists(select 1 from jsonb_array_elements(reply->'original'->'child_history') e where not exists(
  select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e)) then
  raise exception using errcode='42501',message='Original history is unavailable in this account';end if;
 return reply;
end$$;
revoke all on function taskfold_private.child_repair_history_visible(public.task_node_activity),taskfold_private.child_repair_history_conflict(public.tasks,jsonb),
 taskfold_private.commit_child_repair(text,jsonb),public.taskfold_repair_children(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.commit_child_repair(text,jsonb),public.taskfold_repair_children(text,jsonb) to authenticated;
