-- Local candidate. Sender history is not live task/file read authority.
create table taskfold_private.task_file_sender_stops (
 actor_id uuid not null references auth.users(id) on delete cascade,
 operation_id uuid not null,created_at timestamptz not null default clock_timestamp(),
 primary key(actor_id,operation_id)
);
alter table taskfold_private.task_file_sender_stops enable row level security;
revoke all on taskfold_private.task_file_sender_stops from public,anon,authenticated,service_role;
create function taskfold_private.task_file_sender_stop_receipt(a uuid,op uuid) returns jsonb
language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'sender_stop_protocol',1,'account',a,'operation_id',op,'state','cancelled')
$$;
revoke all on function taskfold_private.task_file_sender_stop_receipt(uuid,uuid) from public,anon,authenticated,service_role;

-- Preserve validation/publication/download logic privately. Admission is moved
-- once to the new wrapper so sender-only responses use the same request budget.
alter function taskfold_private.task_file_command(text,uuid,uuid,jsonb) rename to task_file_command_v1;
revoke all on function taskfold_private.task_file_command_v1(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
do $migration$
declare d text;first integer;last integer;begin
 d:=pg_get_functiondef('taskfold_private.task_file_command_v1(text,uuid,uuid,jsonb)'::regprocedure);
 first:=strpos(d,' -- Include retries and both download authorization passes');last:=strpos(d,' if action=''download'' then');
 if first=0 or last<=first then raise exception 'Current task file request admission required';end if;
 execute substring(d from 1 for first-1)||' -- Request budget admitted by the sender wrapper.'||chr(10)||substring(d from last);
end$migration$;
create function taskfold_private.task_file_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare op uuid;r taskfold_private.task_file_uploads;requests integer;begin
 if action is null or action not in('reserve','finalize','resolve','cancel','download') or jsonb_typeof(b) is distinct from 'object' then raise exception using errcode='22023',message='Invalid file operation';end if;
 if not taskfold_private.task_file_actor(a,s) then return jsonb_build_object('status','unavailable');end if;
 insert into taskfold_private.task_file_request_budgets(actor_id,window_start,requests) values(a,date_trunc('minute',clock_timestamp()),1)
 on conflict(actor_id) do update set window_start=excluded.window_start,
 requests=case when task_file_request_budgets.window_start=excluded.window_start then least(121,task_file_request_budgets.requests+1) else 1 end
 returning task_file_request_budgets.requests into requests;
 if requests>120 then return jsonb_build_object('status','rate_limited','retry_after',greatest(1,least(60,ceil(extract(epoch from date_trunc('minute',clock_timestamp())+interval '1 minute'-clock_timestamp()))::integer)));end if;
 if action='download' then return taskfold_private.task_file_command_v1(action,a,s,b);end if;
 if action in('resolve','cancel') then
  if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from array['operation_id']::text[] or jsonb_typeof(b->'operation_id') is distinct from 'string' then raise exception using errcode='22023',message='Invalid sender request';end if;
  op:=(b->>'operation_id')::uuid;
 elsif action='reserve' then op:=(b->>'operation_id')::uuid;
 else op:=(b->'intent'->>'operation_id')::uuid;end if;
 if op is null then raise exception using errcode='22023',message='Missing file operation';end if;
 -- Exactly the same operation lock as reserve/finalize: an unknown stop cannot
 -- race a first reservation or turn a committed publication into cancellation.
 perform pg_advisory_xact_lock(hashtextextended('task-file:'||op::text,20261101));
 if exists(select 1 from taskfold_private.task_file_sender_stops where actor_id=a and operation_id=op) then
  return jsonb_build_object('status','cancelled','receipt',taskfold_private.task_file_sender_stop_receipt(a,op));
 end if;
 select * into r from taskfold_private.task_file_uploads where operation_id=op for update;
 if found and r.actor_id=a then
  if action in('resolve','cancel') then
   if r.state='reserved' and (action='cancel' or r.expires_at<=clock_timestamp()) then
    update taskfold_private.task_file_uploads set state=case when action='cancel' then 'cancelled' else 'expired' end where operation_id=op returning * into r;
   end if;
   -- Only immutable sender-owned data. No current task, project, discussion,
   -- provider path or new download authority is disclosed here.
   return jsonb_build_object('status',r.state,'receipt',taskfold_private.task_file_receipt(r));
  end if;
  if r.state in('cancelled','expired') then return jsonb_build_object('status',r.state,'receipt',taskfold_private.task_file_receipt(r));end if;
 end if;
 if action='cancel' then
  -- No reservation exists for this sender. Fence this sender's operation key,
  -- without claiming that another actor's colliding UUID belongs to them.
  -- No file bytes, intent or provider location are created or changed.
  if (select count(*) from taskfold_private.task_file_sender_stops where actor_id=a)>=1024 then return jsonb_build_object('status','quota');end if;
  insert into taskfold_private.task_file_sender_stops(actor_id,operation_id) values(a,op);
  return jsonb_build_object('status','cancelled','receipt',taskfold_private.task_file_sender_stop_receipt(a,op));
 end if;
 if action='resolve' then return jsonb_build_object('status','unavailable');end if;
 return taskfold_private.task_file_command_v1(action,a,s,b);
end$$;
revoke all on function taskfold_private.task_file_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.task_file_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_task_file_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.task_file_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_task_file_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_task_file_command(text,uuid,uuid,jsonb) to service_role;
notify pgrst,'reload schema';
