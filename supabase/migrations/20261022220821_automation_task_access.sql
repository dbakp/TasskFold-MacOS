-- Candidate, not deployed: bounded task reads and private atomic write claims.
-- No mutation RPC or HTTP gateway is exposed by this migration.
create function taskfold_private.automation_lock_project(_account uuid,_project uuid)
returns void language plpgsql volatile security invoker set search_path='' as $$
declare owner_id uuid;
begin
 select user_id into owner_id from public.projects where id=_project for share;
 if not found then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
 if owner_id=_account then return;end if;
 perform 1 from public.project_collaborators where project_id=_project and user_id=_account and status='accepted' for share;
 if not found then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
end $$;
create function taskfold_private.automation_lock_task_access(_account uuid,_owner uuid,_project uuid)
returns void language plpgsql volatile security invoker set search_path='' as $$
begin
 if _project is not null then perform taskfold_private.automation_lock_project(_account,_project);
 elsif _owner is distinct from _account then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
end $$;

-- Explicit projection: adding a future public.tasks column never publishes it.
create function taskfold_private.automation_task_projection(t public.tasks)
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('id',t.id,'user_id',t.user_id,'task_generation',t.task_generation,'completion_version',t.completion_version,
 'title',t.title,'description',t.description,'completed',t.completed,'completed_at',t.completed_at,'created_at',t.created_at,'priority',t.priority,
 'due_date',t.due_date,'due_time',t.due_time,'project_id',t.project_id,'section_id',t.section_id,'labels',t.labels,'subtasks',t.subtasks,
 'reminders',t.reminders,'reminder_specs',t.reminder_specs,'attachments',t.attachments,'comments',t.comments,
 'is_recurring',t.is_recurring,'recurrence_pattern',t.recurrence_pattern,'recurrence_parent_id',t.recurrence_parent_id,'recurrence_end_date',t.recurrence_end_date,
 'notification_sent_at',t.notification_sent_at,'assigned_to',t.assigned_to,'deadline_date',t.deadline_date,'duration_minutes',t.duration_minutes,
 'time_zone',t.time_zone,'scheduled_at',t.scheduled_at,'source_metadata',t.source_metadata)
$$;

