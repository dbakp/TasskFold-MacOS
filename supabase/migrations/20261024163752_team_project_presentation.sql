-- Presentation is derived only after the existing session/role-checked command.
-- No new project/task write capability or rollout flag is enabled.
create function taskfold_private.team_project_present(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare result jsonb; rows jsonb;
begin
 result=taskfold_private.team_project_command(action,b);
 if action='list' then
  select coalesce(jsonb_agg(z.row||jsonb_build_object('name',case when char_length(p.name) between 1 and 100 and octet_length(p.name)<=400 and p.name !~ '[[:cntrl:]]' then p.name end) order by z.position),'[]') into rows
   from jsonb_array_elements(result->'projects') with ordinality z(row,position) join public.projects p on p.id=(z.row->>'id')::uuid;
  return jsonb_set(result,'{projects}',rows);
 elsif action='get' then
  result=result||jsonb_build_object('name',(select case when char_length(p.name) between 1 and 100 and octet_length(p.name)<=400 and p.name !~ '[[:cntrl:]]' then p.name end from public.projects p where p.id=(result->>'id')::uuid));
  if result->>'role'='manager' then
   -- Project managers need accepted recipients, not global account search. Names
   -- are presentation only. Email remains restricted to the team admin directory.
   select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',case when m.user_id=t.owner_id then 'owner' else m.role end,
    'display_name',case when char_length(btrim(p.display_name)) between 1 and 100 and octet_length(btrim(p.display_name))<=400 and p.display_name !~ '[[:cntrl:]]' then btrim(p.display_name) end) order by m.user_id),'[]') into rows
    from taskfold_private.team_members m join taskfold_private.teams t on t.id=m.team_id
    join auth.users u on u.id=m.user_id and u.email_confirmed_at is not null and coalesce(u.email,'')<>'' and (u.banned_until is null or u.banned_until<=clock_timestamp())
    left join public.profiles p on p.user_id=m.user_id
    where m.team_id=(result->>'team_id')::uuid and not exists(select 1 from taskfold_private.account_removal_receipts r where r.account_id=m.user_id and r.created_at>clock_timestamp()-interval '7 days');
   result=result||jsonb_build_object('eligible_members',rows);
  end if;
 end if;
 return result;
end$$;
revoke all on function taskfold_private.team_project_present(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_project_present(text,jsonb) to authenticated;
create or replace function public.taskfold_team_projects(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_project_present(_action,_body)$$;
revoke all on function public.taskfold_team_projects(text,jsonb) from public,anon,service_role;
grant execute on function public.taskfold_team_projects(text,jsonb) to authenticated;
