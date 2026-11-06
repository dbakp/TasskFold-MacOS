-- Pure planning for explicit saved-copy identity/lifecycle reconciliation.
-- No RPC, grants, writes, rollout or automatic winner. A future transaction must
-- bind this plan to fresh caller-readable copies/history and archive originals.
create function taskfold_private.plan_child_copy_mapping(
 root public.tasks, selected jsonb, stored jsonb, mapping jsonb,
 plan_seed text, historical_references text[], allowed_recipients uuid[]
) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare decoded jsonb;proposed jsonb:=selected;entry jsonb;choice jsonb;row_value jsonb;fields jsonb;prior_fields jsonb;summary jsonb:='[]';
 locations jsonb;source_key text;target_key text;raw_reference text;inc uuid;path text[];seen_sources text[]:='{}';seen_targets text[]:='{}';used_records text[]:='{}';retired text[]:='{}';
 all_old text[]:='{}';life text[]:=array['completed','completed_at','completion_version','taskfold_completion_v1','is_heading','assigned_to','recurrence_parent_id'];
 k text;reset_completion boolean;fresh boolean;candidate public.tasks;person uuid;count_nodes integer;old_count integer;
begin
 if root.id is null or root.task_generation is null or plan_seed is null or plan_seed!~'^[a-f0-9]{64}$'
  or jsonb_typeof(stored) is distinct from 'array' or jsonb_array_length(stored)>1000 or octet_length(stored::text)>4000000 or octet_length(coalesce(selected,'null'::jsonb)::text)>2000000
  or historical_references is null or cardinality(historical_references)>10000 or array_position(historical_references,null) is not null
  or allowed_recipients is null or cardinality(allowed_recipients)>10000 or array_position(allowed_recipients,null) is not null
  or jsonb_typeof(mapping) is distinct from 'object' or octet_length(mapping::text)>512000 or mapping->'version' is distinct from '1'::jsonb
  or not mapping ?& array['version','nodes','retire'] or mapping-array['version','nodes','retire']<>'{}'
  or jsonb_typeof(mapping->'nodes') is distinct from 'array' or jsonb_array_length(mapping->'nodes')>1000
  or jsonb_typeof(mapping->'retire') is distinct from 'array' or jsonb_array_length(mapping->'retire')>1000 then
  raise exception using errcode='22023',message='Review every selected identity and retained history';end if;
 decoded:=taskfold_private.decode_child_task_tree(selected);
 if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Repair the selected copy format before mapping its history';end if;
 with recursive walk(node,path) as (
  select n,array[(position-1)::text] from jsonb_array_elements(case when selected='null'::jsonb then '[]'::jsonb else selected end) with ordinality e(n,position)
  union all
  select n,w.path||array['subtasks',(position-1)::text] from walk w cross join lateral jsonb_array_elements(case when jsonb_typeof(w.node->'subtasks')='array' then w.node->'subtasks' else '[]'::jsonb end) with ordinality e(n,position)
 ) select coalesce(jsonb_object_agg(normalize(node->>'id',NFC),to_jsonb(w.path)),'{}') into locations from walk w;
 count_nodes:=jsonb_array_length(decoded->'nodes');old_count:=jsonb_array_length(stored);
 if jsonb_array_length(mapping->'nodes')<>count_nodes then raise exception using errcode='22023',message='Choose a history identity for every selected item';end if;
 for row_value in select * from jsonb_array_elements(stored) loop
  if jsonb_typeof(row_value) is distinct from 'object' or row_value->>'task_id' is distinct from root.id::text
   or jsonb_typeof(row_value->'node_key') is distinct from 'string' or jsonb_typeof(row_value->'incarnation') is distinct from 'string'
   or jsonb_typeof(row_value->'fields') is distinct from 'object' or row_value->'fields' ? 'subtasks' or jsonb_typeof(row_value->'fields'->'id') is distinct from 'string' then
   raise exception using errcode='PT409',message='Stored identity needs a fresh review';end if;
  target_key:=row_value->>'node_key';inc:=(row_value->>'incarnation')::uuid;
  if inc is null or target_key='' or octet_length(target_key)>128 or normalize(target_key,NFC) collate "C"<>target_key collate "C"
   or normalize(row_value->'fields'->>'id',NFC) collate "C"<>target_key collate "C" or target_key=any(all_old) then
   raise exception using errcode='PT409',message='Stored identity is ambiguous';end if;
  all_old:=array_append(all_old,target_key);
 end loop;
 for choice in select * from jsonb_array_elements(mapping->'nodes') loop
  if jsonb_typeof(choice) is distinct from 'object' or not choice ?& array['source_key','history_key','incarnation','lifecycle']
   or jsonb_typeof(choice->'source_key') is distinct from 'string' or choice->>'lifecycle' not in('selected','recorded')
   or jsonb_typeof(choice->'lifecycle') is distinct from 'string' then raise exception using errcode='22023',message='Choose the selected or recorded lifecycle explicitly';end if;
  source_key:=choice->>'source_key';
  if source_key=any(seen_sources) then raise exception using errcode='22023',message='A selected item cannot be mapped twice';end if;
  select n into entry from jsonb_array_elements(decoded->'nodes') n where n->>'key' collate "C"=source_key collate "C";
  if entry is null then raise exception using errcode='22023',message='The selected item is unavailable';end if;
  seen_sources:=array_append(seen_sources,source_key);fields:=entry->'fields';fresh:=choice->'history_key'='null'::jsonb;
  if fresh then
   if choice->'incarnation' is distinct from 'null'::jsonb or choice->>'lifecycle'<>'selected'
    or jsonb_typeof(choice->'new_reference') is distinct from 'string' or choice-array['source_key','history_key','incarnation','lifecycle','new_reference']<>'{}' then
    raise exception using errcode='22023',message='Choose an unused reference for a new history identity';end if;
   raw_reference:=choice->>'new_reference';target_key:=normalize(raw_reference,NFC);prior_fields:=null;inc:=null;
   if raw_reference='' or octet_length(raw_reference)>128 or octet_length(target_key)>128 or target_key=any(all_old)
    or exists(select 1 from unnest(historical_references) old_key where normalize(old_key,NFC) collate "C"=target_key collate "C") then
    raise exception using errcode='PT409',message='This new reference already has recorded history';end if;
  else
   if choice-array['source_key','history_key','incarnation','lifecycle']<>'{}' or jsonb_typeof(choice->'history_key') is distinct from 'string'
    or jsonb_typeof(choice->'incarnation') is distinct from 'string' then raise exception using errcode='22023',message='Bind the existing history incarnation';end if;
   target_key:=choice->>'history_key';inc:=(choice->>'incarnation')::uuid;
   select n into row_value from jsonb_array_elements(stored) n where n->>'node_key' collate "C"=target_key collate "C";
   if row_value is null or inc is distinct from (row_value->>'incarnation')::uuid then raise exception using errcode='PT409',message='This history identity was changed or recreated';end if;
   prior_fields:=row_value->'fields';raw_reference:=prior_fields->>'id';used_records:=array_append(used_records,target_key);
   if choice->>'lifecycle'='recorded' then
    foreach k in array life loop fields:=fields-k;if prior_fields ? k then fields:=fields||jsonb_build_object(k,prior_fields->k);end if;end loop;
   elsif fields->'recurrence_parent_id' is distinct from prior_fields->'recurrence_parent_id' then
    raise exception using errcode='PT409',message='Review recurrence lineage separately before using this lifecycle';
   end if;
  end if;
  if target_key=any(seen_targets) then raise exception using errcode='22023',message='Two selected items cannot take the same history identity';end if;
  seen_targets:=array_append(seen_targets,target_key);
  fields:=fields||jsonb_build_object('id',raw_reference);
  -- Keep the exact chosen completion date, but never transplant its old cohort
  -- onto another history identity or let old completion Undo certify this state.
  reset_completion:=fresh or (choice->>'lifecycle'='selected' and exists(select 1 from unnest(array['completed','completed_at','completion_version','taskfold_completion_v1','is_heading']) f where fields->f is distinct from prior_fields->f));
  if reset_completion then
   fields:=(fields-array['completion_version','taskfold_completion_v1'])||jsonb_build_object('completion_version',0,'taskfold_completion_v1',jsonb_build_object('epoch',md5(plan_seed||':'||target_key||':reconciliation')::uuid,'version',0));
  end if;
  if fresh and coalesce(fields->'recurrence_parent_id','null'::jsonb)<>'null'::jsonb then raise exception using errcode='PT409',message='A new history identity needs a separate recurrence-lineage review';end if;
  if coalesce(fields->>'assigned_to','')<>'' and (fresh or fields->'assigned_to' is distinct from prior_fields->'assigned_to') then
   if jsonb_typeof(fields->'assigned_to')<>'string' then raise exception using errcode='22023',message='Review the selected recipient';end if;
   person:=(fields->>'assigned_to')::uuid;
   if person is null or not coalesce(person=any(allowed_recipients),false) then raise exception using errcode='42501',message='The selected recipient is not currently eligible';end if;
  end if;
  path:=array(select jsonb_array_elements_text(locations->source_key));
  -- Replace only this item's own fields. Children come from the selected copy
  -- and are mapped independently; unknown keys/numbers never pass through text.
  if entry->>'children_kind'='array' then fields:=fields||jsonb_build_object('subtasks',(proposed#>path)->'subtasks');
  elsif entry->>'children_kind'='null' then fields:=fields||'{"subtasks":null}'::jsonb;end if;
  proposed:=jsonb_set(proposed,path,fields,false);
  summary:=summary||jsonb_build_array(jsonb_build_object('source_key',source_key,'history_key',case when fresh then null else target_key end,'target_key',target_key,'incarnation',inc,'lifecycle',choice->'lifecycle','new_identity',fresh,'reset_completion',reset_completion));
 end loop;
 for choice in select * from jsonb_array_elements(mapping->'retire') loop
  if jsonb_typeof(choice) is distinct from 'object' or not choice ?& array['node_key','incarnation'] or choice-array['node_key','incarnation']<>'{}'
   or jsonb_typeof(choice->'node_key') is distinct from 'string' or jsonb_typeof(choice->'incarnation') is distinct from 'string' then raise exception using errcode='22023',message='Review every retired history incarnation';end if;
  target_key:=choice->>'node_key';inc:=(choice->>'incarnation')::uuid;
  select n into row_value from jsonb_array_elements(stored) n where n->>'node_key' collate "C"=target_key collate "C";
  if row_value is null or inc is distinct from (row_value->>'incarnation')::uuid or target_key=any(used_records) or target_key=any(retired) then raise exception using errcode='PT409',message='This retired history identity changed or is still selected';end if;
  retired:=array_append(retired,target_key);
 end loop;
 if cardinality(used_records)+cardinality(retired)<>old_count then raise exception using errcode='22023',message='Keep or explicitly retire every stored history identity';end if;
 if taskfold_private.decode_child_task_tree(proposed)->>'state'<>'ready' then raise exception using errcode='PT409',message='The mapped copy needs a format review';end if;
 candidate:=root;candidate.subtasks:=proposed;
 perform taskfold_private.node_activity_nodes(candidate);
 return jsonb_build_object('protocol',1,'proposed_tree',proposed,'nodes',summary,'retired',to_jsonb(retired),'new_identity_count',(select count(*) from jsonb_array_elements(summary) n where n->'new_identity'='true'::jsonb),'reset_completion_count',(select count(*) from jsonb_array_elements(summary) n where n->'reset_completion'='true'::jsonb));
end$$;
revoke all on function taskfold_private.plan_child_copy_mapping(public.tasks,jsonb,jsonb,jsonb,text,text[],uuid[]) from public,anon,authenticated,service_role;
