-- Explicit history mapping, still disabled. No automatic migration/backfill.
alter table taskfold_private.child_task_record_config add column mapping_reconciliation_enabled boolean not null default false;

-- Reuse the versioned context column rather than adding a nullable column to
-- archived historical rows: their exact original JSON and digests stay valid.
create function taskfold_private.valid_child_reconciliation(value jsonb) returns boolean
language plpgsql immutable security invoker set search_path='' as $$
declare s jsonb;seen text[]:='{}';key text;begin
 if value is null or jsonb_typeof(value)<>'object' or octet_length(value::text)>4000000
  or not value ?& array['version','request_id','archive_id','subjects'] or value-array['version','request_id','archive_id','subjects']<>'{}'
  or value->'version'<>'1'::jsonb or jsonb_typeof(value->'subjects')<>'array' or jsonb_array_length(value->'subjects')>12000
  or coalesce(value->>'request_id','')!~'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
  or coalesce(value->>'archive_id','')!~'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' then return false;end if;
 for s in select * from jsonb_array_elements(value->'subjects') loop
  if jsonb_typeof(s)<>'object' or not s ?& array['node_key','reset_completion','retired'] or s-array['node_key','reset_completion','retired']<>'{}'
   or jsonb_typeof(s->'node_key')<>'string' or s->'reset_completion' is distinct from 'true'::jsonb or jsonb_typeof(s->'retired')<>'boolean' then return false;end if;
  key:=s->>'node_key';if length(key) not between 1 and 400 or btrim(key)='' or key~'[[:cntrl:]]' or normalize(key,NFC) collate "C"<>key collate "C" or key=any(seen) then return false;end if;
  seen:=array_append(seen,key);
 end loop;return true;
