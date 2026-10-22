-- Private account-only transport. No task, notification, role or permission write.
-- Public wrappers remain security invoker. Only the narrow private command may
-- write the unexposed table; every path binds auth.uid() and a real Auth account.
create table taskfold_private.location_handoffs (
 user_id uuid not null references auth.users(id) on delete cascade,
 id uuid not null,
 task_id uuid not null references public.tasks(id) on delete cascade,
 task_generation uuid not null,
 completion_version bigint not null check(completion_version between 0 and 9007199254740991),
 authored_at_ms bigint not null check(authored_at_ms between 0 and 253402300799000),
 request_digest text not null check(request_digest ~ '^[0-9a-f]{64}$'),
 payload jsonb,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 state text not null default 'pending' check(state in ('pending','claimed','imported','discarded','expired')),
 claim_device uuid,
 claim_nonce uuid,
 primary key(user_id,id),
 check(isfinite(created_at) and isfinite(expires_at) and expires_at>created_at and expires_at<=created_at+interval '168 hours'),
 check((claim_device is null)=(claim_nonce is null)),
 check(state not in ('claimed','imported') or claim_device is not null),
 check((state in ('pending','claimed') and payload is not null and jsonb_typeof(payload)='object' and octet_length(payload::text)<=2048)
    or (state in ('imported','discarded','expired') and payload is null)),
 check(state<>'pending' or claim_device is null)
);
create index location_handoffs_task on taskfold_private.location_handoffs(task_id);
create index location_handoffs_expiry on taskfold_private.location_handoffs(expires_at) where payload is not null;
create index location_handoffs_retention on taskfold_private.location_handoffs(created_at);
alter table taskfold_private.location_handoffs enable row level security;
revoke all on taskfold_private.location_handoffs from public,anon,authenticated,service_role;
create policy location_handoffs_owner_only on taskfold_private.location_handoffs to authenticated
 using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));

create function taskfold_private.location_handoff_request_valid(_r jsonb)
returns boolean language plpgsql immutable security invoker set search_path='' as $$
declare k text; n numeric;
begin
 if jsonb_typeof(_r) is distinct from 'object' or octet_length(_r::text)>4096 then return false; end if;
 if (select count(*) from jsonb_object_keys(_r))<>12 or not (_r ?& array['version','id','task_id','task_generation','completion_version','authored_at_ms','place_name','latitude_e6','longitude_e6','radius_m','transition','repeats']) or _r->'version'<>'1'::jsonb then return false; end if;
 foreach k in array array['id','task_id','task_generation'] loop
  if jsonb_typeof(_r->k) is distinct from 'string' or (_r->>k) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
 end loop;
 if jsonb_typeof(_r->'place_name') is distinct from 'string' or char_length(_r->>'place_name') not between 1 and 120
  or octet_length(_r->>'place_name')>480 or btrim(_r->>'place_name')='' or btrim(_r->>'place_name')<>(_r->>'place_name') or (_r->>'place_name') ~ '[[:cntrl:]]'
  or jsonb_typeof(_r->'repeats') is distinct from 'boolean' or _r->>'transition' not in ('arrive','leave') or jsonb_typeof(_r->'transition') is distinct from 'string' then return false; end if;
 foreach k in array array['completion_version','authored_at_ms','latitude_e6','longitude_e6','radius_m'] loop
  if jsonb_typeof(_r->k) is distinct from 'number' then return false; end if;
  n:=(_r->>k)::numeric;
  if n<>trunc(n) then return false; end if;
  if (k='completion_version' and n not between 0 and 9007199254740991)
   or (k='authored_at_ms' and n not between 0 and 253402300799000)
   or (k='latitude_e6' and n not between -90000000 and 90000000)
   or (k='longitude_e6' and n not between -180000000 and 180000000)
   or (k='radius_m' and n not between 100 and 5000) then return false; end if;
 end loop;
 return true;
end $$;
revoke all on function taskfold_private.location_handoff_request_valid(jsonb) from public,anon,authenticated,service_role;

-- Mirrors the current tasks SELECT policy, with exact open task incarnation.
create function taskfold_private.location_handoff_task_access(_owner uuid,_task uuid,_generation uuid,_completion bigint)
returns boolean language sql stable security invoker set search_path='' as $$
 select _owner=(select auth.uid()) and exists(select 1 from public.tasks t
  where t.id=_task and t.task_generation=_generation and coalesce(t.completion_version,0)=_completion and not coalesce(t.completed,false)
   and ((t.project_id is null and t.user_id=_owner) or public.has_project_access(_owner,t.project_id)))
$$;
revoke all on function taskfold_private.location_handoff_task_access(uuid,uuid,uuid,bigint) from public,anon,authenticated,service_role;

