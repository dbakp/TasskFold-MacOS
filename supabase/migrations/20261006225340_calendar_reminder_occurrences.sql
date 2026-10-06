-- Calendar occurrences are service-only and additive. Dispatch/cron activation is unchanged.
create function taskfold_private.reminder_month_day(_year int,_month int,r jsonb,_fallback int)
returns date language plpgsql immutable security invoker set search_path='' as $$
declare edge date; length int; chosen int; ordinal int; weekday int;
begin
 if _year not between 1 and 9999 or _month not between 1 and 12 then return null; end if;
 edge:=make_date(_year,_month,1); length:=extract(day from edge+interval '1 month'-interval '1 day');
 chosen:=least(coalesce(nullif(r->'dayOfMonth','null'::jsonb)::text::numeric::int,_fallback),length);
 if nullif(r->'weekdayOrdinal','null'::jsonb) is not null then
  ordinal:=(r->>'weekdayOrdinal')::numeric::int; weekday:=(r->>'weekday')::numeric::int;
  if ordinal=-1 then chosen:=length-mod(extract(dow from edge+length-1)::int-weekday+7,7);
  else chosen:=1+mod(weekday-extract(dow from edge)::int+7,7)+(ordinal-1)*7; end if;
 end if;
 if chosen not between 1 and length then return null; end if;
 return edge+chosen-1;
end $$;

create function taskfold_private.reminder_calendar_next(r jsonb,origin date,threshold date)
returns date language plpgsql immutable security invoker set search_path='' as $$
declare n int:=coalesce(nullif(r->'interval','null'::jsonb)::text::numeric::int,1); k text:=r->>'type';
 selected int[]; span int; cycle int; step int; weekday int; elapsed int; base int; target int; result date; edge date; upper_bound date;
begin
 threshold:=greatest(origin,threshold);
 if k in ('daily','custom') then result:=origin+((threshold-origin)/n+1)*n;
 elsif k='weekly' then
  select array_agg(distinct v::text::numeric::int order by v::text::numeric::int) into selected from jsonb_array_elements(coalesce(nullif(r->'daysOfWeek','null'::jsonb),'[]')) v;
  span:=7*n;
  if coalesce(cardinality(selected),0)=0 then result:=origin+((threshold-origin)/span+1)*span;
  else
   edge:=origin-extract(dow from origin)::int; cycle:=(threshold-edge)/span;
   for step in cycle..cycle+1 loop
    foreach weekday in array selected loop result:=edge+step*span+weekday; if result>threshold then exit; end if; result:=null; end loop;
    if result is not null then exit; end if;
   end loop;
  end if;
 elsif k='monthly' then
  elapsed:=(extract(year from threshold)::int-extract(year from origin)::int)*12+extract(month from threshold)::int-extract(month from origin)::int;
  cycle:=greatest(1,elapsed/n); base:=(extract(year from origin)::int-1)*12+extract(month from origin)::int-1;
  for step in cycle..cycle+400 loop
   target:=base+step*n; if target>=9999*12 then return null; end if;
   result:=taskfold_private.reminder_month_day(target/12+1,mod(target,12)+1,r,extract(day from origin)::int);
   if result>threshold then exit; end if; result:=null;
  end loop;
 elsif k='yearly' then
  cycle:=greatest(1,(extract(year from threshold)::int-extract(year from origin)::int)/n);
  for step in cycle..cycle+1 loop
   result:=taskfold_private.reminder_month_day(extract(year from origin)::int+step*n,(r->>'monthOfYear')::numeric::int,r,extract(day from origin)::int);
   if result>threshold then exit; end if; result:=null;
  end loop;
 end if;
 if result is null or extract(year from result) not between 1 and 9999 then return null; end if;
 if coalesce(r->>'endDate','')<>'' then upper_bound:=(r->>'endDate')::date; if result>upper_bound then return null; end if; end if;
 return result;
end $$;

