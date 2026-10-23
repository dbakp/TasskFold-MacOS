-- Candidate only: short-lived HMAC fingerprints, never raw IPs/tokens/accounts.
-- A separate committed admission RPC survives a subsequent task/Auth rejection.
create table taskfold_private.automation_ingress(
 route text not null check(route in('tasks','keys')),
 dimension text not null check(dimension in('global','ip','credential')),
 fingerprint text not null check(fingerprint~'^[a-f0-9]{64}$'),
 window_start timestamptz not null,
 hits integer not null check(hits between 1 and 1200),
 expires_at timestamptz not null,
 primary key(route,dimension,fingerprint)
);
create index automation_ingress_expiry on taskfold_private.automation_ingress(expires_at) where dimension<>'global';
alter table taskfold_private.automation_ingress enable row level security;
revoke all on taskfold_private.automation_ingress from public,anon,authenticated,service_role;
create function taskfold_private.automation_admit_at(_route text,_ip_hash text,_credential_hash text,_stamp timestamptz)
returns jsonb language plpgsql volatile security invoker set search_path='' set timezone='UTC' set lock_timeout='500ms' as $$
declare stamp timestamptz:=clock_timestamp();slot timestamptz;retry int;kind text;fp text;cap int;used int;
begin
 if _route is null or _route not in('tasks','keys') or _ip_hash is null or _ip_hash!~'^[a-f0-9]{64}$' or _credential_hash is null or _credential_hash!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Invalid admission';end if;
 -- Route-local serialization makes the three budgets and global cardinality bound
 -- atomic across workers. Keys stay independent of task-route exhaustion.
 perform pg_advisory_xact_lock(hashtextextended('automation-ingress:'||_route,11820));
 stamp:=coalesce(_stamp,clock_timestamp());slot:=date_trunc('minute',stamp);retry:=greatest(1,least(60,ceil(extract(epoch from slot+interval '1 minute'-stamp))::int));
 for kind,fp,cap in select * from(values
  ('global',repeat('0',64),case when _route='tasks' then 1200 else 600 end),
  ('ip',_ip_hash,case when _route='tasks' then 120 else 60 end),
  ('credential',_credential_hash,case when _route='tasks' then 120 else 60 end)) budgets loop
  select hits into used from taskfold_private.automation_ingress where route=_route and dimension=kind and fingerprint=fp and window_start=slot;
  if coalesce(used,0)>=cap then return jsonb_build_object('allowed',false,'retry_after',retry,'limited_by',kind);end if;
  insert into taskfold_private.automation_ingress(route,dimension,fingerprint,window_start,hits,expires_at)
   values(_route,kind,fp,slot,1,slot+interval '3 minutes')
  on conflict(route,dimension,fingerprint) do update set window_start=excluded.window_start,
   hits=case when automation_ingress.window_start=excluded.window_start then automation_ingress.hits+1 else 1 end,expires_at=excluded.expires_at;
 end loop;
 -- Never sweep a real user's task data. Bounded expiry work uses only this tiny
 -- private transient table; no scheduled retention of task/journal data changes.
 delete from taskfold_private.automation_ingress where (route,dimension,fingerprint) in
  (select route,dimension,fingerprint from taskfold_private.automation_ingress where dimension<>'global' and expires_at<=stamp order by expires_at limit 128);
 return jsonb_build_object('allowed',true,'retry_after',0,'limited_by',null);
end $$;
-- Only the owner can call the explicit-clock algorithm. The service-facing entry
-- always chooses the current server clock after obtaining its budget lock.
revoke all on function taskfold_private.automation_admit_at(text,text,text,timestamptz) from public,anon,authenticated,service_role;
create function taskfold_private.automation_admit(_route text,_ip_hash text,_credential_hash text)
returns jsonb language sql volatile security definer set search_path='' set lock_timeout='500ms'
as $$select taskfold_private.automation_admit_at(_route,_ip_hash,_credential_hash,null)$$;
create function public.taskfold_automation_admit(_route text,_ip_hash text,_credential_hash text)
returns jsonb language sql volatile security invoker set search_path='' set statement_timeout='2s'
as $$select taskfold_private.automation_admit(_route,_ip_hash,_credential_hash)$$;
revoke all on function taskfold_private.automation_admit(text,text,text),public.taskfold_automation_admit(text,text,text) from public,anon,authenticated;
grant execute on function taskfold_private.automation_admit(text,text,text),public.taskfold_automation_admit(text,text,text) to service_role;
