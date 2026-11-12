-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Undeployed prerequisite for reviewing an expired, already-queued recording Undo.
-- Closing certifies non-application and permanently fences the exact old intent.
create table taskfold_private.audio_restore_closures (
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 actor_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null, project_id uuid not null, task_id uuid not null,
 generation uuid not null, restore_from uuid not null, fingerprint text not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,actor_id,request_id)
);
alter table taskfold_private.audio_restore_closures enable row level security;
revoke all on taskfold_private.audio_restore_closures from public,anon,authenticated,service_role;

create function taskfold_private.audio_restore_recovery(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare a uuid:=auth.uid();team uuid;p uuid;t uuid;g uuid;q uuid;source uuid;f text;outcome text;
 prior taskfold_private.team_task_edits;original taskfold_private.team_task_edits;
 closed taskfold_private.audio_restore_closures;d taskfold_private.audio_task_deletions;
begin
 perform taskfold_private.team_actor();
 if action is null or action not in('inspect','close') or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000
  or not b ?& array['team_id','project_id','task_id','request_id','task_generation','record','restore_from','audio_restoration_ack']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('team_id','project_id','task_id','request_id','task_generation','record','restore_from','audio_restoration_ack','parent_generation','task_type_lifecycle_protocol')) then
  raise exception using errcode='22023',message='Review the original recording Undo';end if;
 team:=taskfold_private.team_uuid(b,'team_id');p:=taskfold_private.team_uuid(b,'project_id');t:=taskfold_private.team_uuid(b,'task_id');g:=taskfold_private.team_uuid(b,'task_generation');q:=taskfold_private.team_uuid(b,'request_id');source:=taskfold_private.team_uuid(b,'restore_from');
 if jsonb_typeof(b->'record') is distinct from 'object' or b->'record'->'id' is distinct from to_jsonb(t)
  or b->'record'->'project_id' is distinct from to_jsonb(p) or b->'record'->'task_generation' is distinct from to_jsonb(g) then
  raise exception using errcode='22023',message='Review the saved task identity';end if;
 perform 1 from taskfold_private.teams where id=team and state='active' for share;
 if not found then raise exception using errcode='PT404',message='Shared task is unavailable';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared actions are paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared actions are paused';end if;
 perform 1 from taskfold_private.audio_comment_config where singleton and restoration_enabled for share;
 if not found then raise exception using errcode='PT503',message='Recording recovery is paused';end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 if not found then raise exception using errcode='PT404',message='Shared task is unavailable';end if;
 perform 1 from public.projects where id=p and not is_archived and not ancestor_archived for share;
 if not found then raise exception using errcode='PT409',message='This project is unavailable';end if;
 perform 1 from taskfold_private.team_members where team_id=team and user_id=a for update;
 if not found then raise exception using errcode='42501',message='Current editing access is required';end if;
 perform 1 from taskfold_private.team_project_grants where project_id=p and user_id=a for share;
 perform taskfold_private.team_actor();
 if coalesce(taskfold_private.team_project_role(a,p),'') not in('editor','manager') then raise exception using errcode='42501',message='Current editing access is required';end if;
 -- Same request mutex and task-generation mutex, in the lifecycle writer's order.
 perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));
 perform pg_advisory_xact_lock(hashtextextended(t::text,78137));
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,'restore'::text,b)::text,'UTF8'),s.secret,'sha256'),'hex') into f from taskfold_private.automation_revision_secret s where singleton;
 if exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q) then raise exception using errcode='PT409',message='Review the complete selection';end if;
 select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;
 if found then
  if prior.actor_id<>a or prior.fingerprint<>f or prior.operation<>'restore' or prior.task_id<>t or prior.generation<>g then
   raise exception using errcode='PT409',message='The saved action identity changed';end if;
  outcome:='recorded';
 else
  select * into closed from taskfold_private.audio_restore_closures where team_id=team and actor_id=a and request_id=q;
  if found then
   if closed.fingerprint<>f or closed.task_id<>t or closed.project_id<>p or closed.generation<>g or closed.restore_from<>source then
    raise exception using errcode='PT409',message='The saved action identity changed';end if;
   outcome:='closed';
  else
   select * into original from taskfold_private.team_task_edits where team_id=team and request_id=source for share;
   if not found or original.operation<>'delete' or original.actor_id<>a or original.task_id<>t or original.restoration_hash is null
    or original.restored_request is not null or original.batch_request_id is not null
    or exists(select 1 from public.tasks where id=t)
    or original.restoration_hash<>taskfold_private.team_task_restoration_hash(jsonb_populate_record(null::public.tasks,b->'record')) then
    raise exception using errcode='PT409',message='Review the original task deletion';end if;
   select * into d from taskfold_private.audio_task_deletions where team_id=team and request_id=source for share;
   if not found or d.actor_id<>a or d.task_id<>t or d.project_id<>p or d.generation<>original.generation
    or b->'audio_restoration_ack' is distinct from jsonb_build_object('policy','published_restore_v1','count',cardinality(d.operations),'retention_days',30) then
    raise exception using errcode='PT409',message='Review the original recording policy';end if;
   outcome:='unrecorded';
   if action='close' then
    if d.expires_at>clock_timestamp() or (select count(*) from taskfold_private.audio_comment_publications where operation_id=any(d.operations) and state='purged')<>cardinality(d.operations) then
     raise exception using errcode='PT409',message='Recording cleanup is not yet confirmed';end if;
    insert into taskfold_private.audio_restore_closures(team_id,actor_id,request_id,project_id,task_id,generation,restore_from,fingerprint) values(team,a,q,p,t,g,source,f);
    outcome:='closed';
   end if;
  end if;
 end if;
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'project_id',p,'task_id',t,'task_generation',g,'request_id',q,'restore_from',source,'state',outcome);
end$$;
create function public.taskfold_audio_restore_recovery(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_restore_recovery(_action,_body)$$;
revoke all on function taskfold_private.audio_restore_recovery(text,jsonb),public.taskfold_audio_restore_recovery(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.audio_restore_recovery(text,jsonb),public.taskfold_audio_restore_recovery(text,jsonb) to authenticated;

-- Insert after the writer's request/task mutexes and exact command fingerprint.
-- A closure cannot coexist with a successfully recorded original operation.
do $patch$
declare d text;anchor text:=' select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;';begin
 d:=pg_get_functiondef('taskfold_private.team_task_lifecycle(text,jsonb)'::regprocedure);
 if strpos(d,anchor)=0 then raise exception 'Current native lifecycle coordinator required';end if;
 execute replace(d,anchor,$guard$
 if action='restore' and exists(select 1 from taskfold_private.audio_restore_closures c where c.team_id=team and c.actor_id=a and c.request_id=q) then
  raise exception using errcode='PT412',message='This recording Undo was closed after review. Its saved task is kept';end if;
$guard$||anchor);
end$patch$;
notify pgrst,'reload schema';

commit;
