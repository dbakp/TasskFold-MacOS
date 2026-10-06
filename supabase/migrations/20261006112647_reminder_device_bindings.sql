-- Private APNs addresses. Clients receive metadata receipts, never another device's token.
create table taskfold_private.reminder_devices (
  id uuid primary key,
  secret_hash bytea not null check (octet_length(secret_hash) = 32),
  revision bigint not null default 0 check (revision between 0 and 9007199254740991),
  user_id uuid references auth.users(id) on delete set null,
  session_id uuid references auth.sessions(id) on delete set null,
  binding jsonb,
  token_hash bytea,
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now(),
  check ((binding is null and token_hash is null) or (binding is not null and user_id is not null and session_id is not null and token_hash is not null))
);
alter table taskfold_private.reminder_devices enable row level security;
revoke all on taskfold_private.reminder_devices from public, anon, authenticated;
grant usage on schema taskfold_private to service_role;
grant select, insert, update, delete on taskfold_private.reminder_devices to service_role;
create index reminder_devices_user on taskfold_private.reminder_devices(user_id);
create index reminder_devices_session on taskfold_private.reminder_devices(session_id);
create index reminder_devices_expiry on taskfold_private.reminder_devices(expires_at) where binding is not null;
create unique index reminder_devices_token on taskfold_private.reminder_devices
((binding->>'platform'),(binding->>'bundle'),(binding->>'environment'),token_hash) where token_hash is not null;

create function taskfold_private.retire_deleted_device_owner()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.user_id is null or new.session_id is null then
    new.user_id := null; new.session_id := null; new.binding := null; new.token_hash := null; new.expires_at := now();
  end if;
  return new;
end $$;
revoke all on function taskfold_private.retire_deleted_device_owner() from public, anon, authenticated;
create trigger retire_deleted_device_owner before update on taskfold_private.reminder_devices
for each row execute function taskfold_private.retire_deleted_device_owner();

create function taskfold_private.reminder_device_receipt(d taskfold_private.reminder_devices)
returns jsonb language sql stable security invoker set search_path = '' as $$
select jsonb_build_object('version',1,'device',d.id,'revision',d.revision,'account',d.user_id,
  'state',case when d.binding is null then 'retired' else 'registered' end,
  'enabled',coalesce((d.binding->>'enabled')::boolean,false),
  'expires_at_ms',floor(extract(epoch from d.expires_at)*1000)::bigint)
$$;
revoke all on function taskfold_private.reminder_device_receipt(taskfold_private.reminder_devices) from public, anon, authenticated;

-- Deliberately privileged: the installation capability can rebind its one row after account switching.
-- No direct table access. The JWT user and live Auth session are verified independently of metadata.
create function taskfold_private.register_reminder_device(_device uuid, _secret text, _revision bigint, _binding jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare owner uuid := auth.uid(); session_key uuid; d taskfold_private.reminder_devices; k text; new_row boolean;
begin
  if owner is null then raise insufficient_privilege using message = 'Sign in to register this device.'; end if;
  begin session_key := (auth.jwt()->>'session_id')::uuid;
  exception when invalid_text_representation then raise insufficient_privilege using message = 'Sign in again to register this device.'; end;
  perform 1 from auth.sessions where id=session_key and user_id=owner and (not_after is null or not_after > now()) for share;
  if not found then raise insufficient_privilege using message = 'Sign in again to register this device.'; end if;
  if _device is null or _secret is null or _secret !~ '^[0-9a-f]{64}$' or _revision is null or _revision not between 1 and 9007199254740991 then
    raise exception 'Invalid device binding command.';
  end if;
  if _binding is null or jsonb_typeof(_binding) <> 'object' or not (_binding ?& array['platform','bundle','environment','token','time_zone','permission','enabled'])
     or (_binding - array['platform','bundle','environment','token','time_zone','permission','enabled']) <> '{}'::jsonb then raise exception 'Invalid device binding document.'; end if;
  foreach k in array array['platform','bundle','environment','token','time_zone','permission'] loop
    if jsonb_typeof(_binding->k) <> 'string' then raise exception 'Invalid device binding document.'; end if;
  end loop;
  if not ((_binding->>'platform'='ios' and _binding->>'bundle'='com.dbakp.taskfold') or (_binding->>'platform'='macos' and _binding->>'bundle'='com.dbakp.taskfold.mac'))
     or _binding->>'environment' not in ('development','production') or _binding->>'permission' not in ('authorized','provisional','denied')
     or jsonb_typeof(_binding->'enabled') <> 'boolean' or (( _binding->>'enabled')::boolean and _binding->>'permission'='denied')
     or length(_binding->>'token') not between 2 and 1024 or mod(length(_binding->>'token'),2) <> 0 or _binding->>'token' !~ '^[0-9a-f]+$'
     or not exists(select 1 from pg_catalog.pg_timezone_names where name=_binding->>'time_zone') then raise exception 'Invalid device binding document.'; end if;
  -- Serialize the per-account active-device bound, including concurrent first registrations.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner::text, 64117));
  select * into d from taskfold_private.reminder_devices where id=_device for update;
  new_row := not found;
  if new_row then
    -- Enrollment is inactive. A later acknowledged revision explicitly activates delivery.
    -- Retiring a not-yet-enrolled device can therefore never race with an active first insert.
    if (_binding->>'enabled')::boolean then raise exception 'Enroll an inactive device before enabling remote delivery.'; end if;
    insert into taskfold_private.reminder_devices(id,secret_hash)
      values(_device,extensions.digest(_secret,'sha256')) on conflict(id) do nothing;
    select * into strict d from taskfold_private.reminder_devices where id=_device for update;
  end if;
  if d.secret_hash <> extensions.digest(_secret,'sha256') then raise insufficient_privilege using message = 'Device binding could not be verified.'; end if;
  if d.revision = _revision and d.user_id = owner and d.session_id = session_key and d.binding = _binding then
    return taskfold_private.reminder_device_receipt(d); -- Identical lost-ack retry does not renew the lease.
  end if;
  if _revision <= d.revision then raise exception 'TASKFOLD_DEVICE_CONFLICT: This device binding has a newer revision.'; end if;
  if (select count(*) from taskfold_private.reminder_devices where user_id=owner and binding is not null and id<>_device) >= 32 then
    raise exception 'This account has reached its limit of 32 registered devices.';
  end if;
  begin
    update taskfold_private.reminder_devices set revision=_revision,user_id=owner,session_id=session_key,binding=_binding,
      token_hash=extensions.digest(_binding->>'token','sha256'),updated_at=now(),expires_at=now()+interval '30 days'
      where id=_device returning * into d;
  exception when unique_violation then raise exception 'This push address is already registered. Retire its earlier device binding before registering it again.'; end;
  return taskfold_private.reminder_device_receipt(d);
