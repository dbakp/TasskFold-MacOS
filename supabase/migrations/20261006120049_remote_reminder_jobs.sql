-- Canonical event projection and a service-only queue. No provider is enabled here.
create function taskfold_private.reminder_wall_time(local_time timestamp, zone text)
returns timestamptz language plpgsql stable security invoker set search_path = '' as $$
declare offsets interval[]; candidate timestamptz; result timestamptz; requested timestamp; shift int;
begin
 if not exists(select 1 from pg_catalog.pg_timezone_names where name=zone) then return null; end if;
 -- PostgreSQL defaults to the second fold and preserves minutes in gaps. Native Calendar
 -- uses the first fold and next valid wall time; enumerate the actual adjacent offsets.
 select array_agg(distinct timezone(zone,s)-timezone('UTC',s)) into offsets
 from generate_series((local_time at time zone 'UTC')-interval '36 hours',(local_time at time zone 'UTC')+interval '36 hours',interval '6 hours') s;
 for shift in 0..1439 loop
  requested:=local_time+shift*interval '1 minute';
  if requested::date<>local_time::date then return null; end if;
  select min((requested-o) at time zone 'UTC') into result from unnest(offsets) o
   where timezone(zone,(requested-o) at time zone 'UTC')=requested;
  if result is not null then return result; end if;
 end loop;
 return null;
end $$;
revoke all on function taskfold_private.reminder_wall_time(timestamp,text) from public,anon,authenticated;

create function taskfold_private.reminder_events(t jsonb, device_zone text)
returns table(spec_id uuid,fire_at timestamptz,signature text) language plpgsql stable security invoker set search_path = '' as $$
declare specs jsonb; s jsonb; seen uuid[]:='{}'; sid uuid; kind text; anchor timestamptz; absolute_at timestamptz;
 zone text; local_day date; local_clock time; planned timestamp; saved timestamptz; minutes numeric; channels text; fields text[]; preimage text; v text; cycle numeric;
