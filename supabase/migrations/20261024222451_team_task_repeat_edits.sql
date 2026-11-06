-- Reviewed task recurrence uses the existing gated team edit RPC. No new public
-- endpoint, permission, rollout switch or series-link mutation is introduced.
create function taskfold_private.team_repeat_supported(t jsonb) returns boolean
language plpgsql immutable security invoker set search_path='' as $$
declare r jsonb:=t->'recurrence_pattern';begin
 if coalesce(t->'is_recurring','null') not in('true'::jsonb,'false'::jsonb,'null'::jsonb) then return false;end if;
 if coalesce(t->'recurrence_end_date','null')<>'null'::jsonb and
  (jsonb_typeof(t->'recurrence_end_date')<>'string' or taskfold_private.automation_civil_day(t->>'recurrence_end_date') is null) then return false;end if;
 if r is not null and r<>'null'::jsonb then
  if jsonb_typeof(r)<>'object' then return false;end if;
  if exists(select 1 from jsonb_object_keys(r) k where k not in('type','interval','daysOfWeek','dayOfMonth','daysOfMonth','monthOfYear','weekday','weekdayOrdinal','count','endDate','fromCompletion')) then return false;end if;
  if r<>'{}' and not taskfold_private.automation_recurrence_valid(r) then return false;end if;
 end if;
 if t->'is_recurring'='true'::jsonb then
  if taskfold_private.automation_civil_day(t->>'due_date') is null or not coalesce(taskfold_private.automation_recurrence_valid(r),false) then return false;end if;
 end if;
 return true;
end$$;
revoke all on function taskfold_private.team_repeat_supported(jsonb) from public,anon,authenticated,service_role;

