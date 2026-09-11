-- Moving work to another project clears its old assignments, including nested work.
create or replace function taskfold_private.clear_assignee(items jsonb, person uuid) returns jsonb language plpgsql immutable set search_path = '' as $$
declare result jsonb := '[]'; item jsonb;
begin
 for item in select * from jsonb_array_elements(coalesce(items,'[]')) loop
   if person is null or item->>'assigned_to' = person::text then item := item - 'assigned_to'; end if;
   if jsonb_typeof(item->'subtasks') = 'array' then item := jsonb_set(item,'{subtasks}',taskfold_private.clear_assignee(item->'subtasks',person)); end if;
   result := result || jsonb_build_array(item);
 end loop;
 return result;
end $$;
revoke all on function taskfold_private.clear_assignee(jsonb,uuid) from public, anon, authenticated;

create or replace function taskfold_private.guard_task() returns trigger language plpgsql security definer set search_path = '' as $$
declare child jsonb; grandchild jsonb;
begin
 if tg_op = 'UPDATE' and new.user_id <> old.user_id then raise exception 'Task creator cannot be changed'; end if;
 if tg_op = 'UPDATE' and new.project_id is distinct from old.project_id then
   new.assigned_to := null; new.subtasks := taskfold_private.clear_assignee(new.subtasks,null);
 end if;
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
