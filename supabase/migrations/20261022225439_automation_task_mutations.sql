-- Candidate, not deployed: all task effects and journal receipts share one RPC.
-- Reopen uses the complete capability; request identities remain operation-bound.
alter table taskfold_private.automation_requests drop constraint automation_requests_operation_check;
alter table taskfold_private.automation_requests add constraint automation_requests_operation_check
 check(operation in('create','update','complete','reopen','delete'));

alter table taskfold_private.automation_requests add column successor_access_owner uuid,add column successor_access_project uuid;
create or replace function taskfold_private.automation_request_immutable() returns trigger
language plpgsql volatile security definer set search_path='' as $$
begin
 if tg_op='DELETE' then
  if exists(select 1 from auth.users where id=old.user_id) then raise exception using errcode='PT409',message='Automation request history cannot be removed';end if;
  return old;
 end if;
 if (to_jsonb(new)-array['key_id','applied_at','result_generation','result_completion_version','successor_id','successor_generation','deleted','successor_access_owner','successor_access_project'])
  is distinct from (to_jsonb(old)-array['key_id','applied_at','result_generation','result_completion_version','successor_id','successor_generation','deleted','successor_access_owner','successor_access_project']) then raise exception using errcode='PT409',message='Automation request identity cannot change';end if;
 if new.key_id is distinct from old.key_id and (new.key_id is not null or exists(select 1 from taskfold_private.automation_keys where id=old.key_id)) then raise exception using errcode='PT409',message='Automation request owner cannot change';end if;
 if old.applied_at is not null and (to_jsonb(new)-'key_id') is distinct from (to_jsonb(old)-'key_id') then raise exception using errcode='PT409',message='Automation result cannot change';end if;
 return new;
end $$;

-- Pair key authorization with non-key Auth account changes such as bans.
create or replace function taskfold_private.automation_account_lock(_account uuid) returns void
language plpgsql volatile security definer set search_path='' as $$
begin
 if _account is null then raise exception using errcode='28000',message='Sign in again'; end if;
 perform pg_advisory_xact_lock(hashtextextended('automation:'||_account::text,11819));
 perform 1 from auth.users where id=_account and (banned_until is null or banned_until<=clock_timestamp()) for share;
 if not found or exists(select 1 from taskfold_private.account_removal_receipts where account_id=_account and created_at>clock_timestamp()-interval '7 days') then
  raise exception using errcode='28000',message='Account access is unavailable';
 end if;
end$$;

-- Opaque whole-row revisions permit exact deletion review without resending task
-- content. HMAC prevents a future unprojected column becoming a guessable hash.
create table taskfold_private.automation_revision_secret(
 singleton boolean primary key default true check(singleton),
 secret bytea not null check(octet_length(secret)=32)
);
insert into taskfold_private.automation_revision_secret values(true,extensions.gen_random_bytes(32));
alter table taskfold_private.automation_revision_secret enable row level security;
revoke all on taskfold_private.automation_revision_secret from public,anon,authenticated,service_role;
create function taskfold_private.automation_task_revision(t public.tasks)
returns text language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.hmac(convert_to(to_jsonb(t)::text,'UTF8'),s.secret,'sha256'),'hex')
 from taskfold_private.automation_revision_secret s where singleton
$$;
revoke all on function taskfold_private.automation_task_revision(public.tasks) from public,anon,authenticated,service_role;

create or replace function taskfold_private.automation_task_projection(t public.tasks)
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('id',t.id,'user_id',t.user_id,'task_generation',t.task_generation,'completion_version',t.completion_version,
 'title',t.title,'description',t.description,'completed',t.completed,'completed_at',t.completed_at,'created_at',t.created_at,'priority',t.priority,
 'due_date',t.due_date,'due_time',t.due_time,'project_id',t.project_id,'section_id',t.section_id,'labels',t.labels,'subtasks',t.subtasks,
 'reminders',t.reminders,'reminder_specs',t.reminder_specs,'attachments',t.attachments,'comments',t.comments,
 'is_recurring',t.is_recurring,'recurrence_pattern',t.recurrence_pattern,'recurrence_parent_id',t.recurrence_parent_id,'recurrence_end_date',t.recurrence_end_date,
 'notification_sent_at',t.notification_sent_at,'assigned_to',t.assigned_to,'deadline_date',t.deadline_date,'duration_minutes',t.duration_minutes,
 'time_zone',t.time_zone,'scheduled_at',t.scheduled_at,'source_metadata',t.source_metadata,'revision',taskfold_private.automation_task_revision(t))
$$;

