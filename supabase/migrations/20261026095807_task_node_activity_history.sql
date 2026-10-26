-- Additive, read-only child history. Older clients retain the original parent ledger.
create table public.task_node_activity_epoch (
 id text primary key check(id='current'), recorded_from timestamptz not null default statement_timestamp()
);
insert into public.task_node_activity_epoch(id) values('current');
alter table public.task_node_activity_epoch enable row level security;
revoke all on public.task_node_activity_epoch from public,anon,authenticated;
grant select on public.task_node_activity_epoch to authenticated;
create policy task_node_activity_epoch_read on public.task_node_activity_epoch for select to authenticated using(true);
create table public.task_node_activity (
 id uuid primary key default gen_random_uuid(), format_version integer not null default 1 check(format_version=1),
 sequence bigint generated always as identity unique check(sequence between 1 and 9007199254740991),
 user_id uuid not null references auth.users(id) on delete cascade,
 task_id uuid not null, task_generation uuid, node_key text not null,
 before_path text[] not null, after_path text[] not null,
 actor_id uuid references auth.users(id) on delete set null,
 recorded_at timestamptz not null default statement_timestamp(), effective_at timestamptz not null,
 completion_version bigint not null check(completion_version between 0 and 9007199254740991),
 type_before text check(type_before in ('task','heading')),type_after text check(type_after in ('task','heading')),
 work_before boolean not null,work_after boolean not null,
 kinds text[] not null check(cardinality(kinds)>0 and kinds<@array['created','completed','reopened','completion_time','moved','rescheduled','deleted','scope_changed','type_changed','coverage_gap']::text[]),
 before_state jsonb not null check(jsonb_typeof(before_state)='object'),after_state jsonb not null check(jsonb_typeof(after_state)='object'),
 check(cardinality(before_path)<=32 and cardinality(after_path)<=32 and octet_length(to_jsonb(before_path)::text)<=65536 and octet_length(to_jsonb(after_path)::text)<=65536),
 check((kinds=array['coverage_gap'] and node_key='' and cardinality(before_path)=0 and cardinality(after_path)=0 and not work_before and not work_after and type_before is null and type_after is null and completion_version=0)
   or (not ('coverage_gap'=any(kinds)) and task_generation is not null and length(node_key) between 1 and 400
    and (before_state='{}')=(cardinality(before_path)=0) and (after_state='{}')=(cardinality(after_path)=0)
    and (before_state='{}')=(type_before is null) and (after_state='{}')=(type_after is null)
    and (not work_before or type_before='task') and (not work_after or type_after='task')
    and (cardinality(before_path)=0 or before_path[cardinality(before_path)]=node_key)
    and (cardinality(after_path)=0 or after_path[cardinality(after_path)]=node_key)))
);
create index task_node_activity_owner_sequence on public.task_node_activity(user_id,sequence);
create index task_node_activity_subject_sequence on public.task_node_activity(task_id,task_generation,node_key,sequence);
create index task_node_activity_actor on public.task_node_activity(actor_id) where actor_id is not null;
alter table public.task_node_activity enable row level security;
revoke all on public.task_node_activity from public,anon,authenticated;
grant select on public.task_node_activity to authenticated;
create policy task_node_activity_read on public.task_node_activity for select to authenticated
 using(taskfold_private.can_read_task_activity(user_id,task_id,before_state,after_state));

