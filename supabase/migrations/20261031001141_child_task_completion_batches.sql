-- Atomic groups of independent child completion commands. Disabled by default.
-- batch_id is a separate group namespace; item request IDs remain individually
-- reserved by the existing completion/terminal ledgers. No task policy changes.
alter table taskfold_private.child_task_record_config add column completion_batches_enabled boolean not null default false;
create table taskfold_private.child_task_completion_batches (
 actor_id uuid not null references auth.users(id) on delete cascade,
 batch_id uuid not null,fingerprint text not null check(length(fingerprint)=64),
 outcome text not null check(outcome in('applied','closed')),
 receipts jsonb not null check(jsonb_typeof(receipts)='array' and octet_length(receipts::text)<=524288),
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,batch_id),
 check((outcome='closed' and receipts='[]'::jsonb) or (outcome='applied' and jsonb_array_length(receipts) between 1 and 32))
);
create index child_completion_batches_actor_day on taskfold_private.child_task_completion_batches(actor_id,created_at);
alter table taskfold_private.child_task_completion_batches enable row level security;
revoke all on taskfold_private.child_task_completion_batches from public,anon,authenticated,service_role;

create function taskfold_private.validate_child_completion_batch(b jsonb,a uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare item jsonb;ids uuid[]:='{}';targets text[]:='{}';q uuid;target text;mode text;begin
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>131072
  or b->'protocol' is distinct from '1'::jsonb
  or not(b ?& array['protocol','account','batch_id','items'])
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','batch_id','items'))
  or jsonb_typeof(b->'items') is distinct from 'array' then
  raise exception using errcode='22023',message='Review this saved subtask selection';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This selection belongs to another account';end if;
 perform taskfold_private.team_uuid(b,'batch_id');
 if jsonb_array_length(b->'items') not between 1 and 32 then
  raise exception using errcode='22023',message='Select between 1 and 32 subtasks';end if;
 for item in select * from jsonb_array_elements(b->'items') loop
  perform taskfold_private.validate_child_completion_request(item,a);
  q:=taskfold_private.team_uuid(item,'request_id');
  target:=jsonb_build_array(taskfold_private.team_uuid(item,'task_id'),item->'node_key')::text;
  if q=any(ids) or q=taskfold_private.team_uuid(b,'batch_id') or target collate "C"=any(targets) then
   raise exception using errcode='22023',message='Each selected subtask and request must be unique';end if;
  if mode is not null and mode<>item->>'action' then raise exception using errcode='22023',message='Choose one selection action';end if;
  mode:=item->>'action';ids:=array_append(ids,q);targets:=array_append(targets,target);
 end loop;
end$$;

create function taskfold_private.child_completion_batch_receipt(r taskfold_private.child_task_completion_batches,replayed boolean) returns jsonb
language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'batch_id',r.batch_id,'outcome',r.outcome,'replayed',replayed,
 'receipts',coalesce((select jsonb_agg(value||jsonb_build_object('replayed',replayed) order by ordinal)
 from jsonb_array_elements(r.receipts) with ordinality x(value,ordinal)),'[]'::jsonb))
$$;

