-- One atomic, account-owned document avoids invalid intermediate start/end settings.
create function taskfold_private.valid_working_hours(value jsonb)
returns boolean language plpgsql immutable security invoker set search_path = '' as $$
declare start_min numeric; end_min numeric; item jsonb;
begin
 if value is null then return true; end if;
 if jsonb_typeof(value) is distinct from 'object' or octet_length(value::text)>1024
  or value->'version' is distinct from '1'::jsonb
  or jsonb_typeof(value->'start') is distinct from 'number'
  or jsonb_typeof(value->'end') is distinct from 'number'
  or jsonb_typeof(value->'days') is distinct from 'array' then return false; end if;
 start_min := (value->>'start')::numeric; end_min := (value->>'end')::numeric;
 if start_min<>trunc(start_min) or end_min<>trunc(end_min) or start_min<0 or end_min>1440 or start_min>=end_min or jsonb_array_length(value->'days')>7 then return false; end if;
 for item in select jsonb_array_elements(value->'days') loop
  if jsonb_typeof(item) is distinct from 'number' then return false; end if;
  if (item::text)::numeric<>trunc((item::text)::numeric) or (item::text)::numeric not between 1 and 7 then return false; end if;
 end loop;
 return true;
end $$;
revoke all on function taskfold_private.valid_working_hours(jsonb) from public, anon;
grant execute on function taskfold_private.valid_working_hours(jsonb) to authenticated;
alter table public.view_preferences add column working_hours jsonb;
alter table public.view_preferences add constraint valid_working_hours check(taskfold_private.valid_working_hours(working_hours));
