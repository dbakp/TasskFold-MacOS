-- Read-only custody review for an active older-structure restoration.
-- This does not end restoration, grant editing authority or relax ordinary copy access.
create function taskfold_private.review_restored_child_copies(b jsonb,restore_actor uuid,restore_key uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid(); t public.tasks; s taskfold_private.child_repair_restorations;
 p taskfold_private.child_repair_restore_payloads; base jsonb; snapshot jsonb; projection jsonb; records jsonb;
 materialized boolean:=false; tree jsonb; kind text; summaries jsonb; bundle jsonb; binding jsonb; files jsonb;
begin
 perform taskfold_private.team_actor();
 -- The existing read validates the complete, fresh caller/task/project identity,
 -- review gate, bounded rows and root source before any retained content is read.
 t:=taskfold_private.child_restore_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,(b->>'project_id')::uuid,(b->>'workspace_id')::uuid);
 -- Lock the current root before producing either comparison or binding, so a
 -- concurrent ordinary note edit cannot mix two snapshots in this response.
 base:=taskfold_private.review_child_copies(b);
 if b->'workspace_id'='null'::jsonb then
  if t.user_id is distinct from actor then raise exception using errcode='42501',message='The storage owner must review this retained version';end if;
 else
  perform 1 from taskfold_private.teams where id=(b->>'workspace_id')::uuid and state<>'deleted' for share nowait;
  if not found then raise exception using errcode='42501',message='This workspace is unavailable';end if;
  perform 1 from taskfold_private.team_members where team_id=(b->>'workspace_id')::uuid and user_id=actor for share nowait;
  if not found or coalesce(taskfold_private.team_role((b->>'workspace_id')::uuid,actor),'') not in('owner','admin') then raise exception using errcode='42501',message='Workspace administration is required to review this retained version';end if;
 end if;
 select * into s from taskfold_private.child_repair_restorations where actor_id=restore_actor and restore_id=restore_key for share nowait;
 if not found or s.phase<>'restored' then raise exception using errcode='PT409',message='Review the latest restoration decision';end if;
 if s.task_id<>t.id or s.task_generation is distinct from t.task_generation or s.project_id is distinct from t.project_id
  or s.workspace_id is distinct from (b->>'workspace_id')::uuid or s.user_id<>t.user_id then raise exception using errcode='42501',message='This retained version belongs to another task context';end if;
 select * into p from taskfold_private.child_repair_restore_payloads where actor_id=s.actor_id and restore_id=s.restore_id for share nowait;
 if not found then raise exception using errcode='PT409',message='This retained version is unavailable';end if;
 snapshot:=taskfold_private.child_restore_snapshot(t);projection:=snapshot->'projection';records:=snapshot->'records';
 if snapshot->'tree' is distinct from p.payload->'target' or snapshot->'sql_null' is distinct from p.payload->'target_sql_null'
  or snapshot->'authority'<>'null'::jsonb or projection='null'::jsonb or projection->'task_generation' is distinct from b->'task_generation' then
  raise exception using errcode='PT409',message='Review the current restored structure again';end if;
 perform taskfold_private.validate_child_restore_files(p.payload->'files');
 files:=taskfold_private.team_task_file_inventory(t);perform taskfold_private.validate_child_restore_files(files);
 kind:=coalesce(p.payload->'before'->'authority'->>'root_kind',case when projection->'source_tree'='null'::jsonb then 'null' else 'array' end);
 begin tree:=taskfold_private.materialize_child_task_records(t.id,kind);materialized:=true;
 exception when sqlstate 'PT409' or sqlstate '54000' then tree:='null'::jsonb;end;
 if octet_length(coalesce(tree,'null'::jsonb)::text)>2000000 then raise exception using errcode='PT413',message='These retained records need a larger-work review';end if;
 summaries:=jsonb_build_array(base->'copies'->0,taskfold_private.child_copy_summary('projection',projection->'source_tree','visible'),
  case when materialized then taskfold_private.child_copy_summary('records',tree,'visible') else jsonb_build_object('id','records','state','review','issue','record_shape','node_count',null,'max_depth',null,'bytes',octet_length(records::text)) end);
 bundle:=(base->'export_bundle')||jsonb_build_object('projection',projection,'records',records,'authority',null,'omitted','[]'::jsonb);
 if octet_length(bundle::text)>8000000 then raise exception using errcode='PT413',message='These retained copies need a larger-work export';end if;
 binding:=jsonb_build_object('actor_id',s.actor_id,'restore_id',s.restore_id,'revision',s.revision,'digest',taskfold_private.child_restore_digest(jsonb_build_object('restoration',to_jsonb(s),'payload',p.payload,'current',snapshot,'root',to_jsonb(t),'files',files)));
 base:=base||jsonb_build_object('state',case when materialized and snapshot->'tree'=projection->'source_tree' and snapshot->'tree'=tree then 'aligned' else 'different' end,'authoritative_source','task','copies',summaries,'projection_tree',projection->'source_tree','record_tree',coalesce(tree,'null'::jsonb),'export_bundle',bundle);
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'restoration',binding,'copies',base,'__history_counts',taskfold_private.child_restore_history_counts(t.id));
end$$;
create function public.taskfold_review_restored_child_copies(_body jsonb,_actor uuid,_restore uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 reply:=taskfold_private.review_restored_child_copies(_body,_actor,_restore);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid)
  or (reply->'__history_counts'->>'root')::bigint<>(select count(*) from public.task_activity where task_id=(_body->>'task_id')::uuid)
  or (reply->'__history_counts'->>'child')::bigint<>(select count(*) from public.task_node_activity where task_id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='Current task or history access changed';end if;
 return reply-'__history_counts';
end$$;
revoke all on function taskfold_private.review_restored_child_copies(jsonb,uuid,uuid),public.taskfold_review_restored_child_copies(jsonb,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.review_restored_child_copies(jsonb,uuid,uuid),public.taskfold_review_restored_child_copies(jsonb,uuid,uuid) to authenticated;
