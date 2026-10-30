-- Explicit, incremental adoption. No backfill, hosted rollout or normal-use enablement.
alter table taskfold_private.child_task_record_config add column adoption_enabled boolean not null default false;
create table taskfold_private.child_task_adoptions (
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 fingerprint text not null check(length(fingerprint)=64),task_id uuid not null,task_generation uuid,project_id uuid,workspace_id uuid,team_id uuid,
 review_digest text not null check(length(review_digest)=64),state text not null check(state in('applied','closed')),
 node_count integer check(node_count between 0 and 1000),created_at timestamptz not null default clock_timestamp(),
 primary key(actor_id,request_id),check((state='applied')=(node_count is not null))
);
create index child_adoptions_actor_day on taskfold_private.child_task_adoptions(actor_id,created_at);
create unique index child_adoptions_team_nonce on taskfold_private.child_task_adoptions(team_id,request_id) where team_id is not null;
alter table taskfold_private.child_task_adoptions enable row level security;
revoke all on taskfold_private.child_task_adoptions from public,anon,authenticated,service_role;

-- Internal admission; the granted definer entry points call this as their owner.
create function taskfold_private.child_adoption_root(root_id uuid,generation uuid,writing boolean) returns public.tasks
language plpgsql volatile security invoker set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();before_root public.tasks;t public.tasks;team uuid;role_name text;
begin
 perform taskfold_private.team_actor();
 select * into before_root from public.tasks where id=root_id;
 if not found or before_root.task_generation is distinct from generation then raise exception using errcode='42501',message='This task is unavailable';end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=before_root.project_id;
 if team is not null then
  perform 1 from taskfold_private.team_config where singleton and enabled for share nowait;
  if not found then raise exception using errcode='PT503',message='Shared work is paused';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and (not writing or (native_task_edits_enabled and native_task_types_enabled)) for share nowait;
  if not found then raise exception using errcode='PT503',message='Shared editing is not enabled';end if;
  perform 1 from taskfold_private.teams where id=team and state='active' for share nowait;
  if not found then raise exception using errcode='42501',message='This workspace is unavailable';end if;
  perform 1 from taskfold_private.team_members where team_id=team and user_id=a for share nowait;
  perform 1 from taskfold_private.team_project_grants where project_id=before_root.project_id and user_id=a for share nowait;
  perform 1 from taskfold_private.team_content_projects where project_id=before_root.project_id and team_id=team for share nowait;
 end if;
 if before_root.project_id is not null then
  perform 1 from public.projects where id=before_root.project_id and (not writing or (not is_archived and not ancestor_archived)) for share nowait;
  if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 end if;
 if writing then select * into t from public.tasks where id=root_id for update nowait;
 else select * into t from public.tasks where id=root_id for share nowait;end if;
 if t.id is null or t.task_generation is distinct from generation or t.project_id is distinct from before_root.project_id or t.user_id is distinct from before_root.user_id then raise exception using errcode='PT409',message='This task changed; review it again';end if;
 if team is not null then
  if not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=t.id and c.generation=t.task_generation and c.team_id=team)
   then raise exception using errcode='PT409',message='This shared task changed';end if;
  role_name:=taskfold_private.team_project_role(a,t.project_id);
  if role_name is null or (writing and role_name not in('manager','editor')) then raise exception using errcode='42501',message='Editing access is required';end if;
 elsif taskfold_private.is_team_content_task(t.id) or (t.project_id is null and t.user_id<>a)
  or (t.project_id is not null and not coalesce(public.has_project_access(a,t.project_id),false)) then raise exception using errcode='42501',message='This task is unavailable';end if;
 perform taskfold_private.team_actor();
 return t;
end$$;

-- Read-only diagnosis. It never repairs malformed identities or refreshes an
-- existing projection. The digest binds all original fields and row identities.
create function taskfold_private.child_adoption_snapshot(t public.tasks) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare p taskfold_private.child_task_projections;a taskfold_private.child_task_record_authority;
 tree jsonb:=coalesce(t.subtasks,'null'::jsonb);decoded jsonb;rows jsonb;issue text;state text:='ready';
 bytes integer;count_nodes integer;depth integer;fingerprint text;can_adopt boolean;team uuid;actual jsonb;
