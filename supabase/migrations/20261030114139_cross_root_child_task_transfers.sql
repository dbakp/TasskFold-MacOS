-- Opt-in cross-root transfer candidate. No hosted migration or normal-use rollout.
alter table taskfold_private.child_task_record_config add column transfers_enabled boolean not null default false;
create table taskfold_private.child_task_transfers (
 actor_id uuid not null references auth.users(id) on delete cascade, request_id uuid not null,
 fingerprint text not null check(length(fingerprint)=64), state text not null check(state in('applied','closed')),
 source_id uuid not null,destination_id uuid not null,team_id uuid,
 source_generation uuid,destination_generation uuid,source_project uuid,destination_project uuid,
 action text not null check(action in('transfer','undo')),undo_of uuid,reversed_by uuid,
 source_revision bigint not null,destination_revision bigint not null,
 node_key text collate "C" not null,incarnation uuid not null,moved_count integer not null default 0,
 inverse jsonb not null default '{}',created_at timestamptz not null default clock_timestamp(),
 primary key(actor_id,request_id),check(source_id<>destination_id),check(jsonb_typeof(inverse)='object')
);
create index child_transfers_actor_day on taskfold_private.child_task_transfers(actor_id,created_at);
create unique index child_transfers_team_nonce on taskfold_private.child_task_transfers(team_id,request_id) where team_id is not null;
alter table taskfold_private.child_task_transfers enable row level security;
revoke all on taskfold_private.child_task_transfers from public,anon,authenticated,service_role;

-- Transaction-only history lineage. No title, note or subtree in durable receipts.
create table taskfold_private.child_transfer_history_scope (
 transaction_id bigint not null,actor_id uuid not null,request_id uuid not null,
 source_id uuid not null,destination_id uuid not null,source_generation uuid not null,destination_generation uuid not null,source_project uuid,destination_project uuid,
 node_key text collate "C" not null,raw_key text not null,incarnation uuid not null,
 primary key(transaction_id,source_id,node_key)
);
alter table taskfold_private.child_transfer_history_scope enable row level security;
revoke all on taskfold_private.child_transfer_history_scope from public,anon,authenticated,service_role;
alter table public.task_node_activity add column transfer_context jsonb check(transfer_context is null or jsonb_typeof(transfer_context)='object');
create function taskfold_private.tag_child_transfer_history() returns trigger
language plpgsql security definer set search_path='' as $$
declare s taskfold_private.child_transfer_history_scope;begin
 -- Only server-captured events in this exact authenticated transfer transaction.
 new.transfer_context:=null;
 select * into s from taskfold_private.child_transfer_history_scope h where h.transaction_id=txid_current() and h.actor_id=auth.uid()
  and h.raw_key collate "C"=new.node_key collate "C" and h.actor_id=new.actor_id
  and ((new.task_id=h.source_id and new.task_generation=h.source_generation and new.kinds=array['deleted'])
   or (new.task_id=h.destination_id and new.task_generation=h.destination_generation and new.kinds=array['created']));
 if found then new.transfer_context:=jsonb_build_object('version',1,'request_id',s.request_id,'incarnation',s.incarnation,
  'source',jsonb_build_object('task_id',s.source_id,'task_generation',s.source_generation,'project_id',s.source_project,'node_key',s.raw_key),
  'destination',jsonb_build_object('task_id',s.destination_id,'task_generation',s.destination_generation,'project_id',s.destination_project,'node_key',s.raw_key));end if;
 return new;
end$$;
create trigger task_node_activity_transfer_context before insert on public.task_node_activity for each row execute function taskfold_private.tag_child_transfer_history();

create function taskfold_private.child_transfer_reply(r taskfold_private.child_task_transfers,replayed boolean) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'request_id',r.request_id,'state',r.state,'replayed',replayed,
 'source_id',r.source_id,'destination_id',r.destination_id,'source_generation',r.source_generation,'destination_generation',r.destination_generation,
 'source_project',r.source_project,'destination_project',r.destination_project,'action',r.action,'undo_of',r.undo_of,
 'source_revision',r.source_revision,'destination_revision',r.destination_revision,'node_key',r.node_key,'incarnation',r.incarnation,'moved_count',r.moved_count,'return_parent',r.inverse->'parent_key','return_index',r.inverse->'index')
