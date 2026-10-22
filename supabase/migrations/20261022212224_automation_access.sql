grant usage on schema taskfold_private to service_role;

-- Device-generated 256-bit API secrets never reach this schema: only SHA-256.
-- This credential foundation does not grant direct table access or publish a task API.
create table taskfold_private.automation_keys (
 id uuid primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 name text not null check(char_length(name) between 1 and 80 and octet_length(name)<=320),
 token_hash text not null unique check(token_hash ~ '^[0-9a-f]{64}$'),
 scopes text[] not null check(cardinality(scopes) between 1 and 5 and scopes <@ array['tasks:read','tasks:create','tasks:update','tasks:complete','tasks:delete']::text[]),
 ttl_days integer not null check(ttl_days in(7,30,90,365)),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null,
 revoked_at timestamptz,
 last_used_at timestamptz,
 window_started_at timestamptz not null default clock_timestamp(),
 window_requests integer not null default 0 check(window_requests>=0),
 usage_day date not null default (clock_timestamp() at time zone 'UTC')::date,
 day_requests integer not null default 0 check(day_requests>=0)
);
create index automation_keys_owner_created on taskfold_private.automation_keys(user_id,created_at desc,id desc);
create table taskfold_private.automation_account_usage (
 user_id uuid primary key references auth.users(id) on delete cascade,
 usage_day date not null,
 requests integer not null check(requests>=0)
);
alter table taskfold_private.automation_keys enable row level security;
alter table taskfold_private.automation_account_usage enable row level security;
revoke all on taskfold_private.automation_keys,taskfold_private.automation_account_usage from public,anon,authenticated,service_role;

create function taskfold_private.automation_key_receipt(k taskfold_private.automation_keys) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('id',k.id,'name',k.name,'prefix','tfk_v1_'||left(replace(k.id::text,'-',''),8),
  'scopes',k.scopes,'created_at',k.created_at,'expires_at',k.expires_at,'revoked_at',k.revoked_at,'last_used_at',k.last_used_at)
$$;
revoke all on function taskfold_private.automation_key_receipt(taskfold_private.automation_keys) from public,anon,authenticated,service_role;

-- The same account mutex precedes Auth/key locks in management and API operations.
-- Account removal takes the Auth lock first and never waits on this mutex.
create function taskfold_private.automation_account_lock(_account uuid) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
 if _account is null then raise exception using errcode='28000',message='Sign in again'; end if;
 perform pg_advisory_xact_lock(hashtextextended('automation:'||_account::text,11819));
 perform 1 from auth.users where id=_account and (banned_until is null or banned_until<=clock_timestamp()) for key share;
 if not found or exists(select 1 from taskfold_private.account_removal_receipts where account_id=_account and created_at>clock_timestamp()-interval '7 days') then
  raise exception using errcode='28000',message='Account access is unavailable';
 end if;
end$$;
revoke all on function taskfold_private.automation_account_lock(uuid) from public,anon,authenticated,service_role;

