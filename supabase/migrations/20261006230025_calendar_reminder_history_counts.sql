-- Bound historical finite-count work without changing first folds, gaps or skipped-day counts.
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

