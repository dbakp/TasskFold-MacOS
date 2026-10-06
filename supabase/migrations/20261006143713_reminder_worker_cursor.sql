-- A single durable sweep. It stores no provider credentials, tokens or task content.
create table taskfold_private.reminder_worker_cursor (
 singleton boolean primary key default true check (singleton),
 cursor uuid,
 lease uuid,
 lease_until timestamptz,
 retry_at timestamptz not null default '-infinity',
 sweep_started_at timestamptz,
 last_sweep_finished_at timestamptz,
 completed_sweeps bigint not null default 0 check (completed_sweeps>=0),
 last_started_at timestamptz,
 last_finished_at timestamptz,
 last_status text not null default 'idle' check (last_status in ('idle','processed','paused','error')),
 last_counts jsonb not null default '{}',
 check ((lease is null)=(lease_until is null))
);
alter table taskfold_private.reminder_worker_cursor enable row level security;
revoke all on taskfold_private.reminder_worker_cursor from public,anon,authenticated,service_role;
grant select,update on taskfold_private.reminder_worker_cursor to service_role;
insert into taskfold_private.reminder_worker_cursor(singleton) values (true);

create function public.taskfold_claim_reminder_sweep() returns jsonb
language plpgsql security invoker set search_path='' as $$
declare r taskfold_private.reminder_worker_cursor; stamp timestamptz:=clock_timestamp(); nonce uuid:=gen_random_uuid();
begin
 select * into r from taskfold_private.reminder_worker_cursor where singleton for update skip locked;
 stamp:=clock_timestamp();
 if not found or r.retry_at>stamp or r.lease_until>stamp then return null; end if;
 update taskfold_private.reminder_worker_cursor set lease=nonce,lease_until=stamp+interval '2 minutes',
  sweep_started_at=coalesce(sweep_started_at,stamp),last_started_at=stamp where singleton;
 return jsonb_build_object('version',1,'lease',nonce,'after',r.cursor);
end $$;
revoke all on function public.taskfold_claim_reminder_sweep() from public,anon,authenticated;
grant execute on function public.taskfold_claim_reminder_sweep() to service_role;

-- A resumed obsolete worker cannot obtain an address through the scheduled path. Keep the
-- sweep row locked through existing current-task/device/job revalidation, without exposing it.
create function public.taskfold_prepare_sweep_reminder_job(_sweep uuid,_id text,_lease uuid) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare r taskfold_private.reminder_worker_cursor;
begin
 select * into r from taskfold_private.reminder_worker_cursor where singleton for share;
 if _sweep is null or r.lease is distinct from _sweep or r.lease_until<=clock_timestamp() then return null; end if;
 return public.taskfold_prepare_reminder_job(_id,_lease);
