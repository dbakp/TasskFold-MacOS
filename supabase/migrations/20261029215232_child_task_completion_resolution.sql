-- Terminal completion resolution is metadata-only and never grants task access.
-- Apply transactionally; ordinary app/server feature gates remain unchanged.
create table taskfold_private.child_task_completion_closures (
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 fingerprint text not null check(length(fingerprint)=64),created_at timestamptz not null default clock_timestamp(),
 primary key(actor_id,request_id)
);
create index child_completion_closures_actor_day on taskfold_private.child_task_completion_closures(actor_id,created_at);
create index team_task_edits_actor_request on taskfold_private.team_task_edits(actor_id,request_id);
create index team_task_batches_actor_request on taskfold_private.team_task_batches(actor_id,request_id);
alter table taskfold_private.child_task_completion_closures enable row level security;
revoke all on taskfold_private.child_task_completion_closures from public,anon,authenticated,service_role;

create function taskfold_private.validate_child_completion_request(b jsonb,a uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare id uuid;q uuid;inc uuid;g uuid;p uuid;rev bigint;key text;mode text;undo_id uuid;baseline jsonb;begin
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>4096 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','action']
  or exists(select 1 from jsonb_object_keys(b) x where x not in('protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','action','baseline','undo_of')) then
  raise exception using errcode='22023',message='Review this saved child completion';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This child completion belongs to another account';end if;
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');inc:=taskfold_private.team_uuid(b,'incarnation');
 g:=case when b->'task_generation'='null' then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null' then null else taskfold_private.team_uuid(b,'project_id') end;
 if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')!~'^[0-9]{1,16}$' or (b->>'revision')::numeric not between 1 and 9007199254740990
  or jsonb_typeof(b->'node_key') is distinct from 'string' or octet_length(b->>'node_key') not between 1 and 128
  or b->>'node_key' collate "C"<>normalize(b->>'node_key',NFC) collate "C" then
  raise exception using errcode='22023',message='Review this child identity';end if;
 rev:=(b->>'revision')::bigint;key:=b->>'node_key';mode:=b->>'action';
 if jsonb_typeof(b->'action') is distinct from 'string' or mode not in('complete','reopen','undo') then
  raise exception using errcode='22023',message='Choose a supported completion action';end if;
 if mode='undo' then
  if b ? 'baseline' or not(b ? 'undo_of') then raise exception using errcode='22023',message='Use the saved completion receipt for Undo';end if;
  undo_id:=taskfold_private.team_uuid(b,'undo_of');
 else
  if b ? 'undo_of' or not(b ? 'baseline') or jsonb_typeof(b->'baseline') is distinct from 'object'
   or exists(select 1 from jsonb_object_keys(b->'baseline') x where x not in('completed','completed_at','is_heading','taskfold_completion_v1')) then
   raise exception using errcode='22023',message='Review the completion baseline';end if;
  baseline:=taskfold_private.child_task_completion_state(b->'baseline');
  if coalesce((baseline->>'completed')::boolean,false)=(mode='complete') then
   raise exception using errcode='22023',message='Choose a changed completion state';end if;
 end if;
end$$;

-- Old team writers do not acquire the child actor lock before their root lock.
-- Never block on a new lock at their receipt insert: a failed try-lock aborts
-- the whole command, including any prior DML/history, without a lock inversion.
create function taskfold_private.guard_child_completion_terminal() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then
  raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=new.actor_id and request_id=new.request_id) then
  raise exception using errcode='PT410',message='This original completion request is closed';end if;
 return new;
end$$;
create trigger child_completion_terminal_team_edit before insert or update on taskfold_private.team_task_edits
 for each row execute function taskfold_private.guard_child_completion_terminal();
create trigger child_completion_terminal_team_batch before insert or update on taskfold_private.team_task_batches
 for each row execute function taskfold_private.guard_child_completion_terminal();
