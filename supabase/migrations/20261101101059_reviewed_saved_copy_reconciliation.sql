-- Explicit, archived reconciliation. Rollout remains off; no automatic winner.
alter table taskfold_private.child_task_record_config add column copy_reconciliation_enabled boolean not null default false;
create function taskfold_private.child_copy_history(root_id uuid) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare h public.task_activity;c public.task_node_activity;part text;roots text[]:='{}';children text[]:='{}';used bigint:=64;total integer:=0;result jsonb;
begin
 -- Cursor iteration bounds bytes before retaining another historical row.
 -- A row-count bound alone does not constrain opaque historical payload sizes.
 for h in select a.* from public.task_activity a where a.task_id=root_id order by a.sequence loop
  part:=to_jsonb(h)::text;used:=used+octet_length(part)+2;total:=total+1;
  if used>8000000 or total>10000 then raise exception using errcode='PT413',message='This history needs a larger-work archive';end if;
  roots:=array_append(roots,part);
 end loop;
 for c in select a.* from public.task_node_activity a where a.task_id=root_id order by a.sequence loop
  part:=to_jsonb(c)::text;used:=used+octet_length(part)+2;total:=total+1;
  if used>8000000 or total>10000 then raise exception using errcode='PT413',message='This history needs a larger-work archive';end if;
  children:=array_append(children,part);
 end loop;
 result:=('{"root_history":['||coalesce(array_to_string(roots,','),'')||'],"child_history":['||coalesce(array_to_string(children,','),'')||']}')::jsonb;
 if octet_length(result::text)>8000000 then raise exception using errcode='PT413',message='This history needs a larger-work archive';end if;
 return result;
end$$;
create function taskfold_private.child_copy_history_digest(root_id uuid) returns text
language plpgsql volatile security definer set search_path='' as $$declare t public.tasks;begin
 perform taskfold_private.team_actor();select * into t from public.tasks where id=root_id;
 perform taskfold_private.child_adoption_root(root_id,t.task_generation,false);
 return encode(sha256(convert_to(taskfold_private.child_copy_history(root_id)::text,'UTF8')),'hex');
