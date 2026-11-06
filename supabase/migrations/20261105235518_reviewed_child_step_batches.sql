-- Reviewed literal step insertion. Disabled until both clients complete native acceptance.
alter table taskfold_private.child_task_record_config add column step_batches_enabled boolean not null default false;
create table taskfold_private.child_task_step_receipts (
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,fingerprint text not null check(length(fingerprint)=64),
 task_id uuid not null,generation uuid,project_id uuid,action text not null check(action in('insert','undo')),undo_of uuid,reversed_by uuid,
 before_revision bigint not null,after_revision bigint not null,node_key text collate "C" not null,nodes jsonb not null check(jsonb_typeof(nodes)='array' and jsonb_array_length(nodes) between 1 and 12),inverse jsonb not null check(jsonb_typeof(inverse)='object'),created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id)
);
create index child_step_receipts_actor_day on taskfold_private.child_task_step_receipts(actor_id,created_at);
create table taskfold_private.child_task_step_closures(actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,fingerprint text not null check(length(fingerprint)=64),created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id));
create index child_step_closures_actor_day on taskfold_private.child_task_step_closures(actor_id,created_at);
alter table taskfold_private.child_task_step_receipts enable row level security;
alter table taskfold_private.child_task_step_closures enable row level security;
revoke all on taskfold_private.child_task_step_receipts,taskfold_private.child_task_step_closures from public,anon,authenticated,service_role;
create function taskfold_private.child_step_receipt(r taskfold_private.child_task_step_receipts,replayed boolean) returns jsonb
language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'request_id',r.request_id,'task_id',r.task_id,'task_generation',r.generation,'project_id',r.project_id,'action',r.action,'undo_of',r.undo_of,'before_revision',r.before_revision,'after_revision',r.after_revision,'nodes',r.nodes,'count',jsonb_array_length(r.nodes),'replayed',replayed)
$$;
create function taskfold_private.validate_child_step_request(b jsonb,a uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare fields text[];step jsonb;k text;begin
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>20000 or b->'protocol' is distinct from '1'::jsonb then raise exception using errcode='22023',message='Review these steps';end if;
 fields:=array['protocol','account','request_id','task_id','task_generation','project_id','structure_revision','action'];
 if b->>'action'='insert' then fields:=fields||array['parent_key','index','steps','source_title','parent_incarnation','parent_revision'];
 elsif b->>'action'='undo' then fields:=fields||array['undo_of'];else raise exception using errcode='22023',message='Choose a supported step action';end if;
 if not b ?& fields or exists(select 1 from jsonb_object_keys(b) x where not x=any(fields)) then raise exception using errcode='22023',message='Review this step request';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This step request belongs to another account';end if;
 foreach k in array array['request_id','task_id'] loop perform taskfold_private.team_uuid(b,k);end loop;
 foreach k in array array['task_generation','project_id'] loop if b->k<>'null'::jsonb then perform taskfold_private.team_uuid(b,k);end if;end loop;
 if jsonb_typeof(b->'structure_revision')<>'number' or (b->>'structure_revision')!~'^[0-9]{1,16}$' or (b->>'structure_revision')::numeric not between 1 and 9007199254740990 then raise exception using errcode='22023',message='Review the hierarchy revision';end if;
 if b->>'action'='undo' then perform taskfold_private.team_uuid(b,'undo_of');return;end if;
 if jsonb_typeof(b->'index')<>'number' or (b->>'index')!~'^[0-9]{1,4}$' or (b->>'index')::int>1000 or jsonb_typeof(b->'steps')<>'array' or jsonb_array_length(b->'steps') not between 1 and 12
  or jsonb_typeof(b->'source_title')<>'string' or octet_length(b->>'source_title')>2000 then raise exception using errcode='22023',message='Review between one and twelve literal steps';end if;
 if b->'parent_key'='null'::jsonb then
  if b->'parent_incarnation'<>'null'::jsonb or b->'parent_revision'<>'null'::jsonb then raise exception using errcode='22023',message='Review the step destination';end if;
 else
  if jsonb_typeof(b->'parent_key')<>'string' or octet_length(b->>'parent_key') not between 1 and 128 or normalize(b->>'parent_key',NFC) collate "C"<>b->>'parent_key' collate "C" then raise exception using errcode='22023',message='Review the step destination';end if;
  perform taskfold_private.team_uuid(b,'parent_incarnation');
  if jsonb_typeof(b->'parent_revision')<>'number' or (b->>'parent_revision')!~'^[0-9]{1,16}$' or (b->>'parent_revision')::numeric not between 1 and 9007199254740991 then raise exception using errcode='22023',message='Review the destination revision';end if;
 end if;
 for step in select * from jsonb_array_elements(b->'steps') loop
  if jsonb_typeof(step)<>'object' or not step ?& array['id','title'] or exists(select 1 from jsonb_object_keys(step) x where not x=any(array['id','title'])) then raise exception using errcode='22023',message='Steps may only contain a new identity and a literal title';end if;
  perform taskfold_private.team_uuid(step,'id');
  if step->>'id' collate "C" is distinct from ((step->>'id')::uuid)::text collate "C" then raise exception using errcode='22023',message='Use a fresh canonical step identity';end if;
  if jsonb_typeof(step->'title')<>'string' or char_length(step->>'title') not between 1 and 300 or octet_length(step->>'title')>1200 or btrim(step->>'title')='' or step->>'title' ~ '[[:cntrl:]]' or position(chr(8232) in step->>'title')>0 or position(chr(8233) in step->>'title')>0 then raise exception using errcode='22023',message='Use short titles on one line';end if;
 end loop;
 if (select count(distinct x->>'id') from jsonb_array_elements(b->'steps') x)<>jsonb_array_length(b->'steps') then raise exception using errcode='22023',message='Give each step a fresh identity';end if;
end$$;
create function taskfold_private.edit_child_step_batch(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
<<op>>
declare a uuid:=auth.uid();id uuid;q uuid;g uuid;p uuid;team uuid;initial public.tasks;t public.tasks;
 projection taskfold_private.child_task_projections;n taskfold_private.child_task_records;destination taskfold_private.child_task_records;
 prior taskfold_private.child_task_step_receipts;original taskfold_private.child_task_step_receipts;
 batch_nodes jsonb:='[]';step jsonb;digests jsonb:='{}';offset_value integer:=0;key text;parent text;mode text;undo_id uuid;fingerprint text;rev bigint;slot integer;container_kind text;
 decoded jsonb;extra_decoded jsonb;extra_tree jsonb:='[]';subtree jsonb;desired jsonb;inverse jsonb:='{}';
 recipients uuid[];current_recipients uuid[];replaying boolean;archive_size bigint;archive_count bigint;
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled and step_batches_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child structure editing is not enabled';end if;
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_step_request(b,a);
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');
 g:=case when b->'task_generation'='null'::jsonb then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null'::jsonb then null else taskfold_private.team_uuid(b,'project_id') end;
 mode:=b->>'action';rev:=(b->>'structure_revision')::bigint;key:=b->>'node_key';parent:=b->>'parent_key';slot:=(b->>'index')::integer;
 fingerprint:=encode(extensions.digest(convert_to('child-step-batch-v1:'||b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_step_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original structure action is closed';end if;
 if exists(select 1 from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q) then raise exception using errcode='PT409',message='This request identity belongs to another child action';end if;
 select * into prior from taskfold_private.child_task_step_receipts where actor_id=a and request_id=q;
 replaying:=found;
 if replaying and prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This structure identity was already used';end if;
 if not replaying then
  if mode='insert' then
   for step in select * from jsonb_array_elements(b->'steps') loop
    subtree:=taskfold_private.child_structure_fresh_node(step,false);
    extra_tree:=extra_tree||jsonb_build_array(subtree);
   end loop;
   key:=extra_tree->0->>'id';
  else
   undo_id:=taskfold_private.team_uuid(b,'undo_of');
   select * into original from taskfold_private.child_task_step_receipts where actor_id=a and request_id=undo_id;
   if not found or original.action<>'insert' or original.reversed_by is not null or original.task_id<>id or original.generation is distinct from g or original.project_id is distinct from p then raise exception using errcode='PT409',message='These steps can no longer be undone';end if;
   key:=original.node_key;batch_nodes:=original.nodes;
  end if;
 end if;
 select * into initial from public.tasks where tasks.id=op.id;
 if not found or initial.task_generation is distinct from g or initial.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if octet_length(coalesce(initial.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 decoded:=taskfold_private.decode_child_task_tree(initial.subtasks);extra_decoded:=taskfold_private.decode_child_task_tree(extra_tree);
 if decoded->>'state'<>'ready' or extra_decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 -- Lock all existing/new/restored recipients before team/project/root locks.
 select array_agg(distinct recipient order by recipient) into recipients from (
  select initial.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements((decoded->'nodes')||(extra_decoded->'nodes')) x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 perform 1 from auth.users where users.id=any(coalesce(recipients,'{}')) order by users.id for share;
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if team is not null then
  perform 1 from taskfold_private.teams where teams.id=team and state='active' for share;
  if not found or coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
  if not replaying and exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x where x->'fields'->'is_heading'='true'::jsonb) then
   perform 1 from taskfold_private.team_project_config where singleton and native_task_types_enabled for share;
   if not found then raise exception using errcode='PT503',message='Shared task types are not enabled';end if;
  end if;
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is paused';end if;
  perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 elsif taskfold_private.is_team_content_task(id) then raise exception using errcode='42501',message='This task is unavailable';
 elsif p is null then
  if initial.user_id<>a then raise exception using errcode='42501',message='This task is unavailable';end if;
 elsif not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if p is not null then
  perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73917));
 if team is not null then perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));end if;
 if (exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q)
  or (team is not null and (exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q) or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q)))) and not replaying then raise exception using errcode='PT409',message='This action identity was already used';end if;
 select * into t from public.tasks where tasks.id=op.id for update;
 if not found or t.task_generation is distinct from g or t.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 if replaying then return taskfold_private.child_step_receipt(prior,true);end if;
 if octet_length(coalesce(t.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 -- Verify stored records against the actual tree, not just a saved source hash.
 perform taskfold_private.read_child_task_records(id,g);
 select * into projection from taskfold_private.child_task_projections where task_id=id;
 if projection.structure_revision<>rev or projection.structure_revision>=9007199254740991 or projection.revision>=9007199254740991 then raise exception using errcode='PT409',message='The hierarchy changed; review this structure action';end if;
 decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
 select array_agg(distinct recipient order by recipient) into current_recipients from (
  select t.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 if not coalesce(current_recipients,'{}')<@coalesce(recipients,'{}') then raise exception using errcode='PT409',message='Assignments changed; review this structure action';end if;
 if mode='insert' then
  if t.completed or t.is_heading then raise exception using errcode='PT409',message='Choose an unfinished task';end if;
  if parent is null then
   container_kind:=case when coalesce(t.subtasks,'null'::jsonb)='null'::jsonb then 'null' else 'array' end;
   if t.title collate "C" is distinct from (b->>'source_title') collate "C" then raise exception using errcode='PT409',message='The task title changed; review the steps again';end if;
  else
   select * into destination from taskfold_private.child_task_records where task_id=id and node_key=parent;
   if not found or destination.incarnation is distinct from (b->>'parent_incarnation')::uuid or destination.revision<>(b->>'parent_revision')::bigint
    or destination.fields->>'title' collate "C" is distinct from (b->>'source_title') collate "C" or destination.fields->'completed'='true'::jsonb or destination.fields->'is_heading'='true'::jsonb then raise exception using errcode='PT409',message='The destination changed; review the steps again';end if;
   container_kind:=destination.children_kind;
  end if;
  if exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x join taskfold_private.child_task_records cr on cr.task_id=id and cr.node_key=x->>'key' collate "C") then raise exception using errcode='PT409',message='A new step identity is already used';end if;
  desired:=coalesce(t.subtasks,'null'::jsonb);
  for step in select * from jsonb_array_elements(extra_tree) loop
   desired:=taskfold_private.child_structure_insert(desired,parent,slot+offset_value,step);offset_value:=offset_value+1;
  end loop;
  inverse:=jsonb_build_object('parent_key',parent,'container_kind',container_kind);
 else
  if original.after_revision<>rev then raise exception using errcode='PT409',message='The hierarchy changed; review before Undo';end if;
  desired:=coalesce(t.subtasks,'null'::jsonb);
  for step in select * from jsonb_array_elements(original.nodes) loop
   if taskfold_private.child_structure_digest(id,step->>'node_key') is distinct from original.inverse->'digests'->>(step->>'node_key') then raise exception using errcode='PT409',message='An added step changed; keep its new work';end if;
   desired:=taskfold_private.child_structure_remove(desired,step->>'node_key');
  end loop;
  desired:=taskfold_private.child_structure_restore_container(desired,original.inverse->>'parent_key',original.inverse->>'container_kind');
 end if;
 if desired is not distinct from coalesce(t.subtasks,'null'::jsonb) then raise exception using errcode='22023',message='Choose a different child slot';end if;
 if octet_length(desired::text)>2000000 or taskfold_private.decode_child_task_tree(desired)->>'state'<>'ready' then raise exception using errcode='54000',message='The resulting hierarchy needs review or exceeds its limits';end if;
 if (select count(*) from taskfold_private.child_task_step_receipts where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many structure actions; try again later';end if;
 if team is not null then
  if not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=id and c.generation=g and c.team_id=team) then raise exception using errcode='PT409',message='This team task changed';end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,p,id,g,a,'patch',q);
 end if;
 desired:=taskfold_private.prepare_child_record_tree(op.id,g,desired);
 update public.tasks set subtasks=case when desired='null'::jsonb then null else desired end where tasks.id=op.id returning * into t;
 if team is not null then
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,g,'child_structure');
 end if;
 if coalesce(t.subtasks,'null'::jsonb)<>desired or not exists(select 1 from taskfold_private.child_task_projections where task_id=id and structure_revision=rev+1 and source_tree=desired) then raise exception using errcode='PT409',message='This structure action could not be confirmed';end if;
 perform taskfold_private.read_child_task_records(id,g);perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 if mode='insert' then
  for step in select * from jsonb_array_elements(extra_tree) loop
   select * into n from taskfold_private.child_task_records where task_id=id and node_key=step->>'id';
   if not found then raise exception using errcode='PT409',message='The added steps could not be confirmed';end if;
   batch_nodes:=batch_nodes||jsonb_build_array(jsonb_build_object('node_key',n.node_key,'incarnation',n.incarnation));
   digests:=digests||jsonb_build_object(n.node_key,taskfold_private.child_structure_digest(id,n.node_key));
  end loop;
  inverse:=inverse||jsonb_build_object('digests',digests);
 end if;
 insert into taskfold_private.child_task_step_receipts(actor_id,request_id,fingerprint,task_id,generation,project_id,action,undo_of,before_revision,after_revision,node_key,nodes,inverse)
 values(a,q,fingerprint,id,g,p,mode,undo_id,rev,rev+1,key,batch_nodes,inverse) returning * into prior;
 if mode='undo' then update taskfold_private.child_task_step_receipts set reversed_by=q where actor_id=a and request_id=undo_id;end if;
 return taskfold_private.child_step_receipt(prior,false);
