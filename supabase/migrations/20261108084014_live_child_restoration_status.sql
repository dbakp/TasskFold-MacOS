-- Contentless, live recovery state. Immutable decision receipts are unchanged.
create function taskfold_private.child_restore_status(b jsonb,restore_actor uuid,restore_key uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();t public.tasks;s taskfold_private.child_repair_restorations;current boolean:=false;retained boolean:=false;begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>2048
  or not(b ?& array['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest'])
  or (b-array['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest'])<>'{}'::jsonb
  or b->'protocol'<>'1'::jsonb or b->'account' is distinct from to_jsonb(actor)
  or jsonb_typeof(b->'archive_digest')<>'string' or not((b->>'archive_digest')~'^[a-f0-9]{64}$')
  or restore_actor is null or restore_key is null then raise exception using errcode='22023',message='Choose a saved restoration';end if;
 t:=taskfold_private.child_restore_root(taskfold_private.team_uuid(b,'task_id'),case when b->'task_generation'='null'::jsonb then null else taskfold_private.team_uuid(b,'task_generation') end,case when b->'project_id'='null'::jsonb then null else taskfold_private.team_uuid(b,'project_id') end,case when b->'workspace_id'='null'::jsonb then null else taskfold_private.team_uuid(b,'workspace_id') end);
 -- Lock root first, like Restore and adoption. No mixed transition is reported.
 select * into s from taskfold_private.child_repair_restorations where actor_id=restore_actor and restore_id=restore_key for share nowait;
 if not found or s.task_id<>t.id or s.task_generation is distinct from t.task_generation or s.project_id is distinct from t.project_id
  or s.workspace_id is distinct from (b->>'workspace_id')::uuid or s.user_id<>t.user_id
  or s.repair_request_id is distinct from taskfold_private.team_uuid(b,'repair_request_id') or s.archive_id is distinct from taskfold_private.team_uuid(b,'archive_id')
  or s.archive_digest is distinct from b->>'archive_digest' then raise exception using errcode='42501',message='This restoration is unavailable in the current task context';end if;
 -- An actor can check their known decision. Another custodian needs current
 -- storage-owner or shared-admin authority; the reference grants no content.
 if restore_actor<>actor then perform taskfold_private.require_child_adoption_custodian(t,s.workspace_id);end if;
 if s.phase in('restored','undone') and exists(select 1 from taskfold_private.child_repair_restore_payloads where actor_id=s.actor_id and restore_id=s.restore_id)
  and not exists(select 1 from taskfold_private.child_repair_restorations x where x.task_id=s.task_id and x.phase='restored' and (x.actor_id,x.restore_id)<>(s.actor_id,s.restore_id)) then
  begin current:=taskfold_private.child_restore_digest(taskfold_private.child_restore_snapshot(t))=s.current_digest;
  exception when sqlstate 'PT413' then current:=false;end;
 end if;
 if s.phase='adopted' then retained:=exists(select 1 from taskfold_private.child_task_repair_originals where id=s.adopted_archive_id and actor_id=s.adopted_actor_id and request_id=s.adopted_request_id);end if;
 perform taskfold_private.team_actor();
 return b||jsonb_build_object('actor_id',s.actor_id,'restore_id',s.restore_id,'phase',s.phase,'revision',s.revision,'structure_current',current,'newer_retained',retained,
  '__history_counts',taskfold_private.child_restore_history_counts(t.id));
end$$;
create function public.taskfold_child_restore_status(_body jsonb,_actor uuid,_restore uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 reply:=taskfold_private.child_restore_status(_body,_actor,_restore);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid)
  or (reply->'__history_counts'->>'root')::bigint<>(select count(*) from public.task_activity where task_id=(_body->>'task_id')::uuid)
  or (reply->'__history_counts'->>'child')::bigint<>(select count(*) from public.task_node_activity where task_id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='Current task or history access changed';end if;
 return reply-'__history_counts';
end$$;
revoke all on function taskfold_private.child_restore_status(jsonb,uuid,uuid),public.taskfold_child_restore_status(jsonb,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_restore_status(jsonb,uuid,uuid),public.taskfold_child_restore_status(jsonb,uuid,uuid) to authenticated;
