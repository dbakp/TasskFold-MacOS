-- Disabled team-content custody foundation. No team project admission API yet.
-- Auth credentials/profile may disappear; shared content retains only its creator UUID.
create table taskfold_private.content_identities (
 id uuid primary key,
 removed_at timestamptz
);
-- Install the Auth trigger before backfill. CREATE TRIGGER holds the table lock
-- through this migration transaction, excluding an unregistered concurrent signup.
create function taskfold_private.register_content_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into taskfold_private.content_identities(id) values(new.id) on conflict(id) do nothing;
 if exists(select 1 from taskfold_private.content_identities where id=new.id and removed_at is not null) then
  raise exception using errcode='PT409',message='A removed account identity cannot be reused';end if;
 return new;
end$$;
create trigger aa_taskfold_content_identity before insert on auth.users for each row execute function taskfold_private.register_content_identity();

insert into taskfold_private.content_identities(id) select id from auth.users;
alter table taskfold_private.content_identities enable row level security;
revoke all on taskfold_private.content_identities from public,anon,authenticated,service_role;

create table taskfold_private.team_content_projects (
 project_id uuid primary key references public.projects(id) on delete cascade,
 team_id uuid not null references taskfold_private.teams(id) on delete restrict
);
create index team_content_projects_team on taskfold_private.team_content_projects(team_id,project_id);
create table taskfold_private.team_content_tasks (
 task_id uuid not null,
 generation uuid not null,
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 project_id uuid not null,
 primary key(task_id,generation)
);
create index team_content_tasks_team on taskfold_private.team_content_tasks(team_id,project_id);
create table taskfold_private.team_content_files (
 object_id uuid primary key references storage.objects(id) on delete restrict,
 project_id uuid not null references taskfold_private.team_content_projects(project_id) on delete restrict
);
create index team_content_files_project on taskfold_private.team_content_files(project_id);
alter table taskfold_private.team_content_projects enable row level security;
alter table taskfold_private.team_content_tasks enable row level security;
alter table taskfold_private.team_content_files enable row level security;
revoke all on taskfold_private.team_content_projects,taskfold_private.team_content_tasks,taskfold_private.team_content_files from public,anon,authenticated,service_role;

-- Releasing a binding is not proof that Storage deleted its bytes. Keep private
-- cleanup custody until the Storage API has also removed the object metadata.
create table taskfold_private.team_content_file_removals (
 object_id uuid primary key,
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 bucket_id text not null,
 object_name text not null
);
create index team_content_file_removals_team on taskfold_private.team_content_file_removals(team_id,object_id);
alter table taskfold_private.team_content_file_removals enable row level security;
revoke all on taskfold_private.team_content_file_removals from public,anon,authenticated,service_role;

-- Private transaction authority for the explicit team deletion trigger. A
-- caller-set GUC cannot impersonate this scope; failed statements roll it back.
create table taskfold_private.team_content_operations (
 transaction_id bigint not null,
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 primary key(transaction_id,team_id)
);
create index team_content_operations_team on taskfold_private.team_content_operations(team_id);
alter table taskfold_private.team_content_operations enable row level security;
revoke all on taskfold_private.team_content_operations from public,anon,authenticated,service_role;

-- Keep stable creator fields and existing non-null native/wire contracts.
-- Only these content FKs change. Credentials, profiles, memberships, notification
-- devices/jobs, comment authors and assignees keep their inspected Auth semantics.
alter table public.projects drop constraint projects_user_id_fkey;
alter table public.projects add constraint projects_user_id_fkey foreign key(user_id) references taskfold_private.content_identities(id) on delete restrict;
alter table public.tasks drop constraint tasks_user_id_fkey;
alter table public.tasks add constraint tasks_user_id_fkey foreign key(user_id) references taskfold_private.content_identities(id) on delete restrict;
alter table public.sections drop constraint sections_user_id_fkey;
alter table public.sections add constraint sections_user_id_fkey foreign key(user_id) references taskfold_private.content_identities(id) on delete restrict;
alter table public.task_activity drop constraint task_activity_user_id_fkey;
alter table public.task_activity add constraint task_activity_user_id_fkey foreign key(user_id) references taskfold_private.content_identities(id) on delete restrict;
alter table taskfold_private.task_generations drop constraint task_generations_user_id_fkey;
alter table taskfold_private.task_generations add constraint task_generations_user_id_fkey foreign key(user_id) references taskfold_private.content_identities(id) on delete restrict;

