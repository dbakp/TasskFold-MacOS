-- Candidate only. Enable separately after native workspace acceptance. No legacy
-- write policy is widened. This adapter edits existing tasks, never admits content.
alter table taskfold_private.team_project_config add column native_task_edits_enabled boolean not null default false;
create table taskfold_private.team_task_edit_scope (
 transaction_id bigint not null,team_id uuid not null,project_id uuid not null,
 task_id uuid not null,generation uuid not null,actor_id uuid not null,
 primary key(transaction_id,task_id)
);
alter table taskfold_private.team_task_edit_scope enable row level security;
revoke all on taskfold_private.team_task_edit_scope from public,anon,authenticated,service_role;
-- Durable UUID/hash receipts have no task plaintext. They are not expired: an
-- offline retry must never become a fresh edit after another user's later change.
create table taskfold_private.team_task_edits (
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 request_id uuid not null,actor_id uuid not null references auth.users(id) on delete cascade,
 fingerprint text not null,task_id uuid not null,generation uuid not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,request_id)
);
create index team_task_edits_actor on taskfold_private.team_task_edits(actor_id);
alter table taskfold_private.team_task_edits enable row level security;
revoke all on taskfold_private.team_task_edits from public,anon,authenticated,service_role;
create or replace function taskfold_private.guard_closed_team_content() returns trigger
language plpgsql security definer set search_path='' as $$
declare p uuid; t uuid; row_id uuid;begin
 -- SQL operators and credential/account maintenance without a subject remain
 -- trusted. Native/API mutations carry a real subject and cannot set the scope.
 if auth.uid() is null then
  if tg_op='DELETE' then return old;else return new;end if;
 end if;
 if tg_op='DELETE' then row_id=old.id;else row_id=new.id;end if;
 if tg_table_name='projects' then p=row_id;
 elsif tg_op='DELETE' then p=old.project_id;else p=new.project_id;end if;
 select team_id into t from taskfold_private.team_content_projects where project_id=p;
 if t is null and tg_table_name='tasks' then
  select team_id into t from taskfold_private.team_content_tasks where task_id=row_id limit 1;
 end if;
 if t is null and tg_op='UPDATE' and tg_table_name<>'projects' then
  select team_id into t from taskfold_private.team_content_projects where project_id=old.project_id;
 end if;
 if t is not null and tg_table_name='tasks' and tg_op='UPDATE' and exists(
  select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current()
   and s.team_id=t and s.project_id=old.project_id and s.project_id=new.project_id
   and s.task_id=old.id and s.task_id=new.id and s.generation=old.task_generation and s.generation=new.task_generation
   and s.actor_id=auth.uid()) then return new;end if;
 if t is not null and not exists(select 1 from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t) then
  raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;

CREATE FUNCTION taskfold_private.team_task_merge(_id uuid, _base jsonb, _changes jsonb)
 RETURNS tasks
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t public.tasks; merged jsonb; k text; base_value jsonb; desired_value jsonb; remote_value jsonb; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if _changes is null or _base is null or jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 if t.task_generation is distinct from (_base->>'task_generation')::uuid then
  raise exception 'TASKFOLD_CONFLICT: This edit belongs to an earlier task. Review the synced version';
 end if;
 merged := to_jsonb(t);
 -- Completion revisions detect an intervening complete/reopen cycle even when
 -- the visible values returned to their baseline. Old clients remain compatible;
 -- new native queues require the revision and send it only in the baseline.
 if _changes ?| array['completed','completed_at'] and _base ? 'completion_version' then
  if jsonb_typeof(_base->'completion_version') <> 'number'
     or (_base->>'completion_version')::numeric <> trunc((_base->>'completion_version')::numeric)
     or (_base->>'completion_version')::numeric < 0 then
   raise exception 'TASKFOLD_CONFLICT: Review this completion before replacing synced state';
  end if;
  if t.completion_version <> (_base->>'completion_version')::bigint then
   -- Only the immediately following revision with identical desired completion
   -- values is a lost-response retry. A later cycle can never be mistaken for it.
   if t.completion_version <> (_base->>'completion_version')::bigint + 1
      or (_changes ? 'completed' and t.completed is distinct from (_changes->>'completed')::boolean)
      or (_changes ? 'completed_at' and t.completed_at is distinct from (_changes->>'completed_at')::timestamptz) then
    raise exception 'TASKFOLD_CONFLICT: Completion changed on another device. Review the synced task';
   end if;
  end if;
 end if;

 for k in select jsonb_object_keys(_changes) loop
   if not k = any(allowed) then raise exception 'This task field cannot be edited'; end if;
   if not _base ? k then raise exception 'An edit baseline is required'; end if;
   base_value := _base->k; desired_value := _changes->k; remote_value := merged->k;
   -- Native queues use Z, PostgREST returns +00:00. Compare instants, not JSON spelling.
   -- Real concurrent changes (including different DST folds) must still conflict.
   if k = any(array['scheduled_at','completed_at','notification_sent_at']) then
    if jsonb_typeof(base_value) = 'string' then base_value := to_jsonb((base_value#>>'{}')::timestamptz); end if;
    if jsonb_typeof(desired_value) = 'string' then desired_value := to_jsonb((desired_value#>>'{}')::timestamptz); end if;
    if jsonb_typeof(remote_value) = 'string' then remote_value := to_jsonb((remote_value#>>'{}')::timestamptz); end if;
   elsif k = 'due_time' then
    if jsonb_typeof(base_value) = 'string' then base_value := to_jsonb((base_value#>>'{}')::time); end if;
    if jsonb_typeof(desired_value) = 'string' then desired_value := to_jsonb((desired_value#>>'{}')::time); end if;
    if jsonb_typeof(remote_value) = 'string' then remote_value := to_jsonb((remote_value#>>'{}')::time); end if;
   end if;
   if k = 'subtasks' and desired_value is distinct from base_value
      and remote_value is distinct from base_value and remote_value is distinct from desired_value
      and (taskfold_private.subtask_layout(desired_value) is distinct from taskfold_private.subtask_layout(base_value)
        or taskfold_private.subtask_layout(remote_value) is distinct from taskfold_private.subtask_layout(base_value)) then
     raise exception 'TASKFOLD_CONFLICT: The checklist structure changed on another device. Review the layout and saved edits.';
   end if;
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(base_value, desired_value, remote_value), 'null'));
 end loop;
 t := jsonb_populate_record(t, merged);
 update public.tasks set title=t.title,description=t.description,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to,deadline_date=t.deadline_date,duration_minutes=t.duration_minutes,time_zone=t.time_zone,reminder_specs=t.reminder_specs,source_metadata=t.source_metadata,scheduled_at=t.scheduled_at where id=_id returning * into t;
 return t;
end $function$;


revoke all on function taskfold_private.team_task_merge(uuid,jsonb,jsonb) from public,anon,authenticated,service_role;

create function taskfold_private.team_task_edit(b jsonb) returns jsonb
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
create function public.taskfold_edit_team_task(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_task_edit(_body)$$;
revoke all on function taskfold_private.team_task_edit(jsonb),public.taskfold_edit_team_task(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_task_edit(jsonb),public.taskfold_edit_team_task(jsonb) to authenticated;
