-- Read-only hosted function definitions inspected 24 October 2026.
-- Dependency fixture only: no live records, secrets or runtime writes copied.
CREATE OR REPLACE FUNCTION taskfold_private.check_task_assignment(a text, project uuid, owner uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if a is null or a = '' then return; end if;
 if (project is null and a::uuid <> owner) or (project is not null and not public.has_project_access(a::uuid, project)) then raise exception 'Assign tasks only to current project members'; end if;
end $function$;

CREATE OR REPLACE FUNCTION taskfold_private.clear_assignee(items jsonb, person uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare result jsonb := '[]'; item jsonb;
begin
 for item in select * from jsonb_array_elements(coalesce(items,'[]')) loop
   if person is null or item->>'assigned_to' = person::text then item := item - 'assigned_to'; end if;
   if jsonb_typeof(item->'subtasks') = 'array' then item := jsonb_set(item,'{subtasks}',taskfold_private.clear_assignee(item->'subtasks',person)); end if;
   result := result || jsonb_build_array(item);
 end loop;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION taskfold_private.guard_task()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

create trigger taskfold_guard_task before insert or update on public.tasks for each row execute function taskfold_private.guard_task();
