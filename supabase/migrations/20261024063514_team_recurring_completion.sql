-- Atomic native completion/Undo. All data writes use exact private task scopes.
create table taskfold_private.team_task_completions (
 team_id uuid not null,request_id uuid not null,project_id uuid not null,
 action text not null check(action in('complete','undo')),task_id uuid not null,generation uuid not null,
 revision bigint not null,completed_at timestamptz not null,input_zone text not null,
 series_id uuid not null,series_generation uuid not null,series_project_id uuid not null,
 planned_id uuid,successor_id uuid,successor_generation uuid,created boolean not null default false,
 removed boolean not null default false,successor_hash text,generation_history text,
 related_request uuid,undone_by uuid,redone_by uuid,
 primary key(team_id,request_id),
 foreign key(team_id,request_id) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
alter table taskfold_private.team_task_completions enable row level security;
revoke all on taskfold_private.team_task_completions from public,anon,authenticated,service_role;

-- A durable revision survives edit/revert cycles and actor-receipt cleanup.
create table taskfold_private.team_task_write_epochs (
 task_id uuid not null,generation uuid not null,team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 revision bigint not null default 0 check(revision>=0),primary key(task_id,generation)
);
create index team_task_write_epochs_team on taskfold_private.team_task_write_epochs(team_id);
alter table taskfold_private.team_task_write_epochs enable row level security;
revoke all on taskfold_private.team_task_write_epochs from public,anon,authenticated,service_role;
insert into taskfold_private.team_task_write_epochs(task_id,generation,team_id)
 select t.id,t.task_generation,p.team_id from public.tasks t join taskfold_private.team_content_projects p on p.project_id=t.project_id where t.task_generation is not null;
create function taskfold_private.record_team_task_write_epoch() returns trigger
language plpgsql security definer set search_path='' as $$
declare t uuid;id uuid;g uuid;begin
 if tg_table_name='team_task_edits' then
  if new.operation not in('delete','restore') then return new;end if;
  t=new.team_id;id=new.task_id;g=new.generation;
 elsif tg_op='DELETE' then
  select team_id into t from taskfold_private.team_content_tasks where task_id=old.id and generation=old.task_generation;
  id=old.id;g=old.task_generation;
 else
  select team_id into t from taskfold_private.team_content_projects where project_id=new.project_id;
  id=new.id;g=new.task_generation;
 end if;
 if t is not null and g is not null then
  if tg_table_name='tasks' and tg_op='INSERT' then
   insert into taskfold_private.team_task_write_epochs(task_id,generation,team_id) values(id,g,t) on conflict(task_id,generation) do nothing;
  elsif tg_table_name<>'tasks' or tg_op='DELETE' or new is distinct from old then
   insert into taskfold_private.team_task_write_epochs(task_id,generation,team_id,revision) values(id,g,t,1)
    on conflict(task_id,generation) do update set revision=taskfold_private.team_task_write_epochs.revision+1;
  end if;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;
revoke all on function taskfold_private.record_team_task_write_epoch() from public,anon,authenticated,service_role;
create trigger taskfold_team_write_epoch after insert or update or delete on public.tasks for each row execute function taskfold_private.record_team_task_write_epoch();
create trigger team_task_deleted_write_epoch after insert on taskfold_private.team_task_edits for each row execute function taskfold_private.record_team_task_write_epoch();
create function taskfold_private.team_completion_task_hash(t public.tasks) returns text
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.hmac(convert_to(jsonb_build_array(to_jsonb(t),(select e.revision from taskfold_private.team_task_write_epochs e where e.task_id=t.id and e.generation=t.task_generation))::text,'UTF8'),s.secret,'sha256'),'hex') from taskfold_private.automation_revision_secret s where singleton
$$;
revoke all on function taskfold_private.team_completion_task_hash(public.tasks) from public,anon,authenticated,service_role;

