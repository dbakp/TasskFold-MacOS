-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- An explicit duplicate separation keeps history under its original identity.
-- No event is reassigned, copied, deleted, or credited to the fresh reference.
alter function taskfold_private.plan_child_repair(jsonb,jsonb) rename to plan_child_repair_before_history_choice;
revoke all on function taskfold_private.plan_child_repair_before_history_choice(jsonb,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.plan_child_repair(original jsonb,changes jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare tree jsonb:=coalesce(original,'null'::jsonb);change jsonb;translated jsonb;part jsonb;result jsonb;steps jsonb:='[]';kept jsonb:='[]';choice jsonb;node jsonb;keeper jsonb;key text;ordinal integer:=0;
begin
 if jsonb_typeof(changes) is distinct from 'array' or octet_length(changes::text)>65536 or jsonb_array_length(changes) not between 1 and 64 then
  raise exception using errcode='22023',message='Review between 1 and 64 explicit changes';end if;
 for change in select * from jsonb_array_elements(changes) loop
  translated:=change;ordinal:=ordinal+1;
  if change->>'kind'='separate_duplicate' then
   if not change ?& array['kind','path','reference','keep_path'] or exists(select 1 from jsonb_object_keys(change) k where k not in('kind','path','reference','keep_path'))
    or change->'path'='[]'::jsonb or change->'keep_path'='[]'::jsonb or change->'path'=change->'keep_path' then
    raise exception using errcode='22023',message='Choose two different duplicate items';end if;
   node:=tree#>taskfold_private.child_repair_path(tree,change->'path');keeper:=tree#>taskfold_private.child_repair_path(tree,change->'keep_path');
   if jsonb_typeof(node) is distinct from 'object' or jsonb_typeof(keeper) is distinct from 'object' or jsonb_typeof(node->'id') is distinct from 'string'
    or jsonb_typeof(keeper->'id') is distinct from 'string' or octet_length(node->>'id') not between 1 and 128 or octet_length(keeper->>'id') not between 1 and 128
    or normalize(node->>'id',NFC) collate "C"<>normalize(keeper->>'id',NFC) collate "C"
    or jsonb_typeof(change->'reference') is distinct from 'string' or normalize(node->>'id',NFC) collate "C"=normalize(change->>'reference',NFC) collate "C" then
    raise exception using errcode='22023',message='Keep the original reference with the chosen duplicate';end if;
   kept:=kept||jsonb_build_array(jsonb_build_object('key',normalize(keeper->>'id',NFC),'node',keeper));
   translated:=(change-'keep_path')||jsonb_build_object('kind','assign_reference');
  end if;
  part:=taskfold_private.plan_child_repair_before_history_choice(tree,jsonb_build_array(translated));tree:=part->'proposed_tree';
  steps:=steps||jsonb_build_array((part->'steps'->0)||jsonb_build_object('ordinal',ordinal,'kind',change->>'kind'));
 end loop;
 -- A completed proposal must still contain precisely the chosen original item.
 -- Moving it is fine; changing or replacing it requires a fresh explicit choice.
 if part->'proposal_valid'='true'::jsonb then
  for choice in select * from jsonb_array_elements(kept) loop
   if taskfold_private.child_structure_extract(tree,choice->>'key') is distinct from choice->'node' then
    raise exception using errcode='22023',message='The item keeping history changed; review that choice again';end if;
  end loop;
 end if;
 result:=part||jsonb_build_object('steps',steps);return result;
end$$;

create or replace function taskfold_private.child_repair_history_conflict(t public.tasks,changes jsonb) returns boolean
language plpgsql stable security invoker set search_path='' as $$
declare current_tree jsonb:=coalesce(t.subtasks,'null'::jsonb);change jsonb;node jsonb;reference text;prior_reference text;separating boolean;
begin
 if exists(select 1 from public.task_node_activity h where h.task_id=t.id and not taskfold_private.child_repair_history_visible(h)) then return true;end if;
 -- Validate the entire keeper proof, including changes made after a separation.
 perform taskfold_private.plan_child_repair(current_tree,changes);
 for change in select * from jsonb_array_elements(changes) loop
  separating:=change->>'kind'='separate_duplicate';
  if change->>'kind' in('assign_reference','wrap_item','separate_duplicate') then
   node:=current_tree#>taskfold_private.child_repair_path(current_tree,change->'path');reference:=change->>'reference';prior_reference:=null;
   if change->>'kind' in('assign_reference','separate_duplicate') and jsonb_typeof(node->'id')='string' then prior_reference:=node->>'id';end if;
   if exists(select 1 from public.task_node_activity h where h.task_id=t.id and h.task_generation is not distinct from t.task_generation
    and h.node_key<>'' and (normalize(h.node_key,NFC) collate "C"=normalize(reference,NFC) collate "C"
     or (not separating and normalize(h.node_key,NFC) collate "C"=normalize(prior_reference,NFC) collate "C"))) then return true;end if;
  end if;
  current_tree:=taskfold_private.plan_child_repair(current_tree,jsonb_build_array(change))->'proposed_tree';
 end loop;
 return false;
end$$;
revoke all on function taskfold_private.plan_child_repair(jsonb,jsonb),taskfold_private.child_repair_history_conflict(public.tasks,jsonb) from public,anon,authenticated,service_role;

-- Bind the reviewed event set as well as the two chosen task positions. The
-- summary is delivered only when every historical row is currently readable.
alter function taskfold_private.preview_child_repair(jsonb) rename to preview_child_repair_before_history_choice;
revoke all on function taskfold_private.preview_child_repair_before_history_choice(jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.preview_child_repair(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare reply jsonb;tree jsonb;change jsonb;ordinal integer:=0;key text;events jsonb;choices jsonb:='[]';root_id uuid;generation uuid;
begin
 reply:=taskfold_private.preview_child_repair_before_history_choice(b);
 if not exists(select 1 from jsonb_array_elements(b->'changes') c where c->>'kind'='separate_duplicate') then return reply;end if;
 root_id:=(b->>'task_id')::uuid;generation:=(b->>'task_generation')::uuid;
 if exists(select 1 from public.task_node_activity h where h.task_id=root_id and not taskfold_private.child_repair_history_visible(h)) then return reply;end if;
 tree:=reply->'original_tree';
 for change in select * from jsonb_array_elements(b->'changes') loop
  ordinal:=ordinal+1;
  if change->>'kind'='separate_duplicate' then
   key:=normalize((tree#>taskfold_private.child_repair_path(tree,change->'keep_path'))->>'id',NFC);
   select coalesce(jsonb_agg(to_jsonb(h) order by h.sequence),'[]') into events from public.task_node_activity h
    where h.task_id=root_id and h.task_generation is not distinct from generation and normalize(h.node_key,NFC) collate "C"=key collate "C";
   choices:=choices||jsonb_build_array(jsonb_build_object('ordinal',ordinal,'node_key',key,'keep_path',change->'keep_path','event_count',jsonb_array_length(events),
    'completed_count',(select count(*) from jsonb_array_elements(events) e where e->'kinds' ? 'completed'),
    'digest',encode(extensions.digest(convert_to(events::text,'UTF8'),'sha256'),'hex')));
  end if;
  tree:=taskfold_private.plan_child_repair(tree,jsonb_build_array(change))->'proposed_tree';
 end loop;
 return reply||jsonb_build_object('history_retention',choices,'repair_digest',encode(extensions.digest(convert_to(jsonb_build_object('repair_digest',reply->'repair_digest','history_retention',choices)::text,'UTF8'),'sha256'),'hex'));
end$$;
revoke all on function taskfold_private.preview_child_repair(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.preview_child_repair(jsonb) to authenticated;

-- Recheck the retained event set through caller RLS too. Future restrictive
-- policies must protect summary counts just as they protect original exports.
create or replace function public.taskfold_preview_child_repair(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare reply jsonb;choice jsonb;events jsonb;digest text;
begin
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then
  raise exception using errcode='42501',message='This task is unavailable';end if;
 reply:=taskfold_private.preview_child_repair(_body);
 for choice in select * from jsonb_array_elements(coalesce(reply->'history_retention','[]'::jsonb)) loop
  select coalesce(jsonb_agg(to_jsonb(h) order by h.sequence),'[]') into events from public.task_node_activity h
   where h.task_id=(_body->>'task_id')::uuid and h.task_generation is not distinct from (_body->>'task_generation')::uuid
    and normalize(h.node_key,NFC) collate "C"=(choice->>'node_key') collate "C";
  digest:=encode(sha256(convert_to(events::text,'UTF8')),'hex');
  if digest<>choice->>'digest' then raise exception using errcode='42501',message='This activity is unavailable in the current account';end if;
 end loop;
 return reply;
end$$;
create or replace function public.taskfold_repair_children(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare reply jsonb;proof jsonb;
begin
 if _operation='send' and jsonb_typeof(_body->'changes')='array'
  and exists(select 1 from jsonb_array_elements(_body->'changes') c where c->>'kind'='separate_duplicate') then
  reply:=taskfold_private.commit_child_repair('check',_body);
  if reply->>'state'='unknown' then
   proof:=public.taskfold_preview_child_repair(_body-'request_id'-'repair_digest');
   if proof->>'repair_digest'<>_body->>'repair_digest' then raise exception using errcode='PT409',message='This history needs a fresh review';end if;
  end if;
 end if;
 reply:=taskfold_private.commit_child_repair(_operation,_body);
 if (_operation='original' or (_operation='send' and reply->>'state'='applied' and reply->'replayed'='false'::jsonb))
  and not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if _operation='original' and exists(select 1 from jsonb_array_elements(reply->'original'->'child_history') e where not exists(
  select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e)) then
  raise exception using errcode='42501',message='Original history is unavailable in this account';end if;
 return reply;
end$$;
revoke all on function public.taskfold_preview_child_repair(jsonb),public.taskfold_repair_children(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.taskfold_preview_child_repair(jsonb),public.taskfold_repair_children(text,jsonb) to authenticated;

commit;