-- Fresh groups cannot silently adopt individually used/closed item IDs. A
-- committed group always has its own immutable receipt in the same transaction.
create function taskfold_private.require_unused_child_completion_items(b jsonb,a uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$begin
 if exists(select 1 from jsonb_array_elements(b->'items') i
  where exists(select 1 from taskfold_private.child_task_completion_receipts r where r.actor_id=a and r.request_id=(i->>'request_id')::uuid)
  or exists(select 1 from taskfold_private.child_task_completion_closures c where c.actor_id=a and c.request_id=(i->>'request_id')::uuid)) then
  raise exception using errcode='PT409',message='A selected request already belongs to another action';end if;
end$$;

create function taskfold_private.complete_child_task_batch(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare a uuid:=auth.uid();batch uuid;fingerprint text;prior taskfold_private.child_task_completion_batches;
 item jsonb;root public.tasks;observed jsonb:='{}';decoded jsonb;recipients uuid[]:='{}';batch_project_ids uuid[]:='{}';batch_team_ids uuid[]:='{}';roots uuid[];
 uid uuid;team uuid;q uuid;bytes bigint:=0;receipts jsonb:='[]';proof jsonb;
begin
 perform taskfold_private.team_actor();
 perform pg_advisory_xact_lock(hashtextextended(a::text,73918));
 perform taskfold_private.team_actor();perform taskfold_private.validate_child_completion_batch(b,a);
 batch:=taskfold_private.team_uuid(b,'batch_id');fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.child_task_completion_batches where actor_id=a and batch_id=batch;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This selection identity was already used';end if;
  if prior.outcome='closed' then raise exception using errcode='PT410',message='This original selection is closed';end if;
  return taskfold_private.child_completion_batch_receipt(prior,true);
 end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and completion_batches_enabled for share;
 if not found then raise exception using errcode='PT503',message='Subtask selection completion is not enabled';end if;
 perform taskfold_private.require_unused_child_completion_items(b,a);
 if (select count(*) from taskfold_private.child_task_completion_batches where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=128 then
  raise exception using errcode='PT429',message='Too many selection actions; try again later';end if;
 select array_agg(distinct (i->>'task_id')::uuid order by (i->>'task_id')::uuid) into roots from jsonb_array_elements(b->'items') i;
 foreach uid in array roots loop
  select * into root from public.tasks where id=uid;
  if not found then raise exception using errcode='42501',message='A selected task is unavailable';end if;
  team:=null;select team_id into team from taskfold_private.team_content_projects where project_id=root.project_id;
  if team is not null then
   if coalesce(taskfold_private.team_project_role(a,root.project_id),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required for every selected task';end if;
   batch_team_ids:=array_append(batch_team_ids,team);
  elsif taskfold_private.is_team_content_task(uid) or (root.project_id is null and root.user_id<>a)
   or (root.project_id is not null and not coalesce(public.has_project_access(a,root.project_id),false)) then
   raise exception using errcode='42501',message='A selected task is unavailable';end if;
  bytes:=bytes+octet_length(coalesce(root.subtasks,'null'::jsonb)::text);
  if octet_length(coalesce(root.subtasks,'null'::jsonb)::text)>2000000 or bytes>4000000 then raise exception using errcode='54000',message='This selection is too large';end if;
  decoded:=taskfold_private.decode_child_task_tree(root.subtasks);
  if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review a selected hierarchy';end if;
  select recipients||coalesce(array_agg(distinct recipient),'{}') into recipients from (
   select root.assigned_to recipient union select (n->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') n where coalesce(n->'fields'->>'assigned_to','')<>'') x where recipient is not null;
  if root.project_id is not null then batch_project_ids:=array_append(batch_project_ids,root.project_id);end if;
  observed:=observed||jsonb_build_object(uid::text,jsonb_build_object('generation',root.task_generation,'project',root.project_id,'owner',root.user_id,'assigned',root.assigned_to,'tree',root.subtasks));
 end loop;
 -- Non-blocking prelocks avoid inversion with old writers which acquire their
 -- own advisory/recipient/project locks before a root. No resource wait occurs
 -- after taking a root for a new selection. Any conflict rolls back everything.
 perform 1 from auth.users where id=any(recipients) order by id for share nowait;
 perform 1 from taskfold_private.teams where id=any(batch_team_ids) order by id for share nowait;
 perform 1 from taskfold_private.team_project_config where singleton for share nowait;
 perform 1 from taskfold_private.team_config where singleton for share nowait;
 perform 1 from taskfold_private.team_content_projects where project_id=any(batch_project_ids) order by project_id for share nowait;
 perform 1 from public.projects where id=any(batch_project_ids) order by id for share nowait;
 for item in select value from jsonb_array_elements(b->'items') order by value->>'request_id' collate "C" loop
  q:=(item->>'request_id')::uuid;
  if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73917))
   or not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another selected action is finishing';end if;
  team:=null;select team_id into team from taskfold_private.team_content_projects where project_id=(item->>'project_id')::uuid;
  if team is not null and not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) then raise exception using errcode='55P03',message='Another selected action is finishing';end if;
 end loop;
 foreach uid in array roots loop
  if not pg_try_advisory_xact_lock(hashtextextended(uid::text,78137)) then raise exception using errcode='55P03',message='A selected task is changing';end if;
 end loop;
 perform 1 from public.tasks where id=any(roots) order by id for update nowait;
 foreach uid in array roots loop
  select * into root from public.tasks where id=uid;
  if not found or observed->uid::text is distinct from jsonb_build_object('generation',root.task_generation,'project',root.project_id,'owner',root.user_id,'assigned',root.assigned_to,'tree',root.subtasks) then
   raise exception using errcode='PT409',message='A selected task changed; review the selection';end if;
 end loop;
 -- Keep the caller's order in the receipt. Locks and fresh admission have
 -- already been acquired for the entire set. A later exception undoes every
 -- earlier task, node, activity and receipt write in this database statement.
 for item in select * from jsonb_array_elements(b->'items') loop
  proof:=taskfold_private.complete_child_task(item);receipts:=receipts||jsonb_build_array(proof);
 end loop;
 insert into taskfold_private.child_task_completion_batches(actor_id,batch_id,fingerprint,outcome,receipts)
 values(a,batch,fingerprint,'applied',receipts) returning * into prior;
 return taskfold_private.child_completion_batch_receipt(prior,false);
end$$;

-- Closing an original group is metadata-only. It cannot expose current task
-- content or reverse a successful group, and remains usable with rollout off.
create function taskfold_private.close_child_task_batch(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();batch uuid;fingerprint text;prior taskfold_private.child_task_completion_batches;item jsonb;decision jsonb;begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_completion_batch(b,a);
 batch:=taskfold_private.team_uuid(b,'batch_id');fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.child_task_completion_batches where actor_id=a and batch_id=batch;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This selection identity was already used';end if;
  return taskfold_private.child_completion_batch_receipt(prior,true);
 end if;
 perform taskfold_private.require_unused_child_completion_items(b,a);
 if (select count(*) from taskfold_private.child_task_completion_batches where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=128 then
  raise exception using errcode='PT429',message='Too many selection actions; try again later';end if;
 for item in select * from jsonb_array_elements(b->'items') loop
  decision:=taskfold_private.close_child_completion(item);
  if decision->>'outcome'<>'closed' then raise exception using errcode='PT409',message='A selected request already belongs to another action';end if;
 end loop;
 insert into taskfold_private.child_task_completion_batches(actor_id,batch_id,fingerprint,outcome,receipts)
 values(a,batch,fingerprint,'closed','[]') returning * into prior;
 return taskfold_private.child_completion_batch_receipt(prior,false);
end$$;
create function public.taskfold_complete_child_tasks(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.complete_child_task_batch(_body)$$;
create function public.taskfold_close_child_completion_batch(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.close_child_task_batch(_body)$$;
revoke all on function taskfold_private.validate_child_completion_batch(jsonb,uuid),taskfold_private.child_completion_batch_receipt(taskfold_private.child_task_completion_batches,boolean),
 taskfold_private.require_unused_child_completion_items(jsonb,uuid),taskfold_private.complete_child_task_batch(jsonb),taskfold_private.close_child_task_batch(jsonb),
 public.taskfold_complete_child_tasks(jsonb),public.taskfold_close_child_completion_batch(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.complete_child_task_batch(jsonb),taskfold_private.close_child_task_batch(jsonb),
 public.taskfold_complete_child_tasks(jsonb),public.taskfold_close_child_completion_batch(jsonb) to authenticated;
