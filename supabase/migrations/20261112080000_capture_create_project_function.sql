-- Capture a hosted-only function in version control (12 November 2026).
--
-- public.create_project(text,text) exists on the hosted project (created
-- outside the migration history) but no migration defines it, so a clean
-- replay lacked it. This restores the live definition verbatim and its live
-- privileges (authenticated and service_role only). Re-running it on hosted is
-- a no-op.
create or replace function public.create_project(_name text, _color text default null::text)
 returns public.projects
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  p public.projects;
begin
  -- Require a real authenticated user
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  insert into public.projects (name, color, user_id)
  values (_name, _color, auth.uid())
  returning * into p;

  return p;
end;
$function$;
revoke all on function public.create_project(text,text) from public,anon;
grant execute on function public.create_project(text,text) to authenticated,service_role;
