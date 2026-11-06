-- Extend existing calendar validation/projection without activating remote delivery.
create function taskfold_private.reminder_month_dates(_year int,_month int,r jsonb,_fallback int)
returns setof date language plpgsql immutable security invoker set search_path='' as $$
declare length int;begin
 if _year not between 1 and 9999 or _month not between 1 and 12 then return;end if;
 if nullif(r->'daysOfMonth','null'::jsonb) is null then
  return query select candidate_day from (select taskfold_private.reminder_month_day(_year,_month,r,_fallback) as candidate_day) as candidates where candidate_day is not null;
 else
  length:=extract(day from make_date(_year,_month,1)+interval '1 month'-interval '1 day');
  return query select distinct make_date(_year,_month,least(value::text::numeric::int,length)) from jsonb_array_elements(r->'daysOfMonth') order by 1;
 end if;
end $$;
revoke all on function taskfold_private.reminder_month_dates(int,int,jsonb,int) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_month_dates(int,int,jsonb,int) to service_role;

CREATE OR REPLACE FUNCTION taskfold_private.reminder_calendar_next(r jsonb, origin date, threshold date)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
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
  cycle:=greatest(case when nullif(r->'daysOfMonth','null'::jsonb) is null then 1 else 0 end,elapsed/n); base:=(extract(year from origin)::int-1)*12+extract(month from origin)::int-1;
  for step in cycle..cycle+400 loop
   target:=base+step*n; if target>=9999*12 then return null; end if;
   select min(candidate_day) into result from taskfold_private.reminder_month_dates(target/12+1,mod(target,12)+1,r,extract(day from origin)::int) as candidates(candidate_day) where candidate_day>threshold;
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
end $function$
;
CREATE OR REPLACE FUNCTION taskfold_private.reminder_spec_valid(s jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
 if nullif(r->'daysOfMonth','null'::jsonb) is not null then
  if k<>'monthly' or jsonb_typeof(r->'daysOfMonth')<>'array' or jsonb_array_length(r->'daysOfMonth') not between 1 and 31 then return false;end if;
  if exists(select 1 from unnest(array['dayOfMonth','weekdayOrdinal','weekday','monthOfYear']) key where nullif(r->key,'null'::jsonb) is not null) then return false;end if;
  days:='{}';
  for value in select * from jsonb_array_elements(r->'daysOfMonth') loop
   if jsonb_typeof(value)<>'number' then return false;end if;number:=value::text::numeric;
   if number<>trunc(number) or number not between 1 and 31 then return false;end if;
   if number::int=any(days) then return false;end if;days:=array_append(days,number::int);
  end loop;
 end if;
 if nullif(r->'dayOfMonth','null'::jsonb) is not null and k not in ('monthly','yearly') then return false; end if;
 if nullif(r->'monthOfYear','null'::jsonb) is not null and k<>'yearly' then return false; end if;
 if nullif(r->'weekdayOrdinal','null'::jsonb) is not null and (k<>'monthly' or nullif(r->'weekday','null'::jsonb) is null) then return false; end if;
 if nullif(r->'weekday','null'::jsonb) is not null and nullif(r->'weekdayOrdinal','null'::jsonb) is null then return false; end if;
 if k in ('monthly','yearly') and nullif(r->'dayOfMonth','null'::jsonb) is null and nullif(r->'weekdayOrdinal','null'::jsonb) is null and nullif(r->'daysOfMonth','null'::jsonb) is null then return false; end if;
 if k='yearly' and nullif(r->'monthOfYear','null'::jsonb) is null then return false; end if;
 if k='weekly' and coalesce(jsonb_array_length(nullif(r->'daysOfWeek','null'::jsonb)),0)>0
  and not exists(select 1 from jsonb_array_elements(r->'daysOfWeek') d where d::text::numeric::int=extract(dow from origin)::int) then return false; end if;
 if nullif(r->'daysOfMonth','null'::jsonb) is not null then
  if not exists(select 1 from taskfold_private.reminder_month_dates(extract(year from origin)::int,extract(month from origin)::int,r,extract(day from origin)::int) as candidates(candidate_day) where candidate_day=origin) then return false;end if;
 elsif k in ('monthly','yearly') then
  candidate:=taskfold_private.reminder_month_day(extract(year from origin)::int,case when k='yearly' then (r->>'monthOfYear')::numeric::int else extract(month from origin)::int end,r,extract(day from origin)::int);
  if candidate is distinct from origin then return false; end if;
 end if;
 -- An exact round trip proves the origin exists; ambiguous folds also exist.
 -- Gaps and skipped civil days still use the exact resolver before accepting a rule.
 return timezone(s->>'time_zone',(origin+(s->>'time')::time) at time zone (s->>'time_zone'))=origin+(s->>'time')::time
  or taskfold_private.reminder_calendar_wall_time(origin+(s->>'time')::time,s->>'time_zone') is not null;
exception when others then return false;
end $function$
;
CREATE OR REPLACE FUNCTION taskfold_private.reminder_events_window(t jsonb, device_zone text, _from timestamp with time zone, _until timestamp with time zone)
 RETURNS TABLE(spec_id uuid, fire_at timestamp with time zone, signature text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare specs jsonb:=coalesce(t->'reminder_specs','[]'); s jsonb; legacy jsonb:='[]'; seen uuid[]:='{}'; sid uuid; r jsonb; days text; numeric_fields text; fields text[]; preimage text; v text; instant timestamptz; cycle numeric; generation text;
begin
 if _from is null or _until is null or not isfinite(_from) or not isfinite(_until) or _until<_from or _until-_from>interval '8 days' or t->>'completed'='true' or jsonb_typeof(specs) is distinct from 'array' then return; end if;
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
  fields:=array['taskfold.reminder.v5',lower(t->>'id'),sid::text,s->>'start_day',s->>'time',s->>'time_zone',r->>'type',coalesce(nullif(r->'interval','null'::jsonb)::text::numeric::int,1)::text,days,numeric_fields,coalesce(r->>'endDate','')];
  if nullif(r->'daysOfMonth','null'::jsonb) is not null then
   select string_agg(value::text::numeric::int::text,',' order by value::text::numeric::int) into days from jsonb_array_elements(r->'daysOfMonth');
   fields:=fields||array['monthly-dates',days];
  end if;
  fields:=fields||array['local','1'];
  preimage:=''; foreach v in array fields loop preimage:=preimage||octet_length(v)::text||':'||v; end loop;
  for instant in select * from taskfold_private.reminder_calendar_dates_validated(s,_from-interval '1 microsecond',_until) loop
   fields:=array[round(extract(epoch from instant)*1000)::bigint::text,cycle::bigint::text,generation]; v:='';
   foreach days in array fields loop v:=v||octet_length(days)::text||':'||days; end loop;
   spec_id:=sid; fire_at:=instant; signature:='r5:'||encode(extensions.digest(preimage||v,'sha256'),'hex'); return next;
  end loop;
 end loop;
 if legacy<>'[]'::jsonb then return query select e.* from taskfold_private.reminder_events(t||jsonb_build_object('reminder_specs',legacy),device_zone) e where e.fire_at between _from and _until; end if;
end $function$

;
