-- Disk IO budget (20 November 2026).
-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Baseline IO with nobody using the app was dominated by background machinery that
-- ran whether or not there was work:
--   * the webhook scheduler enqueued a pg_net request every minute (HTTP queue row,
--     response row, edge function boot, scheduler row rewritten twice) for an empty outbox;
--   * the audio maintenance scheduler did the same every 15 minutes;
--   * the one-hour time zone cache refresh rewrote all ~1,200 rows each time;
-- Each scheduler now answers "is there work?" with indexed EXISTS probes and returns
-- before it locks or writes anything. Webhook delivery semantics are unchanged: when
-- there is due work the tick behaves exactly as before.

-- 1. Webhook scheduler: skip cheaply when the outbox has nothing to do.
-- Work is (a) a pending/leased event that is due (partial index webhook_outbox_due),
-- (b) a payload past its expiry (webhook_outbox_expiry), (c) finished history older
-- than seven days (webhook_outbox_history_expiry). An hourly heartbeat still ticks so
-- sweeps that depend on subscription state (revoked, removal blocks) run without a
-- cheap index probe for them.
create or replace function taskfold_private.invoke_webhook_worker() returns bigint
language plpgsql security invoker set search_path='' as $$
declare state taskfold_private.webhook_scheduler;token text;n integer;request_id bigint;nonce uuid;issued bigint;proof text;due boolean;
begin
 -- Lock-free read: a disabled or idle scheduler must not dirty its row.
 select * into state from taskfold_private.webhook_scheduler where singleton;
 if not found or not state.enabled then return null;end if;
 -- Record transport health once per request, and only when it changed.
 if state.last_request_id is not null and (state.last_response_at is null or state.last_response_at<state.last_queued_at) then
  update taskfold_private.webhook_scheduler s set last_response_code=r.status_code,
   last_response_timed_out=r.timed_out,last_response_at=r.created
  from net._http_response r where s.singleton and r.id=state.last_request_id
   and (s.last_response_code,s.last_response_timed_out,s.last_response_at) is distinct from (r.status_code,r.timed_out,r.created);
 end if;
 due:=state.last_queued_at is null or state.last_queued_at<=clock_timestamp()-interval '1 hour'
  or exists(select 1 from taskfold_private.webhook_outbox x where x.status in('pending','leased') and x.next_attempt_at<=clock_timestamp())
  or exists(select 1 from taskfold_private.webhook_outbox x where x.payload is not null and x.expires_at<=clock_timestamp())
  or exists(select 1 from taskfold_private.webhook_outbox x where x.payload is null and x.finished_at<clock_timestamp()-interval '7 days');
 if not due then return null;end if;
 -- There is work: serialize with configuration and the other tick, as before.
 select * into state from taskfold_private.webhook_scheduler where singleton for update;
 if not found or not state.enabled then return null;end if;
 -- pg_net sends after commit. A second concurrent tick must not enqueue another
 -- request in the same minute; outbox leases still protect each actual delivery.
 if state.last_queued_at > clock_timestamp()-interval '55 seconds' then return null;end if;
 select count(*),min(decrypted_secret) into n,token from vault.decrypted_secrets where name='taskfold_webhook_worker_token';
 if n<>1 or token is null or token !~ '^[a-f0-9]{64}$' or state.project_ref is null then
  if state.last_state is distinct from 'unconfigured' then
   update taskfold_private.webhook_scheduler set last_state='unconfigured' where singleton;
  end if;
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
  if state.last_state is distinct from 'enqueue_failed' then
   update taskfold_private.webhook_scheduler set last_state='enqueue_failed' where singleton;
  end if;
  return null;
 end;
 update taskfold_private.webhook_scheduler set scheduled_nonce=nonce,scheduled_issued=issued,consumed_at=null,last_request_id=request_id,
  last_queued_at=clock_timestamp(),last_state='queued' where singleton;
 return request_id;
end$$;
revoke all on function taskfold_private.invoke_webhook_worker() from public,anon,authenticated,service_role;