-- Only bounded planning/completion metadata leaves the tree. Containment comes
-- from the authorized root, never a node's embedded project/user fields.
create function taskfold_private.node_activity_state(n jsonb,t public.tasks)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare r jsonb; k text; v jsonb; s text; stamp text;
begin
 r:=jsonb_build_object('project_id',t.project_id,'section_id',t.section_id,'completed',coalesce((n->>'completed')::boolean,false),
 'completed_at',null,'due_date',null,'due_time',null,'scheduled_at',null,'time_zone',null,'deadline_date',null,'recurrence_parent_id',null);
 foreach k in array array['completed_at','due_date','due_time','scheduled_at','time_zone','deadline_date','recurrence_parent_id'] loop
  v:=n->k;
  if v is null or v='null'::jsonb then continue; end if;
  if jsonb_typeof(v)<>'string' or octet_length(n->>k)>256 then raise exception 'Unsupported node activity metadata'; end if;
  s:=n->>k;
  if k in ('completed_at','scheduled_at') then
   if s !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' then raise exception 'Unsupported node activity instant'; end if;
   stamp:=to_char(s::timestamptz at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"');r:=jsonb_set(r,array[k],to_jsonb(stamp));
  elsif k in ('due_date','deadline_date') then
   if s !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Unsupported node activity day'; end if;
   r:=jsonb_set(r,array[k],to_jsonb(to_char(s::date,'YYYY-MM-DD')));
  elsif k='due_time' and length(s)=5 then r:=jsonb_set(r,array[k],to_jsonb(s||':00'));
  else r:=jsonb_set(r,array[k],v);end if;
 end loop;
 return r;
end $$;
revoke all on function taskfold_private.node_activity_state(jsonb,public.tasks) from public,anon,authenticated;

create function taskfold_private.node_activity_revision(n jsonb)
returns bigint language plpgsql immutable security invoker set search_path='' as $$
declare v numeric;
begin
 if n->'completion_version' is null or n->'completion_version'='null'::jsonb then return 0;end if;
 if jsonb_typeof(n->'completion_version')<>'number' then raise exception 'Unsupported child revision';end if;
 v:=(n->>'completion_version')::numeric;
 if v<0 or v>9007199254740991 or trunc(v)<>v then raise exception 'Unsupported child revision';end if;
 return v::bigint;
end $$;
revoke all on function taskfold_private.node_activity_revision(jsonb) from public,anon,authenticated;

create function taskfold_private.node_activity_nodes(t public.tasks)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare source jsonb:=coalesce(t.subtasks,'[]');items jsonb;result jsonb:='{}';
 total bigint;unique_ids bigint;invalid boolean;bytes bigint;revision numeric;state jsonb;kind text;generation uuid:=coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000');
begin
 if source='null'::jsonb then source:='[]';end if;
 if jsonb_typeof(source)<>'array' or octet_length(source::text)>2100000 or (coalesce(t.is_heading,false) and (coalesce(t.completed,false) or t.completed_at is not null)) then raise exception 'Unsupported node history source';end if;
 with recursive walk(n,path,eligible) as (
  select v,array[v->>'id'],coalesce(t.is_heading,false) from jsonb_array_elements(source) v
  union all
  select v,w.path||(v->>'id'),w.eligible and w.n->'is_heading'='true'::jsonb
  from walk w cross join lateral jsonb_array_elements(case when cardinality(w.path)<32 and jsonb_typeof(w.n->'subtasks')='array' then w.n->'subtasks' else '[]'::jsonb end) v
 ) select coalesce(jsonb_agg(jsonb_build_object('node',n,'path',path,'eligible',coalesce(eligible,false))),'[]'),count(*),count(distinct n->>'id'),
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
  jsonb_build_object('generation',generation,'key',entry->'node'->>'id','path',entry->'path',
   'state',taskfold_private.node_activity_state(entry->'node',t),
   'type',case when entry->'node'->'is_heading'='true'::jsonb then 'heading' else 'task' end,
   'work',coalesce(entry->'node'->'is_heading','false'::jsonb)<>'true'::jsonb and (entry->>'eligible')::boolean,
   'revision',taskfold_private.node_activity_revision(entry->'node'))),'{}') into result
 from jsonb_array_elements(items) entry;
 return result;
end $$;
revoke all on function taskfold_private.node_activity_nodes(public.tasks) from public,anon,authenticated;

-- A private trigger is the only writer. Root DML and its original RLS/FK
-- authorization remain authoritative; there is no callable ledger-writing API.
create function taskfold_private.capture_task_node_activity()
returns trigger language plpgsql security definer set search_path='' as $$
declare caller uuid:=auth.uid();t public.tasks;prior jsonb:='{}';current_nodes jsonb:='{}';b jsonb;a jsonb;o jsonb;n jsonb;key text;kinds text[];instant timestamptz:=statement_timestamp();effective timestamptz;old_path text[];new_path text[];generation uuid;record_owner uuid;failed boolean:=false;
begin
 if tg_table_schema<>'public' or tg_table_name<>'tasks' then raise exception 'Invalid child activity source';end if;
 if tg_op='INSERT' then t:=new;else t:=old;end if;
 if not exists(select 1 from auth.users where id=t.user_id) then if tg_op='DELETE' then return old;else return new;end if;end if;
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
  if cardinality(kinds)=0 then continue;end if;
  effective:=instant;if 'completed'=any(kinds) and a->>'completed_at' is not null then effective:=(a->>'completed_at')::timestamptz;end if;
  generation:=(coalesce(n,o)->>'generation')::uuid;record_owner:=case when n is null then old.user_id else new.user_id end;
  insert into public.task_node_activity(user_id,task_id,task_generation,node_key,before_path,after_path,actor_id,effective_at,completion_version,type_before,type_after,work_before,work_after,kinds,before_state,after_state)
   values(record_owner,t.id,generation,coalesce(n,o)->>'key',old_path,new_path,caller,effective,(coalesce(n,o)->>'revision')::bigint,o->>'type',n->>'type',coalesce((o->>'work')::boolean,false),coalesce((n->>'work')::boolean,false),kinds,b,a);
 end loop;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;
revoke all on function taskfold_private.capture_task_node_activity() from public,anon,authenticated;
create trigger taskfold_capture_node_activity after insert or update or delete on public.tasks for each row execute function taskfold_private.capture_task_node_activity();
