-- Indexed names retain the strict named-zone contract without enumerating all zones per setting.
-- Refresh hourly through existing service-only maintenance, and explicitly after a tzdata upgrade.
create table taskfold_private.reminder_time_zones (
 name text primary key,
 refreshed_at timestamptz not null
);
alter table taskfold_private.reminder_time_zones enable row level security;
create policy reminder_time_zones_client_deny on taskfold_private.reminder_time_zones
 for all to anon,authenticated using(false) with check(false);
revoke all on taskfold_private.reminder_time_zones from public,anon,authenticated;
grant select,insert,update,delete on taskfold_private.reminder_time_zones to service_role;

create function taskfold_private.refresh_reminder_time_zones(_force boolean default false)
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
 on conflict(name) do update set refreshed_at=excluded.refreshed_at;
 return cardinality(names);
end $$;
create function taskfold_private.reminder_named_time_zone_valid(_zone text)
returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from taskfold_private.reminder_time_zones where name=_zone)
$$;
revoke all on function taskfold_private.refresh_reminder_time_zones(boolean),taskfold_private.reminder_named_time_zone_valid(text) from public,anon,authenticated;
grant execute on function taskfold_private.refresh_reminder_time_zones(boolean),taskfold_private.reminder_named_time_zone_valid(text) to service_role;
do $$ begin perform taskfold_private.refresh_reminder_time_zones(true); end $$;