-- 2. Audio maintenance scheduler: only tick when something can be cleaned up.
-- Work is a pending reservation past its expiry (audio_comment_expiry) or any retired
-- publication awaiting Storage cleanup, or blocked by an open upload that the stale
-- fence will settle (audio_comment_cleanup). Retired rows are removed once purged, so
-- an idle account has neither and the worker never boots.
create or replace function taskfold_private.invoke_audio_maintenance_worker() returns bigint
language plpgsql security invoker set search_path='' as $$
declare state taskfold_private.audio_maintenance_scheduler;token text;n integer;request_id bigint;nonce uuid;issued bigint;proof text;due boolean;
begin
 select * into state from taskfold_private.audio_maintenance_scheduler where singleton;
 if not found or not state.enabled then return null;end if;
 if state.last_request_id is not null and (state.last_response_at is null or state.last_response_at<state.last_queued_at) then
  update taskfold_private.audio_maintenance_scheduler s set last_response_code=r.status_code,
   last_response_timed_out=r.timed_out,last_response_at=r.created
  from net._http_response r where s.singleton and r.id=state.last_request_id
   and (s.last_response_code,s.last_response_timed_out,s.last_response_at) is distinct from (r.status_code,r.timed_out,r.created);
 end if;
 due:=exists(select 1 from taskfold_private.audio_comment_publications p where p.state='pending' and p.expires_at<=clock_timestamp())
  or exists(select 1 from taskfold_private.audio_comment_publications p where p.state='retired');
 if not due then return null;end if;
 select * into state from taskfold_private.audio_maintenance_scheduler where singleton for update;
 if not found or not state.enabled then return null;end if;
 if state.last_queued_at > clock_timestamp()-interval '55 seconds' then return null;end if;
 select count(*),min(decrypted_secret) into n,token from vault.decrypted_secrets where name='taskfold_audio_maintenance_key';
 if n<>1 or token is null or token !~ '^[a-f0-9]{64}$' or state.project_ref is null then
  if state.last_state is distinct from 'unconfigured' then
   update taskfold_private.audio_maintenance_scheduler set last_state='unconfigured' where singleton;
  end if;
  return null;
 end if;
 nonce:=gen_random_uuid();issued:=floor(extract(epoch from clock_timestamp()))::bigint;
 proof:=encode(extensions.hmac('taskfold.audio.maintenance.v1.'||issued::text||'.'||nonce::text||'.'||state.project_ref,token,'sha256'),'hex');
 begin
  request_id:=net.http_post(url:='https://'||state.project_ref||'.supabase.co/functions/v1/audio-comment-maintenance',
   headers:=jsonb_build_object('Content-Type','application/json','X-Taskfold-Audio-Schedule',issued::text||'.'||nonce::text||'.'||proof),
   body:='{}'::jsonb,timeout_milliseconds:=25000);
 exception when others then
  if state.last_state is distinct from 'enqueue_failed' then
   update taskfold_private.audio_maintenance_scheduler set last_state='enqueue_failed' where singleton;
  end if;
  return null;
 end;
 update taskfold_private.audio_maintenance_scheduler set scheduled_nonce=nonce,scheduled_issued=issued,consumed_at=null,last_request_id=request_id,
  last_queued_at=clock_timestamp(),last_state='queued' where singleton;
 return request_id;
end$$;
revoke all on function taskfold_private.invoke_audio_maintenance_worker() from public,anon,authenticated,service_role;

-- 3. pg_net keeps each response for six hours by default, and its table grew to 132 MB
-- for a handful of live rows. With the schedulers quiet there is little to keep; one
-- hour is ample for the scheduler's own health read (it reads the response within a
-- minute). The setting takes effect when the pg_net worker restarts
-- (select net.worker_restart(); is part of the deploy steps, not of this migration).
do $$ begin
 execute 'alter role postgres set pg_net.ttl to ''1 hour''';
exception when others then
 raise warning 'pg_net.ttl was not changed (%).',sqlstate;
end $$;

-- 4. Time zone cache: only touch rows that changed. The hourly refresh rewrote every
-- row (about 1,200 updates) although the catalog almost never changes. New names are
-- inserted, removed names deleted, and a single row carries the "refreshed" mark that
-- the one-hour throttle reads. Behaviour for callers is identical.
create or replace function taskfold_private.refresh_reminder_time_zones(_force boolean default false)
returns integer language plpgsql security invoker set search_path='' as $$
declare names text[]; refreshed timestamptz:=clock_timestamp();
begin
 if _force is null then raise exception 'Invalid timezone refresh choice.'; end if;
 if not _force and exists(select 1 from taskfold_private.reminder_time_zones where refreshed_at>refreshed-interval '1 hour') then return 0; end if;
 if not pg_try_advisory_xact_lock(hashtextextended('taskfold.reminder.timezones',78136)) then return 0; end if;
 if not _force and exists(select 1 from taskfold_private.reminder_time_zones where refreshed_at>refreshed-interval '1 hour') then return 0; end if;
 select array_agg(name order by name collate "C") into names from pg_catalog.pg_timezone_names;
 if coalesce(cardinality(names),0)<1 then raise exception 'Timezone catalog is unavailable.'; end if;
 delete from taskfold_private.reminder_time_zones where not(name=any(names));
 insert into taskfold_private.reminder_time_zones(name,refreshed_at) select unnest(names),refreshed
 on conflict(name) do nothing;
 update taskfold_private.reminder_time_zones set refreshed_at=refreshed where name=names[1];
 return cardinality(names);
end $$;
revoke all on function taskfold_private.refresh_reminder_time_zones(boolean) from public,anon,authenticated;
grant execute on function taskfold_private.refresh_reminder_time_zones(boolean) to service_role;

-- 5. Realtime publication is unchanged: current clients join only the tables they need
-- live (Backend.watchChanges), and older installed builds that still join all sixteen
-- keep working. Narrowing the publication can follow once every client has updated.

-- 6. Cron history: the per-minute webhook job writes two run rows a minute, and retention
-- scanned 7 days of them. Keep two days (plenty to debug a failure) so the table stays tiny.
do $$ begin
 if exists (select 1 from cron.job where jobname = 'taskfold-cron-log-retention') then
  perform cron.unschedule('taskfold-cron-log-retention');
 end if;
 perform cron.schedule(
  'taskfold-cron-log-retention',
  '43 3 * * *',
  $job$delete from cron.job_run_details where end_time < now() - interval '2 days'$job$
 );
end $$;

commit;