-- Ignore only server-stamped nested completion dates when certifying an offline
-- baseline. Epoch/revision, state and all authored/opaque fields still match.
create function taskfold_private.team_completion_tree_base(rows jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare n jsonb;r jsonb:='[]';begin
 for n in select * from jsonb_array_elements(coalesce(rows,'[]')) loop
  n=n-'completed_at';if n ? 'subtasks' then n=jsonb_set(n,array['subtasks'],taskfold_private.team_completion_tree_base(n->'subtasks'));end if;
  r=r||jsonb_build_array(n);
 end loop;return r;
end$$;
create function taskfold_private.team_completion_generation_history(id uuid) returns text
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.hmac(convert_to(coalesce((select jsonb_agg(jsonb_build_array(g.generation,g.deleted_at,e.revision) order by g.generation) from taskfold_private.task_generations g left join taskfold_private.team_task_write_epochs e on e.task_id=g.task_id and e.generation=g.generation where g.task_id=id),'[]')::text,'UTF8'),s.secret,'sha256'),'hex') from taskfold_private.automation_revision_secret s where singleton
$$;
-- Source JSON is the actual locked row, never caller-supplied clone content.
create function taskfold_private.team_completion_children(rows jsonb,p uuid,q uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare n jsonb;r jsonb:='[]';person uuid;begin
 for n in select * from jsonb_array_elements(coalesce(rows,'[]')) loop
  n=n||jsonb_build_object('taskfold_completion_v1',jsonb_build_object('epoch',taskfold_private.team_checklist_epoch(q,n->>'id'),'version',0));
  if coalesce(n->>'assigned_to','')<>'' then
   person=(n->>'assigned_to')::uuid;
   if coalesce(taskfold_private.team_project_role(person,p),'') not in('manager','editor') or not exists(select 1 from auth.users where users.id=person and (banned_until is null or banned_until<=clock_timestamp())) then n=n||'{"assigned_to":null}';end if;
  end if;
  if n ? 'subtasks' then n=jsonb_set(n,array['subtasks'],taskfold_private.team_completion_children(n->'subtasks',p,q));end if;
  r=r||jsonb_build_array(n);
 end loop;return r;
end$$;
create function taskfold_private.team_completion_reply(c taskfold_private.team_task_completions,replayed boolean) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',auth.uid(),'team_id',c.team_id,'project_id',c.project_id,
 'task_id',c.task_id,'task_generation',c.generation,'request_id',c.request_id,'operation',c.action,'related_request',c.related_request,
 'series_id',c.series_id,'series_generation',c.series_generation,'series_project_id',c.series_project_id,
 'planned_next_id',c.planned_id,'successor_id',c.successor_id,'successor_generation',c.successor_generation,
 'created_successor',c.created,'removed_successor',c.removed,'source_revision',c.revision,'replayed',replayed,
 'task',(select to_jsonb(t) from public.tasks t where t.id=c.task_id and t.task_generation=c.generation and t.project_id=c.project_id
  and exists(select 1 from taskfold_private.team_content_tasks x where x.task_id=t.id and x.generation=t.task_generation and x.team_id=c.team_id and x.project_id=c.project_id)),
 'successor',(select to_jsonb(t) from public.tasks t where t.id=c.successor_id and t.task_generation=c.successor_generation and t.project_id=c.project_id
  and exists(select 1 from taskfold_private.team_content_tasks x where x.task_id=t.id and x.generation=t.task_generation and x.team_id=c.team_id and x.project_id=c.project_id)))
$$;
revoke all on function taskfold_private.team_completion_tree_base(jsonb),taskfold_private.team_completion_generation_history(uuid),taskfold_private.team_completion_children(jsonb,uuid,uuid),taskfold_private.team_completion_reply(taskfold_private.team_task_completions,boolean) from public,anon,authenticated,service_role;

create function taskfold_private.team_complete_task(action text,b jsonb) returns jsonb
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
    if not exists(select 1 from taskfold_private.task_generations where task_id=planned) or (ref is not null and original.removed and original.successor_id=planned and original.generation_history=taskfold_private.team_completion_generation_history(planned)) then
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
create function public.taskfold_complete_team_task(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_complete_task(_action,_body)$$;
revoke all on function taskfold_private.team_complete_task(text,jsonb),public.taskfold_complete_team_task(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_complete_task(text,jsonb),public.taskfold_complete_team_task(text,jsonb) to authenticated;

create function taskfold_private.team_completion_team_deleted() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.state='deleted' then delete from taskfold_private.team_task_completions where team_id=new.id;delete from taskfold_private.team_task_write_epochs where team_id=new.id;end if;return new;
end$$;
revoke all on function taskfold_private.team_completion_team_deleted() from public,anon,authenticated,service_role;
create trigger team_completion_team_deleted after update of state on taskfold_private.teams for each row when(new.state='deleted') execute function taskfold_private.team_completion_team_deleted();
