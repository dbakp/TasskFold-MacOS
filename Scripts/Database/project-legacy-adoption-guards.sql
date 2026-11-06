-- Read-only function/trigger definitions inspected from Taskfold on 25 Oct 2026.
-- Dependency snapshot for the owned synthetic fixture; no task/user data copied.
CREATE OR REPLACE FUNCTION taskfold_private.clear_departed_assignments()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if old.status = 'accepted' and old.user_id is not null and (tg_op='DELETE' or new.status <> 'accepted') then
   -- Another accepted membership, if present, still grants access.
   if not public.has_project_access(old.user_id,old.project_id) then
     update public.tasks set
       assigned_to = case when assigned_to=old.user_id then null else assigned_to end,
       subtasks = taskfold_private.clear_assignee(subtasks,old.user_id)
     where project_id=old.project_id and (assigned_to=old.user_id or subtasks::text like '%' || old.user_id::text || '%');
   end if;
 end if;
 return null;
end $function$
;
CREATE TRIGGER taskfold_clear_departed_assignments AFTER DELETE OR UPDATE OF status ON public.project_collaborators FOR EACH ROW EXECUTE FUNCTION taskfold_private.clear_departed_assignments();
CREATE OR REPLACE FUNCTION taskfold_private.prepare_invitation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if tg_op='UPDATE' and pg_trigger_depth()>1 then
  if old.user_id is null and new.user_id is not null
   and (to_jsonb(new)-'user_id')=(to_jsonb(old)-'user_id')
   and exists(select 1 from auth.users where id=new.user_id and lower(email)=lower(new.invited_email)) then return new; end if;
  if old.invited_by is not null and new.invited_by is null
   and (to_jsonb(new)-'invited_by')=(to_jsonb(old)-'invited_by')
   and (not exists(select 1 from auth.users where id=old.invited_by)
        or not exists(select 1 from public.profiles where user_id=old.invited_by)) then return new; end if;
 end if;
 if auth.uid() is null then raise exception 'Sign in to manage invitations'; end if;
 if tg_op='INSERT' then
  if not public.is_project_owner(auth.uid(),new.project_id) or new.invited_by is distinct from auth.uid()
   or new.role is distinct from 'collaborator' or new.status is distinct from 'pending' then
   raise exception 'Only the project owner can invite collaborators'; end if;
  new.invited_email:=lower(trim(new.invited_email));
  select id into new.user_id from auth.users where lower(email)=new.invited_email;
  if new.user_id=auth.uid() then raise exception 'You already own this project'; end if;
 else
  if new.project_id is distinct from old.project_id or new.invited_by is distinct from old.invited_by
   or new.role is distinct from old.role or new.invited_email is distinct from old.invited_email
   or new.user_id is distinct from old.user_id then raise exception 'Invitation details cannot be changed'; end if;
  if new.status='accepted' and old.status<>'accepted' then new.accepted_at:=now(); end if;
 end if;
 return new;
end $function$
;

