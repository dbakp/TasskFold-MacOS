-- Disabled candidate. One request/transaction represents the whole selection.
create table taskfold_private.team_task_batches (
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 request_id uuid not null,actor_id uuid not null references auth.users(id) on delete cascade,
 operation text not null check(operation in('delete','restore')),fingerprint text not null,
 restores uuid,restored_request uuid,created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,request_id),
 foreign key(team_id,restores) references taskfold_private.team_task_batches(team_id,request_id) on delete cascade
);
create index team_task_batches_actor on taskfold_private.team_task_batches(actor_id);
create index team_task_batches_restores on taskfold_private.team_task_batches(team_id,restores) where restores is not null;
alter table taskfold_private.team_task_edits add column batch_request_id uuid,
 add constraint team_task_edits_batch foreign key(team_id,batch_request_id) references taskfold_private.team_task_batches(team_id,request_id) on delete cascade;
create index team_task_edits_batch on taskfold_private.team_task_edits(team_id,batch_request_id) where batch_request_id is not null;
create table taskfold_private.team_task_batch_items (
 team_id uuid not null,request_id uuid not null,task_id uuid not null,project_id uuid not null,
 generation uuid not null,operation_request uuid not null,
 primary key(team_id,request_id,task_id),unique(team_id,operation_request),
 foreign key(team_id,request_id) references taskfold_private.team_task_batches(team_id,request_id) on delete cascade,
 foreign key(team_id,operation_request) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
create table taskfold_private.team_task_batch_scope (
 transaction_id bigint not null,team_id uuid not null,request_id uuid not null,actor_id uuid not null,
 operation text not null check(operation in('delete','restore')),source_batch uuid,
 task_id uuid not null,project_id uuid not null,old_generation uuid not null,new_generation uuid,
 primary key(transaction_id,team_id,task_id)
);
do $$declare n text;begin foreach n in array array['team_task_batches','team_task_batch_items','team_task_batch_scope'] loop
 execute format('alter table taskfold_private.%I enable row level security',n);
 execute format('revoke all on taskfold_private.%I from public,anon,authenticated,service_role',n);
end loop;end$$;

-- Pure ordering: leaves first for removal, parents first for recovery. Detect a
-- cycle before touching content. External parents/children are not batch members.
create function taskfold_private.team_batch_order(items jsonb,operation text) returns uuid[]
language plpgsql immutable security invoker set search_path='' as $$
declare ids uuid[];done uuid[]:='{}';item jsonb;id uuid;parent uuid;progress boolean;begin
 select array_agg((value->>'task_id')::uuid) into ids from jsonb_array_elements(items);
 while cardinality(done)<cardinality(ids) loop
  progress=false;
  for item in select value from jsonb_array_elements(items) order by value->>'task_id' loop
   id=(item->>'task_id')::uuid;if id=any(done) then continue;end if;
   parent=(item->'record'->>'recurrence_parent_id')::uuid;
   if operation='restore' then
    if parent=any(ids) and not parent=any(done) then continue;end if;
   elsif exists(select 1 from jsonb_array_elements(items) child where (child->'record'->>'recurrence_parent_id')::uuid=id and not (child->>'task_id')::uuid=any(done)) then continue;
   end if;
   done=array_append(done,id);progress=true;
  end loop;
  if not progress then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the linked task structure';end if;
 end loop;
 return done;
end$$;
revoke all on function taskfold_private.team_batch_order(jsonb,text) from public,anon,authenticated,service_role;

create function taskfold_private.team_task_batch(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
<<batch>>
declare a uuid:=auth.uid();team uuid;q uuid;source uuid;items jsonb;item jsonb;p uuid;id uuid;nonce uuid;g uuid;target uuid;
 ids uuid[]:='{}';nonces uuid[];projects uuid[];parents uuid[];ordered uuid[];old_generation uuid;
 tr taskfold_private.teams;prior taskfold_private.team_task_batches;original taskfold_private.team_task_batches;single taskfold_private.team_task_edits;
 t public.tasks;expected public.tasks;f text;result jsonb;replay boolean:=false;
 defaults constant jsonb:='{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}';
begin
 perform taskfold_private.team_actor();
 if operation is null or operation not in('delete','restore') or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>2000000
  or not b ?& array['team_id','request_id','items'] or exists(select 1 from jsonb_object_keys(b) k where k not in('team_id','request_id','items','restores'))
  or jsonb_typeof(b->'items') is distinct from 'array' or jsonb_array_length(b->'items') not between 1 and 100 then
  raise exception using errcode='22023',message='Choose a supported task selection';end if;
 team=taskfold_private.team_uuid(b,'team_id');q=taskfold_private.team_uuid(b,'request_id');items=b->'items';
 if operation='restore' then source=taskfold_private.team_uuid(b,'restores');elsif b ? 'restores' then raise exception using errcode='22023',message='Invalid recovery selection';end if;
 for item in select value from jsonb_array_elements(items) loop
  if jsonb_typeof(item)<>'object' or octet_length(item::text)>128000 or not item ?& array['team_id','project_id','task_id','request_id','task_generation','record']
   or exists(select 1 from jsonb_object_keys(item) k where k not in('team_id','project_id','task_id','request_id','task_generation','record','restore_from')) then
   raise exception using errcode='22023',message='Review every selected task';end if;
  if taskfold_private.team_uuid(item,'team_id')<>team or jsonb_typeof(item->'record') is distinct from 'object' then raise exception using errcode='22023',message='Choose tasks in the same workspace';end if;
  id=taskfold_private.team_uuid(item,'task_id');p=taskfold_private.team_uuid(item,'project_id');g=taskfold_private.team_uuid(item,'task_generation');nonce=taskfold_private.team_uuid(item,'request_id');
  if id=any(ids) or nonce=q or nonce=any(coalesce(nonces,'{}')) then raise exception using errcode='22023',message='Use unique task and action identities';end if;
  ids=array_append(ids,id);nonces=array_append(coalesce(nonces,'{}'),nonce);projects=array_append(coalesce(projects,'{}'),p);
  if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') or not exists(select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) then
   raise exception using errcode='42501',message='Editing access is required for every selected task';end if;
  if operation='restore' then
   target=taskfold_private.team_uuid(item,'restore_from');
   select * into single from taskfold_private.team_task_edits where team_id=team and request_id=target;
   if not found or single.actor_id<>a or single.operation<>'delete' or single.batch_request_id is distinct from source or single.task_id<>id
    or single.restoration_hash is null then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Recover the original selection together';end if;
   perform taskfold_private.hold_team_conversation_auth(team,target,a);
  elsif item ? 'restore_from' then raise exception using errcode='22023',message='Invalid removal request';end if;
 end loop;
 -- Recipients/attribution before team locks, matching the single-task lifecycle.
 for item in select value from jsonb_array_elements(items) loop
  expected=jsonb_populate_record(null::public.tasks,defaults||item->'record');
  perform 1 from auth.users where users.id in(
   select expected.assigned_to union select (value->>'assigned_to')::uuid from jsonb_each(taskfold_private.automation_tree_index(coalesce(expected.subtasks,'[]')))
  ) order by users.id for share;
 end loop;
 select * into tr from taskfold_private.teams where teams.id=team for share;
 perform taskfold_private.team_actor();
 if tr.id is null or tr.state<>'active' then raise exception using errcode='PT503',message='Team task actions are paused';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team task actions are paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team task actions are not enabled';end if;
 for p in select distinct x from unnest(projects) x order by x loop
  if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
  perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The workspace changed';end if;
  perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: A selected project is archived';end if;
 end loop;
 for nonce in select x from unnest(array_append(nonces,q)) x order by x loop perform pg_advisory_xact_lock(hashtextextended(team::text||':'||nonce::text,79241));end loop;
 select * into prior from taskfold_private.team_task_batches where team_id=team and request_id=q;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,operation,b)::text,'UTF8'),s.secret,'sha256'),'hex') into f from taskfold_private.automation_revision_secret s where singleton;
 if prior.request_id is not null then
  if prior.actor_id<>a or prior.operation<>operation or prior.fingerprint<>f then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This selection identity is already used';end if;
  replay=true;
 else
  if exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q)
   or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=any(nonces))
   or exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=any(nonces)) then
   raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Choose fresh action identities';end if;
  if operation='restore' then
   select * into original from taskfold_private.team_task_batches where team_id=team and request_id=source for update;
   if not found or original.actor_id<>a or original.operation<>'delete' or original.restored_request is not null
    or (select count(*) from taskfold_private.team_task_batch_items where team_id=team and request_id=source)<>cardinality(ids)
    or exists(select 1 from taskfold_private.team_task_batch_items where team_id=team and request_id=source and not task_id=any(ids)) then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Recover the original selection together';end if;
  end if;
  -- Attest supplied relationships before locking any external parent. Recheck
  -- live records under locks in the single-task operation before each effect.
  for item in select value from jsonb_array_elements(items) loop
   id=(item->>'task_id')::uuid;p=(item->>'project_id')::uuid;g=(item->>'task_generation')::uuid;
   expected=jsonb_populate_record(null::public.tasks,defaults||item->'record');
   if expected.id is distinct from id or expected.project_id is distinct from p or expected.task_generation is distinct from g then raise exception using errcode='22023',message='Review every selected task';end if;
   if operation='delete' then
    select * into t from public.tasks where tasks.id=batch.id;
    if not found or t.task_generation is distinct from g or t.project_id is distinct from p
     or (to_jsonb(t)-case when item->'record' ? 'created_at' then array[]::text[] else array['created_at'] end) is distinct from
        (to_jsonb(expected)-case when item->'record' ? 'created_at' then array[]::text[] else array['created_at'] end) then
     raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: A selected task changed';end if;
   else
    select * into single from taskfold_private.team_task_edits where team_id=team and request_id=(item->>'restore_from')::uuid;
    if single.restoration_hash is distinct from taskfold_private.team_task_restoration_hash(expected) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: A recovered task differs from its deletion';end if;
   end if;
  end loop;
  select array_agg(distinct (value->'record'->>'recurrence_parent_id')::uuid) into parents from jsonb_array_elements(items) where value->'record'->>'recurrence_parent_id' is not null;
  for id in select distinct x from unnest(ids||coalesce(parents,'{}')) x order by x loop perform pg_advisory_xact_lock(hashtextextended(id::text,78137));end loop;
  perform 1 from public.tasks where tasks.id=any(coalesce(parents,'{}')) order by tasks.id for key share;
  perform 1 from public.tasks where tasks.id=any(ids) order by tasks.id for update;
  ordered=taskfold_private.team_batch_order(items,operation);
  insert into taskfold_private.team_task_batches(team_id,request_id,actor_id,operation,fingerprint,restores) values(team,q,a,operation,f,source);
  for item in select value from jsonb_array_elements(items) loop
   old_generation=(item->>'task_generation')::uuid;
   if operation='restore' then select generation into old_generation from taskfold_private.team_task_edits where team_id=team and request_id=(item->>'restore_from')::uuid;end if;
   insert into taskfold_private.team_task_batch_scope values(txid_current(),team,q,a,operation,source,(item->>'task_id')::uuid,(item->>'project_id')::uuid,old_generation,
    case when operation='restore' then (item->>'task_generation')::uuid else null end);
  end loop;
  foreach id in array ordered loop
   select value into item from jsonb_array_elements(items) where value->>'task_id'=id::text;
   perform taskfold_private.team_task_lifecycle(operation,item);
   update taskfold_private.team_task_edits set batch_request_id=q where team_id=team and request_id=(item->>'request_id')::uuid;
   insert into taskfold_private.team_task_batch_items values(team,q,id,(item->>'project_id')::uuid,(item->>'task_generation')::uuid,(item->>'request_id')::uuid);
  end loop;
  if operation='restore' then update taskfold_private.team_task_batches set restored_request=q where team_id=team and request_id=source;end if;
  delete from taskfold_private.team_task_batch_scope where transaction_id=txid_current() and team_id=team and request_id=q;
 end if;
 select jsonb_agg(jsonb_build_object('task_id',value->'task_id','project_id',value->'project_id','task_generation',value->'task_generation','request_id',value->'request_id') order by value->>'task_id') into result from jsonb_array_elements(items);
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'request_id',q,'operation',operation,'restores',source,'items',result,'replayed',replay);
end$$;
create function public.taskfold_team_task_batch(_operation text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_task_batch(_operation,_body)$$;
revoke all on function taskfold_private.team_task_batch(text,jsonb),public.taskfold_team_task_batch(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_task_batch(text,jsonb),public.taskfold_team_task_batch(text,jsonb) to authenticated;

create or replace function taskfold_private.team_task_lifecycle(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;p uuid;id uuid;q uuid;generation uuid;restore_from uuid;parent_generation uuid;
 tr taskfold_private.teams;row public.tasks;desired public.tasks;expected public.tasks;child public.tasks;
 prior taskfold_private.team_task_edits;original taskfold_private.team_task_edits;link taskfold_private.team_task_deleted_links;
 fingerprint text;payload jsonb;nodes jsonb;item jsonb;recipient uuid;recipient_ids uuid[];k text;
 replay boolean:=false;unavailable boolean:=false;hash text;
 defaults constant jsonb:='{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}';
 allowed constant text[]:=array['id','user_id','title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','created_at','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at','task_generation','completion_version'];
begin
 perform taskfold_private.team_actor();
 if action not in('create','delete','restore') or action is null or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000
  or not b ?& array['team_id','project_id','task_id','request_id','task_generation','record']
  or exists(select 1 from jsonb_object_keys(b) e where e not in('team_id','project_id','task_id','request_id','task_generation','record','restore_from','parent_generation')) then
  raise exception using errcode='22023',message='Invalid saved team action';end if;
 team=taskfold_private.team_uuid(b,'team_id');p=taskfold_private.team_uuid(b,'project_id');id=taskfold_private.team_uuid(b,'task_id');q=taskfold_private.team_uuid(b,'request_id');generation=taskfold_private.team_uuid(b,'task_generation');
 payload=b->'record';
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['id','user_id','title','project_id','task_generation']
  or exists(select 1 from jsonb_object_keys(payload) e where not e=any(allowed))
  or payload->'id' is distinct from to_jsonb(id) or payload->'project_id' is distinct from to_jsonb(p) or payload->'task_generation' is distinct from to_jsonb(generation) then
  raise exception using errcode='22023',message='Review this task and its workspace';end if;
 if action='restore' then restore_from=taskfold_private.team_uuid(b,'restore_from');
 elsif b ? 'restore_from' then raise exception using errcode='22023',message='Invalid restoration request';end if;
 if b ? 'parent_generation' then parent_generation=taskfold_private.team_uuid(b,'parent_generation');end if;
 if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') or not exists(
  select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) then
  raise exception using errcode='42501',message='Editing access is required';end if;
 if action='restore' then perform taskfold_private.hold_team_conversation_auth(team,restore_from,a);end if;
 desired=jsonb_populate_record(null::public.tasks,defaults||payload);
 -- Collect all nested assignment identities before taking the team lock. Preserve
 -- Auth-before-team ordering and hold recipients against removal/bans until commit.
 nodes=taskfold_private.automation_tree_index(coalesce(desired.subtasks,'[]'));
 select array_agg(distinct u order by u) into recipient_ids from (
  select desired.assigned_to as u union all
  select (e.value->>'assigned_to')::uuid from jsonb_each(nodes) e where coalesce(e.value->>'assigned_to','')<>''
 ) z where u is not null;
 perform 1 from auth.users where users.id=any(coalesce(recipient_ids,'{}')) order by users.id for share;
 select * into tr from taskfold_private.teams where teams.id=team for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform taskfold_private.team_actor();
 if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') or not exists(
  select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) then
  raise exception using errcode='42501',message='Editing access is required';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team task actions are not enabled';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found or tr.state<>'active' then raise exception using errcode='PT503',message='Team task actions are paused';end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
 if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This project is archived or unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));
 -- Match ordinary native INSERT generation serialization, including competing
 -- personal/service attempts at this UUID. Never lock a task before this mutex.
 perform pg_advisory_xact_lock(hashtextextended(id::text,78137));
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,action,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 if exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This action identity is already used';end if;
 select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;
 if found then
  if prior.actor_id<>a or prior.fingerprint<>fingerprint or prior.operation<>action or prior.task_id<>id or prior.generation<>generation then
   raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This action identity is already used';end if;
  replay=true;
 end if;
 select * into row from public.tasks where tasks.id=cmd.id for update;
 if replay then
  if action='delete' or row.id is null or row.task_generation is distinct from generation or row.project_id is distinct from p then unavailable=true;end if;
 elsif action='delete' then
  if row.id is null then
   if not exists(select 1 from taskfold_private.team_content_tasks c join taskfold_private.task_generations g on g.task_id=c.task_id and g.generation=c.generation
    where c.task_id=cmd.id and c.generation=cmd.generation and c.team_id=team and c.project_id=p and g.deleted_at is not null) then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The saved task is unavailable';end if;
   -- A no-op never mints permission to restore a task another person removed.
   insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,generation,action);
  else
   if row.project_id is distinct from p or row.task_generation is distinct from generation then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The task moved or was recreated';end if;
   expected=desired;
   if (to_jsonb(row)-case when payload ? 'created_at' then array[]::text[] else array['created_at'] end)
     is distinct from (to_jsonb(expected)-case when payload ? 'created_at' then array[]::text[] else array['created_at'] end) then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This task changed before deletion';end if;
   if row.recurrence_parent_id is not null then select task_generation into parent_generation from public.tasks where tasks.id=row.recurrence_parent_id for key share;end if;
   hash=taskfold_private.team_task_restoration_hash(row);
   insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation,restoration_hash,parent_generation) values(team,q,a,fingerprint,id,generation,action,hash,parent_generation);
   perform taskfold_private.archive_team_conversation(team,p,id,generation,q);
   -- Parent FOR UPDATE excludes new FK children until deletion finishes. Existing
   -- occurrences are retained; they are not implicit members of a delete batch.
   for child in select * from public.tasks where recurrence_parent_id=cmd.id order by tasks.id for update loop
    if not exists(select 1 from taskfold_private.team_content_projects where project_id=child.project_id and team_id=team) then
     raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review linked work before deleting';end if;
    insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,related_id) values(txid_current(),team,child.project_id,child.id,child.task_generation,a,'detach',id);
    update public.tasks set recurrence_parent_id=null where tasks.id=child.id returning * into child;
    delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=child.id;
    insert into taskfold_private.team_task_deleted_links values(team,q,child.id,child.task_generation,child.project_id,taskfold_private.automation_task_revision(child));
   end loop;
   insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation) values(txid_current(),team,p,id,generation,a,'delete');
   delete from public.tasks where tasks.id=cmd.id;
   delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=cmd.id;
   delete from taskfold_private.team_conversation_scope where transaction_id=txid_current() and request_id=q;
  end if;
  unavailable=true;
 else
  if row.id is not null or exists(select 1 from taskfold_private.task_generations where task_id=cmd.id and task_generations.generation=cmd.generation) then
   raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Choose a new task incarnation';end if;
  if action='restore' then
   select * into original from taskfold_private.team_task_edits where team_id=team and request_id=restore_from for update;
   if not found or original.operation<>'delete' or original.actor_id<>a or original.task_id<>id or original.restoration_hash is null or original.restored_request is not null
    or original.restoration_hash<>taskfold_private.team_task_restoration_hash(desired) then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This Undo no longer matches the deleted task';end if;
   if original.batch_request_id is not null and not exists(select 1 from taskfold_private.team_task_batch_scope bs where bs.transaction_id=txid_current() and bs.team_id=team and bs.actor_id=a
    and bs.operation='restore' and bs.source_batch=original.batch_request_id and bs.task_id=id and bs.old_generation=original.generation and bs.new_generation=generation) then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Recover this selection together';end if;
   perform taskfold_private.assert_team_conversation_undo(team,restore_from);
   parent_generation=original.parent_generation;
   if desired.recurrence_parent_id is not null then
    select coalesce((select bs.new_generation from taskfold_private.team_task_batch_scope bs where bs.transaction_id=txid_current() and bs.team_id=team and bs.actor_id=a and bs.operation='restore'
     and bs.source_batch=original.batch_request_id and bs.task_id=desired.recurrence_parent_id and bs.old_generation=parent_generation),parent_generation) into parent_generation;
   end if;
   -- Auth would have cleared these assignments had the task remained live.
   if desired.assigned_to is not null and coalesce(taskfold_private.team_project_role(desired.assigned_to,p),'') not in('manager','editor') then desired.assigned_to=null;end if;
   foreach recipient in array coalesce(recipient_ids,'{}') loop
    if coalesce(taskfold_private.team_project_role(recipient,p),'') not in('manager','editor') then desired.subtasks=taskfold_private.clear_assignee(desired.subtasks,recipient);end if;
   end loop;
  else
   if payload->'user_id' is distinct from to_jsonb(a) or exists(select 1 from taskfold_private.task_generations where task_id=cmd.id)
    or exists(select 1 from taskfold_private.team_content_tasks where task_id=cmd.id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This creation needs a new identity';end if;
   if coalesce(desired.attachments,'[]')<>'[]' or coalesce(desired.comments,'[]')<>'[]' or desired.notification_sent_at is not null
    or jsonb_typeof(desired.source_metadata)<>'object' or octet_length(desired.source_metadata::text)>8192 or desired.completion_version<>0 then
    raise exception using errcode='22023',message='Use reviewed content and a fresh completion state';end if;
   perform taskfold_private.automation_validate_fields(payload-array['id','user_id','completed','attachments','comments','created_at','completed_at','recurrence_parent_id','notification_sent_at','source_metadata','task_generation','completion_version'],null);
   if desired.completed is null or (payload ? 'completed' and jsonb_typeof(payload->'completed')<>'boolean') then raise exception using errcode='22023',message='Use a valid completion state';end if;
   desired.subtasks=taskfold_private.team_task_tree(coalesce(desired.subtasks,'[]'),'{}',p,a,clock_timestamp());
   if desired.assigned_to is not null then perform taskfold_private.team_task_member(desired.assigned_to,p,a);end if;
   if desired.created_at is null then desired.created_at=clock_timestamp();end if;
   if not isfinite(desired.created_at) then raise exception using errcode='22023',message='Use a valid creation time';end if;
   if desired.completed then desired.completed_at=clock_timestamp();else desired.completed_at=null;end if;
  end if;
  if desired.section_id is not null then
   perform 1 from public.sections where sections.id=desired.section_id and project_id=p for key share;
   if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This section is unavailable';end if;
  end if;
  if desired.recurrence_parent_id is not null then
   if desired.recurrence_parent_id=id or parent_generation is null then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the original repeat task';end if;
   perform 1 from public.tasks parent where parent.id=desired.recurrence_parent_id and parent.task_generation=cmd.parent_generation
    and coalesce(taskfold_private.team_project_role(a,parent.project_id),'') in('manager','editor')
    and exists(select 1 from taskfold_private.team_content_projects where project_id=parent.project_id and team_id=team) for key share;
   if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The repeat task changed';end if;
  elsif b ? 'parent_generation' then raise exception using errcode='22023',message='Unexpected repeat task identity';end if;
  desired.task_generation=generation;desired.completion_version=0;
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation) values(txid_current(),team,p,id,generation,a,'create');
  insert into public.tasks select (desired).* returning * into row;
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=cmd.id;
  if action='restore' then
   update taskfold_private.team_task_edits set restored_request=q where team_id=team and request_id=restore_from;
   perform taskfold_private.restore_team_conversation(team,restore_from,p,id,generation);
   for link in select * from taskfold_private.team_task_deleted_links where team_id=team and request_id=restore_from order by child_id loop
    select * into child from public.tasks where tasks.id=link.child_id for update;
    if found and child.task_generation=link.generation and child.project_id=link.project_id and child.recurrence_parent_id is null
     and taskfold_private.automation_task_revision(child)=link.detached_revision
     and coalesce(taskfold_private.team_project_role(a,child.project_id),'') in('manager','editor') then
     insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,related_id) values(txid_current(),team,child.project_id,child.id,child.task_generation,a,'reattach',id);
     update public.tasks set recurrence_parent_id=cmd.id where tasks.id=child.id;
     delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=child.id;
    end if;
   end loop;
  end if;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,generation,action);
 end if;
 return jsonb_build_object('protocol',1,'operation',action,'account',a,'team_id',team,'project_id',p,'task_id',id,'request_id',q,'task_generation',generation,
  'task',case when unavailable then null else to_jsonb(row) end,'unavailable',unavailable,'replayed',replay);
