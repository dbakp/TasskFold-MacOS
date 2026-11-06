-- Inactive candidate. No task trigger, dispatcher or network call is installed.
-- Only the verified native-session Edge service can call these bounded RPCs.
-- Removal stays irreversible for surviving Auth rows even after short-lived
-- recovery receipts are pruned. Physical Auth deletion cascades this marker.
create table taskfold_private.webhook_removal_blocks (
 user_id uuid primary key references auth.users(id) on delete cascade,
 started_at timestamptz not null default clock_timestamp()
);
alter table taskfold_private.webhook_removal_blocks enable row level security;
revoke all on taskfold_private.webhook_removal_blocks from public,anon,authenticated,service_role;
insert into taskfold_private.webhook_removal_blocks(user_id)
 select distinct u.id from auth.users u join taskfold_private.account_removal_receipts r on r.account_id=u.id;
create table taskfold_private.webhook_subscriptions (
 id uuid primary key,
 revision uuid not null default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 name text not null check(char_length(name) between 1 and 80 and octet_length(name)<=320 and name!~'[[:cntrl:]]'),
 endpoint text not null check(octet_length(endpoint)<=4096 and endpoint~'^https://' and endpoint!~'[[:space:][:cntrl:]]'),
 scope text not null check(scope in('all','inbox','project')),
 project_id uuid,
 events text[] not null check(cardinality(events) between 1 and 5 and events <@ array['task.created','task.updated','task.completed','task.reopened','task.deleted']::text[]),
 ttl_days integer not null check(ttl_days in(30,90,365)),
 secret_hash text not null check(secret_hash~'^[a-f0-9]{64}$'),
 secret_envelope jsonb,
 state text not null default 'pending' check(state in('pending','active','paused','revoked')),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null,
 verified_at timestamptz,
 revoked_at timestamptz,
 unique(user_id,id),
 check((scope='project')=(project_id is not null)),
 check((state='revoked')=(secret_envelope is null)),
 check((state='revoked')=(revoked_at is not null)),
 check(state not in('active','paused') or verified_at is not null)
);
create index webhook_subscriptions_owner_created on taskfold_private.webhook_subscriptions(user_id,created_at,id);
create table taskfold_private.webhook_commands (
 user_id uuid not null,
 request_id uuid not null,
 subscription_id uuid not null,
 action text not null check(action in('pause','resume')),
 baseline uuid not null,
 result_revision uuid not null,
 applied_at timestamptz not null default clock_timestamp(),
 primary key(user_id,request_id),
 foreign key(user_id,subscription_id) references taskfold_private.webhook_subscriptions(user_id,id) on delete cascade
);
create index webhook_commands_subscription on taskfold_private.webhook_commands(subscription_id);
create index webhook_commands_owner_date on taskfold_private.webhook_commands(user_id,applied_at,request_id);
alter table taskfold_private.webhook_commands enable row level security;
revoke all on taskfold_private.webhook_commands from public,anon,authenticated,service_role;
create table taskfold_private.webhook_cancellations (
 user_id uuid not null references auth.users(id) on delete cascade,
 id uuid not null,
 cancelled_at timestamptz not null default clock_timestamp(),
 primary key(user_id,id)
);
create index webhook_cancellations_owner_date on taskfold_private.webhook_cancellations(user_id,cancelled_at,id);
create table taskfold_private.webhook_verifications (
 user_id uuid not null,
 attempt_id uuid not null,
 subscription_id uuid not null,
 nonce text not null check(nonce~'^[a-f0-9]{64}$'),
 created_at timestamptz not null,
 expires_at timestamptz not null,
 finished_at timestamptz,
 outcome text check(outcome in('verified','retry','refused','gone','expired','cancelled')),
 primary key(user_id,attempt_id),
 foreign key(user_id,subscription_id) references taskfold_private.webhook_subscriptions(user_id,id) on delete cascade,
 check((outcome is null)=(finished_at is null))
);
create index webhook_verifications_owner_date on taskfold_private.webhook_verifications(user_id,created_at,attempt_id);
create index webhook_verifications_subscription on taskfold_private.webhook_verifications(subscription_id);
alter table taskfold_private.webhook_subscriptions enable row level security;
alter table taskfold_private.webhook_cancellations enable row level security;
alter table taskfold_private.webhook_verifications enable row level security;
revoke all on taskfold_private.webhook_subscriptions,taskfold_private.webhook_cancellations,taskfold_private.webhook_verifications from public,anon,authenticated,service_role;

