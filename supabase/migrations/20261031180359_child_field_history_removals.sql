-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Exact optional-field removal for guarded field Undo/Redo. No gates are enabled.
-- Existing v1 payloads, nonce fences, authority and authorization are retained.
create function taskfold_private.child_field_removals(b jsonb) returns text[]
language plpgsql immutable security invoker set search_path='' as $$
declare removed text[]:='{}';begin
 if b->'protocol'='1'::jsonb then
  if b ? 'remove_fields' then raise exception using errcode='22023',message='Review this saved child edit';end if;
 elsif b->'protocol'='2'::jsonb then
  if jsonb_typeof(b->'remove_fields') is distinct from 'array' then raise exception using errcode='22023',message='Review removed child fields';end if;
  if jsonb_array_length(b->'remove_fields')>11 or exists(select 1 from jsonb_array_elements(b->'remove_fields') v where jsonb_typeof(v)<>'string') then raise exception using errcode='22023',message='Review removed child fields';end if;
  select coalesce(array_agg(value order by value collate "C"),'{}') into removed from jsonb_array_elements_text(b->'remove_fields');
  if cardinality(removed)<>(select count(distinct v) from unnest(removed) v)
   or exists(select 1 from unnest(removed) v where v not in('description','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminder_specs')) then raise exception using errcode='22023',message='Use a separate reviewed action for this child field';end if;
 else raise exception using errcode='22023',message='Review this saved child edit';end if;
 if jsonb_typeof(b->'changes') is distinct from 'object' or (b->'changes'='{}'::jsonb and cardinality(removed)=0)
  or exists(select 1 from jsonb_object_keys(b->'changes') k where k not in('title','description','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminder_specs') or k=any(removed)) then raise exception using errcode='22023',message='Review changed child fields';end if;
 return removed;