-- UUID-only custody survives task deletion so generation tombstones and activity
-- do not disappear when an original author later removes their account.
create function taskfold_private.record_team_content_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare row_task public.tasks; team uuid;begin
 if tg_op='DELETE' then row_task=old;else row_task=new;end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=row_task.project_id;
 if team is not null then
  insert into taskfold_private.team_content_tasks(task_id,generation,team_id,project_id)
  values(row_task.id,coalesce(row_task.task_generation,'00000000-0000-0000-0000-000000000000'),team,row_task.project_id)
  on conflict(task_id,generation) do nothing;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;
create trigger taskfold_team_content_task after insert or update or delete on public.tasks for each row execute function taskfold_private.record_team_content_task();

create function taskfold_private.admit_team_content_project() returns trigger
language plpgsql security definer set search_path='' as $$
declare creator uuid;begin
 select user_id into creator from public.projects where id=new.project_id;
 perform 1 from auth.users where id=creator for key share;
 if not found then raise exception using errcode='23503',message='Project creator is no longer available';end if;
 perform 1 from taskfold_private.teams where id=new.team_id and state='active' for update;
 if not found then raise exception using errcode='PT409',message='Team is unavailable';end if;
 -- Future reviewed admission must own hierarchy/sharing/archive/import checks.
 -- No client has a grant or callable API to insert this binding now.
 perform 1 from public.projects where id=new.project_id for update;
 if tg_op='UPDATE' and new is distinct from old then raise exception using errcode='PT409',message='Team project custody cannot be reassigned';end if;
 insert into taskfold_private.team_content_tasks(task_id,generation,team_id,project_id)
 select id,coalesce(task_generation,'00000000-0000-0000-0000-000000000000'),new.team_id,new.project_id from public.tasks where project_id=new.project_id
 on conflict(task_id,generation) do nothing;
 return new;
end$$;
create trigger taskfold_admit_team_content before insert or update on taskfold_private.team_content_projects for each row execute function taskfold_private.admit_team_content_project();

-- No direct native client may see/write a team project until the complete role
-- policy is installed. Restrictive policies also fence old creator-only OR rules.
create function taskfold_private.is_team_content_project(p uuid) returns boolean
language sql stable security definer set search_path='' as $$select exists(select 1 from taskfold_private.team_content_projects where project_id=p)$$;
create function taskfold_private.is_team_content_task(t uuid) returns boolean
language sql stable security definer set search_path='' as $$select exists(select 1 from taskfold_private.team_content_tasks where task_id=t)$$;
create function taskfold_private.is_team_content_file(o uuid) returns boolean
language sql stable security definer set search_path='' as $$select exists(select 1 from taskfold_private.team_content_files where object_id=o) or exists(select 1 from taskfold_private.team_content_file_removals where object_id=o)$$;
create policy team_content_project_closed on public.projects as restrictive to authenticated
 using(not taskfold_private.is_team_content_project(id)) with check(not taskfold_private.is_team_content_project(id));
create policy team_content_task_closed on public.tasks as restrictive to authenticated
 using(not taskfold_private.is_team_content_project(project_id) and not taskfold_private.is_team_content_task(id))
 with check(not taskfold_private.is_team_content_project(project_id) and not taskfold_private.is_team_content_task(id));
create policy team_content_section_closed on public.sections as restrictive to authenticated
 using(not taskfold_private.is_team_content_project(project_id)) with check(not taskfold_private.is_team_content_project(project_id));
create policy team_content_activity_closed on public.task_activity as restrictive for select to authenticated
 using(not taskfold_private.is_team_content_task(task_id));
create policy team_content_file_closed on storage.objects as restrictive to authenticated
 using(not taskfold_private.is_team_content_file(id)) with check(not taskfold_private.is_team_content_file(id));

