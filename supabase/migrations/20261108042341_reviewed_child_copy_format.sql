-- Review format repairs and history mapping as one exact metadata-only choice.
-- This does not enable restoration adoption or any normal-use rollout gate.
create function taskfold_private.format_child_copy_for_mapping(tree jsonb,choice jsonb) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare changes jsonb;plan jsonb;begin
 if not choice ? 'format_changes' then return tree;end if;
 changes:=choice->'format_changes';
 if not choice ? 'mapping' or jsonb_typeof(changes) is distinct from 'array'
  or jsonb_array_length(changes) not between 1 and 64 or octet_length(changes::text)>65536
  or octet_length(jsonb_build_array(choice)::text)>550000
  or exists(select 1 from jsonb_array_elements(changes) c where c->>'kind'='choose_copy') then
  raise exception using errcode='22023',message='Review bounded format repairs before mapping their histories';end if;
 -- Existing format planning preserves opaque JSON in PostgreSQL. Source content
 -- is never accepted from the caller or converted through a floating-point model.
 plan:=taskfold_private.plan_child_repair(tree,changes);
 if plan->'proposal_valid' is distinct from 'true'::jsonb then
  raise exception using errcode='PT409',message='Finish reviewing the selected copy format before mapping its history';end if;
 return plan->'proposed_tree';
end$$;
revoke all on function taskfold_private.format_child_copy_for_mapping(jsonb,jsonb) from public,anon,authenticated,service_role;

