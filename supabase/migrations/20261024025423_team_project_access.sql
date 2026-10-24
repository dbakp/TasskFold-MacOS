-- Native team project reads and reviewed access management. Undeployed; off by
-- default. Native/direct/service task, section, comment and file writes stay shut.
create table taskfold_private.team_project_config (
 singleton boolean primary key default true check(singleton),
 native_reads_enabled boolean not null default false
);
insert into taskfold_private.team_project_config default values;
alter table taskfold_private.team_project_config enable row level security;
revoke all on taskfold_private.team_project_config from public,anon,authenticated,service_role;

alter table taskfold_private.team_content_projects
 add column visibility text not null default 'team' check(visibility in('team','private')),
 add column revision bigint not null default 1 check(revision between 1 and 9007199254740991),
 add column folder_id uuid references taskfold_private.team_folders(id) on delete set null,
 add constraint team_content_projects_identity unique(project_id,team_id);
create index team_content_projects_folder on taskfold_private.team_content_projects(folder_id) where folder_id is not null;
create table taskfold_private.team_project_grants (
 project_id uuid not null,
 team_id uuid not null,
 user_id uuid not null,
 role text not null check(role in('manager','editor','viewer')),
 primary key(project_id,user_id),
 foreign key(project_id,team_id) references taskfold_private.team_content_projects(project_id,team_id) on delete cascade,
 foreign key(team_id,user_id) references taskfold_private.team_members(team_id,user_id) on delete cascade
);
create index team_project_grants_member on taskfold_private.team_project_grants(team_id,user_id,project_id);
create table taskfold_private.team_project_identities (
 project_id uuid primary key,
 team_id uuid not null references taskfold_private.teams(id) on delete restrict
);
create index team_project_identities_team on taskfold_private.team_project_identities(team_id);
insert into taskfold_private.team_project_identities select project_id,team_id from taskfold_private.team_content_projects;
create table taskfold_private.team_project_commands (
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 request_id uuid not null,
 actor_id uuid not null references auth.users(id) on delete cascade,
 fingerprint text not null,
 result jsonb not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,request_id)
);
create index team_project_commands_actor on taskfold_private.team_project_commands(actor_id);
create index team_project_commands_expiry on taskfold_private.team_project_commands(team_id,created_at);
alter table taskfold_private.team_project_grants enable row level security;
alter table taskfold_private.team_project_identities enable row level security;
alter table taskfold_private.team_project_commands enable row level security;
revoke all on taskfold_private.team_project_grants,taskfold_private.team_project_identities,taskfold_private.team_project_commands from public,anon,authenticated,service_role;

-- Membership/grant truth does not depend on editable JWT metadata or a creator
-- shortcut. Admins explicitly manage private projects too; guests require grants.
create function taskfold_private.team_project_role(a uuid,p uuid) returns text
language sql stable security invoker set search_path='' as $$
 select case when t.owner_id=a or m.role='admin' then 'manager'
  when g.role='manager' and m.role='guest' then null
  when g.role is not null then g.role
  when b.visibility='team' and m.role='member' then 'editor' end
 from taskfold_private.team_content_projects b
 join taskfold_private.teams t on t.id=b.team_id and t.state<>'deleted'
 join taskfold_private.team_members m on m.team_id=t.id and m.user_id=a
 join auth.users u on u.id=a and u.email_confirmed_at is not null and coalesce(u.email,'')<>'' and (u.banned_until is null or u.banned_until<=statement_timestamp())
 left join taskfold_private.team_project_grants g on g.project_id=p and g.user_id=a
 where b.project_id=p and not exists(select 1 from taskfold_private.account_removal_receipts where account_id=a and created_at>statement_timestamp()-interval '7 days')
$$;
create function taskfold_private.team_native_actor_live() returns boolean
language sql stable security invoker set search_path='' as $$
 select exists(select 1 from auth.users u join auth.sessions s on s.user_id=u.id
 where u.id=auth.uid() and s.id=case when auth.jwt()->>'session_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then (auth.jwt()->>'session_id')::uuid end
 and (s.not_after is null or s.not_after>statement_timestamp()) and u.email_confirmed_at is not null and coalesce(u.email,'')<>''
 and (u.banned_until is null or u.banned_until<=statement_timestamp())
 and not exists(select 1 from taskfold_private.account_removal_receipts where account_id=u.id and created_at>statement_timestamp()-interval '7 days'))
