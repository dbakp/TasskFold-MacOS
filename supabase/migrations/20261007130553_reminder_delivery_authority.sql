-- A durable native local/remote handoff. General delivery remains disabled.
create table taskfold_private.reminder_authority_rollout (
 singleton boolean primary key default true check (singleton),
 version integer not null default 1 check (version=1),
 enabled boolean not null default false
);
insert into taskfold_private.reminder_authority_rollout(singleton) values(true);
alter table taskfold_private.reminder_authority_rollout enable row level security;
revoke all on taskfold_private.reminder_authority_rollout from public,anon,authenticated;
grant select on taskfold_private.reminder_authority_rollout to authenticated,service_role;
grant update on taskfold_private.reminder_authority_rollout to service_role;
create policy authority_rollout_read on taskfold_private.reminder_authority_rollout
 for select to authenticated using ((select auth.uid()) is not null);

-- Expiring, owner-visible pilots let disposable-account transport tests run without
-- enabling the provider or changing any real account's delivery choice.
create table taskfold_private.reminder_authority_pilots (
 user_id uuid primary key references auth.users(id) on delete cascade,
 expires_at timestamptz not null
);
alter table taskfold_private.reminder_authority_pilots enable row level security;
revoke all on taskfold_private.reminder_authority_pilots from public,anon,authenticated;
grant select on taskfold_private.reminder_authority_pilots to authenticated;
grant select,insert,update,delete on taskfold_private.reminder_authority_pilots to service_role;
create policy authority_pilot_read on taskfold_private.reminder_authority_pilots
 for select to authenticated using (user_id=(select auth.uid()));

alter table taskfold_private.reminder_devices
 add column authority_nonce uuid,
 add column authority_revision bigint,
 add column authority_cutoff_ms bigint,
 add constraint reminder_authority_capture check (
  (authority_nonce is null and authority_revision is null and authority_cutoff_ms is null) or
  (authority_nonce is not null and authority_revision is not null and authority_cutoff_ms is not null
   and authority_revision between 1 and 9007199254740991
   and authority_cutoff_ms between 0 and 4133980800000));

-- Preserve existing permission/account/time-zone epoch rules, then enforce the
-- drained local cutoff only for a proven current activation revision. Integer
-- millisecond arithmetic keeps the inclusive boundary exact.
create or replace function taskfold_private.reminder_activation_epoch()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if coalesce(new.binding->>'enabled','false')<>'true' or coalesce(new.binding->>'permission','') not in ('authorized','provisional') then
  new.enabled_since:=null;
 elsif tg_op='INSERT' then new.enabled_since:=clock_timestamp();
 elsif old.enabled_since is null or new.user_id is distinct from old.user_id
   or new.binding->>'time_zone' is distinct from old.binding->>'time_zone' then new.enabled_since:=clock_timestamp();
 else new.enabled_since:=old.enabled_since;
 end if;
 if new.enabled_since is not null and new.authority_nonce is not null
  and new.authority_revision=new.revision and new.authority_cutoff_ms is not null then
  new.enabled_since:=greatest(new.enabled_since,
   timestamptz 'epoch'+(new.authority_cutoff_ms+1)*interval '1 millisecond');
 end if;
 return new;
end $$;
revoke all on function taskfold_private.reminder_activation_epoch() from public,anon,authenticated;

create function public.taskfold_reminder_delivery_available()
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('version',1,'account',auth.uid(),'available',
  auth.uid() is not null and
  (exists(select 1 from taskfold_private.reminder_authority_rollout where singleton and enabled) or
   exists(select 1 from taskfold_private.reminder_authority_pilots where user_id=auth.uid() and expires_at>now())))
$$;
revoke all on function public.taskfold_reminder_delivery_available() from public,anon;
grant execute on function public.taskfold_reminder_delivery_available() to authenticated;

-- Device and provider preparation use the same row lock. The current server time
-- is the resume cutoff; a retry cannot replay past remote-eligible events locally.
create or replace function taskfold_private.reminder_device_receipt(d taskfold_private.reminder_devices)
returns jsonb language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('version',1,'device',d.id,'revision',d.revision,'account',d.user_id,
  'state',case when d.binding is null then 'retired' else 'registered' end,
  'enabled',coalesce((d.binding->>'enabled')::boolean,false),
  'expires_at_ms',floor(extract(epoch from d.expires_at)*1000)::bigint,
  'authority_version',1,'server_time_ms',floor(extract(epoch from clock_timestamp())*1000)::bigint,
  'enabled_since_ms',case when d.binding->>'enabled'='true' then floor(extract(epoch from d.enabled_since)*1000)::bigint else null end,
  'authority_nonce',case when d.binding->>'enabled'='true' and d.authority_revision=d.revision then d.authority_nonce else null end)
$$;
revoke all on function taskfold_private.reminder_device_receipt(taskfold_private.reminder_devices) from public,anon,authenticated;

