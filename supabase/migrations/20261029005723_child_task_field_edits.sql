-- Private field-change fences for independent edits. No ordinary exposure.
alter table taskfold_private.child_task_record_config add column edits_enabled boolean not null default false;
alter table taskfold_private.child_task_records add column field_versions jsonb not null default '{}' check(jsonb_typeof(field_versions)='object');
update taskfold_private.child_task_records r set field_versions=(select coalesce(jsonb_object_agg(k,r.revision),'{}') from jsonb_object_keys(r.fields) k);
create or replace function taskfold_private.sync_child_task_records(root_id uuid,generation uuid,tree jsonb) returns text
language plpgsql security invoker set search_path='' as $$
declare decoded jsonb;prior taskfold_private.child_task_projections%rowtype;entry jsonb;path text[];
begin
 tree:=coalesce(tree,'null'::jsonb);
 select * into prior from taskfold_private.child_task_projections where task_id=root_id for update;
 if found and (prior.task_generation is not distinct from generation) and prior.source_tree=tree then return prior.state;end if;
 decoded:=taskfold_private.decode_child_task_tree(tree);
 if prior.task_id is not null and (prior.task_generation is distinct from generation or prior.state='review' or decoded->>'state'='review') then
  delete from taskfold_private.child_task_records where task_id=root_id;
 end if;
 insert into taskfold_private.child_task_projections(task_id,task_generation,source_tree,state,issue,revision)
 values(root_id,generation,tree,decoded->>'state',decoded->>'issue',1)
 on conflict(task_id) do update set task_generation=excluded.task_generation,source_tree=excluded.source_tree,
  state=excluded.state,issue=excluded.issue,revision=taskfold_private.child_task_projections.revision+1;
 if decoded->>'state'='review' then return 'review';end if;
 delete from taskfold_private.child_task_records r where r.task_id=root_id and not exists(
  select 1 from jsonb_array_elements(decoded->'nodes') n where n->>'key' collate "C"=r.node_key);
 for entry in select * from jsonb_array_elements(decoded->'nodes') loop
  select array_agg(value order by ordinality) into path from jsonb_array_elements_text(entry->'path') with ordinality;
  insert into taskfold_private.child_task_records(task_id,node_key,parent_key,sibling_order,identity_path,fields,children_kind,field_versions)
  values(root_id,entry->>'key',entry->>'parent',(entry->>'position')::integer,path,entry->'fields',entry->>'children_kind',(select coalesce(jsonb_object_agg(k,1),'{}') from jsonb_object_keys(entry->'fields') k))
  on conflict(task_id,node_key) do update set parent_key=excluded.parent_key,sibling_order=excluded.sibling_order,
   identity_path=excluded.identity_path,fields=excluded.fields,children_kind=excluded.children_kind,
   field_versions=taskfold_private.child_task_records.field_versions ||
    (select coalesce(jsonb_object_agg(k,taskfold_private.child_task_records.revision+1),'{}')
      from jsonb_object_keys(taskfold_private.child_task_records.fields || excluded.fields) k
      where taskfold_private.child_task_records.fields->k is distinct from excluded.fields->k),
   revision=taskfold_private.child_task_records.revision+1
  where (taskfold_private.child_task_records.parent_key,taskfold_private.child_task_records.sibling_order,
   taskfold_private.child_task_records.identity_path,taskfold_private.child_task_records.fields,taskfold_private.child_task_records.children_kind)
   is distinct from (excluded.parent_key,excluded.sibling_order,excluded.identity_path,excluded.fields,excluded.children_kind);
 end loop;
 return 'ready';
end $$;

