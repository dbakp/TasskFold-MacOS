-- Source-only team heading edit protocol. No public grants, rollout or personal writer changes.
alter table taskfold_private.team_project_config add column native_task_types_enabled boolean not null default false;

create function taskfold_private.team_type_needed(b jsonb,c jsonb) returns boolean
language plpgsql stable security invoker set search_path='' as $$
declare olds jsonb;news jsonb;n jsonb;k text;begin
 if c ? 'is_heading' then return true;end if;
 if not(c ? 'subtasks') then return false;end if;
 olds=taskfold_private.automation_tree_index(b->'subtasks');news=taskfold_private.automation_tree_index(c->'subtasks');
 for k,n in select * from jsonb_each(news) loop
  if coalesce(nullif(n->'is_heading','null'::jsonb),'false') is distinct from coalesce(nullif(olds->k->'is_heading','null'::jsonb),'false') then return true;end if;
 end loop;
 return false;
end$$;
create function taskfold_private.team_type_review(b jsonb,c jsonb,t jsonb) returns void
language plpgsql stable security invoker set search_path='' as $$
declare k text;old jsonb;n jsonb;olds jsonb;news jsonb;begin
 if c ? 'is_heading' then
  if jsonb_typeof(c->'is_heading') is distinct from 'boolean' or not(b ?& array['is_heading','completed','completed_at','completion_version'])
   or coalesce(b->'is_heading','null') not in('null'::jsonb,'true'::jsonb,'false'::jsonb)
   or b->'completed' is distinct from 'false'::jsonb or b->'completed_at' is distinct from 'null'::jsonb
   or c ?| array['completed','completed_at'] or not taskfold_private.automation_reminder_integer(b->'completion_version',0,9007199254740990) then
   raise exception using errcode='22023',message='Reopen and review the task before changing its type';end if;
  foreach k in array array['is_heading','completed','completed_at','completion_version'] loop
   if b->k is distinct from coalesce(t->k,'null') then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Task type or completion changed';end if;
  end loop;
 end if;
 if c ? 'subtasks' then
  olds=taskfold_private.automation_tree_index(b->'subtasks');news=taskfold_private.automation_tree_index(c->'subtasks');
  for k,n in select * from jsonb_each(news) loop
   old=olds->k;
   if coalesce(nullif(n->'is_heading','null'::jsonb),'false') is distinct from coalesce(nullif(old->'is_heading','null'::jsonb),'false') then
    if jsonb_typeof(n->'is_heading') is distinct from 'boolean'
     or (old is not null and (coalesce(old->'completed','false')<>'false'::jsonb or coalesce(old->'completed_at','null')<>'null'::jsonb))
     or coalesce(n->'completed','false')<>'false'::jsonb or coalesce(n->'completed_at','null')<>'null'::jsonb then
     raise exception using errcode='22023',message='Reopen and review this checklist item before changing its type';end if;
   end if;
  end loop;
 end if;
end$$;
revoke all on function taskfold_private.team_type_needed(jsonb,jsonb),taskfold_private.team_type_review(jsonb,jsonb,jsonb) from public,anon,authenticated,service_role;