create or replace function taskfold_private.preview_child_copy_choice(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare copies jsonb;choice jsonb;tree jsonb;decoded jsonb;old_nodes jsonb;root_id uuid;t public.tasks;blocker text;source text;may_write boolean;history jsonb;digest text;proposed_root public.tasks;plan jsonb;refs text[];people uuid[];candidates uuid[];team uuid;
begin
 if not coalesce(b->'changes'->0 ? 'mapping',false) then return taskfold_private.preview_child_copy_choice_before_mapping(b);end if;
 if jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>600000 or not b ?& array['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes'))
  or jsonb_typeof(b->'changes') is distinct from 'array' or jsonb_array_length(b->'changes')<>1 then raise exception using errcode='22023',message='Choose one complete saved copy';end if;
 choice:=b->'changes'->0;
 if jsonb_typeof(choice) is distinct from 'object' or not choice ?& array['kind','path','source','copy_digest','mapping'] or exists(select 1 from jsonb_object_keys(choice) k where k not in('kind','path','source','copy_digest','mapping','format_changes'))
  or choice->'kind' is distinct from '"choose_copy"'::jsonb or choice->'path' is distinct from '[]'::jsonb or jsonb_typeof(choice->'source') is distinct from 'string'
  or choice->>'source' not in('task','projection','records') or jsonb_typeof(choice->'copy_digest') is distinct from 'string' or (choice->>'copy_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the selected saved copy';end if;
 copies:=taskfold_private.review_child_copies(b-'changes');
 if copies->>'copy_digest'<>choice->>'copy_digest' then raise exception using errcode='PT409',message='The saved copies changed; compare them again';end if;
 root_id:=(b->>'task_id')::uuid;select * into t from public.tasks where id=root_id;
 source:=choice->>'source';tree:=copies->(case source when 'task' then 'task_tree' when 'projection' then 'projection_tree' else 'record_tree' end);
 if copies->'export_bundle'->'omitted'<>'[]'::jsonb or exists(select 1 from jsonb_array_elements(copies->'copies') c where c->>'state' in('unavailable','absent')) then blocker:='indexed_custody';end if;
 if not exists(select 1 from jsonb_array_elements(copies->'copies') c where c->>'id'=source and (c->>'state'='ready' or (choice ? 'format_changes' and c->>'state'='review'))) then raise exception using errcode='PT409',message='This copy needs a format or access review';end if;
 tree:=taskfold_private.format_child_copy_for_mapping(tree,choice);
 decoded:=taskfold_private.decode_child_task_tree(tree);old_nodes:=taskfold_private.decode_child_task_tree(t.subtasks);
 history:=taskfold_private.child_copy_history(root_id);
 if exists(select 1 from public.task_node_activity h where h.task_id=root_id and not taskfold_private.child_repair_history_visible(h)) then blocker:='history_custody';end if;
 if t.task_generation is null then blocker:='history_custody';end if;
 if blocker is not null then raise exception using errcode='PT409',message='Review access to every original and history before mapping';end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
 select coalesce(array_agg(distinct (n->'fields'->>'assigned_to')::uuid),'{}') into candidates
 from jsonb_array_elements(decoded->'nodes') n join jsonb_array_elements(choice->'mapping'->'nodes') c on c->>'source_key'=n->>'key'
 where c->>'lifecycle'='selected' and coalesce(n->'fields'->>'assigned_to','')<>'';
 -- NOWAIT retains auth/project deletion lock ordering without waiting while the
 -- root is held. Membership/grant deletion cannot race the eligibility check.
 perform 1 from auth.users u where u.id=any(candidates) order by u.id for share nowait;
 perform 1 from public.project_collaborators c where c.project_id=t.project_id and c.user_id=any(candidates) order by c.id for share nowait;
 perform 1 from taskfold_private.team_members m where m.team_id=team and m.user_id=any(candidates) order by m.user_id for share nowait;
 perform 1 from taskfold_private.team_project_grants g where g.project_id=t.project_id and g.user_id=any(candidates) order by g.user_id for share nowait;
 select coalesce(array_agg(u.id),'{}') into people from auth.users u where u.id=any(candidates) and (u.banned_until is null or u.banned_until<=clock_timestamp())
  and case when team is not null then coalesce(taskfold_private.team_project_role(u.id,t.project_id),'') in('manager','editor') when t.project_id is null then u.id=t.user_id else coalesce(public.has_project_access(u.id,t.project_id),false) end;
 select coalesce(array_agg(distinct key),'{}') into refs from (
  select n->>'node_key' key from jsonb_array_elements(history->'child_history') n where n->>'node_key'<>''
  union select n->>'key' from jsonb_array_elements(old_nodes->'nodes') n
 ) x;
 plan:=taskfold_private.prepare_child_copy_mapping(t,tree,copies->'export_bundle'->'records',choice->'mapping',encode(sha256(convert_to(b::text,'UTF8')),'hex'),refs,people);
 tree:=plan->'proposed_tree';decoded:=taskfold_private.decode_child_task_tree(tree);
 -- An active restoration needs its own final adoption decision. Previewing
 -- format/history choices must never imply that an ordinary repair can end it.
 if exists(select 1 from taskfold_private.child_repair_restorations where task_id=root_id and phase='restored') then blocker:='restoration_custody';end if;
 may_write:=blocker is null and exists(select 1 from taskfold_private.child_task_record_config where singleton and mapping_reconciliation_enabled and copy_reconciliation_enabled and repair_writes_enabled and repair_reviews_enabled and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled)
  and ((b->>'workspace_id') is null or (coalesce(taskfold_private.team_project_role(auth.uid(),t.project_id),'') in('manager','editor') and exists(select 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled and native_task_types_enabled)))
  and (t.project_id is null or exists(select 1 from public.projects where id=t.project_id and not is_archived and not ancestor_archived));
 digest:=encode(sha256(convert_to(jsonb_build_object('choice',b,'copies',copies->'copy_digest','history',history,'proposed',tree)::text,'UTF8')),'hex');
 return (b-'changes')||jsonb_build_object('repair_digest',digest,'original_tree',coalesce(t.subtasks,'null'::jsonb),'original_sql_null',t.subtasks is null,'changes',b->'changes',
  'proposal_valid',true,'remaining_issue',null,'node_count',jsonb_array_length(decoded->'nodes'),'proposed_tree',tree,
  'steps',jsonb_build_array(jsonb_build_object('ordinal',1,'kind','choose_copy','path','[]'::jsonb,'before_kind',jsonb_typeof(coalesce(t.subtasks,'null'::jsonb)),'after_kind',jsonb_typeof(tree))),
  'custody_blocker',blocker,'mutation_available',may_write,'mapping_plan',plan-'proposed_tree');
end$$;
