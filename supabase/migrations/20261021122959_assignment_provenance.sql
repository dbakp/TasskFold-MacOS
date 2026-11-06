-- Current assignment provenance is server-owned, separate from editable task JSON.
-- No historical actor is inferred from the task owner, assignee or invitation.
create table public.task_assignment_provenance (
 id uuid primary key default gen_random_uuid(),
 task_id uuid not null references public.tasks(id) on delete cascade,
 task_generation uuid not null,
 node_key text collate "C" not null,
 node_path text[] not null,
 assignee_id uuid references auth.users(id) on delete set null,
 actor_id uuid references auth.users(id) on delete set null,
 event_id uuid not null default gen_random_uuid(),
 assigned_at timestamptz,
 origin text not null check(origin in ('recorded','legacy','system','recurrence','unsupported','unassigned')),
 active boolean not null,
 unique(task_id,task_generation,node_key),
 check(length(node_key)<=400),
 check(cardinality(node_path)<=32),
 check((node_key='' and cardinality(node_path)=0) or (node_key<>'' and node_path[cardinality(node_path)]=node_key)),
 check(origin<>'recorded' or assigned_at is not null)
);
create index task_assignment_provenance_assignee on public.task_assignment_provenance(assignee_id) where assignee_id is not null;
create index task_assignment_provenance_actor on public.task_assignment_provenance(actor_id) where actor_id is not null;
alter table public.task_assignment_provenance enable row level security;
revoke all on public.task_assignment_provenance from public,anon,authenticated;
grant select on public.task_assignment_provenance to authenticated;
-- Use the tasks SELECT policy itself: a provenance row never grants task access.
create policy assignment_read_current_task on public.task_assignment_provenance for select to authenticated
 using(active and assignee_id is not null and exists(
  select 1 from public.tasks t where t.id=task_id
   and coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid)=task_assignment_provenance.task_generation
 ));

