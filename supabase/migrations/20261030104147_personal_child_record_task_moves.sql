-- Opt-in personal project moves reuse the ordinary durable mutation identity.
-- Confirmation is metadata-only on replay: later work is never projected back.
create table taskfold_private.personal_task_moves (
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 fingerprint text not null,task_id uuid not null,generation uuid,source_project uuid,destination_project uuid,
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id)
);
create index personal_task_moves_actor_day on taskfold_private.personal_task_moves(actor_id,created_at);
create table taskfold_private.personal_task_move_preparations (
 transaction_id bigint not null,actor_id uuid not null,request_id uuid not null,task_id uuid not null,
 fingerprint text not null,body jsonb not null,old_hash text,new_hash text,
 generation uuid,source_project uuid,destination_project uuid,
 primary key(transaction_id,actor_id,task_id)
);
alter table taskfold_private.personal_task_moves enable row level security;
alter table taskfold_private.personal_task_move_preparations enable row level security;
revoke all on taskfold_private.personal_task_moves,taskfold_private.personal_task_move_preparations from public,anon,authenticated,service_role;

create function taskfold_private.personal_task_move_reply(r taskfold_private.personal_task_moves,replaying boolean) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'request_id',r.request_id,'task_id',r.task_id,'task_generation',r.generation,
 'source_project_id',r.source_project,'destination_project_id',r.destination_project,'applied',true,'replayed',replaying,'task',null)
$$;
create function taskfold_private.personal_task_move_hash(t public.tasks) returns text
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.digest(convert_to((to_jsonb(t)-array['updated_at','completion_version'])::text,'UTF8'),'sha256'),'hex')
$$;
create function taskfold_private.personal_task_move_pending(id uuid) returns boolean
language sql stable security definer set search_path='' set timezone='UTC' as $$
 select auth.uid() is not null and exists(select 1 from taskfold_private.personal_task_move_preparations where transaction_id=txid_current() and actor_id=auth.uid() and task_id=id)
$$;
create function taskfold_private.personal_task_move_authorized(previous public.tasks,proposed public.tasks) returns boolean
language sql stable security definer set search_path='' set timezone='UTC' as $$
 select auth.uid() is not null and previous.id=proposed.id and previous.task_generation is not distinct from proposed.task_generation and exists(
 select 1 from taskfold_private.personal_task_move_preparations s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.task_id=previous.id
 and s.generation is not distinct from previous.task_generation and s.source_project is not distinct from previous.project_id and s.destination_project is not distinct from proposed.project_id
 and s.old_hash=encode(extensions.digest(convert_to(to_jsonb(previous)::text,'UTF8'),'sha256'),'hex') and s.new_hash=taskfold_private.personal_task_move_hash(proposed))
