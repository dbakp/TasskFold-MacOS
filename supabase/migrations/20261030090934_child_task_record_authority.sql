-- Opt-in record authority. No roots are promoted and no app gates enabled here.
create table taskfold_private.child_task_record_authority (
 task_id uuid primary key references taskfold_private.child_task_projections(task_id) on delete cascade,
 task_generation uuid,project_id uuid,root_kind text not null check(root_kind in('null','array'))
);
alter table taskfold_private.child_task_record_authority enable row level security;
revoke all on taskfold_private.child_task_record_authority from public,anon,authenticated,service_role;

-- Rebuild from stored records alone. The legacy tree is never used as content.
create function taskfold_private.materialize_child_task_records(root_id uuid,kind text) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare r taskfold_private.child_task_records;c record;built jsonb:='{}';children jsonb;node jsonb;tree jsonb;decoded jsonb;actual jsonb;expected jsonb;total integer;
begin
 if kind is null or kind not in('null','array') then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 select count(*) into total from taskfold_private.child_task_records where task_id=root_id;
 if total>1000 or (kind='null' and total<>0) then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 for r in select * from taskfold_private.child_task_records where task_id=root_id order by cardinality(identity_path) desc,node_key loop
  children:='[]';
  for c in select node_key from taskfold_private.child_task_records where task_id=root_id and parent_key=r.node_key order by sibling_order,node_key loop
   if not built ? c.node_key then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
   children:=children||jsonb_build_array(built->c.node_key);
  end loop;
  node:=r.fields;
  if r.children_kind='array' then node:=node||jsonb_build_object('subtasks',children);
  elsif children<>'[]'::jsonb then raise exception using errcode='PT409',message='Review this child hierarchy';
  elsif r.children_kind='null' then node:=node||jsonb_build_object('subtasks',null);end if;
  built:=built||jsonb_build_object(r.node_key,node);
 end loop;
 select coalesce(jsonb_agg(built->node_key order by sibling_order,node_key),'[]') into tree from taskfold_private.child_task_records where task_id=root_id and parent_key is null;
 if kind='null' then tree:='null';end if;
 if octet_length(tree::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large';end if;
 decoded:=taskfold_private.decode_child_task_tree(tree);
 if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 select coalesce(jsonb_agg(n order by n->>'key' collate "C"),'[]') into expected from jsonb_array_elements(decoded->'nodes') n;
 select coalesce(jsonb_agg(jsonb_build_object('key',node_key,'parent',parent_key,'position',sibling_order,'path',identity_path,'fields',fields,'children_kind',children_kind) order by node_key),'[]') into actual from taskfold_private.child_task_records where task_id=root_id;
 if actual<>expected then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 return tree;
end$$;

create function taskfold_private.promote_child_task_records(root_id uuid,expected_generation uuid,expected_project uuid,expected_revision bigint,expected_tree jsonb) returns text
language plpgsql security invoker set search_path='' set lock_timeout='3s' as $$
declare t public.tasks;p taskfold_private.child_task_projections;kind text;actual jsonb;
begin
 select * into t from public.tasks where id=root_id for update;
 if not found then return 'missing';end if;
 select * into p from taskfold_private.child_task_projections where task_id=root_id for update;
 if not found or t.task_generation is distinct from expected_generation or t.project_id is distinct from expected_project
  or p.revision is distinct from expected_revision or coalesce(t.subtasks,'null'::jsonb) is distinct from coalesce(expected_tree,'null'::jsonb) then return 'stale';end if;
 if p.state<>'ready' or p.task_generation is distinct from t.task_generation or p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb) then return 'review';end if;
 kind:=case when t.subtasks is null or t.subtasks='null'::jsonb then 'null' else 'array' end;
 actual:=taskfold_private.materialize_child_task_records(root_id,kind);
 if actual is distinct from coalesce(expected_tree,'null'::jsonb) then return 'review';end if;
 insert into taskfold_private.child_task_record_authority(task_id,task_generation,project_id,root_kind) values(t.id,t.task_generation,t.project_id,kind)
 on conflict(task_id) do nothing;
 if not exists(select 1 from taskfold_private.child_task_record_authority a where a.task_id=t.id and a.task_generation is not distinct from t.task_generation and a.project_id is not distinct from t.project_id and a.root_kind=kind) then return 'review';end if;
 return 'records';