create function taskfold_private.automation_task_read(_key uuid,_hash text,_action text,_body jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare account uuid; t public.tasks; cursor_task public.tasks; page jsonb:='[]'; result jsonb; page_limit int:=25; page_count int:=0; more boolean:=false; last_id uuid;
 pattern constant text:='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
begin
 -- Authorization, expiry/quota updates, task/membership locks and the read share
 -- this transaction. Never split credential authorization into a separate RPC.
 account:=taskfold_private.automation_authorize(_key,_hash,'tasks:read');
 if _body is null or jsonb_typeof(_body)<>'object' or octet_length(_body::text)>8192 then raise exception using errcode='22023',message='Invalid task read';end if;
 if _action='get' then
  if (select array_agg(k order by k) from jsonb_object_keys(_body) k) is distinct from array['id'] or jsonb_typeof(_body->'id') is distinct from 'string' or (_body->>'id')!~pattern then raise exception using errcode='22023',message='Invalid task identity';end if;
  select * into t from public.tasks where id=(_body->>'id')::uuid for share;
  if not found then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
  perform taskfold_private.automation_lock_task_access(account,t.user_id,t.project_id);
  result:=jsonb_build_object('task',taskfold_private.automation_task_projection(t));
 elsif _action='list' then
  if exists(select 1 from jsonb_object_keys(_body) k where k not in('after','limit','project_id','completed')) then raise exception using errcode='22023',message='Invalid task page';end if;
  if _body ? 'limit' then
   if jsonb_typeof(_body->'limit') is distinct from 'number' then raise exception using errcode='22023',message='Invalid page size';end if;
   if (_body->>'limit')::numeric not between 1 and 50 or (_body->>'limit')::numeric<>trunc((_body->>'limit')::numeric) then raise exception using errcode='22023',message='Invalid page size';end if;
   page_limit:=(_body->>'limit')::numeric::int;
  end if;
  if _body ? 'completed' and jsonb_typeof(_body->'completed') is distinct from 'boolean' then raise exception using errcode='22023',message='Invalid completion filter';end if;
  if _body ? 'project_id' and _body->'project_id'<>'null'::jsonb then
   if jsonb_typeof(_body->'project_id') is distinct from 'string' or (_body->>'project_id')!~pattern then raise exception using errcode='22023',message='Invalid project filter';end if;
   perform taskfold_private.automation_lock_project(account,(_body->>'project_id')::uuid);
  end if;
  if _body ? 'after' then
   if jsonb_typeof(_body->'after') is distinct from 'string' or (_body->>'after')!~pattern then raise exception using errcode='22023',message='Invalid task cursor';end if;
   select * into cursor_task from public.tasks where id=(_body->>'after')::uuid for share;
   if not found then raise exception using errcode='PT404',message='Task page is unavailable';end if;
   perform taskfold_private.automation_lock_task_access(account,cursor_task.user_id,cursor_task.project_id);
   if (_body ? 'completed' and cursor_task.completed is distinct from (_body->>'completed')::boolean)
    or (_body ? 'project_id' and cursor_task.project_id is distinct from (_body->>'project_id')::uuid) then raise exception using errcode='PT404',message='Task page is unavailable';end if;
  end if;
  for t in select * from public.tasks x where ((x.project_id is null and x.user_id=account) or public.has_project_access(account,x.project_id))
   and (not (_body ? 'project_id') or x.project_id is not distinct from (_body->>'project_id')::uuid)
   and (not (_body ? 'completed') or x.completed=(_body->>'completed')::boolean)
   and (cursor_task.id is null or x.id>cursor_task.id) order by x.id limit page_limit+1 for share loop
    perform taskfold_private.automation_lock_task_access(account,t.user_id,t.project_id);
    if page_count=page_limit then more:=true;exit;end if;
    page:=page||jsonb_build_array(taskfold_private.automation_task_projection(t));last_id:=t.id;page_count:=page_count+1;
  end loop;
  result:=jsonb_build_object('tasks',page,'next_cursor',case when more then last_id else null end);
 else raise exception using errcode='22023',message='Invalid task read action';end if;
 if octet_length(result::text)>256000 then raise exception using errcode='PT413',message='This task page is too large; request fewer tasks';end if;
 return result;
end $$;
create function public.taskfold_automation_read(_key uuid,_hash text,_action text,_body jsonb)
returns jsonb language sql volatile security invoker set search_path='' as $$select taskfold_private.automation_task_read(_key,_hash,_action,_body)$$;
revoke all on function taskfold_private.automation_lock_project(uuid,uuid),taskfold_private.automation_lock_task_access(uuid,uuid,uuid),
 taskfold_private.automation_task_projection(public.tasks) from public,anon,authenticated,service_role;
revoke all on function taskfold_private.automation_task_read(uuid,text,text,jsonb),public.taskfold_automation_read(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.automation_task_read(uuid,text,text,jsonb),public.taskfold_automation_read(uuid,text,text,jsonb) to service_role;

-- The journal deliberately has no FK to tasks/generations or retention job:
-- deletion, recreation and later completion cycles cannot erase a request claim.
-- Only deleting its Auth account removes it. It stores no task text/body/secret.
create table taskfold_private.automation_requests(
 user_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null,
 key_id uuid references taskfold_private.automation_keys(id) on delete set null,
 operation text not null check(operation in('create','update','complete','delete')),
 payload_hash text not null check(payload_hash~'^[0-9a-f]{64}$'),
 task_id uuid not null,
 input_generation uuid,
 access_owner uuid not null,
 access_project uuid,
 started_xid xid8 not null default pg_current_xact_id(),
 created_at timestamptz not null default clock_timestamp(),
 applied_at timestamptz,
 result_generation uuid,
 result_completion_version bigint check(result_completion_version>=0),
 successor_id uuid,
 successor_generation uuid,
 deleted boolean,
 primary key(user_id,request_id),
 check((successor_id is null)=(successor_generation is null)),
 check(applied_at is null or (deleted is not null and
  ((operation='delete' and deleted and result_generation is null and result_completion_version is null and successor_id is null)
   or (operation<>'delete' and not deleted and result_completion_version is not null))))
);
create index automation_requests_key on taskfold_private.automation_requests(key_id) where key_id is not null;
alter table taskfold_private.automation_requests enable row level security;
revoke all on taskfold_private.automation_requests from public,anon,authenticated,service_role;

-- FK cascades and deferred COMMIT checks can run under the Auth/service role,
-- after a write wrapper has returned. These private trigger functions require
-- owner privileges to inspect the journal/Auth row; clients get no EXECUTE.
create function taskfold_private.automation_request_immutable() returns trigger
language plpgsql volatile security definer set search_path='' as $$
begin
 if tg_op='DELETE' then
  if exists(select 1 from auth.users where id=old.user_id) then raise exception using errcode='PT409',message='Automation request history cannot be removed';end if;
  return old;
 end if;
 if (to_jsonb(new)-array['key_id','applied_at','result_generation','result_completion_version','successor_id','successor_generation','deleted'])
  is distinct from (to_jsonb(old)-array['key_id','applied_at','result_generation','result_completion_version','successor_id','successor_generation','deleted']) then raise exception using errcode='PT409',message='Automation request identity cannot change';end if;
 if new.key_id is distinct from old.key_id and (new.key_id is not null or exists(select 1 from taskfold_private.automation_keys where id=old.key_id)) then raise exception using errcode='PT409',message='Automation request owner cannot change';end if;
 if old.applied_at is not null and (to_jsonb(new)-'key_id') is distinct from (to_jsonb(old)-'key_id') then raise exception using errcode='PT409',message='Automation result cannot change';end if;
 return new;
end $$;
create trigger taskfold_automation_request_immutable before update or delete on taskfold_private.automation_requests for each row execute function taskfold_private.automation_request_immutable();

create function taskfold_private.automation_request_complete_at_commit() returns trigger
language plpgsql volatile security definer set search_path='' as $$
begin
 if exists(select 1 from taskfold_private.automation_requests where user_id=new.user_id and request_id=new.request_id and applied_at is null) then
  raise exception using errcode='PT409',message='An automation request must commit with its task result';end if;
 return null;
end $$;
create constraint trigger taskfold_automation_request_atomic after insert or update on taskfold_private.automation_requests
 deferrable initially deferred for each row execute function taskfold_private.automation_request_complete_at_commit();

create function taskfold_private.automation_request_receipt(r taskfold_private.automation_requests)
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('request_id',r.request_id,'operation',r.operation,'task_id',r.task_id,'task_generation',r.result_generation,
 'completion_version',r.result_completion_version,'successor_id',r.successor_id,'successor_generation',r.successor_generation,'deleted',r.deleted,'applied_at',r.applied_at)
$$;

-- PRIVATE ONLY. A future write RPC calls begin -> native guarded effects -> finish
-- within one transaction. Pending claims cannot commit and finish cannot move to
-- another transaction. Never expose either helper as a separate service endpoint.
create function taskfold_private.automation_request_begin(_key uuid,_hash text,_request uuid,_operation text,_task uuid,_generation uuid,_payload jsonb,_create_project uuid default null)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare account uuid; r taskfold_private.automation_requests; t public.tasks; body_hash text; target_exists boolean;
begin
 if _operation is null or _operation not in('create','update','complete','delete') then raise exception using errcode='22023',message='Invalid automation operation';end if;
 account:=taskfold_private.automation_authorize(_key,_hash,'tasks:'||_operation);
 if _request is null or _request='00000000-0000-0000-0000-000000000000' or _task is null or _task='00000000-0000-0000-0000-000000000000'
  or _payload is null or jsonb_typeof(_payload)<>'object' or octet_length(_payload::text)>65536 then raise exception using errcode='22023',message='Invalid automation request';end if;
 if _generation='00000000-0000-0000-0000-000000000000' or (_operation='create' and _generation is null) or (_operation<>'create' and _create_project is not null) then raise exception using errcode='22023',message='Invalid task generation';end if;
 body_hash:=encode(extensions.digest(_payload::text,'sha256'),'hex');
 -- Same mutex as native create-only generation guarding. Acquire before reading
 -- task identity so a concurrent insert cannot slip between check and effect.
 perform pg_advisory_xact_lock(hashtextextended(_task::text,78137));
 select * into r from taskfold_private.automation_requests where user_id=account and request_id=_request for update;
 if found then
  -- Reauthorize the resource recorded by the claim, before even distinguishing
  -- an exact retry from a changed request. Never trust its caller's replacement
  -- task ID to decide which old request can be disclosed.
  select * into t from public.tasks where id=r.task_id for share;target_exists:=found;
  if target_exists then
   perform taskfold_private.automation_lock_task_access(account,t.user_id,t.project_id);
   if t.task_generation is distinct from r.input_generation then raise exception using errcode='PT409',message='This request belongs to an earlier task';end if;
  else perform taskfold_private.automation_lock_task_access(account,r.access_owner,r.access_project);end if;
  if r.operation is distinct from _operation or r.task_id is distinct from _task or r.input_generation is distinct from _generation or r.payload_hash<>body_hash
   or (_operation='create' and r.access_project is distinct from _create_project) then raise exception using errcode='PT409',message='This request ID already belongs to another operation';end if;
  if r.applied_at is null then raise exception using errcode='PT409',message='This request is already being applied';end if;
  return jsonb_build_object('replayed',true,'account',account,'receipt',taskfold_private.automation_request_receipt(r));
 end if;
 select * into t from public.tasks where id=_task for update;target_exists:=found;
 if _operation='create' then
  if target_exists then
   perform taskfold_private.automation_lock_task_access(account,t.user_id,t.project_id);
   raise exception using errcode='PT409',message='Task identity is already in use';
  end if;
  if _create_project is not null then perform taskfold_private.automation_lock_project(account,_create_project);end if;
  t.user_id:=account;t.project_id:=_create_project;
 else
  if not target_exists then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
  perform taskfold_private.automation_lock_task_access(account,t.user_id,t.project_id);
  if t.task_generation is distinct from _generation then raise exception using errcode='PT409',message='This request belongs to an earlier task';end if;
 end if;
 insert into taskfold_private.automation_requests(user_id,request_id,key_id,operation,payload_hash,task_id,input_generation,access_owner,access_project)
 values(account,_request,_key,_operation,body_hash,_task,_generation,t.user_id,t.project_id);
 return jsonb_build_object('replayed',false,'account',account,'request_id',_request);
end $$;

create function taskfold_private.automation_request_finish(_account uuid,_request uuid,_generation uuid,_completion_version bigint,_successor uuid default null,_successor_generation uuid default null)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare r taskfold_private.automation_requests;t public.tasks;next_task public.tasks;
begin
 select * into r from taskfold_private.automation_requests where user_id=_account and request_id=_request for update;
 if not found or r.applied_at is not null or r.started_xid<>pg_current_xact_id() then raise exception using errcode='PT409',message='No current automation operation is awaiting this result';end if;
 if (_successor is null)<>(_successor_generation is null) or (r.operation<>'complete' and _successor is not null) then raise exception using errcode='22023',message='Invalid successor receipt';end if;
 select * into t from public.tasks where id=r.task_id for update;
 if r.operation='delete' then
  if found or _generation is not null or _completion_version is not null or _successor is not null then raise exception using errcode='PT409',message='Task deletion is not confirmed';end if;
 else
  if not found or _generation is distinct from r.input_generation or t.task_generation is distinct from _generation or _completion_version is null or t.completion_version is distinct from _completion_version then raise exception using errcode='PT409',message='Task result is not confirmed';end if;
  perform taskfold_private.automation_lock_task_access(_account,t.user_id,t.project_id);
  if r.operation='complete' and not t.completed then raise exception using errcode='PT409',message='Task completion is not confirmed';end if;
  if r.operation='create' and (t.user_id is distinct from _account or t.project_id is distinct from r.access_project) then raise exception using errcode='PT409',message='Task creation ownership is not confirmed';end if;
 end if;
 if _successor is not null then
  select * into next_task from public.tasks where id=_successor for share;
  if not found or next_task.task_generation is distinct from _successor_generation or next_task.recurrence_parent_id is distinct from coalesce(t.recurrence_parent_id,t.id) then raise exception using errcode='PT409',message='Recurring successor is not confirmed';end if;
  perform taskfold_private.automation_lock_task_access(_account,next_task.user_id,next_task.project_id);
 end if;
 update taskfold_private.automation_requests set applied_at=clock_timestamp(),result_generation=_generation,result_completion_version=_completion_version,
 successor_id=_successor,successor_generation=_successor_generation,deleted=(r.operation='delete') where user_id=_account and request_id=_request returning * into r;
 return taskfold_private.automation_request_receipt(r);
end $$;
revoke all on function taskfold_private.automation_request_immutable(),taskfold_private.automation_request_complete_at_commit(),
 taskfold_private.automation_request_receipt(taskfold_private.automation_requests),
 taskfold_private.automation_request_begin(uuid,text,uuid,text,uuid,uuid,jsonb,uuid),
 taskfold_private.automation_request_finish(uuid,uuid,uuid,bigint,uuid,uuid)
 from public,anon,authenticated,service_role;