-- Recovery identities last for this Auth account's lifetime. History pruning
-- must never turn an old command/cancellation into a new actionable intent.
create function taskfold_private.webhook_immutable_history() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='DELETE' then
  if exists(select 1 from auth.users where id=old.user_id) then raise exception using errcode='PT409',message='Webhook recovery history cannot be removed';end if;
  return old;
 end if;
 if to_jsonb(new) is distinct from to_jsonb(old) then raise exception using errcode='PT409',message='Webhook recovery history cannot change';end if;
 return new;
end$$;
revoke all on function taskfold_private.webhook_immutable_history() from public,anon,authenticated,service_role;
create trigger webhook_command_immutable before update or delete on taskfold_private.webhook_commands for each row execute function taskfold_private.webhook_immutable_history();
create trigger webhook_cancellation_immutable before update or delete on taskfold_private.webhook_cancellations for each row execute function taskfold_private.webhook_immutable_history();
create trigger webhook_removal_block_immutable before update or delete on taskfold_private.webhook_removal_blocks for each row execute function taskfold_private.webhook_immutable_history();

create function taskfold_private.webhook_preserve_setup() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='DELETE' then
  if exists(select 1 from auth.users where id=old.user_id) then raise exception using errcode='PT409',message='Webhook setup history cannot be removed';end if;
  return old;
 end if;
 if (to_jsonb(new)-array['state','revision','verified_at','revoked_at','secret_envelope']) is distinct from
    (to_jsonb(old)-array['state','revision','verified_at','revoked_at','secret_envelope'])
  or (old.state='revoked' and to_jsonb(new) is distinct from to_jsonb(old))
  or ((new.state is distinct from old.state) is distinct from (new.revision is distinct from old.revision))
  or (new.secret_envelope is distinct from old.secret_envelope and not(new.state='revoked' and new.secret_envelope is null))
  or (old.verified_at is not null and new.verified_at is distinct from old.verified_at) then
  raise exception using errcode='PT409',message='Webhook setup identity cannot change';end if;
 return new;
end$$;
revoke all on function taskfold_private.webhook_preserve_setup() from public,anon,authenticated,service_role;
create trigger webhook_preserve_setup before update or delete on taskfold_private.webhook_subscriptions for each row execute function taskfold_private.webhook_preserve_setup();

create function taskfold_private.webhook_receipt(s taskfold_private.webhook_subscriptions) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('id',s.id,'revision',s.revision,'name',s.name,'origin',substring(s.endpoint from '^https://[^/]+'),
 'scope',s.scope,'project_id',s.project_id,'events',s.events,'created_at',s.created_at,'expires_at',s.expires_at,
 'state',case when s.state<>'revoked' and s.expires_at<=clock_timestamp() then 'expired' else s.state end,
 'verified_at',s.verified_at,'revoked_at',s.revoked_at)
$$;
revoke all on function taskfold_private.webhook_receipt(taskfold_private.webhook_subscriptions) from public,anon,authenticated,service_role;

