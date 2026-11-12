-- Disabled local candidate. Only versioned, leased writers can be reclaimed.
alter table taskfold_private.task_file_uploads add column writer_protocol smallint not null default 0 check(writer_protocol in(0,1)),add column object_nonce uuid;
alter table taskfold_private.task_file_uploads add constraint task_file_writer_path check(
 writer_protocol=0 and object_nonce is null or writer_protocol=1 and object_nonce is not null and object_name='team-task-files/v1/'||operation_id::text||'/'||object_nonce::text);
create index task_file_expiring on taskfold_private.task_file_uploads(expires_at,operation_id) where writer_protocol=1 and state='reserved';
create table taskfold_private.task_file_write_attempts (
 ticket_id uuid primary key default gen_random_uuid(),operation_id uuid not null references taskfold_private.task_file_uploads(operation_id),
 state text not null default 'open' check(state in('open','settled')),started_at timestamptz not null default clock_timestamp(),
 settled_at timestamptz,next_probe_at timestamptz not null default clock_timestamp(),
 check((state='open' and settled_at is null) or (state='settled' and settled_at is not null))
);
create index task_file_write_operation on taskfold_private.task_file_write_attempts(operation_id);
create unique index task_file_one_open_write on taskfold_private.task_file_write_attempts(operation_id) where state='open';
create index task_file_write_probe on taskfold_private.task_file_write_attempts(next_probe_at,ticket_id) where state='open';
create table taskfold_private.task_file_cleanup_claims (
 operation_id uuid primary key references taskfold_private.task_file_uploads(operation_id),token uuid not null default gen_random_uuid(),expires_at timestamptz not null default clock_timestamp()+interval '2 minutes'
);
alter table taskfold_private.task_file_write_attempts enable row level security;
alter table taskfold_private.task_file_cleanup_claims enable row level security;
revoke all on taskfold_private.task_file_write_attempts,taskfold_private.task_file_cleanup_claims from public,anon,authenticated,service_role;