create or replace function taskfold_private.automation_task_read(_key uuid,_hash text,_action text,_body jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
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
 if octet_length(result::text)>1048576 then raise exception using errcode='PT413',message='This task page is too large; request fewer tasks';end if;
 return result;
end $$;

create or replace function public.taskfold_automation_read(_key uuid,_hash text,_action text,_body jsonb) returns jsonb language sql volatile security invoker set search_path='' set statement_timeout='10s' as $$select taskfold_private.automation_task_read(_key,_hash,_action,_body)$$;

create or replace function taskfold_private.automation_request_begin(_key uuid,_hash text,_request uuid,_operation text,_task uuid,_generation uuid,_payload jsonb,_create_project uuid default null)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare account uuid; r taskfold_private.automation_requests; t public.tasks; body_hash text; target_exists boolean;
begin
 if _operation is null or _operation not in('create','update','complete','reopen','delete') then raise exception using errcode='22023',message='Invalid automation operation';end if;
 account:=taskfold_private.automation_authorize(_key,_hash,case when _operation='reopen' then 'tasks:complete' else 'tasks:'||_operation end);
 if _request is null or _request='00000000-0000-0000-0000-000000000000' or _task is null or _task='00000000-0000-0000-0000-000000000000'
  or _payload is null or jsonb_typeof(_payload)<>'object' or octet_length(_payload::text)>1048576 then raise exception using errcode='22023',message='Invalid automation request';end if;
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
  if r.successor_id is not null then
   select * into t from public.tasks where id=r.successor_id for share;target_exists:=found;
   if target_exists then
    perform taskfold_private.automation_lock_task_access(account,t.user_id,t.project_id);
    if t.task_generation is distinct from r.successor_generation then raise exception using errcode='PT409',message='This successor belongs to an earlier task';end if;
   else perform taskfold_private.automation_lock_task_access(account,r.successor_access_owner,r.successor_access_project);end if;
  end if;
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

create or replace function taskfold_private.automation_request_finish(_account uuid,_request uuid,_generation uuid,_completion_version bigint,_successor uuid default null,_successor_generation uuid default null)
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
  if (r.operation='complete' and not t.completed) or (r.operation='reopen' and t.completed) then raise exception using errcode='PT409',message='Task completion is not confirmed';end if;
  if r.operation='create' and (t.user_id is distinct from _account or t.project_id is distinct from r.access_project) then raise exception using errcode='PT409',message='Task creation ownership is not confirmed';end if;
 end if;
 if _successor is not null then
  select * into next_task from public.tasks where id=_successor for share;
  if not found or next_task.task_generation is distinct from _successor_generation or next_task.recurrence_parent_id is distinct from coalesce(t.recurrence_parent_id,t.id) then raise exception using errcode='PT409',message='Recurring successor is not confirmed';end if;
  perform taskfold_private.automation_lock_task_access(_account,next_task.user_id,next_task.project_id);
 end if;
 update taskfold_private.automation_requests set applied_at=clock_timestamp(),result_generation=_generation,result_completion_version=_completion_version,
 successor_id=_successor,successor_generation=_successor_generation,successor_access_owner=next_task.user_id,successor_access_project=next_task.project_id,deleted=(r.operation='delete') where user_id=_account and request_id=_request returning * into r;
 return taskfold_private.automation_request_receipt(r);
end $$;

create function taskfold_private.automation_require_scope(_key uuid,_account uuid,_scope text)
returns void language plpgsql volatile security invoker set search_path='' as $$
begin
 -- The journal's authorizer already owns the account/key locks and quota. This
 -- extra capability check never double-charges a compound native operation.
 perform 1 from taskfold_private.automation_keys where id=_key and user_id=_account and _scope=any(scopes) and revoked_at is null and expires_at>clock_timestamp();
 if not found then raise exception using errcode='42501',message='This key does not allow that action';end if;
end $$;
create function taskfold_private.automation_writable_project(_account uuid,_project uuid)
returns void language plpgsql volatile security invoker set search_path='' as $$
begin
 if _project is null then return;end if;
 perform taskfold_private.automation_lock_project(_account,_project);
 if exists(select 1 from public.projects where id=_project and (is_archived or ancestor_archived)) then raise exception using errcode='PT409',message='Restore this project before editing its tasks';end if;
end $$;
create function taskfold_private.automation_member(_person uuid,_project uuid,_owner uuid)
returns void language plpgsql volatile security invoker set search_path='' as $$
begin
 if _person is null then return;end if;
 if _project is null then
  if _person is distinct from _owner then raise exception using errcode='22023',message='Inbox tasks can only be assigned to their creator';end if;
 else perform taskfold_private.automation_lock_project(_person,_project);end if;
end $$;
create function taskfold_private.automation_preference_minutes(_account uuid) returns int
language plpgsql volatile security invoker set search_path='' as $$
declare document jsonb;begin
 -- Establish the missing default row so a concurrent first preference write
 -- serializes with this decision as well as later updates to an existing row.
 insert into public.reminder_preferences(user_id,id,settings) values(_account,'current','{"version":1,"snooze_minutes":60}') on conflict(user_id,id) do nothing;
 select settings into document from public.reminder_preferences where user_id=_account and id='current' for share;
 if not taskfold_private.valid_reminder_preferences(document) or document->'version' is distinct from '1'::jsonb then return null;end if;
 return coalesce((document->>'automatic_before_minutes')::numeric::int,0);
end $$;

-- Current-row review is opaque, byte-bounded and generation-bound. Task locks
-- prevent edits while the native full-baseline guard applies the effect.
create function taskfold_private.automation_review_delete(_account uuid,_root uuid,_revision text,_descendants jsonb)
returns void language plpgsql volatile security invoker set search_path='' as $$
declare t public.tasks; expected jsonb; seen uuid[]:=array[]::uuid[]; ids uuid[];item jsonb;
begin
 if _revision is null or _revision!~'^[0-9a-f]{64}$' or jsonb_typeof(_descendants) is distinct from 'array' or jsonb_array_length(_descendants)>1000 then raise exception using errcode='22023',message='Review the complete deletion before continuing';end if;
 for item in select * from jsonb_array_elements(_descendants) loop
  if jsonb_typeof(item)<>'object' or (select array_agg(k order by k) from jsonb_object_keys(item) k) is distinct from array['id','revision','task_generation']
   or jsonb_typeof(item->'id') is distinct from 'string' or coalesce(item->>'id','')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
   or jsonb_typeof(item->'revision') is distinct from 'string' or coalesce(item->>'revision','')!~'^[0-9a-f]{64}$'
   or not(item ? 'task_generation') or (item->'task_generation'<>'null'::jsonb and (jsonb_typeof(item->'task_generation')<>'string' or coalesce(item->>'task_generation','')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')) then raise exception using errcode='22023',message='Invalid linked-task review';end if;
  if (item->>'id')::uuid=any(seen) or (item->>'id')::uuid=_root then raise exception using errcode='22023',message='Review each linked task once';end if;
  seen:=array_append(seen,(item->>'id')::uuid);
 end loop;
 select * into t from public.tasks where id=_root for update;
 if not found or taskfold_private.automation_task_revision(t) is distinct from _revision then raise exception using errcode='PT409',message='This deletion changed; review the current tasks';end if;
 -- Root FOR UPDATE excludes new direct descendants' FK key-share locks. Lock
 -- the discovered family, then enumerate again after all descendants are held.
 with recursive family(id) as (select id from public.tasks where recurrence_parent_id=_root and id<>_root
  union select x.id from public.tasks x join family f on x.recurrence_parent_id=f.id where x.id<>_root)
 select coalesce(array_agg(id order by id),array[]::uuid[]) into ids from family;
 if cardinality(ids)>1000 or ids is distinct from (select coalesce(array_agg(x order by x),array[]::uuid[]) from unnest(seen) x) then raise exception using errcode='PT409',message='The linked tasks changed; review the complete deletion';end if;
 for t in select * from public.tasks where id=any(ids) order by id for update loop
  perform taskfold_private.automation_lock_task_access(_account,t.user_id,t.project_id);
  perform taskfold_private.automation_writable_project(_account,t.project_id);
  select value into expected from jsonb_array_elements(_descendants) where (value->>'id')::uuid=t.id;
  if t.task_generation is distinct from (expected->>'task_generation')::uuid or taskfold_private.automation_task_revision(t) is distinct from expected->>'revision' then raise exception using errcode='PT409',message='The linked tasks changed; review the complete deletion';end if;
 end loop;
 with recursive family(id) as (select id from public.tasks where recurrence_parent_id=_root and id<>_root
  union select x.id from public.tasks x join family f on x.recurrence_parent_id=f.id where x.id<>_root)
 select coalesce(array_agg(id order by id),array[]::uuid[]) into seen from family;
 if seen is distinct from ids then raise exception using errcode='PT409',message='The linked tasks changed; review the complete deletion';end if;
end $$;

-- API checklist nodes merge supplied writable fields into the reviewed node.
-- Omitted opaque/read-only fields survive, rather than turning a checklist edit
-- into forged comment/history metadata. Structure/order is still explicit.
create function taskfold_private.automation_tree_index(rows jsonb)
returns jsonb language plpgsql immutable security invoker set search_path='' as $$
declare result jsonb:='{}';item record;counted int:=0;begin
 if jsonb_typeof(rows) is distinct from 'array' then raise exception using errcode='22023',message='Use a checklist array';end if;
 for item in with recursive nodes(n,depth) as (
  select value,1 from jsonb_array_elements(rows)
  union all select value,depth+1 from nodes cross join lateral jsonb_array_elements(case when depth<25 and jsonb_typeof(n->'subtasks')='array' then n->'subtasks' else '[]'::jsonb end)
 ) select * from nodes loop
  counted:=counted+1;
  if counted>1000 or item.depth>24 or jsonb_typeof(item.n)<>'object' or jsonb_typeof(item.n->'id') is distinct from 'string' or coalesce(item.n->>'id','')='' or octet_length(item.n->>'id')>128 or result ? (item.n->>'id')
   or (item.n ? 'subtasks' and jsonb_typeof(item.n->'subtasks')<>'array') then raise exception using errcode='22023',message='Use unique checklist IDs and a supported layout';end if;
  result:=result||jsonb_build_object(item.n->>'id',item.n);
 end loop;
 return result;
end $$;
create function taskfold_private.automation_tree(rows jsonb,old_nodes jsonb,_project uuid,_owner uuid,_at timestamptz,depth int default 0)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare result jsonb:='[]';row jsonb;old jsonb;merged jsonb;k text;allowed text[]:=array['id','title','description','completed','completed_at','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','reminder_specs','subtasks'];begin
 if depth>=24 and jsonb_array_length(rows)>0 then raise exception using errcode='22023',message='Use a supported checklist depth';end if;
 for row in select * from jsonb_array_elements(rows) loop
  old:=coalesce(old_nodes->(row->>'id'),'{}');
  for k in select jsonb_object_keys(row) loop
   if not k=any(allowed) and row->k is distinct from old->k and not (old='{}'::jsonb and k in('comments','attachments') and row->k in('[]'::jsonb,'null'::jsonb)) and not (old='{}'::jsonb and k='source_metadata' and row->k in('{}'::jsonb,'null'::jsonb)) then raise exception using errcode='22023',message='Checklist history and unknown fields are read-only';end if;
  end loop;
  perform taskfold_private.automation_validate_fields((select coalesce(jsonb_object_agg(e.k,e.v),'{}') from jsonb_each(row) e(k,v) where e.k=any(array['title','description','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','reminder_specs'])),old);
  merged:=old||row;
  if row ? 'completed' and coalesce(old->'completed','false') is distinct from row->'completed' then
   merged:=merged||jsonb_build_object('completed_at',case when row->'completed'='true'::jsonb then _at else null end);
  elsif row ? 'completed_at' and row->'completed_at' is distinct from old->'completed_at' and not (row->'completed_at'='null'::jsonb and old->'completed_at' is null) then raise exception using errcode='22023',message='Change checklist completion state rather than its history';end if;
  if coalesce(merged->>'title','')='' or jsonb_typeof(merged->'title')<>'string'
   or (merged ? 'completed' and jsonb_typeof(merged->'completed')<>'boolean') then raise exception using errcode='22023',message='Give checklist items a title and valid state';end if;
  if merged->'assigned_to' is not null and merged->'assigned_to'<>'null'::jsonb then
   if jsonb_typeof(merged->'assigned_to')<>'string' or (merged->>'assigned_to')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then raise exception using errcode='22023',message='Invalid checklist assignee';end if;
   perform taskfold_private.automation_member((merged->>'assigned_to')::uuid,_project,_owner);
  end if;
  merged:=merged||jsonb_build_object('subtasks',taskfold_private.automation_tree(coalesce(row->'subtasks',old->'subtasks','[]'),old_nodes,_project,_owner,_at,depth+1));
  result:=result||jsonb_build_array(merged);
 end loop;
 return result;
end $$;
create function taskfold_private.automation_tree_progress(rows jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare nodes jsonb;result jsonb:='{}';k text;v jsonb;begin
 nodes:=taskfold_private.automation_tree_index(rows);
 for k,v in select * from jsonb_each(nodes) loop
  if v->'completed'='true'::jsonb or (v->'completed_at' is not null and v->'completed_at'<>'null'::jsonb) then result:=result||jsonb_build_object(k,jsonb_build_array(coalesce(v->'completed','false'),v->'completed_at'));end if;
 end loop;
 return result;
end $$;

create function taskfold_private.automation_validate_fields(f jsonb,previous jsonb)
returns void language plpgsql stable security invoker set search_path='' as $$
declare k text;v jsonb;s jsonb;old jsonb;previous_specs jsonb:=case when jsonb_typeof(previous->'reminder_specs')='array' then previous->'reminder_specs' else '[]'::jsonb end;ids uuid[]:=array[]::uuid[];n numeric;
 allowed constant text[]:=array['title','description','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','reminder_specs','recurrence_pattern','is_recurring','recurrence_end_date','assigned_to','deadline_date','duration_minutes','time_zone','scheduled_at'];
begin
 if jsonb_typeof(f) is distinct from 'object' or exists(select 1 from jsonb_object_keys(f) x where not x=any(allowed)) then raise exception using errcode='22023',message='Use supported task detail fields';end if;
 for k,v in select * from jsonb_each(f) loop
  if k='title' then
   if jsonb_typeof(v)<>'string' or length(regexp_replace(v#>>'{}','[[:space:]]','','g'))=0 or octet_length(v#>>'{}')>8192 then raise exception using errcode='22023',message='Give the task a supported title';end if;
  elsif k='description' then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or octet_length(v#>>'{}')>512000) then raise exception using errcode='22023',message='Use a supported task description';end if;
  elsif k in('priority','duration_minutes') then
   if k='duration_minutes' and v='null'::jsonb then continue;end if;
   if jsonb_typeof(v)<>'number' then raise exception using errcode='22023',message='Use a whole-number priority or estimate';end if;
   n:=v::text::numeric;
   if n<>trunc(n) or (k='priority' and n not between 1 and 4) or (k='duration_minutes' and n not between 1 and 10080) then raise exception using errcode='22023',message='Use a supported priority or estimate';end if;
  elsif k in('due_date','deadline_date','recurrence_end_date') then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or taskfold_private.automation_civil_day(v#>>'{}') is null) then raise exception using errcode='22023',message='Use an ISO calendar date';end if;
  elsif k='due_time' then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or (v#>>'{}')!~'^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9](\.[0-9]+)?)?$') then raise exception using errcode='22023',message='Use a valid task clock';end if;
  elsif k in('project_id','section_id','assigned_to') then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or (v#>>'{}')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') then raise exception using errcode='22023',message='Use a valid task reference';end if;
  elsif k='time_zone' then
   if v<>'null'::jsonb and (jsonb_typeof(v)<>'string' or not exists(select 1 from pg_catalog.pg_timezone_names where name=v#>>'{}')) then raise exception using errcode='22023',message='Choose a named time zone';end if;
  elsif k='scheduled_at' then
   if v<>'null'::jsonb then
    if jsonb_typeof(v)<>'string' or (v#>>'{}')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.[0-9]+)?(Z|[+-]\d{2}:?\d{2})$' or not isfinite((v#>>'{}')::timestamptz) then raise exception using errcode='22023',message='Use an explicit scheduled instant';end if;
   end if;
  elsif k in('labels','reminders') then
   if jsonb_typeof(v)<>'array' or jsonb_array_length(v)>256 then raise exception using errcode='22023',message='Use a bounded text list';end if;
   if exists(select 1 from jsonb_array_elements(v) e where jsonb_typeof(e)<>'string' or octet_length(e#>>'{}')>1024 or length(e#>>'{}')=0) then raise exception using errcode='22023',message='Use nonempty text list values';end if;
  elsif k='is_recurring' and jsonb_typeof(v)<>'boolean' then raise exception using errcode='22023',message='Use a valid repeat state';
  elsif k='recurrence_pattern' and v<>'null'::jsonb and jsonb_typeof(v)<>'object' then raise exception using errcode='22023',message='Use a repeat rule object';
  elsif k='reminder_specs' then
   if jsonb_typeof(v)<>'array' or jsonb_array_length(v)>20 then raise exception using errcode='22023',message='Use up to twenty reminder choices';end if;
   for s in select * from jsonb_array_elements(v) loop
    if jsonb_typeof(s)<>'object' or coalesce(s->>'id','')!~*'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then raise exception using errcode='22023',message='Use a valid reminder identity';end if;
    if (s->>'id')::uuid=any(ids) then raise exception using errcode='22023',message='Use unique reminder identities';end if;ids:=array_append(ids,(s->>'id')::uuid);
    if taskfold_private.automation_simple_reminder_kind(s) is null then
     if not exists(select 1 from jsonb_array_elements(previous_specs) e where e=s) then raise exception using errcode='22023',message='Create advanced or private reminders in Taskfold';end if;
    end if;
   end loop;
   for old in select * from jsonb_array_elements(previous_specs) loop
    if taskfold_private.automation_simple_reminder_kind(old) is null and not exists(select 1 from jsonb_array_elements(v) e where e=old) then raise exception using errcode='22023',message='Preserve advanced and private reminder choices';end if;
   end loop;
  end if;
 end loop;
end $$;

create function taskfold_private.automation_clear_assignees(rows jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare result jsonb:='[]';n jsonb;begin
 for n in select * from jsonb_array_elements(rows) loop
  n:=n||'{"assigned_to":null}';
  if jsonb_typeof(n->'subtasks')='array' then n:=n||jsonb_build_object('subtasks',taskfold_private.automation_clear_assignees(n->'subtasks'));end if;
  result:=result||jsonb_build_array(n);
 end loop;return result;
end $$;

create function taskfold_private.automation_task_write(_key uuid,_hash text,_action text,_body jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare account uuid;start jsonb;receipt jsonb;task_id uuid;generation uuid;request_id uuid;zone text;fields jsonb;base jsonb;before public.tasks;t public.tasks;proposed public.tasks;
 next_task public.tasks;next_data jsonb;old_actor text:=current_setting('request.jwt.claim.sub',true);expected_keys text[];actual_keys text[];desired boolean;at_time timestamptz;minutes int;new_project uuid;new_assignee uuid;
 pattern constant text:='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$';
begin
 if _action is null or _action not in('create','update','complete','reopen','delete') or jsonb_typeof(_body) is distinct from 'object' or octet_length(_body::text)>1048576 then raise exception using errcode='22023',message='Use a supported bounded task operation';end if;
 expected_keys:=case _action when 'create' then array['fields','id','request_id','task_generation','time_zone'] when 'update' then array['base','fields','id','request_id','task_generation','time_zone'] when 'delete' then array['descendants','id','request_id','revision','task_generation','time_zone'] else array['base','id','request_id','task_generation','time_zone'] end;
 select array_agg(k order by k) into actual_keys from jsonb_object_keys(_body) k;
 if actual_keys is distinct from expected_keys or jsonb_typeof(_body->'id') is distinct from 'string' or coalesce(_body->>'id','')!~pattern
  or jsonb_typeof(_body->'request_id') is distinct from 'string' or coalesce(_body->>'request_id','')!~pattern
  or not(_body ? 'task_generation') or (_body->'task_generation'<>'null'::jsonb and (jsonb_typeof(_body->'task_generation')<>'string' or coalesce(_body->>'task_generation','')!~pattern))
  or jsonb_typeof(_body->'time_zone') is distinct from 'string' or not exists(select 1 from pg_catalog.pg_timezone_names where name=_body->>'time_zone') then raise exception using errcode='22023',message='Use valid operation identities and an explicit time zone';end if;
 task_id:=(_body->>'id')::uuid;generation:=(_body->>'task_generation')::uuid;request_id:=(_body->>'request_id')::uuid;zone:=_body->>'time_zone';fields:=_body->'fields';base:=_body->'base';
 if _action='create' then
  perform taskfold_private.automation_validate_fields(fields,null);
  if not(fields ? 'title') then raise exception using errcode='22023',message='Give the task a title';end if;
  new_project:=(fields->>'project_id')::uuid;
 elsif _action in('update','complete','reopen') then
  if jsonb_typeof(base) is distinct from 'object' or not(base ? 'task_generation') or (base->>'task_generation')::uuid is distinct from generation then raise exception using errcode='22023',message='Provide the reviewed task baseline';end if;
  if _action='update' then perform taskfold_private.automation_validate_fields(fields,base);end if;
 end if;
 start:=taskfold_private.automation_request_begin(_key,_hash,request_id,_action,task_id,generation,_body,case when _action='create' then new_project else null end);
 if (start->>'replayed')::boolean then return jsonb_build_object('replayed',true,'receipt',start->'receipt');end if;
 account:=(start->>'account')::uuid;
 perform set_config('request.jwt.claim.sub',account::text,true);
 at_time:=date_trunc('second',clock_timestamp());
 if _action='create' then
  perform taskfold_private.automation_writable_project(account,new_project);
  proposed:=jsonb_populate_record(null::public.tasks,'{"completed":false,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}'::jsonb||fields||jsonb_build_object('id',task_id,'user_id',account,'task_generation',generation,'completion_version',0,'created_at',at_time));
  if fields ? 'subtasks' then
   perform taskfold_private.automation_tree_index(fields->'subtasks');
   proposed.subtasks:=taskfold_private.automation_tree(fields->'subtasks','{}',new_project,account,at_time);
   if taskfold_private.automation_tree_progress(proposed.subtasks)<>'{}'::jsonb then perform taskfold_private.automation_require_scope(_key,account,'tasks:complete');end if;
  end if;
  perform taskfold_private.automation_member(proposed.assigned_to,new_project,account);
  if proposed.section_id is not null then
   perform 1 from public.sections where id=proposed.section_id and project_id=new_project for share;if not found then raise exception using errcode='22023',message='Choose a section in this project';end if;
  end if;
  if proposed.is_recurring and (proposed.due_date is null or not taskfold_private.automation_recurrence_valid(proposed.recurrence_pattern)) then raise exception using errcode='22023',message='Choose a supported repeat rule and due date';end if;
  next_data:=taskfold_private.automation_automatic_reminder(to_jsonb(proposed),null,0,zone);
  if next_data->'reminder_specs' is distinct from proposed.reminder_specs then minutes:=taskfold_private.automation_preference_minutes(account);proposed:=jsonb_populate_record(proposed,taskfold_private.automation_automatic_reminder(to_jsonb(proposed),null,minutes,zone));end if;
  if proposed.time_zone is not null then proposed.scheduled_at:=taskfold_private.automation_wall_start(to_jsonb(proposed),zone);else proposed.scheduled_at:=null;end if;
  insert into public.tasks select proposed.* returning * into t;
 elsif _action='delete' then
  select * into before from public.tasks where id=task_id for update;
  perform taskfold_private.automation_writable_project(account,before.project_id);
  perform taskfold_private.automation_review_delete(account,task_id,_body->>'revision',_body->'descendants');
  perform public.taskfold_delete_task(task_id,to_jsonb(before));
 else
  select * into before from public.tasks where id=task_id for update;
  perform taskfold_private.automation_writable_project(account,before.project_id);
  if _action='update' then
   if fields='{}'::jsonb then raise exception using errcode='22023',message='Choose task details to change';end if;
   proposed:=jsonb_populate_record(before,fields);new_project:=proposed.project_id;new_assignee:=proposed.assigned_to;
   perform taskfold_private.automation_writable_project(account,new_project);
   if new_project is null and before.user_id<>account then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
   if proposed.section_id is not null then
    if new_project is distinct from before.project_id and not(fields ? 'section_id') then fields:=fields||'{"section_id":null}';proposed.section_id:=null;
    else perform 1 from public.sections where id=proposed.section_id and project_id=new_project for share;if not found then raise exception using errcode='22023',message='Choose a section in this project';end if;end if;
   end if;
   if new_project is distinct from before.project_id then
    if not(base ?& array['assigned_to','subtasks','section_id']) then raise exception using errcode='22023',message='Include the reviewed project, section and assignment baseline';end if;
    fields:=fields||jsonb_build_object('subtasks',taskfold_private.automation_clear_assignees(coalesce(fields->'subtasks',base->'subtasks','[]')));
   end if;
   if fields ? 'subtasks' then
    perform taskfold_private.automation_tree_index(fields->'subtasks');
    fields:=fields||jsonb_build_object('subtasks',taskfold_private.automation_tree(fields->'subtasks',taskfold_private.automation_tree_index(coalesce(base->'subtasks','[]')),new_project,before.user_id,at_time));
    if taskfold_private.automation_tree_progress(fields->'subtasks') is distinct from taskfold_private.automation_tree_progress(coalesce(base->'subtasks','[]')) then perform taskfold_private.automation_require_scope(_key,account,'tasks:complete');end if;
   end if;
   if fields ?| array['recurrence_pattern','is_recurring','recurrence_end_date'] and proposed.is_recurring and (proposed.due_date is null or not taskfold_private.automation_recurrence_valid(proposed.recurrence_pattern)) then raise exception using errcode='22023',message='Choose a supported repeat rule and due date';end if;
   if new_assignee is distinct from before.assigned_to or new_project is distinct from before.project_id then
    if not(fields ? 'assigned_to') and new_project is distinct from before.project_id then new_assignee:=null;fields:=fields||'{"assigned_to":null}';end if;
    perform taskfold_private.automation_member(new_assignee,new_project,before.user_id);
   end if;
   if fields ?| array['due_date','due_time','time_zone','scheduled_at'] then
    if not(base ?& array['due_date','due_time','time_zone','scheduled_at','reminder_specs']) then raise exception using errcode='22023',message='Include the reviewed planning and reminder baseline';end if;
    if (proposed.due_date,proposed.due_time,proposed.time_zone) is distinct from (before.due_date,before.due_time,before.time_zone) and not(fields ? 'scheduled_at') then proposed.scheduled_at:=null;end if;
    if proposed.time_zone is not null then proposed.scheduled_at:=taskfold_private.automation_wall_start(to_jsonb(proposed),zone);else proposed.scheduled_at:=null;end if;
    fields:=fields||jsonb_build_object('scheduled_at',proposed.scheduled_at);
    if not(fields ? 'reminder_specs') and base->'reminder_specs' is not distinct from to_jsonb(before)->'reminder_specs' then
     minutes:=taskfold_private.automation_preference_minutes(account);
     proposed:=jsonb_populate_record(proposed,taskfold_private.automation_automatic_reminder(to_jsonb(proposed),to_jsonb(before),minutes,zone));
     if proposed.reminder_specs is distinct from before.reminder_specs then fields:=fields||jsonb_build_object('reminder_specs',proposed.reminder_specs);end if;
    end if;
   end if;
   if new_project is distinct from before.project_id then
    if not(base ?& array['assigned_to','subtasks','section_id']) then raise exception using errcode='22023',message='Include the reviewed project, section and assignment baseline';end if;
    -- Match the native move's guarded clear, then explicit reassignment. The live
    -- guard clears nested assignees on the first patch for this same project move.
    fields:=fields||'{"assigned_to":null}';
    t:=public.taskfold_patch_task(task_id,base,fields);
    if new_assignee is not null then t:=public.taskfold_patch_task(task_id,jsonb_build_object('task_generation',t.task_generation,'assigned_to',null),jsonb_build_object('assigned_to',new_assignee));end if;
   else t:=public.taskfold_patch_task(task_id,base,fields);end if;
  else
   desired:=_action='complete';
   if not(base ?& array['completed','completed_at','completion_version']) or jsonb_typeof(base->'completed')<>'boolean' or jsonb_typeof(base->'completion_version')<>'number'
    or (base->>'completion_version')::numeric<>trunc((base->>'completion_version')::numeric) or (base->>'completion_version')::numeric not between 0 and 9223372036854775807 then raise exception using errcode='22023',message='Include the reviewed completion state and revision';end if;
   if before.completed=desired then
    if before.completion_version is distinct from (base->>'completion_version')::bigint or before.completed is distinct from (base->>'completed')::boolean or before.completed_at is distinct from (base->>'completed_at')::timestamptz then raise exception using errcode='PT409',message='Completion changed; review the current task';end if;
    t:=before;
   else
    if desired and before.is_recurring and not taskfold_private.automation_recurrence_valid(before.recurrence_pattern) then raise exception using errcode='PT409',message='Review this repeat rule in Taskfold before completing';end if;
    t:=public.taskfold_patch_task(task_id,base,jsonb_build_object('completed',desired,'completed_at',case when desired then at_time else null end));
    if desired then
     next_data:=taskfold_private.automation_successor(to_jsonb(before),account,at_time,zone,request_id,gen_random_uuid());
     if next_data is not null then
      perform pg_advisory_xact_lock(hashtextextended(next_data->>'id',78137));
      select * into next_task from public.tasks where id=(next_data->>'id')::uuid or (recurrence_parent_id=(next_data->>'recurrence_parent_id')::uuid and due_date=(next_data->>'due_date')::date) order by id limit 1 for share;
      if found then
       perform taskfold_private.automation_lock_task_access(account,next_task.user_id,next_task.project_id);
       if next_task.recurrence_parent_id is distinct from (next_data->>'recurrence_parent_id')::uuid or next_task.due_date is distinct from (next_data->>'due_date')::date then raise exception using errcode='PT409',message='Recurring task identity changed; review the series';end if;
       if next_task.task_generation is null then next_task.id:=null;end if;
      else
       next_task:=jsonb_populate_record(null::public.tasks,next_data);
       insert into public.tasks select next_task.* returning * into next_task;
      end if;
     end if;
    end if;
   end if;
  end if;
 end if;
 receipt:=taskfold_private.automation_request_finish(account,request_id,case when _action='delete' then null else t.task_generation end,case when _action='delete' then null else t.completion_version end,next_task.id,next_task.task_generation);
 perform set_config('request.jwt.claim.sub',coalesce(old_actor,''),true);
 return jsonb_build_object('replayed',false,'receipt',receipt);
exception when others then
 perform set_config('request.jwt.claim.sub',coalesce(old_actor,''),true);
 if sqlerrm like 'TASKFOLD_CONFLICT:%' then raise exception using errcode='PT409',message='Task changed; review the current version';end if;
 if sqlstate like '22%' or sqlstate='23514' or sqlstate='23503' then raise exception using errcode='22023',message='Check the task details and references';end if;
 raise;
end $$;
create function public.taskfold_automation_write(_key uuid,_hash text,_action text,_body jsonb)
returns jsonb language sql volatile security invoker set search_path='' set statement_timeout='10s' as $$select taskfold_private.automation_task_write(_key,_hash,_action,_body)$$;
revoke all on function taskfold_private.automation_require_scope(uuid,uuid,text),taskfold_private.automation_writable_project(uuid,uuid),
 taskfold_private.automation_member(uuid,uuid,uuid),taskfold_private.automation_preference_minutes(uuid),taskfold_private.automation_review_delete(uuid,uuid,text,jsonb),
 taskfold_private.automation_tree_index(jsonb),taskfold_private.automation_tree(jsonb,jsonb,uuid,uuid,timestamptz,int),taskfold_private.automation_tree_progress(jsonb),
 taskfold_private.automation_validate_fields(jsonb,jsonb),taskfold_private.automation_clear_assignees(jsonb)
 from public,anon,authenticated,service_role;
revoke all on function taskfold_private.automation_task_write(uuid,text,text,jsonb),public.taskfold_automation_write(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.automation_task_write(uuid,text,text,jsonb),public.taskfold_automation_write(uuid,text,text,jsonb) to service_role;
