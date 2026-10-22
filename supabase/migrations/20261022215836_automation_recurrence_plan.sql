-- Candidate only: pure planning, no public RPC, task writes or new grants.
-- Owned by each app repository. Task operations must additionally enforce access,
-- generation/revision baselines, immutable request claims and successor insertion.
create function taskfold_private.automation_civil_day(value text)
returns date language plpgsql immutable security invoker set search_path='' as $$
declare result date; begin
 if value is null or value !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
 result:=value::date;
 if extract(year from result) not between 1 and 9999 or to_char(result,'YYYY-MM-DD')<>value then return null; end if;
 return result;
exception when datetime_field_overflow or invalid_datetime_format then return null;
end $$;

create function taskfold_private.automation_recurrence_valid(r jsonb)
returns boolean language plpgsql immutable security invoker set search_path='' as $$
declare field text; bounds int[]; value jsonb; n numeric; days int[]:='{}'; begin
 if jsonb_typeof(r) is distinct from 'object' or coalesce(r->>'type','') not in ('daily','custom','weekly','monthly','yearly') then return false; end if;
 for field,bounds in select * from (values ('interval',array[1,10000]),('dayOfMonth',array[1,31]),('monthOfYear',array[1,12]),('weekday',array[0,6]),('count',array[1,2147483647]),('weekdayOrdinal',array[-1,5])) f(name,limits) loop
  value:=nullif(r->field,'null'::jsonb);
  if value is not null then
   if jsonb_typeof(value)<>'number' then return false; end if;
   n:=value::text::numeric;
   if n<>trunc(n) or n not between bounds[1] and bounds[2] then return false; end if;
  end if;
 end loop;
 if nullif(r->'weekdayOrdinal','null'::jsonb) is not null and (r->>'type'<>'monthly' or (r->>'weekdayOrdinal')::numeric=0 or nullif(r->'weekday','null'::jsonb) is null) then return false; end if;
 if nullif(r->'daysOfWeek','null'::jsonb) is not null then
  if jsonb_typeof(r->'daysOfWeek')<>'array' or jsonb_array_length(r->'daysOfWeek')>7 then return false; end if;
  for value in select * from jsonb_array_elements(r->'daysOfWeek') loop
   if jsonb_typeof(value)<>'number' then return false; end if;
   n:=value::text::numeric; if n<>trunc(n) or n not between 0 and 6 then return false; end if;
  end loop;
 end if;
 if nullif(r->'daysOfMonth','null'::jsonb) is not null then
  if r->>'type'<>'monthly' or jsonb_typeof(r->'daysOfMonth')<>'array' or jsonb_array_length(r->'daysOfMonth') not between 1 and 31 then return false; end if;
  if exists(select 1 from unnest(array['dayOfMonth','weekdayOrdinal','weekday','monthOfYear','daysOfWeek']) key where nullif(r->key,'null'::jsonb) is not null) then return false; end if;
  for value in select * from jsonb_array_elements(r->'daysOfMonth') loop
   if jsonb_typeof(value)<>'number' then return false; end if;
   n:=value::text::numeric; if n<>trunc(n) or n not between 1 and 31 or n::int=any(days) then return false; end if;
   days:=array_append(days,n::int);
  end loop;
 end if;
 if nullif(r->'fromCompletion','null'::jsonb) is not null and jsonb_typeof(r->'fromCompletion')<>'boolean' then return false; end if;
 if nullif(r->'endDate','null'::jsonb) is not null then
  if jsonb_typeof(r->'endDate')<>'string' then return false; end if;
  if r->>'endDate'<>'' and taskfold_private.automation_civil_day(r->>'endDate') is null then return false; end if;
 end if;
 return true;
end $$;

