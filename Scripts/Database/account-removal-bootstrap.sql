-- Minimal owned local schema. Hosted RLS/HTTP/native acceptance is separate.
create role anon; create role authenticated; create role service_role;
create schema auth; create schema storage; create schema taskfold_private;
create table auth.users(id uuid primary key,email text,banned_until timestamptz);
create table auth.sessions(id uuid primary key,user_id uuid references auth.users on delete cascade,not_after timestamptz);
create table public.profiles(user_id uuid primary key references auth.users on delete cascade);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table public.projects(id uuid primary key,user_id uuid references auth.users on delete cascade,name text);
create function public.is_project_owner(_owner uuid,_project uuid) returns boolean language sql stable as $$select exists(select 1 from public.projects where id=_project and user_id=_owner)$$;
create table public.project_collaborators(id uuid primary key,project_id uuid references public.projects on delete cascade,user_id uuid references auth.users on delete cascade,
 invited_email text,invited_by uuid not null,role text default 'collaborator',status text default 'pending',accepted_at timestamptz,
 constraint project_collaborators_invited_by_fkey foreign key(invited_by) references auth.users,
 constraint project_collaborators_invited_by_profile_fkey foreign key(invited_by) references public.profiles(user_id) on delete cascade);
create table public.tasks(id uuid primary key,user_id uuid references auth.users on delete cascade,project_id uuid references public.projects on delete set null,
 recurrence_parent_id uuid references public.tasks on delete cascade,title text);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid,owner_id text);
create table taskfold_private.reminder_devices(id uuid primary key,user_id uuid references auth.users on delete set null);

create function taskfold_private.prepare_invitation() returns trigger language plpgsql as $$begin return new;end$$;
create trigger taskfold_prepare_invitation before insert or update on public.project_collaborators for each row execute function taskfold_private.prepare_invitation();

-- Minimal ordinary prefix access, so restrictive removal policy is exercised
-- together with an existing permissive policy rather than in isolation.
grant usage on schema auth,storage to authenticated;
grant select,insert,update on storage.objects to authenticated;
alter table storage.objects enable row level security;
create policy fixture_prefix on storage.objects to authenticated
 using(starts_with(name,(select auth.uid())::text||'/'))
 with check(starts_with(name,(select auth.uid())::text||'/'));
