-- Stage 1: opt-in, private, lossless projection of the existing child tree.
-- Legacy JSON remains authoritative. No client read/write grants or rollout.
create table taskfold_private.child_task_projections (
 task_id uuid primary key references public.tasks(id) on delete cascade,
 task_generation uuid,
 source_tree jsonb not null,
 state text not null check(state in ('ready','review')),
 issue text,
 revision bigint not null check(revision > 0),
 check((state='ready' and issue is null) or (state='review' and issue is not null))
);
create table taskfold_private.child_task_records (
 task_id uuid not null references taskfold_private.child_task_projections(task_id) on delete cascade,
 node_key text collate "C" not null,
 incarnation uuid not null default gen_random_uuid(),
 revision bigint not null default 1 check(revision > 0),
 parent_key text collate "C",
 sibling_order integer not null check(sibling_order >= 0),
 identity_path text[] not null check(cardinality(identity_path) between 1 and 24),
 fields jsonb not null check(jsonb_typeof(fields)='object' and not fields ? 'subtasks'),
 children_kind text not null check(children_kind in ('absent','null','array')),
 primary key(task_id,node_key),
 check(octet_length(node_key) between 1 and 128)
);
create index child_task_records_parent_order on taskfold_private.child_task_records(task_id,parent_key,sibling_order);
alter table taskfold_private.child_task_projections enable row level security;
alter table taskfold_private.child_task_records enable row level security;
revoke all on taskfold_private.child_task_projections,taskfold_private.child_task_records from public,anon,authenticated,service_role;

