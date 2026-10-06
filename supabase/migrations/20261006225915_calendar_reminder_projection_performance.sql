-- Validate the zone once per supported schedule; repeated historical dates use cached zone conversion.
create function taskfold_private.reminder_calendar_wall_time(local_time timestamp without time zone, zone text)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare offsets interval[]; result timestamptz; requested timestamp; shift int;
begin
 -- The spec validator already requires a named zone; avoid catalog enumeration per occurrence.
 begin perform timezone(zone,local_time); exception when invalid_parameter_value then return null; end;
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
end $function$;


create or replace function taskfold_private.reminder_calendar_dates(s jsonb,_after timestamptz,_until timestamptz)
returns setof timestamptz language plpgsql stable security invoker set search_path='' as $$
declare r jsonb:=s->'recurrence'; origin date; day date; threshold date; at timestamptz; emitted int:=0; consumed int:=0; count_limit int; zone text:=s->>'time_zone'; clock time;
begin
 if not isfinite(_after) or not isfinite(_until) or _until<=_after or not taskfold_private.reminder_spec_valid(s) or s->'version'<>'2'::jsonb then return; end if;
 origin:=(s->>'start_day')::date; clock:=(s->>'time')::time; count_limit:=nullif(r->'count','null'::jsonb)::text::numeric::int; day:=origin;
 if count_limit is null then
  at:=taskfold_private.reminder_calendar_wall_time(day+clock,zone);
  if at>_after and at<=_until then return next at; emitted:=1; end if;
  threshold:=greatest(origin,timezone(zone,_after)::date-1);
  day:=taskfold_private.reminder_calendar_next(r,origin,threshold);
 end if;
 while day is not null and emitted<60 loop
  at:=taskfold_private.reminder_calendar_wall_time(day+clock,zone);
  if at>_until then exit; end if;
  if at is not null then
   consumed:=consumed+1;
   if at>_after then return next at; emitted:=emitted+1; end if;
  end if;
  if count_limit is not null and consumed>=count_limit then exit; end if;
  day:=taskfold_private.reminder_calendar_next(r,origin,day);
 end loop;
end $$;

revoke all on function taskfold_private.reminder_calendar_wall_time(timestamp,text) from public,anon,authenticated;
grant execute on function taskfold_private.reminder_calendar_wall_time(timestamp,text) to service_role;
