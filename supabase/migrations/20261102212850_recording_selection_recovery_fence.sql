-- Undeployed: settle the complete original recording selection before a new
-- policy is chosen. No task rows, captions, media paths or session values persist.
create table taskfold_private.audio_selection_restore_closures (
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 request_id uuid not null, actor_id uuid not null references auth.users(id) on delete cascade,
 restore_from uuid not null, member_nonces uuid[] not null, fingerprint text not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,request_id), check(cardinality(member_nonces) between 2 and 100)
);
alter table taskfold_private.audio_selection_restore_closures enable row level security;
revoke all on taskfold_private.audio_selection_restore_closures from public,anon,authenticated,service_role;
create index audio_selection_restore_closures_actor on taskfold_private.audio_selection_restore_closures(actor_id);
create index audio_selection_restore_closures_members on taskfold_private.audio_selection_restore_closures using gin(member_nonces);

create function taskfold_private.audio_selection_restore_recovery(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare a uuid:=auth.uid();team uuid;q uuid;source uuid;p uuid;t uuid;g uuid;nonce uuid;target uuid;
 items jsonb;item jsonb;ids uuid[]:='{}';nonces uuid[]:='{}';projects uuid[]:='{}';f text;outcome text;result jsonb;
 original taskfold_private.team_task_batches;prior taskfold_private.team_task_batches;
 single taskfold_private.team_task_edits;d taskfold_private.audio_task_deletions;
 closed taskfold_private.audio_selection_restore_closures;has_audio boolean:=false;has_expired boolean:=false;
 defaults constant jsonb:='{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}';
begin
 perform taskfold_private.team_actor();
 if action is null or action not in('inspect','close') or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>1500000
  or not b ?& array['team_id','request_id','restores','items']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('team_id','request_id','restores','items'))
  or jsonb_typeof(b->'items') is distinct from 'array' or jsonb_array_length(b->'items') not between 2 and 100 then
  raise exception using errcode='22023',message='Review the complete original recording selection';end if;
 team:=taskfold_private.team_uuid(b,'team_id');q:=taskfold_private.team_uuid(b,'request_id');source:=taskfold_private.team_uuid(b,'restores');items:=b->'items';
 if q=source then raise exception using errcode='22023',message='Use distinct selection identities';end if;
 for item in select value from jsonb_array_elements(items) loop
  if jsonb_typeof(item) is distinct from 'object' or octet_length(item::text)>128000
   or not item ?& array['team_id','project_id','task_id','request_id','task_generation','restore_from','record']
   or exists(select 1 from jsonb_object_keys(item) k where k not in('team_id','project_id','task_id','request_id','task_generation','restore_from','record','audio_restoration_ack','task_type_lifecycle_protocol')) then
   raise exception using errcode='22023',message='Review every original selected task';end if;
  t:=taskfold_private.team_uuid(item,'task_id');p:=taskfold_private.team_uuid(item,'project_id');g:=taskfold_private.team_uuid(item,'task_generation');nonce:=taskfold_private.team_uuid(item,'request_id');target:=taskfold_private.team_uuid(item,'restore_from');
  if taskfold_private.team_uuid(item,'team_id')<>team or t=any(ids) or nonce=any(nonces) or nonce in(q,source)
   or jsonb_typeof(item->'record') is distinct from 'object' or item->'record'->'id' is distinct from to_jsonb(t)
   or item->'record'->'project_id' is distinct from to_jsonb(p) or item->'record'->'task_generation' is distinct from to_jsonb(g)
   or item ? 'task_type_lifecycle_protocol' and item->'task_type_lifecycle_protocol' is distinct from '1'::jsonb then
   raise exception using errcode='22023',message='Review distinct task and action identities';end if;
  ids:=array_append(ids,t);nonces:=array_append(nonces,nonce);projects:=array_append(projects,p);
 end loop;
 if not exists(select 1 from jsonb_array_elements(items) x where x ? 'audio_restoration_ack')
  or exists(select 1 from jsonb_array_elements(items) x where x ? 'audio_restoration_ack' and x->'audio_restoration_ack'->'policy' is distinct from '"published_restore_v1"'::jsonb) then
  raise exception using errcode='PT409',message='Keep the original recording decision for this check';end if;
 -- Auth before team, then project bindings, all request mutexes, all task mutexes.
 -- The actor FK must not acquire Auth locks after an account-removal team lock.
 perform 1 from auth.users where id=a for share;
 perform taskfold_private.team_actor();
 perform 1 from taskfold_private.teams where id=team and state='active' for share;
 if not found then raise exception using errcode='PT404',message='Shared selection is unavailable';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared actions are paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Shared actions are paused';end if;
 perform 1 from taskfold_private.audio_comment_config where singleton and restoration_enabled for share;
 if not found then raise exception using errcode='PT503',message='Recording recovery is paused';end if;
 for p in select distinct x from unnest(projects) x order by x loop
  perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
  if not found then raise exception using errcode='PT404',message='Shared selection is unavailable';end if;
  perform 1 from public.projects where id=p and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='A selected project is unavailable';end if;
  if coalesce(taskfold_private.team_project_role(a,p),'') not in('editor','manager') then raise exception using errcode='42501',message='Current editing access is required for every task';end if;
 end loop;
 for nonce in select x from unnest(array_append(nonces,q)) x order by x loop perform pg_advisory_xact_lock(hashtextextended(team::text||':'||nonce::text,79241));end loop;
 -- The batch writer locks its original group before task mutexes.
 perform 1 from taskfold_private.team_task_batches where team_id=team and request_id=source for share;
 for t in select x from unnest(ids) x order by x loop perform pg_advisory_xact_lock(hashtextextended(t::text,78137));end loop;
 perform taskfold_private.team_actor();
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,'restore'::text,b)::text,'UTF8'),s.secret,'sha256'),'hex') into f from taskfold_private.automation_revision_secret s where singleton;
 select * into prior from taskfold_private.team_task_batches where team_id=team and request_id=q;
 if found then
  if prior.actor_id<>a or prior.operation<>'restore' or prior.fingerprint<>f or prior.restores<>source then
   raise exception using errcode='PT409',message='The saved selection identity changed';end if;
  outcome:='recorded';
 else
  select * into closed from taskfold_private.audio_selection_restore_closures where team_id=team and request_id=q;
  if found then
   if closed.actor_id<>a or closed.fingerprint<>f or closed.restore_from<>source or closed.member_nonces<>nonces then
    raise exception using errcode='PT409',message='The saved selection identity changed';end if;
   outcome:='closed';
  else
   if exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=any(array_append(nonces,q)))
    or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=any(nonces))
    or exists(select 1 from taskfold_private.audio_restore_closures where team_id=team and request_id=any(array_append(nonces,q)))
    or exists(select 1 from taskfold_private.audio_selection_restore_closures where team_id=team and (request_id=any(nonces) or member_nonces&&array_append(nonces,q))) then
    raise exception using errcode='PT409',message='A saved action identity is already used';end if;
   select * into original from taskfold_private.team_task_batches where team_id=team and request_id=source for share;
   if not found or original.actor_id<>a or original.operation<>'delete' or original.restored_request is not null
    or (select count(*) from taskfold_private.team_task_batch_items where team_id=team and request_id=source)<>cardinality(ids) then
    raise exception using errcode='PT409',message='Recover the original selection together';end if;
   for item in select value from jsonb_array_elements(items) loop
    t:=(item->>'task_id')::uuid;p:=(item->>'project_id')::uuid;target:=(item->>'restore_from')::uuid;
    select * into single from taskfold_private.team_task_edits where team_id=team and request_id=target for share;
    if not found or single.actor_id<>a or single.operation<>'delete' or single.batch_request_id is distinct from source
     or single.task_id<>t or single.restored_request is not null or single.restoration_hash is null
     or exists(select 1 from public.tasks where id=t)
     or not exists(select 1 from taskfold_private.team_task_batch_items where team_id=team and request_id=source and task_id=t and project_id=p and operation_request=target and generation=single.generation)
     or single.restoration_hash<>taskfold_private.team_task_restoration_hash(jsonb_populate_record(null::public.tasks,defaults||(item->'record'))) then
     raise exception using errcode='PT409',message='Review the original deletion of every task';end if;
    select * into d from taskfold_private.audio_task_deletions where team_id=team and request_id=target for share;
    if found then
     if d.actor_id<>a or d.task_id<>t or d.project_id<>p or d.generation<>single.generation
      or item->'audio_restoration_ack' is distinct from jsonb_build_object('policy','published_restore_v1','count',cardinality(d.operations),'retention_days',30) then
      raise exception using errcode='PT409',message='Review the original recording policy for every task';end if;
     has_audio:=true;
     if d.expires_at<=clock_timestamp() then
      has_expired:=true;
      if action='close' and (select count(*) from taskfold_private.audio_comment_publications where operation_id=any(d.operations) and state='purged')<>cardinality(d.operations) then
       raise exception using errcode='PT409',message='Recording cleanup is not yet confirmed';end if;
     end if;
    elsif item ? 'audio_restoration_ack' then raise exception using errcode='PT409',message='The original recording inventory changed';end if;
   end loop;
   if not has_audio then raise exception using errcode='PT409',message='This selection has no recording recovery review';end if;
   outcome:='unrecorded';
   if action='close' then
    if not has_expired then raise exception using errcode='PT409',message='Keep the original Undo while recordings remain available';end if;
    insert into taskfold_private.audio_selection_restore_closures(team_id,request_id,actor_id,restore_from,member_nonces,fingerprint) values(team,q,a,source,nonces,f);
    outcome:='closed';
   end if;
  end if;
 end if;
 select jsonb_agg(jsonb_build_object('task_id',value->'task_id','project_id',value->'project_id','task_generation',value->'task_generation','request_id',value->'request_id') order by value->>'task_id') into result from jsonb_array_elements(items);
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'request_id',q,'restores',source,'items',result,'state',outcome);
end$$;
create function public.taskfold_audio_selection_restore_recovery(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_selection_restore_recovery(_action,_body)$$;
revoke all on function taskfold_private.audio_selection_restore_recovery(text,jsonb),public.taskfold_audio_selection_restore_recovery(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.audio_selection_restore_recovery(text,jsonb),public.taskfold_audio_selection_restore_recovery(text,jsonb) to authenticated;

-- Fence header and member identities in both writers, after their existing mutexes.
do $patch$
declare d text;anchor text;begin
 d:=pg_get_functiondef('taskfold_private.team_task_batch(text,jsonb)'::regprocedure);
 -- Parenthesize the record extraction: || and -> otherwise associate left.
 anchor:='defaults||item->''record''';
 if array_length(string_to_array(d,anchor),1)<>3 then raise exception 'Current selection record normalization required';end if;
 d:=replace(d,anchor,'defaults||(item->''record'')');
 anchor:=' select * into prior from taskfold_private.team_task_batches where team_id=team and request_id=q;';
 if strpos(d,anchor)=0 then raise exception 'Current selection coordinator required';end if;
 execute replace(d,anchor,$guard$
 if exists(select 1 from taskfold_private.audio_selection_restore_closures c where c.team_id=team and (c.request_id=any(array_append(nonces,q)) or c.member_nonces&&array_append(nonces,q))) then
  raise exception using errcode='PT412',message='This recording selection Undo was closed after review. Its saved tasks are kept';end if;
 $guard$||anchor);
 d:=pg_get_functiondef('taskfold_private.team_task_lifecycle(text,jsonb)'::regprocedure);
 anchor:=' select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;';
 if strpos(d,anchor)=0 then raise exception 'Current native lifecycle coordinator required';end if;
 execute replace(d,anchor,$guard$
 if exists(select 1 from taskfold_private.audio_selection_restore_closures c where c.team_id=team and (c.request_id=q or c.member_nonces@>array[q])) then
  raise exception using errcode='PT412',message='This recording selection Undo was closed after review. Its saved tasks are kept';end if;
 $guard$||anchor);
end$patch$;
notify pgrst,'reload schema';