create or replace function taskfold_private.team_task_tree(rows jsonb,old_nodes jsonb,_project uuid,_owner uuid,_at timestamptz,depth int default 0)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare result jsonb:='[]';row jsonb;old jsonb;merged jsonb;k text;token jsonb;old_token jsonb;
 recovery taskfold_private.team_checklist_deleted_nodes;scope taskfold_private.team_task_edit_scope;recovering boolean;
 allowed text[]:=array['id','title','description','completed','completed_at','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminder_specs','subtasks','taskfold_completion_v1','is_heading'];begin
 if depth>=24 and jsonb_array_length(rows)>0 then raise exception using errcode='22023',message='Use a supported checklist depth';end if;
 select * into scope from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and actor_id=auth.uid() and project_id=_project and operation='patch';
 for row in select * from jsonb_array_elements(rows) loop
  old:=coalesce(old_nodes->(row->>'id'),'{}');recovering=false;
  if old='{}' and scope.task_id is not null then
   select * into recovery from taskfold_private.team_checklist_deleted_nodes where team_id=scope.team_id
    and task_id=scope.task_id and generation=scope.generation and node_id=row->>'id' for update;
   if found then
    if scope.checklist_restore_request is null or recovery.delete_request<>scope.checklist_restore_request or recovery.restored_request is not null
     or recovery.node_hash is distinct from taskfold_private.team_checklist_node_hash(row) then
     raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this checklist item before restoring it';end if;
    recovering=true;
   end if;
  end if;
  for k in select jsonb_object_keys(row) loop
   if not k=any(allowed) and row->k is distinct from old->k and not recovering
    and not (old='{}' and k in('comments','attachments') and row->k in('[]'::jsonb,'null'::jsonb))
    and not (old='{}' and k='source_metadata' and row->k in('{}'::jsonb,'null'::jsonb)) then
    raise exception using errcode='22023',message='Checklist history and unknown fields are read-only';end if;
  end loop;
  perform taskfold_private.automation_validate_fields((select coalesce(jsonb_object_agg(e.k,e.v),'{}') from jsonb_each(row) e(k,v)
   where e.k=any(array['title','description','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminder_specs'])),case when recovering then row else old end);
  merged:=old||row;
  if coalesce(merged->>'title','')='' or jsonb_typeof(merged->'title')<>'string'
   or (merged ? 'completed' and jsonb_typeof(merged->'completed')<>'boolean') then raise exception using errcode='22023',message='Give checklist items a title and valid state';end if;
  old_token=old->'taskfold_completion_v1';token=row->'taskfold_completion_v1';
  if old='{}' then
   if token is null then token=jsonb_build_object('epoch',pg_catalog.gen_random_uuid(),'version',0);end if;
   if not taskfold_private.team_checklist_token_valid(token) or token->'version'<>'0'::jsonb
    or (recovering and token->>'epoch' is distinct from taskfold_private.team_checklist_epoch(scope.request_id,row->>'id')) then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Use a fresh checklist item identity';end if;
   merged=merged||jsonb_build_object('completed_at',case when recovering then recovery.completed_at when merged->'completed'='true'::jsonb then to_jsonb(_at) else 'null'::jsonb end);
  elsif coalesce(old->'completed','false') is distinct from coalesce(merged->'completed','false') or coalesce(nullif(old->'is_heading','null'::jsonb),'false') is distinct from coalesce(nullif(merged->'is_heading','null'::jsonb),'false') then
   if not taskfold_private.team_checklist_token_valid(token) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the checklist completion revision';end if;
   if taskfold_private.team_checklist_token_valid(old_token) then
    if token is distinct from jsonb_build_object('epoch',old_token->'epoch','version',(old_token->>'version')::bigint+1) then
     raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the synced checklist completion';end if;
   elsif not taskfold_private.team_checklist_token_valid(token) or token->'version'<>'1'::jsonb then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this checklist completion';end if;
   merged=merged||jsonb_build_object('completed_at',case when merged->'completed'='true'::jsonb then _at else null end);
  else
   if row ? 'completed_at' and row->'completed_at' is distinct from old->'completed_at' and not(row->'completed_at'='null'::jsonb and old->'completed_at' is null) then
    raise exception using errcode='22023',message='Change checklist completion state rather than its history';end if;
   if old_token is not null then
    if token is distinct from old_token then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Checklist completion history is read-only';end if;
   else
    if token is null then token=jsonb_build_object('epoch',pg_catalog.gen_random_uuid(),'version',0);end if;
    if not taskfold_private.team_checklist_token_valid(token) or token->'version'<>'0'::jsonb then raise exception using errcode='22023',message='Use a supported checklist completion identity';end if;
   end if;
  end if;
  merged=merged||jsonb_build_object('taskfold_completion_v1',token);
  if merged->'assigned_to' is not null and merged->'assigned_to'<>'null'::jsonb then
   if jsonb_typeof(merged->'assigned_to')<>'string' or (merged->>'assigned_to')!~'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then raise exception using errcode='22023',message='Invalid checklist assignee';end if;
   perform taskfold_private.team_task_member((merged->>'assigned_to')::uuid,_project,_owner);
   if merged->'assigned_to' is distinct from old->'assigned_to' and not exists(select 1 from auth.users where users.id=(merged->>'assigned_to')::uuid and (banned_until is null or banned_until<=clock_timestamp())) then raise exception using errcode='42501',message='Choose a current project editor';end if;
  end if;
  merged=merged||jsonb_build_object('subtasks',taskfold_private.team_task_tree(coalesce(row->'subtasks',old->'subtasks','[]'),old_nodes,_project,_owner,_at,depth+1));
  result=result||jsonb_build_array(merged);
 end loop;
 return result;