end$$;

-- A nonce decision is reciprocal with legacy field/structure/completion writers.
create function taskfold_private.guard_child_step_identity() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 if exists(select 1 from taskfold_private.child_task_step_closures where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT410',message='This step request is closed';end if;
 if exists(select 1 from taskfold_private.child_task_step_receipts where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT409',message='This identity belongs to a step action';end if;
 return new;
end$$;
do $triggers$declare tab text;begin
 foreach tab in array array['child_task_edit_preparations','child_task_edit_receipts','child_task_edit_closures','child_task_completion_receipts','child_task_completion_closures','child_task_structure_receipts','child_task_structure_closures','team_task_edits','team_task_batches'] loop
  execute format('create trigger child_step_identity_fence before insert or update on taskfold_private.%I for each row execute function taskfold_private.guard_child_step_identity()',tab);
 end loop;
end$triggers$;
create function taskfold_private.child_step_request(_operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;fingerprint text;prior taskfold_private.child_task_step_receipts;closed taskfold_private.child_task_step_closures;begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_step_request(b,a);q:=(b->>'request_id')::uuid;
 if _operation is null or _operation not in('apply','resolve','close') then raise exception using errcode='22023',message='Choose a supported step operation';end if;
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 fingerprint:=encode(extensions.digest(convert_to('child-step-batch-v1:'||b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.child_task_step_receipts where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This step identity was already used';end if;
  if _operation='apply' then return taskfold_private.child_step_receipt(prior,true);end if;
  return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','applied','receipt',taskfold_private.child_step_receipt(prior,true));
 end if;
 select * into closed from taskfold_private.child_task_step_closures where actor_id=a and request_id=q;
 if found then
  if closed.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This step identity was closed with another body';end if;
  if _operation='apply' then raise exception using errcode='PT410',message='This original step request is closed';end if;
  return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','closed','receipt',null);
 end if;
 if exists(select 1 from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q) or exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q) or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q) or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q) or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q) or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q) then raise exception using errcode='PT409',message='This identity belongs to another action';end if;
 if _operation='resolve' then return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','absent','receipt',null);end if;
 if _operation='close' then
  if (select count(*) from taskfold_private.child_task_step_closures where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Try closing the original request later';end if;
  insert into taskfold_private.child_task_step_closures(actor_id,request_id,fingerprint) values(a,q,fingerprint);
  return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','closed','receipt',null);
 end if;
 return taskfold_private.edit_child_step_batch(b);
end$$;
create function public.taskfold_child_steps(_operation text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.child_step_request(_operation,_body)$$;
revoke all on function taskfold_private.child_step_receipt(taskfold_private.child_task_step_receipts,boolean),taskfold_private.validate_child_step_request(jsonb,uuid),taskfold_private.edit_child_step_batch(jsonb),taskfold_private.guard_child_step_identity(),taskfold_private.child_step_request(text,jsonb),public.taskfold_child_steps(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_step_request(text,jsonb),public.taskfold_child_steps(text,jsonb) to authenticated;
