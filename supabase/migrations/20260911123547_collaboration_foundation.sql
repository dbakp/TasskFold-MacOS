-- Backwards-compatible collaboration foundation. Existing JSON task data is retained.
create schema if not exists taskfold_private;
revoke all on schema taskfold_private from public, anon;
grant usage on schema taskfold_private to authenticated;

alter table public.tasks add column if not exists assigned_to uuid references auth.users(id) on delete set null;
create index if not exists tasks_assigned_to_idx on public.tasks(assigned_to) where assigned_to is not null;

-- Owners can create projects through the native offline queue as well as create_project().
drop policy if exists projects_no_direct_insert on public.projects;
create policy projects_insert_owner on public.projects for insert to authenticated with check (user_id = (select auth.uid()));
alter policy projects_update_access on public.projects using (public.has_project_access((select auth.uid()), id)) with check (public.has_project_access((select auth.uid()), id));

-- Project membership, not authorship, controls shared data after someone leaves.
alter policy "Users can view accessible tasks" on public.tasks using ((project_id is null and user_id = (select auth.uid())) or public.has_project_access((select auth.uid()), project_id));
alter policy "Users can update accessible tasks" on public.tasks using ((project_id is null and user_id = (select auth.uid())) or public.has_project_access((select auth.uid()), project_id)) with check ((project_id is null and user_id = (select auth.uid())) or public.has_project_access((select auth.uid()), project_id));
alter policy "Users can delete accessible tasks" on public.tasks using ((project_id is null and user_id = (select auth.uid())) or public.has_project_access((select auth.uid()), project_id));
alter policy "Users can view accessible sections" on public.sections using (public.has_project_access((select auth.uid()), project_id));
alter policy "Users can update accessible sections" on public.sections using (public.has_project_access((select auth.uid()), project_id)) with check (public.has_project_access((select auth.uid()), project_id));
alter policy "Users can delete accessible sections" on public.sections using (public.has_project_access((select auth.uid()), project_id));

-- Invitations can be accepted/declined, but never moved to another project or identity.
alter policy "Manage collaborations" on public.project_collaborators
 using (public.is_project_owner((select auth.uid()), project_id) or (user_id = (select auth.uid()) and status = 'pending'))
 with check (public.is_project_owner((select auth.uid()), project_id) or (user_id = (select auth.uid()) and status in ('accepted', 'declined')));
-- Link a new account's invitations without sending email or trusting user-editable metadata.
create or replace function taskfold_private.link_account_invitations() returns trigger language plpgsql security definer set search_path = '' as $$
begin
 -- The invitation guard permits linking only when invoked by this auth.users trigger.
 update public.project_collaborators set user_id = new.id where user_id is null and lower(invited_email) = lower(new.email);
 return new;
end $$;
-- The linking update needs a narrowly scoped exception in the guard (trigger depth, trusted auth row).
create or replace function taskfold_private.prepare_invitation() returns trigger language plpgsql security definer set search_path = '' as $$
begin
 if tg_op = 'UPDATE' and pg_trigger_depth() > 1 and old.user_id is null and new.user_id is not null
    and (to_jsonb(new) - 'user_id') = (to_jsonb(old) - 'user_id')
    and exists(select 1 from auth.users where id = new.user_id and lower(email) = lower(new.invited_email)) then return new; end if;
 if auth.uid() is null then raise exception 'Sign in to manage invitations'; end if;
 if tg_op = 'INSERT' then
   if not public.is_project_owner(auth.uid(), new.project_id) or new.invited_by <> auth.uid() or new.role <> 'collaborator' or new.status <> 'pending' then raise exception 'Only the project owner can invite collaborators'; end if;
   new.invited_email := lower(trim(new.invited_email));
   select id into new.user_id from auth.users where lower(email) = new.invited_email;
   if new.user_id = auth.uid() then raise exception 'You already own this project'; end if;
 else
   if new.project_id <> old.project_id or new.invited_by <> old.invited_by or new.role <> old.role or new.invited_email is distinct from old.invited_email or new.user_id is distinct from old.user_id then raise exception 'Invitation details cannot be changed'; end if;
   if new.status = 'accepted' and old.status <> 'accepted' then new.accepted_at := now(); end if;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.prepare_invitation() from public, anon, authenticated;
create trigger taskfold_prepare_invitation before insert or update on public.project_collaborators for each row execute function taskfold_private.prepare_invitation();
revoke all on function taskfold_private.link_account_invitations() from public, anon, authenticated;
create trigger taskfold_link_account_invitations after insert on auth.users for each row execute function taskfold_private.link_account_invitations();

-- Minimal member directory; profile preferences and email stay private.
create or replace function public.taskfold_project_members(_project_id uuid)
returns table(user_id uuid, display_name text, avatar_url text) language sql stable security definer set search_path = '' as $$
 select p.user_id, coalesce(nullif(pr.display_name, ''), 'Project owner'), pr.avatar_url
 from public.projects p left join public.profiles pr on pr.user_id = p.user_id
 where p.id = _project_id and auth.uid() is not null and public.has_project_access(auth.uid(), _project_id)
 union
 select c.user_id, coalesce(nullif(pr.display_name, ''), 'Collaborator'), pr.avatar_url
 from public.project_collaborators c left join public.profiles pr on pr.user_id = c.user_id
 where c.project_id = _project_id and c.status = 'accepted' and c.user_id is not null and auth.uid() is not null and public.has_project_access(auth.uid(), _project_id)
$$;
revoke all on function public.taskfold_project_members(uuid) from public, anon;
grant execute on function public.taskfold_project_members(uuid) to authenticated;