-- Preserve legacy service/project semantics, but deny the as-yet unsupported team
-- path before creator/collaborator shortcuts can grant service/API/mail authority.
create or replace function taskfold_private.automation_lock_project(_account uuid,_project uuid)
returns void language plpgsql volatile security invoker set search_path='' as $$
declare owner_id uuid;begin
 if taskfold_private.is_team_content_project(_project) then raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 select user_id into owner_id from public.projects where id=_project for share;
 if not found then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
 if owner_id=_account then return;end if;
 perform 1 from public.project_collaborators where project_id=_project and user_id=_account and status='accepted' for share;
 if not found then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
end$$;

-- SQL RLS is not the authority for Auth-trigger cleanup. These explicit rules
-- preserve original personal/shared-project deletion behavior and retain team data.
create function taskfold_private.remove_content_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from taskfold_private.teams where owner_id=old.id and state<>'deleted') then
  raise exception using errcode='PT409',message='Transfer or delete owned teams before removing your account';end if;
 -- Detach every surviving series child from a root that will actually disappear.
 update public.tasks child set recurrence_parent_id=null
 where child.recurrence_parent_id in(select root.id from public.tasks root where root.user_id=old.id
  and not taskfold_private.is_team_content_task(root.id))
 and (child.user_id<>old.id or taskfold_private.is_team_content_task(child.id));
 delete from public.tasks where user_id=old.id and not taskfold_private.is_team_content_task(id);
 delete from public.sections where user_id=old.id and not taskfold_private.is_team_content_project(project_id);
 delete from public.projects where user_id=old.id and not taskfold_private.is_team_content_project(id);
 delete from public.task_activity where user_id=old.id and not taskfold_private.is_team_content_task(task_id);
 delete from taskfold_private.task_generations where user_id=old.id and not taskfold_private.is_team_content_task(task_id);
 update taskfold_private.content_identities set removed_at=clock_timestamp() where id=old.id;
 return old;
end$$;
create trigger taskfold_remove_content_identity before delete on auth.users for each row execute function taskfold_private.remove_content_identity();

-- A retained creator UUID must not cause new team activity to be silently lost
-- after Auth has gone. This remains the same private trigger, not a writer API.
-- Preserve authorized foreign-key cascades; the private trigger has no callable writer API.
create or replace function taskfold_private.capture_task_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare caller uuid := auth.uid(); t public.tasks; b jsonb := '{}'; a jsonb := '{}'; kinds text[] := '{}'; instant timestamptz := statement_timestamp();
begin
 if tg_table_schema <> 'public' or tg_table_name <> 'tasks' then raise exception 'Invalid activity source'; end if;
 if tg_op = 'INSERT' then t := new; else t := old; end if;
 -- Cascading account deletion must not recreate data for an owner being removed.
 if not exists(select 1 from auth.users where id=t.user_id) and not taskfold_private.is_team_content_task(t.id) and not taskfold_private.is_team_content_project(t.project_id) then
  if tg_op = 'DELETE' then return old; else return new; end if;
 end if;
 -- Original DML/FK cascades retain table authorization. Rechecking the old project
 -- here would reject an authorized project deletion after that project disappeared.
 if caller is not null and not exists(select 1 from auth.users where id=caller) then
  raise exception 'Task activity actor is no longer available';
 end if;
 if tg_op <> 'INSERT' then b := taskfold_private.activity_state(old); end if;
 if tg_op <> 'DELETE' then a := taskfold_private.activity_state(new); t := new; end if;
 if tg_op = 'INSERT' then kinds := array['created'];
 elsif tg_op = 'DELETE' then kinds := array['deleted'];
 else
  if coalesce(old.completed,false) is distinct from coalesce(new.completed,false) then
   kinds := array_append(kinds,case when coalesce(new.completed,false) then 'completed' else 'reopened' end);
  elsif old.completed_at is distinct from new.completed_at then kinds := array_append(kinds,'completion_time'); end if;
  if old.project_id is distinct from new.project_id or old.section_id is distinct from new.section_id then kinds := array_append(kinds,'moved'); end if;
  if (b - array['project_id','section_id','completed','completed_at','recurrence_parent_id']) is distinct from (a - array['project_id','section_id','completed','completed_at','recurrence_parent_id']) then
   kinds := array_append(kinds,'rescheduled');
  end if;
 end if;
 if cardinality(kinds) > 0 then
  if 'completed' = any(kinds) and t.completed_at is not null then instant := t.completed_at; end if;
  insert into public.task_activity(user_id,task_id,actor_id,effective_at,completion_version,kinds,before_state,after_state)
   values(t.user_id,t.id,caller,instant,t.completion_version,kinds,b,a);
 end if;
 if tg_op = 'DELETE' then return old; else return new; end if;
