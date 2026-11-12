-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Undeployed native preflight. Counts and retention metadata only: no media,
-- captions, provider paths, task content or session values are returned.
create function taskfold_private.team_audio_lifecycle_review(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare a uuid:=auth.uid();team uuid;p uuid;t uuid;g uuid;source uuid;phase text;root public.tasks;
 d taskfold_private.audio_task_deletions;original taskfold_private.team_task_edits;inventory jsonb;
 available boolean;count integer:=0;policy text;retention timestamptz;pending boolean:=false;
begin
 perform taskfold_private.team_actor();
 perform taskfold_private.audio_fields(b,array['team_id','project_id','task_id','task_generation','phase','restore_from']);
 team:=taskfold_private.team_uuid(b,'team_id');p:=taskfold_private.team_uuid(b,'project_id');t:=taskfold_private.team_uuid(b,'task_id');g:=taskfold_private.team_uuid(b,'task_generation');
 phase:=b->>'phase';if jsonb_typeof(b->'phase') is distinct from 'string' or phase not in('delete','restore') then raise exception using errcode='22023',message='Review this task action';end if;
 if phase='restore' then source:=taskfold_private.team_uuid(b,'restore_from');elsif b->'restore_from'<>'null'::jsonb then raise exception using errcode='22023',message='Unexpected recording restoration identity';end if;
 perform 1 from taskfold_private.teams where id=team and state='active' for share;
 if not found then raise exception using errcode='PT404',message='Shared task is unavailable';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared actions are paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared actions are paused';end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 if not found then raise exception using errcode='PT404',message='Shared task is unavailable';end if;
 perform 1 from public.projects where id=p and not is_archived and not ancestor_archived for share;
 if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 perform 1 from taskfold_private.team_members where team_id=team and user_id=a for update;
 if not found then raise exception using errcode='42501',message='Current editing access is required';end if;
 perform 1 from taskfold_private.team_project_grants where project_id=p and user_id=a for share;
 perform taskfold_private.team_actor();
 if coalesce(taskfold_private.team_project_role(a,p),'') not in('editor','manager') then raise exception using errcode='42501',message='Current editing access is required';end if;
 select restoration_enabled into available from taskfold_private.audio_comment_config where singleton for share;
 if phase='delete' then
  select * into root from public.tasks where id=t and task_generation=g and project_id=p for share;
  if not found or not exists(select 1 from taskfold_private.team_content_tasks where task_id=t and generation=g and project_id=p and team_id=team) then
   raise exception using errcode='PT409',message='The task moved or was recreated. Review it again';end if;
  if available then
   inventory:=taskfold_private.team_task_audio_inventory(root);count:=jsonb_array_length(inventory);
   if count>0 then policy:='published_restore_v1';end if;
  end if;
 else
  select * into original from taskfold_private.team_task_edits where team_id=team and request_id=source for share;
  if not found or original.actor_id<>a or original.task_id<>t or original.operation<>'delete' or original.restoration_hash is null or original.restored_request is not null
   or exists(select 1 from public.tasks where id=t) then raise exception using errcode='PT409',message='Review the original deletion before restoring';end if;
  select * into d from taskfold_private.audio_task_deletions where team_id=team and request_id=source for share;
  if found then
   if d.actor_id<>a or d.task_id<>t or d.project_id<>p or d.generation<>original.generation then raise exception using errcode='PT409',message='The recording restoration changed';end if;
   count:=cardinality(d.operations);retention:=d.expires_at;
   if d.expires_at<=clock_timestamp() or d.inventory is null then
    policy:='expired_recordings_omitted_v1';
    pending:=(select count(*) from taskfold_private.audio_comment_publications where operation_id=any(d.operations) and state='purged')<>count;
   else policy:='published_restore_v1';end if;
  end if;
 end if;
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'project_id',p,'task_id',t,'task_generation',g,'phase',phase,'restore_from',source,
  'enabled',coalesce(available,false),'recording_count',count,'policy',policy,'retain_until',retention,'cleanup_pending',pending,
  'expires_at',to_char(clock_timestamp()+interval '5 minutes','YYYY-MM-DD"T"HH24:MI:SS"Z"'));
end$$;
create function public.taskfold_team_audio_lifecycle_review(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_audio_lifecycle_review(_body)$$;
revoke all on function taskfold_private.team_audio_lifecycle_review(jsonb),public.taskfold_team_audio_lifecycle_review(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_audio_lifecycle_review(jsonb),public.taskfold_team_audio_lifecycle_review(jsonb) to authenticated;
-- Selection envelopes preserve each member's exact acknowledged policy. Existing
-- atomic task checks and all-or-nothing restoration remain in the coordinator.
do $patch$
declare d text;anchor text:='''restore_from'',''task_type_lifecycle_protocol''))';begin
 d:=pg_get_functiondef('taskfold_private.team_task_batch(text,jsonb)'::regprocedure);
 if strpos(d,anchor)=0 then raise exception 'Current typed selection lifecycle required';end if;
 execute replace(d,anchor,'''restore_from'',''task_type_lifecycle_protocol'',''audio_restoration_ack''))');
end$patch$;
notify pgrst,'reload schema';

commit;
