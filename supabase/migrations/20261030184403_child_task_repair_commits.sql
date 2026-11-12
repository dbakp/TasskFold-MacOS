-- Disabled explicit repairs. Never automatically reconcile indexed copies.
alter table taskfold_private.child_task_record_config add column repair_writes_enabled boolean not null default false;
create table taskfold_private.child_task_repair_originals (
 id uuid primary key,actor_id uuid references auth.users(id) on delete set null,
 owner_id uuid references auth.users(id) on delete cascade,
 team_id uuid references taskfold_private.teams(id) on delete cascade,
 task_id uuid not null,task_generation uuid,project_id uuid,request_id uuid not null,
 original jsonb not null check(jsonb_typeof(original)='object'),
 bytes integer not null check(bytes between 1 and 8000000 and bytes=octet_length(original::text)),
 digest text not null check(digest~'^[a-f0-9]{64}$'),created_at timestamptz not null default clock_timestamp(),
 check((team_id is null)=(owner_id is not null))
);
create index child_repair_originals_actor on taskfold_private.child_task_repair_originals(actor_id);
create index child_repair_originals_team on taskfold_private.child_task_repair_originals(team_id);
alter table taskfold_private.child_task_repair_originals enable row level security;
revoke all on taskfold_private.child_task_repair_originals from public,anon,authenticated,service_role;
-- Teams use a logical deleted state and retain UUID tombstones. Match that
-- real lifecycle; a foreign-key cascade alone would leave archived content.
create function taskfold_private.purge_team_repair_originals() returns trigger
language plpgsql security definer set search_path='' as $$begin
 delete from taskfold_private.child_task_repair_originals where team_id=new.id;return new;
end$$;
create trigger taskfold_purge_team_repair_originals after update of state on taskfold_private.teams
 for each row when(new.state='deleted' and old.state is distinct from new.state) execute function taskfold_private.purge_team_repair_originals();
revoke all on function taskfold_private.purge_team_repair_originals() from public,anon,authenticated,service_role;
create table taskfold_private.child_task_repairs (
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 fingerprint text not null check(fingerprint~'^[a-f0-9]{64}$'),state text not null check(state in('applied','closed')),
 task_id uuid not null,task_generation uuid,project_id uuid,workspace_id uuid,team_id uuid,
 review_digest text not null check(review_digest~'^[a-f0-9]{64}$'),repair_digest text not null check(repair_digest~'^[a-f0-9]{64}$'),
 archive_id uuid,archive_digest text,node_count integer check(node_count between 0 and 1000),archive_bytes integer,
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id),
 check((state='applied')=(archive_id is not null and archive_digest is not null and archive_bytes is not null and node_count is not null)),
 check(archive_digest is null or archive_digest~'^[a-f0-9]{64}$'),check(archive_bytes is null or archive_bytes between 1 and 8000000)
);
-- Receipt metadata deliberately survives root/workspace deletion. Original content
-- follows personal-owner/team deletion, not the editor's lifetime in a team.
create index child_repairs_actor_day on taskfold_private.child_task_repairs(actor_id,created_at);
create unique index child_repairs_team_nonce on taskfold_private.child_task_repairs(team_id,request_id) where team_id is not null;
alter table taskfold_private.child_task_repairs enable row level security;
revoke all on taskfold_private.child_task_repairs from public,anon,authenticated,service_role;

-- Identity rewrites with existing history require an explicit mapping workflow.
-- Never bind a new reference to an old event simply because its spelling fits.
create function taskfold_private.child_repair_history_conflict(t public.tasks,changes jsonb) returns boolean
language plpgsql stable security invoker set search_path='' as $$
declare current_tree jsonb:=coalesce(t.subtasks,'null'::jsonb);change jsonb;node jsonb;reference text;prior_reference text;
begin
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