create function taskfold_private.team_repeat_review(b jsonb,c jsonb,t jsonb) returns void
language plpgsql stable security invoker set search_path='' set timezone='UTC' as $$
declare k text;old jsonb;live jsonb;required constant text[]:=array['is_recurring','recurrence_pattern','recurrence_end_date','due_date','due_time','time_zone','completed','completed_at','completion_version'];begin
 if not(c ?| array['is_recurring','recurrence_pattern','recurrence_end_date']) then return;end if;
 if not(b ?& required) or c ?| array['completed','completed_at'] or jsonb_typeof(b->'completion_version') is distinct from 'number'
  or (b->>'completion_version')::numeric<0 or (b->>'completion_version')::numeric>9007199254740991
  or (b->>'completion_version')::numeric<>trunc((b->>'completion_version')::numeric) or jsonb_typeof(b->'completed') is distinct from 'boolean'
  or not taskfold_private.team_repeat_supported(b) then
  raise exception using errcode='22023',message='Review this repeat rule and its planned date';end if;
 if c ? 'is_recurring' and jsonb_typeof(c->'is_recurring') is distinct from 'boolean' then
  raise exception using errcode='22023',message='Choose a valid repeat state';end if;
 if not taskfold_private.team_repeat_supported(b||c) then raise exception using errcode='22023',message='Choose a supported repeat rule and planned date';end if;
 foreach k in array required loop
  old=b->k;live=coalesce(t->k,'null');
  if k='due_time' then
   if old<>'null'::jsonb then old=to_jsonb((old#>>'{}')::time);end if;
   if live<>'null'::jsonb then live=to_jsonb((live#>>'{}')::time);end if;
  elsif k='completed_at' then
   if old<>'null'::jsonb then old=to_jsonb((old#>>'{}')::timestamptz);end if;
   if live<>'null'::jsonb then live=to_jsonb((live#>>'{}')::timestamptz);end if;
  end if;
  if old is distinct from live then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The repeat rule, plan or completion changed. Review the current task';end if;
 end loop;
end$$;
revoke all on function taskfold_private.team_repeat_review(jsonb,jsonb,jsonb) from public,anon,authenticated,service_role;

create or replace function taskfold_private.team_task_edit(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;p uuid;id uuid;q uuid;generation uuid;
 tr taskfold_private.teams;row public.tasks;desired public.tasks;
 prior taskfold_private.team_task_edits;fingerprint text;changes jsonb;base jsonb;k text;replay boolean:=false;nodes jsonb:='{}';recipient_ids uuid[];restore_from uuid;
 allowed constant text[]:=array['title','description','priority','due_date','due_time','completed','completed_at','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','section_id','labels','reminder_specs','subtasks','is_recurring','recurrence_pattern','recurrence_end_date'];
begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000
  or not b ?& array['team_id','project_id','task_id','request_id','task_generation','base','changes']
  or exists(select 1 from jsonb_object_keys(b) keys(key) where keys.key not in('team_id','project_id','task_id','request_id','task_generation','base','changes','checklist_restore_from')) then
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
 -- Validate references before casts/locks. Only the explicit recipient is held;
 -- unrelated text edits do not acquire Auth locks for historical assignments.
 perform taskfold_private.automation_validate_fields(
  (select coalesce(jsonb_object_agg(e.k,e.v),'{}') from jsonb_each(changes) e(k,v)
   where e.k=any(array['assigned_to','section_id','labels','reminder_specs'])),base);
 if changes->'assigned_to' is not null and changes->'assigned_to'<>'null'::jsonb then
  if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') or not exists(
   select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) then
   raise exception using errcode='42501',message='Editing access is required';end if;
  perform 1 from auth.users where users.id=(changes->>'assigned_to')::uuid for share;
 end if;
 if changes ? 'subtasks' then
  nodes=taskfold_private.automation_tree_index(changes->'subtasks');
  perform taskfold_private.automation_tree_index(base->'subtasks');
  for k in select e.key from jsonb_each(nodes) e loop
   perform taskfold_private.automation_validate_fields((select coalesce(jsonb_object_agg(x.k,x.v),'{}') from jsonb_each(nodes->k) x(k,v) where x.k='assigned_to'),null);
  end loop;
  select array_agg(distinct u order by u) into recipient_ids from (select (e.value->>'assigned_to')::uuid u from jsonb_each(nodes) e where e.value->'assigned_to' is not null and e.value->'assigned_to'<>'null'::jsonb) z;
  perform 1 from auth.users where users.id=any(coalesce(recipient_ids,'{}')) order by users.id for share;
 end if;
 if b ? 'checklist_restore_from' then
  if not(changes ? 'subtasks') then raise exception using errcode='22023',message='A checklist Undo needs its saved tree';end if;
  restore_from=taskfold_private.team_uuid(b,'checklist_restore_from');
 end if;
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
  -- A recorded retry never reassigns the task. A departed/banned recipient in
  -- the original intent must not prevent acknowledgement of a completed write.
  if changes->'assigned_to' is not null and changes->'assigned_to'<>'null'::jsonb then
   if not exists(select 1 from auth.users where users.id=(changes->>'assigned_to')::uuid
    and (banned_until is null or banned_until<=clock_timestamp())) then
    raise exception using errcode='42501',message='Choose a current project editor';end if;
  end if;
  perform taskfold_private.team_repeat_review(base,changes,to_jsonb(row));
  desired=jsonb_populate_record(row,changes);
  if desired.title is null or length(btrim(desired.title))=0 or length(desired.title)>10000 or length(desired.description)>100000
   or desired.priority is null or desired.priority not between 1 and 4
   or desired.duration_minutes is not null and desired.duration_minutes not between 1 and 10080
   or desired.time_zone is not null and not exists(select 1 from pg_timezone_names where name=desired.time_zone) then
   raise exception using errcode='22023',message='Review the task values';end if;
  if restore_from is not null and not exists(select 1 from taskfold_private.team_task_edits e where e.team_id=team and e.request_id=restore_from and e.actor_id=a and e.task_id=id and e.generation=cmd.generation and e.operation='patch') then
   raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The saved checklist Undo is unavailable';end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,request_id,checklist_restore_request) values(txid_current(),team,p,id,generation,a,q,restore_from);
  -- Reuse the reviewed three-way merge, privately; no public RPC gains definer authority.
  row=taskfold_private.team_task_merge(id,base,changes);
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=cmd.id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation) values(team,q,a,fingerprint,id,generation);
 end if;
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'project_id',p,'request_id',q,'task_generation',generation,'task',to_jsonb(row),'replayed',replay);
end$$;