create function taskfold_private.automation_month_dates(y int,m int,r jsonb,fallback int)
returns setof date language plpgsql immutable security invoker set search_path='' as $$
declare length int; edge date; day int; ordinal int; weekday int; begin
 if y not between 1 and 9999 or m not between 1 and 12 then return; end if;
 length:=extract(day from make_date(y,m,1)+interval '1 month'-interval '1 day');
 if nullif(r->'daysOfMonth','null'::jsonb) is not null then
  return query select distinct make_date(y,m,least(value::text::numeric::int,length)) from jsonb_array_elements(r->'daysOfMonth') order by 1;
 else
  day:=coalesce((r->>'dayOfMonth')::numeric::int,fallback);
  ordinal:=(r->>'weekdayOrdinal')::numeric::int; weekday:=(r->>'weekday')::numeric::int;
  if ordinal is not null and weekday is not null then
   edge:=make_date(y,m,case when ordinal=-1 then length else 1 end);
   day:=case when ordinal=-1 then length-mod(extract(dow from edge)::int-weekday+7,7)
    else 1+mod(weekday-extract(dow from edge)::int+7,7)+(ordinal-1)*7 end;
  else day:=least(day,length); end if;
  if day between 1 and length then return next make_date(y,m,day); end if;
 end if;
end $$;

create function taskfold_private.automation_successor_id(parent text,day text)
returns uuid language sql immutable security invoker set search_path='' as $$
 select (substr(h,1,8)||'-'||substr(h,9,4)||'-5'||substr(h,14,3)||'-a'||substr(h,18,3)||'-'||substr(h,21,12))::uuid
 from (select encode(extensions.digest('com.taskfold.recurrence.v1|'||lower(parent)||'|'||day,'sha256'),'hex') h) digest
$$;

-- Gregorian Calendar day addition counts a whole skipped/repeated date-line day
-- as elapsed time while retaining ordinary DST wall-clock adjustment. Work with
-- explicit instants; the database connection's TimeZone must not affect results.
create function taskfold_private.automation_calendar_add_days(origin date,amount int,zone text)
returns date language plpgsql stable security invoker set search_path='' as $$
declare start_at timestamptz:=origin::timestamp at time zone zone; candidate timestamptz;
 offset_start numeric; delta numeric; pass int;
begin
 offset_start:=extract(epoch from ((start_at at time zone zone)-(start_at at time zone 'UTC')));
 candidate:=start_at+make_interval(secs=>amount::double precision*86400);
 for pass in 1..2 loop
  delta:=extract(epoch from ((candidate at time zone zone)-(candidate at time zone 'UTC')))-offset_start;
  delta:=delta-round(delta/86400)*86400;
  candidate:=start_at+make_interval(secs=>amount::double precision*86400-delta::double precision);
 end loop;
 return (candidate at time zone zone)::date;
end $$;

create function taskfold_private.automation_calendar_day_distance(origin date,target date,zone text)
returns int language plpgsql stable security invoker set search_path='' as $$
declare start_at timestamptz:=origin::timestamp at time zone zone; end_at timestamptz:=target::timestamp at time zone zone; delta numeric;
begin
 delta:=extract(epoch from ((end_at at time zone zone)-(end_at at time zone 'UTC')))-extract(epoch from ((start_at at time zone zone)-(start_at at time zone 'UTC')));
 delta:=delta-round(delta/86400)*86400;
 return round((extract(epoch from (end_at-start_at))+delta)/86400)::int;
end $$;

create function taskfold_private.automation_recurrence_plan(task jsonb,completed_at timestamptz,input_zone text)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=task->'recurrence_pattern'; origin date; threshold date; result date; waited date; upper_bound date;
 zone text:=input_zone; n int; k text; selected int[]; weekday int; span int; cycle int; step int; elapsed int; base int; target int;
 year int; month int; parent text; from_completion boolean;