end $$;
revoke all on function public.taskfold_prepare_sweep_reminder_job(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.taskfold_prepare_sweep_reminder_job(uuid,text,uuid) to service_role;

-- Only the current, unexpired nonce can publish progress. Error retries never advance.
-- A paused NULL cursor means interrupted at the start, not a completed sweep.
create function public.taskfold_finish_reminder_sweep(_lease uuid,_after uuid,_next uuid,_status text,
 _counts jsonb,_retry_after_seconds int default 0) returns boolean
language plpgsql security invoker set search_path='' as $$
declare r taskfold_private.reminder_worker_cursor; stamp timestamptz:=clock_timestamp(); item record;
begin
 if _lease is null or _status is null or _status not in ('processed','paused','error') or
  _retry_after_seconds is null or _retry_after_seconds not between 0 and 3600 or
  (_status='processed' and _retry_after_seconds<>0) or
  _counts is null or jsonb_typeof(_counts)<>'object' or
  (_counts-array['devices','accepted','retry','failed','obsolete','receiptRejected'])<>'{}'::jsonb or
  not (_counts ?& array['devices','accepted','retry','failed','obsolete','receiptRejected']) then
  raise exception 'Invalid reminder sweep receipt.';
 end if;
 for item in select key,value from jsonb_each(_counts) loop
  if jsonb_typeof(item.value)<>'number' or item.value::text !~ '^(0|[1-9][0-9]?)$' or
   (item.key='devices' and (item.value::text)::int>20) or (item.value::text)::int>80 then
   raise exception 'Invalid reminder sweep counts.';
  end if;
 end loop;
 select * into r from taskfold_private.reminder_worker_cursor where singleton for update;
 stamp:=clock_timestamp();
 if not found or r.lease is distinct from _lease or r.lease_until<=stamp or r.cursor is distinct from _after then return false; end if;
 if (_status='error' and _next is distinct from _after) or
  (_next is not null and _after is not null and _next<_after) or
  (_status='processed' and _next is not null and _next=_after) or
  (_status='paused' and _next is null and _after is not null) then
  raise exception 'Invalid reminder sweep progress.';
 end if;
 update taskfold_private.reminder_worker_cursor set cursor=_next,lease=null,lease_until=null,
  retry_at=stamp+make_interval(secs=>_retry_after_seconds),last_finished_at=stamp,last_status=_status,last_counts=_counts,
  last_sweep_finished_at=case when _status='processed' and _next is null then stamp else last_sweep_finished_at end,
  completed_sweeps=completed_sweeps+case when _status='processed' and _next is null then 1 else 0 end,
  sweep_started_at=case when _status='processed' and _next is null then null else sweep_started_at end
 where singleton;
 return true;
end $$;
revoke all on function public.taskfold_finish_reminder_sweep(uuid,uuid,uuid,text,jsonb,int) from public,anon,authenticated;
grant execute on function public.taskfold_finish_reminder_sweep(uuid,uuid,uuid,text,jsonb,int) to service_role;

-- Aggregate service diagnostics omit the device cursor, lease and all private payloads.
create function public.taskfold_reminder_sweep_status() returns jsonb
language sql security invoker set search_path='' as $$
 select jsonb_build_object('version',1,'running',coalesce(lease_until>clock_timestamp(),false),
  'retry_at',retry_at,'sweep_started_at',sweep_started_at,'last_sweep_finished_at',last_sweep_finished_at,
  'completed_sweeps',completed_sweeps,'last_started_at',last_started_at,'last_finished_at',last_finished_at,
  'last_status',last_status,'last_counts',last_counts) from taskfold_private.reminder_worker_cursor where singleton
$$;
revoke all on function public.taskfold_reminder_sweep_status() from public,anon,authenticated;
grant execute on function public.taskfold_reminder_sweep_status() to service_role;

-- Runs as the cron's database owner. No service/client role can read Vault through this function.
-- Resolve secrets only at execution; neither cron.command nor this migration contains a key.
create function taskfold_private.invoke_reminder_worker() returns bigint
language plpgsql security invoker set search_path='' as $$
declare endpoint text; secret text; n int;
begin
 select count(*),min(decrypted_secret) into n,endpoint from vault.decrypted_secrets where name='taskfold_reminder_project_url';
 if n<>1 or endpoint is null or endpoint !~ '^https://[a-z0-9]{20}\.supabase\.co$' then raise exception 'Native reminder scheduler is not configured.'; end if;
 select count(*),min(decrypted_secret) into n,secret from vault.decrypted_secrets where name='taskfold_reminder_cron_secret';
 if n<>1 or secret is null or length(secret) not between 32 and 512 then raise exception 'Native reminder scheduler is not configured.'; end if;
 return net.http_post(url:=endpoint||'/functions/v1/dispatch-reminders',
  headers:=jsonb_build_object('Content-Type','application/json','x-cron-secret',secret),
  body:='{}'::jsonb,timeout_milliseconds:=60000);
end $$;
revoke all on function taskfold_private.invoke_reminder_worker() from public,anon,authenticated,service_role;

-- Atomic creation + disable: pg_cron cannot observe an armed job at migration commit.
do $$ declare job bigint; begin
 job:=cron.schedule('taskfold-native-reminder-sweep','30 seconds','select taskfold_private.invoke_reminder_worker();');
 perform cron.alter_job(job,active:=false);
end $$;
