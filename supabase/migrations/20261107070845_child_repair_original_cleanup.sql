-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Explicit retention cleanup is separate from task repair authoring and stays off.
alter table taskfold_private.child_task_record_config add column archive_cleanup_enabled boolean not null default false;

-- This operation never reads/returns archived content or changes current work.
-- Personal copies belong to their storage owner, shared copies to their team.
-- The browser remains actor-bound; this is not a departed-editor admin browser.
create function taskfold_private.child_repair_original_cleanup(operation text,request uuid,archive uuid,expected_digest text,expected_bytes integer) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();r taskfold_private.child_task_repairs;o record;enabled boolean;status text;
begin
 perform taskfold_private.team_actor();
 if operation is null or operation not in('review','remove') or request is null or archive is null
 or expected_digest is null or expected_digest !~ '^[a-f0-9]{64}$' or expected_bytes is null or expected_bytes not between 1 and 8000000 then
  raise exception using errcode='22023',message='Review one saved original';
 end if;
 select * into r from taskfold_private.child_task_repairs where actor_id=a and request_id=request and archive_id=archive and state='applied' for share nowait;
 if not found then raise exception using errcode='42501',message='This saved original is unavailable';end if;
 if r.archive_digest<>expected_digest or r.archive_bytes<>expected_bytes then raise exception using errcode='PT409',message='This original changed; refresh its confirmation';end if;
 select archive_cleanup_enabled into enabled from taskfold_private.child_task_record_config where singleton for share nowait;
 enabled:=coalesce(enabled,false);
 -- Retrying the same immutable archive identity is harmless, including after
 -- a lost reply or a gate pause. Never retarget another original for this task.
 select id,actor_id,owner_id,team_id,task_id,task_generation,project_id,request_id,digest,bytes into o from taskfold_private.child_task_repair_originals where id=archive;
 if not found then status:='unavailable';
 else
  if o.actor_id is distinct from a or o.request_id<>r.request_id or o.task_id<>r.task_id or o.task_generation is distinct from r.task_generation
  or o.project_id is distinct from r.project_id or o.team_id is distinct from r.workspace_id or o.digest<>expected_digest or o.bytes<>expected_bytes then
   raise exception using errcode='PT409',message='This original needs custody review';
  end if;
  if o.team_id is null then
   if o.owner_id is distinct from a then raise exception using errcode='42501',message='Only the storage owner can remove this original';end if;
  else
   perform 1 from taskfold_private.teams where id=o.team_id and state<>'deleted' for share nowait;
   if not found then raise exception using errcode='42501',message='This workspace is unavailable';end if;
   perform 1 from taskfold_private.team_members where team_id=o.team_id and user_id=a for share nowait;
   if not found or coalesce(taskfold_private.team_role(o.team_id,a),'') not in('owner','admin') then
    raise exception using errcode='42501',message='Workspace administration is required to remove this original';
   end if;
  end if;
  if operation='remove' and not enabled then raise exception using errcode='PT503',message='Original cleanup is paused';end if;
  -- Lock after custody locks, matching team deletion's team -> original order.
  perform 1 from taskfold_private.child_task_repair_originals x where x.id=archive and x.actor_id=a and x.request_id=request
   and x.task_id=r.task_id and x.task_generation is not distinct from r.task_generation and x.project_id is not distinct from r.project_id
   and x.team_id is not distinct from o.team_id and x.owner_id is not distinct from o.owner_id and x.digest=expected_digest and x.bytes=expected_bytes for update nowait;
  if not found then
   if exists(select 1 from taskfold_private.child_task_repair_originals where id=archive) then raise exception using errcode='PT409',message='This original changed; review it again';end if;
   status:='unavailable';
  elsif operation='remove' then
   delete from taskfold_private.child_task_repair_originals where id=archive;
   status:='unavailable';
  else status:='retained';end if;
 end if;
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',a,'request_id',request,'archive_id',archive,'archive_digest',expected_digest,'archive_bytes',expected_bytes,'state',status,'cleanup_enabled',enabled);
end$$;
create function public.taskfold_child_repair_original_cleanup(_operation text,_request uuid,_archive uuid,_digest text,_bytes integer) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select taskfold_private.child_repair_original_cleanup(_operation,_request,_archive,_digest,_bytes)
$$;
revoke all on function taskfold_private.child_repair_original_cleanup(text,uuid,uuid,text,integer),public.taskfold_child_repair_original_cleanup(text,uuid,uuid,text,integer) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_repair_original_cleanup(text,uuid,uuid,text,integer),public.taskfold_child_repair_original_cleanup(text,uuid,uuid,text,integer) to authenticated;

commit;
