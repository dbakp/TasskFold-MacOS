-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Read-only availability hint. Applying still repeats current write admission.
create function taskfold_private.child_steps_available(root_id uuid,expected_generation uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();r jsonb;t public.tasks;enabled boolean;begin
 perform taskfold_private.team_actor();
 r:=taskfold_private.read_child_task_structure(root_id,expected_generation);
 select * into t from public.tasks where id=root_id and task_generation is not distinct from expected_generation;
 select reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled and step_batches_enabled
 into enabled from taskfold_private.child_task_record_config where singleton;
 enabled:=coalesce(enabled,false) and not coalesce(t.completed,false) and not coalesce(t.is_heading,false) and jsonb_array_length(r->'records')<1000;
 if t.project_id is not null then
  enabled:=enabled and exists(select 1 from public.projects where id=t.project_id and not is_archived and not ancestor_archived);
 end if;
 if taskfold_private.is_team_content_task(t.id) or taskfold_private.is_team_content_project(t.project_id) then
  enabled:=enabled and coalesce(taskfold_private.team_project_role(a,t.project_id),'') in('manager','editor')
   and exists(select 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled)
   and exists(select 1 from taskfold_private.team_config tc where tc.singleton and tc.enabled);
 end if;
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',a,'task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,
  'structure_revision',r->'structure_revision','maximum_steps',12,'enabled',coalesce(enabled,false));
end$$;
create function public.taskfold_child_steps_available(_id uuid,_generation uuid) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.child_steps_available(_id,_generation)$$;
revoke all on function taskfold_private.child_steps_available(uuid,uuid),public.taskfold_child_steps_available(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_steps_available(uuid,uuid),public.taskfold_child_steps_available(uuid,uuid) to authenticated;

commit;