end $$;

CREATE OR REPLACE FUNCTION taskfold_private.team_task_merge(_id uuid, _base jsonb, _changes jsonb)
 RETURNS public.tasks
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t public.tasks; merged jsonb; previous jsonb;old_nodes jsonb;desired_nodes jsonb;base_nodes jsonb;after_nodes jsonb;node jsonb;check_id text;scope taskfold_private.team_task_edit_scope; k text; base_value jsonb; desired_value jsonb; remote_value jsonb; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at','is_heading'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if _changes is null or _base is null or jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 if t.task_generation is distinct from (_base->>'task_generation')::uuid then
  raise exception 'TASKFOLD_CONFLICT: This edit belongs to an earlier task. Review the synced version';
 end if;
 perform taskfold_private.team_type_review(_base,_changes,to_jsonb(t));
 merged := to_jsonb(t); previous := merged;
 if _changes ? 'subtasks' then
  old_nodes=taskfold_private.automation_tree_index(coalesce(t.subtasks,'[]'));
  base_nodes=taskfold_private.automation_tree_index(_base->'subtasks');
  desired_nodes=taskfold_private.automation_tree_index(_changes->'subtasks');
  for check_id,node in select * from jsonb_each(desired_nodes) loop
   if base_nodes ? check_id and (
    (node-array['subtasks','taskfold_completion_v1']) is distinct from ((base_nodes->check_id)-array['subtasks','taskfold_completion_v1'])
    or taskfold_private.subtask_layout(coalesce(node->'subtasks','[]')) is distinct from taskfold_private.subtask_layout(coalesce(base_nodes->check_id->'subtasks','[]'))) then
    if not(old_nodes ? check_id) or base_nodes->check_id->'taskfold_completion_v1'->'epoch' is distinct from old_nodes->check_id->'taskfold_completion_v1'->'epoch' then
     raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This checklist item was replaced';end if;
   end if;
   if base_nodes ? check_id and (coalesce(node->'completed','false') is distinct from coalesce(base_nodes->check_id->'completed','false') or coalesce(nullif(node->'is_heading','null'::jsonb),'false') is distinct from coalesce(nullif(base_nodes->check_id->'is_heading','null'::jsonb),'false')) then
    if not(old_nodes ? check_id) or base_nodes->check_id->'taskfold_completion_v1' is distinct from old_nodes->check_id->'taskfold_completion_v1' then
     raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Checklist completion changed on another device';end if;
   end if;
  end loop;
  for check_id in select e.key from jsonb_each(base_nodes) e where not(desired_nodes ? e.key) loop
   if old_nodes ? check_id and base_nodes->check_id->'taskfold_completion_v1'->'epoch' is distinct from old_nodes->check_id->'taskfold_completion_v1'->'epoch' then
    raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The checklist deletion targets an earlier item';end if;
  end loop;
 end if;
 -- Completion revisions detect an intervening complete/reopen cycle even when
 -- the visible values returned to their baseline. Old clients remain compatible;
 -- new native queues require the revision and send it only in the baseline.
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
   if k='subtasks' then
    desired_value=taskfold_private.team_checklist_completion_times(desired_value,base_nodes,old_nodes);
    base_value=taskfold_private.team_checklist_completion_times(base_value,desired_nodes,old_nodes);
   end if;
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(base_value, desired_value, remote_value), 'null'));
 end loop;
 -- Validate the final merged values against the current row, not just the
 -- submitted baseline. This catches oversized merged lists, duplicate reminder
 -- identities and lost opaque/private reminder fields after concurrent edits.
 perform taskfold_private.automation_validate_fields(
  (select coalesce(jsonb_object_agg(e.k,merged->e.k),'{}') from jsonb_object_keys(_changes) e(k)
   where e.k=any(array['assigned_to','section_id','labels','reminder_specs'])),previous);
 if _changes ? 'assigned_to' and merged->'assigned_to'<>'null'::jsonb then
  perform taskfold_private.team_task_member((merged->>'assigned_to')::uuid,t.project_id,auth.uid());
 end if;
 if _changes ? 'section_id' and merged->'section_id'<>'null'::jsonb then
  perform 1 from public.sections where sections.id=(merged->>'section_id')::uuid and sections.project_id=t.project_id for share;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Choose a current section in this project';end if;
 end if;
 if _changes ? 'subtasks' then
  select * into scope from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=_id and actor_id=auth.uid() and operation='patch';
  if scope.request_id is null then raise exception using errcode='42501',message='Use the reviewed checklist action';end if;
  perform taskfold_private.automation_tree_index(merged->'subtasks');
  merged=jsonb_set(merged,array['subtasks'],taskfold_private.team_task_tree(merged->'subtasks',old_nodes,t.project_id,auth.uid(),clock_timestamp()));
  after_nodes=taskfold_private.automation_tree_index(merged->'subtasks');
  insert into taskfold_private.team_checklist_deleted_nodes(team_id,task_id,generation,node_id,delete_request,node_hash,completed_at,old_epoch)
   select scope.team_id,_id,t.task_generation,e.k,scope.request_id,taskfold_private.team_checklist_node_hash(e.v),coalesce(e.v->'completed_at','null'),
    case when taskfold_private.team_checklist_token_valid(e.v->'taskfold_completion_v1') then (e.v->'taskfold_completion_v1'->>'epoch')::uuid end
   from jsonb_each(old_nodes) e(k,v) where not(after_nodes ? e.k)
   on conflict(team_id,task_id,generation,node_id) do update set delete_request=excluded.delete_request,node_hash=excluded.node_hash,
    completed_at=excluded.completed_at,old_epoch=excluded.old_epoch,restored_request=null;
  update taskfold_private.team_checklist_deleted_nodes d set restored_request=scope.request_id
   where d.team_id=scope.team_id and d.task_id=_id and d.generation=t.task_generation
    and d.delete_request=scope.checklist_restore_request and d.restored_request is null and after_nodes ? d.node_id and not(old_nodes ? d.node_id);
 end if;
 t := jsonb_populate_record(t, merged);
 update public.tasks set is_heading=t.is_heading,title=t.title,description=t.description,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to,deadline_date=t.deadline_date,duration_minutes=t.duration_minutes,time_zone=t.time_zone,reminder_specs=t.reminder_specs,source_metadata=t.source_metadata,scheduled_at=t.scheduled_at where id=_id returning * into t;
 return t;