create or replace function taskfold_private.preview_child_repair(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();root_id uuid;generation uuid;project_id uuid;workspace_id uuid;t public.tasks;review jsonb;plan jsonb;digest text;blocker text;may_write boolean;
begin
 perform taskfold_private.team_actor();
 if jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>68000 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','task_id','task_generation','project_id','workspace_id','review_digest','changes')) then
  raise exception using errcode='22023',message='Review this repair preview request';end if;
 if taskfold_private.team_uuid(b,'account')<>actor then raise exception using errcode='42501',message='This review belongs to another account';end if;
 root_id:=taskfold_private.team_uuid(b,'task_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if b->'workspace_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'workspace_id');end if;
 if jsonb_typeof(b->'review_digest') is distinct from 'string' or (b->>'review_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the current source first';end if;
 generation:=(b->>'task_generation')::uuid;project_id:=(b->>'project_id')::uuid;workspace_id:=(b->>'workspace_id')::uuid;
 perform 1 from taskfold_private.child_task_record_config where singleton and adoption_enabled and repair_reviews_enabled for share;
 if not found then raise exception using errcode='PT503',message='Repair previews are not enabled';end if;
 t:=taskfold_private.child_adoption_root(root_id,generation,false);review:=taskfold_private.child_adoption_snapshot(t);
 if t.project_id is distinct from project_id or (review->>'workspace_id')::uuid is distinct from workspace_id or review->>'review_digest'<>b->>'review_digest' then
  raise exception using errcode='PT409',message='This source changed; review it again';end if;
 plan:=taskfold_private.plan_child_repair(t.subtasks,b->'changes');
 -- A structurally valid proposal is not proof that indexed copies/history can
 -- be reconciled. Those need a separate reviewed custody and archive workflow.
 if exists(select 1 from taskfold_private.child_task_projections where task_id=root_id)
  or exists(select 1 from taskfold_private.child_task_records where task_id=root_id)
  or exists(select 1 from taskfold_private.child_task_record_authority where task_id=root_id) then blocker:='indexed_custody';
 elsif taskfold_private.child_repair_history_conflict(t,b->'changes') then blocker:='history_custody';end if;
 may_write:=blocker is null and plan->'proposal_valid'='true'::jsonb and exists(select 1 from taskfold_private.child_task_record_config where singleton and repair_writes_enabled and repair_reviews_enabled and adoption_enabled and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled)
  and (workspace_id is null or (coalesce(taskfold_private.team_project_role(actor,t.project_id),'') in('manager','editor') and exists(select 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled and native_task_types_enabled)))
  and (t.project_id is null or exists(select 1 from public.projects where id=t.project_id and not is_archived and not ancestor_archived));
 digest:=encode(extensions.digest(convert_to(jsonb_build_object('protocol',1,'account',actor,'root',to_jsonb(t),
  'review_digest',review->'review_digest','changes',b->'changes','proposed_tree',plan->'proposed_tree')::text,'UTF8'),'sha256'),'hex');
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',actor,'task_id',root_id,'task_generation',generation,'project_id',project_id,'workspace_id',workspace_id,
  'review_digest',review->'review_digest','repair_digest',digest,'original_tree',coalesce(t.subtasks,'null'::jsonb),'original_sql_null',t.subtasks is null,
  'changes',b->'changes','proposal_valid',plan->'proposal_valid','remaining_issue',plan->'remaining_issue','node_count',plan->'node_count',
  'proposed_tree',plan->'proposed_tree','steps',plan->'steps','custody_blocker',blocker,'mutation_available',may_write);
end$$;

-- Symmetric actor and live-team nonce fences on every existing command ledger.
create function taskfold_private.guard_child_repair_nonce() returns trigger
language plpgsql security invoker set search_path='' as $$
declare team uuid:=nullif(to_jsonb(new)->>'team_id','')::uuid;name text;used boolean;
begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 if team is not null and not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||new.request_id::text,79241)) then raise exception using errcode='55P03',message='Another workspace decision is finishing';end if;
 if tg_table_name<>'child_task_repairs' then
  if exists(select 1 from taskfold_private.child_task_repairs r where (r.actor_id=new.actor_id or r.team_id=team) and r.request_id=new.request_id) then raise exception using errcode='PT409',message='This identity belongs to a reviewed repair';end if;
 else
  if team is not null and exists(select 1 from taskfold_private.child_task_repairs r where r.team_id=team and r.request_id=new.request_id and r.actor_id<>new.actor_id) then raise exception using errcode='PT409',message='This workspace repair identity was already used';end if;
  foreach name in array array['child_task_edit_preparations','child_task_edit_receipts','child_task_edit_closures','child_task_completion_receipts','child_task_completion_closures','child_task_structure_receipts','child_task_structure_closures','team_task_edits','personal_task_moves','team_task_batches','child_task_transfers','child_task_adoptions'] loop
   execute format('select exists(select 1 from taskfold_private.%I r where r.actor_id=$1 and r.request_id=$2)',name) into used using new.actor_id,new.request_id;
   if not used and team is not null and exists(select 1 from pg_catalog.pg_attribute where attrelid=to_regclass('taskfold_private.'||name) and attname='team_id' and not attisdropped) then
    execute format('select exists(select 1 from taskfold_private.%I r where r.team_id=$1 and r.request_id=$2)',name) into used using team,new.request_id;
   end if;
   if used then raise exception using errcode='PT409',message='This identity belongs to another action';end if;
  end loop;
 end if;
 return new;