end$$;

create or replace function taskfold_private.team_task_edit(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;p uuid;id uuid;q uuid;generation uuid;
 tr taskfold_private.teams;row public.tasks;desired public.tasks;
 prior taskfold_private.team_task_edits;fingerprint text;changes jsonb;base jsonb;k text;replay boolean:=false;
 allowed constant text[]:=array['title','description','priority','due_date','due_time','completed','completed_at','deadline_date','duration_minutes','time_zone','scheduled_at'];
begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000
  or not b ?& array['team_id','project_id','task_id','request_id','task_generation','base','changes']
  or exists(select 1 from jsonb_object_keys(b) keys(key) where keys.key not in('team_id','project_id','task_id','request_id','task_generation','base','changes')) then
  raise exception using errcode='22023',message='Invalid saved team edit';end if;
 team=taskfold_private.team_uuid(b,'team_id');p=taskfold_private.team_uuid(b,'project_id');
 id=taskfold_private.team_uuid(b,'task_id');q=taskfold_private.team_uuid(b,'request_id');generation=taskfold_private.team_uuid(b,'task_generation');
 changes=b->'changes';base=b->'base';
 if jsonb_typeof(changes) is distinct from 'object' or changes='{}' or jsonb_typeof(base) is distinct from 'object' then
  raise exception using errcode='22023',message='A saved edit and baseline are required';end if;
 if base->'project_id' is distinct from to_jsonb(p) or base->'task_generation' is distinct from to_jsonb(generation) then
  raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This edit belongs to another task or project';end if;
 for k in select jsonb_object_keys(changes) loop
  if not k=any(allowed) or not base ? k then raise exception using errcode='22023',message='This field needs a separate reviewed action';end if;
  if k in('title','description','due_date','due_time','completed_at','deadline_date','time_zone','scheduled_at') and jsonb_typeof(changes->k) not in('string','null') then
   raise exception using errcode='22023',message='Invalid task value';end if;
  if k='completed' and jsonb_typeof(changes->k) is distinct from 'boolean' then raise exception using errcode='22023',message='Invalid completion';end if;
  if k in('priority','duration_minutes') and changes->k<>'null'::jsonb and
   (jsonb_typeof(changes->k)<>'number' or (changes->>k)::numeric<>trunc((changes->>k)::numeric)) then
   raise exception using errcode='22023',message='Invalid task number';end if;
 end loop;
 if changes ?| array['completed','completed_at'] and (jsonb_typeof(base->'completion_version') is distinct from 'number'
  or (base->>'completion_version')::numeric<0 or (base->>'completion_version')::numeric<>trunc((base->>'completion_version')::numeric)
  or (base->>'completion_version')::numeric>9007199254740991) then
  raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the synced completion';end if;
 -- Auth locks precede the team lock, matching membership management. Recheck
 -- after waiting: a pre-wait role snapshot cannot authorize a revoked draft.
 select * into tr from taskfold_private.teams where teams.id=team for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform taskfold_private.team_actor();
 if taskfold_private.team_project_role(a,p) is null or not exists(
  select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) then
  raise exception using errcode='PT404',message='Project is unavailable';end if;
 if taskfold_private.team_project_role(a,p) not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team task editing is not enabled';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found or tr.state<>'active' then raise exception using errcode='PT503',message='Team task editing is paused';end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
 if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This project is archived or unavailable';end if;
 -- Serialize an operation identity even if a forged reuse names another task.
 perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));
 select * into row from public.tasks where tasks.id=cmd.id for update;
 if not found or row.project_id is distinct from p or row.task_generation is distinct from generation
  or not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=cmd.id and c.generation=cmd.generation and c.team_id=team) then
  raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The saved task or project changed';end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 if exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This action identity is already used';end if;
 select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;
 if found then
  if prior.actor_id<>a or prior.fingerprint<>fingerprint or prior.task_id<>id or prior.generation<>generation then
   raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This edit identity is already used';end if;
  replay=true;
 else
  desired=jsonb_populate_record(row,changes);
  if desired.title is null or length(btrim(desired.title))=0 or length(desired.title)>10000 or length(desired.description)>100000
   or desired.priority is null or desired.priority not between 1 and 4
   or desired.duration_minutes is not null and desired.duration_minutes not between 1 and 10080
   or desired.time_zone is not null and not exists(select 1 from pg_timezone_names where name=desired.time_zone) then
   raise exception using errcode='22023',message='Review the task values';end if;
  insert into taskfold_private.team_task_edit_scope values(txid_current(),team,p,id,generation,a);
  -- Reuse the reviewed three-way merge, privately; no public RPC gains definer authority.
  row=taskfold_private.team_task_merge(id,base,changes);
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=cmd.id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation) values(team,q,a,fingerprint,id,generation);
 end if;
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'project_id',p,'request_id',q,'task_generation',generation,'task',to_jsonb(row),'replayed',replay);
end$$;