end$$;

alter function taskfold_private.sync_child_task_records(uuid,uuid,jsonb) rename to sync_child_task_records_legacy;
create function taskfold_private.sync_child_task_records(root_id uuid,generation uuid,tree jsonb) returns text
language plpgsql security invoker set search_path='' as $$
declare a taskfold_private.child_task_record_authority;t public.tasks;p taskfold_private.child_task_projections;
begin
 select * into a from taskfold_private.child_task_record_authority where task_id=root_id;
 if not found then return taskfold_private.sync_child_task_records_legacy(root_id,generation,tree);end if;
 select * into t from public.tasks where id=root_id;
 select * into p from taskfold_private.child_task_projections where task_id=root_id;
 if a.task_generation is distinct from generation or a.project_id is distinct from t.project_id or p.state<>'ready'
  or p.source_tree is distinct from coalesce(tree,'null'::jsonb)
  or taskfold_private.materialize_child_task_records(root_id,a.root_kind) is distinct from coalesce(tree,'null'::jsonb) then
  raise exception using errcode='PT409',message='Use separate subtask editing for this hierarchy';end if;
 return 'ready';
end$$;

-- Called only after existing typed-command admission and the root UPDATE lock.
-- Rows are written first; the compatibility mirror is reconstructed from them.
create function taskfold_private.prepare_child_record_tree(root_id uuid,generation uuid,desired jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare a taskfold_private.child_task_record_authority;t public.tasks;p taskfold_private.child_task_projections;actual jsonb;kind text;
begin
 select * into t from public.tasks where id=root_id and task_generation is not distinct from generation for update;
 if not found then raise exception using errcode='PT409',message='This task changed';end if;
 select * into a from taskfold_private.child_task_record_authority where task_id=root_id;
 if not found then return desired;end if;
 select * into p from taskfold_private.child_task_projections where task_id=root_id for update;
 if a.task_generation is distinct from generation or a.project_id is distinct from t.project_id or p.state<>'ready' or p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb)
  or taskfold_private.materialize_child_task_records(root_id,a.root_kind) is distinct from coalesce(t.subtasks,'null'::jsonb) then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 desired:=coalesce(desired,'null'::jsonb);kind:=case when desired='null'::jsonb then 'null' else 'array' end;
 if octet_length(desired::text)>2000000 or taskfold_private.decode_child_task_tree(desired)->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 update taskfold_private.child_task_record_authority set root_kind=kind where task_id=root_id;
 if taskfold_private.sync_child_task_records_legacy(root_id,generation,desired)<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 actual:=taskfold_private.materialize_child_task_records(root_id,kind);
 if actual is distinct from desired then raise exception using errcode='PT409',message='This subtask change could not be confirmed';end if;
 return actual;
end$$;

-- No prepared record write can commit without its matching root mirror. In
-- particular, calling preparation directly and omitting the public patch rolls
-- back at commit. Direct tables/helpers remain unavailable to client roles.
create function taskfold_private.check_child_record_mirror() returns trigger
language plpgsql security definer set search_path='' as $$
declare a taskfold_private.child_task_record_authority;t public.tasks;p taskfold_private.child_task_projections;root_id uuid:=new.task_id;
begin
 select * into a from taskfold_private.child_task_record_authority where task_id=root_id;
 if not found then return null;end if;
 select * into t from public.tasks where id=root_id;
 select * into p from taskfold_private.child_task_projections where task_id=root_id;
 if t.id is null or p.task_id is null or p.state<>'ready' or a.task_generation is distinct from t.task_generation or a.project_id is distinct from t.project_id
  or p.task_generation is distinct from t.task_generation or p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb)
  or taskfold_private.materialize_child_task_records(root_id,a.root_kind) is distinct from coalesce(t.subtasks,'null'::jsonb) then raise exception using errcode='PT409',message='This subtask change could not be committed';end if;
 return null;
