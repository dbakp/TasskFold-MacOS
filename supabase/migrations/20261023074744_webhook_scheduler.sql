-- Inactive candidate. No task data, receiver credentials or worker token in cron.
-- Hosted pg_net grants cannot be changed by postgres. Never enqueue a reusable
-- credential: use a 90-second HMAC proof and one-use private admission instead.
-- Only the database operator can configure or invoke this worker. Native and
-- service roles have neither table access nor function execution privileges.
create table taskfold_private.webhook_scheduler (
 singleton boolean primary key default true check(singleton),
 project_ref text check(project_ref ~ '^[a-z]{20}$'),
 enabled boolean not null default false,
 scheduled_nonce uuid,
 scheduled_issued bigint,
 consumed_at timestamptz,
 last_request_id bigint,
 last_queued_at timestamptz,
 last_response_code integer,
 last_response_timed_out boolean,
 last_response_at timestamptz,
 last_state text not null default 'disabled' check(last_state in('disabled','unconfigured','queued','enqueue_failed')),
 check(not enabled or project_ref is not null)
);
alter table taskfold_private.webhook_scheduler enable row level security;
revoke all on taskfold_private.webhook_scheduler from public,anon,authenticated,service_role;
insert into taskfold_private.webhook_scheduler(singleton) values(true);

create function taskfold_private.configure_webhook_scheduler(_project_ref text,_enabled boolean) returns void
language plpgsql security invoker set search_path='' as $$
declare n integer;token text;job bigint;
begin
 if _enabled is null or (_enabled and (_project_ref is null or _project_ref !~ '^[a-z]{20}$')) then
  raise exception 'Webhook scheduler configuration is invalid.';
 end if;
 select jobid into job from cron.job where jobname='taskfold-webhook-dispatch';
 if job is null then raise exception 'Webhook scheduler job is unavailable.';end if;
 if _enabled then
  select count(*),min(decrypted_secret) into n,token from vault.decrypted_secrets where name='taskfold_webhook_worker_token';
  if n<>1 or token is null or token !~ '^[a-f0-9]{64}$' then raise exception 'Webhook scheduler credential is unavailable.';end if;
 end if;
 -- Serialize configuration with enqueue; disable needs no available credential.
 update taskfold_private.webhook_scheduler set enabled=_enabled,scheduled_nonce=null,scheduled_issued=null,consumed_at=null,
  project_ref=case when _enabled then _project_ref else project_ref end,
  last_state=case when _enabled then 'unconfigured' else 'disabled' end where singleton;
 perform cron.alter_job(job,active:=_enabled);
end$$;
revoke all on function taskfold_private.configure_webhook_scheduler(text,boolean) from public,anon,authenticated,service_role;

create function taskfold_private.invoke_webhook_worker() returns bigint
language plpgsql security invoker set search_path='' as $$
declare state taskfold_private.webhook_scheduler;token text;n integer;request_id bigint;nonce uuid;issued bigint;proof text;
begin
 select * into state from taskfold_private.webhook_scheduler where singleton for update;
 if not found or not state.enabled then return null;end if;
 -- Record only transport health. Response bodies are not copied into our state.
 update taskfold_private.webhook_scheduler s set last_response_code=r.status_code,
  last_response_timed_out=r.timed_out,last_response_at=r.created
 from net._http_response r where s.singleton and r.id=state.last_request_id;
 -- pg_net sends after commit. A second concurrent tick must not enqueue another
 -- request in the same minute; outbox leases still protect each actual delivery.
 if state.last_queued_at > clock_timestamp()-interval '55 seconds' then return null;end if;
 select count(*),min(decrypted_secret) into n,token from vault.decrypted_secrets where name='taskfold_webhook_worker_token';
 if n<>1 or token is null or token !~ '^[a-f0-9]{64}$' or state.project_ref is null then
  update taskfold_private.webhook_scheduler set last_state='unconfigured' where singleton;
  return null;
 end if;
 nonce:=gen_random_uuid();issued:=floor(extract(epoch from clock_timestamp()))::bigint;
 proof:=encode(extensions.hmac('taskfold.webhook.schedule.v1.'||issued::text||'.'||nonce::text||'.'||state.project_ref,token,'sha256'),'hex');
 begin
  request_id:=net.http_post(url:='https://'||state.project_ref||'.supabase.co/functions/v1/dispatch-webhooks',
   headers:=jsonb_build_object('Content-Type','application/json','Authorization','Taskfold-Schedule '||issued::text||'.'||nonce::text||'.'||proof),
   body:='{}'::jsonb,timeout_milliseconds:=60000);
 exception when others then
  -- No SQLERRM: extension errors may contain a request or credential.
  update taskfold_private.webhook_scheduler set last_state='enqueue_failed' where singleton;
  return null;
 end;
 update taskfold_private.webhook_scheduler set scheduled_nonce=nonce,scheduled_issued=issued,consumed_at=null,last_request_id=request_id,
  last_queued_at=clock_timestamp(),last_state='queued' where singleton;
 return request_id;
end$$;
revoke all on function taskfold_private.invoke_webhook_worker() from public,anon,authenticated,service_role;

-- Service-only admission after Edge verifies the HMAC. One signed tick cannot
-- cause several worker runs, even when its transient pg_net header is replayed.
create function taskfold_private.admit_webhook_schedule(_nonce uuid,_issued bigint) returns boolean
language plpgsql security definer set search_path='' as $$
declare changed integer;
begin
 if _nonce is null or _issued is null or _issued < extract(epoch from clock_timestamp())-90 or _issued > extract(epoch from clock_timestamp())+5 then return false;end if;
 update taskfold_private.webhook_scheduler set consumed_at=clock_timestamp()
 where singleton and enabled and scheduled_nonce=_nonce and scheduled_issued=_issued and consumed_at is null;
 get diagnostics changed=row_count;return changed=1;
end$$;
revoke all on function taskfold_private.admit_webhook_schedule(uuid,bigint) from public,anon,authenticated;
grant execute on function taskfold_private.admit_webhook_schedule(uuid,bigint) to service_role;
create function public.taskfold_webhook_schedule_admit(_nonce uuid,_issued bigint) returns boolean
language sql security invoker set search_path='' as $$select taskfold_private.admit_webhook_schedule(_nonce,_issued)$$;
revoke all on function public.taskfold_webhook_schedule_admit(uuid,bigint) from public,anon,authenticated;
grant execute on function public.taskfold_webhook_schedule_admit(uuid,bigint) to service_role;

-- The create/disable pair commits atomically. Applying the migration cannot send.
do $$declare job bigint;begin
 job:=cron.schedule('taskfold-webhook-dispatch','* * * * *','select taskfold_private.invoke_webhook_worker();');
 perform cron.alter_job(job,active:=false);
end$$;
