-- NULL boundaries are not finite bounded windows; reject them before calendar iteration.
create or replace function taskfold_private.reminder_calendar_dates_validated(s jsonb,_after timestamptz,_until timestamptz)
returns setof timestamptz language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=s->'recurrence'; origin date; day date; threshold date; at timestamptz; emitted int:=0; consumed int:=0; count_limit int; zone text:=s->>'time_zone'; clock time;
begin
 if _after is null or _until is null or not isfinite(_after) or not isfinite(_until) or _until<=_after or s->'version'<>'2'::jsonb then return; end if;
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
 if _after is null or _until is null or not taskfold_private.reminder_spec_valid(s) or s->'version'<>'2'::jsonb then return; end if;
 return query select * from taskfold_private.reminder_calendar_dates_validated(s,_after,_until);
end $$;
create or replace function taskfold_private.reminder_events_window(t jsonb,device_zone text,_from timestamptz,_until timestamptz)
returns table(spec_id uuid,fire_at timestamptz,signature text) language plpgsql stable security invoker set search_path='' as $$
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

