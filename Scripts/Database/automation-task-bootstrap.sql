-- Local dependency extension to account-removal-bootstrap.sql, not hosted schema.
-- Fields mirror the inspected live tasks contract; real migrations install the
-- generation, completion and guarded-edit routines after this dependency schema.
alter table public.tasks alter column user_id set not null,alter column title set not null;
alter table public.tasks add column description text,add column completed boolean not null default false,
 add column priority int not null default 4,add column due_date date,add column due_time time,
 add column section_id uuid,add column labels text[] default '{}',add column subtasks jsonb default '[]',
 add column reminders text[] default '{}',add column attachments jsonb default '[]',add column comments jsonb default '[]',
 add column created_at timestamptz not null default now(),add column completed_at timestamptz,
 add column recurrence_pattern jsonb,add column is_recurring boolean not null default false,
 add column recurrence_end_date date,add column notification_sent_at timestamptz,add column assigned_to uuid,
 add column deadline_date date,add column duration_minutes int,add column time_zone text,
 add column reminder_specs jsonb not null default '[]',add column source_metadata jsonb not null default '{}',add column scheduled_at timestamptz;
create function public.has_project_access(_user_id uuid,_project_id uuid) returns boolean
language sql stable security definer set search_path='public' as $$
 select exists(select 1 from public.projects where id=_project_id and user_id=_user_id
 union select 1 from public.project_collaborators where project_id=_project_id and user_id=_user_id and status='accepted')
$$;
alter table public.tasks enable row level security;
-- Match the distinct live INSERT policy: project access does not let a new
-- native row impersonate its original series creator.
create policy fixture_automation_task_select on public.tasks for select to authenticated
 using((project_id is null and user_id=auth.uid()) or public.has_project_access(auth.uid(),project_id));
create policy fixture_automation_task_update on public.tasks for update to authenticated
 using((project_id is null and user_id=auth.uid()) or public.has_project_access(auth.uid(),project_id))
 with check((project_id is null and user_id=auth.uid()) or public.has_project_access(auth.uid(),project_id));
create policy fixture_automation_task_delete on public.tasks for delete to authenticated
 using((project_id is null and user_id=auth.uid()) or public.has_project_access(auth.uid(),project_id));
create policy fixture_automation_task_insert on public.tasks for insert to authenticated
 with check(user_id=auth.uid() and (project_id is null or public.has_project_access(auth.uid(),project_id)));
-- Existing live schema USAGE is independent of per-helper EXECUTE grants.
grant usage on schema taskfold_private to authenticated,service_role;
grant select,insert,update,delete on public.tasks,public.projects,public.project_collaborators to authenticated;

-- Read-only snapshot of the pre-managed live merge_edit function, inspected
-- 23 October. Newer guarded patch/deletion implementations load from actual
-- repository migrations, not test doubles. No live task contents were copied.
create function taskfold_private.merge_edit(b jsonb,d jsonb,c jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare r jsonb;k text;v jsonb;bv jsonb;dv jsonb;cv jsonb;
begin
 if d is not distinct from b then return c;end if;
 if c is not distinct from b or c is not distinct from d then return d;end if;
 if jsonb_typeof(b)='object' and jsonb_typeof(d)='object' and jsonb_typeof(c)='object' then
  r:=c;
  for k in select jsonb_object_keys(b||d) loop
   if d->k is distinct from b->k then
    v:=taskfold_private.merge_edit(b->k,d->k,c->k);
    if v is null then r:=r-k;else r:=jsonb_set(r,array[k],v);end if;
   end if;
  end loop;return r;
 end if;
 if jsonb_typeof(b)='array' and jsonb_typeof(d)='array' and jsonb_typeof(c)='array'
 and not exists(select 1 from jsonb_array_elements(b||d||c) x where jsonb_typeof(x)<>'object' or coalesce(x->>'id','')='')
 and not exists(select 1 from (values(b),(d),(c)) q(a) where jsonb_array_length(a)<>(select count(distinct x->>'id') from jsonb_array_elements(a) x)) then
  r:='[]';
  for cv in select * from jsonb_array_elements(c) loop
   select x into bv from jsonb_array_elements(b) x where x->>'id'=cv->>'id';
   select x into dv from jsonb_array_elements(d) x where x->>'id'=cv->>'id';
   if bv is null then
    if dv is not null and dv<>cv then raise exception 'TASKFOLD_CONFLICT: An item changed on another device. Review the conflicting change.';end if;
    r:=r||jsonb_build_array(cv);
   else
    v:=taskfold_private.merge_edit(bv,dv,cv);if v is not null then r:=r||jsonb_build_array(v);end if;
   end if;
  end loop;
  for dv in select * from jsonb_array_elements(d) loop
   select x into bv from jsonb_array_elements(b) x where x->>'id'=dv->>'id';
   if not exists(select 1 from jsonb_array_elements(c) x where x->>'id'=dv->>'id') then
    if bv is null then r:=r||jsonb_build_array(dv);
    elsif bv<>dv then raise exception 'TASKFOLD_CONFLICT: This item was deleted on another device. Your edit is saved locally.';end if;
   end if;
  end loop;return r;
 end if;
 raise exception 'TASKFOLD_CONFLICT: The same field changed on another device. Your edit is saved locally.';
end $$;
