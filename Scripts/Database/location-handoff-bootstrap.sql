-- Minimal local policy fixture; hosted policy/transport acceptance remains separate.
create role anon; create role authenticated; create role service_role;
create schema auth; create schema taskfold_private; create schema cron;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth,public,taskfold_private to authenticated;
create table public.projects(id uuid primary key,user_id uuid references auth.users(id) on delete cascade,name text);
create table public.project_collaborators(id uuid primary key,project_id uuid references public.projects(id) on delete cascade,user_id uuid references auth.users(id),invited_email text,invited_by uuid,role text default 'collaborator',status text default 'pending');
create function taskfold_private.fixture_handoff_link_invite() returns trigger language plpgsql security definer set search_path='' as $$begin if new.user_id is null then select id into new.user_id from auth.users where email=new.invited_email; end if; return new; end$$;
create trigger link_invite before insert on public.project_collaborators for each row execute function taskfold_private.fixture_handoff_link_invite();
create table public.tasks(id uuid primary key,user_id uuid references auth.users(id),project_id uuid references public.projects(id),title text,completed boolean default false,task_generation uuid default gen_random_uuid(),completion_version bigint default 0);
create function public.has_project_access(_owner uuid,_project uuid) returns boolean language sql stable as $$select exists(select 1 from public.projects p where p.id=_project and p.user_id=_owner) or exists(select 1 from public.project_collaborators c where c.project_id=_project and c.user_id=_owner and c.status='accepted')$$;
alter table public.tasks enable row level security;
create policy fixture_handoff_task_read on public.tasks for select to authenticated using((project_id is null and user_id=(select auth.uid())) or public.has_project_access((select auth.uid()),project_id));
grant select on public.tasks,public.projects,public.project_collaborators to authenticated;
create table cron.job(jobid bigint generated always as identity primary key,jobname text unique,schedule text,command text);
create function cron.schedule(_name text,_schedule text,_command text) returns bigint language sql as $$insert into cron.job(jobname,schedule,command) values(_name,_schedule,_command) returning jobid$$;