create function taskfold_private.webhook_manage(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare stamp timestamptz; s taskfold_private.webhook_subscriptions; cursor_row taskfold_private.webhook_subscriptions;
 v taskfold_private.webhook_verifications; command taskfold_private.webhook_commands; target uuid; attempt uuid; settings jsonb; envelope jsonb; names text[];
 selected_events text[]; rows jsonb:='[]'; maximum int:=50; inactive boolean:=false; count_rows int:=0; last_id uuid; more boolean:=false;
 pattern constant text:='^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$';
begin
 perform taskfold_private.automation_account_lock(_account);
 if exists(select 1 from taskfold_private.webhook_removal_blocks where user_id=_account) then raise exception using errcode='28000',message='Account access is unavailable';end if;
 perform 1 from auth.sessions where id=_session and user_id=_account and (not_after is null or not_after>clock_timestamp()) for key share;
 if not found then raise exception using errcode='28000',message='Sign in again';end if;
 stamp=clock_timestamp();
 if _body is null or jsonb_typeof(_body)<>'object' or octet_length(_body::text)>12288 then raise exception using errcode='22023',message='Invalid webhook request';end if;
 if _action='list' then
  if exists(select 1 from jsonb_object_keys(_body) k where k not in('cursor','limit','include_inactive'))
   or (_body ? 'include_inactive' and jsonb_typeof(_body->'include_inactive') is distinct from 'boolean')
   or (_body ? 'limit' and jsonb_typeof(_body->'limit') is distinct from 'number')
   or (_body ? 'cursor' and (jsonb_typeof(_body->'cursor') is distinct from 'string' or (_body->>'cursor')!~pattern)) then
    raise exception using errcode='22023',message='Invalid webhook page';end if;
  if _body ? 'limit' then
   if (_body->>'limit')::numeric not between 1 and 100 or (_body->>'limit')::numeric<>trunc((_body->>'limit')::numeric) then raise exception using errcode='22023',message='Invalid page size';end if;
   maximum=(_body->>'limit')::numeric::int;
  end if;
  inactive=coalesce((_body->>'include_inactive')::boolean,false);
  if _body ? 'cursor' then
   select * into cursor_row from taskfold_private.webhook_subscriptions where user_id=_account and id=(_body->>'cursor')::uuid;
   if not found then raise exception using errcode='22023',message='Webhook page is unavailable';end if;
  end if;
  for s in select * from taskfold_private.webhook_subscriptions x where user_id=_account
   and (inactive or (state<>'revoked' and expires_at>stamp))
   and (cursor_row.id is null or (x.created_at,x.id)>(cursor_row.created_at,cursor_row.id))
   order by x.created_at,x.id limit maximum+1 loop
   if count_rows=maximum then more=true;exit;end if;
   rows=rows||jsonb_build_array(taskfold_private.webhook_receipt(s));last_id=s.id;count_rows=count_rows+1;
  end loop;
  return jsonb_build_object('account',_account,'subscriptions',rows,'next_cursor',case when more then last_id else null end);
 end if;
 if jsonb_typeof(_body->'id') is distinct from 'string' or (_body->>'id')!~pattern or (_body->>'id')='00000000-0000-0000-0000-000000000000' then
  raise exception using errcode='22023',message='Invalid webhook identity';end if;
 target=(_body->>'id')::uuid;
 if _action='create' then
  select array_agg(k order by k) into names from jsonb_object_keys(_body) k;
  if names is distinct from array['endpoint','events','id','name','project_id','scope','secret_envelope','secret_hash','ttl_days']
   or jsonb_typeof(_body->'name') is distinct from 'string' or char_length(btrim(_body->>'name')) not between 1 and 80 or octet_length(_body->>'name')>320 or (_body->>'name')~'[[:cntrl:]]'
   or jsonb_typeof(_body->'endpoint') is distinct from 'string' or octet_length(_body->>'endpoint')>4096 or (_body->>'endpoint')!~'^https://[^/@#?]+/' or (_body->>'endpoint')~'[[:space:][:cntrl:]]' or (_body->>'endpoint')~'[#\\]'
   or jsonb_typeof(_body->'scope') is distinct from 'string' or (_body->>'scope') not in('all','inbox','project')
   or (jsonb_typeof(_body->'project_id') is distinct from 'null' and (jsonb_typeof(_body->'project_id') is distinct from 'string' or (_body->>'project_id')!~pattern))
   or jsonb_typeof(_body->'events') is distinct from 'array' or jsonb_typeof(_body->'ttl_days') is distinct from 'number'
   or jsonb_typeof(_body->'secret_hash') is distinct from 'string' or (_body->>'secret_hash')!~'^[a-f0-9]{64}$'
   or jsonb_typeof(_body->'secret_envelope') is distinct from 'object' then raise exception using errcode='22023',message='Invalid webhook settings';end if;
  if jsonb_array_length(_body->'events') not between 1 and 5 or exists(select 1 from jsonb_array_elements(_body->'events') e where jsonb_typeof(e)<>'string')
   or (_body->>'ttl_days')::numeric not in(30,90,365)
   or ((_body->>'scope')='project') is distinct from (_body->'project_id'<>'null'::jsonb) then raise exception using errcode='22023',message='Invalid webhook scope';end if;
  select array_agg(e order by e) into selected_events from jsonb_array_elements_text(_body->'events') e;
  if cardinality(selected_events)<>(select count(distinct e) from unnest(selected_events) e)
   or not selected_events <@ array['task.created','task.updated','task.completed','task.reopened','task.deleted']::text[] then raise exception using errcode='22023',message='Invalid webhook events';end if;
  envelope=_body->'secret_envelope';
  if (select array_agg(k order by k) from jsonb_object_keys(envelope) k) is distinct from array['ciphertext','keyVersion','nonce','version']
   or envelope->'version' is distinct from '1'::jsonb or jsonb_typeof(envelope->'keyVersion') is distinct from 'string' or (envelope->>'keyVersion')!~'^[a-z0-9-]{1,32}$'
   or jsonb_typeof(envelope->'nonce') is distinct from 'string' or (envelope->>'nonce')!~'^[A-Za-z0-9_-]{16}$'
   or jsonb_typeof(envelope->'ciphertext') is distinct from 'string' or (envelope->>'ciphertext')!~'^[A-Za-z0-9_-]{64}$' then raise exception using errcode='22023',message='Invalid encrypted webhook secret';end if;
  if exists(select 1 from taskfold_private.webhook_cancellations where user_id=_account and id=target) then raise exception using errcode='PT409',message='Webhook setup was discarded';end if;
  -- Take project locks before the subscription row in every activating path.
  if (_body->>'scope')='project' then perform taskfold_private.automation_lock_project(_account,(_body->>'project_id')::uuid);end if;
  select * into s from taskfold_private.webhook_subscriptions where id=target for update;
  if found then
   if s.user_id<>_account then raise exception using errcode='PT404',message='Webhook is unavailable';end if;
   if (s.name,s.endpoint,s.scope,s.project_id,s.events,s.ttl_days,s.secret_hash) is distinct from
    (btrim(_body->>'name'),_body->>'endpoint',_body->>'scope',(_body->>'project_id')::uuid,selected_events,(_body->>'ttl_days')::int,_body->>'secret_hash') then
    raise exception using errcode='PT409',message='This setup already has different settings';end if;
   -- A retry never replaces the first encrypted secret, extends expiry, or
   -- reactivates a revoked row, even if re-encryption used a different nonce.
  else
   if (select count(*) from taskfold_private.webhook_subscriptions where user_id=_account and state<>'revoked' and expires_at>stamp)>=5
    or (select count(*) from taskfold_private.webhook_subscriptions where user_id=_account and created_at>=(date_trunc('day',stamp at time zone 'UTC') at time zone 'UTC'))>=10 then
    raise exception using errcode='PT429',message='Webhook creation limit reached';end if;
   insert into taskfold_private.webhook_subscriptions(id,user_id,name,endpoint,scope,project_id,events,ttl_days,secret_hash,secret_envelope,created_at,expires_at)
    values(target,_account,btrim(_body->>'name'),_body->>'endpoint',_body->>'scope',(_body->>'project_id')::uuid,selected_events,(_body->>'ttl_days')::int,_body->>'secret_hash',envelope,stamp,stamp+(_body->>'ttl_days')::int*interval '24 hours') returning * into s;
  end if;
  return jsonb_build_object('account',_account,'subscription',taskfold_private.webhook_receipt(s));
 end if;
 if _action='cancel' then
  if (select count(*) from jsonb_object_keys(_body))<>1 then raise exception using errcode='22023',message='Invalid discard request';end if;
  select * into s from taskfold_private.webhook_subscriptions where user_id=_account and id=target for update;
  if found then
   update taskfold_private.webhook_subscriptions set state='revoked',revision=case when state='revoked' then revision else gen_random_uuid() end,secret_envelope=null,revoked_at=coalesce(revoked_at,stamp) where id=target;
   update taskfold_private.webhook_verifications set outcome='cancelled',finished_at=stamp where user_id=_account and subscription_id=target and outcome is null;
  elsif not exists(select 1 from taskfold_private.webhook_cancellations where user_id=_account and id=target) then
   if (select count(*) from taskfold_private.webhook_cancellations where user_id=_account and cancelled_at>=(date_trunc('day',stamp at time zone 'UTC') at time zone 'UTC'))>=100 then raise exception using errcode='PT429',message='Setup cancellation limit reached';end if;
   insert into taskfold_private.webhook_cancellations(user_id,id,cancelled_at) values(_account,target,stamp);
  end if;
  return jsonb_build_object('account',_account,'id',target,'cancelled',true);
 end if;
 -- Read scope without locking it first; it is immutable, and all mutations of
 -- this account serialize on its existing automation mutex.
 select * into s from taskfold_private.webhook_subscriptions where user_id=_account and id=target;
 if not found then raise exception using errcode='PT404',message='Webhook is unavailable';end if;
 if _action in('pause','resume') then
  if (select array_agg(k order by k) from jsonb_object_keys(_body) k) is distinct from array['id','request_id','revision']
   or jsonb_typeof(_body->'request_id') is distinct from 'string' or (_body->>'request_id')!~pattern or (_body->>'request_id')='00000000-0000-0000-0000-000000000000'
   or jsonb_typeof(_body->'revision') is distinct from 'string' or (_body->>'revision')!~pattern or (_body->>'revision')='00000000-0000-0000-0000-000000000000' then
   raise exception using errcode='22023',message='Review the current webhook state';end if;
  select * into command from taskfold_private.webhook_commands where user_id=_account and request_id=(_body->>'request_id')::uuid;
  if found then
   if (command.subscription_id,command.action,command.baseline) is distinct from (target,_action,(_body->>'revision')::uuid) then raise exception using errcode='PT409',message='This action already has different settings';end if;
   -- A lost Pause reply may be retried after a later Resume. Confirm its receipt
   -- and return CURRENT metadata; never apply that old pause a second time.
   return jsonb_build_object('account',_account,'subscription',taskfold_private.webhook_receipt(s),'command',jsonb_build_object('request_id',command.request_id,'applied',true));
  end if;
 end if;
 if _action in('resume','begin_verify','finish_verify') and s.scope='project' then perform taskfold_private.automation_lock_project(_account,s.project_id);end if;
 select * into s from taskfold_private.webhook_subscriptions where user_id=_account and id=target for update;
 if _action in('pause','resume','revoke','details') then
  if _action in('revoke','details') and (select count(*) from jsonb_object_keys(_body))<>1 then raise exception using errcode='22023',message='Invalid webhook action';end if;
  if _action='revoke' then
   update taskfold_private.webhook_subscriptions set state='revoked',revision=case when state='revoked' then revision else gen_random_uuid() end,secret_envelope=null,revoked_at=coalesce(revoked_at,stamp) where id=target returning * into s;
   update taskfold_private.webhook_verifications set outcome='cancelled',finished_at=stamp where user_id=_account and subscription_id=target and outcome is null;
  elsif _action in('pause','resume') then
   if s.state='revoked' or s.expires_at<=stamp or s.verified_at is null then raise exception using errcode='PT409',message='Verify a current webhook first';end if;
   if s.revision is distinct from (_body->>'revision')::uuid then raise exception using errcode='PT409',message='The webhook changed; refresh before editing';end if;
   if (select count(*) from taskfold_private.webhook_commands where user_id=_account and applied_at>=(date_trunc('day',stamp at time zone 'UTC') at time zone 'UTC'))>=200 then raise exception using errcode='PT429',message='Webhook control limit reached';end if;
   update taskfold_private.webhook_subscriptions set state=case when _action='pause' then 'paused' else 'active' end,
    revision=case when state=(case when _action='pause' then 'paused' else 'active' end) then revision else gen_random_uuid() end where id=target returning * into s;
   insert into taskfold_private.webhook_commands(user_id,request_id,subscription_id,action,baseline,result_revision,applied_at)
    values(_account,(_body->>'request_id')::uuid,target,_action,(_body->>'revision')::uuid,s.revision,stamp) returning * into command;
  end if;
  return jsonb_build_object('account',_account,'subscription',taskfold_private.webhook_receipt(s)) || case when _action in('pause','resume') then jsonb_build_object('command',jsonb_build_object('request_id',command.request_id,'applied',true)) else '{}'::jsonb end || case when _action='details' then jsonb_build_object('endpoint',s.endpoint) else '{}'::jsonb end;
 end if;
 if _action not in('begin_verify','finish_verify') or _action is null
  or jsonb_typeof(_body->'attempt_id') is distinct from 'string' or (_body->>'attempt_id')!~pattern or (_body->>'attempt_id')='00000000-0000-0000-0000-000000000000'
  or exists(select 1 from jsonb_object_keys(_body) k where k not in('id','attempt_id','outcome'))
  or (_action='begin_verify' and _body ? 'outcome') then raise exception using errcode='22023',message='Invalid verification';end if;
 attempt=(_body->>'attempt_id')::uuid;
 select * into v from taskfold_private.webhook_verifications where user_id=_account and attempt_id=attempt for update;
 if found and v.subscription_id<>target then raise exception using errcode='PT409',message='Verification belongs to a different setup';end if;
 if _action='begin_verify' then
  if s.state<>'pending' or s.expires_at<=stamp then
   return jsonb_build_object('account',_account,'subscription',taskfold_private.webhook_receipt(s),'verification',jsonb_build_object('attempt_id',attempt,'outcome','unavailable'));
  end if;
  if v.attempt_id is null then
   if (select count(*) from taskfold_private.webhook_verifications where user_id=_account and created_at>=stamp-interval '1 minute')>=6
    or (select count(*) from taskfold_private.webhook_verifications where user_id=_account and created_at>=(date_trunc('day',stamp at time zone 'UTC') at time zone 'UTC'))>=60 then
    raise exception using errcode='PT429',message='Verification limit reached';end if;
   -- A new attempt invalidates earlier outstanding callbacks, while an exact
   -- retry below keeps its original nonce and expiry.
   update taskfold_private.webhook_verifications set outcome='cancelled',finished_at=stamp where user_id=_account and subscription_id=target and outcome is null;
   insert into taskfold_private.webhook_verifications(user_id,attempt_id,subscription_id,nonce,created_at,expires_at)
    values(_account,attempt,target,encode(extensions.gen_random_bytes(32),'hex'),stamp,least(s.expires_at,stamp+interval '5 minutes')) returning * into v;
  end if;
 else
  if v.attempt_id is null then raise exception using errcode='PT404',message='Verification is unavailable';end if;
  if jsonb_typeof(_body->'outcome') is distinct from 'string' or (_body->>'outcome') not in('verified','retry','refused','gone') then raise exception using errcode='22023',message='Invalid verification result';end if;
  if v.outcome is null then
   update taskfold_private.webhook_verifications set outcome=case when s.state<>'pending' then 'cancelled' when v.expires_at<=stamp or s.expires_at<=stamp then 'expired' else _body->>'outcome' end,finished_at=stamp
    where user_id=_account and attempt_id=attempt returning * into v;
   if v.outcome='verified' then update taskfold_private.webhook_subscriptions set state='active',revision=gen_random_uuid(),verified_at=stamp where id=target returning * into s;end if;
  end if;
 end if;
 -- Private challenge/envelope leave SQL only for the service's internal begin
 -- operation. Edge responses must explicitly project metadata, never this row.
 return jsonb_build_object('account',_account,'subscription',taskfold_private.webhook_receipt(s),
  'verification',jsonb_build_object('attempt_id',attempt,'outcome',coalesce(v.outcome,case when v.expires_at<=stamp then 'expired' else 'pending' end))) ||
  case when _action='begin_verify' and v.outcome is null and v.expires_at>stamp then jsonb_build_object('challenge',jsonb_build_object('nonce',v.nonce,'expires_at',v.expires_at),'endpoint',s.endpoint,'secret_envelope',s.secret_envelope) else '{}'::jsonb end;
end$$;
revoke all on function taskfold_private.webhook_manage(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.webhook_manage(uuid,uuid,text,jsonb) to service_role;
create function public.taskfold_webhooks(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' set statement_timeout='10s' as $$
 select taskfold_private.webhook_manage(_account,_session,_action,_body)
$$;
revoke all on function public.taskfold_webhooks(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_webhooks(uuid,uuid,text,jsonb) to service_role;

create function taskfold_private.webhook_revoke_on_removal() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into taskfold_private.webhook_removal_blocks(user_id) select id from auth.users where id=new.account_id on conflict(user_id) do nothing;
 update taskfold_private.webhook_subscriptions set state='revoked',revision=gen_random_uuid(),secret_envelope=null,revoked_at=coalesce(revoked_at,clock_timestamp()) where user_id=new.account_id and state<>'revoked';
 update taskfold_private.webhook_verifications set outcome='cancelled',finished_at=clock_timestamp() where user_id=new.account_id and outcome is null;
 return new;
end$$;
revoke all on function taskfold_private.webhook_revoke_on_removal() from public,anon,authenticated,service_role;
create trigger taskfold_webhook_removal_revoke after insert on taskfold_private.account_removal_receipts
 for each row execute function taskfold_private.webhook_revoke_on_removal();