$$;
create function taskfold_private.prepare_personal_task_move(b jsonb,confirm_only boolean default false) returns jsonb
language plpgsql security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;root_id uuid;g uuid;src uuid;dest uuid;fingerprint text;t public.tasks;prior taskfold_private.personal_task_moves;begin
 if confirm_only is null then raise exception using errcode='22023',message='Choose a known move confirmation mode';end if;
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>4194304 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','request_id','task_id','baseline','changes'] or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','request_id','task_id','baseline','changes')) then raise exception using errcode='22023',message='Review this saved project move';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This move belongs to another account';end if;
 q:=taskfold_private.team_uuid(b,'request_id');root_id:=taskfold_private.team_uuid(b,'task_id');
 if jsonb_typeof(b->'baseline') is distinct from 'object' or jsonb_typeof(b->'changes') is distinct from 'object'
  or not (b->'baseline') ?& array['task_generation','project_id'] or not (b->'changes') ? 'project_id'
  or exists(select 1 from jsonb_object_keys(b->'changes') k where not (b->'baseline') ? k) then raise exception using errcode='22023',message='Review the original project and saved edit';end if;
 g:=case when b->'baseline'->'task_generation'='null'::jsonb then null else taskfold_private.team_uuid(b->'baseline','task_generation') end;
 src:=case when b->'baseline'->'project_id'='null'::jsonb then null else taskfold_private.team_uuid(b->'baseline','project_id') end;
 dest:=case when b->'changes'->'project_id'='null'::jsonb then null else taskfold_private.team_uuid(b->'changes','project_id') end;
 if src is not distinct from dest then raise exception using errcode='22023',message='Choose another project or Inbox';end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 if confirm_only then
  select * into prior from taskfold_private.personal_task_moves where actor_id=a and request_id=q;
  if found then
   if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This saved move identity is already used';end if;
   return taskfold_private.personal_task_move_reply(prior,true);
  end if;
  return jsonb_build_object('protocol',1,'account',a,'request_id',q,'task_id',root_id,'task_generation',g,'source_project_id',src,'destination_project_id',dest,'applied',false,'replayed',false,'task',null);
 end if;
 perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73921)) then raise exception using errcode='55P03',message='This saved project move is finishing; retry it';end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.personal_task_moves where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This saved move identity is already used';end if;
  return taskfold_private.personal_task_move_reply(prior,true);
 end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate subtask project moves are not enabled';end if;
 -- Auth before root; project locks after root must never wait on a writer that
 -- needs this task. All authority is rechecked after these fences.
 begin perform 1 from auth.users where auth.users.id=a for key share nowait;
 exception when lock_not_available then raise exception using errcode='PT409',message='Account changes are finishing; retry this move';end;
 select * into t from public.tasks where tasks.id=root_id for update;
 if not found or t.task_generation is distinct from g or t.project_id is distinct from src then raise exception using errcode='PT409',message='This task or its project changed';end if;
 begin
  perform 1 from auth.users where auth.users.id=t.user_id for key share nowait;
  perform 1 from public.projects where projects.id=src or projects.id=dest order by projects.id for share nowait;
 exception when lock_not_available then raise exception using errcode='PT409',message='Project access is changing; retry this move';end;
 if taskfold_private.is_team_content_task(t.id) or taskfold_private.is_team_content_project(src) or taskfold_private.is_team_content_project(dest) then raise exception using errcode='PT409',message='Use the reviewed shared-task transfer';end if;
 if (src is null and t.user_id<>a) or (src is not null and not public.has_project_access(a,src))
  or (dest is null and t.user_id<>a) or (dest is not null and not public.has_project_access(a,dest)) then raise exception using errcode='42501',message='Access to both personal locations is required';end if;
 if dest is not null and not exists(select 1 from public.projects where projects.id=dest and not is_archived and not ancestor_archived) then raise exception using errcode='PT409',message='Choose an active destination project';end if;
 if (select count(*) from taskfold_private.personal_task_moves where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=10000 then raise exception using errcode='PT429',message='Too many project moves today';end if;
 insert into taskfold_private.personal_task_move_preparations(transaction_id,actor_id,request_id,task_id,fingerprint,body,old_hash,generation,source_project,destination_project)
 values(txid_current(),a,q,t.id,fingerprint,b,encode(extensions.digest(convert_to(to_jsonb(t)::text,'UTF8'),'sha256'),'hex'),g,src,dest);
 return jsonb_build_object('replayed',false);
end$$;

create function taskfold_private.stage_personal_task_move(id uuid,base jsonb,changes jsonb,previous public.tasks,proposed public.tasks) returns public.tasks
language plpgsql security definer set search_path='' set timezone='UTC' as $$
declare s taskfold_private.personal_task_move_preparations;desired jsonb;begin
 select * into s from taskfold_private.personal_task_move_preparations where transaction_id=txid_current() and actor_id=auth.uid() and task_id=id for update;
 if not found or s.body->'baseline' is distinct from base or s.body->'changes' is distinct from changes
  or s.old_hash<>encode(extensions.digest(convert_to(to_jsonb(previous)::text,'UTF8'),'sha256'),'hex')
  or proposed.id<>previous.id or proposed.user_id<>previous.user_id or proposed.task_generation is distinct from previous.task_generation
  or proposed.project_id is distinct from s.destination_project then raise exception using errcode='PT409',message='This project move was not prepared';end if;
 perform taskfold_private.child_record_move_index(proposed.subtasks);
 desired:=taskfold_private.child_record_move_clear(proposed.subtasks);
 if exists(select 1 from taskfold_private.child_task_record_authority where task_id=id) and coalesce(desired,'null'::jsonb) is distinct from coalesce(taskfold_private.child_record_move_clear(previous.subtasks),'null'::jsonb) then
  raise exception using errcode='PT409',message='Save separate subtask edits before moving this task';end if;
 if not changes ? 'section_id' then proposed.section_id:=null;end if;
 if proposed.section_id is not null then
  begin
   perform 1 from public.sections where sections.id=proposed.section_id and project_id=proposed.project_id for key share nowait;
   if not found then raise exception using errcode='PT409',message='Choose a section in the destination project';end if;
  exception when lock_not_available then raise exception using errcode='PT409',message='This section is changing; review the move again';end;
 end if;
 proposed.assigned_to:=null;proposed.subtasks:=desired;
 update taskfold_private.personal_task_move_preparations set new_hash=taskfold_private.personal_task_move_hash(proposed) where transaction_id=s.transaction_id and actor_id=s.actor_id and task_id=id;
 return proposed;
end$$;

create function taskfold_private.finish_personal_task_move(q uuid) returns jsonb
language plpgsql security definer set search_path='' set timezone='UTC' as $$
declare s taskfold_private.personal_task_move_preparations;t public.tasks;r taskfold_private.personal_task_moves;begin
 perform taskfold_private.team_actor();
 select * into s from taskfold_private.personal_task_move_preparations where transaction_id=txid_current() and actor_id=auth.uid() and request_id=q for update;
 if not found or s.new_hash is null then raise exception using errcode='PT409',message='This project move is incomplete';end if;
 select * into t from public.tasks where id=s.task_id;
 if t.id is null or t.project_id is distinct from s.destination_project or t.task_generation is distinct from s.generation or taskfold_private.personal_task_move_hash(t) is distinct from s.new_hash then raise exception using errcode='PT409',message='This project move could not be confirmed';end if;
 insert into taskfold_private.personal_task_moves(actor_id,request_id,fingerprint,task_id,generation,source_project,destination_project)
 values(s.actor_id,s.request_id,s.fingerprint,s.task_id,s.generation,s.source_project,s.destination_project) returning * into r;
 delete from taskfold_private.personal_task_move_preparations where transaction_id=s.transaction_id and actor_id=s.actor_id and task_id=s.task_id;
 return taskfold_private.personal_task_move_reply(r,false);
end$$;
create function taskfold_private.check_personal_task_move_finished() returns trigger
language plpgsql security definer set search_path='' set timezone='UTC' as $$begin
 if exists(select 1 from taskfold_private.personal_task_move_preparations where transaction_id=new.transaction_id and actor_id=new.actor_id and task_id=new.task_id) then raise exception using errcode='PT409',message='Finish this prepared project move in the same transaction';end if;return null;
end$$;
create constraint trigger personal_task_move_finished after insert on taskfold_private.personal_task_move_preparations deferrable initially deferred for each row execute function taskfold_private.check_personal_task_move_finished();
revoke all on function taskfold_private.personal_task_move_reply(taskfold_private.personal_task_moves,boolean),taskfold_private.personal_task_move_hash(public.tasks),taskfold_private.personal_task_move_pending(uuid),taskfold_private.personal_task_move_authorized(public.tasks,public.tasks),taskfold_private.prepare_personal_task_move(jsonb,boolean),taskfold_private.stage_personal_task_move(uuid,jsonb,jsonb,public.tasks,public.tasks),taskfold_private.finish_personal_task_move(uuid),taskfold_private.check_personal_task_move_finished() from public,anon,authenticated,service_role;
grant execute on function taskfold_private.personal_task_move_pending(uuid),taskfold_private.prepare_personal_task_move(jsonb,boolean),taskfold_private.stage_personal_task_move(uuid,jsonb,jsonb,public.tasks,public.tasks),taskfold_private.finish_personal_task_move(uuid) to authenticated;

create function public.taskfold_move_personal_task(_body jsonb,_confirm_only boolean default false) returns jsonb
language plpgsql security invoker set search_path='' set timezone='UTC' as $$
declare plan jsonb;saved public.tasks;receipt jsonb;begin
 plan:=taskfold_private.prepare_personal_task_move(_body,_confirm_only);
 if _confirm_only or plan->'replayed'='true'::jsonb then return plan;end if;
 saved:=public.taskfold_patch_task((_body->>'task_id')::uuid,_body->'baseline',_body->'changes');
 receipt:=taskfold_private.finish_personal_task_move((_body->>'request_id')::uuid);
 -- The ordinary workspace read supplies current task data. Even a first
 -- confirmation never echoes task content across a concurrent access change.
 return receipt;
end$$;
revoke all on function public.taskfold_move_personal_task(jsonb,boolean) from public,anon,service_role;
grant execute on function public.taskfold_move_personal_task(jsonb,boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.taskfold_patch_task(_id uuid, _base jsonb, _changes jsonb)
 RETURNS tasks
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare original public.tasks;t public.tasks; merged jsonb; k text; base_value jsonb; desired_value jsonb; remote_value jsonb; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at','is_heading'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 if taskfold_private.is_team_content_task(_id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this team action in a supported Taskfold app';end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if _changes is null or _base is null or jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 if t.task_generation is distinct from (_base->>'task_generation')::uuid then
  raise exception 'TASKFOLD_CONFLICT: This edit belongs to an earlier task. Review the synced version';
 end if;
 original:=t;
 merged := to_jsonb(t);
 -- Completion revisions detect an intervening complete/reopen cycle even when
 -- the visible values returned to their baseline. Old clients remain compatible;
 -- new native queues require the revision and send it only in the baseline.
 if _changes ? 'is_heading' then
  if jsonb_typeof(_changes->'is_heading') <> 'boolean' or not (_base ?& array['is_heading','completed','completed_at','completion_version']) then
   raise exception 'TASKFOLD_CONFLICT: Review the task type before changing it';
  end if;
  if (_base->'is_heading' <> 'null'::jsonb and jsonb_typeof(_base->'is_heading') <> 'boolean')
     or _base->'completed' is distinct from to_jsonb(t.completed)
     or (case when _base->'completed_at'='null'::jsonb then null else (_base->>'completed_at')::timestamptz end) is distinct from t.completed_at then
   raise exception 'TASKFOLD_CONFLICT: Completion changed before the task type was saved';
  end if;
 end if;
 if _changes ?| array['completed','completed_at','is_heading'] and _base ? 'completion_version' then
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
      or (_changes ? 'completed_at' and t.completed_at is distinct from (_changes->>'completed_at')::timestamptz)
      or (_changes ? 'is_heading' and t.is_heading is distinct from (_changes->>'is_heading')::boolean) then
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
 if t.project_id is distinct from original.project_id and taskfold_private.personal_task_move_pending(_id) then
  t:=taskfold_private.stage_personal_task_move(_id,_base,_changes,original,t);
 end if;
 update public.tasks set title=t.title,description=t.description,is_heading=t.is_heading,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to,deadline_date=t.deadline_date,duration_minutes=t.duration_minutes,time_zone=t.time_zone,reminder_specs=t.reminder_specs,source_metadata=t.source_metadata,scheduled_at=t.scheduled_at where id=_id returning * into t;
 return t;
end $function$;

create or replace function taskfold_private.guard_child_record_scope() returns trigger
language plpgsql security definer set search_path='' as $$
declare a taskfold_private.child_task_record_authority;
begin
 select * into a from taskfold_private.child_task_record_authority where task_id=old.id;
 if not found or (new.task_generation is not distinct from old.task_generation and new.project_id is not distinct from old.project_id) then return new;end if;
 -- Only the existing actor/transaction/root/old-row/new-row-bound move scope
 -- authorizes transfer. No caller-set flag, SQL subject bypass or demotion.
 if new.task_generation is distinct from old.task_generation or a.task_generation is distinct from old.task_generation or a.project_id is distinct from old.project_id
  or not (taskfold_private.team_task_move_authorized(old,new) or taskfold_private.personal_task_move_authorized(old,new)) then raise exception using errcode='PT409',message='Review this task before moving its subtasks to another project';end if;
 perform taskfold_private.prepare_child_record_tree(old.id,old.task_generation,new.subtasks);
 update taskfold_private.child_task_record_authority set project_id=new.project_id where task_id=old.id;
 return new;
end$$;

create or replace function taskfold_private.purge_child_structure_archives() returns trigger
language plpgsql security definer set search_path='' as $$begin
 -- A reviewed same-team move never republishes private deleted content. Its
 -- original receipt still binds source project/generation and current access;
 -- discovery/disposal remain actor-only, while root/account deletion cascades.
 if new.task_generation is not distinct from old.task_generation and (taskfold_private.team_task_move_authorized(old,new) or taskfold_private.personal_task_move_authorized(old,new)) then return new;end if;
 delete from taskfold_private.child_task_structure_archives where task_id=new.id;
 return new;
end$$;

create or replace function taskfold_private.guard_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare child jsonb;
begin
 if tg_op='UPDATE' and new.user_id<>old.user_id then raise exception 'Task creator cannot be changed';end if;
 if tg_op='UPDATE' and new.project_id is distinct from old.project_id and not taskfold_private.team_task_move_authorized(old,new) and not taskfold_private.personal_task_move_authorized(old,new) then
  new.assigned_to:=null;new.subtasks:=taskfold_private.clear_assignee(new.subtasks,null);
 end if;
 if tg_op='INSERT' or new.assigned_to is distinct from old.assigned_to or new.project_id is distinct from old.project_id then
  perform taskfold_private.check_task_assignment(new.assigned_to::text,new.project_id,new.user_id);
 end if;
 if tg_op='INSERT' or new.subtasks is distinct from old.subtasks or new.project_id is distinct from old.project_id then
  for child in
   with recursive nodes(value) as (
    select value from jsonb_array_elements(case when jsonb_typeof(new.subtasks)='array' then new.subtasks else '[]'::jsonb end)
    union all
    select c.value from nodes cross join lateral jsonb_array_elements(case when jsonb_typeof(nodes.value->'subtasks')='array' then nodes.value->'subtasks' else '[]'::jsonb end) c(value)
   ) select value from nodes
  loop perform taskfold_private.check_task_assignment(child->>'assigned_to',new.project_id,new.user_id);end loop;
 end if;
 return new;
end $$;