-- Bounded breadth-first decoding. Never assign/rewrite missing or duplicate IDs.
-- NFC matches Swift's canonical String equality; raw identities remain in fields.
create function taskfold_private.decode_child_task_tree(tree jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare queue jsonb:='[]';nodes jsonb:='[]';seen jsonb:='{}';entry jsonb;node jsonb;
 key text;raw_key text;kind text;children jsonb;item jsonb;position integer;depth integer;
begin
 if tree is null or tree='null'::jsonb then return jsonb_build_object('state','ready','nodes',nodes);end if;
 if jsonb_typeof(tree)<>'array' then return jsonb_build_object('state','review','issue','root_shape');end if;
 position:=0;
 for item in select * from jsonb_array_elements(tree) loop
  queue:=queue||jsonb_build_array(jsonb_build_object('node',item,'parent',null,'position',position,'path','[]'::jsonb));position:=position+1;
  if position>1000 then return jsonb_build_object('state','review','issue','node_limit');end if;
 end loop;
 while jsonb_array_length(queue)>0 loop
  entry:=queue->0;queue:=queue-0;node:=entry->'node';depth:=jsonb_array_length(entry->'path')+1;
  if depth>24 then return jsonb_build_object('state','review','issue','depth_limit');end if;
  if jsonb_typeof(node)<>'object' or jsonb_typeof(node->'id') is distinct from 'string' then
   return jsonb_build_object('state','review','issue','identity');end if;
  raw_key:=node->>'id';key:=normalize(raw_key,NFC);
  if octet_length(raw_key) not between 1 and 128 or octet_length(key) not between 1 and 128 then
   return jsonb_build_object('state','review','issue','identity');end if;
  if seen ? key then return jsonb_build_object('state','review','issue','duplicate_identity');end if;
  seen:=seen||jsonb_build_object(key,true);
  if not node ? 'subtasks' then kind:='absent';children:='[]';
  elsif node->'subtasks'='null'::jsonb then kind:='null';children:='[]';
  elsif jsonb_typeof(node->'subtasks')='array' then kind:='array';children:=node->'subtasks';
  else return jsonb_build_object('state','review','issue','children_shape');end if;
  nodes:=nodes||jsonb_build_array(jsonb_build_object('key',key,'parent',entry->'parent','position',entry->'position',
   'path',(entry->'path')||jsonb_build_array(raw_key),'fields',node-'subtasks','children_kind',kind));
  if jsonb_array_length(nodes)+jsonb_array_length(queue)+jsonb_array_length(children)>1000 then
   return jsonb_build_object('state','review','issue','node_limit');end if;
  position:=0;
  for item in select * from jsonb_array_elements(children) loop
   queue:=queue||jsonb_build_array(jsonb_build_object('node',item,'parent',key,'position',position,
    'path',(entry->'path')||jsonb_build_array(raw_key)));position:=position+1;
  end loop;
 end loop;
 return jsonb_build_object('state','ready','nodes',nodes);
end $$;

-- Caller must hold the root task row lock first. Only internal trigger/admin
-- adoption calls this function. It never writes tasks or bypasses their guards.
create function taskfold_private.sync_child_task_records(root_id uuid,generation uuid,tree jsonb) returns text
language plpgsql security invoker set search_path='' as $$
declare decoded jsonb;prior taskfold_private.child_task_projections%rowtype;entry jsonb;path text[];
begin
 tree:=coalesce(tree,'null'::jsonb);
 select * into prior from taskfold_private.child_task_projections where task_id=root_id for update;
 if found and (prior.task_generation is not distinct from generation) and prior.source_tree=tree then return prior.state;end if;
 decoded:=taskfold_private.decode_child_task_tree(tree);
 if prior.task_id is not null and (prior.task_generation is distinct from generation or prior.state='review' or decoded->>'state'='review') then
  delete from taskfold_private.child_task_records where task_id=root_id;
 end if;
 insert into taskfold_private.child_task_projections(task_id,task_generation,source_tree,state,issue,revision)
 values(root_id,generation,tree,decoded->>'state',decoded->>'issue',1)
 on conflict(task_id) do update set task_generation=excluded.task_generation,source_tree=excluded.source_tree,
  state=excluded.state,issue=excluded.issue,revision=taskfold_private.child_task_projections.revision+1;
 if decoded->>'state'='review' then return 'review';end if;
 delete from taskfold_private.child_task_records r where r.task_id=root_id and not exists(
  select 1 from jsonb_array_elements(decoded->'nodes') n where n->>'key' collate "C"=r.node_key);
 for entry in select * from jsonb_array_elements(decoded->'nodes') loop
  select array_agg(value order by ordinality) into path from jsonb_array_elements_text(entry->'path') with ordinality;
  insert into taskfold_private.child_task_records(task_id,node_key,parent_key,sibling_order,identity_path,fields,children_kind)
  values(root_id,entry->>'key',entry->>'parent',(entry->>'position')::integer,path,entry->'fields',entry->>'children_kind')
  on conflict(task_id,node_key) do update set parent_key=excluded.parent_key,sibling_order=excluded.sibling_order,
   identity_path=excluded.identity_path,fields=excluded.fields,children_kind=excluded.children_kind,
   revision=taskfold_private.child_task_records.revision+1
  where (taskfold_private.child_task_records.parent_key,taskfold_private.child_task_records.sibling_order,
   taskfold_private.child_task_records.identity_path,taskfold_private.child_task_records.fields,taskfold_private.child_task_records.children_kind)
   is distinct from (excluded.parent_key,excluded.sibling_order,excluded.identity_path,excluded.fields,excluded.children_kind);
 end loop;
 return 'ready';
end $$;

-- Explicit root-by-root trusted adoption. Exact generation/tree protects a
-- reviewed snapshot from a concurrent update. No automatic bulk backfill.
create function taskfold_private.adopt_child_task_records(root_id uuid,expected_generation uuid,expected_tree jsonb) returns text
language plpgsql security invoker set search_path='' as $$
declare root public.tasks%rowtype;
begin
 select * into root from public.tasks where id=root_id for update;
 if not found then return 'missing';end if;
 if root.task_generation is distinct from expected_generation or coalesce(root.subtasks,'null'::jsonb) is distinct from coalesce(expected_tree,'null'::jsonb) then return 'stale';end if;
 return taskfold_private.sync_child_task_records(root.id,root.task_generation,root.subtasks);
end $$;

create function taskfold_private.refresh_child_task_records() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 -- Trigger-only definer: derives all identifiers/content from the authorized
 -- updated row; no client-callable arguments or task write capability.
 if exists(select 1 from taskfold_private.child_task_projections where task_id=new.id) then
  perform taskfold_private.sync_child_task_records(new.id,new.task_generation,new.subtasks);
 end if;
 return new;
end $$;
create trigger taskfold_refresh_child_task_records after update of subtasks,task_generation on public.tasks
 for each row when(old.subtasks is distinct from new.subtasks or old.task_generation is distinct from new.task_generation)
 execute function taskfold_private.refresh_child_task_records();
revoke all on function taskfold_private.decode_child_task_tree(jsonb),
 taskfold_private.sync_child_task_records(uuid,uuid,jsonb),taskfold_private.adopt_child_task_records(uuid,uuid,jsonb),
 taskfold_private.refresh_child_task_records() from public,anon,authenticated,service_role;
