-- Disabled structural command candidate. Ordinary reads and app gates stay off.
alter table taskfold_private.child_task_record_config
 add column structure_reads_enabled boolean not null default false,
 add column structure_edits_enabled boolean not null default false;
alter table taskfold_private.team_task_edits drop constraint team_task_edits_operation_check;
alter table taskfold_private.team_task_edits add constraint team_task_edits_operation_check
 check(operation in('patch','create','delete','restore','move','child_completion','child_structure'));

create function taskfold_private.read_child_task_structure(root_id uuid,expected_generation uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare reply jsonb;rev bigint;begin
 perform 1 from taskfold_private.child_task_record_config where singleton and structure_reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child structure is not enabled';end if;
 reply:=taskfold_private.read_child_task_records(root_id,expected_generation);
 -- The delegated read retains its root SHARE lock until this transaction ends.
 select structure_revision into rev from taskfold_private.child_task_projections where task_id=root_id;
 if rev is null or rev not between 1 and 9007199254740991 then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 reply:=reply||jsonb_build_object('protocol',2,'structure_revision',rev);
 if octet_length(reply::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large to open';end if;
 return reply;
end$$;
create function public.taskfold_read_child_structure(_id uuid,_generation uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$begin
 if not exists(select 1 from public.tasks where id=_id and task_generation is not distinct from _generation) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return taskfold_private.read_child_task_structure(_id,_generation);
end$$;

create table taskfold_private.child_task_structure_receipts (
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 fingerprint text not null check(length(fingerprint)=64),task_id uuid not null,generation uuid,project_id uuid,
 action text not null check(action in('insert','move','delete','undo')),undo_of uuid,reversed_by uuid,
 before_revision bigint not null,after_revision bigint not null,
 node_key text collate "C" not null,incarnation uuid,
 inverse jsonb not null check(jsonb_typeof(inverse)='object'),
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id)
);
create index child_structure_receipts_actor_day on taskfold_private.child_task_structure_receipts(actor_id,created_at);
create table taskfold_private.child_task_structure_archives (
 actor_id uuid not null,request_id uuid not null,task_id uuid not null references public.tasks(id) on delete cascade,
 subtree jsonb not null check(jsonb_typeof(subtree)='object'),primary key(actor_id,request_id),
 foreign key(actor_id,request_id) references taskfold_private.child_task_structure_receipts(actor_id,request_id) on delete cascade
);
create index child_structure_archives_task on taskfold_private.child_task_structure_archives(task_id);
create table taskfold_private.child_task_structure_closures (
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,
 fingerprint text not null check(length(fingerprint)=64),created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id)
);
create index child_structure_closures_actor_day on taskfold_private.child_task_structure_closures(actor_id,created_at);
alter table taskfold_private.child_task_structure_receipts enable row level security;
alter table taskfold_private.child_task_structure_archives enable row level security;
alter table taskfold_private.child_task_structure_closures enable row level security;
revoke all on taskfold_private.child_task_structure_receipts,taskfold_private.child_task_structure_archives,taskfold_private.child_task_structure_closures from public,anon,authenticated,service_role;

create function taskfold_private.child_structure_receipt(r taskfold_private.child_task_structure_receipts,replayed boolean) returns jsonb
language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'request_id',r.request_id,'task_id',r.task_id,'task_generation',r.generation,'project_id',r.project_id,
 'action',r.action,'undo_of',r.undo_of,'before_revision',r.before_revision,'after_revision',r.after_revision,'node_key',r.node_key,'incarnation',r.incarnation,'replayed',replayed)
