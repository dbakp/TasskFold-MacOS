-- Source-only candidate; rollout remains disabled. Extend frozen planning groups
-- with portable labels; complete baselines, permissions, quotas, replay and rollback
-- stay in the existing guarded editor and transaction. No new grants or tables.
create or replace function taskfold_private.team_task_planning_batch(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
<<batch>>
declare a uuid:=auth.uid();team uuid;q uuid;item jsonb;id uuid;p uuid;nonce uuid;g uuid;
 ids uuid[]:='{}';nonces uuid[]:='{}';projects uuid[]:='{}';recipients uuid[]:='{}';prior taskfold_private.team_task_batches;
 tr taskfold_private.teams;t public.tasks;expected public.tasks;fingerprint text;result jsonb;replay boolean:=false;
 allowed constant text[]:=array['priority','due_date','due_time','time_zone','scheduled_at','deadline_date','duration_minutes','assigned_to','labels'];
 defaults constant jsonb:='{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}';
begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>2000000
  or not b ?& array['team_id','request_id','items'] or exists(select 1 from jsonb_object_keys(b) k where k not in('team_id','request_id','items'))
  or jsonb_typeof(b->'items') is distinct from 'array' or jsonb_array_length(b->'items') not between 1 and 100 then
  raise exception using errcode='22023',message='Choose between 1 and 100 shared tasks';end if;
 team=taskfold_private.team_uuid(b,'team_id');q=taskfold_private.team_uuid(b,'request_id');
 for item in select value from jsonb_array_elements(b->'items') loop
  if jsonb_typeof(item)<>'object' or not item ?& array['team_id','project_id','task_id','request_id','task_generation','record','changes']
   or exists(select 1 from jsonb_object_keys(item) k where k not in('team_id','project_id','task_id','request_id','task_generation','record','changes'))
   or jsonb_typeof(item->'record') is distinct from 'object' or jsonb_typeof(item->'changes') is distinct from 'object' or item->'changes'='{}'::jsonb
   or exists(select 1 from jsonb_object_keys(item->'changes') k where not k=any(allowed)) then
   raise exception using errcode='22023',message='Review a supported planning change for every task';end if;
  id=taskfold_private.team_uuid(item,'task_id');p=taskfold_private.team_uuid(item,'project_id');g=taskfold_private.team_uuid(item,'task_generation');nonce=taskfold_private.team_uuid(item,'request_id');
  if taskfold_private.team_uuid(item,'team_id')<>team or id=any(ids) or nonce=q or nonce=any(nonces) then raise exception using errcode='22023',message='Use distinct tasks and action identities in one team';end if;
  if item->'changes' ? 'assigned_to' then
   perform taskfold_private.automation_validate_fields(jsonb_build_object('assigned_to',item->'changes'->'assigned_to'),item->'record');
   if item->'changes'->'assigned_to'<>'null'::jsonb then
    if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') or not exists(
     select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) then
     raise exception using errcode='42501',message='Editing access is required for every selected task';end if;
    recipients=array_append(recipients,(item->'changes'->>'assigned_to')::uuid);
   end if;
  end if;
  ids=array_append(ids,id);nonces=array_append(nonces,nonce);projects=array_append(projects,p);
 end loop;
 -- Recipient Auth locks precede team/project/task locks, matching the single
 -- editor and membership operations. Canonical order covers cross-project groups.
 -- A recorded retry only acknowledges the old write; it never reassigns work.
 perform 1 from auth.users where users.id=any(recipients) order by users.id for share;
 select * into tr from taskfold_private.teams where teams.id=team for share;
 perform taskfold_private.team_actor();
 if tr.id is null or tr.state<>'active' then raise exception using errcode='PT503',message='Team planning is paused';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team planning is paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team planning is not enabled';end if;
 for p in select distinct x from unnest(projects) x order by x loop
  if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required for every selected task';end if;
  perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The selected workspace changed';end if;
  perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: A selected project is archived';end if;
 end loop;
 for nonce in select x from unnest(array_append(nonces,q)) x order by x loop perform pg_advisory_xact_lock(hashtextextended(team::text||':'||nonce::text,79241));end loop;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,'edit',b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 select * into prior from taskfold_private.team_task_batches where team_id=team and request_id=q;
 if found then
  if prior.actor_id<>a or prior.operation<>'edit' or prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This selection identity is already used';end if;
  replay=true;
 else
  if exists(select 1 from taskfold_private.team_task_edits where team_id=team and (request_id=q or request_id=any(nonces)))
   or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=any(nonces)) then
   raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Choose fresh action identities';end if;
  -- Nonblocking canonical row locks cannot wait behind a task writer while holding
  -- the selection's other rows. A conflict retains the complete device command.
  perform 1 from public.tasks where tasks.id=any(ids) order by tasks.id for update nowait;
  for item in select value from jsonb_array_elements(b->'items') order by value->>'task_id' loop
   id=(item->>'task_id')::uuid;p=(item->>'project_id')::uuid;g=(item->>'task_generation')::uuid;
   expected=jsonb_populate_record(null::public.tasks,defaults||item->'record');
   select * into t from public.tasks where tasks.id=batch.id;
   if not found or expected.id is distinct from id or expected.project_id is distinct from p or expected.task_generation is distinct from g
    or t.project_id is distinct from p or t.task_generation is distinct from g
    or (to_jsonb(t)-case when item->'record' ? 'created_at' then array[]::text[] else array['created_at'] end) is distinct from
       (to_jsonb(expected)-case when item->'record' ? 'created_at' then array[]::text[] else array['created_at'] end) then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: A selected task changed; review the whole selection';end if;
  end loop;
  insert into taskfold_private.team_task_batches(team_id,request_id,actor_id,operation,fingerprint) values(team,q,a,'edit',fingerprint);
  for item in select value from jsonb_array_elements(b->'items') order by value->>'task_id' loop
   expected=jsonb_populate_record(null::public.tasks,defaults||item->'record');
   perform taskfold_private.team_task_edit((item-array['record'])||jsonb_build_object('base',to_jsonb(expected)));
   update taskfold_private.team_task_edits set batch_request_id=q where team_id=team and request_id=(item->>'request_id')::uuid;
   insert into taskfold_private.team_task_batch_items values(team,q,(item->>'task_id')::uuid,(item->>'project_id')::uuid,(item->>'task_generation')::uuid,(item->>'request_id')::uuid);
  end loop;
 end if;
 select jsonb_agg(jsonb_build_object('task_id',value->'task_id','project_id',value->'project_id','task_generation',value->'task_generation','request_id',value->'request_id') order by value->>'task_id') into result from jsonb_array_elements(b->'items');
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'request_id',q,'operation','edit','restores',null,'items',result,'replayed',replay);
exception when lock_not_available then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: A selected task is busy; retry the saved selection';
end$$;
revoke all on function taskfold_private.team_task_planning_batch(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_task_planning_batch(jsonb) to authenticated;
