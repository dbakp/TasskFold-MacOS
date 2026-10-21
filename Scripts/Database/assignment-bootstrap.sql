-- Local minimal dependency schema, NOT a replacement for hosted-policy acceptance.
create role anon; create role authenticated; create role service_role; create schema auth; create schema taskfold_private;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth,public to authenticated;
create table public.projects(id uuid primary key,user_id uuid references auth.users(id) on delete cascade,name text);
create table public.project_collaborators(id uuid primary key,project_id uuid references public.projects(id) on delete cascade,user_id uuid references auth.users(id) on delete set null,invited_email text,invited_by uuid,status text default 'pending');
create function taskfold_private.fixture_link_invitation() returns trigger language plpgsql security definer as $$begin select id into new.user_id from auth.users where email=new.invited_email; return new; end$$;
create trigger link_invite before insert on public.project_collaborators for each row execute function taskfold_private.fixture_link_invitation();
create table public.tasks(id uuid primary key,user_id uuid references auth.users(id),title text,completed boolean default false,project_id uuid references public.projects(id),assigned_to uuid references auth.users(id) on delete set null,subtasks jsonb default '[]',task_generation uuid default gen_random_uuid(),recurrence_parent_id uuid,source_metadata jsonb);
alter table public.tasks enable row level security;
create policy fixture_task_access on public.tasks to authenticated using((project_id is null and user_id=auth.uid()) or project_id in (select id from public.projects where user_id=auth.uid() union select project_id from public.project_collaborators where user_id=auth.uid() and status='accepted')) with check((project_id is null and user_id=auth.uid()) or project_id in (select id from public.projects where user_id=auth.uid() union select project_id from public.project_collaborators where user_id=auth.uid() and status='accepted'));
grant select,insert,update,delete on public.tasks,public.projects,public.project_collaborators to authenticated;
