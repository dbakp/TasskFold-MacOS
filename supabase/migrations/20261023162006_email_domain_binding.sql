-- Candidate only; no live provider/domain has been configured or enabled.
-- Unknown legacy address domains cannot be inferred from their one-way hashes.
create function taskfold_private.email_domain_valid(_value text) returns boolean
language sql immutable security invoker set search_path='' as $$
 select _value is not null and octet_length(_value)<=189 and (_value collate "C") ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.[a-z]{2,63}$'
$$;
alter table taskfold_private.email_intake_config add column domain text;
update taskfold_private.email_intake_config set enabled=false;
alter table taskfold_private.email_intake_config add constraint email_config_domain_valid check(domain is null or taskfold_private.email_domain_valid(domain)), add constraint email_enabled_domain_required check(not enabled or domain is not null);
alter table taskfold_private.email_routes add column alias_domain text;
update taskfold_private.email_routes set state='revoked',revision=least(revision::bigint+1,2147483647)::int,updated_at=clock_timestamp() where state<>'revoked';
alter table taskfold_private.email_routes add constraint email_route_domain_valid check((alias_domain is null and state='revoked') or taskfold_private.email_domain_valid(alias_domain));

-- Configuration changes serialize with management/capture through their existing
-- config-row SHARE locks. Query fresh committed routes only; a snapshot-isolated
-- operator transaction cannot silently miss a concurrent enrollment.
create function taskfold_private.email_config_guard() returns trigger
language plpgsql volatile security definer set search_path='' as $$
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception using errcode='25000',message='Configure email capture in a read-committed transaction';end if;
 if (new.domain is distinct from old.domain or new.provider is distinct from old.provider)
  and exists(select 1 from taskfold_private.email_routes where state<>'revoked') then
  raise exception using errcode='PT409',message='Revoke existing email addresses before changing the domain or provider';
 end if;
 return new;
end $$;
create index email_routes_live_domain_idx on taskfold_private.email_routes(alias_domain) where state<>'revoked';
create trigger taskfold_email_config_guard before update on taskfold_private.email_intake_config for each row execute function taskfold_private.email_config_guard();
create function taskfold_private.email_configure(_provider text,_domain text,_enabled boolean) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set statement_timeout='10s' as $$
declare cfg taskfold_private.email_intake_config;
begin
 if _enabled is null or ((_provider is null)<>(_domain is null)) or (_enabled and _domain is null)
  or (_provider is not null and (_provider collate "C") !~ '^[a-z0-9][a-z0-9_-]{0,47}$')
  or (_domain is not null and not taskfold_private.email_domain_valid(_domain)) then raise exception using errcode='22023',message='Review the email provider and domain';end if;
 update taskfold_private.email_intake_config set enabled=_enabled,provider=_provider,domain=_domain where singleton returning * into cfg;
 if not found then raise exception using errcode='PT503',message='Email configuration is unavailable';end if;
 return jsonb_build_object('protocol',2,'enabled',cfg.enabled,'provider',cfg.provider,'domain',cfg.domain);
end $$;
create function public.taskfold_email_configure(_provider text,_domain text,_enabled boolean) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.email_configure(_provider,_domain,_enabled)$$;
revoke all on function taskfold_private.email_domain_valid(text),taskfold_private.email_config_guard() from public,anon,authenticated,service_role;
revoke all on function taskfold_private.email_configure(text,text,boolean),public.taskfold_email_configure(text,text,boolean) from public,anon,authenticated;
grant execute on function taskfold_private.email_configure(text,text,boolean),public.taskfold_email_configure(text,text,boolean) to service_role;