end$$;
create constraint trigger taskfold_child_record_mirror after insert or update on taskfold_private.child_task_projections deferrable initially deferred for each row execute function taskfold_private.check_child_record_mirror();
create constraint trigger taskfold_child_record_promotion after insert or update on taskfold_private.child_task_record_authority deferrable initially deferred for each row execute function taskfold_private.check_child_record_mirror();
create function taskfold_private.guard_child_record_scope() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from taskfold_private.child_task_record_authority where task_id=old.id) and (new.task_generation is distinct from old.task_generation or new.project_id is distinct from old.project_id) then
  raise exception using errcode='PT409',message='This separate hierarchy needs a reviewed project transfer';end if;
 return new;
end$$;
create trigger taskfold_child_record_scope before update of task_generation,project_id on public.tasks for each row execute function taskfold_private.guard_child_record_scope();

create function taskfold_private.stage_prepared_child_records(b jsonb) returns void
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;scope taskfold_private.child_task_edit_preparations;t public.tasks;desired jsonb;
begin
 perform taskfold_private.team_actor();q:=taskfold_private.team_uuid(b,'request_id');
 select * into scope from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q and transaction_id=txid_current() for update;
 if not found or scope.fingerprint<>encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This child edit was not prepared';end if;
 select * into t from public.tasks where id=scope.task_id for update;
 if not found or t.task_generation is distinct from scope.generation or t.project_id is distinct from scope.project_id then raise exception using errcode='PT409',message='This task changed';end if;
 desired:=taskfold_private.child_task_field_tree(t.subtasks,scope.node_key,b->'changes');
 if scope.after_hash<>encode(extensions.digest(convert_to(desired::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This prepared child edit changed';end if;
 perform taskfold_private.prepare_child_record_tree(t.id,t.task_generation,desired);
end$$;
revoke all on function taskfold_private.materialize_child_task_records(uuid,text),taskfold_private.promote_child_task_records(uuid,uuid,uuid,bigint,jsonb),
 taskfold_private.sync_child_task_records_legacy(uuid,uuid,jsonb),taskfold_private.sync_child_task_records(uuid,uuid,jsonb),taskfold_private.prepare_child_record_tree(uuid,uuid,jsonb),
 taskfold_private.check_child_record_mirror(),taskfold_private.guard_child_record_scope(),taskfold_private.stage_prepared_child_records(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.stage_prepared_child_records(jsonb) to authenticated;

-- Existing admission, nonces, history, receipts and Undo remain intact.
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
 desired:=taskfold_private.prepare_child_record_tree(op.id,g,desired);
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

-- Existing admission, nonces, history, receipts and Undo remain intact.
create or replace function taskfold_private.edit_child_structure(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
<<op>>
declare a uuid:=auth.uid();id uuid;q uuid;g uuid;p uuid;team uuid;initial public.tasks;t public.tasks;
 projection taskfold_private.child_task_projections;n taskfold_private.child_task_records;destination taskfold_private.child_task_records;
 prior taskfold_private.child_task_structure_receipts;original taskfold_private.child_task_structure_receipts;
 key text;parent text;mode text;undo_id uuid;fingerprint text;rev bigint;slot integer;container_kind text;
 decoded jsonb;extra_decoded jsonb;extra_tree jsonb:='[]';subtree jsonb;desired jsonb;inverse jsonb:='{}';
 recipients uuid[];current_recipients uuid[];replaying boolean;archive_size bigint;archive_count bigint;
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child structure editing is not enabled';end if;
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_structure_request(b,a);
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');
 g:=case when b->'task_generation'='null'::jsonb then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null'::jsonb then null else taskfold_private.team_uuid(b,'project_id') end;
 mode:=b->>'action';rev:=(b->>'structure_revision')::bigint;key:=b->>'node_key';parent:=b->>'parent_key';slot:=(b->>'index')::integer;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original structure action is closed';end if;
 if exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q) then raise exception using errcode='PT409',message='This request identity belongs to another child action';end if;
 select * into prior from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q;
 replaying:=found;
 if replaying and prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This structure identity was already used';end if;
 if not replaying then
  if mode='insert' then
   extra_decoded:=taskfold_private.decode_child_task_tree(jsonb_build_array(b->'node'));
   if extra_decoded->>'state'<>'ready' then raise exception using errcode='22023',message='Review the new child hierarchy';end if;
   subtree:=taskfold_private.child_structure_fresh_node(b->'node',false);extra_tree:=jsonb_build_array(subtree);key:=normalize(subtree->>'id',NFC);
  elsif mode='undo' then
   undo_id:=taskfold_private.team_uuid(b,'undo_of');
   select * into original from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=undo_id;
   if not found or original.action='undo' or original.reversed_by is not null or original.task_id<>id or original.generation is distinct from g or original.project_id is distinct from p then raise exception using errcode='PT409',message='This structure action can no longer be undone';end if;
   key:=original.node_key;
   if original.action='delete' then
    select ar.subtree into subtree from taskfold_private.child_task_structure_archives ar where actor_id=a and request_id=undo_id and task_id=id;
    if not found then raise exception using errcode='PT409',message='The saved subtree is no longer available for Undo';end if;
    extra_tree:=jsonb_build_array(subtree);
   end if;
  end if;
 end if;
 select * into initial from public.tasks where tasks.id=op.id;
 if not found or initial.task_generation is distinct from g or initial.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if octet_length(coalesce(initial.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 decoded:=taskfold_private.decode_child_task_tree(initial.subtasks);extra_decoded:=taskfold_private.decode_child_task_tree(extra_tree);
 if decoded->>'state'<>'ready' or extra_decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 -- Lock all existing/new/restored recipients before team/project/root locks.
 select array_agg(distinct recipient order by recipient) into recipients from (
  select initial.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements((decoded->'nodes')||(extra_decoded->'nodes')) x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 perform 1 from auth.users where users.id=any(coalesce(recipients,'{}')) order by users.id for share;
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if team is not null then
  perform 1 from taskfold_private.teams where teams.id=team and state='active' for share;
  if not found or coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
  if not replaying and exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x where x->'fields'->'is_heading'='true'::jsonb) then
   perform 1 from taskfold_private.team_project_config where singleton and native_task_types_enabled for share;
   if not found then raise exception using errcode='PT503',message='Shared task types are not enabled';end if;
  end if;
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
 if team is not null then perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));end if;
 if (exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q)
  or (team is not null and (exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q) or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q)))) and not replaying then raise exception using errcode='PT409',message='This action identity was already used';end if;
 select * into t from public.tasks where tasks.id=op.id for update;
 if not found or t.task_generation is distinct from g or t.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 if replaying then return taskfold_private.child_structure_receipt(prior,true);end if;
 if octet_length(coalesce(t.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 -- Verify stored records against the actual tree, not just a saved source hash.
 perform taskfold_private.read_child_task_records(id,g);
 select * into projection from taskfold_private.child_task_projections where task_id=id;
 if projection.structure_revision<>rev or projection.structure_revision>=9007199254740991 or projection.revision>=9007199254740991 then raise exception using errcode='PT409',message='The hierarchy changed; review this structure action';end if;
 decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
 select array_agg(distinct recipient order by recipient) into current_recipients from (
  select t.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 if not coalesce(current_recipients,'{}')<@coalesce(recipients,'{}') then raise exception using errcode='PT409',message='Assignments changed; review this structure action';end if;
 if mode in('move','delete') or (mode='undo' and original.action in('move','insert')) then
  select * into n from taskfold_private.child_task_records where task_id=id and node_key=key;
  if not found or n.incarnation is distinct from (case when mode='undo' then original.incarnation else taskfold_private.team_uuid(b,'incarnation') end) then raise exception using errcode='PT409',message='This child changed or was recreated';end if;
  subtree:=taskfold_private.child_structure_extract(t.subtasks,key);
  if subtree is null then raise exception using errcode='PT409',message='This child is unavailable';end if;
 end if;
 if mode in('insert','move') then
  if parent is null then container_kind:=case when coalesce(t.subtasks,'null'::jsonb)='null'::jsonb then 'null' else 'array' end;
  else
   select * into destination from taskfold_private.child_task_records where task_id=id and node_key=parent;
   if not found then raise exception using errcode='PT409',message='The destination is unavailable';end if;
   container_kind:=destination.children_kind;
   if mode='move' and destination.identity_path[1:cardinality(n.identity_path)]=n.identity_path then raise exception using errcode='22023',message='A subtask cannot contain itself';end if;
  end if;
 end if;
 if mode='insert' then
  if exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x join taskfold_private.child_task_records r on r.task_id=id and r.node_key=x->>'key' collate "C") then raise exception using errcode='PT409',message='A new child identity is already in use';end if;
  desired:=taskfold_private.child_structure_insert(coalesce(t.subtasks,'null'::jsonb),parent,slot,subtree);
  inverse:=jsonb_build_object('parent_key',parent,'container_kind',container_kind);
 elsif mode='move' then
  desired:=taskfold_private.child_structure_insert(taskfold_private.child_structure_remove(t.subtasks,key),parent,slot,subtree);
  inverse:=jsonb_build_object('parent_key',n.parent_key,'index',n.sibling_order,'destination_parent',parent,'destination_kind',container_kind);
 elsif mode='delete' then
  if b->'subtree_versions' is distinct from taskfold_private.child_structure_versions(id,key) then raise exception using errcode='PT409',message='A subtask being removed changed; review it before deleting';end if;
  select count(*),coalesce(sum(octet_length(ar.subtree::text)),0) into archive_count,archive_size from taskfold_private.child_task_structure_archives ar where actor_id=a;
  if archive_count>=64 or archive_size+octet_length(subtree::text)>16777216 then raise exception using errcode='PT429',message='Review saved subtree Undo content before deleting more tasks';end if;
  desired:=taskfold_private.child_structure_remove(t.subtasks,key);inverse:=jsonb_build_object('parent_key',n.parent_key,'index',n.sibling_order);
 else
  if original.after_revision<>rev then raise exception using errcode='PT409',message='The hierarchy changed after this action; review it before Undo';end if;
  if original.action='insert' then
   if taskfold_private.child_structure_digest(id,key) is distinct from original.inverse->>'subtree_digest' then raise exception using errcode='PT409',message='The inserted subtree changed; keep its new work and review it before deleting';end if;
   desired:=taskfold_private.child_structure_remove(t.subtasks,key);
   desired:=taskfold_private.child_structure_restore_container(desired,original.inverse->>'parent_key',original.inverse->>'container_kind');
  elsif original.action='move' then
   desired:=taskfold_private.child_structure_insert(taskfold_private.child_structure_remove(t.subtasks,key),original.inverse->>'parent_key',(original.inverse->>'index')::integer,subtree);
   desired:=taskfold_private.child_structure_restore_container(desired,original.inverse->>'destination_parent',original.inverse->>'destination_kind');
  else
   -- A fresh completion epoch fences supported legacy tokened requests too.
   subtree:=taskfold_private.child_structure_fresh_node(subtree,true);
   if exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x join taskfold_private.child_task_records r on r.task_id=id and r.node_key=x->>'key' collate "C") then raise exception using errcode='PT409',message='A restored child identity is already in use';end if;
   desired:=taskfold_private.child_structure_insert(coalesce(t.subtasks,'null'::jsonb),original.inverse->>'parent_key',(original.inverse->>'index')::integer,subtree);
  end if;
 end if;
 if desired is not distinct from coalesce(t.subtasks,'null'::jsonb) then raise exception using errcode='22023',message='Choose a different child slot';end if;
 if octet_length(desired::text)>2000000 or taskfold_private.decode_child_task_tree(desired)->>'state'<>'ready' then raise exception using errcode='54000',message='The resulting hierarchy needs review or exceeds its limits';end if;
 if (select count(*) from taskfold_private.child_task_structure_receipts where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many structure actions; try again later';end if;
 if team is not null then
  if not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=id and c.generation=g and c.team_id=team) then raise exception using errcode='PT409',message='This team task changed';end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,p,id,g,a,'patch',q);
 end if;
 desired:=taskfold_private.prepare_child_record_tree(op.id,g,desired);
 update public.tasks set subtasks=case when desired='null'::jsonb then null else desired end where tasks.id=op.id returning * into t;
 if team is not null then
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,g,'child_structure');
 end if;
 if coalesce(t.subtasks,'null'::jsonb)<>desired or not exists(select 1 from taskfold_private.child_task_projections where task_id=id and structure_revision=rev+1 and source_tree=desired) then raise exception using errcode='PT409',message='This structure action could not be confirmed';end if;
 perform taskfold_private.read_child_task_records(id,g);perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 select * into n from taskfold_private.child_task_records where task_id=id and node_key=key;
 if mode='insert' then inverse:=inverse||jsonb_build_object('subtree_digest',taskfold_private.child_structure_digest(id,key));end if;
 insert into taskfold_private.child_task_structure_receipts(actor_id,request_id,fingerprint,task_id,generation,project_id,action,undo_of,before_revision,after_revision,node_key,incarnation,inverse)
 values(a,q,fingerprint,id,g,p,mode,undo_id,rev,rev+1,key,n.incarnation,inverse) returning * into prior;
 if mode='delete' then insert into taskfold_private.child_task_structure_archives(actor_id,request_id,task_id,subtree) values(a,q,id,subtree);end if;
 if mode='undo' then
  update taskfold_private.child_task_structure_receipts set reversed_by=q where actor_id=a and request_id=undo_id;
  delete from taskfold_private.child_task_structure_archives where actor_id=a and request_id=undo_id;
 end if;
 return taskfold_private.child_structure_receipt(prior,false);
