-- One metadata-only ordering entry per changed sibling list. No values or new grants.
lock table auth.users in share row exclusive mode;
lock table public.tasks in share row exclusive mode;
alter table public.task_node_activity_epoch add column order_recorded_from timestamptz not null default statement_timestamp();
alter table public.task_node_activity add column order_context jsonb;
create function taskfold_private.valid_node_order_context(value jsonb)
returns boolean language plpgsql immutable security invoker set search_path='' as $$
declare b text[];a text[];invalid boolean;
begin
 if value is null or jsonb_typeof(value)<>'object' then return false;end if;
 if (select array_agg(key order by key) from jsonb_object_keys(value) key) is distinct from array['after','before']
  or jsonb_typeof(value->'before') is distinct from 'array' or jsonb_typeof(value->'after') is distinct from 'array' or octet_length(value::text)>4200000 then return false;end if;
 select bool_or(jsonb_typeof(v)<>'string' or length(v#>>'{}') not between 1 and 400 or btrim(v#>>'{}')='' or (v#>>'{}')~'[[:cntrl:]]') into invalid from jsonb_array_elements((value->'before')||(value->'after')) v;
 if coalesce(invalid,true) then return false;end if;
 b:=array(select jsonb_array_elements_text(value->'before'));a:=array(select jsonb_array_elements_text(value->'after'));
 return cardinality(b) between 2 and 99999 and cardinality(b)=cardinality(a) and b<>a
  and cardinality(b)=(select count(distinct v) from unnest(b) v) and cardinality(a)=(select count(distinct v) from unnest(a) v) and b@>a and a@>b;
end $$;
alter table public.task_node_activity drop constraint task_node_activity_format_version_check;
alter table public.task_node_activity add constraint task_node_activity_format_version_check check(format_version in(1,2,3));
alter table public.task_node_activity drop constraint task_node_activity_kinds_check;
alter table public.task_node_activity add constraint task_node_activity_kinds_check check(cardinality(kinds)>0 and kinds<@array['created','completed','reopened','completion_time','moved','rescheduled','deleted','scope_changed','type_changed','coverage_gap','edited','reordered']::text[]);
alter table public.task_node_activity drop constraint task_node_activity_field_details_check;
alter table public.task_node_activity add constraint task_node_activity_field_details_check check(
 (format_version=1 and changed_fields='{}' and not('edited'=any(kinds)) and not('reordered'=any(kinds)) and order_context is null) or
 (format_version=2 and cardinality(changed_fields) between 1 and 7 and changed_fields<@array['assigned_to','description','duration_minutes','labels','priority','reminder_specs','title']::text[]
  and 'edited'=any(kinds) and before_state<>'{}' and after_state<>'{}' and not('coverage_gap'=any(kinds)) and not('reordered'=any(kinds)) and order_context is null) or
 (format_version=3 and changed_fields='{}' and kinds=array['reordered'] and taskfold_private.valid_node_order_context(order_context))
);
-- Preserve the original node/gap constraint verbatim for v1/v2. v3 describes a
-- sibling list (its parent path may be empty), never a work/completion subject.
do $$declare c record;expression text;begin
 select conname,pg_get_constraintdef(oid) definition into strict c from pg_constraint
 where conrelid='public.task_node_activity'::regclass and contype='c' and pg_get_constraintdef(oid) like '%coverage_gap%' and pg_get_constraintdef(oid) like '%completion_version%';
 expression:=substring(c.definition from 7);
 execute format('alter table public.task_node_activity drop constraint %I',c.conname);
 execute format('alter table public.task_node_activity add constraint task_node_activity_subject_check check ((format_version<>3 and %s) or (format_version=3 and task_generation is not null and before_state<>''{}'' and after_state<>''{}'' and before_path[cardinality(before_path)] is not distinct from after_path[cardinality(after_path)] and node_key=coalesce(before_path[cardinality(before_path)],'''') and not (order_context->''before'' ? node_key) and not work_before and not work_after and type_before is null and type_after is null and completion_version=0 and recorded_at=effective_at))',expression);
end $$;

create or replace function taskfold_private.node_activity_nodes(t public.tasks)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare source jsonb:=coalesce(t.subtasks,'[]');items jsonb;result jsonb:='{}';
 total bigint;unique_ids bigint;invalid boolean;bytes bigint;revision numeric;state jsonb;kind text;generation uuid:=coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000');
begin
 if source='null'::jsonb then source:='[]';end if;
 if jsonb_typeof(source)<>'array' or octet_length(source::text)>2100000 or (coalesce(t.is_heading,false) and (coalesce(t.completed,false) or t.completed_at is not null)) then raise exception 'Unsupported node history source';end if;
 with recursive walk(n,path,eligible,position) as (
  select v,array[v->>'id'],coalesce(t.is_heading,false),position from jsonb_array_elements(source) with ordinality entry(v,position)
  union all
  select v,w.path||(v->>'id'),w.eligible and w.n->'is_heading'='true'::jsonb,entry.position
  from walk w cross join lateral jsonb_array_elements(case when cardinality(w.path)<32 and jsonb_typeof(w.n->'subtasks')='array' then w.n->'subtasks' else '[]'::jsonb end) with ordinality entry(v,position)
 ) select coalesce(jsonb_agg(jsonb_build_object('node',n,'path',path,'eligible',coalesce(eligible,false),'position',position)),'[]'),count(*),count(distinct n->>'id'),
 coalesce(bool_or(jsonb_typeof(n)<>'object' or coalesce(jsonb_typeof(n->'id'),'null')<>'string' or length(coalesce(n->>'id','')) not between 1 and 400 or n->>'id'~'[[:cntrl:]]' or btrim(coalesce(n->>'id',''))=''
  or coalesce(jsonb_typeof(n->'title'),'null')<>'string' or regexp_replace(coalesce(n->>'title',''),'[[:space:]]','','g')=''
  or coalesce(jsonb_typeof(n->'subtasks'),'null') not in ('null','array')
  or coalesce(jsonb_typeof(n->'is_heading'),'null') not in ('null','boolean')
  or coalesce(jsonb_typeof(n->'completed'),'null') not in ('null','boolean')
  or (n->'is_heading'='true'::jsonb and (n->'completed'='true'::jsonb or coalesce(n->'completed_at','null')<>'null'))
  or (cardinality(path)=32 and jsonb_typeof(n->'subtasks')='array' and jsonb_array_length(n->'subtasks')>0)),false),coalesce(sum(8+4*ceil((octet_length(to_jsonb(path)::text)+40-cardinality(path)+(length(to_jsonb(path)::text)-length(replace(to_jsonb(path)::text,'/',''))))::numeric/3)),0)+36
 into items,total,unique_ids,invalid,bytes from walk;
 if total>=100000 or unique_ids<>total or invalid or bytes>33554432 then raise exception 'Ambiguous or unsupported child history';end if;
 select coalesce(jsonb_object_agg(generation::text||':'||(entry->'node'->>'id'),
  jsonb_build_object('position',entry->'position','generation',generation,'key',entry->'node'->>'id','path',entry->'path',
   'state',taskfold_private.node_activity_state(entry->'node',t),
   'type',case when entry->'node'->'is_heading'='true'::jsonb then 'heading' else 'task' end,
   'work',coalesce(entry->'node'->'is_heading','false'::jsonb)<>'true'::jsonb and (entry->>'eligible')::boolean,
   'revision',taskfold_private.node_activity_revision(entry->'node'),
   'edit_state',(select coalesce(jsonb_object_agg(f.key,f.value),'{}') from jsonb_each(entry->'node') f
    where f.key=any(array['assigned_to','description','duration_minutes','labels','priority','reminder_specs','title'])))),'{}') into result
 from jsonb_array_elements(items) entry;
 return result;
end $$;

create function taskfold_private.node_activity_order_changes(prior jsonb,current_nodes jsonb)
returns table(old_path text[],new_path text[],old_order text[],new_order text[])
language sql immutable security invoker set search_path='' as $$
 with common as (
  select b.value b,a.value a,
   array(select jsonb_array_elements_text(b.value->'path')) bp,
   array(select jsonb_array_elements_text(a.value->'path')) ap
  from jsonb_each(prior) b join jsonb_each(current_nodes) a on a.key=b.key
 ), same_parent as (
  select *,bp[1:cardinality(bp)-1] parent_before,ap[1:cardinality(ap)-1] parent_after from common
  where bp[cardinality(bp)-1] is not distinct from ap[cardinality(ap)-1]
 ), lists as (
  select parent_before,parent_after,array_agg(b->>'key' order by (b->>'position')::bigint) old_order,
   array_agg(a->>'key' order by (a->>'position')::bigint) new_order
  from same_parent group by parent_before,parent_after
 ) select parent_before,parent_after,old_order,new_order from lists where old_order<>new_order order by parent_before;
$$;

create or replace function taskfold_private.capture_task_node_activity()
returns trigger language plpgsql security definer set search_path='' as $$
declare caller uuid:=auth.uid();t public.tasks;prior jsonb:='{}';current_nodes jsonb:='{}';b jsonb;a jsonb;o jsonb;n jsonb;key text;kinds text[];instant timestamptz:=statement_timestamp();effective timestamptz;old_path text[];new_path text[];generation uuid;record_owner uuid;failed boolean:=false;changed text[];ordering record;
begin
 if tg_table_schema<>'public' or tg_table_name<>'tasks' then raise exception 'Invalid child activity source';end if;
 if tg_op='INSERT' then t:=new;else t:=old;end if;
 if not exists(select 1 from auth.users where id=t.user_id) and not taskfold_private.is_team_content_task(t.id) and not taskfold_private.is_team_content_project(t.project_id) then if tg_op='DELETE' then return old;else return new;end if;end if;
 if caller is not null and not exists(select 1 from auth.users where id=caller) then raise exception 'Activity actor is no longer available';end if;
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

revoke all on function taskfold_private.node_activity_nodes(public.tasks),taskfold_private.capture_task_node_activity() from public,anon,authenticated,service_role;

revoke all on function taskfold_private.valid_node_order_context(jsonb),taskfold_private.node_activity_order_changes(jsonb,jsonb) from public,anon,authenticated,service_role;