begin
 select * into p from taskfold_private.child_task_projections where task_id=t.id;
 select * into a from taskfold_private.child_task_record_authority where task_id=t.id;
 select coalesce(jsonb_agg(to_jsonb(r) order by node_key),'[]') into rows from taskfold_private.child_task_records r where task_id=t.id;
 bytes:=octet_length(tree::text);
 if bytes>2000000 then issue:='source_size';else
  decoded:=taskfold_private.decode_child_task_tree(tree);issue:=decoded->>'issue';
 end if;
 if issue is null then
  count_nodes:=jsonb_array_length(decoded->'nodes');
  select coalesce(max(jsonb_array_length(n->'path')),0) into depth from jsonb_array_elements(decoded->'nodes') n;
  if p.task_id is not null then
   if p.state<>'ready' or p.task_generation is distinct from t.task_generation or p.source_tree is distinct from tree then issue:='projection_mismatch';else
    begin actual:=taskfold_private.materialize_child_task_records(t.id,case when tree='null'::jsonb then 'null' else 'array' end);
     if actual is distinct from tree then issue:='projection_mismatch';end if;
    exception when sqlstate 'PT409' then issue:='projection_mismatch';end;
   end if;
  elsif rows<>'[]'::jsonb then issue:='projection_mismatch';end if;
 end if;
 if a.task_id is not null then
  if a.task_generation is distinct from t.task_generation or a.project_id is distinct from t.project_id
   or a.root_kind is distinct from (case when tree='null'::jsonb then 'null' else 'array' end) or issue is not null then issue:='authority_mismatch';else state:='records';end if;
 end if;
 if issue is not null then state:='review';end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
 fingerprint:=encode(extensions.digest(convert_to(jsonb_build_object('protocol',1,'task_id',t.id,'task_generation',t.task_generation,
  'project_id',t.project_id,'workspace_id',team,'user_id',t.user_id,'source_tree',tree,'projection',case when p.task_id is null then null else to_jsonb(p) end,
  'authority',case when a.task_id is null then null else to_jsonb(a) end,'records',rows)::text,'UTF8'),'sha256'),'hex');
 can_adopt:=state='ready' and exists(select 1 from taskfold_private.child_task_record_config where singleton and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled) and (team is null or (coalesce(taskfold_private.team_project_role(auth.uid(),t.project_id),'') in('manager','editor') and exists(select 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled and native_task_types_enabled)))
  and (t.project_id is null or exists(select 1 from public.projects where id=t.project_id and not is_archived and not ancestor_archived));
 return jsonb_build_object('protocol',1,'account',auth.uid(),'task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'workspace_id',team,
  'review_digest',fingerprint,'state',state,'issue',issue,'node_count',count_nodes,'max_depth',depth,'source_bytes',bytes,
  'root_kind',jsonb_typeof(tree),'source_included',bytes<=2000000,'source_tree',case when bytes<=2000000 then tree else null end,
  'projection_revision',p.revision,'structure_revision',p.structure_revision,'can_adopt',can_adopt);
end$$;