end $$;
revoke all on function taskfold_private.capture_task_activity() from public, anon, authenticated;

create or replace function public.taskfold_account_removal_files(_token_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_owner uuid; result jsonb;
begin
 select account_id into v_owner from taskfold_private.account_removal_receipts
 where token_hash=_token_hash and created_at>clock_timestamp()-interval '7 days' and completed_at is null;
 if not found then raise exception 'Removal authorization unavailable' using errcode='28000'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('bucket',f.bucket_id,'name',f.name)),'[]') into result from (
  select o.bucket_id,o.name from storage.objects o
  where not taskfold_private.is_team_content_file(o.id) and (coalesce(o.owner_id,o.owner::text)=v_owner::text
   or (o.owner_id is null and o.owner is null and o.bucket_id in ('avatars','task-attachments')
       and starts_with(o.name,v_owner::text||'/')))
  order by o.bucket_id,o.name limit 100
 ) f;
 return result;
end $$;

create or replace function public.taskfold_account_removal_prepare(_token_hash text) returns uuid
language plpgsql security definer set search_path='' as $$
declare departing uuid;
begin
 select account_id into departing from taskfold_private.account_removal_receipts
 where token_hash=_token_hash and created_at>clock_timestamp()-interval '7 days' and completed_at is null;
 if not found then raise exception 'Removal authorization unavailable' using errcode='28000'; end if;
 if jsonb_array_length(public.taskfold_account_removal_files(_token_hash))<>0 then raise exception 'Remove stored files before the account'; end if;
 -- A surviving task must not cascade away merely because its recurrence parent leaves.
 update public.tasks child set recurrence_parent_id=null where (child.user_id<>departing or taskfold_private.is_team_content_task(child.id))
 and child.recurrence_parent_id in(select id from public.tasks where user_id=departing and not taskfold_private.is_team_content_task(id));
 -- Device rows otherwise retain a push token with a NULL owner after Auth deletion.
 delete from taskfold_private.reminder_devices where user_id=departing;
 return departing;
end $$;

-- Team deletion is explicit and atomic. Object bytes must first be removed by
-- an authorized Storage API workflow; never delete storage.objects through SQL.
create function taskfold_private.delete_team_content() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='deleted' and old.state<>'deleted' then
  delete from taskfold_private.team_content_file_removals r where r.team_id=old.id and not exists(select 1 from storage.objects where id=r.object_id);
  if exists(select 1 from taskfold_private.team_content_files f join taskfold_private.team_content_projects p on p.project_id=f.project_id where p.team_id=old.id) or exists(select 1 from taskfold_private.team_content_file_removals where team_id=old.id) then
   raise exception using errcode='PT409',message='Remove team files before deleting this team';end if;
  insert into taskfold_private.team_content_operations values(txid_current(),old.id);
  update public.tasks child set recurrence_parent_id=null where child.recurrence_parent_id in(
   select t.id from public.tasks t join taskfold_private.team_content_tasks c on c.task_id=t.id where c.team_id=old.id)
   and not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=child.id and c.team_id=old.id);
  delete from public.tasks where id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id);
  delete from public.projects where id in(select project_id from taskfold_private.team_content_projects where team_id=old.id);
  delete from public.task_activity where task_id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id);
  delete from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=old.id;
  -- Generation/custody tombstones contain UUIDs only and continue preventing replay.
 end if;
 return new;
end$$;
create trigger taskfold_delete_team_content before update on taskfold_private.teams for each row execute function taskfold_private.delete_team_content();

