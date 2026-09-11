-- Leaving/revoking a project must not leave work assigned to somebody who cannot see it.
create or replace function taskfold_private.clear_assignee(items jsonb, person uuid) returns jsonb language plpgsql immutable set search_path = '' as $$
declare result jsonb := '[]'; item jsonb;
begin
 for item in select * from jsonb_array_elements(coalesce(items,'[]')) loop
   if item->>'assigned_to' = person::text then item := item - 'assigned_to'; end if;
   if jsonb_typeof(item->'subtasks') = 'array' then item := jsonb_set(item,'{subtasks}',taskfold_private.clear_assignee(item->'subtasks',person)); end if;
   result := result || jsonb_build_array(item);
 end loop;
 return result;
end $$;
revoke all on function taskfold_private.clear_assignee(jsonb,uuid) from public, anon, authenticated;
create or replace function taskfold_private.clear_departed_assignments() returns trigger language plpgsql security definer set search_path = '' as $$
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
end $$;
revoke all on function taskfold_private.clear_departed_assignments() from public, anon, authenticated;
create trigger taskfold_clear_departed_assignments after delete or update of status on public.project_collaborators for each row execute function taskfold_private.clear_departed_assignments();