end$$;
alter table public.task_node_activity drop constraint task_node_activity_format_version_check;
alter table public.task_node_activity add constraint task_node_activity_format_version_check check(format_version in(1,2,3,4));
alter table public.task_node_activity drop constraint task_node_activity_kinds_check;
alter table public.task_node_activity add constraint task_node_activity_kinds_check check(cardinality(kinds)>0 and kinds<@array['created','completed','reopened','completion_time','moved','rescheduled','deleted','scope_changed','type_changed','coverage_gap','edited','reordered','reconciled']::text[]);
-- Keep previous version contracts verbatim; only v4 admits reconciliation.
do $$declare d text;begin
 select pg_get_constraintdef(oid) into strict d from pg_constraint where conrelid='public.task_node_activity'::regclass and conname='task_node_activity_field_details_check';
 execute 'alter table public.task_node_activity drop constraint task_node_activity_field_details_check';
 execute 'alter table public.task_node_activity add constraint task_node_activity_field_details_check check ((format_version<>4 and not(''reconciled''=any(kinds)) and '||substring(d from 7)||') or (format_version=4 and changed_fields=''{}'' and kinds=array[''reconciled''] and taskfold_private.valid_child_reconciliation(order_context)))';
 select pg_get_constraintdef(oid) into strict d from pg_constraint where conrelid='public.task_node_activity'::regclass and conname='task_node_activity_subject_check';
 execute 'alter table public.task_node_activity drop constraint task_node_activity_subject_check';
 execute 'alter table public.task_node_activity add constraint task_node_activity_subject_check check ((format_version<>4 and '||substring(d from 7)||') or (format_version=4 and task_generation is not null and node_key='''' and before_path=''{}'' and after_path=''{}'' and before_state<>''{}'' and after_state<>''{}'' and not work_before and not work_after and type_before is null and type_after is null and completion_version=0 and recorded_at=effective_at and transfer_context is null))';
end$$;

create function taskfold_private.prepare_child_copy_mapping(root public.tasks,selected jsonb,stored jsonb,mapping jsonb,seed text,history text[],people uuid[]) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare p jsonb;tree jsonb;old_nodes jsonb:='{}';new_nodes jsonb;n jsonb;o jsonb;summary jsonb:='[]';subjects jsonb:='[]';candidate public.tasks;path text[];target_ref text;reset boolean;locations jsonb;v jsonb;all_keys text[];new_keys text[];old_decoded jsonb;old_fields jsonb;
begin
 p:=taskfold_private.plan_child_copy_mapping(root,selected,stored,mapping,seed,history,people);tree:=p->'proposed_tree';candidate:=root;candidate.subtasks:=tree;
 new_nodes:=taskfold_private.node_activity_nodes(candidate);old_decoded:=taskfold_private.decode_child_task_tree(coalesce(root.subtasks,'null'::jsonb));
 begin old_nodes:=taskfold_private.node_activity_nodes(root);exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range or raise_exception then old_nodes:='{}';end;
 if (select count(*)<>count(distinct normalize(e.value->>'key',NFC) collate "C") from jsonb_each(old_nodes) e) then old_nodes:='{}';end if;
 with recursive walk(node,location) as (
  select x.n,array[(x.pos-1)::text] from jsonb_array_elements(case when tree='null'::jsonb then '[]'::jsonb else tree end) with ordinality x(n,pos)
  union all select x.n,w.location||array['subtasks',(x.pos-1)::text] from walk w cross join lateral jsonb_array_elements(case when jsonb_typeof(w.node->'subtasks')='array' then w.node->'subtasks' else '[]'::jsonb end) with ordinality x(n,pos)
 ) select coalesce(jsonb_object_agg(normalize(node->>'id',NFC),to_jsonb(w.location)),'{}') into locations from walk w;
 for v in select * from jsonb_array_elements(p->'nodes') loop
  target_ref:=v->>'target_key';select e.value into n from jsonb_each(new_nodes) e where normalize(e.value->>'key',NFC) collate "C"=target_ref collate "C";
  select e.value into o from jsonb_each(old_nodes) e where normalize(e.value->>'key',NFC) collate "C"=target_ref collate "C";
  path:=array(select jsonb_array_elements_text(locations->target_ref));
  select j.value->'fields' into old_fields from jsonb_array_elements(old_decoded->'nodes') j(value) where j.value->>'key' collate "C"=target_ref collate "C";
  reset:=(v->>'reset_completion')::boolean or o is null or exists(select 1 from unnest(array['completed','completed_at','recurrence_parent_id']) f where o->'state'->f is distinct from n->'state'->f) or o->'revision' is distinct from n->'revision' or o->'type' is distinct from n->'type' or o->'work' is distinct from n->'work' or old_fields->'taskfold_completion_v1' is distinct from (tree#>path)->'taskfold_completion_v1' or old_fields->'completion_version' is distinct from (tree#>path)->'completion_version';
  -- The old root is a third history authority: retaining stored lifecycle must
  -- also reset when that lifecycle differs from the last observable root.
  if reset then
   path:=array(select jsonb_array_elements_text(locations->target_ref));
   tree:=jsonb_set(tree,path,(tree#>path)||jsonb_build_object('completion_version',0,'taskfold_completion_v1',jsonb_build_object('epoch',md5(seed||':'||target_ref||':reconciliation')::uuid,'version',0)),false);
   subjects:=subjects||jsonb_build_array(jsonb_build_object('node_key',target_ref,'reset_completion',true,'retired',false));
  end if;
  summary:=summary||jsonb_build_array(v||jsonb_build_object('reset_completion',reset));
 end loop;
 new_keys:=array(select j.value->>'target_key' from jsonb_array_elements(summary) j(value));
 all_keys:=array(select distinct normalize(k,NFC) collate "C" from (
  select j.value->'fields'->>'id' k from jsonb_array_elements(stored) j(value) union select e.value->>'key' from jsonb_each(old_nodes) e union select h from unnest(history) h
 ) x where k is not null and k<>'');
 foreach target_ref in array all_keys loop
  if not target_ref=any(new_keys) then subjects:=subjects||jsonb_build_array(jsonb_build_object('node_key',target_ref,'reset_completion',true,'retired',true));end if;
 end loop;
 return p||jsonb_build_object('proposed_tree',tree,'nodes',summary,'subjects',subjects,'reset_completion_count',(select count(*) from jsonb_array_elements(summary) j(value) where j.value->'reset_completion'='true'::jsonb));
end$$;

-- Private, transaction-bound proof; no user-settable settings or caller grant.
create table taskfold_private.child_mapping_scope (
 transaction_id bigint not null,actor_id uuid not null,task_id uuid not null,generation uuid not null,request_id uuid not null,archive_id uuid not null,
 proposed_tree jsonb not null,context jsonb not null check(taskfold_private.valid_child_reconciliation(context)),consumed boolean not null default false,
 primary key(transaction_id,task_id)
);
alter table taskfold_private.child_mapping_scope enable row level security;
revoke all on taskfold_private.child_mapping_scope from public,anon,authenticated,service_role;
create function taskfold_private.capture_child_mapping(prior public.tasks,current_row public.tasks) returns boolean
language plpgsql volatile security invoker set search_path='' as $$
declare s taskfold_private.child_mapping_scope;o taskfold_private.child_task_repair_originals;r taskfold_private.child_task_repairs;instant timestamptz:=statement_timestamp();begin
 select * into s from taskfold_private.child_mapping_scope where transaction_id=txid_current() and task_id=current_row.id for update;
 if not found then return false;end if;
 select * into o from taskfold_private.child_task_repair_originals where id=s.archive_id;
 select * into r from taskfold_private.child_task_repairs where actor_id=s.actor_id and request_id=s.request_id;
 if s.consumed or auth.uid() is distinct from s.actor_id or current_row.task_generation is distinct from s.generation or prior.task_generation is distinct from s.generation
  or o.id is null or r.archive_id is distinct from s.archive_id or r.state<>'applied' or r.task_id<>current_row.id or r.task_generation is distinct from s.generation
  or (o.original->'root')::text collate "C" is distinct from to_jsonb(prior)::text collate "C" or (to_jsonb(current_row)-'subtasks')::text collate "C" is distinct from (to_jsonb(prior)-'subtasks')::text collate "C"
  or coalesce(current_row.subtasks,'null'::jsonb)::text collate "C" is distinct from s.proposed_tree::text collate "C"
  or o.original->'copy_choice'->'mapping' is null or o.original->'mapping_context' is distinct from s.context
  or o.digest<>encode(sha256(convert_to(o.original::text,'UTF8')),'hex') or o.bytes<>octet_length(o.original::text) then raise exception using errcode='PT409',message='This reconciliation proof changed; all copies stay unchanged';end if;
 insert into public.task_node_activity(format_version,order_context,user_id,task_id,task_generation,node_key,before_path,after_path,actor_id,effective_at,completion_version,type_before,type_after,work_before,work_after,kinds,before_state,after_state)
 values(4,s.context,current_row.user_id,current_row.id,current_row.task_generation,'','{}','{}',s.actor_id,instant,0,null,null,false,false,array['reconciled'],taskfold_private.activity_state(prior),taskfold_private.activity_state(current_row));
 update taskfold_private.child_mapping_scope set consumed=true where transaction_id=s.transaction_id and task_id=s.task_id;
 return true;
end$$;

-- Ordinary activity capture is unchanged outside the verified private scope.
create or replace function taskfold_private.capture_task_node_activity()
returns trigger language plpgsql security definer set search_path='' as $$
declare caller uuid:=auth.uid();t public.tasks;prior jsonb:='{}';current_nodes jsonb:='{}';b jsonb;a jsonb;o jsonb;n jsonb;key text;kinds text[];instant timestamptz:=statement_timestamp();effective timestamptz;old_path text[];new_path text[];generation uuid;record_owner uuid;failed boolean:=false;changed text[];ordering record;
begin
 if tg_table_schema<>'public' or tg_table_name<>'tasks' then raise exception 'Invalid child activity source';end if;
 if tg_op='INSERT' then t:=new;else t:=old;end if;
 if not exists(select 1 from auth.users where id=t.user_id) and not taskfold_private.is_team_content_task(t.id) and not taskfold_private.is_team_content_project(t.project_id) then if tg_op='DELETE' then return old;else return new;end if;end if;
 if caller is not null and not exists(select 1 from auth.users where id=caller) then raise exception 'Activity actor is no longer available';end if;
 if tg_op='UPDATE' and taskfold_private.capture_child_mapping(old,new) then return new;end if;
 if tg_op='UPDATE' and old.subtasks is not distinct from new.subtasks and old.is_heading is not distinct from new.is_heading
  and old.project_id is not distinct from new.project_id and old.section_id is not distinct from new.section_id and old.task_generation is not distinct from new.task_generation then return new;end if;
 begin
  if tg_op<>'INSERT' then prior:=taskfold_private.node_activity_nodes(old);end if;
  if tg_op<>'DELETE' then current_nodes:=taskfold_private.node_activity_nodes(new);end if;
 exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range or raise_exception then failed:=true;
 end;
 if failed then
  b:='{}';a:='{}';
  if tg_op<>'INSERT' then b:=taskfold_private.activity_state(old);end if;
  if tg_op<>'DELETE' then a:=taskfold_private.activity_state(new);end if;
  insert into public.task_node_activity(user_id,task_id,task_generation,node_key,before_path,after_path,actor_id,effective_at,completion_version,type_before,type_after,work_before,work_after,kinds,before_state,after_state)
  values(case when tg_op='DELETE' then old.user_id else new.user_id end,t.id,t.task_generation,'','{}','{}',caller,instant,0,null,null,false,false,array['coverage_gap'],b,a);
  if tg_op='DELETE' then return old;else return new;end if;
 end if;
 for key in select k from (select jsonb_object_keys(prior) k union select jsonb_object_keys(current_nodes) k) x order by k loop
  o:=prior->key;n:=current_nodes->key;b:=coalesce(o->'state','{}');a:=coalesce(n->'state','{}');kinds:='{}';
  old_path:=array(select jsonb_array_elements_text(coalesce(o->'path','[]')));new_path:=array(select jsonb_array_elements_text(coalesce(n->'path','[]')));
  if o is null then kinds:=array['created'];elsif n is null then kinds:=array['deleted'];else
   if b->'completed' is distinct from a->'completed' then kinds:=array_append(kinds,case when a->'completed'='true'::jsonb then 'completed' else 'reopened' end);
   elsif b->'completed_at' is distinct from a->'completed_at' then kinds:=array_append(kinds,'completion_time');end if;
   if b->'project_id' is distinct from a->'project_id' or b->'section_id' is distinct from a->'section_id' or old_path<>new_path then kinds:=array_append(kinds,'moved');end if;
   if b-array['project_id','section_id','completed','completed_at','recurrence_parent_id'] is distinct from a-array['project_id','section_id','completed','completed_at','recurrence_parent_id'] then kinds:=array_append(kinds,'rescheduled');end if;
   if o->'type' is distinct from n->'type' then kinds:=array_append(kinds,'type_changed');elsif o->'work' is distinct from n->'work' then kinds:=array_append(kinds,'scope_changed');end if;
  end if;
  changed:='{}';
  if o is not null and n is not null then
   select coalesce(array_agg(field order by field),'{}') into changed
   from (select jsonb_object_keys(coalesce(o->'edit_state','{}')||coalesce(n->'edit_state','{}')) field) fields
   where o->'edit_state'->field is distinct from n->'edit_state'->field;
   if cardinality(changed)>0 then kinds:=array_append(kinds,'edited');end if;
  end if;
  if cardinality(kinds)=0 then continue;end if;
  effective:=instant;if 'completed'=any(kinds) and a->>'completed_at' is not null then effective:=(a->>'completed_at')::timestamptz;end if;
  generation:=(coalesce(n,o)->>'generation')::uuid;record_owner:=case when n is null then old.user_id else new.user_id end;
  insert into public.task_node_activity(format_version,changed_fields,user_id,task_id,task_generation,node_key,before_path,after_path,actor_id,effective_at,completion_version,type_before,type_after,work_before,work_after,kinds,before_state,after_state)
   values(case when cardinality(changed)>0 then 2 else 1 end,changed,record_owner,t.id,generation,coalesce(n,o)->>'key',old_path,new_path,caller,effective,(coalesce(n,o)->>'revision')::bigint,o->>'type',n->>'type',coalesce((o->>'work')::boolean,false),coalesce((n->>'work')::boolean,false),kinds,b,a);
 end loop;
 if tg_op='UPDATE' then
  for ordering in select * from taskfold_private.node_activity_order_changes(prior,current_nodes) loop
   insert into public.task_node_activity(format_version,order_context,user_id,task_id,task_generation,node_key,before_path,after_path,actor_id,effective_at,completion_version,type_before,type_after,work_before,work_after,kinds,before_state,after_state)
   values(3,jsonb_build_object('before',ordering.old_order,'after',ordering.new_order),new.user_id,new.id,coalesce(new.task_generation,'00000000-0000-0000-0000-000000000000'),
    coalesce(ordering.old_path[cardinality(ordering.old_path)],''),ordering.old_path,ordering.new_path,caller,instant,0,null,null,false,false,array['reordered'],taskfold_private.activity_state(old),taskfold_private.activity_state(new));
  end loop;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;

alter function taskfold_private.preview_child_copy_choice(jsonb) rename to preview_child_copy_choice_before_mapping;
revoke all on function taskfold_private.preview_child_copy_choice_before_mapping(jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.preview_child_copy_choice(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare copies jsonb;choice jsonb;tree jsonb;decoded jsonb;old_nodes jsonb;root_id uuid;t public.tasks;blocker text;source text;may_write boolean;history jsonb;digest text;proposed_root public.tasks;plan jsonb;refs text[];people uuid[];candidates uuid[];team uuid;
begin
 if not coalesce(b->'changes'->0 ? 'mapping',false) then return taskfold_private.preview_child_copy_choice_before_mapping(b);end if;
 if jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>600000 or not b ?& array['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes'))
  or jsonb_typeof(b->'changes') is distinct from 'array' or jsonb_array_length(b->'changes')<>1 then raise exception using errcode='22023',message='Choose one complete saved copy';end if;
 choice:=b->'changes'->0;
 if jsonb_typeof(choice) is distinct from 'object' or not choice ?& array['kind','path','source','copy_digest','mapping'] or exists(select 1 from jsonb_object_keys(choice) k where k not in('kind','path','source','copy_digest','mapping'))
  or choice->'kind' is distinct from '"choose_copy"'::jsonb or choice->'path' is distinct from '[]'::jsonb or jsonb_typeof(choice->'source') is distinct from 'string'
  or choice->>'source' not in('task','projection','records') or jsonb_typeof(choice->'copy_digest') is distinct from 'string' or (choice->>'copy_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the selected saved copy';end if;
 copies:=taskfold_private.review_child_copies(b-'changes');
 if copies->>'copy_digest'<>choice->>'copy_digest' then raise exception using errcode='PT409',message='The saved copies changed; compare them again';end if;
 root_id:=(b->>'task_id')::uuid;select * into t from public.tasks where id=root_id;
 source:=choice->>'source';tree:=copies->(case source when 'task' then 'task_tree' when 'projection' then 'projection_tree' else 'record_tree' end);
 if copies->'export_bundle'->'omitted'<>'[]'::jsonb or exists(select 1 from jsonb_array_elements(copies->'copies') c where c->>'state' in('unavailable','absent')) then blocker:='indexed_custody';end if;
 if not exists(select 1 from jsonb_array_elements(copies->'copies') c where c->>'id'=source and c->>'state'='ready') then raise exception using errcode='PT409',message='This copy needs a format or access review';end if;
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
 may_write:=blocker is null and exists(select 1 from taskfold_private.child_task_record_config where singleton and mapping_reconciliation_enabled and copy_reconciliation_enabled and repair_writes_enabled and repair_reviews_enabled and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled)
  and ((b->>'workspace_id') is null or (coalesce(taskfold_private.team_project_role(auth.uid(),t.project_id),'') in('manager','editor') and exists(select 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled and native_task_types_enabled)))
  and (t.project_id is null or exists(select 1 from public.projects where id=t.project_id and not is_archived and not ancestor_archived));
 digest:=encode(sha256(convert_to(jsonb_build_object('choice',b,'copies',copies->'copy_digest','history',history,'proposed',tree)::text,'UTF8')),'hex');
 return (b-'changes')||jsonb_build_object('repair_digest',digest,'original_tree',coalesce(t.subtasks,'null'::jsonb),'original_sql_null',t.subtasks is null,'changes',b->'changes',
  'proposal_valid',true,'remaining_issue',null,'node_count',jsonb_array_length(decoded->'nodes'),'proposed_tree',tree,
  'steps',jsonb_build_array(jsonb_build_object('ordinal',1,'kind','choose_copy','path','[]'::jsonb,'before_kind',jsonb_typeof(coalesce(t.subtasks,'null'::jsonb)),'after_kind',jsonb_typeof(tree))),
  'custody_blocker',blocker,'mutation_available',may_write,'mapping_plan',plan-'proposed_tree');
end$$;

create or replace function taskfold_private.commit_child_repair_before_history_access(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();q uuid;root_id uuid;generation uuid;pid uuid;team uuid;fingerprint text;prior taskfold_private.child_task_repairs;
 t public.tasks;view jsonb;original jsonb;archive_id uuid;archive_digest text;archive_bytes integer;revision bigint;status text;current_workspace uuid;
begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(actor::text,73918));perform taskfold_private.team_actor();
 if operation is null or operation not in('send','check','close','original') or jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>(case when jsonb_typeof(b->'changes')='array' and jsonb_array_length(b->'changes')=1 and b->'changes'->0->>'kind'='choose_copy' and jsonb_typeof(b->'changes'->0->'mapping')='object' then 600000 else 70000 end)
  or b->'protocol' is distinct from '1'::jsonb or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest','repair_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest','repair_digest','changes'))
  or jsonb_typeof(b->'changes') is distinct from 'array' or jsonb_array_length(b->'changes') not between 1 and 64 or octet_length((b->'changes')::text)>(case when jsonb_array_length(b->'changes')=1 and b->'changes'->0->>'kind'='choose_copy' and jsonb_typeof(b->'changes'->0->'mapping')='object' then 550000 else 65536 end) then
  raise exception using errcode='22023',message='Review this saved repair request';end if;
 if taskfold_private.team_uuid(b,'account')<>actor then raise exception using errcode='42501',message='This repair belongs to another account';end if;
 q:=taskfold_private.team_uuid(b,'request_id');root_id:=taskfold_private.team_uuid(b,'task_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if b->'workspace_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'workspace_id');end if;
 if jsonb_typeof(b->'review_digest') is distinct from 'string' or (b->>'review_digest')!~'^[a-f0-9]{64}$'
  or jsonb_typeof(b->'repair_digest') is distinct from 'string' or (b->>'repair_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the current repair proposal';end if;
 generation:=(b->>'task_generation')::uuid;pid:=(b->>'project_id')::uuid;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(actor::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 select * into prior from taskfold_private.child_task_repairs where actor_id=actor and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This repair identity was already used';end if;
  if operation<>'original' then return taskfold_private.child_repair_reply(prior,true);end if;
  if prior.state<>'applied' then raise exception using errcode='PT409',message='This repair has no saved original';end if;
  -- Content recovery requires current access to the same root and realm. Only
  -- contentless receipt recovery survives deletion or access loss.
  t:=taskfold_private.child_adoption_root(root_id,generation,false);
  select team_id into current_workspace from taskfold_private.team_content_projects where project_id=t.project_id;
  if t.project_id is distinct from pid or current_workspace is distinct from prior.workspace_id then raise exception using errcode='42501',message='The original belongs to another task context';end if;
  select o.original into original from taskfold_private.child_task_repair_originals o where o.id=prior.archive_id
   and o.task_id=root_id and o.task_generation is not distinct from generation and o.project_id is not distinct from pid
   and o.team_id is not distinct from prior.workspace_id and (o.team_id is not null or o.owner_id=actor);
  if original is null then raise exception using errcode='42501',message='This original is unavailable';end if;
  if octet_length(original::text)<>prior.archive_bytes or encode(extensions.digest(convert_to(original::text,'UTF8'),'sha256'),'hex')<>prior.archive_digest then raise exception using errcode='PT409',message='This saved original needs recovery review';end if;
  perform taskfold_private.team_actor();
  return jsonb_build_object('protocol',1,'account',actor,'request_id',q,'archive_id',prior.archive_id,'archive_digest',prior.archive_digest,'original',original);
 end if;
 if operation='check' then return jsonb_build_object('protocol',1,'account',actor,'request_id',q,'state','unknown');end if;
 if operation='original' then raise exception using errcode='PT409',message='This repair has not saved an original';end if;
 if (select count(*) from taskfold_private.child_task_repairs where actor_id=actor and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many repair decisions; try later';end if;
 if operation='close' then
  -- Claimed workspace IDs must not reserve a different actor's team nonce.
  insert into taskfold_private.child_task_repairs(actor_id,request_id,fingerprint,state,task_id,task_generation,project_id,workspace_id,review_digest,repair_digest)
   values(actor,q,fingerprint,'closed',root_id,generation,pid,(b->>'workspace_id')::uuid,b->>'review_digest',b->>'repair_digest') returning * into prior;
  return taskfold_private.child_repair_reply(prior,false);
 end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and repair_writes_enabled and repair_reviews_enabled and adoption_enabled
  and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Reviewed repairs are not enabled';end if;
 t:=taskfold_private.child_adoption_root(root_id,generation,true);
 view:=taskfold_private.preview_child_repair(b-'request_id'-'repair_digest');
 if view->>'repair_digest'<>b->>'repair_digest' or view->'proposal_valid'<>'true'::jsonb or view->'custody_blocker'<>'null'::jsonb then raise exception using errcode='PT409',message='This proposal needs another repair or custody review';end if;
 if taskfold_private.child_repair_history_conflict(t,b->'changes') then raise exception using errcode='PT409',message='These references need an explicit history custody review';end if;
 team:=(view->>'workspace_id')::uuid;
 if team is not null then
  if not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) then raise exception using errcode='55P03',message='Another workspace decision is finishing';end if;
  if not pg_try_advisory_xact_lock(hashtextextended(team::text,73928)) then raise exception using errcode='55P03',message='Another workspace original is being saved';end if;
 end if;
 original:=taskfold_private.child_repair_original_bounded(t,view->>'review_digest',view->>'repair_digest');
 archive_bytes:=octet_length(original::text);
 if archive_bytes>8000000 then raise exception using errcode='PT413',message='This original needs a larger-work archive';end if;
 if coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.actor_id=actor),0)+archive_bytes>64000000
  or (team is not null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.team_id=team),0)+archive_bytes>256000000) then
  raise exception using errcode='PT429',message='Original storage is full; keep this task unchanged';end if;
 archive_id:=gen_random_uuid();archive_digest:=encode(extensions.digest(convert_to(original::text,'UTF8'),'sha256'),'hex');
 insert into taskfold_private.child_task_repair_originals(id,actor_id,owner_id,team_id,task_id,task_generation,project_id,request_id,original,bytes,digest)
  values(archive_id,actor,case when team is null then actor else null end,team,root_id,generation,pid,q,original,archive_bytes,archive_digest);
 -- The original exists before the first source write. Any trigger, authority,
 -- receipt or caller-RLS failure rolls back the archive and all derived writes.
 if team is not null then
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
   values(txid_current(),team,pid,root_id,generation,actor,'patch',q);
 end if;
 update public.tasks set subtasks=view->'proposed_tree' where id=root_id returning * into t;
 if team is not null then delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=root_id;end if;
 if t.subtasks is distinct from view->'proposed_tree' then raise exception using errcode='PT409',message='This repair could not be confirmed';end if;
 status:=taskfold_private.adopt_child_task_records(root_id,generation,t.subtasks);
 if status<>'ready' then raise exception using errcode='PT409',message='The repaired hierarchy is not ready';end if;
 select p.revision into revision from taskfold_private.child_task_projections p where p.task_id=root_id;
 if taskfold_private.promote_child_task_records(root_id,generation,pid,revision,t.subtasks)<>'records' then raise exception using errcode='PT409',message='The repaired hierarchy could not be adopted';end if;
 perform taskfold_private.team_actor();
 insert into taskfold_private.child_task_repairs(actor_id,request_id,fingerprint,state,task_id,task_generation,project_id,workspace_id,team_id,review_digest,repair_digest,archive_id,archive_digest,archive_bytes,node_count)
  values(actor,q,fingerprint,'applied',root_id,generation,pid,team,team,b->>'review_digest',b->>'repair_digest',archive_id,archive_digest,archive_bytes,(view->>'node_count')::integer) returning * into prior;
 return taskfold_private.child_repair_reply(prior,false);
end$$;

alter function taskfold_private.commit_child_repair(text,jsonb) rename to commit_child_repair_before_mapping;
revoke all on function taskfold_private.commit_child_repair_before_mapping(text,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.commit_child_repair(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();prior jsonb;t public.tasks;view jsonb;copies jsonb;original jsonb;archive_id uuid;digest text;bytes integer;team uuid;q uuid;n jsonb;path text[];saved jsonb;receipt taskfold_private.child_task_repairs;context jsonb;
begin
 if not coalesce(b->'changes'->0 ? 'mapping',false) then return taskfold_private.commit_child_repair_before_mapping(operation,b);end if;
 if operation is null or operation not in('send','check','close','original') then raise exception using errcode='22023',message='Choose a supported repair action';end if;
 if jsonb_typeof(b->'changes') is distinct from 'array' or not exists(select 1 from jsonb_array_elements(b->'changes') c where c->>'kind'='choose_copy') then return taskfold_private.commit_child_repair_before_copy_choice(operation,b);end if;
 -- Existing validation, actor/session/nonce locks and replay semantics remain.
 prior:=taskfold_private.commit_child_repair_before_mapping('check',b);
 if operation<>'send' or prior->>'state'<>'unknown' then return taskfold_private.commit_child_repair_before_mapping(operation,b);end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and mapping_reconciliation_enabled and copy_reconciliation_enabled and repair_writes_enabled and repair_reviews_enabled and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Saved-copy reconciliation is not enabled';end if;
 t:=taskfold_private.child_adoption_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,true);
 view:=taskfold_private.preview_child_copy_choice(b-'request_id'-'repair_digest');
 if view->>'repair_digest'<>b->>'repair_digest' or view->'custody_blocker'<>'null'::jsonb or view->'mutation_available'<>'true'::jsonb then raise exception using errcode='PT409',message='Review this copy and its history before saving';end if;
 q:=(b->>'request_id')::uuid;team:=(b->>'workspace_id')::uuid;
 if team is not null and (not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) or not pg_try_advisory_xact_lock(hashtextextended(team::text,73928))) then raise exception using errcode='55P03',message='Another workspace decision is finishing';end if;
 if (select count(*) from taskfold_private.child_task_repairs where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many repair decisions; try later';end if;
 if team is null and not pg_try_advisory_xact_lock(hashtextextended(t.user_id::text,73918)) then raise exception using errcode='55P03',message='Another original-owner decision is finishing';end if;
 copies:=taskfold_private.review_child_copies(b-array['request_id','repair_digest','changes']);
 archive_id:=gen_random_uuid();context:=jsonb_build_object('version',1,'request_id',q,'archive_id',archive_id,'subjects',view->'mapping_plan'->'subjects');
 original:=jsonb_build_object('protocol',1,'root',copies->'export_bundle'->'root','subtasks_sql_null',copies->'export_bundle'->'subtasks_sql_null','projection',copies->'export_bundle'->'projection','records',copies->'export_bundle'->'records','authority',copies->'export_bundle'->'authority','review_digest',b->'review_digest','repair_digest',b->'repair_digest','copy_choice',b->'changes'->0,'mapping_context',context)||taskfold_private.child_copy_history(t.id);
 if encode(sha256(convert_to(jsonb_build_object('choice',b-array['request_id','repair_digest'],'copies',copies->'copy_digest','history',jsonb_build_object('root_history',original->'root_history','child_history',original->'child_history'),'proposed',view->'proposed_tree')::text,'UTF8')),'hex')<>b->>'repair_digest' then raise exception using errcode='PT409',message='History changed before the archive was saved; review again';end if;
 bytes:=octet_length(original::text);
 if bytes>8000000 then raise exception using errcode='PT413',message='This original needs a larger-work archive';end if;
 if coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.actor_id=a),0)+bytes>64000000 or (team is null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.owner_id=t.user_id),0)+bytes>64000000) or (team is not null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.team_id=team),0)+bytes>256000000) then raise exception using errcode='PT429',message='Original storage is full; all copies stay unchanged';end if;
 digest:=encode(sha256(convert_to(original::text,'UTF8')),'hex');
 insert into taskfold_private.child_task_repair_originals(id,actor_id,owner_id,team_id,task_id,task_generation,project_id,request_id,original,bytes,digest)
 values(archive_id,a,case when team is null then t.user_id else null end,team,t.id,t.task_generation,t.project_id,q,original,bytes,digest);
 -- Explicit retirement removes only current projection records. Historical
 -- activity and the complete immutable originals remain in their old custody.
 delete from taskfold_private.child_task_records where task_id=t.id and node_key in(select jsonb_array_elements_text(view->'mapping_plan'->'retired'));
 -- Bound records retain their incarnations; only explicit new identities insert.

 for n in select * from jsonb_array_elements(taskfold_private.decode_child_task_tree(view->'proposed_tree')->'nodes') loop
  path:=array(select jsonb_array_elements_text(n->'path'));
  if exists(select 1 from taskfold_private.child_task_records r where r.task_id=t.id and r.node_key=n->>'key' and r.revision>=9007199254740990 and (r.parent_key,r.sibling_order,r.identity_path,r.fields::text collate "C",r.children_kind) is distinct from (n->>'parent',(n->>'position')::integer,path,(n->'fields')::text collate "C",n->>'children_kind')) then raise exception using errcode='PT409',message='This revision needs a recovery review';end if;
  if not exists(select 1 from taskfold_private.child_task_records where task_id=t.id and node_key=n->>'key') then
   insert into taskfold_private.child_task_records(task_id,node_key,parent_key,sibling_order,identity_path,fields,children_kind,field_versions)
   values(t.id,n->>'key',n->>'parent',(n->>'position')::integer,path,n->'fields',n->>'children_kind',(select coalesce(jsonb_object_agg(k,1),'{}') from jsonb_object_keys(n->'fields') k));
   continue;
  end if;
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
 insert into taskfold_private.child_mapping_scope(transaction_id,actor_id,task_id,generation,request_id,archive_id,proposed_tree,context) values(txid_current(),a,t.id,t.task_generation,q,archive_id,view->'proposed_tree',context);
 return taskfold_private.child_repair_reply(receipt,false)||jsonb_build_object('_copy_mirror',view->'proposed_tree');
end$$;

create or replace function taskfold_private.finish_child_copy_choice(b jsonb,tree jsonb) returns void
language plpgsql volatile security definer set search_path='' as $$declare t public.tasks;begin
 perform taskfold_private.team_actor();t:=taskfold_private.child_adoption_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,true);
 if t.project_id is distinct from (b->>'project_id')::uuid or coalesce(t.subtasks,'null'::jsonb)::text collate "C" is distinct from tree::text collate "C" then raise exception using errcode='PT409',message='This copy could not be confirmed';end if;
 if b->'changes'->0 ? 'mapping' then
  delete from taskfold_private.child_mapping_scope where transaction_id=txid_current() and actor_id=auth.uid() and task_id=t.id and request_id=(b->>'request_id')::uuid and consumed;
  if not found then raise exception using errcode='PT409',message='The reconciliation history could not be confirmed';end if;
 end if;
 delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=t.id and actor_id=auth.uid() and request_id=(b->>'request_id')::uuid;
end$$;
revoke all on function taskfold_private.valid_child_reconciliation(jsonb),taskfold_private.prepare_child_copy_mapping(public.tasks,jsonb,jsonb,jsonb,text,text[],uuid[]),taskfold_private.capture_child_mapping(public.tasks,public.tasks),taskfold_private.capture_task_node_activity(),taskfold_private.preview_child_copy_choice(jsonb),taskfold_private.commit_child_repair(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.preview_child_copy_choice(jsonb),taskfold_private.commit_child_repair(text,jsonb) to authenticated;