end$$;
create function taskfold_private.preview_child_copy_choice(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare copies jsonb;choice jsonb;tree jsonb;decoded jsonb;old_nodes jsonb;root_id uuid;t public.tasks;blocker text;source text;may_write boolean;history jsonb;digest text;proposed_root public.tasks;
begin
 if jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>70000 or not b ?& array['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes'))
  or jsonb_typeof(b->'changes') is distinct from 'array' or jsonb_array_length(b->'changes')<>1 then raise exception using errcode='22023',message='Choose one complete saved copy';end if;
 choice:=b->'changes'->0;
 if jsonb_typeof(choice) is distinct from 'object' or not choice ?& array['kind','path','source','copy_digest'] or exists(select 1 from jsonb_object_keys(choice) k where k not in('kind','path','source','copy_digest'))
  or choice->'kind' is distinct from '"choose_copy"'::jsonb or choice->'path' is distinct from '[]'::jsonb or jsonb_typeof(choice->'source') is distinct from 'string'
  or choice->>'source' not in('task','projection','records') or jsonb_typeof(choice->'copy_digest') is distinct from 'string' or (choice->>'copy_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the selected saved copy';end if;
 copies:=taskfold_private.review_child_copies(b-'changes');
 if copies->>'copy_digest'<>choice->>'copy_digest' then raise exception using errcode='PT409',message='The saved copies changed; compare them again';end if;
 root_id:=(b->>'task_id')::uuid;select * into t from public.tasks where id=root_id;
 source:=choice->>'source';tree:=copies->(case source when 'task' then 'task_tree' when 'projection' then 'projection_tree' else 'record_tree' end);
 if copies->'export_bundle'->'omitted'<>'[]'::jsonb or exists(select 1 from jsonb_array_elements(copies->'copies') c where c->>'state' in('unavailable','absent')) then blocker:='indexed_custody';end if;
 if not exists(select 1 from jsonb_array_elements(copies->'copies') c where c->>'id'=source and c->>'state'='ready') then raise exception using errcode='PT409',message='This copy needs a format or access review';end if;
 decoded:=taskfold_private.decode_child_task_tree(tree);old_nodes:=taskfold_private.decode_child_task_tree(t.subtasks);
 -- Keep every existing identity/incarnation and completion/recipient lifecycle.
 -- Ambiguous identities/lifecycles require the subsequent explicit mapping flow.
 if blocker is null then
 if old_nodes->>'state'<>'ready' or jsonb_array_length(decoded->'nodes')<>(select count(*) from taskfold_private.child_task_records where task_id=root_id)
  or jsonb_array_length(decoded->'nodes')<>jsonb_array_length(old_nodes->'nodes') or exists(
   select 1 from jsonb_array_elements(decoded->'nodes') n left join taskfold_private.child_task_records r on r.task_id=root_id and r.node_key=n->>'key'
   left join lateral (select e from jsonb_array_elements(old_nodes->'nodes') e where e->>'key'=n->>'key') old on true
   where r.task_id is null or old.e is null or exists(select 1 from unnest(array['id','completed','completed_at','completion_version','taskfold_completion_v1','is_heading','assigned_to','recurrence_parent_id']) k
    where n->'fields'->k is distinct from r.fields->k or n->'fields'->k is distinct from old.e->'fields'->k)) then blocker:='history_custody';end if;
 end if;
 if t.task_generation is null then blocker:='history_custody';end if;
 if blocker is null then
  proposed_root:=t;proposed_root.subtasks:=tree;
  begin perform taskfold_private.node_activity_nodes(t);perform taskfold_private.node_activity_nodes(proposed_root);
  exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range or raise_exception then blocker:='history_custody';end;
 end if;
 history:=taskfold_private.child_copy_history(root_id);
 if exists(select 1 from public.task_node_activity h where h.task_id=root_id and not taskfold_private.child_repair_history_visible(h)) then blocker:='history_custody';end if;
 may_write:=blocker is null and exists(select 1 from taskfold_private.child_task_record_config where singleton and copy_reconciliation_enabled and repair_writes_enabled and repair_reviews_enabled and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled)
  and ((b->>'workspace_id') is null or (coalesce(taskfold_private.team_project_role(auth.uid(),t.project_id),'') in('manager','editor') and exists(select 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled and native_task_types_enabled)))
  and (t.project_id is null or exists(select 1 from public.projects where id=t.project_id and not is_archived and not ancestor_archived));
 digest:=encode(sha256(convert_to(jsonb_build_object('choice',b,'copies',copies->'copy_digest','history',history,'proposed',tree)::text,'UTF8')),'hex');
 return (b-'changes')||jsonb_build_object('repair_digest',digest,'original_tree',coalesce(t.subtasks,'null'::jsonb),'original_sql_null',t.subtasks is null,'changes',b->'changes',
  'proposal_valid',true,'remaining_issue',null,'node_count',jsonb_array_length(decoded->'nodes'),'proposed_tree',tree,
  'steps',jsonb_build_array(jsonb_build_object('ordinal',1,'kind','choose_copy','path','[]'::jsonb,'before_kind',jsonb_typeof(coalesce(t.subtasks,'null'::jsonb)),'after_kind',jsonb_typeof(tree))),
  'custody_blocker',blocker,'mutation_available',may_write);
end$$;
alter function taskfold_private.preview_child_repair(jsonb) rename to preview_child_repair_before_copy_choice;
revoke all on function taskfold_private.preview_child_repair_before_copy_choice(jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.preview_child_repair(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$begin
 if jsonb_typeof(b->'changes')='array' and exists(select 1 from jsonb_array_elements(b->'changes') c where c->>'kind'='choose_copy') then return taskfold_private.preview_child_copy_choice(b);end if;
 return taskfold_private.preview_child_repair_before_copy_choice(b);
end$$;
alter function public.taskfold_preview_child_repair(jsonb) rename to taskfold_preview_child_repair_before_copy_choice;
revoke all on function public.taskfold_preview_child_repair_before_copy_choice(jsonb) from public,anon,authenticated,service_role;
alter function public.taskfold_preview_child_repair_before_copy_choice(jsonb) set schema taskfold_private;
create function public.taskfold_preview_child_repair(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare result jsonb;visible jsonb;root_id uuid;begin
 if jsonb_typeof(_body->'changes')='array' and exists(select 1 from jsonb_array_elements(_body->'changes') c where c->>'kind'='choose_copy') then
  root_id:=(_body->>'task_id')::uuid;
  if not exists(select 1 from public.tasks where id=root_id and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
  result:=taskfold_private.preview_child_copy_choice(_body);
  visible:=jsonb_build_object('root_history',(select coalesce(jsonb_agg(to_jsonb(h) order by h.sequence),'[]') from public.task_activity h where task_id=root_id),'child_history',(select coalesce(jsonb_agg(to_jsonb(h) order by h.sequence),'[]') from public.task_node_activity h where task_id=root_id));
  if encode(sha256(convert_to(visible::text,'UTF8')),'hex')<>taskfold_private.child_copy_history_digest(root_id) then raise exception using errcode='42501',message='This history needs an access review';end if;
  return result;
 end if;
 return taskfold_private.taskfold_preview_child_repair_before_copy_choice(_body);
end$$;

alter function taskfold_private.commit_child_repair(text,jsonb) rename to commit_child_repair_before_copy_choice;
revoke all on function taskfold_private.commit_child_repair_before_copy_choice(text,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.commit_child_repair(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();prior jsonb;t public.tasks;view jsonb;copies jsonb;original jsonb;archive_id uuid;digest text;bytes integer;team uuid;q uuid;n jsonb;path text[];saved jsonb;receipt taskfold_private.child_task_repairs;
begin
 if operation is null or operation not in('send','check','close','original') then raise exception using errcode='22023',message='Choose a supported repair action';end if;
 if jsonb_typeof(b->'changes') is distinct from 'array' or not exists(select 1 from jsonb_array_elements(b->'changes') c where c->>'kind'='choose_copy') then return taskfold_private.commit_child_repair_before_copy_choice(operation,b);end if;
 -- Existing validation, actor/session/nonce locks and replay semantics remain.
 prior:=taskfold_private.commit_child_repair_before_copy_choice('check',b);
 if operation='original' and prior->>'state'='applied' then
  t:=taskfold_private.child_adoption_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,false);
  select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
  if t.project_id is distinct from (b->>'project_id')::uuid or team is distinct from (b->>'workspace_id')::uuid then raise exception using errcode='42501',message='This original belongs to another task context';end if;
  select o.original into saved from taskfold_private.child_task_repair_originals o where o.id=(prior->>'archive_id')::uuid and o.task_id=t.id and o.task_generation is not distinct from t.task_generation and o.project_id is not distinct from t.project_id and o.team_id is not distinct from team and (team is not null or o.owner_id=t.user_id);
  if saved is null or octet_length(saved::text)<>(prior->>'archive_bytes')::integer or encode(sha256(convert_to(saved::text,'UTF8')),'hex')<>prior->>'archive_digest' then raise exception using errcode='PT409',message='This saved original needs recovery review';end if;
  if exists(select 1 from jsonb_array_elements(saved->'child_history') e where not exists(select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e and taskfold_private.child_repair_history_visible(h))) then raise exception using errcode='42501',message='Original history access changed';end if;
  return jsonb_build_object('protocol',1,'account',a,'request_id',b->'request_id','archive_id',prior->'archive_id','archive_digest',prior->'archive_digest','original',saved);
 end if;
 if operation<>'send' or prior->>'state'<>'unknown' then return taskfold_private.commit_child_repair_before_copy_choice(operation,b);end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and copy_reconciliation_enabled and repair_writes_enabled and repair_reviews_enabled and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Saved-copy reconciliation is not enabled';end if;
 t:=taskfold_private.child_adoption_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,true);
 view:=taskfold_private.preview_child_copy_choice(b-'request_id'-'repair_digest');
 if view->>'repair_digest'<>b->>'repair_digest' or view->'custody_blocker'<>'null'::jsonb or view->'mutation_available'<>'true'::jsonb then raise exception using errcode='PT409',message='Review this copy and its history before saving';end if;
 q:=(b->>'request_id')::uuid;team:=(b->>'workspace_id')::uuid;
 if team is not null and (not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) or not pg_try_advisory_xact_lock(hashtextextended(team::text,73928))) then raise exception using errcode='55P03',message='Another workspace decision is finishing';end if;
 if (select count(*) from taskfold_private.child_task_repairs where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many repair decisions; try later';end if;
 if team is null and not pg_try_advisory_xact_lock(hashtextextended(t.user_id::text,73918)) then raise exception using errcode='55P03',message='Another original-owner decision is finishing';end if;
 copies:=taskfold_private.review_child_copies(b-array['request_id','repair_digest','changes']);
 original:=jsonb_build_object('protocol',1,'root',copies->'export_bundle'->'root','subtasks_sql_null',copies->'export_bundle'->'subtasks_sql_null','projection',copies->'export_bundle'->'projection','records',copies->'export_bundle'->'records','authority',copies->'export_bundle'->'authority','review_digest',b->'review_digest','repair_digest',b->'repair_digest','copy_choice',b->'changes'->0)||taskfold_private.child_copy_history(t.id);
 if encode(sha256(convert_to(jsonb_build_object('choice',b-array['request_id','repair_digest'],'copies',copies->'copy_digest','history',jsonb_build_object('root_history',original->'root_history','child_history',original->'child_history'),'proposed',view->'proposed_tree')::text,'UTF8')),'hex')<>b->>'repair_digest' then raise exception using errcode='PT409',message='History changed before the archive was saved; review again';end if;
 bytes:=octet_length(original::text);
 if bytes>8000000 then raise exception using errcode='PT413',message='This original needs a larger-work archive';end if;
 if coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.actor_id=a),0)+bytes>64000000 or (team is null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.owner_id=t.user_id),0)+bytes>64000000) or (team is not null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.team_id=team),0)+bytes>256000000) then raise exception using errcode='PT429',message='Original storage is full; all copies stay unchanged';end if;
 archive_id:=gen_random_uuid();digest:=encode(sha256(convert_to(original::text,'UTF8')),'hex');
 insert into taskfold_private.child_task_repair_originals(id,actor_id,owner_id,team_id,task_id,task_generation,project_id,request_id,original,bytes,digest)
 values(archive_id,a,case when team is null then t.user_id else null end,team,t.id,t.task_generation,t.project_id,q,original,bytes,digest);
 -- Row-first staging retains incarnations and only advances changed revisions.
 for n in select * from jsonb_array_elements(taskfold_private.decode_child_task_tree(view->'proposed_tree')->'nodes') loop
  path:=array(select jsonb_array_elements_text(n->'path'));
  if exists(select 1 from taskfold_private.child_task_records r where r.task_id=t.id and r.node_key=n->>'key' and r.revision>=9007199254740990 and (r.parent_key,r.sibling_order,r.identity_path,r.fields::text collate "C",r.children_kind) is distinct from (n->>'parent',(n->>'position')::integer,path,(n->'fields')::text collate "C",n->>'children_kind')) then raise exception using errcode='PT409',message='This revision needs a recovery review';end if;
  update taskfold_private.child_task_records r set parent_key=n->>'parent',sibling_order=(n->>'position')::integer,identity_path=path,fields=n->'fields',children_kind=n->>'children_kind',
   field_versions=r.field_versions||(select coalesce(jsonb_object_agg(k,r.revision+1),'{}') from jsonb_object_keys(r.fields||(n->'fields')) k where (r.fields->k)::text collate "C" is distinct from (n->'fields'->k)::text collate "C"),revision=r.revision+1
   where r.task_id=t.id and r.node_key=n->>'key' and (r.parent_key,r.sibling_order,r.identity_path,r.fields::text collate "C",r.children_kind) is distinct from (n->>'parent',(n->>'position')::integer,path,(n->'fields')::text collate "C",n->>'children_kind');
 end loop;
 update taskfold_private.child_task_projections set source_tree=view->'proposed_tree',state='ready',issue=null,revision=revision+1,structure_revision=structure_revision+1 where task_id=t.id and revision<9007199254740990 and structure_revision<9007199254740990;
 if not found then raise exception using errcode='PT409',message='This saved snapshot needs recovery review';end if;
 insert into taskfold_private.child_task_record_authority(task_id,task_generation,project_id,root_kind) values(t.id,t.task_generation,t.project_id,case when view->'proposed_tree'='null'::jsonb then 'null' else 'array' end)
 on conflict(task_id) do update set root_kind=excluded.root_kind;
 if taskfold_private.materialize_child_task_records(t.id,case when view->'proposed_tree'='null'::jsonb then 'null' else 'array' end)::text collate "C" is distinct from (view->'proposed_tree')::text collate "C" then raise exception using errcode='PT409',message='This copy could not be staged';end if;
 if team is not null then insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,t.project_id,t.id,t.task_generation,a,'patch',q);end if;
 insert into taskfold_private.child_task_repairs(actor_id,request_id,fingerprint,state,task_id,task_generation,project_id,workspace_id,team_id,review_digest,repair_digest,archive_id,archive_digest,archive_bytes,node_count)
 values(a,q,encode(sha256(convert_to(b::text,'UTF8')),'hex'),'applied',t.id,t.task_generation,t.project_id,team,team,b->>'review_digest',b->>'repair_digest',archive_id,digest,bytes,(view->>'node_count')::integer) returning * into receipt;
 return taskfold_private.child_repair_reply(receipt,false)||jsonb_build_object('_copy_mirror',view->'proposed_tree');
