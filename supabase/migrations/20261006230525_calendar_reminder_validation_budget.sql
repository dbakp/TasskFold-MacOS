-- A supported row is validated once during joint ID selection. Public/service entry
-- points still validate raw documents; the internal iterator accepts only those rows.
create function taskfold_private.reminder_calendar_dates_validated(s jsonb,_after timestamptz,_until timestamptz)
returns setof timestamptz language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=s->'recurrence'; origin date; day date; threshold date; at timestamptz; emitted int:=0; consumed int:=0; count_limit int; zone text:=s->>'time_zone'; clock time;
begin
 if not isfinite(_after) or not isfinite(_until) or _until<=_after or s->'version'<>'2'::jsonb then return; end if;
 origin:=(s->>'start_day')::date; clock:=(s->>'time')::time; count_limit:=nullif(r->'count','null'::jsonb)::text::numeric::int; day:=origin;
 if count_limit is null then
  at:=taskfold_private.reminder_calendar_wall_time(day+clock,zone);
  if at>_after and at<=_until then return next at; emitted:=1; end if;
  threshold:=greatest(origin,timezone(zone,_after)::date-1);
  day:=taskfold_private.reminder_calendar_next(r,origin,threshold);
 end if;
 while day is not null and emitted<60 loop
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

create or replace function taskfold_private.reminder_calendar_dates(s jsonb,_after timestamptz,_until timestamptz)
returns setof timestamptz language plpgsql stable security invoker set search_path='' as $$
begin
 if not taskfold_private.reminder_spec_valid(s) or s->'version'<>'2'::jsonb then return; end if;
 return query select * from taskfold_private.reminder_calendar_dates_validated(s,_after,_until);
end $$;
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
 return taskfold_private.reminder_calendar_wall_time(origin+(s->>'time')::time,s->>'time_zone') is not null;
exception when others then return false;
end $$;

-- Qualify JSON elements independently of the signature framing variable.
create or replace function taskfold_private.reminder_events_window(t jsonb,device_zone text,_from timestamptz,_until timestamptz)
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
  select coalesce(string_agg(d::text,',' order by d),'') into days from (select distinct element.value::text::numeric::int d from jsonb_array_elements(coalesce(nullif(r->'daysOfWeek','null'::jsonb),'[]')) as element(value)) f;
  select string_agg(coalesce(nullif(r->name,'null'::jsonb)::text::numeric::int::text,''),',' order by position) into numeric_fields
   from unnest(array['dayOfMonth','monthOfYear','weekday','weekdayOrdinal','count']) with ordinality f(name,position);
  fields:=array['taskfold.reminder.v5',lower(t->>'id'),sid::text,s->>'start_day',s->>'time',s->>'time_zone',r->>'type',coalesce(nullif(r->'interval','null'::jsonb)::text::numeric::int,1)::text,days,numeric_fields,coalesce(r->>'endDate',''),'local','1'];
  preimage:=''; foreach v in array fields loop preimage:=preimage||octet_length(v)::text||':'||v; end loop;
  for instant in select * from taskfold_private.reminder_calendar_dates_validated(s,_from-interval '1 microsecond',_until) loop
   fields:=array[round(extract(epoch from instant)*1000)::bigint::text,cycle::bigint::text,generation]; v:='';
   foreach days in array fields loop v:=v||octet_length(days)::text||':'||days; end loop;
   spec_id:=sid; fire_at:=instant; signature:='r5:'||encode(extensions.digest(preimage||v,'sha256'),'hex'); return next;
  end loop;
 end loop;
 if legacy<>'[]'::jsonb then return query select e.* from taskfold_private.reminder_events(t||jsonb_build_object('reminder_specs',legacy),device_zone) e where e.fire_at between _from and _until; end if;
end $$;

revoke all on function taskfold_private.reminder_calendar_dates_validated(jsonb,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_calendar_dates_validated(jsonb,timestamptz,timestamptz) to service_role;
