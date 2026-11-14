-- Local minimal dependency schema, NOT a replacement for hosted-policy acceptance.
-- Mirrors only what 20261114120000_task_dependencies_lite.sql reads: auth identity, projects,
-- accepted collaborators, tasks with their legacy access policy, has_project_access and Realtime.
create role anon; create role authenticated; create role service_role; create schema auth; create schema taskfold_private;
create publication supabase_realtime;
create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth,public to authenticated;
create table public.projects(id uuid primary key,user_id uuid references auth.users(id) on delete cascade,name text);
create table public.project_collaborators(id uuid primary key,project_id uuid references public.projects(id) on delete cascade,user_id uuid references auth.users(id) on delete cascade,status text default 'pending');
create table public.tasks(id uuid primary key,user_id uuid references auth.users(id),title text,completed boolean default false,project_id uuid references public.projects(id));
-- Same shape as the hosted helper after the team-content migrations: legacy sharing only.
create function taskfold_private.legacy_project_access(a uuid,p uuid,owner_only boolean) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.projects where id=p and user_id=a) or
  (not owner_only and exists(select 1 from public.project_collaborators where project_id=p and user_id=a and status='accepted'))
$$;
create function public.has_project_access(_user_id uuid,_project_id uuid) returns boolean
language sql stable security invoker set search_path='' as $$select taskfold_private.legacy_project_access(_user_id,_project_id,false)$$;
revoke all on function taskfold_private.legacy_project_access(uuid,uuid,boolean),public.has_project_access(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.legacy_project_access(uuid,uuid,boolean),public.has_project_access(uuid,uuid) to authenticated,service_role;
alter table public.tasks enable row level security;
create policy "Users can view accessible tasks" on public.tasks for select to authenticated
 using ((project_id is null and user_id=(select auth.uid())) or public.has_project_access((select auth.uid()),project_id));
grant select,insert,update,delete on public.tasks,public.projects,public.project_collaborators to authenticated;