end$$;
do $$declare name text;begin
 foreach name in array array['child_task_edit_preparations','child_task_edit_receipts','child_task_edit_closures','child_task_completion_receipts','child_task_completion_closures','child_task_structure_receipts','child_task_structure_closures','team_task_edits','personal_task_moves','team_task_batches','child_task_transfers','child_task_adoptions','child_task_repairs'] loop
  execute format('create trigger child_repair_nonce before insert or update on taskfold_private.%I for each row execute function taskfold_private.guard_child_repair_nonce()',name);
 end loop;
end$$;

create function taskfold_private.child_repair_reply(r taskfold_private.child_task_repairs,replayed boolean) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'request_id',r.request_id,'state',r.state,'replayed',replayed,
 'task_id',r.task_id,'task_generation',r.task_generation,'project_id',r.project_id,'workspace_id',r.workspace_id,
 'review_digest',r.review_digest,'repair_digest',r.repair_digest,'archive_id',r.archive_id,'archive_digest',r.archive_digest,'archive_bytes',r.archive_bytes,'node_count',r.node_count)
$$;
create function taskfold_private.commit_child_repair(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();q uuid;root_id uuid;generation uuid;pid uuid;team uuid;fingerprint text;prior taskfold_private.child_task_repairs;
 t public.tasks;view jsonb;original jsonb;archive_id uuid;archive_digest text;archive_bytes integer;revision bigint;status text;current_workspace uuid;
begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(actor::text,73918));perform taskfold_private.team_actor();
 if operation is null or operation not in('send','check','close','original') or jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>70000
  or b->'protocol' is distinct from '1'::jsonb or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest','repair_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest','repair_digest','changes'))
  or jsonb_typeof(b->'changes') is distinct from 'array' or jsonb_array_length(b->'changes') not between 1 and 64 or octet_length((b->'changes')::text)>65536 then
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
 original:=jsonb_build_object('protocol',1,'root',to_jsonb(t),'subtasks_sql_null',t.subtasks is null,
  'projection',null,'records','[]'::jsonb,'authority',null,
  'child_history',(select coalesce(jsonb_agg(to_jsonb(h) order by h.sequence),'[]') from public.task_node_activity h where h.task_id=root_id),
  'review_digest',view->'review_digest','repair_digest',view->'repair_digest');
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
create function public.taskfold_repair_children(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 reply:=taskfold_private.commit_child_repair(_operation,_body);
 if (_operation='original' or (_operation='send' and reply->>'state'='applied' and reply->'replayed'='false'::jsonb))
  and not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return reply;
end$$;
revoke all on function taskfold_private.child_repair_history_conflict(public.tasks,jsonb),taskfold_private.guard_child_repair_nonce(),
 taskfold_private.child_repair_reply(taskfold_private.child_task_repairs,boolean),taskfold_private.commit_child_repair(text,jsonb),public.taskfold_repair_children(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.commit_child_repair(text,jsonb),public.taskfold_repair_children(text,jsonb) to authenticated;
