-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Read-only recovery, independent of repair/migration authoring switches.
-- Original export authorization (including every archived history row) remains
-- authoritative. No receipt, task, record, projection or archive is changed.
create function taskfold_private.child_repair_comparison_current(request uuid,archive uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();r taskfold_private.child_task_repairs;t public.tasks;team uuid;reply jsonb;
begin
 perform taskfold_private.team_actor();
 select * into r from taskfold_private.child_task_repairs where actor_id=a and request_id=request and archive_id=archive and state='applied';
 if not found or not exists(select 1 from taskfold_private.child_task_repair_originals o where o.id=archive and o.request_id=request and o.actor_id=a
  and o.task_id=r.task_id and o.task_generation is not distinct from r.task_generation and o.project_id is not distinct from r.project_id
  and o.team_id is not distinct from r.workspace_id and o.digest=r.archive_digest and o.bytes=r.archive_bytes) then
  raise exception using errcode='42501',message='This saved original is unavailable';end if;
 t:=taskfold_private.child_adoption_root(r.task_id,r.task_generation,false);
 select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
 if t.project_id is distinct from r.project_id or team is distinct from r.workspace_id then
  raise exception using errcode='42501',message='This original belongs to another task context';end if;
 reply:=taskfold_private.child_adoption_snapshot(t);
 perform taskfold_private.team_actor();return reply;
end$$;
create function public.taskfold_compare_child_repair_original(_request uuid,_archive uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare original jsonb;current_read jsonb;
begin
 -- The existing invoker export wrapper rechecks current task AND history RLS.
 -- Its root share lock also prevents a concurrent writer from mixing the two
 -- structures during this transaction. This is never mutation admission.
 original:=public.taskfold_child_repair_original(_request,_archive);
 current_read:=taskfold_private.child_repair_comparison_current(_request,_archive);
 if not exists(select 1 from public.tasks t where t.id=(current_read->>'task_id')::uuid
  and t.task_generation is not distinct from (current_read->>'task_generation')::uuid
  and t.project_id is not distinct from (current_read->>'project_id')::uuid) then
  raise exception using errcode='42501',message='Current task access changed';end if;
 return jsonb_build_object('protocol',1,'account',auth.uid(),'original',original,'current',current_read);
end$$;
revoke all on function taskfold_private.child_repair_comparison_current(uuid,uuid),public.taskfold_compare_child_repair_original(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_repair_comparison_current(uuid,uuid),public.taskfold_compare_child_repair_original(uuid,uuid) to authenticated;

commit;