-- Pure bounded projection. NULL means unsupported; {} means a known empty tree.
-- A malformed legacy checklist must not block an unrelated title/date edit, but
-- must never acquire invented identities or fabricated assignment authorship.
create function taskfold_private.assignment_nodes(_tree jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $nodes$
declare result jsonb; invalid boolean;
begin
 if _tree is null or _tree='null'::jsonb then return '{}'::jsonb; end if;
 if jsonb_typeof(_tree)<>'array' or octet_length(_tree::text)>33554432 then return null; end if;
 with recursive walk(node,path,depth) as (
  select e.value,array[e.value->>'id'],1 from jsonb_array_elements(_tree) e
  union all
  select e.value,w.path || (e.value->>'id'),w.depth+1 from walk w
   cross join lateral jsonb_array_elements(case when jsonb_typeof(w.node->'subtasks')='array' then w.node->'subtasks' else '[]'::jsonb end) e
   where w.depth<32
 ), bounded as materialized (select * from walk limit 100001), checked as (
  select *, node->>'id' collate "C" as key,
   jsonb_typeof(node) is distinct from 'object'
   or jsonb_typeof(node->'id') is distinct from 'string'
   or coalesce(btrim(node->>'id'),'')='' or length(node->>'id')>400
   or (node->>'id') ~ '[[:cntrl:]]'
   or jsonb_typeof(node->'title') is distinct from 'string'
   or (node->'subtasks' is not null and node->'subtasks'<>'null'::jsonb and jsonb_typeof(node->'subtasks')<>'array')
   or (depth=32 and case when jsonb_typeof(node->'subtasks')='array' then jsonb_array_length(node->'subtasks')>0 else false end)
   or (node->'assigned_to' is not null and node->'assigned_to'<>'null'::jsonb and node->'assigned_to'<>'""'::jsonb
    and (jsonb_typeof(node->'assigned_to')<>'string' or (node->>'assigned_to') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) as bad
  from bounded
 )
 select count(*)>100000 or coalesce(bool_or(bad),false) or count(*)<>count(distinct key),
  coalesce(jsonb_object_agg(coalesce(key,''),jsonb_build_object('path',path,'assignee',lower(nullif(node->>'assigned_to','')))),'{}'::jsonb)
 into invalid,result from checked;
 if invalid then return null; end if;
 return result;
end $nodes$;
revoke all on function taskfold_private.assignment_nodes(jsonb) from public,anon,authenticated;

-- Private trigger is the sole writer. SECURITY DEFINER is required because
-- authenticated clients deliberately have no write grant on the provenance table.
create function taskfold_private.capture_assignment_provenance()
returns trigger language plpgsql security definer set search_path='' as $capture$
declare
 actor uuid:=auth.uid(); generation uuid; before_nodes jsonb; after_nodes jsonb;
 item record; previous jsonb; recipient uuid; prior public.task_assignment_provenance;
 source text; initial_source text; root_before uuid;
begin
 -- Only an actual authenticated account can become a recorded actor. Trusted
 -- system writes without a subject remain explicitly unknown.
 if actor is not null and not exists(select 1 from auth.users where id=actor) then actor:=null; end if;
 generation:=coalesce(new.task_generation,'00000000-0000-0000-0000-000000000000'::uuid);
 initial_source:=case when tg_op='INSERT' and (new.recurrence_parent_id is not null or coalesce(new.source_metadata,'{}'::jsonb) ? 'taskfold_recurrence_v1') then 'recurrence'
  when actor is null then 'system' else 'recorded' end;
 if tg_op='UPDATE' then root_before:=old.assigned_to; end if;
 select * into prior from public.task_assignment_provenance where task_id=new.id and task_generation=generation and node_key='';
 if tg_op='INSERT' or new.assigned_to is distinct from root_before then
  source:=case when new.assigned_to is null then 'unassigned' else initial_source end;
  insert into public.task_assignment_provenance(task_id,task_generation,node_key,node_path,assignee_id,actor_id,event_id,assigned_at,origin,active)
  values(new.id,generation,'','{}',new.assigned_to,case when source='recorded' then actor end,gen_random_uuid(),case when source='recorded' then clock_timestamp() end,source,new.assigned_to is not null)
  on conflict(task_id,task_generation,node_key) do update set assignee_id=excluded.assignee_id,actor_id=excluded.actor_id,event_id=excluded.event_id,assigned_at=excluded.assigned_at,origin=excluded.origin,active=excluded.active;
 elsif not found and new.assigned_to is not null then
  insert into public.task_assignment_provenance(task_id,task_generation,node_key,node_path,assignee_id,origin,active)
  values(new.id,generation,'','{}',new.assigned_to,'legacy',true);
 end if;
 if tg_op='UPDATE' and new.subtasks is not distinct from old.subtasks then return new; end if;
 if tg_op='UPDATE' then before_nodes:=taskfold_private.assignment_nodes(old.subtasks); else before_nodes:='{}'::jsonb; end if;
 after_nodes:=taskfold_private.assignment_nodes(new.subtasks);
 if after_nodes is null then
  update public.task_assignment_provenance set active=false,actor_id=null,assigned_at=null,origin='unsupported',event_id=gen_random_uuid()
   where task_id=new.id and task_generation=generation and node_key<>'';
  return new;
 end if;
 -- Keep inactive identity tombstones for delete/Undo within this root incarnation.
 update public.task_assignment_provenance set active=false
  where task_id=new.id and task_generation=generation and node_key<>'' and not (after_nodes ? node_key);
 for item in select key,value from jsonb_each(after_nodes) loop
  recipient:=(item.value->>'assignee')::uuid;
  -- Old embedded JSON can reference a removed account (it has no FK). Do not
  -- make an unrelated child edit fail or treat that stale UUID as a live member.
  if recipient is not null and not exists(select 1 from auth.users where id=recipient) then recipient:=null; end if;
  previous:=before_nodes->item.key;
  select * into prior from public.task_assignment_provenance where task_id=new.id and task_generation=generation and node_key=item.key;
  if found and prior.assignee_id is not distinct from recipient and prior.origin<>'unsupported'
    and before_nodes is not null and (previous is null or (previous->>'assignee')::uuid is not distinct from recipient) then
   update public.task_assignment_provenance set node_path=array(select jsonb_array_elements_text(item.value->'path')),active=recipient is not null
    where id=prior.id;
  else
   source:=case when recipient is null then 'unassigned'
    when before_nodes is null or (tg_op='UPDATE' and previous is not null and (previous->>'assignee')::uuid is not distinct from recipient) then 'legacy'
    else initial_source end;
   insert into public.task_assignment_provenance(task_id,task_generation,node_key,node_path,assignee_id,actor_id,event_id,assigned_at,origin,active)
   values(new.id,generation,item.key,array(select jsonb_array_elements_text(item.value->'path')),recipient,case when source='recorded' then actor end,gen_random_uuid(),case when source='recorded' then clock_timestamp() end,source,recipient is not null)
   on conflict(task_id,task_generation,node_key) do update set node_path=excluded.node_path,assignee_id=excluded.assignee_id,actor_id=excluded.actor_id,event_id=excluded.event_id,assigned_at=excluded.assigned_at,origin=excluded.origin,active=excluded.active;
  end if;
 end loop;
 return new;
end $capture$;
revoke all on function taskfold_private.capture_assignment_provenance() from public,anon,authenticated;
create trigger taskfold_capture_assignment_provenance after insert or update on public.tasks
 for each row execute function taskfold_private.capture_assignment_provenance();

comment on table public.task_assignment_provenance is 'Read-only current assignment provenance. Missing/legacy/system/recurrence/unsupported/deleted-actor history is unknown. Never an access grant. Inactive child identities support Undo, and are not client-readable.';
notify pgrst,'reload schema';