end $function$;

create or replace function taskfold_private.team_task_edit(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;p uuid;id uuid;q uuid;generation uuid;
 tr taskfold_private.teams;row public.tasks;desired public.tasks;
 prior taskfold_private.team_task_edits;fingerprint text;changes jsonb;base jsonb;k text;replay boolean:=false;nodes jsonb:='{}';recipient_ids uuid[];restore_from uuid;
 allowed constant text[]:=array['title','description','priority','due_date','due_time','completed','completed_at','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','section_id','labels','reminder_specs','subtasks','is_recurring','recurrence_pattern','recurrence_end_date','is_heading'];
begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000
  or not b ?& array['team_id','project_id','task_id','request_id','task_generation','base','changes']
  or exists(select 1 from jsonb_object_keys(b) keys(key) where keys.key not in('team_id','project_id','task_id','request_id','task_generation','base','changes','checklist_restore_from','task_types_protocol')) then
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
 if taskfold_private.team_type_needed(base,changes) then
  if b->'task_types_protocol' is distinct from '1'::jsonb then raise exception using errcode='22023',message='Review task types with a supported client';end if;
 elsif b ? 'task_types_protocol' then raise exception using errcode='22023',message='Unexpected task type protocol';end if;
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
  if taskfold_private.team_type_needed(base,changes) then
   perform 1 from taskfold_private.team_project_config where singleton and native_task_types_enabled for share;
   if not found then raise exception using errcode='PT503',message='Team heading editing is not enabled';end if;
  end if;
  perform taskfold_private.team_type_review(base,changes,to_jsonb(row));
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
 return jsonb_build_object('protocol',1,'account',a,'team_id',team,'project_id',p,'request_id',q,'task_generation',generation,'task',to_jsonb(row),'replayed',replay)||case when taskfold_private.team_type_needed(base,changes) then jsonb_build_object('task_types_protocol',1) else '{}'::jsonb end;
end$$;

create or replace function taskfold_private.workspace_boundary() returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();ids uuid[]:='{}';tr taskfold_private.teams;reads boolean;edits boolean;enabled boolean;projects jsonb;teams jsonb;result jsonb;token text;
begin
 perform taskfold_private.team_actor();
 select native_reads_enabled,native_task_edits_enabled into reads,edits from taskfold_private.team_project_config where singleton for share;
 select c.enabled into enabled from taskfold_private.team_config c where singleton for share;
 -- Match role-command serialization; recheck identity after every potential wait.
 for tr in select t.* from taskfold_private.teams t join taskfold_private.team_members m on m.team_id=t.id where m.user_id=a and t.state<>'deleted' order by t.id for share of t loop ids=array_append(ids,tr.id);end loop;
 perform 1 from taskfold_private.team_access_epochs e where e.team_id=any(ids) order by e.team_id for share;
 perform taskfold_private.team_actor();
 -- The epoch includes access ABA changes, not ordinary task edits. Continuous
 -- collaboration need not prevent refreshing under unchanged permissions.
 select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'state',t.state,'revision',t.revision,'access_revision',e.revision) order by t.id),'[]') into teams
  from taskfold_private.teams t join taskfold_private.team_access_epochs e on e.team_id=t.id
  join taskfold_private.team_members m on m.team_id=t.id and m.user_id=a where t.id=any(ids) and t.state<>'deleted' and reads;
 select coalesce(jsonb_agg(v order by id),'[]') into projects from (
  select p.id,jsonb_build_object('id',p.id,'team_id',null,'role',case when p.user_id=a then 'owner' else 'collaborator' end,
   'archived',p.is_archived or p.ancestor_archived,'can_send_tasks',true) v
  from public.projects p where not exists(select 1 from taskfold_private.team_project_identities i where i.project_id=p.id)
   and (p.user_id=a or exists(select 1 from public.project_collaborators c where c.project_id=p.id and c.user_id=a and c.status='accepted'))
  union all
  select p.id,jsonb_build_object('id',p.id,'team_id',c.team_id,'role',taskfold_private.team_project_role(a,p.id),
   'archived',p.is_archived or p.ancestor_archived,'can_send_tasks',coalesce(edits and enabled and t.state='active' and not(p.is_archived or p.ancestor_archived) and taskfold_private.team_project_role(a,p.id) in('manager','editor'),false))
  from public.projects p join taskfold_private.team_content_projects c on c.project_id=p.id join taskfold_private.teams t on t.id=c.team_id
  where reads and c.team_id=any(ids) and t.state<>'deleted' and taskfold_private.team_project_role(a,p.id) is not null
 ) q;
 if jsonb_array_length(projects)>10000 or jsonb_array_length(teams)>1000 then raise exception using errcode='54000',message='This workspace access list is too large to refresh safely';end if;
 result=jsonb_build_object('task_types_protocol',case when reads and edits and enabled and (select native_task_types_enabled from taskfold_private.team_project_config where singleton) then 1 else 0 end,'workspace_boundary_protocol',1,'account',a,'native_team_reads_enabled',coalesce(reads,false),'setup_paused',not coalesce(enabled,false),'projects',projects,'teams',teams);
 select encode(extensions.hmac(convert_to(result::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 result=result||jsonb_build_object('token',token);
 if octet_length(result::text)>3000000 then raise exception using errcode='54000',message='This workspace access list is too large to refresh safely';end if;
 return result;
end$$;
