-- Nullable goal preferences; existing task dates, history and settings are unchanged.
create function taskfold_private.valid_productivity_goals(value jsonb)
returns boolean language plpgsql stable security invoker set search_path='' as $$
declare field text; amount numeric; day jsonb; seen int[] := '{}';
begin
 if value is null or value='null'::jsonb then return true;end if;
 if jsonb_typeof(value) is distinct from 'object' or octet_length(value::text)>4096 or value->'version' is distinct from '1'::jsonb then return false;end if;
 foreach field in array array['daily_target','weekly_target','week_start'] loop
  if jsonb_typeof(value->field) is distinct from 'number' then return false;end if;
  amount=(value->>field)::numeric;
  if amount<>trunc(amount) or amount<(case when field='week_start' then 1 else 0 end) or amount>(case when field='week_start' then 7 else 10000 end) then return false;end if;
 end loop;
 if jsonb_typeof(value->'active_weekdays') is distinct from 'array' or jsonb_array_length(value->'active_weekdays')>7 then return false;end if;
 for day in select * from jsonb_array_elements(value->'active_weekdays') loop
  if jsonb_typeof(day) is distinct from 'number' then return false;end if;
  amount=(day#>>'{}')::numeric;
  if amount<>trunc(amount) or amount not between 1 and 7 or amount::int=any(seen) then return false;end if;
  seen=array_append(seen,amount::int);
 end loop;
 if (value->>'daily_target')::numeric>0 and cardinality(seen)=0 then return false;end if;
 if jsonb_typeof(value->'time_zone') is distinct from 'string' or length(value->>'time_zone')>128 then return false;end if;
 return exists(select 1 from pg_catalog.pg_timezone_names where name=value->>'time_zone');
end $$;
revoke all on function taskfold_private.valid_productivity_goals(jsonb) from public,anon;
grant execute on function taskfold_private.valid_productivity_goals(jsonb) to authenticated;
alter table public.view_preferences add column productivity_goals jsonb;
alter table public.view_preferences add constraint valid_productivity_goals check(taskfold_private.valid_productivity_goals(productivity_goals));
alter table public.view_preferences add constraint productivity_goals_scope check(productivity_goals is null or productivity_goals='null'::jsonb or id='insights');
comment on column public.view_preferences.productivity_goals is 'Account-owned optional daily/weekly completion goals, active weekdays and fixed civil zone on id=insights. Recorded history is not backfilled.';

create function public.taskfold_set_productivity_goals(_base jsonb,_goals jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare caller uuid := auth.uid(); item public.view_preferences; current_goals jsonb;
begin
 if caller is null then raise exception 'Not authorized' using errcode='42501';end if;
 if not taskfold_private.valid_productivity_goals(_goals) then raise exception 'Choose supported productivity goals, weekdays and time zone';end if;
 -- The account primary key serializes simultaneous first saves as well as later edits.
 insert into public.view_preferences(user_id,id) values(caller,'insights') on conflict(user_id,id) do nothing;
 select * into strict item from public.view_preferences where user_id=caller and id='insights' for update;
 current_goals=coalesce(item.productivity_goals,'null'::jsonb);
 if current_goals is distinct from coalesce(_base,'null'::jsonb) and current_goals is distinct from coalesce(_goals,'null'::jsonb) then
  raise exception 'TASKFOLD_CONFLICT: Goals changed on another device. Review both choices before saving.' using errcode='P0001';
 end if;
 update public.view_preferences set productivity_goals=nullif(_goals,'null'::jsonb) where user_id=caller and id='insights' returning * into item;
 return to_jsonb(item);
end $$;
revoke all on function public.taskfold_set_productivity_goals(jsonb,jsonb) from public,anon;
grant execute on function public.taskfold_set_productivity_goals(jsonb,jsonb) to authenticated;
