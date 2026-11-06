-- Disabled candidate: create/delete/verified Undo share the existing durable
-- request namespace. No direct/native legacy task policy is widened.
alter table taskfold_private.team_task_edit_scope
 add column operation text not null default 'patch' check(operation in('patch','create','delete','detach','reattach')),
 add column related_id uuid;
alter table taskfold_private.team_task_edits
 add column operation text not null default 'patch' check(operation in('patch','create','delete','restore')),
 add column restoration_hash text,
 add column restored_request uuid,
 add column parent_generation uuid;
create table taskfold_private.team_task_deleted_links (
 team_id uuid not null,request_id uuid not null,child_id uuid not null,
 generation uuid not null,project_id uuid not null,detached_revision text not null,
 primary key(team_id,request_id,child_id),
 foreign key(team_id,request_id) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
alter table taskfold_private.team_task_deleted_links enable row level security;
revoke all on taskfold_private.team_task_deleted_links from public,anon,authenticated,service_role;
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
 if t is not null and tg_table_name='tasks' then
  if tg_op='INSERT' and exists(select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current()
   and s.team_id=t and s.project_id=new.project_id and s.task_id=new.id and s.generation=new.task_generation
   and s.actor_id=auth.uid() and s.operation='create') then return new;end if;
  if tg_op='DELETE' and exists(select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current()
   and s.team_id=t and s.project_id=old.project_id and s.task_id=old.id and s.generation=old.task_generation
   and s.actor_id=auth.uid() and s.operation='delete') then return old;end if;
  if tg_op='UPDATE' and exists(select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current()
   and s.team_id=t and s.project_id=old.project_id and s.project_id=new.project_id
   and s.task_id=old.id and s.task_id=new.id and s.generation=old.task_generation and s.generation=new.task_generation
   and s.actor_id=auth.uid() and (s.operation='patch' or (
    (to_jsonb(new)-'recurrence_parent_id')=(to_jsonb(old)-'recurrence_parent_id') and
    (s.operation='detach' and old.recurrence_parent_id=s.related_id and new.recurrence_parent_id is null
     or s.operation='reattach' and new.recurrence_parent_id=s.related_id and old.recurrence_parent_id is null)))) then return new;end if;
 end if;
 if t is not null and not exists(select 1 from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t) then
  raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;


create or replace function taskfold_private.check_task_assignment(a text,project uuid,owner uuid)
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if a is null or a='' then return;end if;
 if taskfold_private.is_team_content_project(project) then
  if coalesce(taskfold_private.team_project_role(a::uuid,project),'') not in('manager','editor') then
   raise exception using errcode='42501',message='Choose a current project editor';end if;
 elsif (project is null and a::uuid<>owner) or (project is not null and not public.has_project_access(a::uuid,project)) then
  raise exception 'Assign tasks only to current project members';
 end if;
end$$;
revoke all on function taskfold_private.check_task_assignment(text,uuid,uuid) from public,anon,authenticated,service_role;
-- Called only with the team locked and recipient Auth rows already held.
create function taskfold_private.team_task_member(a uuid,p uuid,owner uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$begin
 if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then
  raise exception using errcode='42501',message='Choose a current project editor';end if;
end$$;
create function taskfold_private.team_task_tree(rows jsonb,old_nodes jsonb,_project uuid,_owner uuid,_at timestamptz,depth int default 0)
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
   perform taskfold_private.team_task_member((merged->>'assigned_to')::uuid,_project,_owner);
  end if;
  merged:=merged||jsonb_build_object('subtasks',taskfold_private.team_task_tree(coalesce(row->'subtasks',old->'subtasks','[]'),old_nodes,_project,_owner,_at,depth+1));
  result:=result||jsonb_build_array(merged);
 end loop;
 return result;
end $$;
revoke all on function taskfold_private.team_task_member(uuid,uuid,uuid),taskfold_private.team_task_tree(jsonb,jsonb,uuid,uuid,timestamptz,integer) from public,anon,authenticated,service_role;

-- Original field values travel back in the user's Undo request, not the receipt.
-- Normalize only incarnation/server completion counters when certifying a restore.
create function taskfold_private.team_task_restoration_hash(t public.tasks) returns text
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select taskfold_private.automation_task_revision(jsonb_populate_record(t,'{"task_generation":null,"completion_version":0}'::jsonb))
$$;
revoke all on function taskfold_private.team_task_restoration_hash(public.tasks) from public,anon,authenticated,service_role;

create function taskfold_private.team_task_lifecycle(action text,b jsonb) returns jsonb
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
   -- Conversation preservation is owned by the next shared-comment adapter.
   -- Do not let an FK cascade discard someone else's conversation in the meantime.
   if exists(select 1 from public.task_comments where task_id=cmd.id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Preserve this conversation before removing the task';end if;
   if row.recurrence_parent_id is not null then select task_generation into parent_generation from public.tasks where tasks.id=row.recurrence_parent_id for key share;end if;
   hash=taskfold_private.team_task_restoration_hash(row);
   insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation,restoration_hash,parent_generation) values(team,q,a,fingerprint,id,generation,action,hash,parent_generation);
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
   parent_generation=original.parent_generation;
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
create function public.taskfold_team_task_lifecycle(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_task_lifecycle(_action,_body)$$;
revoke all on function taskfold_private.team_task_lifecycle(text,jsonb),public.taskfold_team_task_lifecycle(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_task_lifecycle(text,jsonb),public.taskfold_team_task_lifecycle(text,jsonb) to authenticated;

-- An older unscoped queue must not silently acknowledge an RLS-hidden task.
CREATE OR REPLACE FUNCTION public.taskfold_patch_task(_id uuid, _base jsonb, _changes jsonb)
 RETURNS tasks
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t public.tasks; merged jsonb; k text; base_value jsonb; desired_value jsonb; remote_value jsonb; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 if taskfold_private.is_team_content_task(_id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this team action in a supported Taskfold app';end if;
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


-- An older unscoped queue must not silently acknowledge an RLS-hidden task.
create or replace function public.taskfold_delete_task(_id uuid, _base jsonb)
returns boolean language plpgsql security invoker set search_path = '' as $$
declare t public.tasks; expected public.tasks; current_json jsonb; expected_json jsonb; k text;
begin
 if auth.uid() is null then raise exception 'Sign in to delete tasks'; end if;
 if taskfold_private.is_team_content_task(_id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this team action in a supported Taskfold app';end if;
 if _base is null or jsonb_typeof(_base) <> 'object' or not (_base ?& array['id','user_id','title']) then
  raise exception 'TASKFOLD_CONFLICT: Review this older deletion before removing a synced task';
 end if;
 if (_base->>'id')::uuid is distinct from _id then raise exception 'Invalid deletion identity'; end if;
 select * into t from public.tasks where id = _id for update;
 -- Already deleted or no longer visible: an idempotent success never reveals another account's row.
 if not found then return true; end if;
 -- Defaults match missing=default inserts from the native queue. Populate the typed record
 -- to canonicalize UUIDs, dates, clocks and timestamps before comparing the whole task.
 expected := jsonb_populate_record(null::public.tasks,
  '{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}'::jsonb || _base);
 current_json := to_jsonb(t); expected_json := to_jsonb(expected);
 for k in select jsonb_object_keys(current_json) loop
  -- The server assigns created_at when an ordinary new-task insert omits it.
  if k = 'created_at' and not (_base ? k) then continue; end if;
  if current_json->k is distinct from expected_json->k then
   raise exception 'TASKFOLD_CONFLICT: This task changed before deletion. Review the synced version';
  end if;
 end loop;
 delete from public.tasks where id = _id;
 if not found then raise exception 'This task could not be deleted. Your change is saved locally.'; end if;
 return true;
end $$;
revoke all on function public.taskfold_delete_task(uuid,jsonb) from public, anon;
grant execute on function public.taskfold_delete_task(uuid,jsonb) to authenticated;