$$;
create function taskfold_private.team_native_project_read(p uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce((select native_reads_enabled from taskfold_private.team_project_config where singleton),false)
 and auth.uid() is not null and taskfold_private.team_native_actor_live()
 and taskfold_private.team_project_role(auth.uid(),p) is not null
$$;
create function taskfold_private.team_native_task_read(t uuid,p uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select taskfold_private.team_native_project_read(p) and not exists(
  select 1 from taskfold_private.team_content_tasks c where c.task_id=t and c.team_id is distinct from
   (select team_id from taskfold_private.team_content_projects where project_id=p))
$$;
create function taskfold_private.team_native_activity_read(t uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=t and taskfold_private.team_native_project_read(c.project_id))
$$;
create function taskfold_private.team_native_file_read(o uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from taskfold_private.team_content_files f join storage.objects s on s.id=f.object_id
 join storage.buckets b on b.id=s.bucket_id and not b.public and b.id='task-attachments'
 where f.object_id=o and taskfold_private.team_native_project_read(f.project_id))
$$;

-- Do not let an old manager grant revive after a member was demoted to guest.
create function taskfold_private.demote_team_project_manager() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.role='guest' and old.role<>'guest' then delete from taskfold_private.team_project_grants where team_id=new.team_id and user_id=new.user_id and role='manager';end if;
 return new;
end$$;
create trigger taskfold_demote_project_manager after update of role on taskfold_private.team_members for each row execute function taskfold_private.demote_team_project_manager();

-- Existing live bindings can change settings after their creator departed. New
-- admission still locks the live creator; key custody itself remains immutable.
create or replace function taskfold_private.admit_team_content_project() returns trigger
language plpgsql security definer set search_path='' as $$
declare creator uuid;begin
 if tg_op='UPDATE' then
  if new.project_id is distinct from old.project_id or new.team_id is distinct from old.team_id then raise exception using errcode='PT409',message='Team project custody cannot be reassigned';end if;
 else
  select user_id into creator from public.projects where id=new.project_id;
  perform 1 from auth.users where id=creator for key share;
  if not found then raise exception using errcode='23503',message='Project creator is no longer available';end if;
  perform 1 from taskfold_private.teams where id=new.team_id and state='active' for update;
  if not found then raise exception using errcode='PT409',message='Team is unavailable';end if;
  perform 1 from public.projects where id=new.project_id for update;
  if exists(select 1 from public.projects c left join taskfold_private.team_content_projects b on b.project_id=c.id where c.parent_id=new.project_id and b.team_id is distinct from new.team_id)
   or exists(select 1 from public.projects c left join taskfold_private.team_content_projects b on b.project_id=c.parent_id where c.id=new.project_id and c.parent_id is not null and b.team_id is distinct from new.team_id)
   or exists(select 1 from public.tasks c join public.tasks parent on parent.id=c.recurrence_parent_id
    left join taskfold_private.team_content_projects cb on cb.project_id=c.project_id
    left join taskfold_private.team_content_projects pb on pb.project_id=parent.project_id
    where (c.project_id=new.project_id or parent.project_id=new.project_id)
     and (case when c.project_id=new.project_id then new.team_id else cb.team_id end) is distinct from (case when parent.project_id=new.project_id then new.team_id else pb.team_id end)) then
   raise exception using errcode='22023',message='Move linked work into the same workspace before sharing';end if;
  insert into taskfold_private.team_project_identities values(new.project_id,new.team_id);
  insert into taskfold_private.team_content_tasks(task_id,generation,team_id,project_id)
   select id,coalesce(task_generation,'00000000-0000-0000-0000-000000000000'),new.team_id,new.project_id from public.tasks where project_id=new.project_id on conflict(task_id,generation) do nothing;
 end if;
 if new.folder_id is not null and not exists(select 1 from taskfold_private.team_folders where id=new.folder_id and team_id=new.team_id) then raise exception using errcode='22023',message='Choose a folder in this team';end if;
 return new;
end$$;

-- Existing permissive policies keep personal sharing intact; separate SELECT
-- restrictions permit native team reads while every direct write remains closed.
drop policy team_content_project_closed on public.projects;
drop policy team_content_task_closed on public.tasks;
drop policy team_content_section_closed on public.sections;
drop policy team_content_activity_closed on public.task_activity;
drop policy team_content_file_closed on storage.objects;
create policy team_project_native_read on public.projects as restrictive for select to authenticated
 using(not taskfold_private.is_team_content_project(id) or taskfold_private.team_native_project_read(id));
create policy team_task_native_read on public.tasks as restrictive for select to authenticated
 using((not taskfold_private.is_team_content_project(project_id) and not taskfold_private.is_team_content_task(id)) or taskfold_private.team_native_task_read(id,project_id));
create policy team_section_native_read on public.sections as restrictive for select to authenticated
 using(not taskfold_private.is_team_content_project(project_id) or taskfold_private.team_native_project_read(project_id));
create policy team_activity_native_read on public.task_activity as restrictive for select to authenticated
 using(not taskfold_private.is_team_content_task(task_id) or taskfold_private.team_native_activity_read(task_id));
create policy team_file_native_read on storage.objects as restrictive for select to authenticated
 using(not taskfold_private.is_team_content_file(id) or taskfold_private.team_native_file_read(id));
create policy team_file_member_read on storage.objects for select to authenticated using(taskfold_private.team_native_file_read(id));
do $$declare r record;begin
 for r in select * from(values
 ('public.projects','not taskfold_private.is_team_content_project(id)'),
 ('public.tasks','not taskfold_private.is_team_content_project(project_id) and not taskfold_private.is_team_content_task(id)'),
 ('public.sections','not taskfold_private.is_team_content_project(project_id)'),
 ('storage.objects','not taskfold_private.is_team_content_file(id)'))v(rel,predicate) loop
  execute format('create policy team_native_insert_closed on %s as restrictive for insert to authenticated with check(%s)',r.rel,r.predicate);
  execute format('create policy team_native_update_closed on %s as restrictive for update to authenticated using(%s) with check(%s)',r.rel,r.predicate,r.predicate);
  execute format('create policy team_native_delete_closed on %s as restrictive for delete to authenticated using(%s)',r.rel,r.predicate);
 end loop;
end$$;

-- These old helpers are used by both RLS and privileged routines. Only a live
-- native actor may take the new branch. Service/API/email access stays disabled.
create or replace function taskfold_private.legacy_project_access(a uuid,p uuid,owner_only boolean) returns boolean
language sql stable security definer set search_path='' as $$
 select case when taskfold_private.is_team_content_project(p) then
  not owner_only and a=auth.uid() and taskfold_private.team_native_project_read(p)
 else exists(select 1 from public.projects where id=p and user_id=a) or
  (not owner_only and exists(select 1 from public.project_collaborators where project_id=p and user_id=a and status='accepted')) end
$$;
-- Comments use privileged writer RPCs rather than task UPDATE, so keep their
-- write path closed independently while permitting normal role-checked reads.
create trigger aaa_taskfold_team_comment_closed before insert or update or delete on public.task_comments for each row execute function taskfold_private.guard_closed_team_content();

revoke all on function taskfold_private.team_project_role(uuid,uuid),taskfold_private.team_native_actor_live(),taskfold_private.team_native_project_read(uuid),taskfold_private.team_native_task_read(uuid,uuid),taskfold_private.team_native_activity_read(uuid),taskfold_private.team_native_file_read(uuid),taskfold_private.demote_team_project_manager() from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_native_project_read(uuid),taskfold_private.team_native_task_read(uuid,uuid),taskfold_private.team_native_activity_read(uuid),taskfold_private.team_native_file_read(uuid) to authenticated;

create function taskfold_private.team_project_command(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid(); t uuid; p uuid; q uuid; target uuid; item uuid; folder uuid;
 team taskfold_private.teams; binding taskfold_private.team_content_projects; prior taskfold_private.team_project_commands;
 team_role text; role text; offered text; target_team_role text; chosen_visibility text; n text; result jsonb;
 fingerprint text; issued timestamptz; reviewed numeric; page_limit integer:=50; cursor_id uuid; rows jsonb; today date; resetting boolean:=false; target_available boolean:=false;
begin
 perform taskfold_private.team_actor();
 if action='list' then perform taskfold_private.team_fields(b,array['team_id'],array['after','limit']);
 elsif action='get' then perform taskfold_private.team_fields(b,array['team_id','project_id']);
 elsif action='create' then perform taskfold_private.team_fields(b,array['team_id','project_id','request_id','issued_at','team_revision','name','visibility','folder_id']);
 elsif action='set_access' then perform taskfold_private.team_fields(b,array['team_id','project_id','request_id','issued_at','team_revision','revision','user_id','role']);
 elsif action='reset_access' then perform taskfold_private.team_fields(b,array['team_id','project_id','request_id','issued_at','team_revision','revision','user_id']);
 elsif action='settings' then perform taskfold_private.team_fields(b,array['team_id','project_id','request_id','issued_at','team_revision','revision','visibility','folder_id']);
 else raise exception using errcode='22023',message='Unsupported project action';end if;
 t=taskfold_private.team_uuid(b,'team_id');
 if action<>'list' then p=taskfold_private.team_uuid(b,'project_id');end if;
 if action in('set_access','reset_access') then
  target=taskfold_private.team_uuid(b,'user_id');
  -- Auth cleanup locks the target before deleting memberships; take the same
  -- order before holding team/project rows, so a grant cannot race account loss.
  if not exists(select 1 from taskfold_private.team_content_projects where project_id=p and team_id=t) or taskfold_private.team_project_role(a,p) is distinct from 'manager' then raise exception using errcode='42501',message='Project management access is required';end if;
  perform 1 from auth.users u join taskfold_private.team_members m on m.user_id=u.id and m.team_id=t where u.id=target and u.email_confirmed_at is not null and coalesce(u.email,'')<>'' and (u.banned_until is null or u.banned_until<=clock_timestamp()) for share of u;
  target_available=found;
 end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if action in('list','get') then
  select * into team from taskfold_private.teams where id=t and state<>'deleted' for share;
 else select * into team from taskfold_private.teams where id=t and state<>'deleted' for update;end if;
 if not found then raise exception using errcode='PT404',message='Team is unavailable';end if;
 perform taskfold_private.team_actor();
 team_role=taskfold_private.team_role(t,a);
 if team_role is null then raise exception using errcode='PT404',message='Team is unavailable';end if;
 if action='list' then
  if b ? 'limit' then
   if jsonb_typeof(b->'limit') is distinct from 'number' or (b->>'limit')::numeric not between 1 and 100 or (b->>'limit')::numeric<>trunc((b->>'limit')::numeric) then raise exception using errcode='22023',message='Choose a valid project page';end if;
   page_limit=(b->>'limit')::numeric::integer;
  end if;
  if b ? 'after' then cursor_id=taskfold_private.team_uuid(b,'after');end if;
  select coalesce(jsonb_agg(value order by project_id),'[]') into rows from(
   select c.project_id,jsonb_build_object('id',c.project_id,'team_id',t,'revision',c.revision,'visibility',c.visibility,'folder_id',c.folder_id,'role',taskfold_private.team_project_role(a,c.project_id),'can_edit_tasks',false,'can_manage_access',taskfold_private.team_project_role(a,c.project_id)='manager') as value
   from taskfold_private.team_content_projects c where c.team_id=t and (cursor_id is null or c.project_id>cursor_id) and taskfold_private.team_project_role(a,c.project_id) is not null order by c.project_id limit page_limit+1) z;
  return jsonb_build_object('protocol',1,'account',a,'team_id',t,'projects',case when jsonb_array_length(rows)>page_limit then rows-(jsonb_array_length(rows)-1) else rows end,
   'next_cursor',case when jsonb_array_length(rows)>page_limit then rows->(page_limit-1)->>'id' else null end,'team_revision',team.revision,'task_writes_enabled',false,'team_state',team.state,'setup_paused',not coalesce((select enabled from taskfold_private.team_config where singleton),false));
 end if;
 select * into binding from taskfold_private.team_content_projects where project_id=p and team_id=t for update;
 if action<>'create' and not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 role=taskfold_private.team_project_role(a,p);
 if action='get' then
  if role is null then raise exception using errcode='PT404',message='Project is unavailable';end if;
  result=jsonb_build_object('protocol',1,'account',a,'id',p,'team_id',t,'revision',binding.revision,'team_revision',team.revision,'visibility',binding.visibility,'folder_id',binding.folder_id,'role',role,'can_edit_tasks',false,'can_manage_access',role='manager','team_state',team.state,'setup_paused',not coalesce((select enabled from taskfold_private.team_config where singleton),false));
  if role='manager' then result=result||jsonb_build_object('grants',(select coalesce(jsonb_agg(jsonb_build_object('user_id',g.user_id,'role',g.role) order by g.user_id),'[]') from taskfold_private.team_project_grants g where g.project_id=p));end if;
  return result;
 end if;
 if action='create' then
  if team_role='guest' then raise exception using errcode='42501',message='Team membership is required to create a project';end if;
 elsif role is distinct from 'manager' then raise exception using errcode='42501',message='Project management access is required';end if;
 q=taskfold_private.team_uuid(b,'request_id');
 if jsonb_typeof(b->'issued_at') is distinct from 'string' or (b->>'issued_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then raise exception using errcode='22023',message='Review the project request again';end if;
 begin issued=(b->>'issued_at')::timestamptz;exception when others then raise exception using errcode='22023',message='Review the project request again';end;
 if issued<clock_timestamp()-interval '15 minutes' or issued>clock_timestamp()+interval '1 minute' then raise exception using errcode='PT409',message='Review the project request again';end if;
 fingerprint=encode(extensions.digest(convert_to(jsonb_build_array(action,b)::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.team_project_commands where team_id=t and request_id=q;
 if found then
  if prior.actor_id=a and prior.fingerprint=fingerprint then return prior.result;end if;
  raise exception using errcode='PT409',message='Project request changed';end if;
 if jsonb_typeof(b->'team_revision') is distinct from 'number' or (b->>'team_revision')::numeric<>trunc((b->>'team_revision')::numeric) or (b->>'team_revision')::numeric not between 1 and 9007199254740991 then raise exception using errcode='22023',message='Invalid team review';end if;
 if (b->>'team_revision')::numeric<>team.revision then raise exception using errcode='PT409',message='Team changed; review it again';end if;
 if action<>'create' then
  if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')::numeric<>trunc((b->>'revision')::numeric) or (b->>'revision')::numeric not between 1 and 9007199254740990 then raise exception using errcode='22023',message='Invalid project review';end if;
  if (b->>'revision')::numeric<>binding.revision then raise exception using errcode='PT409',message='Project changed; review it again';end if;
 end if;
 if action in('set_access','reset_access') then
  target_team_role=taskfold_private.team_role(t,target);
  if not target_available or target_team_role is null then raise exception using errcode='PT404',message='Team member is unavailable';end if;
  if target_team_role in('owner','admin') then raise exception using errcode='42501',message='Team admins manage projects through their team role';end if;
  if action='set_access' then
   if jsonb_typeof(b->'role') is distinct from 'string' or b->>'role' not in('manager','editor','viewer') then raise exception using errcode='22023',message='Choose a supported project role';end if;
   offered=b->>'role';
   if offered='manager' and target_team_role='guest' then raise exception using errcode='22023',message='Guests cannot manage projects';end if;
  else
   select g.role into offered from taskfold_private.team_project_grants g where g.project_id=p and g.user_id=target;
   if not found then raise exception using errcode='PT404',message='There is no project override to reset';end if;
   resetting=(binding.visibility='private' or target_team_role='guest' or offered='manager');
  end if;
 end if;
 if not resetting then
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Team setup is paused';end if;
  if team.state='archived' then raise exception using errcode='PT409',message='Unarchive this team first';end if;
 end if;
 today=(clock_timestamp() at time zone 'UTC')::date;
 if not resetting and team.usage_day=today and team.day_operations>=2000 then raise exception using errcode='PT429',message='Team administration is busy; try another day';end if;
 if action in('create','settings') then
  if jsonb_typeof(b->'visibility') is distinct from 'string' or b->>'visibility' not in('team','private') then raise exception using errcode='22023',message='Choose team or private visibility';end if;
  chosen_visibility=b->>'visibility';
  if b->'folder_id'<>'null'::jsonb then folder=taskfold_private.team_uuid(b,'folder_id');end if;
  if folder is not null and not exists(select 1 from taskfold_private.team_folders where id=folder and team_id=t) then raise exception using errcode='22023',message='Choose a folder in this team';end if;
 end if;
 if action='create' then
  if exists(select 1 from taskfold_private.team_project_identities where project_id=p) or exists(select 1 from public.projects where id=p) then raise exception using errcode='PT409',message='Project identity is unavailable';end if;
  if (select count(*) from taskfold_private.team_content_projects where team_id=t)>=1000 then raise exception using errcode='54000',message='Team project limit reached';end if;
  n=taskfold_private.team_name(b);
  insert into public.projects(id,user_id,name) values(p,a,n);
  insert into taskfold_private.team_content_projects(project_id,team_id,visibility,folder_id) values(p,t,chosen_visibility,folder);
  insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(p,t,a,'manager');
 elsif action='set_access' then
  insert into taskfold_private.team_project_grants values(p,t,target,offered) on conflict(project_id,user_id) do update set role=excluded.role;
 elsif action='reset_access' then delete from taskfold_private.team_project_grants where project_id=p and user_id=target;
 elsif action='settings' then update taskfold_private.team_content_projects set visibility=chosen_visibility,folder_id=folder where project_id=p;
 end if;
 if action<>'create' then update taskfold_private.team_content_projects set revision=revision+1 where project_id=p;end if;
 select * into binding from taskfold_private.team_content_projects where project_id=p;
 update taskfold_private.teams set usage_day=today,day_operations=case when usage_day=today then least(day_operations+1,2000) else 1 end where id=t;
 result=jsonb_build_object('protocol',1,'account',a,'request_id',q,'id',p,'team_id',t,'revision',binding.revision,'team_revision',team.revision);
 delete from taskfold_private.team_project_commands where team_id=t and created_at<clock_timestamp()-interval '1 day';
 insert into taskfold_private.team_project_commands values(t,q,a,fingerprint,result,clock_timestamp());
 return result;
end$$;
create function public.taskfold_team_projects(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_project_command(_action,_body)$$;
revoke all on function taskfold_private.team_project_command(text,jsonb),public.taskfold_team_projects(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_project_command(text,jsonb),public.taskfold_team_projects(text,jsonb) to authenticated;

-- Current project readers only; a departed creator is not a directory entry.
-- Only project members can resolve another member's public display identity.
create or replace function taskfold_private.project_member_profiles(_project_id uuid)
returns table(user_id uuid, display_name text, avatar_url text)
language sql stable security definer set search_path = ''
as $$
  with members as (
    select p.user_id from public.projects p
    where p.id = _project_id
      and not taskfold_private.is_team_content_project(_project_id)
      and auth.uid() is not null
      and public.has_project_access(auth.uid(), _project_id)
    union
    select c.user_id from public.project_collaborators c
    where c.project_id = _project_id and c.status = 'accepted' and c.user_id is not null
      and not taskfold_private.is_team_content_project(_project_id)
      and auth.uid() is not null
      and public.has_project_access(auth.uid(), _project_id)
    union
    select m.user_id from taskfold_private.team_members m
    join taskfold_private.team_content_projects b on b.team_id=m.team_id
    where b.project_id=_project_id and taskfold_private.team_native_project_read(_project_id)
      and taskfold_private.team_project_role(m.user_id,_project_id) is not null
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

-- The pre-managed email helper used creator/collaborator shortcuts independently
-- of RLS. Team relationships must not expose contact email, especially after an
-- original creator leaves. Preserve the existing personal-sharing contract only.
create function taskfold_private.legacy_contact_email(person uuid) returns text
language sql stable security definer set search_path='' as $$
 select u.email from auth.users u where u.id=person and auth.uid() is not null
 and exists(select 1 from auth.users a where a.id=auth.uid() and (a.banned_until is null or a.banned_until<=statement_timestamp()))
 and (u.id=auth.uid()
  or exists(select 1 from public.project_collaborators pc where pc.user_id=auth.uid() and pc.invited_by=u.id and pc.status in('pending','accepted') and not taskfold_private.is_team_content_project(pc.project_id))
  or exists(select 1 from public.projects p join public.project_collaborators pc on pc.project_id=p.id where p.user_id=auth.uid() and pc.user_id=u.id and pc.status='accepted' and not taskfold_private.is_team_content_project(p.id))) limit 1
$$;
create or replace function public.get_user_email_by_id(_user_id uuid) returns text
language sql stable security invoker set search_path='' as $$select taskfold_private.legacy_contact_email(_user_id)$$;
revoke all on function taskfold_private.legacy_contact_email(uuid),public.get_user_email_by_id(uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.legacy_contact_email(uuid),public.get_user_email_by_id(uuid) to authenticated,service_role;

-- New native visibility must not let legacy personal writes attach to company
-- hierarchy/recurrence/section relationships. Personal sharing stays unchanged.
create function taskfold_private.guard_team_workspace_link() returns trigger
language plpgsql security definer set search_path='' as $$
declare own_team uuid; old_team uuid; related_team uuid;begin
 if tg_table_name='projects' then
  if new.parent_id is null or (tg_op='UPDATE' and new.parent_id is not distinct from old.parent_id and new.id=old.id) then return new;end if;
  select team_id into own_team from taskfold_private.team_content_projects where project_id=new.id;
  select team_id into related_team from taskfold_private.team_content_projects where project_id=new.parent_id;
 else
  select team_id into own_team from taskfold_private.team_content_projects where project_id=new.project_id;
  if tg_op='UPDATE' and new.project_id is distinct from old.project_id then
   select team_id into old_team from taskfold_private.team_content_projects where project_id=old.project_id;
   if own_team is distinct from old_team then raise exception using errcode='22023',message='Move work within the same workspace';end if;
  end if;
  if tg_table_name='sections' then return new;end if;
  if new.recurrence_parent_id is null or (tg_op='UPDATE' and new.recurrence_parent_id is not distinct from old.recurrence_parent_id and new.project_id is not distinct from old.project_id) then return new;end if;
  select b.team_id into related_team from public.tasks t left join taskfold_private.team_content_projects b on b.project_id=t.project_id where t.id=new.recurrence_parent_id;
 end if;
 if own_team is distinct from related_team then raise exception using errcode='22023',message='Choose a linked item in the same workspace';end if;
 return new;
end$$;
create trigger aa_taskfold_workspace_link before insert or update on public.projects for each row execute function taskfold_private.guard_team_workspace_link();
create trigger aa_taskfold_workspace_link before insert or update on public.tasks for each row execute function taskfold_private.guard_team_workspace_link();
create trigger aa_taskfold_workspace_link before insert or update on public.sections for each row execute function taskfold_private.guard_team_workspace_link();
revoke all on function taskfold_private.guard_team_workspace_link() from public,anon,authenticated,service_role;

-- Track the last project within immutable team custody, including deletion.
-- Otherwise a legitimate move could leave history authorized by an old project.
create or replace function taskfold_private.record_team_content_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare row_task public.tasks; team uuid;begin
 if tg_op='DELETE' then row_task=old;else row_task=new;end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=row_task.project_id;
 if team is not null then
  insert into taskfold_private.team_content_tasks(task_id,generation,team_id,project_id)
  values(row_task.id,coalesce(row_task.task_generation,'00000000-0000-0000-0000-000000000000'),team,row_task.project_id)
  on conflict(task_id,generation) do update set project_id=excluded.project_id where team_content_tasks.team_id=excluded.team_id;
  if not found then raise exception using errcode='22023',message='Task custody cannot cross workspaces';end if;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;
update taskfold_private.team_content_tasks c set project_id=t.project_id from public.tasks t
 join taskfold_private.team_content_projects b on b.project_id=t.project_id
 where t.id=c.task_id and coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000')=c.generation and c.team_id=b.team_id and c.project_id is distinct from t.project_id;
create or replace function taskfold_private.team_native_activity_read(t uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from public.tasks where id=t) then
  exists(select 1 from public.tasks x where x.id=t and taskfold_private.team_native_task_read(x.id,x.project_id))
 else exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=t and taskfold_private.team_native_project_read(c.project_id)) end
$$;
create function taskfold_private.team_native_activity_states_read(b jsonb,a jsonb) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and taskfold_private.team_native_actor_live()
 and (b='{}'::jsonb or taskfold_private.team_native_project_read(case when b->>'project_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then (b->>'project_id')::uuid end))
 and (a='{}'::jsonb or taskfold_private.team_native_project_read(case when a->>'project_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then (a->>'project_id')::uuid end))
$$;
drop policy team_activity_native_read on public.task_activity;
create policy team_activity_native_read on public.task_activity as restrictive for select to authenticated
 using(not taskfold_private.is_team_content_task(task_id) or (taskfold_private.team_native_activity_read(task_id) and taskfold_private.team_native_activity_states_read(before_state,after_state)));
alter policy task_activity_read on public.task_activity
 using(taskfold_private.is_team_content_task(task_id) or taskfold_private.can_read_task_activity(user_id,task_id,before_state,after_state));
revoke all on function taskfold_private.team_native_activity_states_read(jsonb,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_native_activity_states_read(jsonb,jsonb) to authenticated;