-- Preserve inactive/legacy enrollment. An available authority rollout accepts
-- activation only through the new explicit drain/nonce contract.
create or replace function public.taskfold_register_reminder_device(_device uuid,_secret text,_revision bigint,_binding jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 if _binding->>'enabled'='true' and (public.taskfold_reminder_delivery_available()->>'available')::boolean then
  raise exception 'Use the current app to switch reminder delivery.';
 end if;
 return taskfold_private.register_reminder_device(_device,_secret,_revision,_binding);
end $$;
revoke all on function public.taskfold_register_reminder_device(uuid,text,bigint,jsonb) from public,anon;
grant execute on function public.taskfold_register_reminder_device(uuid,text,bigint,jsonb) to authenticated;

-- Deliberately privileged, unexposed writer: ownership/live-session/installation
-- proof are checked by the existing register function before authority metadata is
-- read or changed. Its advisory/device lock order is retained.
create function taskfold_private.activate_reminder_device(_device uuid,_secret text,_revision bigint,_binding jsonb,
 _local_cutoff_ms bigint,_authority_nonce uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d taskfold_private.reminder_devices; cutoff_now bigint;
begin
 if auth.uid() is null then raise insufficient_privilege using message='Sign in to switch reminder delivery.'; end if;
 if not (public.taskfold_reminder_delivery_available()->>'available')::boolean then
  raise exception 'Remote reminders are not available for this account yet.';
 end if;
 cutoff_now:=floor(extract(epoch from clock_timestamp())*1000)::bigint;
 if _authority_nonce is null or _local_cutoff_ms is null or _local_cutoff_ms not between 0 and 4133980800000
  or _local_cutoff_ms>cutoff_now+300000 or coalesce(_binding->>'enabled','false')<>'true' then
  raise exception 'Invalid reminder delivery handoff.';
 end if;
 perform taskfold_private.register_reminder_device(_device,_secret,_revision,_binding);
 select * into strict d from taskfold_private.reminder_devices where id=_device for update;
 if d.authority_revision=_revision then
  if d.authority_nonce is distinct from _authority_nonce or d.authority_cutoff_ms is distinct from _local_cutoff_ms then
   raise exception 'TASKFOLD_DEVICE_CONFLICT: This delivery handoff has different metadata.';
  end if;
 else
  update taskfold_private.reminder_devices set authority_nonce=_authority_nonce,authority_revision=_revision,
   authority_cutoff_ms=_local_cutoff_ms
   where id=_device returning * into d;
 end if;
 return taskfold_private.reminder_device_receipt(d);
end $$;
revoke all on function taskfold_private.activate_reminder_device(uuid,text,bigint,jsonb,bigint,uuid) from public,anon;
grant execute on function taskfold_private.activate_reminder_device(uuid,text,bigint,jsonb,bigint,uuid) to authenticated;
create function public.taskfold_activate_reminder_device(_device uuid,_secret text,_revision bigint,_binding jsonb,
 _local_cutoff_ms bigint,_authority_nonce uuid)
returns jsonb language sql security invoker set search_path='' as $$
 select taskfold_private.activate_reminder_device(_device,_secret,_revision,_binding,_local_cutoff_ms,_authority_nonce)
$$;
revoke all on function public.taskfold_activate_reminder_device(uuid,text,bigint,jsonb,bigint,uuid) from public,anon;
grant execute on function public.taskfold_activate_reminder_device(uuid,text,bigint,jsonb,bigint,uuid) to authenticated;

-- Unknown-device retirement is also authoritative and stores no anonymous row.
create or replace function public.taskfold_retire_reminder_device(_device uuid,_secret text,_revision bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r jsonb;
begin
 r:=taskfold_private.retire_reminder_device(_device,_secret,_revision);
 return r||jsonb_build_object('authority_version',1,
  'server_time_ms',floor(extract(epoch from clock_timestamp())*1000)::bigint,'enabled_since_ms',null,'authority_nonce',null);
end $$;
revoke all on function public.taskfold_retire_reminder_device(uuid,text,bigint) from public;
grant execute on function public.taskfold_retire_reminder_device(uuid,text,bigint) to anon,authenticated;

-- Only the scheduled provider path enforces the new authority marker. Direct,
-- service-only projection/preparation remains compatible for contract diagnostics.
create or replace function public.taskfold_prepare_sweep_reminder_job(_sweep uuid,_id text,_lease uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare cursor_row taskfold_private.reminder_worker_cursor; d taskfold_private.reminder_devices;
 j taskfold_private.reminder_jobs; payload jsonb;
begin
 select * into cursor_row from taskfold_private.reminder_worker_cursor where singleton for share;
 if _sweep is null or cursor_row.lease is distinct from _sweep or cursor_row.lease_until<=clock_timestamp() then return null; end if;
 -- Existing preparation locks device then job and rechecks current grants,
 -- generation, schedule, opt-in, binding, session and lease before returning.
 payload:=public.taskfold_prepare_reminder_job(_id,_lease);
 if payload is null then return null; end if;
 select * into strict j from taskfold_private.reminder_jobs where id=_id;
 select * into strict d from taskfold_private.reminder_devices where id=j.device_id;
 if d.authority_nonce is null or d.authority_revision is distinct from d.revision or j.fire_at>clock_timestamp() or not
  (exists(select 1 from taskfold_private.reminder_authority_rollout where singleton and enabled) or
   exists(select 1 from taskfold_private.reminder_authority_pilots where user_id=d.user_id and expires_at>clock_timestamp())) then return null; end if;
 return payload;
end $$;
revoke all on function public.taskfold_prepare_sweep_reminder_job(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.taskfold_prepare_sweep_reminder_job(uuid,text,uuid) to service_role;