end$$;
create function taskfold_private.finish_child_copy_choice(b jsonb,tree jsonb) returns void
language plpgsql volatile security definer set search_path='' as $$declare t public.tasks;begin
 perform taskfold_private.team_actor();t:=taskfold_private.child_adoption_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,true);
 if t.project_id is distinct from (b->>'project_id')::uuid or coalesce(t.subtasks,'null'::jsonb)::text collate "C" is distinct from tree::text collate "C" then raise exception using errcode='PT409',message='This copy could not be confirmed';end if;
 delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=t.id and actor_id=auth.uid() and request_id=(b->>'request_id')::uuid;
end$$;
alter function public.taskfold_repair_children(text,jsonb) rename to taskfold_repair_children_before_copy_choice;
revoke all on function public.taskfold_repair_children_before_copy_choice(text,jsonb) from public,anon,authenticated,service_role;
alter function public.taskfold_repair_children_before_copy_choice(text,jsonb) set schema taskfold_private;
create function public.taskfold_repair_children(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;proof jsonb;delivery jsonb;affected integer;begin
 if jsonb_typeof(_body->'changes') is distinct from 'array' or not exists(select 1 from jsonb_array_elements(_body->'changes') c where c->>'kind'='choose_copy') then return taskfold_private.taskfold_repair_children_before_copy_choice(_operation,_body);end if;
 if _operation='send' then
  reply:=taskfold_private.commit_child_repair('check',_body);
  if reply->>'state'='unknown' then proof:=public.taskfold_preview_child_repair(_body-array['request_id','repair_digest']);if proof->>'repair_digest'<>_body->>'repair_digest' then raise exception using errcode='PT409',message='Review this saved-copy choice again';end if;end if;
 end if;
 reply:=taskfold_private.commit_child_repair(_operation,_body);
 if reply ? '_copy_mirror' then
  -- The actual UPDATE runs as the caller: restrictive/future UPDATE policies
  -- can reject it, rolling back the staged records, original and receipt.
  update public.tasks set subtasks=reply->'_copy_mirror' where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid;
  get diagnostics affected=row_count;if affected<>1 then raise exception using errcode='42501',message='Editing access changed; all copies are unchanged';end if;
  perform taskfold_private.finish_child_copy_choice(_body,reply->'_copy_mirror');reply:=reply-'_copy_mirror';
  if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='Read access changed; all copies are unchanged';end if;
  delivery:=taskfold_private.commit_child_repair('original',_body);
 end if;
 if _operation='original' then delivery:=reply;end if;
 if delivery is not null then
  if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
  if exists(select 1 from jsonb_array_elements(delivery->'original'->'root_history') e where not exists(select 1 from public.task_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e)) or exists(select 1 from jsonb_array_elements(delivery->'original'->'child_history') e where not exists(select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e)) then raise exception using errcode='42501',message='Original history access changed';end if;
 end if;
 return reply;
end$$;
revoke all on function taskfold_private.child_copy_history(uuid),taskfold_private.child_copy_history_digest(uuid),taskfold_private.preview_child_copy_choice(jsonb),taskfold_private.preview_child_repair(jsonb),taskfold_private.commit_child_repair(text,jsonb),taskfold_private.finish_child_copy_choice(jsonb,jsonb),public.taskfold_preview_child_repair(jsonb),public.taskfold_repair_children(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_copy_history_digest(uuid),taskfold_private.preview_child_copy_choice(jsonb),taskfold_private.preview_child_repair(jsonb),taskfold_private.commit_child_repair(text,jsonb),taskfold_private.finish_child_copy_choice(jsonb,jsonb),public.taskfold_preview_child_repair(jsonb),public.taskfold_repair_children(text,jsonb) to authenticated;

-- A narrow transaction proof admits only this reviewed mirror patch through
-- existing UPDATE RLS. Ordinary team inserts/updates/deletes remain closed.
create function taskfold_private.child_copy_update_admitted(t public.tasks,checking boolean) returns boolean
language plpgsql stable security definer set search_path='' as $$begin
 if auth.uid() is null or not exists(select 1 from taskfold_private.child_task_record_config where singleton and copy_reconciliation_enabled and repair_writes_enabled) then return false;end if;
 return exists(select 1 from taskfold_private.team_task_edit_scope s
  join taskfold_private.child_task_repairs r on r.actor_id=s.actor_id and r.request_id=s.request_id and r.task_id=s.task_id and r.task_generation is not distinct from s.generation and r.project_id=s.project_id and r.team_id=s.team_id and r.state='applied'
  join taskfold_private.child_task_repair_originals o on o.id=r.archive_id and o.actor_id=s.actor_id and o.team_id=s.team_id and o.owner_id is null
  join taskfold_private.child_task_projections p on p.task_id=s.task_id and p.task_generation is not distinct from s.generation and p.state='ready'
  join taskfold_private.teams team on team.id=s.team_id and team.state='active'
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.operation='patch' and s.task_id=t.id and s.generation is not distinct from t.task_generation and s.project_id=t.project_id
   and o.original->'copy_choice'->>'kind'='choose_copy' and (to_jsonb(t)-'subtasks')::text collate "C"=((o.original->'root')-'subtasks')::text collate "C"
   and coalesce(taskfold_private.team_project_role(auth.uid(),t.project_id),'') in('manager','editor')
   and case when checking then coalesce(t.subtasks,'null'::jsonb)::text collate "C"=p.source_tree::text collate "C" else coalesce(t.subtasks,'null'::jsonb)::text collate "C"=coalesce(o.original->'root'->'subtasks','null'::jsonb)::text collate "C" end);
end$$;
revoke all on function taskfold_private.child_copy_update_admitted(public.tasks,boolean) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_copy_update_admitted(public.tasks,boolean) to authenticated;
do $$declare p record;begin
 -- Preserve both existing predicates verbatim. No fallback/grant is installed
 -- if the inspected canonical UPDATE policies are missing or changed in kind.
 for p in select polname,pg_get_expr(polqual,polrelid) qual,pg_get_expr(polwithcheck,polrelid) checked from pg_policy where polrelid='public.tasks'::regclass and polcmd='w' and ((polname='Users can update accessible tasks' and polpermissive) or (polname='team_native_update_closed' and not polpermissive)) loop
  execute format('alter policy %I on public.tasks using((%s) or taskfold_private.child_copy_update_admitted(tasks,false)) with check((%s) or taskfold_private.child_copy_update_admitted(tasks,true))',p.polname,p.qual,coalesce(p.checked,p.qual));
 end loop;
 if (select count(*) from pg_policy where polrelid='public.tasks'::regclass and polcmd='w' and ((polname='Users can update accessible tasks' and polpermissive) or (polname='team_native_update_closed' and not polpermissive)))<>2 then raise exception using errcode='PT409',message='Review the current task update policies before installing copy reconciliation';end if;
end$$;

grant execute on function taskfold_private.taskfold_preview_child_repair_before_copy_choice(jsonb),taskfold_private.taskfold_repair_children_before_copy_choice(text,jsonb) to authenticated;
