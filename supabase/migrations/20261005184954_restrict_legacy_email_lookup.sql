-- Legacy email lookup RPCs previously bypassed RLS without checking the caller.
-- Keep the web invitation display contract, restricted to explicit relationships.
create or replace function public.get_user_email_by_id(_user_id uuid)
returns text language sql stable security definer set search_path = '' as $$
 select u.email from auth.users u where u.id=_user_id and auth.uid() is not null and (
  u.id=auth.uid()
  or exists(select 1 from public.project_collaborators pc where pc.user_id=auth.uid() and pc.invited_by=u.id and pc.status in ('pending','accepted'))
  or exists(select 1 from public.projects p join public.project_collaborators pc on pc.project_id=p.id where p.user_id=auth.uid() and pc.user_id=u.id and pc.status='accepted')
 ) limit 1
$$;
revoke all on function public.get_user_email_by_id(uuid) from public, anon;
grant execute on function public.get_user_email_by_id(uuid) to authenticated;
-- The clients no longer use account-existence lookup. Server-side invitations resolve
-- recipients internally and ordinary clients cannot enumerate email addresses.
revoke all on function public.get_user_id_by_email(text) from public, anon, authenticated;
grant execute on function public.get_user_id_by_email(text) to service_role;