create or replace function taskfold_private.email_route_receipt(r taskfold_private.email_routes) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('id',r.id,'alias_domain',r.alias_domain,'name',r.name,'project_id',r.project_id,'sender_email',r.sender_email,'state',r.state,'revision',r.revision,'created_at',r.created_at,'updated_at',r.updated_at,'rotated_to',r.rotated_to,'accept_after',r.accept_after)
$$;
create or replace function taskfold_private.email_manage(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set statement_timeout='10s' as $$
declare r taskfold_private.email_routes; cfg taskfold_private.email_intake_config; sender text; confirmed timestamptz; target uuid; expected bigint; requested timestamptz; destination uuid; now_at timestamptz; replacement jsonb; result jsonb;
 pattern constant text:='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$';
begin
 perform taskfold_private.automation_account_lock(_account);
 -- SHARE fences email/confirmation changes as well as deletion (KEY SHARE does not).
 select lower(btrim(email)),email_confirmed_at into sender,confirmed from auth.users where id=_account for share;
 perform 1 from auth.sessions where id=_session and user_id=_account and (not_after is null or not_after>clock_timestamp()) for share;
 if not found then raise exception using errcode='28000',message='Sign in again';end if;
 select * into cfg from taskfold_private.email_intake_config where singleton for share;
 perform taskfold_private.email_prune_locked(_account);
 now_at:=clock_timestamp();
 if _action is null or _body is null or jsonb_typeof(_body)<>'object' or octet_length(_body::text)>8192 then raise exception using errcode='22023',message='Invalid email route request';end if;
 if _action='list' then
  if _body<>'{}'::jsonb then raise exception using errcode='22023',message='Invalid email route list';end if;
  select coalesce(jsonb_agg(taskfold_private.email_route_receipt(x) order by x.created_at,x.id),'[]'::jsonb) into result from taskfold_private.email_routes x where x.user_id=_account;
  return jsonb_build_object('account',_account,'available',coalesce(cfg.enabled,false),'domain',case when cfg.enabled then cfg.domain else null end,'routes',result);
 end if;
 if _action='create' then
  if (select array_agg(k order by k) from jsonb_object_keys(_body) k) is distinct from array['alias_hash','domain','id','name','project_id','requested_at']
   or jsonb_typeof(_body->'id') is distinct from 'string' or (_body->>'id')!~pattern
   or jsonb_typeof(_body->'alias_hash') is distinct from 'string' or (_body->>'alias_hash')!~'^[0-9a-f]{64}$'
   or jsonb_typeof(_body->'domain') is distinct from 'string' or not taskfold_private.email_domain_valid(_body->>'domain')
   or jsonb_typeof(_body->'name') is distinct from 'string' or char_length(btrim(_body->>'name')) not between 1 and 80 or octet_length(_body->>'name')>320 or (_body->>'name')~'[[:cntrl:]]'
   or (_body->'project_id'<>'null'::jsonb and (jsonb_typeof(_body->'project_id') is distinct from 'string' or (_body->>'project_id')!~pattern))
   or jsonb_typeof(_body->'requested_at') is distinct from 'string' or length(_body->>'requested_at')>40 or (_body->>'requested_at')!~'^\d{4}-\d\d-\d\dT' then raise exception using errcode='22023',message='Invalid email route setup';end if;
  target:=(_body->>'id')::uuid;requested:=(_body->>'requested_at')::timestamptz;destination:=(_body->>'project_id')::uuid;
  if exists(select 1 from taskfold_private.email_route_cancellations where id=target) then raise exception using errcode='PT409',message='This email setup was cancelled';end if;
  select * into r from taskfold_private.email_routes where id=target for update;
  if found then
   if r.user_id is distinct from _account then raise exception using errcode='PT404',message='Email route is unavailable';end if;
   if (r.alias_hash,r.alias_domain,r.name,r.project_id,r.requested_at) is distinct from (_body->>'alias_hash',_body->>'domain',btrim(_body->>'name'),destination,requested) then raise exception using errcode='PT409',message='Email setup changed; review it before continuing';end if;
   return jsonb_build_object('account',_account,'route',taskfold_private.email_route_receipt(r));
  end if;
  if not coalesce(cfg.enabled,false) then raise exception using errcode='PT503',message='Email capture is not configured';end if;
  if cfg.domain is distinct from _body->>'domain' then raise exception using errcode='PT409',message='The email domain changed; review a new address';end if;
  if requested<now_at-interval '7 days' or requested>now_at+interval '5 minutes' then raise exception using errcode='22023',message='Start a new email setup';end if;
  if confirmed is null or sender is null or position('@' in sender)<=1 or char_length(sender)>254 then raise exception using errcode='42501',message='Verify your Taskfold email before setting up capture';end if;
  perform taskfold_private.automation_writable_project(_account,destination);
  if (select count(*) from taskfold_private.email_routes where user_id=_account and state<>'revoked')>=5
   or (select count(*) from taskfold_private.email_routes where user_id=_account and created_at>now_at-interval '1 day')>=10 then raise exception using errcode='PT429',message='Email route limit reached; retry later';end if;
  if exists(select 1 from taskfold_private.email_routes where alias_hash=_body->>'alias_hash') then raise exception using errcode='PT409',message='Choose a fresh email address';end if;
  insert into taskfold_private.email_routes(id,user_id,name,alias_hash,alias_domain,project_id,sender_email,requested_at) values(target,_account,btrim(_body->>'name'),_body->>'alias_hash',_body->>'domain',destination,sender,requested) returning * into r;
 elsif _action in('pause','resume','revoke','rotate') then
  if (select array_agg(k order by k) from jsonb_object_keys(_body) k) is distinct from (case when _action='rotate' then array['id','replacement','revision'] when _action='resume' then array['domain','id','revision'] else array['id','revision'] end)
   or jsonb_typeof(_body->'id') is distinct from 'string' or (_body->>'id')!~pattern
   or jsonb_typeof(_body->'revision') is distinct from 'number' or (_body->>'revision')::numeric<0 or (_body->>'revision')::numeric>2147483646 or (_body->>'revision')::numeric<>trunc((_body->>'revision')::numeric) then raise exception using errcode='22023',message='Review the current email route before changing it';end if;
  target:=(_body->>'id')::uuid;expected:=(_body->>'revision')::bigint;
  select * into r from taskfold_private.email_routes where id=target for update;
  if not found then
   if _action<>'revoke' or expected<>0 then raise exception using errcode='PT404',message='Email route is unavailable';end if;
   if exists(select 1 from taskfold_private.email_route_cancellations where id=target and user_id<>_account) then raise exception using errcode='PT404',message='Email route is unavailable';end if;
   if not exists(select 1 from taskfold_private.email_route_cancellations where id=target) and (select count(*) from taskfold_private.email_route_cancellations where user_id=_account and created_at>now_at-interval '1 day')>=100 then raise exception using errcode='PT429',message='Retry an existing email cancellation';end if;
   insert into taskfold_private.email_route_cancellations(id,user_id) values(target,_account) on conflict do nothing;
   if not exists(select 1 from taskfold_private.email_route_cancellations where id=target and user_id=_account) then raise exception using errcode='PT404',message='Email route is unavailable';end if;
   return jsonb_build_object('account',_account,'id',target,'cancelled',true);
  end if;
  if r.user_id is distinct from _account then raise exception using errcode='PT404',message='Email route is unavailable';end if;
  if _action='resume' and (jsonb_typeof(_body->'domain') is distinct from 'string' or not taskfold_private.email_domain_valid(_body->>'domain') or cfg.domain is distinct from _body->>'domain' or r.alias_domain is distinct from _body->>'domain') then raise exception using errcode='PT409',message='The email domain changed; review this address';end if;
  if _action='rotate' then
   replacement:=_body->'replacement';
   if jsonb_typeof(replacement) is distinct from 'object' or replacement->>'id'=target::text or replacement->>'alias_hash'=r.alias_hash then raise exception using errcode='22023',message='Choose a new email address for rotation';end if;
   if r.state='revoked' and r.rotated_to is not null and r.rotated_to::text=replacement->>'id' then
    result:=taskfold_private.email_manage(_account,_session,'create',replacement);
    return result||jsonb_build_object('replaced',taskfold_private.email_route_receipt(r));
   end if;
   if r.state='revoked' or r.revision<>expected then raise exception using errcode='PT409',message='Email route changed; review it again';end if;
   if exists(select 1 from taskfold_private.email_routes where id=(replacement->>'id')::uuid) then raise exception using errcode='PT409',message='Choose a new email setup for rotation';end if;
   update taskfold_private.email_routes set state='revoked',revision=revision+1,rotated_to=(replacement->>'id')::uuid,updated_at=now_at where id=r.id returning * into r;
   result:=taskfold_private.email_manage(_account,_session,'create',replacement);
   return result||jsonb_build_object('replaced',taskfold_private.email_route_receipt(r));
  elsif _action='revoke' then
   if r.state<>'revoked' then
    if r.revision<>expected and not(expected=0 and r.revision=1) then raise exception using errcode='PT409',message='Email route changed; review it again';end if;
    update taskfold_private.email_routes set state='revoked',revision=revision+1,updated_at=now_at where id=r.id returning * into r;
   end if;
  else
   if r.state='revoked' then raise exception using errcode='PT409',message='This email route is revoked';end if;
   if r.revision=expected+1 and r.state=(case _action when 'pause' then 'paused' else 'active' end) then
    return jsonb_build_object('account',_account,'route',taskfold_private.email_route_receipt(r));
   end if;
   if r.revision<>expected then raise exception using errcode='PT409',message='Email route changed; review it again';end if;
   if _action='resume' then
    if not coalesce(cfg.enabled,false) then raise exception using errcode='PT503',message='Email capture is not configured';end if;
    if confirmed is null or sender is distinct from r.sender_email then raise exception using errcode='42501',message='Verify the sending address before capture';end if;
    perform taskfold_private.automation_writable_project(_account,r.project_id);
   end if;
   update taskfold_private.email_routes set state=(case _action when 'pause' then 'paused' else 'active' end),accept_after=(case when _action='resume' and state='paused' then now_at else accept_after end),revision=revision+1,updated_at=now_at where id=r.id returning * into r;
  end if;
 else raise exception using errcode='22023',message='Unsupported email route action';end if;
 return jsonb_build_object('account',_account,'route',taskfold_private.email_route_receipt(r));
exception when unique_violation then raise exception using errcode='PT409',message='Choose a fresh email setup';
 when data_exception then raise exception using errcode='22023',message='Invalid email route request';
end $$;

create or replace function taskfold_private.email_deliver_v2(_alias_hash text,_recipient_domain text,_provider text,_delivery_id text,_received_at timestamptz,_verified_sender text,_content jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set statement_timeout='10s' as $$
declare r taskfold_private.email_routes; cfg taskfold_private.email_intake_config; owner_id uuid; sender text; confirmed timestamptz; key text; fingerprint text; saved taskfold_private.email_deliveries; task_id uuid; generation uuid; now_at timestamptz; old_actor text:=current_setting('request.jwt.claim.sub',true); count_attachments int;
begin
 if not taskfold_private.email_domain_valid(_recipient_domain) then raise exception using errcode='22023',message='A verified recipient domain is required';end if;
 if _alias_hash is null or _alias_hash!~'^[0-9a-f]{64}$' or _provider is null or (_provider collate "C")!~'^[a-z0-9][a-z0-9_-]{0,47}$'
  or _delivery_id is null or octet_length(_delivery_id) not between 1 and 256 or (_delivery_id collate "C")!~'^[!-~]+$' or _received_at is null or not isfinite(_received_at)
  or _verified_sender is null or octet_length(_verified_sender)>254 then raise exception using errcode='22023',message='Invalid verified email delivery';end if;
 if _content is null or jsonb_typeof(_content)<>'object' or (select array_agg(k order by k) from jsonb_object_keys(_content) k) is distinct from array['attachmentCount','description','title']
  or jsonb_typeof(_content->'title') is distinct from 'string' or octet_length(_content->>'title') not between 1 and 512 or btrim(_content->>'title')='' or ((_content->>'title') collate "C")~'[\x01-\x1f\x7f]'
  or jsonb_typeof(_content->'description') is distinct from 'string' or octet_length(_content->>'description')>60064 or (translate(_content->>'description',chr(9)||chr(10),'') collate "C")~'[\x01-\x1f\x7f]'
  or jsonb_typeof(_content->'attachmentCount') is distinct from 'number' or (_content->>'attachmentCount')::numeric not between 0 and 100 or (_content->>'attachmentCount')::numeric<>trunc((_content->>'attachmentCount')::numeric) then raise exception using errcode='22023',message='Invalid normalized email content';end if;
 count_attachments:=(_content->>'attachmentCount')::int;
 select user_id into owner_id from taskfold_private.email_routes where alias_hash=_alias_hash;
 if not found then raise exception using errcode='PT404',message='Email route is unavailable';end if;
 perform taskfold_private.automation_account_lock(owner_id);
 select lower(btrim(email)),email_confirmed_at into sender,confirmed from auth.users where id=owner_id for share;
 select * into cfg from taskfold_private.email_intake_config where singleton for share;
 if not coalesce(cfg.enabled,false) or cfg.provider is distinct from _provider then raise exception using errcode='PT503',message='Email capture is not configured';end if;
 perform taskfold_private.email_prune_locked(owner_id);
 select * into r from taskfold_private.email_routes where alias_hash=_alias_hash and user_id=owner_id for update;
 if not found or r.state<>'active' or r.alias_domain is distinct from cfg.domain or r.alias_domain is distinct from _recipient_domain then raise exception using errcode='PT404',message='Email route is unavailable';end if;
 if confirmed is null or sender is distinct from r.sender_email or lower(btrim(_verified_sender)) is distinct from r.sender_email then raise exception using errcode='42501',message='The sending address is not approved';end if;
 perform taskfold_private.automation_writable_project(owner_id,r.project_id);
 key:=encode(extensions.digest(convert_to('["taskfold-email-delivery",1,'||to_jsonb(_provider)::text||','||to_jsonb(_delivery_id)::text||','||to_jsonb(r.id::text)::text||']','UTF8'),'sha256'),'hex');
 fingerprint:=encode(extensions.digest(convert_to('["taskfold-email-content",1,'||to_jsonb(_content->>'title')::text||','||to_jsonb(_content->>'description')::text||','||count_attachments::text||']','UTF8'),'sha256'),'hex');
 select * into saved from taskfold_private.email_deliveries where route_id=r.id and delivery_key=key;
 if found then
  if saved.content_fingerprint<>fingerprint or saved.received_at<>_received_at then raise exception using errcode='PT409',message='This email delivery changed; review it before retrying';end if;
  return jsonb_build_object('accepted',true,'replayed',true);
 end if;
 now_at:=clock_timestamp();
 -- Resuming does not import old mail from the paused interval. Second precision
 -- permits providers that round their original receipt timestamps to seconds.
 -- ORIGINAL provider timestamp is attested by the adapter, not Message-Date or
 -- the signature's retry timestamp. This is the safety boundary after pruning.
 if _received_at<now_at-interval '7 days' or _received_at>now_at+interval '5 minutes' or _received_at<date_trunc('second',r.accept_after) then raise exception using errcode='22023',message='Email delivery is outside the capture window';end if;
 if (select count(*) from taskfold_private.email_deliveries where user_id=owner_id and created_at>now_at-interval '1 day')>=100
  or (select count(*) from taskfold_private.email_deliveries where route_id=r.id and created_at>now_at-interval '1 hour')>=50
  or (select count(*) from taskfold_private.email_deliveries where user_id=owner_id)>=6000 then raise exception using errcode='PT429',message='Email capture limit reached; retry later';end if;
 task_id:=gen_random_uuid();generation:=gen_random_uuid();
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 insert into public.tasks(id,user_id,task_generation,completion_version,title,description,project_id,completed,priority,labels,subtasks,reminders,reminder_specs,attachments,comments,is_recurring,source_metadata)
 values(task_id,owner_id,generation,0,_content->>'title',_content->>'description',r.project_id,false,4,'{}','[]','{}','[]','[]','[]',false,'{}');
 insert into taskfold_private.email_deliveries(route_id,user_id,delivery_key,content_fingerprint,received_at,task_id,task_generation) values(r.id,owner_id,key,fingerprint,_received_at,task_id,generation);
 perform set_config('request.jwt.claim.sub',coalesce(old_actor,''),true);
 return jsonb_build_object('accepted',true,'replayed',false);
exception when others then
 perform set_config('request.jwt.claim.sub',coalesce(old_actor,''),true);raise;
end $$;

-- Fail old delivery callers closed. A hash alone does not attest the actual
-- recipient domain, even if a malicious enrollment reused a known old hash.
create or replace function taskfold_private.email_deliver(_alias_hash text,_provider text,_delivery_id text,_received_at timestamptz,_verified_sender text,_content jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$begin raise exception using errcode='PT428',message='Use verified recipient-domain delivery';end$$;
revoke all on function taskfold_private.email_deliver(text,text,text,timestamptz,text,jsonb),public.taskfold_email_deliver(text,text,text,timestamptz,text,jsonb) from public,anon,authenticated,service_role;
create function public.taskfold_email_deliver_v2(_alias_hash text,_recipient_domain text,_provider text,_delivery_id text,_received_at timestamptz,_verified_sender text,_content jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.email_deliver_v2(_alias_hash,_recipient_domain,_provider,_delivery_id,_received_at,_verified_sender,_content)$$;
revoke all on function taskfold_private.email_deliver_v2(text,text,text,text,timestamptz,text,jsonb),public.taskfold_email_deliver_v2(text,text,text,text,timestamptz,text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.email_deliver_v2(text,text,text,text,timestamptz,text,jsonb),public.taskfold_email_deliver_v2(text,text,text,text,timestamptz,text,jsonb) to service_role;

create or replace function public.taskfold_email_routes(_account uuid,_session uuid,_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.email_manage(_account,_session,_action,_body)||jsonb_build_object('protocol',2)$$;