create or replace function taskfold_private.reminder_spec_valid(s jsonb)
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
   or not taskfold_private.reminder_named_time_zone_valid(s->>'time_zone') then return false; end if;
  return isfinite((s->>'at')::timestamptz);
 elsif k is distinct from 'recurring' or s->'version'<>'2'::jsonb or s->'channels'<>'["local"]'::jsonb or sid='00000000-0000-4000-8000-000000000001' then return false; end if;
 if jsonb_typeof(s->'start_day') is distinct from 'string' or coalesce(s->>'start_day','') !~ '^\d{4}-\d{2}-\d{2}$'
  or jsonb_typeof(s->'time') is distinct from 'string' or coalesce(s->>'time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
  or not taskfold_private.reminder_named_time_zone_valid(s->>'time_zone') or jsonb_typeof(s->'recurrence') is distinct from 'object' then return false; end if;
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
 -- An exact round trip proves the origin exists; ambiguous folds also exist.
 -- Gaps and skipped civil days still use the exact resolver before accepting a rule.
 return timezone(s->>'time_zone',(origin+(s->>'time')::time) at time zone (s->>'time_zone'))=origin+(s->>'time')::time
  or taskfold_private.reminder_calendar_wall_time(origin+(s->>'time')::time,s->>'time_zone') is not null;
exception when others then return false;
end $$;

create or replace function taskfold_private.reminder_events(t jsonb, device_zone text)
returns table(spec_id uuid,fire_at timestamptz,signature text) language plpgsql stable security invoker set search_path = '' as $$
declare specs jsonb; s jsonb; seen uuid[]:='{}'; sid uuid; kind text; anchor timestamptz; absolute_at timestamptz;
 zone text; local_day date; local_clock time; planned timestamp; saved timestamptz; minutes numeric; channels text; fields text[]; preimage text; v text; cycle numeric; generation text; prefix text;
begin
 if t->>'completed'='true' then return; end if;
 generation:=lower(coalesce(t->>'task_generation',''));
 if generation<>'' and generation !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then return; end if;
 prefix:=case when generation='' then 'r3:' else 'r4:' end;
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
     or not taskfold_private.reminder_named_time_zone_valid(s->>'time_zone') then continue; end if;
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
  fields:=array[case when generation='' then 'taskfold.reminder.v3' else 'taskfold.reminder.v4' end,lower(t->>'id'),sid::text,kind,case when kind='relative' then 'planned' else '' end,
    case when kind='relative' then trunc(minutes)::bigint::text else '' end,
    case when kind='absolute' then round(extract(epoch from absolute_at)*1000)::bigint::text else '' end,
    case when kind='absolute' then s->>'time_zone' else '' end,channels,'1',round(extract(epoch from fire_at)*1000)::bigint::text,cycle::bigint::text];
  if generation<>'' then fields:=array_append(fields,generation); end if;
  preimage:=''; foreach v in array fields loop preimage:=preimage||octet_length(v)::text||':'||v; end loop;
  signature:=prefix||encode(extensions.digest(preimage,'sha256'),'hex'); spec_id:=sid; return next;
 end loop;
end $$;

create or replace function taskfold_private.reminder_calendar_dates_validated(s jsonb,_after timestamptz,_until timestamptz)
returns setof timestamptz language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=s->'recurrence'; origin date; day date; threshold date; at timestamptz; emitted int:=0; consumed int:=0; count_limit int; zone text:=s->>'time_zone'; clock time; step int; batch_size int; skipped int; final_day date;
begin
 if _after is null or _until is null or not isfinite(_after) or not isfinite(_until) or _until<=_after or s->'version'<>'2'::jsonb then return; end if;
 origin:=(s->>'start_day')::date; clock:=(s->>'time')::time; count_limit:=nullif(r->'count','null'::jsonb)::text::numeric::int; day:=origin;
 if r->>'type' in ('daily','custom') then step:=coalesce((r->>'interval')::numeric::int,1);
 elsif r->>'type'='weekly' and coalesce(jsonb_array_length(nullif(r->'daysOfWeek','null'::jsonb)),0)=0 then step:=7*coalesce((r->>'interval')::numeric::int,1); end if;
 final_day:=least(date '9999-12-31',coalesce(nullif(r->>'endDate','')::date,date '9999-12-31'));
 if count_limit is null then
  at:=taskfold_private.reminder_calendar_wall_time(day+clock,zone);
  if at>_after and at<=_until then return next at; emitted:=1; end if;
  threshold:=greatest(origin,timezone(zone,_after)::date-1);
  day:=taskfold_private.reminder_calendar_next(r,origin,threshold);
 end if;
 while day is not null and emitted<60 loop
  -- Consume a proven already-past prefix. Exact round trips consume one count.
  -- A mapped later valid minute on the same day also proves a gap's next valid
  -- minute exists no later than this past instant. Second-based historical
  -- transitions, whole skipped days and possibly future folds use the resolver.
  -- Counts remain anchored; the series is bounded by the original count/end/year.
  if count_limit is not null and step is not null and (day+clock) at time zone zone<=_after then
   if day>final_day then exit; end if;
   batch_size:=least(count_limit-consumed,(final_day-day)/step+1);
   if batch_size<=0 then exit; end if;
   with mapped as materialized (
    select i,day+i*step+clock as wall,(day+i*step+clock) at time zone zone as instant
    from generate_series(0,batch_size-1) i
   ) select coalesce(min(i) filter(where instant>_after or not (
      timezone(zone,instant)=wall or (timezone(zone,instant)::date=wall::date
       and timezone(zone,instant)>wall
       and date_trunc('minute',timezone(zone,instant))=timezone(zone,instant))
    )),batch_size) into skipped from mapped;
   consumed:=consumed+skipped;
   if consumed>=count_limit or skipped=batch_size then exit; end if;
   day:=day+skipped*step;
  end if;
  -- A past exact wall-time round trip proves this civil day consumed one count.
  -- The default second fold is safe only when it is also past. Gaps/skipped days
  -- and any possible future first fold still use the exact native resolver.
  at:=(day+clock) at time zone zone;
  if count_limit is not null and at<=_after and timezone(zone,at)=day+clock then
   consumed:=consumed+1;
  else
   at:=taskfold_private.reminder_calendar_wall_time(day+clock,zone);
   if at>_until then exit; end if;
   if at is not null then
    consumed:=consumed+1;
    if at>_after then return next at; emitted:=emitted+1; end if;
   end if;
  end if;
  if count_limit is not null and consumed>=count_limit then exit; end if;
  day:=taskfold_private.reminder_calendar_next(r,origin,day);
 end loop;
end $$;

create or replace function taskfold_private.maintain_reminder_queue(_limit int default 1000)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare retired int; removed int;
begin
 if _limit is null or _limit not between 1 and 1000 then raise exception 'Invalid maintenance batch size.'; end if;
 perform taskfold_private.refresh_reminder_time_zones();
 with expired as (select d.id from taskfold_private.reminder_devices d where d.binding is not null and
  (d.expires_at<=clock_timestamp() or not taskfold_private.reminder_session_live(d.session_id,d.user_id))
  order by d.expires_at,d.id for update of d skip locked limit _limit)
 update taskfold_private.reminder_devices d set user_id=null,session_id=null,binding=null,token_hash=null,expires_at=now(),updated_at=now() from expired e where d.id=e.id;
 get diagnostics retired=row_count;
 with terminal as (select id from taskfold_private.reminder_jobs where state in ('sent','failed','cancelled') and fire_at<clock_timestamp()-interval '8 days' order by fire_at,id for update skip locked limit _limit)
 delete from taskfold_private.reminder_jobs j using terminal t where j.id=t.id;
 get diagnostics removed=row_count;
 return jsonb_build_object('retired',retired,'removed',removed);
end $$;