$$;

-- Symmetric nonce fencing includes pre-existing field/completion/team protocols.
create function taskfold_private.guard_child_transfer_nonce() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 if exists(select 1 from taskfold_private.child_task_transfers r where (r.actor_id=new.actor_id or r.team_id=nullif(to_jsonb(new)->>'team_id','')::uuid) and r.request_id=new.request_id) then raise exception using errcode='PT409',message='This identity belongs to a subtask transfer';end if;
 return new;
end$$;
create trigger child_transfer_nonce before insert or update on taskfold_private.child_task_edit_preparations for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.child_task_edit_receipts for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.child_task_edit_closures for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.child_task_completion_receipts for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.child_task_completion_closures for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.child_task_structure_receipts for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.child_task_structure_closures for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.team_task_edits for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.personal_task_moves for each row execute function taskfold_private.guard_child_transfer_nonce();
create trigger child_transfer_nonce before insert or update on taskfold_private.team_task_batches for each row execute function taskfold_private.guard_child_transfer_nonce();

create function taskfold_private.transfer_child(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
<<op>>
declare a uuid:=auth.uid();q uuid;sid uuid;did uuid;sg uuid;dg uuid;sp uuid;dp uuid;st uuid;dt uuid;fingerprint text;
 s public.tasks;d public.tasks;t public.tasks;prior taskfold_private.child_task_transfers;original taskfold_private.child_task_transfers;
 n taskfold_private.child_task_records;dest taskfold_private.child_task_records;
 sr bigint;dr bigint;key text;parent text;slot integer;mode text;undo_id uuid;kind text;
 subtree jsonb;sdesired jsonb;ddesired jsonb;saved jsonb;inverse jsonb;entry jsonb;assignments jsonb:='{}';
 recipients uuid[];current_recipients uuid[];pid uuid;team uuid;count_moved integer;newrev bigint;
begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 if operation is null or operation not in('send','check','close') or jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>384000
  or b->'protocol' is distinct from '1'::jsonb or not b ?& array['account','request_id','source','destination','node_key','incarnation','subtree_versions','action']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','request_id','source','destination','node_key','incarnation','subtree_versions','action','undo_of')) then raise exception using errcode='22023',message='Review this saved subtask transfer';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This transfer belongs to another account';end if;
 q:=taskfold_private.team_uuid(b,'request_id');mode:=b->>'action';
 if mode is null or mode not in('transfer','undo') or (mode='undo')<>(b ? 'undo_of') then raise exception using errcode='22023',message='Review the transfer action';end if;
 if mode='undo' then undo_id:=taskfold_private.team_uuid(b,'undo_of');end if;
 foreach entry in array array[b->'source',b->'destination'] loop
  if jsonb_typeof(entry) is distinct from 'object' or not entry ?& array['task_id','task_generation','project_id','structure_revision']
   or exists(select 1 from jsonb_object_keys(entry) k where k not in('task_id','task_generation','project_id','structure_revision','parent_key','parent_incarnation','index')) then raise exception using errcode='22023',message='Review both transfer tasks';end if;
  perform taskfold_private.team_uuid(entry,'task_id');
  if entry->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(entry,'task_generation');end if;
  if entry->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(entry,'project_id');end if;
  if jsonb_typeof(entry->'structure_revision') is distinct from 'number' or (entry->>'structure_revision')!~'^[0-9]{1,16}$'
   or (entry->>'structure_revision')::numeric not between 1 and 9007199254740990 then raise exception using errcode='22023',message='Review both hierarchy revisions';end if;
 end loop;
 if (b->'source') ?| array['parent_key','parent_incarnation','index'] or not (b->'destination') ?& array['parent_key','parent_incarnation','index'] then raise exception using errcode='22023',message='Review the destination slot';end if;
 sid:=taskfold_private.team_uuid(b->'source','task_id');did:=taskfold_private.team_uuid(b->'destination','task_id');
 sg:=(b->'source'->>'task_generation')::uuid;dg:=(b->'destination'->>'task_generation')::uuid;
 sp:=(b->'source'->>'project_id')::uuid;dp:=(b->'destination'->>'project_id')::uuid;
 sr:=(b->'source'->>'structure_revision')::bigint;dr:=(b->'destination'->>'structure_revision')::bigint;
 key:=b->>'node_key';parent:=b->'destination'->>'parent_key';
 if sid=did or jsonb_typeof(b->'node_key') is distinct from 'string' or octet_length(key) not between 1 and 128 or key collate "C"<>normalize(key,NFC) collate "C"
  or (parent is not null and (jsonb_typeof(b->'destination'->'parent_key')<>'string' or octet_length(parent) not between 1 and 128 or parent collate "C"<>normalize(parent,NFC) collate "C"))
  or (parent is null)<>(b->'destination'->'parent_incarnation'='null'::jsonb)
  or jsonb_typeof(b->'destination'->'index') is distinct from 'number' or (b->'destination'->>'index')!~'^[0-9]{1,4}$' or (b->'destination'->>'index')::int>1000
  or jsonb_typeof(b->'subtree_versions') is distinct from 'object' or b->'subtree_versions'='{}'::jsonb then raise exception using errcode='22023',message='Review the subtask and destination';end if;
 perform taskfold_private.team_uuid(b,'incarnation');if parent is not null then perform taskfold_private.team_uuid(b->'destination','parent_incarnation');end if;
 slot:=(b->'destination'->>'index')::int;fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 select * into prior from taskfold_private.child_task_transfers where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This transfer identity was already used';end if;
  return taskfold_private.child_transfer_reply(prior,true);
 end if;
 if exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.personal_task_moves where actor_id=a and request_id=q) then raise exception using errcode='PT409',message='This identity belongs to another action';end if;
 if operation='check' then return jsonb_build_object('protocol',1,'account',a,'request_id',q,'state','unknown');end if;
 if (select count(*) from taskfold_private.child_task_transfers where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many transfer decisions; try later';end if;
 if operation='close' then
  insert into taskfold_private.child_task_transfers(actor_id,request_id,fingerprint,state,source_id,destination_id,source_generation,destination_generation,source_project,destination_project,action,undo_of,source_revision,destination_revision,node_key,incarnation)
   values(a,q,fingerprint,'closed',sid,did,sg,dg,sp,dp,mode,undo_id,sr,dr,key,(b->>'incarnation')::uuid) returning * into prior;
  return taskfold_private.child_transfer_reply(prior,false);
 end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled and transfers_enabled for share;
 if not found then raise exception using errcode='PT503',message='Subtask transfers are not enabled';end if;
 select * into s from public.tasks where id=sid;select * into d from public.tasks where id=did;
 if s.id is null or d.id is null then raise exception using errcode='42501',message='Both tasks must be available';end if;
 if mode='undo' then select * into original from taskfold_private.child_task_transfers where actor_id=a and request_id=undo_id;end if;
 select array_agg(distinct u order by u) into recipients from (
  select a u union select s.user_id union select d.user_id union select s.assigned_to union select d.assigned_to union select (v->>'value')::uuid from jsonb_each(coalesce(original.inverse->'assignments','{}')) e(k,v) where coalesce(v->>'value','')<>'' union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements((taskfold_private.decode_child_task_tree(s.subtasks)->'nodes')||(taskfold_private.decode_child_task_tree(d.subtasks)->'nodes')) x where coalesce(x->'fields'->>'assigned_to','')<>'') v where u is not null;
 perform 1 from auth.users where id=any(coalesce(recipients,'{}')) order by id for share;
 select team_id into st from taskfold_private.team_content_projects where project_id=sp;select team_id into dt from taskfold_private.team_content_projects where project_id=dp;
 if st is distinct from dt then raise exception using errcode='PT409',message='Review a separate workspace transfer before moving this subtask';end if;
 team:=st;
 if team is not null then
  perform 1 from taskfold_private.teams where id=team and state='active' for share;
  if not found then raise exception using errcode='42501',message='This workspace is unavailable';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled and native_task_types_enabled for share;
  if not found then raise exception using errcode='PT503',message='Shared editing is not enabled';end if;
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Shared editing is paused';end if;
  if not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) then raise exception using errcode='55P03',message='Another workspace action is finishing';end if;
  if exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q) or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q)
   or exists(select 1 from taskfold_private.child_task_transfers where team_id=team and request_id=q) then raise exception using errcode='PT409',message='This workspace identity was already used';end if;
 end if;
 for pid in select distinct x from unnest(array[sp,dp]) x where x is not null order by x loop
  perform 1 from public.projects where id=pid and not is_archived and not ancestor_archived for share nowait;
  if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
  if team is not null then
   perform 1 from taskfold_private.team_content_projects where project_id=pid and team_id=team for share nowait;
   if not found or coalesce(taskfold_private.team_project_role(a,pid),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing both tasks is required';end if;
  elsif not coalesce(public.has_project_access(a,pid),false) then raise exception using errcode='42501',message='Editing both tasks is required';end if;
 end loop;
 -- Sorted, nonblocking roots avoid opposite-direction lock inversion with old writers.
 perform 1 from public.tasks where id=any(array[sid,did]) order by id for update nowait;
 select * into s from public.tasks where id=sid;select * into d from public.tasks where id=did;
 perform taskfold_private.team_actor();
 if s.task_generation is distinct from sg or d.task_generation is distinct from dg or s.project_id is distinct from sp or d.project_id is distinct from dp then raise exception using errcode='PT409',message='A task moved or was recreated';end if;
 if team is null then
  if taskfold_private.is_team_content_task(sid) or taskfold_private.is_team_content_task(did)
   or (sp is null and s.user_id<>a) or (dp is null and d.user_id<>a) then raise exception using errcode='42501',message='Both tasks must be available';end if;
 else
  if not exists(select 1 from taskfold_private.team_content_tasks where task_id=sid and generation=sg and team_id=team)
   or not exists(select 1 from taskfold_private.team_content_tasks where task_id=did and generation=dg and team_id=team) then raise exception using errcode='PT409',message='A shared task changed';end if;
 end if;
 if team is not null and (coalesce(taskfold_private.team_project_role(a,sp),'') not in('manager','editor') or coalesce(taskfold_private.team_project_role(a,dp),'') not in('manager','editor')) then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and ((sp is not null and not coalesce(public.has_project_access(a,sp),false)) or (dp is not null and not coalesce(public.has_project_access(a,dp),false))) then raise exception using errcode='42501',message='Editing access changed';end if;
 perform taskfold_private.read_child_task_records(sid,sg);perform taskfold_private.read_child_task_records(did,dg);
 if not exists(select 1 from taskfold_private.child_task_projections where task_id=sid and structure_revision=sr and revision<9007199254740991)
  or not exists(select 1 from taskfold_private.child_task_projections where task_id=did and structure_revision=dr and revision<9007199254740991) then raise exception using errcode='PT409',message='A hierarchy changed; review this move';end if;
 select array_agg(distinct u order by u) into current_recipients from (
  select a u union select s.user_id union select d.user_id union select s.assigned_to union select d.assigned_to union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements((taskfold_private.decode_child_task_tree(s.subtasks)->'nodes')||(taskfold_private.decode_child_task_tree(d.subtasks)->'nodes')) x where coalesce(x->'fields'->>'assigned_to','')<>'') v where u is not null;
 if not coalesce(current_recipients,'{}')<@coalesce(recipients,'{}') then raise exception using errcode='PT409',message='Assignments changed; review this move';end if;
 select * into n from taskfold_private.child_task_records where task_id=sid and node_key=key;
 if not found or n.incarnation<>(b->>'incarnation')::uuid or b->'subtree_versions' is distinct from taskfold_private.child_structure_versions(sid,key) then raise exception using errcode='PT409',message='The moved branch changed; review its latest work';end if;
 if parent is null then kind:=case when coalesce(d.subtasks,'null'::jsonb)='null'::jsonb then 'null' else 'array' end;
 else
  select * into dest from taskfold_private.child_task_records where task_id=did and node_key=parent;
  if not found or dest.incarnation<>(b->'destination'->>'parent_incarnation')::uuid then raise exception using errcode='PT409',message='The destination changed';end if;
  kind:=dest.children_kind;
 end if;
 select jsonb_agg(to_jsonb(r) order by r.node_key),count(*) into saved,count_moved from taskfold_private.child_task_records r where r.task_id=sid and r.identity_path[1:cardinality(n.identity_path)]=n.identity_path;
 if exists(select 1 from jsonb_array_elements(saved) x join taskfold_private.child_task_records r on r.task_id=did and r.node_key=x->>'node_key' collate "C") then raise exception using errcode='PT409',message='A child identity already exists at the destination';end if;
 subtree:=taskfold_private.child_structure_extract(s.subtasks,key);
 inverse:=jsonb_build_object('parent_key',n.parent_key,'index',n.sibling_order,'destination_parent',parent,'destination_kind',kind);
 if mode='undo' then
  select * into original from taskfold_private.child_task_transfers where actor_id=a and request_id=undo_id for update;
  if not found or original.state<>'applied' or original.action<>'transfer' or original.reversed_by is not null
   or original.source_id<>did or original.destination_id<>sid or original.source_generation is distinct from dg or original.destination_generation is distinct from sg
   or original.source_project is distinct from dp or original.destination_project is distinct from sp or original.node_key<>key or original.incarnation<>n.incarnation
   or original.source_revision+1<>dr or original.destination_revision+1<>sr
   or original.inverse->>'digest' is distinct from taskfold_private.child_structure_digest(sid,key)
   or original.inverse->>'parent_key' is distinct from parent or (original.inverse->>'index')::int<>slot then raise exception using errcode='PT409',message='This move can no longer be undone; review the current work';end if;
 end if;
 -- Preserve exact assignment shape within a project; cross-project assignment
 -- clearing follows whole-task moves, and Undo revalidates restored recipients.
 for entry in select * from jsonb_array_elements(saved) loop
  assignments:=assignments||jsonb_build_object(entry->>'node_key',jsonb_build_object('present',(entry->'fields')?'assigned_to','value',entry->'fields'->'assigned_to'));
 end loop;
 inverse:=inverse||jsonb_build_object('assignments',assignments);
 if sp is distinct from dp then
  if mode='transfer' then subtree:=(taskfold_private.child_record_move_clear(jsonb_build_array(subtree)))->0;
  else
   for entry in select * from jsonb_array_elements(saved) loop
    assignments:=original.inverse->'assignments'->(entry->>'node_key');
    subtree:=taskfold_private.child_transfer_assign(subtree,entry->>'node_key',(assignments->>'present')::boolean,assignments->'value');
   end loop;
  end if;
 end if;
 sdesired:=taskfold_private.child_structure_remove(s.subtasks,key);
 if mode='undo' then sdesired:=taskfold_private.child_structure_restore_container(sdesired,original.inverse->>'destination_parent',original.inverse->>'destination_kind');end if;
 ddesired:=taskfold_private.child_structure_insert(coalesce(d.subtasks,'null'::jsonb),parent,slot,subtree);
 if taskfold_private.decode_child_task_tree(sdesired)->>'state'<>'ready' or taskfold_private.decode_child_task_tree(ddesired)->>'state'<>'ready'
  or octet_length(sdesired::text)>2000000 or octet_length(ddesired::text)>2000000 then raise exception using errcode='54000',message='The resulting hierarchy exceeds supported limits';end if;
 insert into taskfold_private.child_transfer_history_scope(transaction_id,actor_id,request_id,source_id,destination_id,source_generation,destination_generation,source_project,destination_project,node_key,raw_key,incarnation)
  select txid_current(),a,q,sid,did,coalesce(sg,'00000000-0000-0000-0000-000000000000'),coalesce(dg,'00000000-0000-0000-0000-000000000000'),sp,dp,x->>'node_key',x->'fields'->>'id',(x->>'incarnation')::uuid from jsonb_array_elements(saved) x;
 if team is not null then
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
   values(txid_current(),team,sp,sid,sg,a,'patch',q),(txid_current(),team,dp,did,dg,a,'patch',q);
 end if;
 sdesired:=taskfold_private.prepare_child_record_tree(sid,sg,sdesired);
 update public.tasks set subtasks=case when sdesired='null'::jsonb then null else sdesired end where id=sid;
 ddesired:=taskfold_private.prepare_child_record_tree(did,dg,ddesired);
 update public.tasks set subtasks=ddesired where id=did;
 -- Keep stable incarnation/completion epochs. Fence every previously authored
 -- field, including absent editable keys, when the root binding changes (ABA).
 for entry in select * from jsonb_array_elements(saved) loop
  newrev:=(entry->>'revision')::bigint+1;
  if newrev>=9007199254740991 then raise exception using errcode='PT409',message='Review this child revision';end if;
  update taskfold_private.child_task_records r set incarnation=(entry->>'incarnation')::uuid,revision=newrev,
   field_versions=(select jsonb_object_agg(k,newrev) from (select jsonb_object_keys(r.fields) k union select jsonb_object_keys(entry->'field_versions') union select unnest(array['title','description','priority','due_date','due_time','scheduled_at','time_zone','deadline_date','duration_minutes','assigned_to','labels','reminder_specs','is_heading','completed','completed_at','taskfold_completion_v1'])) keys)
   where r.task_id=did and r.node_key=entry->>'node_key' collate "C";
 end loop;
 delete from taskfold_private.child_transfer_history_scope where transaction_id=txid_current() and request_id=q and actor_id=a;
 if team is not null then delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=any(array[sid,did]);end if;
 if team is not null and (coalesce(taskfold_private.team_project_role(a,sp),'') not in('manager','editor') or coalesce(taskfold_private.team_project_role(a,dp),'') not in('manager','editor')) then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and ((sp is not null and not coalesce(public.has_project_access(a,sp),false)) or (dp is not null and not coalesce(public.has_project_access(a,dp),false))) then raise exception using errcode='42501',message='Editing access changed';end if;
 perform taskfold_private.read_child_task_records(sid,sg);perform taskfold_private.read_child_task_records(did,dg);
 if not exists(select 1 from taskfold_private.child_task_projections where task_id=sid and structure_revision=sr+1)
  or not exists(select 1 from taskfold_private.child_task_projections where task_id=did and structure_revision=dr+1) then raise exception using errcode='PT409',message='The move could not be confirmed';end if;
 inverse:=inverse||jsonb_build_object('digest',taskfold_private.child_structure_digest(did,key));
 insert into taskfold_private.child_task_transfers(actor_id,request_id,fingerprint,state,source_id,destination_id,team_id,source_generation,destination_generation,source_project,destination_project,action,undo_of,source_revision,destination_revision,node_key,incarnation,moved_count,inverse)
  values(a,q,fingerprint,'applied',sid,did,team,sg,dg,sp,dp,mode,undo_id,sr,dr,key,n.incarnation,count_moved,inverse) returning * into prior;
 if mode='undo' then update taskfold_private.child_task_transfers set reversed_by=q where actor_id=a and request_id=undo_id;end if;
 perform taskfold_private.team_actor();
 return taskfold_private.child_transfer_reply(prior,false);
end$$;

create function taskfold_private.child_transfer_assign(node jsonb,target text,present boolean,value jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare n jsonb;children jsonb:='[]';begin
 if normalize(node->>'id',NFC) collate "C"=target collate "C" then node:=case when present then node||jsonb_build_object('assigned_to',value) else node-'assigned_to' end;end if;
 if jsonb_typeof(node->'subtasks')='array' then
  for n in select * from jsonb_array_elements(node->'subtasks') loop children:=children||jsonb_build_array(taskfold_private.child_transfer_assign(n,target,present,value));end loop;
  node:=node||jsonb_build_object('subtasks',children);
 end if;return node;
end$$;
create function public.taskfold_transfer_child(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare reply jsonb;begin
 reply:=taskfold_private.transfer_child(_operation,_body);
 -- Send authorizes both current roots. Check/retry/close disclose only the
 -- authenticated actor's immutable receipt, including after access loss/deletion.
 if _operation='send' and reply->'replayed'='false'::jsonb and reply->>'state'='applied' then
  if (select count(*) from public.tasks where id in((_body->'source'->>'task_id')::uuid,(_body->'destination'->>'task_id')::uuid))<>2 then raise exception using errcode='42501',message='Both tasks must be available';end if;
 end if;return reply;
end$$;
revoke all on function taskfold_private.tag_child_transfer_history(),taskfold_private.child_transfer_reply(taskfold_private.child_task_transfers,boolean),taskfold_private.guard_child_transfer_nonce(),taskfold_private.transfer_child(text,jsonb),taskfold_private.child_transfer_assign(jsonb,text,boolean,jsonb),public.taskfold_transfer_child(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.transfer_child(text,jsonb),public.taskfold_transfer_child(text,jsonb) to authenticated;
