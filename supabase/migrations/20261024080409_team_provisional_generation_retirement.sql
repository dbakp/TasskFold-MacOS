-- Purely provisional tombstones are not deletions of actual shared work.
-- Keep their exact generation retired without blocking another fresh generation.
create table taskfold_private.team_provisional_retirements (
 task_id uuid not null,generation uuid not null,team_id uuid not null references taskfold_private.teams(id) on delete restrict,project_id uuid not null,
 primary key(task_id,generation),foreign key(task_id,generation) references taskfold_private.task_generations(task_id,generation) on delete cascade
);
create index team_provisional_retirements_team on taskfold_private.team_provisional_retirements(team_id,project_id);
alter table taskfold_private.team_provisional_retirements enable row level security;
revoke all on taskfold_private.team_provisional_retirements from public,anon,authenticated,service_role;

-- A recorded completion may have adopted another occurrence while an offline
-- client edited its unused provisional generation. Retire that exact generation
-- before any local draft is parked: old callbacks must never gain a live target.
create function taskfold_private.retire_team_provisional_generation(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<retirement>>
declare r jsonb;a uuid:=auth.uid();team uuid;p uuid;q uuid;id uuid;g uuid;registry taskfold_private.task_generations;
 binding taskfold_private.team_content_tasks;current_row jsonb;result jsonb;
begin
 -- Includes live identity/session, original actor/HMAC, read flags/project role,
 -- active team and the original command nonce mutex. Never executes completion.
 r=taskfold_private.review_team_completion('complete',b);
 if r->>'state'<>'recorded' or r->'planned_next_id'='null'::jsonb then raise exception using errcode='PT409',message='This draft needs another review';end if;
 team=(r->>'team_id')::uuid;p=(r->>'project_id')::uuid;q=(r->>'request_id')::uuid;
 id=(r->>'planned_next_id')::uuid;g=taskfold_private.team_uuid(b,'next_generation');
 -- The recorded, HMAC-bound original completion certified this prospective ID.
 -- A merely cancelled/forged baseline cannot reserve arbitrary task identities.
 if not exists(select 1 from taskfold_private.team_task_completions c where c.team_id=team and c.request_id=q and c.action='complete' and c.planned_id=id) then raise exception using errcode='PT409',message='This draft needs another review';end if;
 perform pg_advisory_xact_lock(hashtextextended(id::text,78137));
 -- Creation/deletion use the same mutex. Recheck after waiting rather than
 -- retiring a generation that became live while the read was in flight.
 if exists(select 1 from public.tasks where tasks.id=retirement.id and tasks.task_generation=g) then raise exception using errcode='PT409',message='This occurrence is already shared. Review its changes instead';end if;
 select * into binding from taskfold_private.team_content_tasks where task_id=id and generation=g;
 if found and (binding.team_id<>team or binding.project_id<>p) then raise exception using errcode='PT409',message='This draft identity is unavailable';end if;
 select * into registry from taskfold_private.task_generations where task_id=id and generation=g;
 if found and (registry.deleted_at is null or binding.task_id is null) then raise exception using errcode='PT409',message='This draft identity is unavailable';end if;
 insert into taskfold_private.team_content_tasks(task_id,generation,team_id,project_id) values(id,g,team,p) on conflict(task_id,generation) do nothing;
 if registry.task_id is null then
  insert into taskfold_private.task_generations(user_id,task_id,generation,eligible_at,deleted_at) values(a,id,g,clock_timestamp(),clock_timestamp());
  insert into taskfold_private.team_provisional_retirements(task_id,generation,team_id,project_id) values(id,g,team,p);
 end if;
 -- Custody/tombstone UUIDs survive actor removal and team deletion, exactly like
 -- other team generation history. No public task or attribution is manufactured.
 r=taskfold_private.review_team_completion('complete',b);
 select to_jsonb(t) into current_row from public.tasks t where t.id=retirement.id and t.project_id=p
  and exists(select 1 from taskfold_private.team_content_tasks x where x.task_id=t.id and x.generation=t.task_generation and x.team_id=team and x.project_id=p);
 result=jsonb_build_object('draft_retirement_protocol',1,'account',a,'team_id',team,'project_id',p,'request_id',q,
  'task_id',id,'task_generation',g,'generation_unavailable',true,'review',r,'current_proposed',current_row);
 if octet_length(result::text)>1900000 then raise exception using errcode='54000',message='This draft review is too large. Your saved work is unchanged';end if;
 return result;
end$$;
create function public.taskfold_retire_team_provisional(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.retire_team_provisional_generation(_body)$$;
revoke all on function taskfold_private.retire_team_provisional_generation(jsonb),public.taskfold_retire_team_provisional(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.retire_team_provisional_generation(jsonb),public.taskfold_retire_team_provisional(jsonb) to authenticated;

create or replace function taskfold_private.team_completion_generation_history(id uuid) returns text
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.hmac(convert_to(coalesce((select jsonb_agg(jsonb_build_array(g.generation,g.deleted_at,e.revision) order by g.generation) from taskfold_private.task_generations g left join taskfold_private.team_task_write_epochs e on e.task_id=g.task_id and e.generation=g.generation where g.task_id=id and not exists(select 1 from taskfold_private.team_provisional_retirements v where v.task_id=g.task_id and v.generation=g.generation)),'[]')::text,'UTF8'),s.secret,'sha256'),'hex') from taskfold_private.automation_revision_secret s where singleton
$$;

-- Retain the full guarded transaction; only the test for a real canonical
-- deletion changes. Exact retired generations are still rejected below.
create or replace function taskfold_private.team_complete_task(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;p uuid;id uuid;generation uuid;q uuid;series uuid;series_gen uuid;series_p uuid;
 next_gen uuid;planned uuid;ref uuid;at_time timestamptz;zone text;fingerprint text;tr taskfold_private.teams;
 source public.tasks;expected public.tasks;successor public.tasks;parent public.tasks;
 prior taskfold_private.team_task_edits;c taskfold_private.team_task_completions;original taskfold_private.team_task_completions;
 plan jsonb;payload jsonb;nodes jsonb;k text;node_value jsonb;recipient_ids uuid[];lock_ids uuid[];candidate_ids uuid[];uid uuid;
 defaults constant jsonb:='{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}';
begin
 perform taskfold_private.team_actor();
 if action is null or action not in('complete','undo') or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000
  or not b ?& array['team_id','project_id','task_id','task_generation','request_id','record','completed_at','input_zone','next_generation','planned_next_id','series_id','series_generation','series_project_id']
  or exists(select 1 from jsonb_object_keys(b) e where e not in('team_id','project_id','task_id','task_generation','request_id','record','completed_at','input_zone','next_generation','planned_next_id','series_id','series_generation','series_project_id','undoes','redo_of')) then raise exception using errcode='22023',message='Invalid saved completion';end if;
 team=taskfold_private.team_uuid(b,'team_id');p=taskfold_private.team_uuid(b,'project_id');id=taskfold_private.team_uuid(b,'task_id');generation=taskfold_private.team_uuid(b,'task_generation');q=taskfold_private.team_uuid(b,'request_id');
 series=taskfold_private.team_uuid(b,'series_id');series_gen=taskfold_private.team_uuid(b,'series_generation');series_p=taskfold_private.team_uuid(b,'series_project_id');next_gen=taskfold_private.team_uuid(b,'next_generation');
 if b->'planned_next_id'<>'null'::jsonb then planned=taskfold_private.team_uuid(b,'planned_next_id');end if;
 if action='undo' then ref=taskfold_private.team_uuid(b,'undoes');if b ? 'redo_of' then raise exception using errcode='22023',message='Review this Undo';end if;
 else if b ? 'undoes' then raise exception using errcode='22023',message='Review this completion';end if;if b ? 'redo_of' then ref=taskfold_private.team_uuid(b,'redo_of');end if;end if;
 if jsonb_typeof(b->'completed_at')<>'string' or (b->>'completed_at')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.[0-9]+)?(Z|[+-]\d{2}:?\d{2})$' or jsonb_typeof(b->'input_zone')<>'string' then raise exception using errcode='22023',message='Use a completion clock and named time zone';end if;
 at_time=(b->>'completed_at')::timestamptz;zone=b->>'input_zone';
 if not isfinite(at_time) or not exists(select 1 from pg_timezone_names where name=zone) then raise exception using errcode='22023',message='Use a completion clock and named time zone';end if;
 payload=b->'record';
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['id','user_id','title','project_id','task_generation','completed','completion_version']
  or payload->'id' is distinct from to_jsonb(id) or payload->'project_id' is distinct from to_jsonb(p) or payload->'task_generation' is distinct from to_jsonb(generation)
  or payload->'completed' is distinct from 'false'::jsonb
  or not taskfold_private.automation_reminder_integer(payload->'completion_version',0,9007199254740990)
  or exists(select 1 from jsonb_object_keys(payload) e where not exists(select 1 from pg_attribute att where att.attrelid='public.tasks'::regclass and att.attnum>0 and not att.attisdropped and att.attname=e)) then raise exception using errcode='22023',message='Include the original task and completion revision';end if;
 expected=jsonb_populate_record(null::public.tasks,defaults||payload);
 nodes=taskfold_private.automation_tree_index(coalesce(expected.subtasks,'[]'));
 for k,node_value in select * from jsonb_each(nodes) loop
  perform taskfold_private.automation_validate_fields((select coalesce(jsonb_object_agg(e.k,e.v),'{}') from jsonb_each(node_value) e(k,v) where e.k='assigned_to'),null);
 end loop;
 select array_agg(distinct u order by u) into recipient_ids from (select expected.assigned_to u union all select (e.value->>'assigned_to')::uuid from jsonb_each(nodes) e where coalesce(e.value->>'assigned_to','')<>'') z where u is not null;
 perform 1 from auth.users where users.id=any(coalesce(recipient_ids,'{}')) order by users.id for share;
 select * into tr from taskfold_private.teams where teams.id=team for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform taskfold_private.team_actor();
 if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') or coalesce(taskfold_private.team_project_role(a,series_p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found or tr.state<>'active' then raise exception using errcode='PT503',message='Team editing is paused';end if;
 perform 1 from taskfold_private.team_content_projects where project_id in(p,series_p) and team_id=team order by project_id for share;
 if not exists(select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) or not exists(select 1 from taskfold_private.team_content_projects where project_id=series_p and team_id=team) then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform 1 from public.projects where projects.id in(p,series_p) order by projects.id for share;
 if not exists(select 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived) or not exists(select 1 from public.projects where projects.id=series_p) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This project is archived or unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,action,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 if exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This action identity is already used';end if;
 select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;
 if found then
  select * into c from taskfold_private.team_task_completions where team_id=team and request_id=q;
  if not found or prior.actor_id<>a or prior.fingerprint<>fingerprint or prior.task_id<>id or prior.generation<>generation or c.action<>action then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This action identity is already used';end if;
  return taskfold_private.team_completion_reply(c,true);
 end if;
 if ref is not null then
  select x.* into original from taskfold_private.team_task_completions x join taskfold_private.team_task_edits e using(team_id,request_id)
   where x.team_id=team and x.request_id=ref and e.actor_id=a and x.project_id=p and x.task_id=cmd.id and x.generation=cmd.generation;
  if not found or (action='undo' and (original.action<>'complete' or original.undone_by is not null)) or (action='complete' and (original.action<>'undo' or original.redone_by is not null)) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This saved completion history is unavailable';end if;
 end if;
 if action='complete' then
  if expected.is_recurring and (expected.due_date is null or not taskfold_private.automation_recurrence_valid(expected.recurrence_pattern)) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this repeat rule before completing';end if;
  plan=taskfold_private.automation_recurrence_plan(to_jsonb(expected),at_time,zone);
  if planned is distinct from (plan->>'id')::uuid or series is distinct from (case when plan is null then id else coalesce(expected.recurrence_parent_id,id) end)
   or (series=id and (series_gen<>generation or series_p<>p)) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The next occurrence changed';end if;
 else
  if original.planned_id is distinct from planned or original.series_id<>series or original.series_generation<>series_gen or original.series_project_id<>series_p or original.completed_at<>at_time or original.input_zone<>zone then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this completion Undo';end if;
 end if;
 -- Reserve all known task identities before taking any task row locks.
 select array_agg(t.id order by t.id) into candidate_ids from public.tasks t where action='complete' and planned is not null and (t.id=planned or (t.recurrence_parent_id=series and t.due_date=(plan->>'due_date')::date));
 select array_agg(distinct x order by x) into lock_ids from unnest(array[id,series,planned,original.successor_id]||coalesce(candidate_ids,'{}')) x where x is not null;
 foreach uid in array lock_ids loop perform pg_advisory_xact_lock(hashtextextended(uid::text,78137));end loop;
 if series<>id then
  select * into parent from public.tasks where tasks.id=series and tasks.task_generation=series_gen and tasks.project_id=series_p for key share;
  if not found then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The original repeat task changed';end if;
 end if;
 select * into source from public.tasks where tasks.id=cmd.id and tasks.task_generation=cmd.generation and tasks.project_id=p for update;
 if not found or not exists(select 1 from taskfold_private.team_content_tasks where task_id=cmd.id and taskfold_private.team_content_tasks.generation=cmd.generation and team_id=team and project_id=p) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This task was replaced or moved';end if;
 if source.completion_version>=9007199254740991 then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review this completion revision';end if;
 c.team_id=team;c.request_id=q;c.project_id=p;c.action=action;c.task_id=id;c.generation=generation;c.completed_at=at_time;c.input_zone=zone;c.series_id=series;c.series_generation=series_gen;c.series_project_id=series_p;c.planned_id=planned;c.related_request=ref;c.created=false;c.removed=false;
 if action='complete' then
  for k,node_value in select * from jsonb_each(to_jsonb(source)) loop
   if k='created_at' and not(payload ? k) then continue;end if;
   if k='subtasks' then
    if taskfold_private.team_completion_tree_base(coalesce(source.subtasks,'[]')) is distinct from taskfold_private.team_completion_tree_base(coalesce(expected.subtasks,'[]')) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The checklist changed before completion';end if;
   elsif node_value is distinct from to_jsonb(expected)->k then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This task changed before completion';end if;
  end loop;
  if planned is not null then
   if planned in(id,series) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The recurring identity conflicts';end if;
   if exists(select 1 from public.tasks t where (t.id=planned or (t.recurrence_parent_id=series and t.due_date=(plan->>'due_date')::date)) and not(t.id=any(coalesce(lock_ids,'{}')))) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The recurring tasks changed';end if;
   select array_agg(t.id order by t.id) into candidate_ids from public.tasks t where t.id=planned or (t.recurrence_parent_id=series and t.due_date=(plan->>'due_date')::date);
   if (select count(*) from public.tasks t where t.id=any(coalesce(candidate_ids,'{}')))>1 then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the existing occurrences';end if;
   select * into successor from public.tasks where tasks.id=any(coalesce(candidate_ids,'{}')) for update;
   if found then
    if successor.project_id<>p or successor.recurrence_parent_id is distinct from series or successor.due_date is distinct from (plan->>'due_date')::date or successor.task_generation is null
     or not exists(select 1 from taskfold_private.team_content_tasks x where x.task_id=successor.id and x.generation=successor.task_generation and x.team_id=team and x.project_id=p) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The recurring identity is unavailable';end if;
   else
    if ref is not null and original.removed and original.successor_id=planned and original.generation_history is distinct from taskfold_private.team_completion_generation_history(planned) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The occurrence changed after Undo';end if;
    if not exists(select 1 from taskfold_private.task_generations h where h.task_id=planned and not exists(select 1 from taskfold_private.team_provisional_retirements v where v.task_id=h.task_id and v.generation=h.generation)) or (ref is not null and original.removed and original.successor_id=planned and original.generation_history=taskfold_private.team_completion_generation_history(planned)) then
    if exists(select 1 from taskfold_private.task_generations where task_id=planned and taskfold_private.task_generations.generation=next_gen) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Use a fresh occurrence identity';end if;
    payload=taskfold_private.automation_successor(to_jsonb(source),a,at_time,zone,q,next_gen);
    payload=jsonb_set(payload,array['subtasks'],taskfold_private.team_completion_children(payload->'subtasks',p,q));
    if payload->'assigned_to'<>'null'::jsonb and (coalesce(taskfold_private.team_project_role((payload->>'assigned_to')::uuid,p),'') not in('manager','editor') or not exists(select 1 from auth.users where users.id=(payload->>'assigned_to')::uuid and (banned_until is null or banned_until<=clock_timestamp()))) then payload=payload||'{"assigned_to":null}';end if;
    successor=jsonb_populate_record(null::public.tasks,payload);
    insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation) values(txid_current(),team,p,successor.id,next_gen,a,'create');
    insert into public.tasks select (successor).* returning * into successor;
    delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=successor.id;
    c.created=true;c.successor_hash=taskfold_private.team_completion_task_hash(successor);
    end if;
   end if;
   c.successor_id=coalesce(successor.id,planned);c.successor_generation=successor.task_generation;
  end if;
 else
  if source.completed is distinct from true or source.completion_version<>original.revision or source.completed_at is distinct from original.completed_at then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Completion changed after this action';end if;
  c.successor_id=original.successor_id;c.successor_generation=original.successor_generation;c.created=original.created;
  if original.created and original.successor_generation is not null then
   select * into successor from public.tasks where tasks.id=original.successor_id and tasks.task_generation=original.successor_generation and tasks.project_id=p for update;
   if found and taskfold_private.team_completion_task_hash(successor)=original.successor_hash
    and not exists(select 1 from public.task_comments where task_id=successor.id)
    and not exists(select 1 from public.tasks where recurrence_parent_id=successor.id) then
    insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation) values(txid_current(),team,p,successor.id,successor.task_generation,a,'delete');
    delete from public.tasks where tasks.id=successor.id;
    delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=successor.id;
    c.removed=true;c.generation_history=taskfold_private.team_completion_generation_history(successor.id);
   end if;
  end if;
 end if;
 insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,p,id,generation,a,'patch',q);
 source=taskfold_private.team_task_merge(id,jsonb_build_object('task_generation',generation,'completed',source.completed,'completed_at',source.completed_at,'completion_version',source.completion_version),jsonb_build_object('completed',action='complete','completed_at',case when action='complete' then at_time else null end));
 delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=cmd.id;
 c.revision=source.completion_version;
 insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation) values(team,q,a,fingerprint,id,generation);
 insert into taskfold_private.team_task_completions select (c).*;
 if ref is not null then
  if action='undo' then update taskfold_private.team_task_completions set undone_by=q where team_id=team and request_id=ref;
  else update taskfold_private.team_task_completions set redone_by=q where team_id=team and request_id=ref;end if;
 end if;
 return taskfold_private.team_completion_reply(c,false);
end$$;