create function taskfold_private.location_handoff_document(_row taskfold_private.location_handoffs,_device uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('version',1,'account_id',_row.user_id,'id',_row.id,'task_id',_row.task_id,'task_generation',_row.task_generation,
  'completion_version',_row.completion_version,'authored_at_ms',_row.authored_at_ms,
  'created_at_ms',floor(extract(epoch from _row.created_at)*1000)::bigint,'expires_at_ms',floor(extract(epoch from _row.expires_at)*1000)::bigint,
  'state',case when _row.expires_at<=now() and _row.state in ('pending','claimed') then 'expired' else _row.state end,
  'claim_device',_row.claim_device,'available',a.allowed,
  'payload',case when a.allowed and (_row.state='pending' or _row.claim_device=_device) then _row.payload else null end)
 from (select _row.expires_at>now() and _row.state in ('pending','claimed') and
  taskfold_private.location_handoff_task_access(_row.user_id,_row.task_id,_row.task_generation,_row.completion_version) as allowed) a
$$;
revoke all on function taskfold_private.location_handoff_document(taskfold_private.location_handoffs,uuid) from public,anon,authenticated,service_role;

create function taskfold_private.location_handoff_command(_op text,_request jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare owner uuid:=auth.uid(); row taskfold_private.location_handoffs; target uuid; device uuid; nonce uuid; authored timestamptz;
 digest text; body jsonb; items jsonb; canonical jsonb;
begin
 if owner is null or not exists(select 1 from auth.users where id=owner) then raise exception 'Sign in to manage private place drafts.' using errcode='42501'; end if;
 if _op is null or _op not in ('put','list','claim','finish','abandon','discard') or jsonb_typeof(_request) is distinct from 'object' then raise exception 'Unsupported private place draft request.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('taskfold.location-handoff|' || owner::text,0));
 -- Cleanup is owner-scoped here; the hourly job handles inactive accounts too.
 update taskfold_private.location_handoffs set state='expired',payload=null where user_id=owner and expires_at<=now() and state in ('pending','claimed');
 delete from taskfold_private.location_handoffs where user_id=owner and created_at<now()-interval '720 hours';
 if _op='list' then
  device:=nullif(_request->>'device','')::uuid;
  select coalesce(jsonb_agg(taskfold_private.location_handoff_document(h,device) order by h.created_at desc,h.id),'[]'::jsonb)
   into items from taskfold_private.location_handoffs h where h.user_id=owner;
  return jsonb_build_object('version',1,'account_id',owner,'server_now_ms',floor(extract(epoch from now())*1000)::bigint,'items',items);
 elsif _op='put' then
  if not taskfold_private.location_handoff_request_valid(_request) then raise exception 'Review the place and task before sending this draft.' using errcode='22023'; end if;
  target:=(_request->>'id')::uuid;
  -- Canonical integer fields keep equivalent JSON numeric representations idempotent.
  canonical:=_request || jsonb_build_object('version',1,'completion_version',(_request->>'completion_version')::numeric::bigint,'authored_at_ms',(_request->>'authored_at_ms')::numeric::bigint,
   'latitude_e6',(_request->>'latitude_e6')::numeric::bigint,'longitude_e6',(_request->>'longitude_e6')::numeric::bigint,'radius_m',(_request->>'radius_m')::numeric::bigint);
  digest:=encode(sha256(convert_to(canonical::text,'UTF8')),'hex');
  select * into row from taskfold_private.location_handoffs where user_id=owner and id=target for update;
  if found then
   if row.request_digest<>digest then raise exception 'This draft was already sent with different contents. Start a new draft.' using errcode='22023'; end if;
  else
   authored:=to_timestamp((canonical->>'authored_at_ms')::double precision/1000);
   if authored<now()-interval '24 hours' or authored>now()+interval '5 minutes' then raise exception 'This place draft needs a fresh review before sending.' using errcode='22023'; end if;
   if not taskfold_private.location_handoff_task_access(owner,(canonical->>'task_id')::uuid,(canonical->>'task_generation')::uuid,(canonical->>'completion_version')::bigint) then raise exception 'This task changed or is no longer available. Reopen it before sending a place draft.' using errcode='42501'; end if;
   if (select count(*) from taskfold_private.location_handoffs where user_id=owner)>=256
    or (select count(*) from taskfold_private.location_handoffs where user_id=owner and state in ('pending','claimed'))>=32 then raise exception 'Your private place drafts are full. Finish or discard a pending draft before sending another.' using errcode='54000'; end if;
   body:=canonical-array['version','id','task_id','task_generation','completion_version','authored_at_ms'];
   insert into taskfold_private.location_handoffs(user_id,id,task_id,task_generation,completion_version,authored_at_ms,request_digest,payload,expires_at)
    values(owner,target,(canonical->>'task_id')::uuid,(canonical->>'task_generation')::uuid,(canonical->>'completion_version')::bigint,(canonical->>'authored_at_ms')::bigint,digest,body,least(now()+interval '168 hours',authored+interval '168 hours')) returning * into row;
  end if;
 else
  target:=(_request->>'id')::uuid;
  device:=nullif(_request->>'device','')::uuid; nonce:=nullif(_request->>'nonce','')::uuid;
  select * into row from taskfold_private.location_handoffs where user_id=owner and id=target for update;
  if not found then raise exception 'This private place draft is unavailable.' using errcode='42501'; end if;
  if _op='discard' then
   if row.state='claimed' then raise exception 'Review has started on a device. Finish or cancel that review on the same device.' using errcode='22023'; end if;
   if row.state='pending' then update taskfold_private.location_handoffs set state='discarded',payload=null where user_id=owner and id=target returning * into row; end if;
  else
   if device is null or nonce is null then raise exception 'Reopen the saved review on this device.' using errcode='22023'; end if;
   if _op='claim' and row.state='pending' then
    if row.expires_at<=now() or not taskfold_private.location_handoff_task_access(owner,row.task_id,row.task_generation,row.completion_version) then raise exception 'This place draft expired or its task changed. Start a new draft.' using errcode='42501'; end if;
    update taskfold_private.location_handoffs set state='claimed',claim_device=device,claim_nonce=nonce where user_id=owner and id=target returning * into row;
   elsif row.claim_device is distinct from device or row.claim_nonce is distinct from nonce then
    raise exception 'This draft belongs to a different device review.' using errcode='42501';
   end if;
   if _op='claim' and row.state not in ('claimed','imported') then raise exception 'This draft is no longer waiting for review.' using errcode='22023'; end if;
   if _op in ('finish','abandon') and row.state='claimed' then
    update taskfold_private.location_handoffs set state=case when _op='finish' then 'imported' else 'discarded' end,payload=null where user_id=owner and id=target returning * into row;
   end if;
  end if;
 end if;
 return jsonb_build_object('version',1,'account_id',owner,'server_now_ms',floor(extract(epoch from now())*1000)::bigint,
  'items',jsonb_build_array(taskfold_private.location_handoff_document(row,device)));
end $$;
revoke all on function taskfold_private.location_handoff_command(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.location_handoff_command(text,jsonb) to authenticated;

create function public.taskfold_location_handoff_put(_request jsonb) returns jsonb language sql volatile security invoker set search_path='' as $$ select taskfold_private.location_handoff_command('put',_request) $$;
create function public.taskfold_location_handoff_list(_device uuid default null) returns jsonb language sql volatile security invoker set search_path='' as $$ select taskfold_private.location_handoff_command('list',jsonb_build_object('device',_device)) $$;
create function public.taskfold_location_handoff_claim(_id uuid,_device uuid,_nonce uuid) returns jsonb language sql volatile security invoker set search_path='' as $$ select taskfold_private.location_handoff_command('claim',jsonb_build_object('id',_id,'device',_device,'nonce',_nonce)) $$;
create function public.taskfold_location_handoff_finish(_id uuid,_device uuid,_nonce uuid) returns jsonb language sql volatile security invoker set search_path='' as $$ select taskfold_private.location_handoff_command('finish',jsonb_build_object('id',_id,'device',_device,'nonce',_nonce)) $$;
create function public.taskfold_location_handoff_abandon(_id uuid,_device uuid,_nonce uuid) returns jsonb language sql volatile security invoker set search_path='' as $$ select taskfold_private.location_handoff_command('abandon',jsonb_build_object('id',_id,'device',_device,'nonce',_nonce)) $$;
create function public.taskfold_location_handoff_discard(_id uuid) returns jsonb language sql volatile security invoker set search_path='' as $$ select taskfold_private.location_handoff_command('discard',jsonb_build_object('id',_id)) $$;
revoke all on function public.taskfold_location_handoff_put(jsonb),public.taskfold_location_handoff_list(uuid),public.taskfold_location_handoff_claim(uuid,uuid,uuid),public.taskfold_location_handoff_finish(uuid,uuid,uuid),public.taskfold_location_handoff_abandon(uuid,uuid,uuid),public.taskfold_location_handoff_discard(uuid) from public,anon,service_role;
grant execute on function public.taskfold_location_handoff_put(jsonb),public.taskfold_location_handoff_list(uuid),public.taskfold_location_handoff_claim(uuid,uuid,uuid),public.taskfold_location_handoff_finish(uuid,uuid,uuid),public.taskfold_location_handoff_abandon(uuid,uuid,uuid),public.taskfold_location_handoff_discard(uuid) to authenticated;

create function taskfold_private.prune_location_handoffs() returns void language plpgsql security definer set search_path='' as $$
begin
 update taskfold_private.location_handoffs set state='expired',payload=null where expires_at<=now() and payload is not null;
 delete from taskfold_private.location_handoffs where created_at<now()-interval '720 hours';
end $$;
revoke all on function taskfold_private.prune_location_handoffs() from public,anon,authenticated,service_role;
do $$ begin
 if exists(select 1 from cron.job where jobname='taskfold-location-handoff-retention') then raise exception 'Private place retention job already exists; inspect it before migration.'; end if;
 perform cron.schedule('taskfold-location-handoff-retention','17 * * * *','select taskfold_private.prune_location_handoffs()');
end $$;
