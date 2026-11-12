-- Only project members can resolve another member's public display identity.
create or replace function taskfold_private.project_member_profiles(_project_id uuid)
returns table(user_id uuid, display_name text, avatar_url text)
language sql stable security definer set search_path = ''
as $$
  with members as (
    select p.user_id from public.projects p
    where p.id = _project_id
      and auth.uid() is not null
      and public.has_project_access(auth.uid(), _project_id)
    union
    select c.user_id from public.project_collaborators c
    where c.project_id = _project_id and c.status = 'accepted' and c.user_id is not null
      and auth.uid() is not null
      and public.has_project_access(auth.uid(), _project_id)
  )
  select m.user_id,
    coalesce(nullif(btrim(pr.display_name), ''),
             nullif(btrim(g.identity_data->>'full_name'), ''),
             nullif(btrim(g.identity_data->>'name'), ''),
             nullif(btrim(u.raw_user_meta_data->>'full_name'), ''),
             nullif(btrim(u.raw_user_meta_data->>'name'), ''), 'Project member'),
    coalesce(nullif(btrim(pr.avatar_url), ''),
             nullif(g.identity_data->>'avatar_url', ''),
             nullif(g.identity_data->>'picture', ''),
             case when u.raw_app_meta_data->>'provider' = 'google'
                         or u.raw_app_meta_data->'providers' ? 'google'
               then coalesce(nullif(u.raw_user_meta_data->>'avatar_url', ''),
                             nullif(u.raw_user_meta_data->>'picture', '')) end)
  from members m
  left join public.profiles pr on pr.user_id = m.user_id
  left join auth.users u on u.id = m.user_id
  left join lateral (
    select i.identity_data from auth.identities i
    where i.user_id = m.user_id and i.provider = 'google'
    order by i.created_at limit 1
  ) g on true
$$;
revoke all on function taskfold_private.project_member_profiles(uuid) from public, anon;
grant usage on schema taskfold_private to authenticated;
grant execute on function taskfold_private.project_member_profiles(uuid) to authenticated;

-- Preserve the existing API signature; privileged lookup stays in the private schema.
create or replace function public.taskfold_project_members(_project_id uuid)
returns table(user_id uuid, display_name text, avatar_url text)
language sql stable security invoker set search_path = ''
as $$ select * from taskfold_private.project_member_profiles(_project_id) $$;
revoke all on function public.taskfold_project_members(uuid) from public, anon;
grant execute on function public.taskfold_project_members(uuid) to authenticated;