-- Called only with the subject/session independently verified by the native-JWT
-- Edge Function. No public client gets EXECUTE on either wrapper or implementation.
create function taskfold_private.automation_manage(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare k taskfold_private.automation_keys; key_id uuid; key_name text; key_hash text; key_scopes text[]; days integer; now_at timestamptz:=clock_timestamp(); fields text[]; page_limit integer:=50; include_inactive boolean:=false; cursor_key taskfold_private.automation_keys; page jsonb:='[]'::jsonb; count_on_page integer:=0; last_id uuid; more boolean:=false;
begin
 perform taskfold_private.automation_account_lock(_account);
 perform 1 from auth.sessions where id=_session and user_id=_account and (not_after is null or not_after>clock_timestamp()) for key share;
 if not found then raise exception using errcode='28000',message='Sign in again';end if;
 now_at=clock_timestamp();
 if _body is null or jsonb_typeof(_body)<>'object' then raise exception using errcode='22023',message='Invalid key request';end if;
 if _action='list' then
  if exists(select 1 from jsonb_object_keys(_body) x where x not in('cursor','limit','include_inactive'))
   or (_body ? 'include_inactive' and jsonb_typeof(_body->'include_inactive') is distinct from 'boolean')
   or (_body ? 'limit' and (jsonb_typeof(_body->'limit') is distinct from 'number'))
   or (_body ? 'cursor' and (jsonb_typeof(_body->'cursor') is distinct from 'string' or (_body->>'cursor')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) then
    raise exception using errcode='22023',message='Invalid key list request';end if;
  if _body ? 'limit' then
   if (_body->>'limit')::numeric not between 1 and 100 or (_body->>'limit')::numeric<>trunc((_body->>'limit')::numeric) then raise exception using errcode='22023',message='Invalid page size';end if;
   page_limit=(_body->>'limit')::numeric::integer;
  end if;
  include_inactive=coalesce((_body->>'include_inactive')::boolean,false);
  if _body ? 'cursor' then
   select * into cursor_key from taskfold_private.automation_keys where id=(_body->>'cursor')::uuid and user_id=_account;
   if not found then raise exception using errcode='42501',message='Key page is unavailable';end if;
  end if;
  for k in select * from taskfold_private.automation_keys x where x.user_id=_account
   and (include_inactive or (x.revoked_at is null and x.expires_at>now_at))
   and (cursor_key.id is null or (x.created_at,x.id)<(cursor_key.created_at,cursor_key.id))
   order by x.created_at desc,x.id desc limit page_limit+1 loop
    if count_on_page=page_limit then more=true;exit;end if;
    page=page||jsonb_build_array(taskfold_private.automation_key_receipt(k));last_id=k.id;count_on_page=count_on_page+1;
  end loop;
  return jsonb_build_object('account',_account,'keys',page,'next_cursor',case when more then last_id else null end);
 end if;
 select coalesce(array_agg(x order by x),array[]::text[]) into fields from jsonb_object_keys(_body) x;
 if _action='revoke' then
  if fields<>array['id'] or jsonb_typeof(_body->'id') is distinct from 'string' or (_body->>'id')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
   raise exception using errcode='22023',message='Invalid key request';end if;
  select * into k from taskfold_private.automation_keys where id=(_body->>'id')::uuid and user_id=_account for update;
  if not found then raise exception using errcode='42501',message='Key is unavailable';end if;
  update taskfold_private.automation_keys set revoked_at=coalesce(revoked_at,now_at) where id=k.id returning * into k;
  return jsonb_build_object('account',_account,'key',taskfold_private.automation_key_receipt(k));
 elsif _action<>'create' or _action is null then
  raise exception using errcode='22023',message='Invalid key action';
 end if;
 if fields<>array['id','name','scopes','token_hash','ttl_days']
 or jsonb_typeof(_body->'id') is distinct from 'string' or (_body->>'id')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or jsonb_typeof(_body->'name') is distinct from 'string'
 or jsonb_typeof(_body->'token_hash') is distinct from 'string' or (_body->>'token_hash')!~'^[0-9a-f]{64}$'
 or jsonb_typeof(_body->'scopes') is distinct from 'array'
 or jsonb_typeof(_body->'ttl_days') is distinct from 'number' then
  raise exception using errcode='22023',message='Invalid key request';end if;
 key_id=(_body->>'id')::uuid;key_name=btrim(_body->>'name');key_hash=_body->>'token_hash';
 if key_id='00000000-0000-0000-0000-000000000000' or char_length(key_name) not between 1 and 80 or octet_length(key_name)>320 or key_name ~ '[[:cntrl:]]'
 or exists(select 1 from jsonb_array_elements(_body->'scopes') s where jsonb_typeof(s)<>'string')
 or jsonb_array_length(_body->'scopes') not between 1 and 5 then raise exception using errcode='22023',message='Invalid key settings';end if;
 select array_agg(s order by s) into key_scopes from jsonb_array_elements_text(_body->'scopes') s;
 if not key_scopes <@ array['tasks:read','tasks:create','tasks:update','tasks:complete','tasks:delete']::text[]
 or cardinality(key_scopes)<>(select count(distinct s) from unnest(key_scopes) s)
 or (_body->>'ttl_days')::numeric not in(7,30,90,365) then raise exception using errcode='22023',message='Invalid key settings';end if;
 days=(_body->>'ttl_days')::numeric::integer;
 select * into k from taskfold_private.automation_keys where id=key_id for update;
 if found then
  if k.user_id<>_account then raise exception using errcode='42501',message='Key is unavailable';end if;
  if (k.name,k.token_hash,k.scopes,k.ttl_days) is distinct from (key_name,key_hash,key_scopes,days) then
   raise exception using errcode='23505',message='This key request already has different settings';end if;
  -- A retry neither extends expiry nor reactivates a revoked key.
  return jsonb_build_object('account',_account,'key',taskfold_private.automation_key_receipt(k));
 end if;
 if (select count(*) from taskfold_private.automation_keys where user_id=_account and revoked_at is null and expires_at>now_at)>=20
 or (select count(*) from taskfold_private.automation_keys where user_id=_account and created_at>=date_trunc('day',now_at at time zone 'UTC') at time zone 'UTC')>=10 then
  raise exception using errcode='PT429',message='Key creation limit reached';end if;
 insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,created_at,expires_at)
 values(key_id,_account,key_name,key_hash,key_scopes,days,now_at,now_at+days*interval '24 hours') returning * into k;
 return jsonb_build_object('account',_account,'key',taskfold_private.automation_key_receipt(k));
end$$;
revoke all on function taskfold_private.automation_manage(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.automation_manage(uuid,uuid,text,jsonb) to service_role;
create function public.taskfold_automation_keys(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.automation_manage(_account,_session,_action,_body)$$;
revoke all on function public.taskfold_automation_keys(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_automation_keys(uuid,uuid,text,jsonb) to service_role;

-- Private transaction helper, never a standalone authorization endpoint. Future
-- task-operation RPCs must call it within the SAME transaction as effects/replay.
-- Its account/key locks then serialize revocation against the complete operation.
create function taskfold_private.automation_authorize(_id uuid,_token_hash text,_scope text) returns uuid
language plpgsql volatile security definer set search_path='' as $$
declare k taskfold_private.automation_keys; owner_id uuid; now_at timestamptz:=clock_timestamp(); today date:=(clock_timestamp() at time zone 'UTC')::date; used integer;
begin
 if _id is null or _token_hash is null or _token_hash!~'^[0-9a-f]{64}$' then raise exception using errcode='28000',message='Key is unavailable';end if;
 select user_id into owner_id from taskfold_private.automation_keys where id=_id and token_hash=_token_hash;
 if not found then raise exception using errcode='28000',message='Key is unavailable';end if;
 perform taskfold_private.automation_account_lock(owner_id);
 select * into k from taskfold_private.automation_keys where id=_id and user_id=owner_id and token_hash=_token_hash for update;
 if not found or k.revoked_at is not null or k.expires_at<=clock_timestamp() then raise exception using errcode='28000',message='Key is unavailable';end if;
 now_at=clock_timestamp();today=(now_at at time zone 'UTC')::date;
 if _scope is null or not _scope=any(k.scopes) then raise exception using errcode='42501',message='This key does not allow that action';end if;
 if k.window_started_at<=now_at-interval '1 minute' then k.window_started_at=now_at;k.window_requests=0;end if;
 if k.usage_day<>today then k.usage_day=today;k.day_requests=0;end if;
 if k.window_requests>=60 or k.day_requests>=1000 then raise exception using errcode='PT429',message='Automation request limit reached';end if;
 insert into taskfold_private.automation_account_usage(user_id,usage_day,requests) values(owner_id,today,1)
 on conflict(user_id) do update set usage_day=excluded.usage_day,requests=case when automation_account_usage.usage_day=excluded.usage_day then automation_account_usage.requests+1 else 1 end
 returning requests into used;
 if used>2000 then raise exception using errcode='PT429',message='Automation request limit reached';end if;
 update taskfold_private.automation_keys set window_started_at=k.window_started_at,window_requests=k.window_requests+1,usage_day=today,day_requests=k.day_requests+1,last_used_at=now_at where id=k.id;
 return owner_id;
end$$;
revoke all on function taskfold_private.automation_authorize(uuid,text,text) from public,anon,authenticated,service_role;

-- Beginning an irreversible account removal disconnects existing integrations.
-- Revocation survives receipt pruning, failed cleanup and a still-live Auth row.
create function taskfold_private.automation_revoke_on_removal() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update taskfold_private.automation_keys set revoked_at=clock_timestamp()
 where user_id=new.account_id and revoked_at is null;
 return new;
end$$;
revoke all on function taskfold_private.automation_revoke_on_removal() from public,anon,authenticated,service_role;
create trigger taskfold_automation_removal_revoke after insert on taskfold_private.account_removal_receipts
 for each row execute function taskfold_private.automation_revoke_on_removal();
