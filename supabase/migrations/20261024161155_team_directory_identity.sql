-- Enrich only the existing owner/admin directory, after the original service
-- has verified the session and locked the team. No global account lookup API,
-- metadata-based authority, avatar fetch or task/project access is introduced.
create function taskfold_private.team_present(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare result jsonb; directory jsonb;
begin
 result=taskfold_private.team_manage(action,b);
 if action<>'get' or result->>'role' not in('owner','admin') then return result;end if;
 -- team_manage holds the team row lock for this transaction. Membership/role
 -- changes use that same lock. Enrich only the exact authorized result rows.
 select coalesce(jsonb_agg(z.row||jsonb_build_object(
  'display_name',case when u.id is not null and char_length(btrim(p.display_name)) between 1 and 100
    and octet_length(btrim(p.display_name))<=400 and p.display_name !~ '[[:cntrl:]]'
    and p.display_name !~ U&'[\202A-\202E\2066-\2069]' then btrim(p.display_name) end,
  'verified_email',case when u.email_confirmed_at is not null and char_length(btrim(u.email)) between 3 and 254
    and btrim(u.email) ~ '^[^@]+@[^@]+$' and u.email !~ '[[:space:][:cntrl:]]'
    and u.email !~ U&'[\202A-\202E\2066-\2069]' then lower(btrim(u.email)) end
 ) order by z.position),'[]') into directory
 from jsonb_array_elements(result->'members') with ordinality z(row,position)
 left join auth.users u on u.id=(z.row->>'user_id')::uuid
  and (u.banned_until is null or u.banned_until<=clock_timestamp())
  and not exists(select 1 from taskfold_private.account_removal_receipts ar where ar.account_id=u.id and ar.created_at>clock_timestamp()-interval '7 days')
 left join public.profiles p on p.user_id=u.id;
 return jsonb_set(result,'{members}',directory);
end$$;
revoke all on function taskfold_private.team_present(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_present(text,jsonb) to authenticated;

-- Keep the public entry point invoker-only and its existing argument signature.
create or replace function public.taskfold_teams(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_present(_action,_body)$$;
revoke all on function public.taskfold_teams(text,jsonb) from public,anon,service_role;
grant execute on function public.taskfold_teams(text,jsonb) to authenticated;