create or replace function taskfold_private.read_child_task_records(root_id uuid,expected_generation uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();s uuid;t public.tasks%rowtype;p taskfold_private.child_task_projections%rowtype;
 records jsonb;actual jsonb;expected jsonb;reply jsonb;decoded jsonb;allowed boolean;
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child records are not enabled';end if;
 if a is null or not taskfold_private.team_native_actor_live() then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 s:=(auth.jwt()->>'session_id')::uuid;
 -- Prevent deletion/revocation of this actor/session during the accepted read.
 perform 1 from auth.users where id=a for share;
 if not found then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 perform 1 from auth.sessions where id=s and user_id=a and (not_after is null or not_after>clock_timestamp()) for share;
 if not found then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 select * into t from public.tasks where id=root_id and task_generation is not distinct from expected_generation for share;
 if not found then raise exception using errcode='42501',message='This task is unavailable';end if;
 if taskfold_private.is_team_content_task(t.id) or taskfold_private.is_team_content_project(t.project_id) then
  allowed:=taskfold_private.team_native_task_read(t.id,t.project_id);
 else allowed:=case when t.project_id is null then t.user_id=a else public.has_project_access(a,t.project_id) end;end if;
 if not coalesce(allowed,false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 select * into p from taskfold_private.child_task_projections where task_id=t.id;
 if not found or p.state<>'ready' or p.task_generation is distinct from t.task_generation or p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb) then
  raise exception using errcode='PT409',message='Review this child hierarchy before opening separate records';end if;
 decoded:=taskfold_private.decode_child_task_tree(p.source_tree);
 if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy before opening separate records';end if;
 select coalesce(jsonb_agg(n order by n->>'key' collate "C"),'[]') into expected
  from jsonb_array_elements(decoded->'nodes') n;
 select coalesce(jsonb_agg(jsonb_build_object('key',r.node_key,'parent',r.parent_key,'position',r.sibling_order,'path',r.identity_path,
  'fields',r.fields,'children_kind',r.children_kind) order by r.node_key),'[]'),
  coalesce(jsonb_agg(to_jsonb(r)-'task_id'-'field_versions' order by r.identity_path collate "C"),'[]') into actual,records
  from taskfold_private.child_task_records r where r.task_id=t.id;
 if actual<>expected then raise exception using errcode='PT409',message='Review this child hierarchy before opening separate records';end if;
 reply:=jsonb_build_object('protocol',1,'account',a,'task_id',t.id,'project_id',t.project_id,'task_generation',t.task_generation,'projection_revision',p.revision,
  'root_kind',case when p.source_tree='null'::jsonb then 'null' else 'array' end,'records',records);
 if octet_length(reply::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large to open as separate records';end if;
 -- Recheck volatile account/project admission after assembling the bounded data.
 if not taskfold_private.team_native_actor_live() or not exists(select 1 from auth.sessions where id=s and user_id=a and (not_after is null or not_after>clock_timestamp())) then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 if taskfold_private.is_team_content_task(t.id) or taskfold_private.is_team_content_project(t.project_id) then
  allowed:=taskfold_private.team_native_task_read(t.id,t.project_id);
 else allowed:=case when t.project_id is null then t.user_id=a else public.has_project_access(a,t.project_id) end;end if;
 if not coalesce(allowed,false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return reply;
end $$;
create table taskfold_private.child_task_edit_receipts(
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 fingerprint text not null,task_id uuid not null,generation uuid,project_id uuid,
 node_key text collate "C" not null,incarnation uuid not null,revision bigint not null,
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id)
);
create index child_task_edit_receipts_task on taskfold_private.child_task_edit_receipts(task_id);
create index child_task_edit_receipts_actor_day on taskfold_private.child_task_edit_receipts(actor_id,created_at);
create table taskfold_private.child_task_edit_preparations(
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 transaction_id bigint not null,fingerprint text not null,task_id uuid not null,generation uuid,project_id uuid,
 node_key text collate "C" not null,incarnation uuid not null,after_hash text not null,
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id)
);
alter table taskfold_private.child_task_edit_receipts enable row level security;
alter table taskfold_private.child_task_edit_preparations enable row level security;
revoke all on taskfold_private.child_task_edit_receipts,taskfold_private.child_task_edit_preparations from public,anon,authenticated,service_role;

-- Exactly one identity-addressed leaf replacement, retaining all other JSON.
create function taskfold_private.child_task_field_tree(rows jsonb,target text,changes jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare result jsonb:='[]';row jsonb;begin
 for row in select * from jsonb_array_elements(rows) loop
  if normalize(row->>'id',NFC) collate "C"=target collate "C" then row:=row||changes;end if;
  if jsonb_typeof(row->'subtasks')='array' then row:=jsonb_set(row,'{subtasks}',taskfold_private.child_task_field_tree(row->'subtasks',target,changes));end if;
  result:=result||jsonb_build_array(row);
 end loop;return result;
end $$;
create function taskfold_private.child_task_edit_prepare(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
<<op>>
declare a uuid:=auth.uid();id uuid;q uuid;g uuid;p uuid;team uuid;initial public.tasks;t public.tasks;
 node taskfold_private.child_task_records;projection taskfold_private.child_task_projections;prior taskfold_private.child_task_edit_receipts;
 key text;inc uuid;rev bigint;changes jsonb;k text;fingerprint text;desired jsonb;decoded jsonb;recipients uuid[];current_recipients uuid[];
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child editing is not enabled';end if;
 perform taskfold_private.team_actor();
 -- Serialize this actor's bounded preparation/receipt budget before content
 -- locks. Other actors retain independent concurrency; all waits stay bounded.
 perform pg_advisory_xact_lock(hashtextextended(a::text,73918));
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','changes']
  or exists(select 1 from jsonb_object_keys(b) x where x not in('protocol','account','request_id','task_id','task_generation','project_id','node_key','incarnation','revision','changes')) then
  raise exception using errcode='22023',message='Review this saved child edit';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This child edit belongs to another account';end if;
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');inc:=taskfold_private.team_uuid(b,'incarnation');
 g:=case when b->'task_generation'='null' then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null' then null else taskfold_private.team_uuid(b,'project_id') end;
 if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')!~'^[0-9]{1,16}$' or (b->>'revision')::numeric not between 1 and 9007199254740991
  or jsonb_typeof(b->'node_key') is distinct from 'string' or octet_length(b->>'node_key') not between 1 and 128
  or b->>'node_key' collate "C"<>normalize(b->>'node_key',NFC) collate "C" then raise exception using errcode='22023',message='Review this child identity';end if;
 rev:=(b->>'revision')::bigint;key:=b->>'node_key';changes:=b->'changes';
 if jsonb_typeof(changes) is distinct from 'object' or changes='{}' or exists(select 1 from jsonb_object_keys(changes) x where x not in('title','description','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminder_specs')) then
  raise exception using errcode='22023',message='Use a separate reviewed action for this child field';end if;
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
  return jsonb_build_object('replayed',true,'receipt',jsonb_build_object('protocol',1,'account',a,'request_id',q,'task_id',id,'task_generation',g,'project_id',p,'node_key',prior.node_key,'incarnation',prior.incarnation,'revision',prior.revision,'replayed',true));
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
 for k in select jsonb_object_keys(changes) loop
  if coalesce((node.field_versions->>k)::bigint,1)>rev then raise exception using errcode='PT409',message='This child field changed; review your saved edit';end if;
 end loop;
 perform taskfold_private.automation_validate_fields(changes,node.fields);
 desired:=taskfold_private.child_task_field_tree(t.subtasks,key,changes);
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
create function taskfold_private.child_task_edit_finish(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare a uuid:=auth.uid();q uuid;scope taskfold_private.child_task_edit_preparations;t public.tasks;n taskfold_private.child_task_records;begin
 perform taskfold_private.team_actor();q:=taskfold_private.team_uuid(b,'request_id');
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
 return jsonb_build_object('protocol',1,'account',a,'request_id',q,'task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'node_key',n.node_key,'incarnation',n.incarnation,'revision',n.revision,'replayed',false);
end $$;
create function public.taskfold_edit_child_task(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare plan jsonb;begin
 plan:=taskfold_private.child_task_edit_prepare(_body);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if plan->'replayed'='true'::jsonb then return plan->'receipt';end if;
 if plan->'team_id'='null'::jsonb then
  perform public.taskfold_patch_task((_body->>'task_id')::uuid,plan->'base',plan->'changes');
 else perform public.taskfold_edit_team_task(plan->'team_command');end if;
 return taskfold_private.child_task_edit_finish(_body);
end $$;
revoke all on function taskfold_private.child_task_field_tree(jsonb,text,jsonb),taskfold_private.child_task_edit_prepare(jsonb),taskfold_private.child_task_edit_finish(jsonb),public.taskfold_edit_child_task(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_task_edit_prepare(jsonb),taskfold_private.child_task_edit_finish(jsonb),public.taskfold_edit_child_task(jsonb) to authenticated;
