-- Nullable additive column: legacy clients and existing task dates remain unchanged.
create function taskfold_private.valid_date_preferences(value jsonb)
returns boolean language plpgsql immutable security invoker set search_path = '' as $$
declare field text; day numeric;
begin
 if value is null or value = 'null'::jsonb then return true; end if;
 if jsonb_typeof(value) is distinct from 'object' or octet_length(value::text) > 4096
  or value->'version' is distinct from '1'::jsonb then return false; end if;
 foreach field in array array['next_week','weekend'] loop
  if jsonb_typeof(value->field) is distinct from 'number' then return false; end if;
  day := (value->>field)::numeric;
  if day <> trunc(day) or day not between 1 and 7 then return false; end if;
 end loop;
 return true;
end $$;
revoke all on function taskfold_private.valid_date_preferences(jsonb) from public, anon;
grant execute on function taskfold_private.valid_date_preferences(jsonb) to authenticated;
alter table public.view_preferences add column date_preferences jsonb;
alter table public.view_preferences add constraint valid_date_preferences check(taskfold_private.valid_date_preferences(date_preferences));
comment on column public.view_preferences.date_preferences is 'Account-owned relative date meanings on id=dates; Gregorian Sunday=1 through Saturday=7. Concrete task dates do not change.';