begin
 if t->>'completed'='true' then return; end if;
 cycle:=coalesce((t->>'completion_version')::numeric,0);
 if cycle<>trunc(cycle) or cycle not between 0 and 9007199254740991 then return; end if;
 specs:=coalesce(t->'reminder_specs','[]'::jsonb);
 if jsonb_typeof(specs)<>'array' then return; end if;
 if specs='[]'::jsonb then specs:='[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":true}]'; end if;
 for s in select value from jsonb_array_elements(specs) with ordinality where ordinality<=20 loop
  if jsonb_typeof(s)<>'object' or s->'version'<>'1'::jsonb or s->'version' is null or coalesce(s->>'id','') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
   or (s ? 'enabled' and jsonb_typeof(s->'enabled')<>'boolean') then continue; end if;
  if jsonb_typeof(s->'channels')<>'array' or s->'channels' is null then continue; end if;
  if jsonb_array_length(s->'channels')=0 or exists(select 1 from jsonb_array_elements(s->'channels') c where jsonb_typeof(c)<>'string' or c#>>'{}' not in ('local','push','email')) then continue; end if;
  kind:=s->>'kind'; minutes:=null; absolute_at:=null;
  if kind='relative' then
   if s->>'anchor'<>'planned' or s->>'anchor' is null or jsonb_typeof(s->'offset_minutes')<>'number' or s->'offset_minutes' is null then continue; end if;
   minutes:=(s->>'offset_minutes')::numeric;
   if minutes<>trunc(minutes) or minutes not between -10080 and 10080 then continue; end if;
  elsif kind='absolute' then
   if jsonb_typeof(s->'at')<>'string' or s->'at' is null or coalesce(s->>'at','') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$'
     or not exists(select 1 from pg_catalog.pg_timezone_names where name=s->>'time_zone') then continue; end if;
   begin absolute_at:=date_trunc('milliseconds',(s->>'at')::timestamptz); exception when others then continue; end;
  else continue; end if;
  sid:=(s->>'id')::uuid;
  if sid='00000000-0000-4000-8000-000000000001' and (kind<>'relative' or minutes<>0) then continue; end if;
  if sid=any(seen) then continue; end if;
  seen:=array_append(seen,sid);
  if s->>'enabled'='false' or not (s->'channels' ?| array['local','push']) then continue; end if;
  if kind='absolute' then fire_at:=absolute_at;
  else
   if coalesce(t->>'due_date','')='' then continue; end if;
   begin local_day:=(t->>'due_date')::date; exception when others then continue; end;
   if coalesce(t->>'due_time','')='' then local_clock:='08:00'; zone:=device_zone;
   else
    begin local_clock:=date_trunc('minute',(t->>'due_time')::interval)::time; exception when others then continue; end;
    zone:=coalesce(nullif(t->>'time_zone',''),device_zone);
   end if;
   planned:=local_day+local_clock;
   anchor:=taskfold_private.reminder_wall_time(planned,zone);
   if coalesce(t->>'time_zone','')<>'' and coalesce(t->>'due_time','')<>'' and coalesce(t->>'scheduled_at','')<>'' then
    begin saved:=date_trunc('milliseconds',(t->>'scheduled_at')::timestamptz);
     if date_trunc('minute',timezone(zone,saved))=planned then anchor:=saved; end if;
    exception when others then null; end;
   end if;
   if anchor is null then continue; end if;
   fire_at:=anchor+minutes*interval '1 minute';
  end if;
  select string_agg(c#>>'{}',',' order by c#>>'{}' collate "C") into channels from jsonb_array_elements(s->'channels') c;
  fields:=array['taskfold.reminder.v3',lower(t->>'id'),sid::text,kind,case when kind='relative' then 'planned' else '' end,
    case when kind='relative' then trunc(minutes)::bigint::text else '' end,
    case when kind='absolute' then round(extract(epoch from absolute_at)*1000)::bigint::text else '' end,
    case when kind='absolute' then s->>'time_zone' else '' end,channels,'1',round(extract(epoch from fire_at)*1000)::bigint::text,cycle::bigint::text];
  preimage:=''; foreach v in array fields loop preimage:=preimage||octet_length(v)::text||':'||v; end loop;
  signature:='r3:'||encode(extensions.digest(preimage,'sha256'),'hex'); spec_id:=sid; return next;
 end loop;
end $$;
revoke all on function taskfold_private.reminder_events(jsonb,text) from public,anon,authenticated;

create table taskfold_private.reminder_jobs (
 id text primary key check(id ~ '^[0-9a-f]{64}$'),
 device_id uuid not null references taskfold_private.reminder_devices(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 task_id uuid not null references public.tasks(id) on delete cascade,
 spec_id uuid not null, signature text not null check(signature ~ '^r3:[0-9a-f]{64}$'), fire_at timestamptz not null,
 device_revision bigint not null,
 state text not null default 'pending' check(state in ('pending','leased','sent','cancelled','failed')),
 attempts int not null default 0 check(attempts between 0 and 8),
 next_attempt timestamptz not null, lease_token uuid, lease_until timestamptz,
 updated_at timestamptz not null default now(), outcome text check(outcome in ('accepted','transient','permanent','invalid_token','obsolete','expired','exhausted')),
 check((state='leased' and lease_token is not null and lease_until is not null) or (state<>'leased' and lease_token is null and lease_until is null))
);
alter table taskfold_private.reminder_jobs enable row level security;
create policy no_direct_client_job_access on taskfold_private.reminder_jobs for all to anon,authenticated using(false) with check(false);
revoke all on taskfold_private.reminder_jobs from public,anon,authenticated;
grant select,insert,update,delete on taskfold_private.reminder_jobs to service_role;
create index reminder_jobs_due on taskfold_private.reminder_jobs(next_attempt,id) where state in ('pending','leased');
create index reminder_jobs_device on taskfold_private.reminder_jobs(device_id);
create index reminder_jobs_user on taskfold_private.reminder_jobs(user_id);
create index reminder_jobs_task on taskfold_private.reminder_jobs(task_id);
create index tasks_reminder_owner on public.tasks(user_id,id) where not completed and (due_date is not null or reminder_specs<>'[]'::jsonb);

create function taskfold_private.reminder_job_current(j taskfold_private.reminder_jobs)
returns boolean language sql stable security invoker set search_path = '' as $$
 select exists(select 1 from taskfold_private.reminder_devices d join auth.sessions a on a.id=d.session_id and a.user_id=d.user_id
  join public.tasks t on t.id=j.task_id and t.user_id=d.user_id
  cross join lateral taskfold_private.reminder_events(to_jsonb(t),d.binding->>'time_zone') e
  where d.id=j.device_id and d.user_id=j.user_id and d.revision=j.device_revision and d.expires_at>now()
   and (a.not_after is null or a.not_after>now()) and d.binding->>'enabled'='true' and d.binding->>'permission' in ('authorized','provisional')
   and (t.project_id is null or public.has_project_access(d.user_id,t.project_id))
   and e.spec_id=j.spec_id and e.signature=j.signature and e.fire_at=j.fire_at)
$$;
revoke all on function taskfold_private.reminder_job_current(taskfold_private.reminder_jobs) from public,anon,authenticated;

create function taskfold_private.cancel_obsolete_reminder_jobs()
returns trigger language plpgsql security definer set search_path = '' as $$
declare task_key uuid; device_key uuid; project_key uuid;
begin
 if tg_table_name='tasks' then task_key:=coalesce(new.id,old.id);
 elsif tg_table_name='reminder_devices' then device_key:=coalesce(new.id,old.id);
 elsif tg_table_name='project_collaborators' then project_key:=coalesce(new.project_id,old.project_id); end if;
 update taskfold_private.reminder_jobs j set state='cancelled',outcome='obsolete',lease_token=null,lease_until=null,updated_at=now()
 where j.state in ('pending','leased') and (j.task_id=task_key or j.device_id=device_key or j.task_id in (select id from public.tasks where project_id=project_key))
 and not taskfold_private.reminder_job_current(j);
 return null;
end $$;
revoke all on function taskfold_private.cancel_obsolete_reminder_jobs() from public,anon,authenticated;
create trigger taskfold_cancel_task_jobs after update on public.tasks for each row execute function taskfold_private.cancel_obsolete_reminder_jobs();
create trigger taskfold_cancel_device_jobs after update on taskfold_private.reminder_devices for each row execute function taskfold_private.cancel_obsolete_reminder_jobs();
create trigger taskfold_cancel_member_jobs after update or delete on public.project_collaborators for each row execute function taskfold_private.cancel_obsolete_reminder_jobs();

create function taskfold_private.reconcile_reminder_jobs(_device uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare d taskfold_private.reminder_devices; n int; cutoff timestamptz:=clock_timestamp();
begin
 perform pg_advisory_xact_lock(hashtextextended(_device::text,78136));
 select * into d from taskfold_private.reminder_devices where id=_device for update;
 if not found then return jsonb_build_object('queued',0); end if;
 update taskfold_private.reminder_jobs j set state='cancelled',outcome='obsolete',lease_token=null,lease_until=null,updated_at=cutoff
  where device_id=_device and state in ('pending','leased') and not taskfold_private.reminder_job_current(j);
 if d.expires_at<=cutoff or not exists(select 1 from auth.sessions where id=d.session_id and user_id=d.user_id and (not_after is null or not_after>cutoff))
   or coalesce(d.binding->>'enabled','false')<>'true' or d.binding->>'permission' not in ('authorized','provisional') then return jsonb_build_object('queued',0); end if;
 insert into taskfold_private.reminder_jobs(id,device_id,user_id,task_id,spec_id,signature,fire_at,device_revision,next_attempt)
 select encode(extensions.digest(d.user_id::text||'|'||d.id::text||'|'||t.id::text||'|'||e.spec_id::text||'|'||e.signature,'sha256'),'hex'),
  d.id,d.user_id,t.id,e.spec_id,e.signature,e.fire_at,d.revision,e.fire_at
 from public.tasks t cross join lateral taskfold_private.reminder_events(to_jsonb(t),d.binding->>'time_zone') e
 where t.user_id=d.user_id and not t.completed and (t.due_date is not null or t.reminder_specs<>'[]'::jsonb)
  and (t.project_id is null or public.has_project_access(d.user_id,t.project_id)) and e.fire_at between cutoff-interval '1 hour' and cutoff+interval '7 days'
 on conflict(id) do update set device_revision=excluded.device_revision,state='pending',outcome=null,lease_token=null,lease_until=null,next_attempt=excluded.fire_at,updated_at=cutoff
  where reminder_jobs.state='cancelled' and reminder_jobs.fire_at>cutoff;
 get diagnostics n=row_count;
 return jsonb_build_object('queued',n);
end $$;
revoke all on function taskfold_private.reconcile_reminder_jobs(uuid) from public,anon,authenticated;
grant execute on function taskfold_private.reconcile_reminder_jobs(uuid) to service_role;

create function taskfold_private.claim_reminder_jobs(_device uuid, _limit int default 25)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare cutoff timestamptz:=clock_timestamp(); result jsonb;
begin
 if _limit is null or _limit not between 1 and 100 then raise exception 'Invalid reminder batch size.'; end if;
 update taskfold_private.reminder_jobs j set state='cancelled',outcome=case when fire_at<cutoff-interval '1 hour' then 'expired' else 'obsolete' end,lease_token=null,lease_until=null,updated_at=cutoff
  where device_id=_device and state in ('pending','leased') and (fire_at<cutoff-interval '1 hour' or not taskfold_private.reminder_job_current(j));
 update taskfold_private.reminder_jobs set state='failed',outcome='exhausted',lease_token=null,lease_until=null,updated_at=cutoff
  where device_id=_device and state in ('pending','leased') and attempts>=8 and (lease_until is null or lease_until<=cutoff);
 with candidates as (select id from taskfold_private.reminder_jobs where device_id=_device and fire_at<=cutoff and next_attempt<=cutoff and attempts<8
   and (state='pending' or (state='leased' and lease_until<=cutoff)) order by next_attempt,id for update skip locked limit _limit),
 leased as (update taskfold_private.reminder_jobs j set state='leased',attempts=attempts+1,lease_token=gen_random_uuid(),lease_until=cutoff+interval '2 minutes',next_attempt=cutoff+interval '2 minutes',updated_at=cutoff
  from candidates c where j.id=c.id returning j.*)
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'device',device_id,'account',user_id,'task',task_id,'spec',spec_id,'signature',signature,'fire_at',fire_at,'lease',lease_token,'attempt',attempts)),'[]'::jsonb) into result from leased;
 return result;
end $$;
revoke all on function taskfold_private.claim_reminder_jobs(uuid,int) from public,anon,authenticated;
grant execute on function taskfold_private.claim_reminder_jobs(uuid,int) to service_role;

create function taskfold_private.finish_reminder_job(_id text, _lease uuid, _outcome text)
returns boolean language plpgsql security invoker set search_path = '' as $$
declare j taskfold_private.reminder_jobs; cutoff timestamptz:=clock_timestamp();
begin
 if _outcome is null or _outcome not in ('accepted','transient','permanent','invalid_token') then raise exception 'Invalid reminder outcome.'; end if;
 select * into j from taskfold_private.reminder_jobs where id=_id;
 if not found then return false; end if;
 -- Device before job is the same lock order as registration/reconciliation.
 perform 1 from taskfold_private.reminder_devices where id=j.device_id for update;
 select * into j from taskfold_private.reminder_jobs where id=_id for update;
 if not found or j.state<>'leased' or j.lease_token<>_lease or _lease is null or j.lease_until<=cutoff then return false; end if;
 if not taskfold_private.reminder_job_current(j) then
  update taskfold_private.reminder_jobs set state='cancelled',outcome='obsolete',lease_token=null,lease_until=null,updated_at=cutoff where id=_id; return false;
 end if;
 update taskfold_private.reminder_jobs set state=case when _outcome='accepted' then 'sent' when _outcome='transient' and attempts<8 then 'pending' else 'failed' end,
  outcome=_outcome,lease_token=null,lease_until=null,next_attempt=cutoff+least(3600,30*power(2,attempts-1))*interval '1 second',updated_at=cutoff where id=_id;
 if _outcome='invalid_token' then
  update taskfold_private.reminder_devices set user_id=null,session_id=null,binding=null,token_hash=null,expires_at=cutoff,updated_at=cutoff
   where id=j.device_id and revision=j.device_revision;
 end if;
 return true;
end $$;
revoke all on function taskfold_private.finish_reminder_job(text,uuid,text) from public,anon,authenticated;
grant execute on function taskfold_private.finish_reminder_job(text,uuid,text) to service_role;

-- Data API wrappers expose no privileged writer to native client roles.
create function public.taskfold_reconcile_reminder_jobs(_device uuid) returns jsonb language sql security invoker set search_path='' as $$ select taskfold_private.reconcile_reminder_jobs(_device) $$;
create function public.taskfold_claim_reminder_jobs(_device uuid,_limit int default 25) returns jsonb language sql security invoker set search_path='' as $$ select taskfold_private.claim_reminder_jobs(_device,_limit) $$;
create function public.taskfold_finish_reminder_job(_id text,_lease uuid,_outcome text) returns boolean language sql security invoker set search_path='' as $$ select taskfold_private.finish_reminder_job(_id,_lease,_outcome) $$;
revoke all on function public.taskfold_reconcile_reminder_jobs(uuid), public.taskfold_claim_reminder_jobs(uuid,int), public.taskfold_finish_reminder_job(text,uuid,text) from public,anon,authenticated;
grant execute on function public.taskfold_reconcile_reminder_jobs(uuid), public.taskfold_claim_reminder_jobs(uuid,int), public.taskfold_finish_reminder_job(text,uuid,text) to service_role;

-- Projection helpers have no client grants; service-only invoker routines need their explicit grants.
grant execute on function taskfold_private.reminder_wall_time(timestamp,text),taskfold_private.reminder_events(jsonb,text),taskfold_private.reminder_job_current(taskfold_private.reminder_jobs) to service_role;

create function taskfold_private.prepare_reminder_job(_id text,_lease uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare j taskfold_private.reminder_jobs; d taskfold_private.reminder_devices; t public.tasks; event_id text; provider_id text;
begin
 select * into j from taskfold_private.reminder_jobs where id=_id;
 if not found then return null; end if;
 select * into d from taskfold_private.reminder_devices where id=j.device_id for update;
 select * into j from taskfold_private.reminder_jobs where id=_id for update;
 if not found or j.state<>'leased' or _lease is null or j.lease_token<>_lease or j.lease_until<=clock_timestamp() or not taskfold_private.reminder_job_current(j) then return null; end if;
 select * into t from public.tasks where id=j.task_id;
 event_id:=t.id::text||case when t.reminder_specs='[]'::jsonb then '' else '.'||j.spec_id::text end;
 provider_id:=substr(j.id,1,8)||'-'||substr(j.id,9,4)||'-5'||substr(j.id,14,3)||'-a'||substr(j.id,18,3)||'-'||substr(j.id,21,12);
 return jsonb_build_object('id',j.id,'provider_id',provider_id,'collapse_id',j.id,'binding',d.binding,
  'content',jsonb_build_object('title',t.title,'body',coalesce(t.description,''),'category','taskfold.reminder',
   'info',jsonb_build_object('eventKind','task','eventID',event_id,'accountID',j.user_id,'taskID',j.task_id,'specID',j.spec_id,'signature',j.signature,
    'originalAt',extract(epoch from j.fire_at),'fireAt',extract(epoch from j.fire_at),'snoozed',false)));
end $$;
revoke all on function taskfold_private.prepare_reminder_job(text,uuid) from public,anon,authenticated;
grant execute on function taskfold_private.prepare_reminder_job(text,uuid) to service_role;
create function public.taskfold_prepare_reminder_job(_id text,_lease uuid) returns jsonb language sql security invoker set search_path='' as $$ select taskfold_private.prepare_reminder_job(_id,_lease) $$;
revoke all on function public.taskfold_prepare_reminder_job(text,uuid) from public,anon,authenticated;
grant execute on function public.taskfold_prepare_reminder_job(text,uuid) to service_role;

create function taskfold_private.maintain_reminder_queue(_limit int default 1000)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare retired int; removed int;
begin
 if _limit is null or _limit not between 1 and 1000 then raise exception 'Invalid maintenance batch size.'; end if;
 with expired as (select d.id from taskfold_private.reminder_devices d where d.binding is not null and
  (d.expires_at<=clock_timestamp() or not exists(select 1 from auth.sessions where id=d.session_id and user_id=d.user_id and (not_after is null or not_after>clock_timestamp())))
  order by d.expires_at,d.id for update of d skip locked limit _limit)
 update taskfold_private.reminder_devices d set user_id=null,session_id=null,binding=null,token_hash=null,expires_at=now(),updated_at=now() from expired e where d.id=e.id;
 get diagnostics retired=row_count;
 with terminal as (select id from taskfold_private.reminder_jobs where state in ('sent','failed','cancelled') and fire_at<clock_timestamp()-interval '8 days' order by fire_at,id for update skip locked limit _limit)
 delete from taskfold_private.reminder_jobs j using terminal t where j.id=t.id;
 get diagnostics removed=row_count;
 return jsonb_build_object('retired',retired,'removed',removed);
end $$;
revoke all on function taskfold_private.maintain_reminder_queue(int) from public,anon,authenticated;
grant execute on function taskfold_private.maintain_reminder_queue(int) to service_role;
create function public.taskfold_maintain_reminder_queue(_limit int default 1000) returns jsonb language sql security invoker set search_path='' as $$ select taskfold_private.maintain_reminder_queue(_limit) $$;
revoke all on function public.taskfold_maintain_reminder_queue(int) from public,anon,authenticated;
grant execute on function public.taskfold_maintain_reminder_queue(int) to service_role;

create function public.taskfold_reminder_device_page(_after uuid default null,_limit int default 100)
returns jsonb language sql security invoker set search_path='' as $$
 select coalesce(jsonb_agg(id order by id),'[]'::jsonb) from
 (select id from taskfold_private.reminder_devices where binding->>'enabled'='true' and expires_at>now() and (_after is null or id>_after) order by id limit greatest(0,least(coalesce(_limit,0),100))) d
$$;
revoke all on function public.taskfold_reminder_device_page(uuid,int) from public,anon,authenticated;
grant execute on function public.taskfold_reminder_device_page(uuid,int) to service_role;
create index reminder_devices_enabled on taskfold_private.reminder_devices(id) where binding->>'enabled'='true';