end$$;
create function taskfold_private.child_field_validation(b jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare removed text[];result jsonb:=b->'changes';k text;begin
 removed:=taskfold_private.child_field_removals(b);
 foreach k in array removed loop
  result:=result||jsonb_build_object(k,case when k='priority' then '4'::jsonb when k in('labels','reminder_specs') then '[]'::jsonb else 'null'::jsonb end);
 end loop;return result;
end$$;
create function taskfold_private.child_task_field_tree_v2(rows jsonb,target text,changes jsonb,removed text[]) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare result jsonb:='[]';row jsonb;begin
 for row in select * from jsonb_array_elements(rows) loop
  if normalize(row->>'id',NFC) collate "C"=target collate "C" then row:=(row||changes)-removed;end if;
  if jsonb_typeof(row->'subtasks')='array' then row:=jsonb_set(row,'{subtasks}',taskfold_private.child_task_field_tree_v2(row->'subtasks',target,changes,removed));end if;
  result:=result||jsonb_build_array(row);
 end loop;return result;
end$$;

create or replace function taskfold_private.child_task_edit_prepare(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
<<op>>
declare a uuid:=auth.uid();id uuid;q uuid;g uuid;p uuid;team uuid;initial public.tasks;t public.tasks;
 node taskfold_private.child_task_records;projection taskfold_private.child_task_projections;prior taskfold_private.child_task_edit_receipts;
 key text;inc uuid;rev bigint;changes jsonb;k text;removed text[];fingerprint text;desired jsonb;decoded jsonb;recipients uuid[];current_recipients uuid[];
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child editing is not enabled';end if;
 perform taskfold_private.team_actor();
 -- Serialize this actor's bounded preparation/receipt budget before content
 -- locks. Other actors retain independent concurrency; all waits stay bounded.
 perform pg_advisory_xact_lock(hashtextextended(a::text,73918));
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000 or (b->'protocol' is null or b->'protocol' not in('1'::jsonb,'2'::jsonb))
  or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','changes']
  or exists(select 1 from jsonb_object_keys(b) x where x not in('protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','changes','remove_fields')) then
  raise exception using errcode='22023',message='Review this saved child edit';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This child edit belongs to another account';end if;
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');inc:=taskfold_private.team_uuid(b,'incarnation');
 g:=case when b->'task_generation'='null' then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null' then null else taskfold_private.team_uuid(b,'project_id') end;
 if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')!~'^[0-9]{1,16}$' or (b->>'revision')::numeric not between 1 and 9007199254740991
  or jsonb_typeof(b->'node_key') is distinct from 'string' or octet_length(b->>'node_key') not between 1 and 128
  or b->>'node_key' collate "C"<>normalize(b->>'node_key',NFC) collate "C" then raise exception using errcode='22023',message='Review this child identity';end if;
 rev:=(b->>'revision')::bigint;key:=b->>'node_key';changes:=b->'changes';
 removed:=taskfold_private.child_field_removals(b);
 if exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original child request is closed';end if;
 select * into initial from public.tasks where tasks.id=op.id;
 if not found or initial.task_generation is distinct from g or initial.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if changes->'assigned_to' is not null and changes->'assigned_to'<>'null'::jsonb then
  perform taskfold_private.automation_validate_fields(jsonb_build_object('assigned_to',changes->'assigned_to'),null);end if;
 if octet_length(coalesce(initial.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for child editing';end if;
 decoded:=taskfold_private.decode_child_task_tree(initial.subtasks);
 if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 -- Auth recipients precede project/team/root locks, matching team RPCs. A new
 -- recipient appearing while waiting must force a fresh preparation.
 select array_agg(distinct recipient order by recipient) into recipients from (
  select initial.assigned_to recipient union select (changes->>'assigned_to')::uuid where changes->'assigned_to' is not null and changes->'assigned_to'<>'null'::jsonb union select (n->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') n where coalesce(n->'fields'->>'assigned_to','')<>'') x where recipient is not null;
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
 select * into t from public.tasks where tasks.id=op.id for update;
 if not found or t.task_generation is distinct from g or t.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if octet_length(coalesce(t.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for child editing';end if;
 perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This action identity was already used';end if;
  return jsonb_build_object('replayed',true,'receipt',jsonb_build_object('protocol',b->'protocol','account',a,'request_id',q,'task_id',id,'task_generation',g,'project_id',p,'node_key',prior.node_key,'incarnation',prior.incarnation,'revision',prior.revision,'replayed',true));
 end if;
 select * into projection from taskfold_private.child_task_projections where task_id=id;
 if not found or projection.state<>'ready' or projection.revision>=9007199254740991 or projection.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb) or projection.task_generation is distinct from g then
  raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 select * into node from taskfold_private.child_task_records where task_id=id and node_key=key;
 if not found or node.incarnation<>inc or rev>node.revision or node.revision>=9007199254740991 then raise exception using errcode='PT409',message='This child changed or was recreated';end if;
 decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
 if decoded->>'state'<>'ready' or node.fields is distinct from (select n->'fields' from jsonb_array_elements(decoded->'nodes') n where n->>'key' collate "C"=key collate "C") then
  raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 select array_agg(distinct recipient order by recipient) into current_recipients from (
  select t.assigned_to recipient union select (n->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') n where coalesce(n->'fields'->>'assigned_to','')<>'') x where recipient is not null;
 if not coalesce(current_recipients,'{}')<@coalesce(recipients,'{}') then raise exception using errcode='PT409',message='Assignments changed; review this child edit';end if;
 for k in select jsonb_object_keys(changes) union select unnest(removed) loop
  if coalesce((node.field_versions->>k)::bigint,1)>rev then raise exception using errcode='PT409',message='This child field changed; review your saved edit';end if;
 end loop;
 perform taskfold_private.automation_validate_fields(taskfold_private.child_field_validation(b),node.fields);
 desired:=case when b->'protocol'='2'::jsonb then taskfold_private.child_task_field_tree_v2(t.subtasks,key,changes,removed) else taskfold_private.child_task_field_tree(t.subtasks,key,changes) end;
 delete from taskfold_private.child_task_edit_preparations where actor_id=a and created_at<clock_timestamp()-interval '10 minutes';
 if (select count(*) from taskfold_private.child_task_edit_preparations where actor_id=a)>=64
  or (select count(*) from taskfold_private.child_task_edit_receipts where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then
  raise exception using errcode='54000',message='Too many child edits; try again later';end if;
 insert into taskfold_private.child_task_edit_preparations(actor_id,request_id,transaction_id,fingerprint,task_id,generation,project_id,node_key,incarnation,after_hash)
 values(a,q,txid_current(),fingerprint,id,g,p,key,inc,encode(extensions.digest(convert_to(desired::text,'UTF8'),'sha256'),'hex'))
 on conflict(actor_id,request_id) do update set transaction_id=excluded.transaction_id,fingerprint=excluded.fingerprint,task_id=excluded.task_id,generation=excluded.generation,project_id=excluded.project_id,node_key=excluded.node_key,incarnation=excluded.incarnation,after_hash=excluded.after_hash,created_at=excluded.created_at;
 return jsonb_build_object('replayed',false,'team_id',team,'base',to_jsonb(t),'changes',jsonb_build_object('subtasks',desired),
  'team_command',jsonb_build_object('team_id',team,'project_id',p,'task_id',id,'task_generation',g,'request_id',q,'base',to_jsonb(t),'changes',jsonb_build_object('subtasks',desired)));
end $$;
create or replace function taskfold_private.child_task_edit_finish(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare a uuid:=auth.uid();q uuid;scope taskfold_private.child_task_edit_preparations;t public.tasks;n taskfold_private.child_task_records;begin
 perform taskfold_private.team_actor();q:=taskfold_private.team_uuid(b,'request_id');
 if exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original child request is closed';end if;
 select * into scope from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q and transaction_id=txid_current() for update;
 if not found or scope.fingerprint<>encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This child edit was not prepared';end if;
 select * into t from public.tasks where id=scope.task_id for update;
 if not found or t.task_generation is distinct from scope.generation or t.project_id is distinct from scope.project_id
  or scope.after_hash<>encode(extensions.digest(convert_to(t.subtasks::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This child edit could not be confirmed';end if;
 select * into n from taskfold_private.child_task_records where task_id=t.id and node_key=scope.node_key;
 if not found or n.incarnation<>scope.incarnation then raise exception using errcode='PT409',message='This child edit could not be confirmed';end if;
 insert into taskfold_private.child_task_edit_receipts(actor_id,request_id,fingerprint,task_id,generation,project_id,node_key,incarnation,revision)
 values(a,q,scope.fingerprint,t.id,t.task_generation,t.project_id,n.node_key,n.incarnation,n.revision);
 delete from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q;
 return jsonb_build_object('protocol',b->'protocol','account',a,'request_id',q,'task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'node_key',n.node_key,'incarnation',n.incarnation,'revision',n.revision,'replayed',false);
end $$;
create or replace function taskfold_private.close_child_task_edit(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;fingerprint text;old taskfold_private.child_task_edit_closures;prior taskfold_private.child_task_edit_receipts;result jsonb;proof jsonb;
begin
 perform taskfold_private.team_actor();
 -- Same actor lock as preparation: either the edit commits first, or closure
 -- commits first and all later attempts are refused before touching task data.
 perform pg_advisory_xact_lock(hashtextextended(a::text,73918));
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000 or (b->'protocol' is null or b->'protocol' not in('1'::jsonb,'2'::jsonb))
  or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','changes']
  or exists(select 1 from jsonb_object_keys(b) x where x not in('protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','changes','remove_fields')) then
  raise exception using errcode='22023',message='Review this saved child edit';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This request belongs to another account';end if;
 q:=taskfold_private.team_uuid(b,'request_id');
 perform taskfold_private.team_uuid(b,'task_id');perform taskfold_private.team_uuid(b,'incarnation');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')!~'^[0-9]{1,16}$' or (b->>'revision')::numeric not between 1 and 9007199254740991
  or jsonb_typeof(b->'node_key') is distinct from 'string' or octet_length(b->>'node_key') not between 1 and 128
  or b->>'node_key' collate "C"<>normalize(b->>'node_key',NFC) collate "C"
 then
  raise exception using errcode='22023',message='Review this saved child edit';end if;
 perform taskfold_private.child_field_removals(b);
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 result:=(b-'changes'-'revision'-'remove_fields')||jsonb_build_object('outcome','closed','receipt',null);
 select * into prior from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This request identity was already used';end if;
  proof:=jsonb_build_object('protocol',b->'protocol','account',a,'request_id',q,'task_id',prior.task_id,'task_generation',prior.generation,'project_id',prior.project_id,'node_key',prior.node_key,'incarnation',prior.incarnation,'revision',prior.revision,'replayed',true);
  return result||jsonb_build_object('outcome','applied','receipt',proof);
 end if;
 select * into old from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q;
 if found then
  if old.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This request identity was already closed';end if;
  return result;
 end if;
 if (select count(*) from taskfold_private.child_task_edit_closures where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then
  raise exception using errcode='PT429',message='Try closing this original request later';end if;
 insert into taskfold_private.child_task_edit_closures(actor_id,request_id,fingerprint) values(a,q,fingerprint);
 return result;
end $$;
create or replace function taskfold_private.stage_prepared_child_records(b jsonb) returns void
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;scope taskfold_private.child_task_edit_preparations;t public.tasks;desired jsonb;
begin
 perform taskfold_private.team_actor();q:=taskfold_private.team_uuid(b,'request_id');
 select * into scope from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q and transaction_id=txid_current() for update;
 if not found or scope.fingerprint<>encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This child edit was not prepared';end if;
 select * into t from public.tasks where id=scope.task_id for update;
 if not found or t.task_generation is distinct from scope.generation or t.project_id is distinct from scope.project_id then raise exception using errcode='PT409',message='This task changed';end if;
 desired:=case when b->'protocol'='2'::jsonb then taskfold_private.child_task_field_tree_v2(t.subtasks,scope.node_key,b->'changes',taskfold_private.child_field_removals(b)) else taskfold_private.child_task_field_tree(t.subtasks,scope.node_key,b->'changes') end;
 if scope.after_hash<>encode(extensions.digest(convert_to(desired::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This prepared child edit changed';end if;
 perform taskfold_private.prepare_child_record_tree(t.id,t.task_generation,desired);
end$$;
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
 desired:=case when b->'protocol'='2'::jsonb then taskfold_private.child_task_field_tree_v2(t.subtasks,scope.node_key,b->'changes',taskfold_private.child_field_removals(b)) else taskfold_private.child_task_field_tree(t.subtasks,scope.node_key,b->'changes') end;
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
revoke all on function taskfold_private.child_field_removals(jsonb),taskfold_private.child_field_validation(jsonb),taskfold_private.child_task_field_tree_v2(jsonb,text,jsonb,text[]) from public,anon,authenticated,service_role;

commit;