end$$;

-- Existing admission, nonces, history, receipts and Undo remain intact.
create or replace function taskfold_private.apply_prepared_team_child_field(b jsonb) returns void
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;scope taskfold_private.child_task_edit_preparations;t public.tasks;team uuid;desired jsonb;fingerprint text;begin
 perform taskfold_private.team_actor();q:=taskfold_private.team_uuid(b,'request_id');
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into scope from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q and transaction_id=txid_current() for update;
 if not found or scope.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This child edit was not prepared';end if;
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child editing is not enabled';end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=scope.project_id;
 if team is null then raise exception using errcode='42501',message='This prepared team task is unavailable';end if;
 perform 1 from taskfold_private.teams where id=team and state='active' for share;
 if not found or coalesce(taskfold_private.team_project_role(a,scope.project_id),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team editing is paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
 perform 1 from public.projects where id=scope.project_id and not is_archived and not ancestor_archived for share;
 if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 if exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original child request is closed';end if;
 if exists(select 1 from taskfold_private.team_task_edits where (actor_id=a or team_id=team) and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where (actor_id=a or team_id=team) and request_id=q) then raise exception using errcode='PT409',message='This request identity belongs to another task action';end if;
 select * into t from public.tasks where id=scope.task_id for update;
 if not found or t.task_generation is distinct from scope.generation or t.project_id is distinct from scope.project_id
  or not exists(select 1 from taskfold_private.team_content_tasks where task_id=t.id and generation=t.task_generation and team_id=team) then raise exception using errcode='PT409',message='This team task changed';end if;
 perform taskfold_private.read_child_task_records(t.id,t.task_generation);
 desired:=taskfold_private.child_task_field_tree(t.subtasks,scope.node_key,b->'changes');
 if scope.after_hash<>encode(extensions.digest(convert_to(desired::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This prepared child edit changed';end if;
 insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
 values(txid_current(),team,t.project_id,t.id,t.task_generation,a,'patch',q);
 desired:=taskfold_private.prepare_child_record_tree(t.id,t.task_generation,desired);
 update public.tasks set subtasks=desired where id=t.id returning * into t;
 delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=t.id;
 if t.subtasks is distinct from desired then raise exception using errcode='PT409',message='This child edit could not be confirmed';end if;
 perform taskfold_private.read_child_task_records(t.id,t.task_generation);perform taskfold_private.team_actor();
 if coalesce(taskfold_private.team_project_role(a,t.project_id),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation)
 values(team,q,a,fingerprint,t.id,t.task_generation,'child_field');
end$$;

create or replace function public.taskfold_edit_child_task(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare plan jsonb;receipt jsonb;begin
 plan:=taskfold_private.child_task_edit_prepare(_body);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if plan->'replayed'='true'::jsonb then return plan->'receipt';end if;
 if plan->'team_id'='null'::jsonb then perform taskfold_private.stage_prepared_child_records(_body); perform public.taskfold_patch_task((_body->>'task_id')::uuid,plan->'base',plan->'changes');
 else perform taskfold_private.apply_prepared_team_child_field(_body);end if;
 receipt:=taskfold_private.child_task_edit_finish(_body);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return receipt;
end$$;