end $$;
revoke all on function taskfold_private.register_reminder_device(uuid,text,bigint,jsonb) from public, anon;
grant execute on function taskfold_private.register_reminder_device(uuid,text,bigint,jsonb) to authenticated;

-- Revocation-only capability: can retire its installation even after local sign-out. It cannot enroll,
-- activate, read tokens or discover any other binding. Unknown IDs leave no anonymous storage behind.
create function taskfold_private.retire_reminder_device(_device uuid, _secret text, _revision bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d taskfold_private.reminder_devices;
begin
  if _device is null or _secret is null or _secret !~ '^[0-9a-f]{64}$' or _revision is null or _revision not between 1 and 9007199254740991 then raise exception 'Invalid device retirement command.'; end if;
  select * into d from taskfold_private.reminder_devices where id=_device for update;
  if not found then return jsonb_build_object('version',1,'device',_device,'revision',_revision,'account',null,'state','retired','enabled',false,'expires_at_ms',floor(extract(epoch from now())*1000)::bigint); end if;
  if d.secret_hash <> extensions.digest(_secret,'sha256') then raise insufficient_privilege using message = 'Device binding could not be verified.'; end if;
  if _revision = d.revision and d.binding is null then return taskfold_private.reminder_device_receipt(d); end if;
  if _revision <= d.revision then raise exception 'TASKFOLD_DEVICE_CONFLICT: This device binding has a newer revision.'; end if;
  update taskfold_private.reminder_devices set revision=_revision,user_id=null,session_id=null,binding=null,token_hash=null,updated_at=now(),expires_at=now()
    where id=_device returning * into d;
  return taskfold_private.reminder_device_receipt(d);
end $$;
revoke all on function taskfold_private.retire_reminder_device(uuid,text,bigint) from public;
grant execute on function taskfold_private.retire_reminder_device(uuid,text,bigint) to anon, authenticated;

-- Public API wrappers run as their caller. Privileged writers remain in the unexposed schema.
grant usage on schema taskfold_private to anon, authenticated;
create function public.taskfold_register_reminder_device(_device uuid, _secret text, _revision bigint, _binding jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select taskfold_private.register_reminder_device(_device,_secret,_revision,_binding)
$$;
revoke all on function public.taskfold_register_reminder_device(uuid,text,bigint,jsonb) from public, anon;
grant execute on function public.taskfold_register_reminder_device(uuid,text,bigint,jsonb) to authenticated;
create function public.taskfold_retire_reminder_device(_device uuid, _secret text, _revision bigint)
returns jsonb language sql security invoker set search_path = '' as $$
  select taskfold_private.retire_reminder_device(_device,_secret,_revision)
$$;
revoke all on function public.taskfold_retire_reminder_device(uuid,text,bigint) from public;
grant execute on function public.taskfold_retire_reminder_device(uuid,text,bigint) to anon, authenticated;