-- Three-way merge. Different fields and independently identified collection items commute.
-- A same-field conflict stops the queue rather than silently losing either edit.
create or replace function taskfold_private.merge_edit(b jsonb, d jsonb, c jsonb) returns jsonb language plpgsql immutable set search_path = '' as $$
declare r jsonb; k text; v jsonb; bv jsonb; dv jsonb; cv jsonb;
begin
 if d is not distinct from b then return c; end if;
 if c is not distinct from b or c is not distinct from d then return d; end if;
 if jsonb_typeof(b) = 'object' and jsonb_typeof(d) = 'object' and jsonb_typeof(c) = 'object' then
   r := c;
   for k in select jsonb_object_keys(b || d) loop
     if d->k is distinct from b->k then
       v := taskfold_private.merge_edit(b->k, d->k, c->k);
       if v is null then r := r - k; else r := jsonb_set(r, array[k], v); end if;
     end if;
   end loop;
   return r;
 end if;
 if jsonb_typeof(b) = 'array' and jsonb_typeof(d) = 'array' and jsonb_typeof(c) = 'array'
 and not exists(select 1 from jsonb_array_elements(b || d || c) x where jsonb_typeof(x) <> 'object' or coalesce(x->>'id', '') = '')
 and not exists(select 1 from (values(b),(d),(c)) q(a) where jsonb_array_length(a) <> (select count(distinct x->>'id') from jsonb_array_elements(a) x)) then
   r := '[]';
   for cv in select * from jsonb_array_elements(c) loop
     select x into bv from jsonb_array_elements(b) x where x->>'id' = cv->>'id';
     select x into dv from jsonb_array_elements(d) x where x->>'id' = cv->>'id';
     if bv is null then
       if dv is not null and dv <> cv then raise exception 'TASKFOLD_CONFLICT: An item changed on another device. Review the conflicting change.'; end if;
       r := r || jsonb_build_array(cv);
     else
       v := taskfold_private.merge_edit(bv, dv, cv);
       if v is not null then r := r || jsonb_build_array(v); end if;
     end if;
   end loop;
   for dv in select * from jsonb_array_elements(d) loop
     select x into bv from jsonb_array_elements(b) x where x->>'id' = dv->>'id';
     if not exists(select 1 from jsonb_array_elements(c) x where x->>'id' = dv->>'id') then
       if bv is null then r := r || jsonb_build_array(dv);
       elsif bv <> dv then raise exception 'TASKFOLD_CONFLICT: This item was deleted on another device. Your edit is saved locally.'; end if;
     end if;
   end loop;
   return r;
 end if;
 raise exception 'TASKFOLD_CONFLICT: The same field changed on another device. Your edit is saved locally.';
end $$;
revoke all on function taskfold_private.merge_edit(jsonb,jsonb,jsonb) from public, anon;
grant execute on function taskfold_private.merge_edit(jsonb,jsonb,jsonb) to authenticated;

create or replace function public.taskfold_patch_task(_id uuid, _base jsonb, _changes jsonb)
returns public.tasks language plpgsql security invoker set search_path = '' as $$
declare t public.tasks; merged jsonb; k text; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 merged := to_jsonb(t);
 for k in select jsonb_object_keys(_changes) loop
   if not k = any(allowed) then raise exception 'This task field cannot be edited'; end if;
   if not _base ? k then raise exception 'An edit baseline is required'; end if;
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(_base->k, _changes->k, merged->k), 'null'));
 end loop;
 t := jsonb_populate_record(t, merged);
 update public.tasks set title=t.title,description=t.description,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to where id=_id returning * into t;
 return t;
end $$;
revoke all on function public.taskfold_patch_task(uuid,jsonb,jsonb) from public, anon;
grant execute on function public.taskfold_patch_task(uuid,jsonb,jsonb) to authenticated;

-- Guard direct REST writes too: assignments may only name current project members.
create or replace function taskfold_private.check_task_assignment(a text, project uuid, owner uuid) returns void language plpgsql stable security definer set search_path = '' as $$
begin
 if a is null or a = '' then return; end if;
 if (project is null and a::uuid <> owner) or (project is not null and not public.has_project_access(a::uuid, project)) then raise exception 'Assign tasks only to current project members'; end if;
end $$;
revoke all on function taskfold_private.check_task_assignment(text,uuid,uuid) from public, anon, authenticated;
create or replace function taskfold_private.guard_task() returns trigger language plpgsql security definer set search_path = '' as $$
declare child jsonb; grandchild jsonb;
begin
 if tg_op = 'UPDATE' and new.user_id <> old.user_id then raise exception 'Task creator cannot be changed'; end if;
 if tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to or new.project_id is distinct from old.project_id then
   perform taskfold_private.check_task_assignment(new.assigned_to::text,new.project_id,new.user_id);
 end if;
 if tg_op = 'INSERT' or new.subtasks is distinct from old.subtasks or new.project_id is distinct from old.project_id then
   for child in select * from jsonb_array_elements(coalesce(new.subtasks,'[]')) loop
     perform taskfold_private.check_task_assignment(child->>'assigned_to',new.project_id,new.user_id);
     for grandchild in select * from jsonb_array_elements(coalesce(child->'subtasks','[]')) loop
       perform taskfold_private.check_task_assignment(grandchild->>'assigned_to',new.project_id,new.user_id);
     end loop;
   end loop;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_task() from public, anon, authenticated;
create trigger taskfold_guard_task before insert or update on public.tasks for each row execute function taskfold_private.guard_task();
create or replace function taskfold_private.guard_project_owner() returns trigger language plpgsql set search_path = '' as $$
begin
 if new.user_id <> old.user_id then raise exception 'Project ownership cannot be changed'; end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_project_owner() from public, anon, authenticated;
create trigger taskfold_guard_project_owner before update on public.projects for each row execute function taskfold_private.guard_project_owner();
