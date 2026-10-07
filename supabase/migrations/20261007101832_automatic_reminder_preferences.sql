-- Add a timed-task default to the existing account preference document. Missing
-- offsets retain legacy at-planned-time behavior; -1 disables the timed default.
create or replace function taskfold_private.valid_reminder_preferences(value jsonb)
returns boolean language plpgsql immutable security invoker set search_path='' as $$
declare version numeric; minutes numeric;
begin
 if jsonb_typeof(value) is distinct from 'object' or octet_length(value::text)>8192
  or jsonb_typeof(value->'version') is distinct from 'number' then return false; end if;
 version:=(value->>'version')::numeric;
 if version<>trunc(version) or version not between 1 and 1000 then return false; end if;
 if version<>1 then return true; end if;
 if jsonb_typeof(value->'snooze_minutes') is distinct from 'number' then return false; end if;
 minutes:=(value->>'snooze_minutes')::numeric;
 if minutes<>trunc(minutes) or minutes not between 1 and 1440 then return false; end if;
 if value ? 'automatic_before_minutes' then
  if jsonb_typeof(value->'automatic_before_minutes') is distinct from 'number' then return false; end if;
  minutes:=(value->>'automatic_before_minutes')::numeric;
  if minutes<>trunc(minutes) or minutes not between -1 and 10080 then return false; end if;
 end if;
 return true;
exception when others then return false;
end $$;
revoke all on function taskfold_private.valid_reminder_preferences(jsonb) from public,anon;
grant execute on function taskfold_private.valid_reminder_preferences(jsonb) to authenticated,service_role;

-- Row locking serializes this choice with the existing snooze RPC. Neither
-- semantic command can replace the other choice or downgrade future settings.
create function public.taskfold_set_automatic_reminder(_minutes integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare owner uuid:=auth.uid(); saved public.reminder_preferences;
begin
 if owner is null then raise exception 'Sign in before changing reminder preferences.'; end if;
 if _minutes is null or _minutes not between -1 and 10080 then raise exception 'Choose no automatic reminder or an offset from 0 to 10080 minutes.'; end if;
 insert into public.reminder_preferences(user_id,id) values(owner,'current') on conflict(user_id,id) do nothing;
 select * into saved from public.reminder_preferences where user_id=owner and id='current' for update;
 if (saved.settings->>'version')::numeric<>1 then raise exception 'This reminder preference needs a newer app.'; end if;
 update public.reminder_preferences set settings=jsonb_set(settings,'{automatic_before_minutes}',to_jsonb(_minutes),true)
  where user_id=owner and id='current' returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.taskfold_set_automatic_reminder(integer) from public,anon;
grant execute on function public.taskfold_set_automatic_reminder(integer) to authenticated,service_role;