$$;
-- No title, notes or deleted content is returned by resolution/receipt APIs.
create function taskfold_private.validate_child_structure_request(b jsonb,a uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare mode text;allowed text[];v jsonb;k text;begin
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>384000 or b->'protocol' is distinct from '1'::jsonb
  or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','structure_revision','action'] then raise exception using errcode='22023',message='Review this saved structure action';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This structure action belongs to another account';end if;
 perform taskfold_private.team_uuid(b,'request_id');perform taskfold_private.team_uuid(b,'task_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if jsonb_typeof(b->'structure_revision') is distinct from 'number' or (b->>'structure_revision')!~'^[0-9]{1,16}$' or (b->>'structure_revision')::numeric not between 1 and 9007199254740990 then raise exception using errcode='22023',message='Review this hierarchy revision';end if;
 mode:=b->>'action';allowed:=array['protocol','account','request_id','task_id','task_generation','project_id','structure_revision','action'];
 if mode='insert' then allowed:=allowed||array['parent_key','index','node'];
 elsif mode='move' then allowed:=allowed||array['parent_key','index','node_key','incarnation'];
 elsif mode='delete' then allowed:=allowed||array['node_key','incarnation','subtree_versions'];
 elsif mode='undo' then allowed:=allowed||array['undo_of'];
 else raise exception using errcode='22023',message='Choose a supported structure action';end if;
 if not b ?& allowed or exists(select 1 from jsonb_object_keys(b) x where not x=any(allowed)) then raise exception using errcode='22023',message='Review this structure action';end if;
 foreach k in array array['parent_key','node_key'] loop
  if b ? k and not(k='parent_key' and b->k='null'::jsonb) then
   v:=b->k;if jsonb_typeof(v)<>'string' or octet_length(v#>>'{}') not between 1 and 128 or (v#>>'{}') collate "C"<>normalize(v#>>'{}',NFC) collate "C" then raise exception using errcode='22023',message='Review this child identity';end if;
  end if;
 end loop;
 if b ? 'index' and (jsonb_typeof(b->'index')<>'number' or (b->>'index')!~'^[0-9]{1,4}$' or (b->>'index')::int not between 0 and 1000) then raise exception using errcode='22023',message='Choose a supported sibling slot';end if;
 if b ? 'incarnation' then perform taskfold_private.team_uuid(b,'incarnation');end if;
 if mode='undo' then perform taskfold_private.team_uuid(b,'undo_of');end if;
 if mode='insert' and jsonb_typeof(b->'node')<>'object' then raise exception using errcode='22023',message='Review the new subtask';end if;
 if mode='delete' and (jsonb_typeof(b->'subtree_versions')<>'object' or b->'subtree_versions'='{}'::jsonb) then raise exception using errcode='22023',message='Review every subtask being removed';end if;
end$$;

-- Helpers receive only an already validated, bounded, identity-unique tree.
create function taskfold_private.child_structure_extract(rows jsonb,target text) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare n jsonb;found_node jsonb;begin
 for n in select * from jsonb_array_elements(rows) loop
  if normalize(n->>'id',NFC) collate "C"=target collate "C" then return n;end if;
  if jsonb_typeof(n->'subtasks')='array' then
   found_node:=taskfold_private.child_structure_extract(n->'subtasks',target);if found_node is not null then return found_node;end if;
  end if;
 end loop;return null;
end$$;
create function taskfold_private.child_structure_remove(rows jsonb,target text) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare n jsonb;result jsonb:='[]';begin
 for n in select * from jsonb_array_elements(rows) loop
  if normalize(n->>'id',NFC) collate "C"=target collate "C" then continue;end if;
  if jsonb_typeof(n->'subtasks')='array' then n:=jsonb_set(n,'{subtasks}',taskfold_private.child_structure_remove(n->'subtasks',target));end if;
  result:=result||jsonb_build_array(n);
 end loop;return result;
end$$;
create function taskfold_private.child_structure_splice(rows jsonb,slot integer,node jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare n jsonb;i integer:=0;result jsonb:='[]';begin
 if slot<0 or slot>jsonb_array_length(rows) then raise exception using errcode='PT409',message='The sibling order changed';end if;
 for n in select * from jsonb_array_elements(rows) loop
  if i=slot then result:=result||jsonb_build_array(node);end if;
  result:=result||jsonb_build_array(n);i:=i+1;
 end loop;
 if i=slot then result:=result||jsonb_build_array(node);end if;
 return result;
end$$;
create function taskfold_private.child_structure_insert(rows jsonb,parent text,slot integer,node jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare n jsonb;result jsonb:='[]';begin
 if parent is null then return taskfold_private.child_structure_splice(case when rows='null'::jsonb then '[]'::jsonb else rows end,slot,node);end if;
 for n in select * from jsonb_array_elements(rows) loop
  if normalize(n->>'id',NFC) collate "C"=parent collate "C" then
   n:=jsonb_set(n,'{subtasks}',taskfold_private.child_structure_splice(case when jsonb_typeof(n->'subtasks')='array' then n->'subtasks' else '[]'::jsonb end,slot,node));
  elsif jsonb_typeof(n->'subtasks')='array' then n:=jsonb_set(n,'{subtasks}',taskfold_private.child_structure_insert(n->'subtasks',parent,slot,node));end if;
  result:=result||jsonb_build_array(n);
 end loop;return result;
end$$;
create function taskfold_private.child_structure_restore_container(rows jsonb,parent text,kind text) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare n jsonb;result jsonb:='[]';begin
 if kind='array' then return rows;end if;
 if parent is null then
  if rows<>'[]'::jsonb then raise exception using errcode='PT409',message='The child container changed';end if;
  return 'null'::jsonb;
 end if;
 for n in select * from jsonb_array_elements(rows) loop
  if normalize(n->>'id',NFC) collate "C"=parent collate "C" then
   if n->'subtasks'<>'[]'::jsonb then raise exception using errcode='PT409',message='The child container changed';end if;
   n:=case when kind='absent' then n-'subtasks' else jsonb_set(n,'{subtasks}','null') end;
  elsif jsonb_typeof(n->'subtasks')='array' then n:=jsonb_set(n,'{subtasks}',taskfold_private.child_structure_restore_container(n->'subtasks',parent,kind));end if;
  result:=result||jsonb_build_array(n);
 end loop;return result;
end$$;
-- New creation rejects forged history/files/opaque fields; existing content is
-- moved/archived losslessly. Restoration changes only the completion identity.
create function taskfold_private.child_structure_fresh_node(node jsonb,restoring boolean) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare result jsonb;children jsonb:='[]';n jsonb;fields jsonb;begin
 fields:=node-'subtasks';
 if not restoring then
  if not fields ? 'title' or exists(select 1 from jsonb_object_keys(fields) k where k not in('id','title','description','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminder_specs','is_heading','completed','completed_at'))
   or (fields ? 'completed' and fields->'completed'<>'false'::jsonb) or coalesce(fields->'completed_at','null'::jsonb)<>'null'::jsonb
   or (fields ? 'is_heading' and jsonb_typeof(fields->'is_heading')<>'boolean') then raise exception using errcode='22023',message='Use supported new subtask fields';end if;
  perform taskfold_private.automation_validate_fields(fields-array['id','is_heading','completed','completed_at'],null);
  fields:=fields||jsonb_build_object('completed',false,'completed_at',null);
 end if;
 result:=fields||jsonb_build_object('taskfold_completion_v1',jsonb_build_object('epoch',gen_random_uuid(),'version',0));
 if jsonb_typeof(node->'subtasks')='array' then
  for n in select * from jsonb_array_elements(node->'subtasks') loop children:=children||jsonb_build_array(taskfold_private.child_structure_fresh_node(n,restoring));end loop;
  result:=result||jsonb_build_object('subtasks',children);
 elsif node ? 'subtasks' then result:=result||jsonb_build_object('subtasks',node->'subtasks');end if;
 return result;
end$$;
create function taskfold_private.child_structure_versions(root_id uuid,target text) returns jsonb
language sql stable security invoker set search_path='' as $$
 select coalesce(jsonb_object_agg(r.node_key,jsonb_build_object('incarnation',r.incarnation,'revision',r.revision)),'{}')
 from taskfold_private.child_task_records r,taskfold_private.child_task_records n
 where n.task_id=root_id and n.node_key=target and r.task_id=root_id and r.identity_path[1:cardinality(n.identity_path)]=n.identity_path
$$;
create function taskfold_private.child_structure_digest(root_id uuid,target text) returns text
language sql stable security invoker set search_path='' as $$
 select encode(extensions.digest(convert_to(coalesce(jsonb_agg(to_jsonb(r) order by r.node_key),'[]')::text,'UTF8'),'sha256'),'hex')
 from taskfold_private.child_task_records r,taskfold_private.child_task_records n
 where n.task_id=root_id and n.node_key=target and r.task_id=root_id and r.identity_path[1:cardinality(n.identity_path)]=n.identity_path
$$;

-- Reciprocal final-nonce checks also fence older writers which hold a root
-- lock before reaching their receipt. A failed try-lock aborts their DML.
create function taskfold_private.guard_child_structure_identity() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT410',message='This original structure action is closed';end if;
 if exists(select 1 from taskfold_private.child_task_structure_receipts where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT409',message='This request identity was used for a structure action';end if;
 return new;
end$$;
create trigger child_structure_fence_field_prepare before insert or update on taskfold_private.child_task_edit_preparations for each row execute function taskfold_private.guard_child_structure_identity();
create trigger child_structure_fence_field_receipt before insert or update on taskfold_private.child_task_edit_receipts for each row execute function taskfold_private.guard_child_structure_identity();
create trigger child_structure_fence_field_close before insert or update on taskfold_private.child_task_edit_closures for each row execute function taskfold_private.guard_child_structure_identity();
create trigger child_structure_fence_completion_receipt before insert or update on taskfold_private.child_task_completion_receipts for each row execute function taskfold_private.guard_child_structure_identity();
create trigger child_structure_fence_completion_close before insert or update on taskfold_private.child_task_completion_closures for each row execute function taskfold_private.guard_child_structure_identity();
create trigger child_structure_fence_team_edit before insert or update on taskfold_private.team_task_edits for each row execute function taskfold_private.guard_child_structure_identity();
create trigger child_structure_fence_team_batch before insert or update on taskfold_private.team_task_batches for each row execute function taskfold_private.guard_child_structure_identity();

create function taskfold_private.close_child_structure(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;fingerprint text;prior taskfold_private.child_task_structure_receipts;closed taskfold_private.child_task_structure_closures;begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_structure_request(b,a);q:=taskfold_private.team_uuid(b,'request_id');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This structure identity was already used';end if;
  return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','applied','receipt',taskfold_private.child_structure_receipt(prior,true));
 end if;
 select * into closed from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q;
 if found then
  if closed.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This original structure identity was already closed';end if;
  return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','closed','receipt',null);
 end if;
 if exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q) then raise exception using errcode='PT409',message='This request identity belongs to another action';end if;
 if (select count(*) from taskfold_private.child_task_structure_closures where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Try closing this original action later';end if;
 insert into taskfold_private.child_task_structure_closures(actor_id,request_id,fingerprint) values(a,q,fingerprint);
 return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','closed','receipt',null);
end$$;
create function public.taskfold_close_child_structure(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.close_child_structure(_body)$$;

-- Task deletion cascades archived content. A project/generation transfer purges
-- it before a future Undo can attempt to recover content into a different scope.
create function taskfold_private.purge_child_structure_archives() returns trigger
language plpgsql security definer set search_path='' as $$begin
 delete from taskfold_private.child_task_structure_archives where task_id=new.id;
 return new;
end$$;
create trigger taskfold_purge_child_structure_archives after update of project_id,task_generation on public.tasks
 for each row when(old.project_id is distinct from new.project_id or old.task_generation is distinct from new.task_generation)
 execute function taskfold_private.purge_child_structure_archives();

create function taskfold_private.edit_child_structure(b jsonb) returns jsonb
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
create function public.taskfold_edit_child_structure(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare receipt jsonb;begin
 receipt:=taskfold_private.edit_child_structure(_body);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return receipt;
end$$;

revoke all on function taskfold_private.read_child_task_structure(uuid,uuid),public.taskfold_read_child_structure(uuid,uuid),
 taskfold_private.child_structure_receipt(taskfold_private.child_task_structure_receipts,boolean),taskfold_private.validate_child_structure_request(jsonb,uuid),
 taskfold_private.child_structure_extract(jsonb,text),taskfold_private.child_structure_remove(jsonb,text),taskfold_private.child_structure_splice(jsonb,integer,jsonb),
 taskfold_private.child_structure_insert(jsonb,text,integer,jsonb),taskfold_private.child_structure_restore_container(jsonb,text,text),taskfold_private.child_structure_fresh_node(jsonb,boolean),
 taskfold_private.child_structure_versions(uuid,text),taskfold_private.child_structure_digest(uuid,text),taskfold_private.guard_child_structure_identity(),
 taskfold_private.close_child_structure(jsonb),public.taskfold_close_child_structure(jsonb),taskfold_private.purge_child_structure_archives(),
 taskfold_private.edit_child_structure(jsonb),public.taskfold_edit_child_structure(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.read_child_task_structure(uuid,uuid),public.taskfold_read_child_structure(uuid,uuid),
 taskfold_private.close_child_structure(jsonb),public.taskfold_close_child_structure(jsonb),taskfold_private.edit_child_structure(jsonb),public.taskfold_edit_child_structure(jsonb) to authenticated;

-- Explicit private-content disposal frees capacity without forgetting whether
-- the original task mutation happened. It never changes a task or its receipt.
create function taskfold_private.forget_child_structure_undo(q uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 if q is null then raise exception using errcode='22023',message='Choose a saved subtree Undo';end if;
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if not exists(select 1 from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q and action='delete') then raise exception using errcode='PT409',message='This saved subtree Undo is unavailable';end if;
 delete from taskfold_private.child_task_structure_archives where actor_id=a and request_id=q;
 return jsonb_build_object('protocol',1,'account',a,'request_id',q,'outcome','forgotten');
end$$;
create function public.taskfold_forget_child_structure_undo(_request_id uuid) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.forget_child_structure_undo(_request_id)$$;
revoke all on function taskfold_private.forget_child_structure_undo(uuid),public.taskfold_forget_child_structure_undo(uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.forget_child_structure_undo(uuid),public.taskfold_forget_child_structure_undo(uuid) to authenticated;

-- Bounded actor-owned discovery survives device/journal loss. Only original
-- immutable metadata is returned; current task state and archived text stay out.
create function taskfold_private.child_structure_undo_archives() returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();entries jsonb;reply jsonb;begin
 perform taskfold_private.team_actor();
 select coalesce(jsonb_agg(taskfold_private.child_structure_receipt(r,true) order by r.created_at,r.request_id),'[]') into entries
 from taskfold_private.child_task_structure_archives ar join taskfold_private.child_task_structure_receipts r using(actor_id,request_id)
 where ar.actor_id=a;
 if jsonb_array_length(entries)>64 then raise exception using errcode='54000',message='The saved Undo list needs review';end if;
 reply:=jsonb_build_object('protocol',1,'account',a,'entries',entries);
 if octet_length(reply::text)>65536 then raise exception using errcode='54000',message='The saved Undo list is too large';end if;
 perform taskfold_private.team_actor();return reply;
end$$;
create function public.taskfold_child_structure_undo_archives() returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.child_structure_undo_archives()$$;
revoke all on function taskfold_private.child_structure_undo_archives(),public.taskfold_child_structure_undo_archives() from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_structure_undo_archives(),public.taskfold_child_structure_undo_archives() to authenticated;