-- One shared live-actor budget, including retries, before operation locks.
create function taskfold_private.task_file_admit(a uuid,s uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare n integer;begin
 if not taskfold_private.task_file_actor(a,s) then return jsonb_build_object('status','unavailable');end if;
 insert into taskfold_private.task_file_request_budgets(actor_id,window_start,requests) values(a,date_trunc('minute',clock_timestamp()),1)
 on conflict(actor_id) do update set window_start=excluded.window_start,requests=case when task_file_request_budgets.window_start=excluded.window_start then least(121,task_file_request_budgets.requests+1) else 1 end returning requests into n;
 if n>120 then return jsonb_build_object('status','rate_limited','retry_after',greatest(1,least(60,ceil(extract(epoch from date_trunc('minute',clock_timestamp())+interval '1 minute'-clock_timestamp()))::integer)));end if;
 return null;
end$$;
revoke all on function taskfold_private.task_file_admit(uuid,uuid) from public,anon,authenticated,service_role;
alter function taskfold_private.task_file_command(text,uuid,uuid,jsonb) rename to task_file_sender_command_v2;
revoke all on function taskfold_private.task_file_sender_command_v2(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
do $migration$
declare d text;first integer;last integer;begin
 d:=pg_get_functiondef('taskfold_private.task_file_sender_command_v2(text,uuid,uuid,jsonb)'::regprocedure);
 first:=strpos(d,' insert into taskfold_private.task_file_request_budgets');last:=strpos(d,' if action=''download'' then');
 if first=0 or last<=first then raise exception 'Current sender request budget required';end if;
 execute substring(d from 1 for first-1)||' -- Budget admitted by leased-writer wrapper.'||chr(10)||substring(d from last);
end$migration$;

create function taskfold_private.task_file_reconcile(op uuid,ticket uuid,proof jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare r taskfold_private.task_file_uploads;attempt taskfold_private.task_file_write_attempts;asset storage.objects;n integer;begin
 select * into r from taskfold_private.task_file_uploads where operation_id=op for update;
 if not found or r.writer_protocol<>1 or r.state not in('reserved','cancelled','expired') or r.provider_cleanup_confirmed_at is not null
  or proof->'stored_sha256' is distinct from r.intent->'sha256' or proof->'stored_bytes' is distinct from r.intent->'byte_count' then return jsonb_build_object('protocol',1,'settled',false);end if;
 select * into attempt from taskfold_private.task_file_write_attempts where ticket_id=ticket and operation_id=op for update;
 if not found then return jsonb_build_object('protocol',1,'settled',false);end if;
 if attempt.state='settled' then return jsonb_build_object('protocol',1,'settled',true);end if;
 perform 1 from storage.buckets where id='task-attachments' and not public for share;
 if not found then return jsonb_build_object('protocol',1,'settled',false);end if;
 select count(*) into n from storage.objects where bucket_id='task-attachments' and name=r.object_name;
 if n<>1 then return jsonb_build_object('protocol',1,'settled',false);end if;
 select * into asset from storage.objects where bucket_id='task-attachments' and name=r.object_name for share nowait;
 if coalesce(asset.owner_id,asset.owner::text) is not null or to_jsonb(asset)->'metadata'->'size' is distinct from r.intent->'byte_count'
  or to_jsonb(asset)->'metadata'->'mimetype' is distinct from r.intent->'type' then return jsonb_build_object('protocol',1,'settled',false);end if;
 -- New tickets require metadata absence; existing committed objects never start
 -- a retry POST. Sole-open-ticket + fully hashed committed bytes proves this
 -- admitted write reached Storage. Absence/time elapsed never settles a write.
 update taskfold_private.task_file_write_attempts set state='settled',settled_at=clock_timestamp() where ticket_id=ticket;
 return jsonb_build_object('protocol',1,'settled',true);
end$$;
revoke all on function taskfold_private.task_file_reconcile(uuid,uuid,jsonb) from public,anon,authenticated,service_role;

create function taskfold_private.task_file_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare op uuid;r taskfold_private.task_file_uploads;result jsonb;ticket uuid;existed boolean;asset storage.objects;nonce uuid;begin
 if action is null or action not in('reserve','reserve_fenced','finalize','resolve','cancel','download','upload_begin','upload_settle','upload_reconcile') or jsonb_typeof(b) is distinct from 'object' then raise exception using errcode='22023',message='Invalid file command';end if;
 if action in('upload_settle','upload_reconcile') then
  if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from (case when action='upload_settle' then array['operation_id','ticket_id']::text[] else array['operation_id','stored_bytes','stored_sha256','ticket_id']::text[] end) then raise exception using errcode='22023',message='Invalid upload observation';end if;
  op:=(b->>'operation_id')::uuid;ticket:=(b->>'ticket_id')::uuid;
  perform pg_advisory_xact_lock(hashtextextended('task-file:'||op::text,20261101));
  if action='upload_reconcile' then return taskfold_private.task_file_reconcile(op,ticket,b);end if;
  -- Service-only transport observation, never a native caller's timeout claim.
  perform 1 from taskfold_private.task_file_uploads where operation_id=op and writer_protocol=1 for update;
  if not found then return jsonb_build_object('protocol',1,'settled',false);end if;
  update taskfold_private.task_file_write_attempts set state='settled',settled_at=coalesce(settled_at,clock_timestamp()) where operation_id=op and ticket_id=ticket;
  return jsonb_build_object('protocol',1,'settled',found);
 end if;
 result:=taskfold_private.task_file_admit(a,s);if result is not null then return result;end if;
 if action='reserve' then return jsonb_build_object('status','writer_update_required');end if;
 if action in('resolve','cancel','download') then return taskfold_private.task_file_sender_command_v2(action,a,s,b);end if;
 op:=case when action='finalize' then (b->'intent'->>'operation_id')::uuid else (b->>'operation_id')::uuid end;
 if op is null then raise exception using errcode='22023',message='Missing file operation';end if;
 perform pg_advisory_xact_lock(hashtextextended('task-file:'||op::text,20261101));
 select * into r from taskfold_private.task_file_uploads where operation_id=op for update;existed:=found;
 if action='reserve_fenced' then
  result:=taskfold_private.task_file_sender_command_v2('reserve',a,s,b);
  if result->>'status'<>'reserved' then return result;end if;
  if not existed then
   nonce:=gen_random_uuid();update taskfold_private.task_file_uploads set writer_protocol=1,object_nonce=nonce,object_name='team-task-files/v1/'||op::text||'/'||nonce::text where operation_id=op returning * into r;
  end if;
  if r.writer_protocol<>1 then return jsonb_build_object('status','legacy_unverified');end if;
  return result||jsonb_build_object('writer_protocol',1,'object_name',r.object_name);
 end if;
 if action='upload_begin' then
  if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from array['operation_id']::text[] then raise exception using errcode='22023',message='Invalid write admission';end if;
  if not existed or r.actor_id<>a or r.writer_protocol<>1 then return jsonb_build_object('status','unavailable');end if;
  result:=taskfold_private.task_file_sender_command_v2('reserve',a,s,r.intent);
  if result->>'status'<>'reserved' then return result;end if;
  select ticket_id into ticket from taskfold_private.task_file_write_attempts where operation_id=op and state='open';
  if found then return jsonb_build_object('protocol',1,'writer_protocol',1,'operation_id',op,'object_name',r.object_name,'status','upload_unresolved','ticket_id',ticket);end if;
  if exists(select 1 from storage.objects where bucket_id='task-attachments' and name=r.object_name) then
   return jsonb_build_object('protocol',1,'writer_protocol',1,'operation_id',op,'object_name',r.object_name,'status','verify');end if;
  insert into taskfold_private.task_file_write_attempts(operation_id) values(op) returning ticket_id into ticket;
  return jsonb_build_object('protocol',1,'writer_protocol',1,'operation_id',op,'object_name',r.object_name,'status','upload','ticket_id',ticket);
 end if;
 -- No legacy/untracked/unfinished write may publish through the old API.
 if existed and r.actor_id=a and r.state in('reserved','published') then
  if r.writer_protocol<>1 then return jsonb_build_object('status','legacy_unverified');end if;
  if r.state='reserved' and r.expires_at>clock_timestamp() and (not exists(select 1 from taskfold_private.task_file_write_attempts where operation_id=op and state='settled')
   or exists(select 1 from taskfold_private.task_file_write_attempts where operation_id=op and state='open')) then return jsonb_build_object('status','upload_unresolved');end if;
 end if;
 return taskfold_private.task_file_sender_command_v2(action,a,s,b);
end$$;
revoke all on function taskfold_private.task_file_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.task_file_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_task_file_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.task_file_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_task_file_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_task_file_command(text,uuid,uuid,jsonb) to service_role;

create function taskfold_private.task_file_maintenance(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare r taskfold_private.task_file_uploads;attempt taskfold_private.task_file_write_attempts;claim taskfold_private.task_file_cleanup_claims;op uuid;items jsonb:='[]';begin
 if jsonb_typeof(b) is distinct from 'object' then raise exception using errcode='22023',message='Invalid file maintenance';end if;
 if action in('probe','claim') then
  if b<>'{}'::jsonb then raise exception using errcode='22023',message='Invalid file maintenance';end if;
  update taskfold_private.task_file_uploads set state='expired' where operation_id in(
   select operation_id from taskfold_private.task_file_uploads where writer_protocol=1 and state='reserved' and expires_at<=clock_timestamp()
   order by expires_at,operation_id limit 25 for update skip locked);
  if action='probe' then
   for attempt in select w.* from taskfold_private.task_file_write_attempts w join taskfold_private.task_file_uploads u using(operation_id)
    where w.state='open' and u.writer_protocol=1 and u.state in('cancelled','expired') and w.next_probe_at<=clock_timestamp()
    order by w.next_probe_at,w.ticket_id limit 25 for update of w skip locked loop
    select * into r from taskfold_private.task_file_uploads where operation_id=attempt.operation_id;
    update taskfold_private.task_file_write_attempts set next_probe_at=clock_timestamp()+interval '2 minutes' where ticket_id=attempt.ticket_id;
    items:=items||jsonb_build_array(jsonb_build_object('operation_id',r.operation_id,'ticket_id',attempt.ticket_id,'object_name',r.object_name,'sha256',r.sha256,'byte_count',r.byte_count));
   end loop;
  else
   perform 1 from storage.buckets where id='task-attachments' and not public for share;
   if not found then return jsonb_build_object('protocol',1,'items',items);end if;
   for r in select * from taskfold_private.task_file_uploads u where writer_protocol=1 and state in('cancelled','expired') and provider_cleanup_confirmed_at is null
    and not exists(select 1 from taskfold_private.task_file_write_attempts w where w.operation_id=u.operation_id and w.state='open')
    and (exists(select 1 from taskfold_private.task_file_write_attempts w where w.operation_id=u.operation_id) or not exists(select 1 from storage.objects o where o.bucket_id='task-attachments' and o.name=u.object_name))
    and not exists(select 1 from taskfold_private.task_file_cleanup_claims c where c.operation_id=u.operation_id and c.expires_at>clock_timestamp())
    order by created_at,operation_id limit 25 for update skip locked loop
    insert into taskfold_private.task_file_cleanup_claims(operation_id) values(r.operation_id) on conflict(operation_id) do update set token=gen_random_uuid(),expires_at=clock_timestamp()+interval '2 minutes' returning * into claim;
    items:=items||jsonb_build_array(jsonb_build_object('operation_id',r.operation_id,'object_name',r.object_name,'token',claim.token,'sha256',r.sha256,'byte_count',r.byte_count));
   end loop;
  end if;
  return jsonb_build_object('protocol',1,'items',items);
 elsif action='reconcile' then
  if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from array['operation_id','stored_bytes','stored_sha256','ticket_id']::text[] then raise exception using errcode='22023',message='Invalid file probe';end if;
  return taskfold_private.task_file_reconcile((b->>'operation_id')::uuid,(b->>'ticket_id')::uuid,b);
 elsif action='confirm' then
  if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from array['object_name','operation_id','token']::text[] then raise exception using errcode='22023',message='Invalid cleanup confirmation';end if;
  op:=(b->>'operation_id')::uuid;select * into r from taskfold_private.task_file_uploads where operation_id=op for update;
  if not found or r.writer_protocol<>1 or r.state not in('cancelled','expired') or r.object_name is distinct from b->>'object_name' then return jsonb_build_object('protocol',1,'purged',false);end if;
  select * into claim from taskfold_private.task_file_cleanup_claims where operation_id=op for update;
  if not found or claim.token is distinct from (b->>'token')::uuid then return jsonb_build_object('protocol',1,'purged',false);end if;
  if r.provider_cleanup_confirmed_at is not null then return jsonb_build_object('protocol',1,'purged',true);end if;
  if claim.expires_at<=clock_timestamp()
   or exists(select 1 from taskfold_private.task_file_write_attempts where operation_id=op and state='open')
   or exists(select 1 from storage.objects where bucket_id='task-attachments' and name=r.object_name) then return jsonb_build_object('protocol',1,'purged',false);end if;
  -- Worker must observe provider absence after any necessary API deletion.
  -- SQL adds independent metadata absence. No Storage table writes occur here.
  update taskfold_private.task_file_uploads set provider_cleanup_confirmed_at=clock_timestamp() where operation_id=op;
  -- Keep the matching token as the immutable lost-acknowledgement receipt.
  return jsonb_build_object('protocol',1,'purged',true);
 end if;
 raise exception using errcode='22023',message='Unsupported file maintenance';
end$$;
revoke all on function taskfold_private.task_file_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.task_file_maintenance(text,jsonb) to service_role;
create function public.taskfold_task_file_maintenance(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.task_file_maintenance(_action,_body)$$;
revoke all on function public.taskfold_task_file_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_task_file_maintenance(text,jsonb) to service_role;
notify pgrst,'reload schema';
