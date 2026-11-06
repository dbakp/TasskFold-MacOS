-- Inspect before reconciling. No tree, row, history, receipt or custody writes.
create function taskfold_private.child_copy_summary(name text,tree jsonb,visibility text,reason text default null) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare decoded jsonb;count_nodes integer;depth integer;
begin
 if visibility<>'visible' then return jsonb_build_object('id',name,'state',visibility,'issue',reason,'node_count',null,'max_depth',null,'bytes',null);end if;
 decoded:=taskfold_private.decode_child_task_tree(tree);
 if decoded->>'state'='ready' then
  count_nodes:=jsonb_array_length(decoded->'nodes');select coalesce(max(jsonb_array_length(n->'path')),0) into depth from jsonb_array_elements(decoded->'nodes') n;
 end if;
 return jsonb_build_object('id',name,'state',decoded->>'state','issue',decoded->'issue','node_count',count_nodes,'max_depth',depth,'bytes',octet_length(tree::text));
end$$;
create function taskfold_private.review_child_copies(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();t public.tasks;p taskfold_private.child_task_projections;a taskfold_private.child_task_record_authority;
 review jsonb;rows jsonb;actual jsonb;task_tree jsonb;projection_tree jsonb;record_tree jsonb;kind text;materialized boolean:=false;
 generation uuid;root_id uuid;workspace uuid;project uuid;anchored boolean:=false;projection_readable boolean:=false;records_readable boolean:=false;
 summaries jsonb;bundle jsonb;omitted jsonb:='[]';digest text;state text;source text;total_rows integer;total_bytes bigint;
begin
 perform taskfold_private.team_actor();
 if jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>5000 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'))
  or jsonb_typeof(b->'review_digest') is distinct from 'string' or (b->>'review_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the current saved copies';end if;
 if taskfold_private.team_uuid(b,'account')<>actor then raise exception using errcode='42501',message='This review belongs to another account';end if;
 root_id:=taskfold_private.team_uuid(b,'task_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if b->'workspace_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'workspace_id');end if;
 generation:=(b->>'task_generation')::uuid;project:=(b->>'project_id')::uuid;workspace:=(b->>'workspace_id')::uuid;
 perform 1 from taskfold_private.child_task_record_config where singleton and adoption_enabled and repair_reviews_enabled and reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Saved-copy review is not enabled';end if;
 t:=taskfold_private.child_adoption_root(root_id,generation,false);review:=taskfold_private.child_adoption_snapshot(t);
 if t.project_id is distinct from project or (review->>'workspace_id')::uuid is distinct from workspace or review->>'review_digest'<>b->>'review_digest' then
  raise exception using errcode='PT409',message='These saved copies changed; review them again';end if;
 select * into p from taskfold_private.child_task_projections where task_id=root_id;
 select * into a from taskfold_private.child_task_record_authority where task_id=root_id;
 select count(*),coalesce(sum(octet_length(to_jsonb(r)::text)),0) into total_rows,total_bytes from taskfold_private.child_task_records r where task_id=root_id;
 if total_rows>1000 or total_bytes>4000000 or octet_length(coalesce(t.subtasks,'null')::text)>2000000
  or (p.task_id is not null and octet_length(p.source_tree::text)>2000000) then raise exception using errcode='PT413',message='These saved copies need a larger-work review';end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by node_key),'[]') into rows from taskfold_private.child_task_records r where task_id=root_id;
 task_tree:=coalesce(t.subtasks,'null'::jsonb);
 -- Authority was established by a trusted, reviewed promotion. A generation or
 -- project mismatch never borrows the current task's permissions for old data.
 anchored:=a.task_id is not null and p.task_id is not null and p.task_generation is not distinct from generation
  and a.task_generation is not distinct from generation and a.project_id is not distinct from project;
 if p.task_id is not null and p.task_generation is not distinct from generation then
  kind:=case when anchored then a.root_kind when p.source_tree='null'::jsonb then 'null' else 'array' end;
  begin actual:=taskfold_private.materialize_child_task_records(root_id,kind);materialized:=true;
  exception when sqlstate 'PT409' or sqlstate '54000' then materialized:=false;end;
  -- Without an authority anchor, reveal only content already present in the
  -- caller-readable task. Different unproven shadow content stays private.
  if a.task_id is null or anchored then
   projection_readable:=anchored or p.source_tree=task_tree;
   records_readable:=anchored or (materialized and actual=task_tree);
  end if;
 end if;
 if projection_readable then projection_tree:=p.source_tree;elsif p.task_id is not null then omitted:=omitted||jsonb_build_array('projection');end if;
 if records_readable and materialized then record_tree:=actual;end if;
 if not records_readable and total_rows>0 then omitted:=omitted||jsonb_build_array('records');end if;
 if a.task_id is not null and not anchored then omitted:=omitted||jsonb_build_array('authority');end if;
 source:=case when a.task_id is null then 'task' when anchored then 'records' else 'unavailable' end;
 summaries:=jsonb_build_array(taskfold_private.child_copy_summary('task',task_tree,'visible'),
  taskfold_private.child_copy_summary('projection',projection_tree,case when p.task_id is null then 'absent' when projection_readable then 'visible' else 'unavailable' end,case when not projection_readable and p.task_id is not null then 'access_review' end),
  case when records_readable and not materialized then jsonb_build_object('id','records','state','review','issue','record_shape','node_count',null,'max_depth',null,'bytes',total_bytes)
   else taskfold_private.child_copy_summary('records',record_tree,case when p.task_id is null and total_rows=0 then 'absent' when records_readable and materialized then 'visible' else 'unavailable' end,case when not records_readable and (p.task_id is not null or total_rows>0) then 'access_review' end) end);
 digest:=encode(sha256(convert_to(jsonb_build_object('protocol',1,'account',actor,'root',to_jsonb(t),'projection',case when p.task_id is null then null else to_jsonb(p) end,'records',rows,'authority',case when a.task_id is null then null else to_jsonb(a) end)::text,'UTF8')),'hex');
 state:=case when jsonb_array_length(omitted)>0 then 'limited' when p.task_id is null and total_rows=0 then 'single'
  when materialized and task_tree=projection_tree and task_tree=record_tree then 'aligned' else 'different' end;
 bundle:=jsonb_build_object('protocol',1,'kind','taskfold_saved_child_copies','account',actor,'task_id',root_id,'task_generation',generation,'project_id',project,'workspace_id',workspace,'review_digest',b->'review_digest','copy_digest',digest,
  'root',to_jsonb(t),'subtasks_sql_null',t.subtasks is null,'projection',case when projection_readable then to_jsonb(p) else null end,'records',case when records_readable then rows else '[]'::jsonb end,'authority',case when anchored then to_jsonb(a) else null end,'omitted',omitted);
 if octet_length(bundle::text)>8000000 then raise exception using errcode='PT413',message='These saved copies need a larger-work export';end if;
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',actor,'task_id',root_id,'task_generation',generation,'project_id',project,'workspace_id',workspace,'review_digest',b->'review_digest','copy_digest',digest,
  'state',state,'authoritative_source',source,'copies',summaries,'task_tree',task_tree,'projection_tree',projection_tree,'record_tree',record_tree,'export_bundle',bundle);
end$$;
create function public.taskfold_review_child_copies(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 reply:=taskfold_private.review_child_copies(_body);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return reply;
end$$;
revoke all on function taskfold_private.child_copy_summary(text,jsonb,text,text),taskfold_private.review_child_copies(jsonb),public.taskfold_review_child_copies(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.review_child_copies(jsonb),public.taskfold_review_child_copies(jsonb) to authenticated;
