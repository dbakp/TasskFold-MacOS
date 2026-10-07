-- Account preferences are separate from device-local notification permissions.
-- Older clients can continue reading their existing tables without new columns.
create function taskfold_private.valid_reminder_preferences(value jsonb)
returns boolean language plpgsql immutable security invoker set search_path='' as $$
declare version numeric; minutes numeric;
begin
 if jsonb_typeof(value) is distinct from 'object' or octet_length(value::text)>8192
  or jsonb_typeof(value->'version') is distinct from 'number' then return false; end if;
 version:=(value->>'version')::numeric;
 if version<>trunc(version) or version not between 1 and 1000 then return false; end if;
 -- Future documents remain opaque; supported readers must not rewrite them.
 if version<>1 then return true; end if;
 if jsonb_typeof(value->'snooze_minutes') is distinct from 'number' then return false; end if;
 minutes:=(value->>'snooze_minutes')::numeric;
 return minutes=trunc(minutes) and minutes between 1 and 1440;
exception when others then return false;
end $$;
revoke all on function taskfold_private.valid_reminder_preferences(jsonb) from public,anon;
grant execute on function taskfold_private.valid_reminder_preferences(jsonb) to authenticated,service_role;
create table public.reminder_preferences (
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 id text not null default 'current' check(id='current'),
 settings jsonb not null default '{"version":1,"snooze_minutes":60}'::jsonb check(taskfold_private.valid_reminder_preferences(settings)),
 updated_at timestamptz not null default now(),
 primary key(user_id,id)
);
alter table public.reminder_preferences enable row level security;
create policy account_owner on public.reminder_preferences for all to authenticated
 using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
create policy reminder_preferences_anon_deny on public.reminder_preferences for all to anon using(false) with check(false);
revoke all on public.reminder_preferences from public,anon,authenticated;
grant select,insert,update,delete on public.reminder_preferences to authenticated;
grant all on public.reminder_preferences to service_role;
create trigger reminder_preferences_touch before update on public.reminder_preferences
 for each row execute function taskfold_private.touch_organization();
alter publication supabase_realtime add table public.reminder_preferences;

-- An offline delay choice edits only its semantic field under a row lock. Other
-- devices' newer extension metadata survives; older writes cannot downgrade future frames.
create function public.taskfold_set_reminder_snooze(_minutes integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare owner uuid:=auth.uid(); saved public.reminder_preferences;
begin
 if owner is null then raise exception 'Sign in before changing reminder preferences.'; end if;
 if _minutes is null or _minutes not between 1 and 1440 then raise exception 'Choose a snooze delay from 1 to 1440 minutes.'; end if;
 insert into public.reminder_preferences(user_id,id) values(owner,'current') on conflict(user_id,id) do nothing;
 select * into saved from public.reminder_preferences where user_id=owner and id='current' for update;
 if (saved.settings->>'version')::numeric<>1 then raise exception 'This reminder preference needs a newer app.'; end if;
 update public.reminder_preferences set settings=jsonb_set(settings,'{snooze_minutes}',to_jsonb(_minutes),true)
  where user_id=owner and id='current' returning * into saved;
 return to_jsonb(saved);
end $$;
revoke all on function public.taskfold_set_reminder_snooze(integer) from public,anon;
grant execute on function public.taskfold_set_reminder_snooze(integer) to authenticated,service_role;