create function taskfold_private.review_child_adoption(root_id uuid,generation uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare t public.tasks;reply jsonb;begin
 perform taskfold_private.team_actor();
 perform 1 from taskfold_private.child_task_record_config where singleton and adoption_enabled for share;
 if not found then raise exception using errcode='PT503',message='Subtask migration review is not enabled';end if;
 t:=taskfold_private.child_adoption_root(root_id,generation,false);
 reply:=taskfold_private.child_adoption_snapshot(t);
 perform taskfold_private.team_actor();return reply;
end$$;
create function public.taskfold_review_child_adoption(_id uuid,_generation uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$begin
 if not exists(select 1 from public.tasks where id=_id and task_generation is not distinct from _generation) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return taskfold_private.review_child_adoption(_id,_generation);
end$$;

create function taskfold_private.child_adoption_reply(r taskfold_private.child_task_adoptions,replayed boolean) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'request_id',r.request_id,'task_id',r.task_id,'task_generation',r.task_generation,
  'project_id',r.project_id,'workspace_id',r.workspace_id,'review_digest',r.review_digest,'state',r.state,'node_count',r.node_count,'replayed',replayed)
$$;

-- The same actor/nonce cannot be used by an older writer after this decision.
create function taskfold_private.guard_child_adoption_nonce() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 if exists(select 1 from taskfold_private.child_task_adoptions r where (r.actor_id=new.actor_id or r.team_id=nullif(to_jsonb(new)->>'team_id','')::uuid) and r.request_id=new.request_id) then raise exception using errcode='PT409',message='This identity belongs to subtask migration';end if;
 return new;
end$$;
do $$declare name text;begin
 foreach name in array array['child_task_edit_preparations','child_task_edit_receipts','child_task_edit_closures','child_task_completion_receipts','child_task_completion_closures','child_task_structure_receipts','child_task_structure_closures','team_task_edits','personal_task_moves','team_task_batches','child_task_transfers'] loop
  execute format('create trigger child_adoption_nonce before insert or update on taskfold_private.%I for each row execute function taskfold_private.guard_child_adoption_nonce()',name);
 end loop;
end$$;

create function taskfold_private.adopt_reviewed_children(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;root_id uuid;gen uuid;pid uuid;team uuid;fingerprint text;prior taskfold_private.child_task_adoptions;
 t public.tasks;review jsonb;rev bigint;status text;other_nonce boolean;table_name text;
begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 if operation is null or operation not in('send','check','close') or jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>2000
  or b->'protocol' is distinct from '1'::jsonb or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest')) then raise exception using errcode='22023',message='Review this migration request';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This review belongs to another account';end if;
 q:=taskfold_private.team_uuid(b,'request_id');root_id:=taskfold_private.team_uuid(b,'task_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if b->'workspace_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'workspace_id');end if;
 if jsonb_typeof(b->'review_digest') is distinct from 'string' or (b->>'review_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the current version of this task';end if;
 gen:=(b->>'task_generation')::uuid;pid:=(b->>'project_id')::uuid;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 select * into prior from taskfold_private.child_task_adoptions where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This migration identity was already used';end if;
  return taskfold_private.child_adoption_reply(prior,true);
 end if;
 foreach table_name in array array['child_task_edit_preparations','child_task_edit_receipts','child_task_edit_closures','child_task_completion_receipts','child_task_completion_closures','child_task_structure_receipts','child_task_structure_closures','team_task_edits','personal_task_moves','team_task_batches','child_task_transfers'] loop
  execute format('select exists(select 1 from taskfold_private.%I where actor_id=$1 and request_id=$2)',table_name) into other_nonce using a,q;
  if other_nonce then raise exception using errcode='PT409',message='This identity belongs to another action';end if;
 end loop;
 if operation='check' then return jsonb_build_object('protocol',1,'account',a,'request_id',q,'state','unknown');end if;
 if (select count(*) from taskfold_private.child_task_adoptions where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many migration decisions; try later';end if;
 if operation='close' then
  insert into taskfold_private.child_task_adoptions(actor_id,request_id,fingerprint,task_id,task_generation,project_id,workspace_id,review_digest,state)
   values(a,q,fingerprint,root_id,gen,pid,(b->>'workspace_id')::uuid,b->>'review_digest','closed') returning * into prior;
  return taskfold_private.child_adoption_reply(prior,false);
 end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Subtask migration is not enabled';end if;
 t:=taskfold_private.child_adoption_root(root_id,gen,true);
 if t.project_id is distinct from pid then raise exception using errcode='PT409',message='This task moved; review it again';end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=pid;
 if team is distinct from (b->>'workspace_id')::uuid then raise exception using errcode='PT409',message='This task changed workspaces; review it again';end if;
 if team is not null then
  if not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) then raise exception using errcode='55P03',message='Another workspace action is finishing';end if;
  if exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q)
   or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q)
   or exists(select 1 from taskfold_private.child_task_transfers where team_id=team and request_id=q)
   or exists(select 1 from taskfold_private.child_task_adoptions where team_id=team and request_id=q) then raise exception using errcode='PT409',message='This workspace identity was already used';end if;
 end if;
 review:=taskfold_private.child_adoption_snapshot(t);
 if review->>'review_digest'<>b->>'review_digest' or review->>'state'<>'ready' or review->'can_adopt'<>'true'::jsonb then raise exception using errcode='PT409',message='This task needs a fresh migration review; its original content is kept';end if;
 if not exists(select 1 from taskfold_private.child_task_projections where task_id=root_id) then
  status:=taskfold_private.adopt_child_task_records(root_id,gen,t.subtasks);
  if status<>'ready' then raise exception using errcode='PT409',message='The original hierarchy needs review';end if;
 end if;
 select revision into rev from taskfold_private.child_task_projections where task_id=root_id;
 status:=taskfold_private.promote_child_task_records(root_id,gen,pid,rev,t.subtasks);
 if status<>'records' then raise exception using errcode='PT409',message='This task changed; review it again';end if;
 perform taskfold_private.team_actor();
 insert into taskfold_private.child_task_adoptions(actor_id,request_id,fingerprint,task_id,task_generation,project_id,workspace_id,team_id,review_digest,state,node_count)
  values(a,q,fingerprint,root_id,gen,pid,team,team,b->>'review_digest','applied',(review->>'node_count')::integer) returning * into prior;
 return taskfold_private.child_adoption_reply(prior,false);
end$$;
create function public.taskfold_adopt_child_records(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 reply:=taskfold_private.adopt_reviewed_children(_operation,_body);
 if _operation='send' and reply->'state'='"applied"'::jsonb and reply->'replayed'='false'::jsonb
  and not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return reply;
end$$;
revoke all on function taskfold_private.child_adoption_root(uuid,uuid,boolean),taskfold_private.child_adoption_snapshot(public.tasks),taskfold_private.review_child_adoption(uuid,uuid),taskfold_private.child_adoption_reply(taskfold_private.child_task_adoptions,boolean),taskfold_private.guard_child_adoption_nonce(),taskfold_private.adopt_reviewed_children(text,jsonb),public.taskfold_review_child_adoption(uuid,uuid),public.taskfold_adopt_child_records(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.review_child_adoption(uuid,uuid),taskfold_private.adopt_reviewed_children(text,jsonb),public.taskfold_review_child_adoption(uuid,uuid),public.taskfold_adopt_child_records(text,jsonb) to authenticated;