-- Validate supported rows before casting/calculation; malformed or future rows stay inert.
create function taskfold_private.reminder_spec_valid(s jsonb)
returns boolean language plpgsql stable security invoker set search_path='' as $$
declare r jsonb; k text; value jsonb; field text; bounds int[]; number numeric; origin date; candidate date; start_month date; days int[]; sid uuid;
begin
 if jsonb_typeof(s)<>'object' or s->'version' is null or s->'version' not in ('1'::jsonb,'2'::jsonb)
  or coalesce(s->>'id','') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
  or (s ? 'enabled' and jsonb_typeof(s->'enabled')<>'boolean') then return false; end if;
 if jsonb_typeof(s->'channels') is distinct from 'array' then return false; end if;
 if jsonb_array_length(s->'channels')=0 or exists(select 1 from jsonb_array_elements(s->'channels') c where jsonb_typeof(c)<>'string' or c#>>'{}' not in ('local','push','email')) then return false; end if;
 sid:=(s->>'id')::uuid; k:=s->>'kind';
 if k='relative' and s->'version'='1'::jsonb then
  if s->>'anchor' is distinct from 'planned' or jsonb_typeof(s->'offset_minutes') is distinct from 'number' then return false; end if;
  number:=(s->>'offset_minutes')::numeric;
  return number=trunc(number) and number between -10080 and 10080 and (sid<>'00000000-0000-4000-8000-000000000001' or number=0);
 elsif k='absolute' and s->'version'='1'::jsonb then
  if sid='00000000-0000-4000-8000-000000000001' or jsonb_typeof(s->'at') is distinct from 'string'
   or coalesce(s->>'at','') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$'
   or not exists(select 1 from pg_catalog.pg_timezone_names where name=s->>'time_zone') then return false; end if;
  return isfinite((s->>'at')::timestamptz);
 elsif k is distinct from 'recurring' or s->'version'<>'2'::jsonb or s->'channels'<>'["local"]'::jsonb or sid='00000000-0000-4000-8000-000000000001' then return false; end if;
 if jsonb_typeof(s->'start_day') is distinct from 'string' or coalesce(s->>'start_day','') !~ '^\d{4}-\d{2}-\d{2}$'
  or jsonb_typeof(s->'time') is distinct from 'string' or coalesce(s->>'time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
  or not exists(select 1 from pg_catalog.pg_timezone_names where name=s->>'time_zone') or jsonb_typeof(s->'recurrence') is distinct from 'object' then return false; end if;
 origin:=(s->>'start_day')::date; if extract(year from origin) not between 1 and 9999 or to_char(origin,'YYYY-MM-DD')<>s->>'start_day' then return false; end if;
 r:=s->'recurrence'; k:=r->>'type'; if k is null or k not in ('daily','custom','weekly','monthly','yearly') then return false; end if;
 for field,bounds in select * from (values ('interval',array[1,10000]),('dayOfMonth',array[1,31]),('monthOfYear',array[1,12]),('weekday',array[0,6]),('weekdayOrdinal',array[-1,5]),('count',array[1,999])) f(name,limits) loop
  value:=nullif(r->field,'null'::jsonb);
  if value is not null then
   if jsonb_typeof(value)<>'number' then return false; end if;
   number:=value::text::numeric; if number<>trunc(number) or number not between bounds[1] and bounds[2] or (field='weekdayOrdinal' and number=0) then return false; end if;
  end if;
 end loop;
 if nullif(r->'fromCompletion','null'::jsonb) is not null and r->'fromCompletion'<>'false'::jsonb then return false; end if;
 if nullif(r->'endDate','null'::jsonb) is not null then
  if jsonb_typeof(r->'endDate')<>'string' then return false; end if;
  if r->>'endDate'<>'' and ((r->>'endDate') !~ '^\d{4}-\d{2}-\d{2}$' or (r->>'endDate')::date<origin) then return false; end if;
 end if;
 if nullif(r->'daysOfWeek','null'::jsonb) is not null then
  if k<>'weekly' or jsonb_typeof(r->'daysOfWeek')<>'array' then return false; end if;
  if jsonb_array_length(r->'daysOfWeek')>7 then return false; end if;
  for value in select * from jsonb_array_elements(r->'daysOfWeek') loop
   if jsonb_typeof(value)<>'number' then return false; end if; number:=value::text::numeric;
   if number<>trunc(number) or number not between 0 and 6 then return false; end if;
  end loop;
 end if;
 if nullif(r->'dayOfMonth','null'::jsonb) is not null and k not in ('monthly','yearly') then return false; end if;
 if nullif(r->'monthOfYear','null'::jsonb) is not null and k<>'yearly' then return false; end if;
 if nullif(r->'weekdayOrdinal','null'::jsonb) is not null and (k<>'monthly' or nullif(r->'weekday','null'::jsonb) is null) then return false; end if;
 if nullif(r->'weekday','null'::jsonb) is not null and nullif(r->'weekdayOrdinal','null'::jsonb) is null then return false; end if;
 if k in ('monthly','yearly') and nullif(r->'dayOfMonth','null'::jsonb) is null and nullif(r->'weekdayOrdinal','null'::jsonb) is null then return false; end if;
 if k='yearly' and nullif(r->'monthOfYear','null'::jsonb) is null then return false; end if;
 if k='weekly' and coalesce(jsonb_array_length(nullif(r->'daysOfWeek','null'::jsonb)),0)>0
  and not exists(select 1 from jsonb_array_elements(r->'daysOfWeek') d where d::text::numeric::int=extract(dow from origin)::int) then return false; end if;
 if k in ('monthly','yearly') then
  candidate:=taskfold_private.reminder_month_day(extract(year from origin)::int,case when k='yearly' then (r->>'monthOfYear')::numeric::int else extract(month from origin)::int end,r,extract(day from origin)::int);
  if candidate is distinct from origin then return false; end if;
 end if;
 return taskfold_private.reminder_wall_time(origin+(s->>'time')::time,s->>'time_zone') is not null;
exception when others then return false;
end $$;

create function taskfold_private.reminder_calendar_dates(s jsonb,_after timestamptz,_until timestamptz)
returns setof timestamptz language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=s->'recurrence'; origin date; day date; threshold date; at timestamptz; emitted int:=0; consumed int:=0; count_limit int; zone text:=s->>'time_zone'; clock time;
begin
 if not isfinite(_after) or not isfinite(_until) or _until<=_after or not taskfold_private.reminder_spec_valid(s) or s->'version'<>'2'::jsonb then return; end if;
 origin:=(s->>'start_day')::date; clock:=(s->>'time')::time; count_limit:=nullif(r->'count','null'::jsonb)::text::numeric::int; day:=origin;
 if count_limit is null then
  at:=taskfold_private.reminder_wall_time(day+clock,zone);
  if at>_after and at<=_until then return next at; emitted:=1; end if;
  threshold:=greatest(origin,timezone(zone,_after)::date-1);
  day:=taskfold_private.reminder_calendar_next(r,origin,threshold);
 end if;
 while day is not null and emitted<60 loop
  at:=taskfold_private.reminder_wall_time(day+clock,zone);
  if at>_until then exit; end if;
  if at is not null then
   consumed:=consumed+1;
   if at>_after then return next at; emitted:=emitted+1; end if;
  end if;
  if count_limit is not null and consumed>=count_limit then exit; end if;
  day:=taskfold_private.reminder_calendar_next(r,origin,day);
 end loop;
end $$;

-- Inclusive bounded worker window. The legacy projector remains unchanged for old callers.
-- Scan every supported row together so a first valid disabled/v2 ID suppresses later copies.
create function taskfold_private.reminder_events_window(t jsonb,device_zone text,_from timestamptz,_until timestamptz)
returns table(spec_id uuid,fire_at timestamptz,signature text) language plpgsql stable security invoker set search_path='' as $$
declare specs jsonb:=coalesce(t->'reminder_specs','[]'); s jsonb; legacy jsonb:='[]'; seen uuid[]:='{}'; sid uuid; r jsonb; days text; numeric_fields text; fields text[]; preimage text; v text; instant timestamptz; cycle numeric; generation text;
begin
 if not isfinite(_from) or not isfinite(_until) or _until<_from or _until-_from>interval '8 days' or t->>'completed'='true' or jsonb_typeof(specs) is distinct from 'array' then return; end if;
 if nullif(t->'task_generation','null'::jsonb) is not null and (jsonb_typeof(t->'task_generation')<>'string' or coalesce(t->>'task_generation','') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') then return; end if;
 generation:=lower(coalesce(t->>'task_generation','')); if generation<>'' and generation !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then return; end if;
 begin cycle:=coalesce((t->>'completion_version')::numeric,0); exception when others then return; end;
 if cycle<>trunc(cycle) or cycle not between 0 and 9007199254740991 then return; end if;
 if specs='[]'::jsonb then return query select e.* from taskfold_private.reminder_events(t,device_zone) e where e.fire_at between _from and _until; return; end if;
 for s in select value from jsonb_array_elements(specs) with ordinality where ordinality<=20 loop
  if not taskfold_private.reminder_spec_valid(s) then continue; end if;
  sid:=(s->>'id')::uuid; if sid=any(seen) then continue; end if; seen:=array_append(seen,sid);
  if s->'version'='1'::jsonb then legacy:=legacy||jsonb_build_array(s); continue; end if;
  if s->>'enabled'='false' then continue; end if;
  r:=s->'recurrence';
  select coalesce(string_agg(d::text,',' order by d),'') into days from (select distinct v::text::numeric::int d from jsonb_array_elements(coalesce(nullif(r->'daysOfWeek','null'::jsonb),'[]')) v) f;
  select string_agg(coalesce(nullif(r->name,'null'::jsonb)::text::numeric::int::text,''),',' order by position) into numeric_fields
   from unnest(array['dayOfMonth','monthOfYear','weekday','weekdayOrdinal','count']) with ordinality f(name,position);
  fields:=array['taskfold.reminder.v5',lower(t->>'id'),sid::text,s->>'start_day',s->>'time',s->>'time_zone',r->>'type',coalesce(nullif(r->'interval','null'::jsonb)::text::numeric::int,1)::text,days,numeric_fields,coalesce(r->>'endDate',''),'local','1'];
  preimage:=''; foreach v in array fields loop preimage:=preimage||octet_length(v)::text||':'||v; end loop;
  for instant in select * from taskfold_private.reminder_calendar_dates(s,_from-interval '1 microsecond',_until) loop
   fields:=array[round(extract(epoch from instant)*1000)::bigint::text,cycle::bigint::text,generation]; v:='';
   foreach days in array fields loop v:=v||octet_length(days)::text||':'||days; end loop;
   spec_id:=sid; fire_at:=instant; signature:='r5:'||encode(extensions.digest(preimage||v,'sha256'),'hex'); return next;
  end loop;
 end loop;
 if legacy<>'[]'::jsonb then return query select e.* from taskfold_private.reminder_events(t||jsonb_build_object('reminder_specs',legacy),device_zone) e where e.fire_at between _from and _until; end if;
end $$;

CREATE OR REPLACE FUNCTION taskfold_private.reconcile_reminder_jobs(_device uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare d taskfold_private.reminder_devices; n int; cutoff timestamptz:=clock_timestamp();
begin
 perform pg_advisory_xact_lock(hashtextextended(_device::text,78136));
 select * into d from taskfold_private.reminder_devices where id=_device for update;
 if not found then return jsonb_build_object('queued',0); end if;
 update taskfold_private.reminder_jobs j set state='cancelled',outcome='obsolete',lease_token=null,lease_until=null,updated_at=cutoff
  where device_id=_device and state in ('pending','leased') and not taskfold_private.reminder_job_current(j);
 if d.expires_at<=cutoff or not taskfold_private.reminder_session_live(d.session_id,d.user_id)
   or coalesce(d.binding->>'enabled','false')<>'true' or d.binding->>'permission' not in ('authorized','provisional') then return jsonb_build_object('queued',0); end if;
 insert into taskfold_private.reminder_jobs(id,device_id,user_id,task_id,spec_id,signature,fire_at,device_revision,next_attempt)
 select encode(extensions.digest(d.user_id::text||'|'||d.id::text||'|'||t.id::text||'|'||e.spec_id::text||'|'||e.signature,'sha256'),'hex'),
  d.id,d.user_id,t.id,e.spec_id,e.signature,e.fire_at,d.revision,e.fire_at
 from public.tasks t join taskfold_private.task_generations g on g.task_id=t.id and g.user_id=t.user_id
  and g.generation=coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000')
 cross join lateral taskfold_private.reminder_events_window(to_jsonb(t),d.binding->>'time_zone',cutoff-interval '1 hour',cutoff+interval '7 days') e
 where t.user_id=d.user_id and not t.completed and (t.due_date is not null or t.reminder_specs<>'[]'::jsonb)
  and (t.project_id is null or public.has_project_access(d.user_id,t.project_id)) and e.fire_at>=g.eligible_at and e.fire_at>=d.enabled_since and e.fire_at between cutoff-interval '1 hour' and cutoff+interval '7 days'
 on conflict(id) do update set device_revision=excluded.device_revision,state='pending',outcome=null,lease_token=null,lease_until=null,next_attempt=excluded.fire_at,updated_at=cutoff
  where reminder_jobs.state='cancelled' and reminder_jobs.fire_at>cutoff;
 get diagnostics n=row_count;
 return jsonb_build_object('queued',n);
end $function$;


CREATE OR REPLACE FUNCTION taskfold_private.reminder_job_current(j taskfold_private.reminder_jobs)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 select exists(select 1 from taskfold_private.reminder_devices d
  join public.tasks t on t.id=j.task_id and t.user_id=d.user_id
  join taskfold_private.task_generations g on g.task_id=t.id and g.user_id=t.user_id
   and g.generation=coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000')
  cross join lateral taskfold_private.reminder_events_window(to_jsonb(t),d.binding->>'time_zone',j.fire_at,j.fire_at) e
  where d.id=j.device_id and d.user_id=j.user_id and d.revision=j.device_revision and d.expires_at>now()
   and taskfold_private.reminder_session_live(d.session_id,d.user_id) and d.binding->>'enabled'='true' and d.binding->>'permission' in ('authorized','provisional')
   and (t.project_id is null or public.has_project_access(d.user_id,t.project_id))
   and e.fire_at>=g.eligible_at and e.fire_at>=d.enabled_since
   and e.spec_id=j.spec_id and e.signature=j.signature and e.fire_at=j.fire_at)
$function$;



CREATE OR REPLACE FUNCTION taskfold_private.prepare_reminder_job(_id text, _lease uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare j taskfold_private.reminder_jobs; d taskfold_private.reminder_devices; t public.tasks; event_id text; provider_id text;
begin
 select * into j from taskfold_private.reminder_jobs where id=_id;
 if not found then return null; end if;
 select * into d from taskfold_private.reminder_devices where id=j.device_id for update;
 select * into j from taskfold_private.reminder_jobs where id=_id for update;
 if not found or j.state<>'leased' or _lease is null or j.lease_token<>_lease or j.lease_until<=clock_timestamp() or not taskfold_private.reminder_job_current(j) then return null; end if;
 select * into t from public.tasks where id=j.task_id;
 event_id:=t.id::text||case when t.reminder_specs='[]'::jsonb then '' else '.'||j.spec_id::text end||case when j.signature like 'r5:%' then '.'||round(extract(epoch from j.fire_at)*1000)::bigint::text else '' end;
 provider_id:=substr(j.id,1,8)||'-'||substr(j.id,9,4)||'-5'||substr(j.id,14,3)||'-a'||substr(j.id,18,3)||'-'||substr(j.id,21,12);
 return jsonb_build_object('id',j.id,'provider_id',provider_id,'collapse_id',j.id,'binding',d.binding,
  'content',jsonb_build_object('title',left(t.title,128),'body','Open Taskfold to review this task.','category','taskfold.reminder',
   'info',jsonb_build_object('eventKind','task','eventID',event_id,'accountID',j.user_id,'taskID',j.task_id,'specID',j.spec_id,'signature',j.signature,
    'originalAt',extract(epoch from j.fire_at),'fireAt',extract(epoch from j.fire_at),'snoozed',false,'calendarOccurrence',j.signature like 'r5:%')));
end $function$;



alter table taskfold_private.reminder_jobs drop constraint reminder_jobs_signature_check;
alter table taskfold_private.reminder_jobs add constraint reminder_jobs_signature_check check(signature ~ '^r[345]:[0-9a-f]{64}$');
revoke all on function taskfold_private.reminder_month_day(int,int,jsonb,int) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_month_day(int,int,jsonb,int) to service_role;
revoke all on function taskfold_private.reminder_calendar_next(jsonb,date,date) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_calendar_next(jsonb,date,date) to service_role;
revoke all on function taskfold_private.reminder_spec_valid(jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_spec_valid(jsonb) to service_role;
revoke all on function taskfold_private.reminder_calendar_dates(jsonb,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_calendar_dates(jsonb,timestamptz,timestamptz) to service_role;
revoke all on function taskfold_private.reminder_events_window(jsonb,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_events_window(jsonb,text,timestamptz,timestamptz) to service_role;
