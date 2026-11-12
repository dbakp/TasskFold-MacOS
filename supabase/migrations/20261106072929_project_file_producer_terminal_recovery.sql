-- A service producer owns only the write ticket it actually created. A lost
-- reservation reply can be closed without guessing that an absent upload ended.
create table taskfold_private.project_file_copy_producers (
 producer_id uuid primary key,
 plan_id uuid not null references taskfold_private.project_file_preparations(id) on delete cascade,
 operation_id uuid not null references taskfold_private.project_file_preparation_items(operation_id) on delete cascade,
 actor_id uuid not null,
 ticket_id uuid unique,
 closed_at timestamptz,
 proof text check(proof in('not_started','provider_terminal','verified')),
 check((closed_at is null and proof is null) or (closed_at is not null and proof is not null))
);
create index project_file_copy_producers_operation on taskfold_private.project_file_copy_producers(operation_id);
alter table taskfold_private.project_file_copy_producers enable row level security;
revoke all on taskfold_private.project_file_copy_producers from public,anon,authenticated,service_role;

alter function taskfold_private.project_file_preparation_impl(text,uuid,jsonb) rename to project_file_preparation_before_producers;
revoke all on function taskfold_private.project_file_preparation_before_producers(text,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.project_file_preparation_impl(action text,a uuid,b jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare p taskfold_private.project_file_preparations;j taskfold_private.project_file_preparation_items;
 c taskfold_private.project_file_copy_producers;r jsonb;producer uuid;
begin
 if action<>'reserve_producer' then return taskfold_private.project_file_preparation_before_producers(action,a,b);end if;
 if a is distinct from auth.uid() then return jsonb_build_object('status','unavailable');end if;
 perform taskfold_private.project_adoption_fields(b,array['plan_id','operation_id','producer_id','sha256','byte_count']);
 perform taskfold_private.team_uuid(b,'plan_id');perform taskfold_private.team_uuid(b,'operation_id');perform taskfold_private.team_uuid(b,'producer_id');
 producer:=(b->>'producer_id')::uuid;
 -- Keep the existing plan -> item -> operation -> writer lock order.
 select * into p from taskfold_private.project_file_preparations where id=(b->>'plan_id')::uuid and actor_id=a for update nowait;
 if not found then return jsonb_build_object('status','unavailable');end if;
 select * into j from taskfold_private.project_file_preparation_items where plan_id=p.id and operation_id=(b->>'operation_id')::uuid for update nowait;
 if not found then return jsonb_build_object('status','unavailable');end if;
 if not pg_try_advisory_xact_lock(hashtextextended('task-file:'||j.operation_id::text,20261101)) then return jsonb_build_object('status','busy');end if;
 select * into c from taskfold_private.project_file_copy_producers where producer_id=producer for update;
 if found then
  if c.plan_id<>p.id or c.operation_id<>j.operation_id or c.actor_id<>a then return jsonb_build_object('status','conflict');end if;
  if c.closed_at is not null then return jsonb_build_object('status','producer_closed');end if;
 else
  insert into taskfold_private.project_file_copy_producers(producer_id,plan_id,operation_id,actor_id) values(producer,p.id,j.operation_id,a) returning * into c;
 end if;
 r:=taskfold_private.project_file_preparation_before_producers('reserve',a,b-'producer_id');
 if r->>'status'='upload' then
  -- A verify reply may refer to somebody else's unresolved ticket. Never bind
  -- it to this producer or let that producer close the other writer.
  if c.ticket_id is not null then raise exception using errcode='PT409',message='This producer already owns a write';end if;
  update taskfold_private.project_file_copy_producers set ticket_id=(r->>'ticket_id')::uuid where producer_id=producer;
 end if;
 return r;
exception when lock_not_available then return jsonb_build_object('status','busy');
end$$;
revoke all on function taskfold_private.project_file_preparation_impl(text,uuid,jsonb) from public,anon,authenticated,service_role;

-- A trusted service observation, never a native timeout/absence assertion.
-- Settlement remains available after actor/session/access or gate departure.
create function taskfold_private.project_file_producer_terminal(a uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare p taskfold_private.project_file_preparations;j taskfold_private.project_file_preparation_items;
 c taskfold_private.project_file_copy_producers;u taskfold_private.task_file_uploads;w taskfold_private.task_file_write_attempts;
 producer uuid;observation text;
begin
 perform taskfold_private.project_adoption_fields(b,array['plan_id','operation_id','producer_id','proof']);
 perform taskfold_private.team_uuid(b,'plan_id');perform taskfold_private.team_uuid(b,'operation_id');perform taskfold_private.team_uuid(b,'producer_id');
 observation:=b->>'proof';producer:=(b->>'producer_id')::uuid;
 if jsonb_typeof(b->'proof') is distinct from 'string' or observation not in('not_started','provider_terminal','verified') then raise exception using errcode='22023',message='Use a supported producer observation';end if;
 select * into p from taskfold_private.project_file_preparations where id=(b->>'plan_id')::uuid and actor_id=a for update nowait;
 if not found then return jsonb_build_object('protocol',1,'settled',false);end if;
 select * into j from taskfold_private.project_file_preparation_items where plan_id=p.id and operation_id=(b->>'operation_id')::uuid for update nowait;
 if not found then return jsonb_build_object('protocol',1,'settled',false);end if;
 if not pg_try_advisory_xact_lock(hashtextextended('task-file:'||j.operation_id::text,20261101)) then return jsonb_build_object('protocol',1,'settled',false);end if;
 select * into c from taskfold_private.project_file_copy_producers where producer_id=producer for update;
 if found then
  if c.plan_id<>p.id or c.operation_id<>j.operation_id or c.actor_id<>a then return jsonb_build_object('protocol',1,'settled',false);end if;
  if c.closed_at is not null then return jsonb_build_object('protocol',1,'settled',c.proof=observation);end if;
 else
  if observation<>'not_started' then return jsonb_build_object('protocol',1,'settled',false);end if;
  -- Closing before a delayed reservation commits prevents that producer from
  -- ever receiving a new upload grant. It does not settle any existing writer.
  insert into taskfold_private.project_file_copy_producers(producer_id,plan_id,operation_id,actor_id,closed_at,proof)
   values(producer,p.id,j.operation_id,a,clock_timestamp(),observation);
  return jsonb_build_object('protocol',1,'settled',true);
 end if;
 if c.ticket_id is not null then
  select * into u from taskfold_private.task_file_uploads where operation_id=j.operation_id and actor_id=a and writer_protocol=1 for update;
  if not found then return jsonb_build_object('protocol',1,'settled',false);end if;
  select * into w from taskfold_private.task_file_write_attempts where ticket_id=c.ticket_id and operation_id=j.operation_id for update;
  if not found or (observation='verified' and w.state<>'settled') then return jsonb_build_object('protocol',1,'settled',false);end if;
  update taskfold_private.task_file_write_attempts set state='settled',settled_at=coalesce(settled_at,clock_timestamp()) where ticket_id=w.ticket_id;
 elsif observation<>'not_started' then return jsonb_build_object('protocol',1,'settled',false);
 end if;
 update taskfold_private.project_file_copy_producers set closed_at=clock_timestamp(),proof=observation where producer_id=producer;
 return jsonb_build_object('protocol',1,'settled',true);
exception when lock_not_available then return jsonb_build_object('protocol',1,'settled',false);
end$$;
revoke all on function taskfold_private.project_file_producer_terminal(uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.project_file_producer_terminal(uuid,jsonb) to service_role;
create function public.taskfold_project_file_producer_terminal(_actor uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.project_file_producer_terminal(_actor,_body)$$;
revoke all on function public.taskfold_project_file_producer_terminal(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_project_file_producer_terminal(uuid,jsonb) to service_role;
notify pgrst,'reload schema';