revoke all on function taskfold_private.register_content_identity(),taskfold_private.record_team_content_task(),taskfold_private.admit_team_content_project(),taskfold_private.remove_content_identity(),taskfold_private.delete_team_content(),taskfold_private.is_team_content_project(uuid),taskfold_private.is_team_content_task(uuid),taskfold_private.is_team_content_file(uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.is_team_content_project(uuid),taskfold_private.is_team_content_task(uuid),taskfold_private.is_team_content_file(uuid) to authenticated;

-- Comments, assignment/profile lookup and other privileged callers use these
-- existing helper signatures. Keep legacy sharing, close team shortcuts centrally.
create function taskfold_private.legacy_project_access(a uuid,p uuid,owner_only boolean) returns boolean
language sql stable security definer set search_path='' as $$
 select not taskfold_private.is_team_content_project(p) and (
  exists(select 1 from public.projects where id=p and user_id=a) or
  (not owner_only and exists(select 1 from public.project_collaborators where project_id=p and user_id=a and status='accepted')))
$$;
create or replace function public.has_project_access(_user_id uuid,_project_id uuid) returns boolean
language sql stable security invoker set search_path='' as $$select taskfold_private.legacy_project_access(_user_id,_project_id,false)$$;
create or replace function public.is_project_owner(_user_id uuid,_project_id uuid) returns boolean
language sql stable security invoker set search_path='' as $$select taskfold_private.legacy_project_access(_user_id,_project_id,true)$$;
revoke all on function taskfold_private.legacy_project_access(uuid,uuid,boolean),public.has_project_access(uuid,uuid),public.is_project_owner(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.legacy_project_access(uuid,uuid,boolean),public.has_project_access(uuid,uuid),public.is_project_owner(uuid,uuid) to authenticated,service_role;

-- Replacing the creator FK must not let a still-valid deleted-account JWT create
-- new personal data. The old Auth FK also serialized creators against deletion;
-- retain that exact row lock for all new/changed personal creator references.
create function taskfold_private.guard_content_creator() returns trigger
language plpgsql security definer set search_path='' as $$
declare p uuid; protected boolean;begin
 if tg_table_name='projects' and tg_op='INSERT' and new.user_id is null then new.user_id=auth.uid();end if;
 if tg_op='UPDATE' and new.user_id is not distinct from old.user_id then return new;end if;
 if tg_table_name='projects' then p=new.id;else p=new.project_id;end if;
 protected=taskfold_private.is_team_content_project(p);
 if not protected then
  perform 1 from auth.users where id=new.user_id for key share;
  if not found then raise exception using errcode='23503',message='Content creator is no longer available';end if;
 end if;
 return new;
end$$;
create trigger aa_taskfold_content_creator before insert or update on public.projects for each row execute function taskfold_private.guard_content_creator();
create trigger aa_taskfold_content_creator before insert or update on public.tasks for each row execute function taskfold_private.guard_content_creator();
create trigger aa_taskfold_content_creator before insert or update on public.sections for each row execute function taskfold_private.guard_content_creator();
revoke all on function taskfold_private.guard_content_creator() from public,anon,authenticated,service_role;
create policy team_content_collaborators_closed on public.project_collaborators as restrictive to authenticated
 using(not taskfold_private.is_team_content_project(project_id)) with check(not taskfold_private.is_team_content_project(project_id));

-- File custody is restricted to the existing private attachment bucket. A new
-- binding serializes with removal begin on the original uploader's Auth row.
create function taskfold_private.guard_team_content_file() returns trigger
language plpgsql security definer set search_path='' as $$
declare uploader text; bucket text; is_public boolean;begin
 if tg_op='UPDATE' and new is distinct from old then raise exception using errcode='PT409',message='File custody cannot be reassigned';end if;
 if exists(select 1 from taskfold_private.team_content_file_removals where object_id=new.object_id) then raise exception using errcode='PT409',message='File cleanup is still pending';end if;
 select coalesce(o.owner_id,o.owner::text),b.id,b.public into uploader,bucket,is_public
 from storage.objects o join storage.buckets b on b.id=o.bucket_id where o.id=new.object_id for share of o,b;
 if not found or bucket<>'task-attachments' or is_public then raise exception using errcode='22023',message='Use a private team attachment';end if;
 if uploader is null or uploader!~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then raise exception using errcode='22023',message='File uploader is unavailable';end if;
 perform 1 from auth.users where id=uploader::uuid for key share;
 if not found or exists(select 1 from taskfold_private.account_removal_receipts where account_id=uploader::uuid and created_at>clock_timestamp()-interval '7 days') then
  raise exception using errcode='PT409',message='File uploader is removing their account';end if;
 return new;
end$$;
create trigger taskfold_guard_team_content_file before insert or update on taskfold_private.team_content_files for each row execute function taskfold_private.guard_team_content_file();
create function taskfold_private.guard_team_bucket_privacy() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='buckets' then
  if new.public and exists(select 1 from storage.objects o where o.bucket_id=old.id and taskfold_private.is_team_content_file(o.id)) then
   raise exception using errcode='PT409',message='A bucket containing team files must remain private';end if;
 elsif new.bucket_id is distinct from old.bucket_id and taskfold_private.is_team_content_file(old.id) then
  raise exception using errcode='PT409',message='Move team files through a reviewed transfer';
 end if;
 return new;
end$$;
create trigger taskfold_guard_team_bucket_privacy before update of public on storage.buckets for each row execute function taskfold_private.guard_team_bucket_privacy();
create trigger taskfold_guard_team_object_bucket before update of bucket_id on storage.objects for each row execute function taskfold_private.guard_team_bucket_privacy();
revoke all on function taskfold_private.guard_team_content_file(),taskfold_private.guard_team_bucket_privacy() from public,anon,authenticated,service_role;

create function taskfold_private.release_team_content_file() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into taskfold_private.team_content_file_removals(object_id,team_id,bucket_id,object_name)
 select old.object_id,p.team_id,o.bucket_id,o.name from taskfold_private.team_content_projects p join storage.objects o on o.id=old.object_id where p.project_id=old.project_id
 on conflict(object_id) do nothing;
 return old;
end$$;
create trigger taskfold_release_team_content_file before delete on taskfold_private.team_content_files for each row execute function taskfold_private.release_team_content_file();
revoke all on function taskfold_private.release_team_content_file() from public,anon,authenticated,service_role;

-- RLS does not run on an FK cascade. Close those old native/service side effects
-- as well, while permitting the explicit, permission-checked team delete scope.
create function taskfold_private.guard_closed_team_content() returns trigger
language plpgsql security definer set search_path='' as $$
declare p uuid; t uuid; row_id uuid;begin
 -- SQL operators and credential/account maintenance without a subject remain
 -- trusted. Native/API mutations carry a real subject and cannot set the scope.
 if auth.uid() is null then
  if tg_op='DELETE' then return old;else return new;end if;
 end if;
 if tg_op='DELETE' then row_id=old.id;else row_id=new.id;end if;
 if tg_table_name='projects' then p=row_id;
 elsif tg_op='DELETE' then p=old.project_id;else p=new.project_id;end if;
 select team_id into t from taskfold_private.team_content_projects where project_id=p;
 if t is null and tg_table_name='tasks' then
  select team_id into t from taskfold_private.team_content_tasks where task_id=row_id limit 1;
 end if;
 if t is null and tg_op='UPDATE' and tg_table_name<>'projects' then
  select team_id into t from taskfold_private.team_content_projects where project_id=old.project_id;
 end if;
 if t is not null and not exists(select 1 from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t) then
  raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;
create trigger aaa_taskfold_team_content_closed before insert or update or delete on public.tasks for each row execute function taskfold_private.guard_closed_team_content();
create trigger aaa_taskfold_team_content_closed before update or delete on public.projects for each row execute function taskfold_private.guard_closed_team_content();
create trigger aaa_taskfold_team_content_closed before insert or update or delete on public.sections for each row execute function taskfold_private.guard_closed_team_content();
revoke all on function taskfold_private.guard_closed_team_content() from public,anon,authenticated,service_role;
