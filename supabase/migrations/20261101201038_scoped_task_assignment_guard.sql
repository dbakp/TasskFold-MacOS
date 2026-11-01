-- Scoped assignment deliberately uses the destination project as a precondition.
-- Keep the existing task editor's authorization, locking, generation and merge
-- rules. Only the explicit no-op project/assignment pair gains this strict fence.
do $migration$
declare
 definition text;
 anchor constant text := 'merged := to_jsonb(t);';
 guard_sql constant text := $guard$
 -- TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1
 if _changes ?& array['assigned_to','project_id'] and _base ? 'project_id'
    and (_changes->>'project_id')::uuid is not distinct from (_base->>'project_id')::uuid
    then
  if t.project_id is distinct from (_base->>'project_id')::uuid then
   raise exception using errcode='PT409',message='This task moved. Reopen it before applying this saved assignment';
  end if;
  if t.assigned_to is distinct from (_base->>'assigned_to')::uuid
     and t.assigned_to is distinct from (_changes->>'assigned_to')::uuid then
   raise exception using errcode='PT409',message='The assignment changed. Review the current assignee before applying this choice';
  end if;
 end if;
 $guard$;
begin
 definition := pg_catalog.pg_get_functiondef('public.taskfold_patch_task(uuid,jsonb,jsonb)'::regprocedure);
 if pg_catalog.strpos(definition,'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1') > 0 then return;end if;
 if (pg_catalog.length(definition)-pg_catalog.length(pg_catalog.replace(definition,anchor,''))) / pg_catalog.length(anchor) <> 1 then
  raise exception using errcode='55000',message='The scoped assignment guard requires the current guarded task editor';
 end if;
 execute pg_catalog.replace(definition,anchor,guard_sql || anchor);
end;
$migration$;

-- A separate invoker endpoint prevents new clients from silently falling back
-- to an older server whose generic merge treats a no-op project as untouched.
create or replace function public.taskfold_assign_task_scoped(_id uuid,_base jsonb,_changes jsonb)
returns public.tasks language plpgsql security invoker set search_path='' as $$
begin
 if jsonb_typeof(_base) is distinct from 'object' or jsonb_typeof(_changes) is distinct from 'object'
    or not (_base ?& array['task_generation','project_id','assigned_to'])
    or not (_changes ?& array['project_id','assigned_to'])
    or jsonb_typeof(_base->'project_id') not in('null','string')
    or jsonb_typeof(_changes->'project_id') not in('null','string')
    or jsonb_typeof(_changes->'assigned_to') not in('null','string') then
  raise exception using errcode='22023',message='Review this saved assignment and its original project';
 end if;
 if (_changes->>'project_id')::uuid is distinct from (_base->>'project_id')::uuid then
  raise exception using errcode='22023',message='Choose a project move before assigning this task';
 end if;
 -- Fail closed if a later service migration replaced the guarded merge body.
 if not exists(select 1 from pg_catalog.pg_proc p
               where p.oid=pg_catalog.to_regprocedure('public.taskfold_patch_task(uuid,jsonb,jsonb)')
                 and pg_catalog.strpos(p.prosrc,'TASKFOLD_SCOPED_ASSIGNMENT_GUARD_V1') > 0) then
  raise exception using errcode='PT503',message='Saved assignment support needs a server update';
 end if;
 return public.taskfold_patch_task(_id,_base,_changes);
end;
$$;
revoke all on function public.taskfold_assign_task_scoped(uuid,jsonb,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.taskfold_assign_task_scoped(uuid,jsonb,jsonb) to authenticated;
notify pgrst,'reload schema';