create trigger child_completion_terminal_receipt before insert or update on taskfold_private.child_task_completion_receipts
 for each row execute function taskfold_private.guard_child_completion_terminal();

create or replace function taskfold_private.guard_child_completion_identity() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then
  raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=new.actor_id and request_id=new.request_id) then
  raise exception using errcode='PT410',message='This original completion request is closed';end if;
 if exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=new.actor_id and request_id=new.request_id) then
  raise exception using errcode='PT409',message='This action identity was already used for completion';end if;
 return new;
end$$;

create function taskfold_private.close_child_completion(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;fingerprint text;prior taskfold_private.child_task_completion_receipts;
 old taskfold_private.child_task_completion_closures;result jsonb;begin
 perform taskfold_private.team_actor();
 perform pg_advisory_xact_lock(hashtextextended(a::text,73918));
 perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_completion_request(b,a);
 q:=taskfold_private.team_uuid(b,'request_id');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then
  raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 result:=(b-array['baseline','revision'])||jsonb_build_object('undo_of',coalesce(b->'undo_of','null'::jsonb),'outcome','closed','receipt',null);
 select * into prior from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This completion identity was already used';end if;
  return result||jsonb_build_object('outcome','applied','receipt',taskfold_private.child_task_completion_receipt(prior,true));
 end if;
 select * into old from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q;
 if found then
  if old.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This original completion identity was already closed';end if;
  return result;
 end if;
 if exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q) then
  raise exception using errcode='PT409',message='This request identity belongs to another task action';end if;
 if (select count(*) from taskfold_private.child_task_completion_closures where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then
  raise exception using errcode='PT429',message='Try closing this original completion later';end if;
 insert into taskfold_private.child_task_completion_closures(actor_id,request_id,fingerprint) values(a,q,fingerprint);
 return result;
end$$;
create function public.taskfold_close_child_completion(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.close_child_completion(_body)$$;
revoke all on function taskfold_private.validate_child_completion_request(jsonb,uuid),taskfold_private.guard_child_completion_terminal(),
 taskfold_private.guard_child_completion_identity(),taskfold_private.close_child_completion(jsonb),public.taskfold_close_child_completion(jsonb)
 from public,anon,authenticated,service_role;
grant execute on function taskfold_private.close_child_completion(jsonb),public.taskfold_close_child_completion(jsonb) to authenticated;

create or replace function taskfold_private.complete_child_task(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
<<op>>
declare a uuid:=auth.uid();id uuid;q uuid;g uuid;p uuid;team uuid;initial public.tasks;t public.tasks;
 node taskfold_private.child_task_records;projection taskfold_private.child_task_projections;
 prior taskfold_private.child_task_completion_receipts;original taskfold_private.child_task_completion_receipts;
 key text;inc uuid;rev bigint;fingerprint text;decoded jsonb;recipients uuid[];current_recipients uuid[];
 mode text;undo_id uuid;baseline jsonb;current_state jsonb;after_state jsonb;own_fields jsonb;desired jsonb;k text;epoch uuid;version bigint;
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child completion is not enabled';end if;
 perform taskfold_private.team_actor();
 perform pg_advisory_xact_lock(hashtextextended(a::text,73918));
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>4096 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','action']
  or exists(select 1 from jsonb_object_keys(b) x where x not in('protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','action','baseline','undo_of')) then
  raise exception using errcode='22023',message='Review this saved child completion';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This child completion belongs to another account';end if;
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');inc:=taskfold_private.team_uuid(b,'incarnation');
 g:=case when b->'task_generation'='null' then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null' then null else taskfold_private.team_uuid(b,'project_id') end;
 if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')!~'^[0-9]{1,16}$' or (b->>'revision')::numeric not between 1 and 9007199254740990
  or jsonb_typeof(b->'node_key') is distinct from 'string' or octet_length(b->>'node_key') not between 1 and 128
  or b->>'node_key' collate "C"<>normalize(b->>'node_key',NFC) collate "C" then
  raise exception using errcode='22023',message='Review this child identity';end if;
 rev:=(b->>'revision')::bigint;key:=b->>'node_key';mode:=b->>'action';
 if jsonb_typeof(b->'action') is distinct from 'string' or mode not in('complete','reopen','undo') then
  raise exception using errcode='22023',message='Choose a supported completion action';end if;
 if mode='undo' then
  if b ? 'baseline' or not(b ? 'undo_of') then raise exception using errcode='22023',message='Use the saved completion receipt for Undo';end if;
  undo_id:=taskfold_private.team_uuid(b,'undo_of');
 else
  if b ? 'undo_of' or not(b ? 'baseline') or jsonb_typeof(b->'baseline') is distinct from 'object'
   or exists(select 1 from jsonb_object_keys(b->'baseline') x where x not in('completed','completed_at','is_heading','taskfold_completion_v1')) then
   raise exception using errcode='22023',message='Review the completion baseline';end if;
  baseline:=taskfold_private.child_task_completion_state(b->'baseline');
  if coalesce((baseline->>'completed')::boolean,false)=(mode='complete') then
   raise exception using errcode='22023',message='Choose a changed completion state';end if;
 end if;
 if exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original completion request is closed';end if;
 if exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q) then
  raise exception using errcode='PT409',message='This action identity was already used for a child edit';end if;
 select * into initial from public.tasks where tasks.id=op.id;
 if not found or initial.task_generation is distinct from g or initial.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if octet_length(coalesce(initial.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for child editing';end if;
 decoded:=taskfold_private.decode_child_task_tree(initial.subtasks);
 if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 -- Auth recipients precede project/team/root locks, matching team RPCs. A new
 -- recipient appearing while waiting must force a fresh preparation.
 select array_agg(distinct recipient order by recipient) into recipients from (
  select initial.assigned_to recipient union select (n->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') n where coalesce(n->'fields'->>'assigned_to','')<>'') x where recipient is not null;
 perform 1 from auth.users where users.id=any(coalesce(recipients,'{}')) order by users.id for share;
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if team is not null then
  perform 1 from taskfold_private.teams where teams.id=team and state='active' for share;
  if not found or coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is paused';end if;
  perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 elsif taskfold_private.is_team_content_task(id) then raise exception using errcode='42501',message='This task is unavailable';
 elsif p is null then
  if initial.user_id<>a then raise exception using errcode='42501',message='This task is unavailable';end if;
 elsif not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if p is not null then
  perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73917));
 -- The existing team adapter takes this namespace before its root lock too.
 if team is not null then perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));end if;
 if team is not null and (exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q))
  and not exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q) then
  raise exception using errcode='PT409',message='This action identity was already used';end if;
 select * into t from public.tasks where tasks.id=op.id for update;
 if not found or t.task_generation is distinct from g or t.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if octet_length(coalesce(t.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for child editing';end if;
 perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This completion identity was already used';end if;
  return taskfold_private.child_task_completion_receipt(prior,true);
 end if;
 select * into projection from taskfold_private.child_task_projections where task_id=id;
 if not found or projection.state<>'ready' or projection.revision>=9007199254740991
  or projection.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb) or projection.task_generation is distinct from g then
  raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 select * into node from taskfold_private.child_task_records where task_id=id and node_key=key;
 if not found or node.incarnation<>inc or rev>node.revision or node.revision>=9007199254740991 then
  raise exception using errcode='PT409',message='This child changed or was recreated';end if;
 decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
 if decoded->>'state'<>'ready' or node.fields is distinct from (select n->'fields' from jsonb_array_elements(decoded->'nodes') n where n->>'key' collate "C"=key collate "C") then
  raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 select array_agg(distinct recipient order by recipient) into current_recipients from (
  select t.assigned_to recipient union select (n->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') n where coalesce(n->'fields'->>'assigned_to','')<>'') x where recipient is not null;
 if not coalesce(current_recipients,'{}')<@coalesce(recipients,'{}') then raise exception using errcode='PT409',message='Assignments changed; review this child completion';end if;
 current_state:=taskfold_private.child_task_completion_state(node.fields);
 if mode='undo' then
  select * into original from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=undo_id for update;
  if not found or original.action='undo' or original.reversed_by is not null or original.task_id<>id
   or original.generation is distinct from g or original.project_id is distinct from p
   or original.node_key<>key or original.incarnation<>inc or original.revision>rev or current_state<>original.after_state then
   raise exception using errcode='PT409',message='This completion can no longer be undone; review the current task';end if;
  baseline:=original.before_state;
 end if;
 if mode<>'undo' and current_state<>baseline then raise exception using errcode='PT409',message='This child completion changed';end if;
 foreach k in array array['completed','completed_at','is_heading','taskfold_completion_v1'] loop
  if coalesce((node.field_versions->>k)::bigint,1)>(case when mode='undo' then original.revision else rev end) then
   raise exception using errcode='PT409',message='This child completion changed; review it again';end if;
 end loop;
 if current_state ? 'taskfold_completion_v1' then
  version:=(current_state->'taskfold_completion_v1'->>'version')::bigint;
  epoch:=(current_state->'taskfold_completion_v1'->>'epoch')::uuid;
  if version>=9007199254740990 then raise exception using errcode='PT409',message='Review this completion revision';end if;
 else
  if mode='undo' or node.revision<>rev then raise exception using errcode='PT409',message='Review this legacy completion again';end if;
  epoch:=gen_random_uuid();version:=0;
 end if;
 if mode='undo' then
  own_fields:=(node.fields-array['completed','completed_at','taskfold_completion_v1'])||(baseline-'taskfold_completion_v1');
 else
  own_fields:=node.fields||jsonb_build_object('completed',mode='complete','completed_at',case when mode='complete' then to_jsonb(clock_timestamp()) else 'null'::jsonb end);
 end if;
 own_fields:=own_fields||jsonb_build_object('taskfold_completion_v1',jsonb_build_object('epoch',epoch,'version',version+1));
 after_state:=taskfold_private.child_task_completion_state(own_fields);
 desired:=taskfold_private.child_task_completion_tree(t.subtasks,key,own_fields);
 if (select count(*) from taskfold_private.child_task_completion_receipts where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then
  raise exception using errcode='PT429',message='Too many completion actions; try again later';end if;
 -- Only this private command can create a team write scope. It is admitted by
 -- the same live role/project/config checks and changes exactly one cohort.
 if team is not null then
  if not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=id and c.generation=g and c.team_id=team) then
   raise exception using errcode='PT409',message='This team task changed';end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
   values(txid_current(),team,p,id,g,a,'patch',q);
 end if;
 update public.tasks set subtasks=desired where tasks.id=op.id returning * into t;
 if team is not null then
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation)
   values(team,q,a,fingerprint,id,g,'child_completion');
 end if;
 select * into node from taskfold_private.child_task_records where task_id=id and node_key=key;
 if not found or node.incarnation<>inc or node.fields<>own_fields or t.subtasks<>desired then
  raise exception using errcode='PT409',message='This completion could not be confirmed';end if;
 perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 insert into taskfold_private.child_task_completion_receipts(actor_id,request_id,fingerprint,task_id,generation,project_id,node_key,incarnation,revision,action,undo_of,before_state,after_state)
 values(a,q,fingerprint,id,g,p,key,inc,node.revision,mode,undo_id,current_state,after_state) returning * into prior;
 if mode='undo' then update taskfold_private.child_task_completion_receipts set reversed_by=q where actor_id=a and request_id=undo_id;end if;
 return taskfold_private.child_task_completion_receipt(prior,false);
end$$;