begin
 -- Floating tasks need the caller's explicit civil-day zone. Fixed-time tasks
 -- retain the native saved-zone rule; an invalid legacy zone falls back to input.
 if completed_at is null or not isfinite(completed_at) or input_zone is null or input_zone='' then raise exception 'A completion clock and time zone are required' using errcode='22023'; end if;
 perform completed_at at time zone input_zone;
 if coalesce(task->>'due_time','')<>'' and coalesce(task->>'time_zone','')<>'' then
  begin perform completed_at at time zone (task->>'time_zone'); zone:=task->>'time_zone';
  exception when invalid_parameter_value then zone:=input_zone; end;
 end if;
 if jsonb_typeof(task->'id') is distinct from 'string' or coalesce(task->>'id','')='' then return null; end if;
 if task->'is_recurring' is distinct from 'true'::jsonb or task->'completed'='true'::jsonb or not taskfold_private.automation_recurrence_valid(r) then return null; end if;
 origin:=taskfold_private.automation_civil_day(task->>'due_date');
 if origin is null or (r->>'count')::numeric=1 then return null; end if;
 if ((origin::timestamp at time zone zone) at time zone zone)::date<>origin then return null; end if;
 k:=r->>'type'; n:=coalesce((r->>'interval')::numeric::int,1); from_completion:=coalesce((r->>'fromCompletion')::boolean,false);
 if from_completion then origin:=(completed_at at time zone zone)::date; end if;
 if extract(year from origin) not between 1 and 9999 then return null; end if;
 threshold:=greatest(origin,(completed_at at time zone zone)::date);
 if from_completion then
  waited:=case when k in ('daily','custom') then taskfold_private.automation_calendar_add_days(origin,n,zone) when k='weekly' then taskfold_private.automation_calendar_add_days(origin,7*n,zone)
   when k='monthly' then (origin+make_interval(months=>n))::date else (origin+make_interval(years=>n))::date end;
  if extract(year from waited)>9999 then return null; end if;
  result:=waited;
  if k='weekly' and jsonb_array_length(coalesce(nullif(r->'daysOfWeek','null'::jsonb),'[]'))>0 then
   select min(mod(value::text::numeric::int-extract(dow from waited)::int+7,7)) into step from jsonb_array_elements(r->'daysOfWeek'); result:=taskfold_private.automation_calendar_add_days(waited,step,zone);
  elsif k='monthly' and (nullif(r->'dayOfMonth','null'::jsonb) is not null or nullif(r->'weekdayOrdinal','null'::jsonb) is not null or nullif(r->'daysOfMonth','null'::jsonb) is not null) then
   base:=(extract(year from waited)::int-1)*12+extract(month from waited)::int-1; result:=null;
   for step in 0..400 loop
    target:=base+step; if target>=9999*12 then return null; end if;
    select min(d) into result from taskfold_private.automation_month_dates(target/12+1,mod(target,12)+1,r,1) d where d>=waited;
    if result is not null then exit; end if;
   end loop;
  elsif k='yearly' and (nullif(r->'dayOfMonth','null'::jsonb) is not null or nullif(r->'monthOfYear','null'::jsonb) is not null) then
   year:=extract(year from waited); month:=coalesce((r->>'monthOfYear')::numeric::int,extract(month from waited)::int); result:=null;
   for step in 0..1 loop
    if year+step>9999 then return null; end if;
    select min(d) into result from taskfold_private.automation_month_dates(year+step,month,r-'weekday'-'weekdayOrdinal',extract(day from waited)::int) d where d>=waited;
    if result is not null then exit; end if;
   end loop;
  end if;
 elsif k in ('daily','custom') then result:=taskfold_private.automation_calendar_add_days(origin,(taskfold_private.automation_calendar_day_distance(origin,threshold,zone)/n+1)*n,zone);
 elsif k='weekly' then
  select array_agg(distinct value::text::numeric::int order by value::text::numeric::int) into selected from jsonb_array_elements(coalesce(nullif(r->'daysOfWeek','null'::jsonb),'[]'));
  span:=7*n;
  if coalesce(cardinality(selected),0)=0 then result:=taskfold_private.automation_calendar_add_days(origin,(taskfold_private.automation_calendar_day_distance(origin,threshold,zone)/span+1)*span,zone);
  else
   waited:=taskfold_private.automation_calendar_add_days(origin,-extract(dow from origin)::int,zone); cycle:=taskfold_private.automation_calendar_day_distance(waited,threshold,zone)/span;
   for step in cycle..cycle+1 loop
    foreach weekday in array selected loop result:=taskfold_private.automation_calendar_add_days(waited,step*span+weekday,zone); if result>threshold then exit; end if; result:=null; end loop;
    if result is not null then exit; end if;
   end loop;
  end if;
 elsif k='monthly' then
  elapsed:=(extract(year from threshold)::int-extract(year from origin)::int)*12+extract(month from threshold)::int-extract(month from origin)::int;
  cycle:=greatest(case when nullif(r->'daysOfMonth','null'::jsonb) is null then 1 else 0 end,elapsed/n); base:=(extract(year from origin)::int-1)*12+extract(month from origin)::int-1;
  for step in cycle..cycle+400 loop
   target:=base+step*n; if target>=9999*12 then return null; end if;
   select min(d) into result from taskfold_private.automation_month_dates(target/12+1,mod(target,12)+1,r,extract(day from origin)::int) d where d>threshold;
   if result is not null then exit; end if;
  end loop;
 elsif k='yearly' then
  cycle:=greatest(1,(extract(year from threshold)::int-extract(year from origin)::int)/n);
  for step in cycle..cycle+1 loop
   year:=extract(year from origin)::int+step*n; if year>9999 then return null; end if;
   select min(d) into result from taskfold_private.automation_month_dates(year,coalesce((r->>'monthOfYear')::numeric::int,extract(month from origin)::int),r-'weekday'-'weekdayOrdinal',extract(day from origin)::int) d where d>threshold;
   if result is not null then exit; end if;
  end loop;
 end if;
 if result is null or extract(year from result) not between 1 and 9999 then return null; end if;
 result:=((result::timestamp at time zone zone) at time zone zone)::date;
 if coalesce(nullif(r->>'endDate',''),task->>'recurrence_end_date','')<>'' then
  upper_bound:=taskfold_private.automation_civil_day(coalesce(nullif(r->>'endDate',''),task->>'recurrence_end_date'));
  if upper_bound is null or ((upper_bound::timestamp at time zone zone) at time zone zone)::date<>upper_bound or result>upper_bound then return null; end if;
 end if;
 -- Preserve the requested day across February, then decrement only the successor.
 if not from_completion then
  if k in ('monthly','yearly') and nullif(r->'dayOfMonth','null'::jsonb) is null and nullif(r->'weekdayOrdinal','null'::jsonb) is null and nullif(r->'daysOfMonth','null'::jsonb) is null then r:=r||jsonb_build_object('dayOfMonth',extract(day from origin)::int); end if;
  if k='yearly' and nullif(r->'monthOfYear','null'::jsonb) is null then r:=r||jsonb_build_object('monthOfYear',extract(month from origin)::int); end if;
 end if;
 if (r->>'count')::numeric>1 then r:=r||jsonb_build_object('count',(r->>'count')::numeric::int-1); end if;
 parent:=coalesce(nullif(task->>'recurrence_parent_id',''),task->>'id');
 return jsonb_build_object('due_date',to_char(result,'YYYY-MM-DD'),'id',taskfold_private.automation_successor_id(parent,to_char(result,'YYYY-MM-DD')),'recurrence_pattern',r);
end $$;

revoke all on function taskfold_private.automation_civil_day(text),
 taskfold_private.automation_recurrence_valid(jsonb),
 taskfold_private.automation_calendar_add_days(date,int,text),
 taskfold_private.automation_calendar_day_distance(date,date,text),
 taskfold_private.automation_month_dates(int,int,jsonb,int),
 taskfold_private.automation_successor_id(text,text),
 taskfold_private.automation_recurrence_plan(jsonb,timestamptz,text)
 from public,anon,authenticated,service_role;
