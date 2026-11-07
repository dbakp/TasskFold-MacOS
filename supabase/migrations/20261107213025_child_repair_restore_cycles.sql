-- Reversible, explicit subtask-original restoration. No rollout is enabled.
alter table taskfold_private.child_task_record_config
 add column archive_restore_enabled boolean not null default false,
 add column archive_restore_reversals_enabled boolean not null default false;
create table taskfold_private.child_repair_restorations(
 actor_id uuid not null references auth.users(id) on delete cascade,restore_id uuid not null,
 task_id uuid not null,task_generation uuid,project_id uuid,workspace_id uuid,user_id uuid not null,
 repair_request_id uuid not null,archive_id uuid not null,archive_digest text not null check(archive_digest~'^[a-f0-9]{64}$'),
 phase text not null check(phase in('restored','undone','purged')),revision bigint not null check(revision between 1 and 9007199254740991),
 current_digest text not null check(current_digest~'^[a-f0-9]{64}$'),created_at timestamptz not null default clock_timestamp(),primary key(actor_id,restore_id)
);
create unique index child_restore_active_root on taskfold_private.child_repair_restorations(task_id) where phase='restored';
create index child_restore_workspace on taskfold_private.child_repair_restorations(workspace_id);
create table taskfold_private.child_repair_restore_payloads(
 actor_id uuid not null,restore_id uuid not null,team_id uuid,
 payload jsonb not null check(jsonb_typeof(payload)='object'),
 bytes integer not null check(bytes between 1 and 8000000 and bytes=octet_length(payload::text)),
 primary key(actor_id,restore_id),foreign key(actor_id,restore_id) references taskfold_private.child_repair_restorations(actor_id,restore_id) on delete cascade
);
create index child_restore_payload_team on taskfold_private.child_repair_restore_payloads(team_id);
create table taskfold_private.child_repair_restore_requests(
 actor_id uuid not null references auth.users(id) on delete cascade,request_id uuid not null,team_id uuid,
 fingerprint text not null check(fingerprint~'^[a-f0-9]{64}$'),reply jsonb not null,
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,request_id)
);
create unique index child_restore_team_nonce on taskfold_private.child_repair_restore_requests(team_id,request_id) where team_id is not null;
create index child_restore_request_day on taskfold_private.child_repair_restore_requests(actor_id,created_at);
-- An ungranted, transaction-bound scope permits only the exact mirror write.
create table taskfold_private.child_repair_restore_scope(
 transaction_id bigint not null,task_id uuid not null,task_generation uuid,actor_id uuid not null,
 tree_digest text not null,sql_null boolean not null,primary key(transaction_id,task_id)
);
alter table taskfold_private.child_repair_restorations enable row level security;
alter table taskfold_private.child_repair_restore_payloads enable row level security;
alter table taskfold_private.child_repair_restore_requests enable row level security;
alter table taskfold_private.child_repair_restore_scope enable row level security;
revoke all on taskfold_private.child_repair_restorations,taskfold_private.child_repair_restore_payloads,taskfold_private.child_repair_restore_requests,taskfold_private.child_repair_restore_scope from public,anon,authenticated,service_role;

-- Physical file identities remain pinned while a reversible version needs them.
-- No copies, provider calls or new read grants are made by restoration.
create table taskfold_private.child_repair_restore_files(
 actor_id uuid not null,restore_id uuid not null,object_id uuid not null references storage.objects(id) on delete restrict,
 primary key(actor_id,restore_id,object_id),foreign key(actor_id,restore_id) references taskfold_private.child_repair_restore_payloads(actor_id,restore_id) on delete cascade
);
create index child_restore_file_object on taskfold_private.child_repair_restore_files(object_id);
alter table taskfold_private.child_repair_restore_files enable row level security;
revoke all on taskfold_private.child_repair_restore_files from public,anon,authenticated,service_role;
create function taskfold_private.guard_child_restore_file() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.object_id)
 and (tg_op='DELETE' or to_jsonb(new)::text collate "C" is distinct from to_jsonb(old)::text collate "C") then raise exception using errcode='PT409',message='This file is retained by a saved restoration version';end if;
 if tg_op='DELETE' then return old;end if;return new;
end$$;
create trigger child_restore_file_binding before delete or update on taskfold_private.team_content_files for each row execute function taskfold_private.guard_child_restore_file();
create function taskfold_private.guard_child_restore_object() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.id)
 and (tg_op='DELETE' or (to_jsonb(new)-array['updated_at','last_accessed_at'])::text collate "C" is distinct from (to_jsonb(old)-array['updated_at','last_accessed_at'])::text collate "C") then
  raise exception using errcode='PT409',message='This file is retained by a saved restoration version';end if;
 if tg_op='DELETE' then return old;end if;return new;
end$$;
create trigger child_restore_object_identity before delete or update on storage.objects for each row execute function taskfold_private.guard_child_restore_object();

create function taskfold_private.validate_child_restore_files(manifest jsonb) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare entry jsonb;f taskfold_private.team_content_files;o storage.objects;b storage.buckets;actual jsonb;begin
 for entry in select * from jsonb_array_elements(manifest) loop
  select * into f from taskfold_private.team_content_files where object_id=(entry->>'object_id')::uuid for share nowait;
  if not found then raise exception using errcode='PT409',message='A retained file needs its custody review';end if;
  select * into o from storage.objects where id=f.object_id for share nowait;
  if not found then raise exception using errcode='PT409',message='A retained file is unavailable';end if;
  select * into b from storage.buckets where id=o.bucket_id for share nowait;
  if not found or b.public then raise exception using errcode='PT409',message='Retained files must stay private';end if;
  actual:=jsonb_build_object('object_id',f.object_id,'project_id',f.project_id,'task_id',f.task_id,'task_generation',f.task_generation,
    'bucket_id',o.bucket_id,'name',o.name,'owner',o.owner,'owner_id',o.owner_id,'metadata',to_jsonb(o)->'metadata','version',to_jsonb(o)->'version');
  if actual::text collate "C" is distinct from entry::text collate "C" then raise exception using errcode='PT409',message='A retained file changed; keep the current source';end if;
 end loop;
end$$;

-- Never discard records when showing an older malformed tree. They remain an
-- independently retained copy, with authoring paused until Undo or review.
create or replace function taskfold_private.refresh_child_task_records() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from taskfold_private.child_repair_restore_scope s where s.transaction_id=txid_current() and s.task_id=new.id
  and s.actor_id=auth.uid() and s.task_generation is not distinct from new.task_generation and s.sql_null=(new.subtasks is null)
  and s.tree_digest=encode(extensions.digest(convert_to(coalesce(new.subtasks,'null'::jsonb)::text,'UTF8'),'sha256'),'hex')) then return new;end if;
 if exists(select 1 from taskfold_private.child_task_projections where task_id=new.id) then
  perform taskfold_private.sync_child_task_records(new.id,new.task_generation,new.subtasks);
 end if;
 return new;
end$$;
create function taskfold_private.guard_restored_child_realm() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if (new.task_generation is distinct from old.task_generation or new.project_id is distinct from old.project_id or new.user_id is distinct from old.user_id)
 and exists(select 1 from taskfold_private.child_repair_restorations where task_id=old.id and phase='restored') then
  raise exception using errcode='PT409',message='Undo this older-structure restoration before moving the task';end if;
 return new;
end$$;
create trigger aaa_taskfold_restored_child_realm before update of task_generation,project_id,user_id on public.tasks for each row execute function taskfold_private.guard_restored_child_realm();
-- Ordinary writers cannot silently re-project and clear the retained copy.
create function taskfold_private.guard_restored_child_content() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if (new.subtasks is null) is distinct from (old.subtasks is null)
  or coalesce(new.subtasks,'null'::jsonb)::text collate "C" is distinct from coalesce(old.subtasks,'null'::jsonb)::text collate "C" then
  if exists(select 1 from taskfold_private.child_repair_restorations where task_id=old.id and phase='restored')
  and not exists(select 1 from taskfold_private.child_repair_restore_scope s where s.transaction_id=txid_current() and s.task_id=new.id and s.actor_id=auth.uid()
   and s.task_generation is not distinct from new.task_generation and s.sql_null=(new.subtasks is null) and s.tree_digest=encode(extensions.digest(convert_to(coalesce(new.subtasks,'null'::jsonb)::text,'UTF8'),'sha256'),'hex')) then
   raise exception using errcode='PT409',message='Undo the older-structure restoration before changing its subtasks';end if;
 end if;return new;
end$$;
create trigger aaa_taskfold_restored_child_content before update of subtasks on public.tasks for each row execute function taskfold_private.guard_restored_child_content();
-- Existing original producers share the same retained-content budget.
create function taskfold_private.guard_child_restore_original_budget() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if new.actor_id is null then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended(new.actor_id::text,73918));
 if new.team_id is not null and not pg_try_advisory_xact_lock(hashtextextended(new.team_id::text,73928)) then raise exception using errcode='55P03',message='Another workspace original is being retained';end if;
 if coalesce((select sum(bytes) from taskfold_private.child_task_repair_originals where actor_id=new.actor_id and id<>new.id),0)
   +coalesce((select sum(bytes) from taskfold_private.child_repair_restore_payloads where actor_id=new.actor_id),0)+new.bytes>64000000
 or (new.team_id is not null and coalesce((select sum(bytes) from taskfold_private.child_task_repair_originals where team_id=new.team_id and id<>new.id),0)
   +coalesce((select sum(bytes) from taskfold_private.child_repair_restore_payloads where team_id=new.team_id),0)+new.bytes>256000000) then raise exception using errcode='PT429',message='Retained-original storage is full';end if;
 return new;
end$$;
create trigger child_restore_original_budget before insert or update of bytes,actor_id,team_id on taskfold_private.child_task_repair_originals for each row execute function taskfold_private.guard_child_restore_original_budget();
create function taskfold_private.purge_team_child_restore_payloads() returns trigger
language plpgsql security definer set search_path='' as $$begin
 delete from taskfold_private.child_repair_restore_payloads where team_id=new.id;
 update taskfold_private.child_repair_restorations set phase='purged' where workspace_id=new.id;
 return new;
end$$;
create trigger taskfold_purge_team_child_restore after update of state on taskfold_private.teams for each row when(new.state='deleted' and old.state is distinct from new.state) execute function taskfold_private.purge_team_child_restore_payloads();

-- All old operation ledgers reciprocally fence the new decision nonce. Scope
-- tables are transient and removed before the immutable decision is inserted.
create function taskfold_private.guard_child_restore_nonce() returns trigger
language plpgsql security invoker set search_path='' as $$
declare team uuid:=nullif(to_jsonb(new)->>'team_id','')::uuid;entry record;used boolean;begin
 if new.actor_id is null then return new;end if;
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another saved decision is finishing';end if;
 if tg_table_name<>'child_repair_restore_requests' then
  if exists(select 1 from taskfold_private.child_repair_restore_requests r where r.request_id=new.request_id and (r.actor_id=new.actor_id or r.team_id=team)) then raise exception using errcode='PT409',message='This identity belongs to an original restoration';end if;
 else
  for entry in select c.oid,c.relname,exists(select 1 from pg_attribute where attrelid=c.oid and attname='team_id' and not attisdropped) has_team
   from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='taskfold_private' and c.relkind='r' and c.relname<>'child_repair_restore_requests'
    and exists(select 1 from pg_attribute where attrelid=c.oid and attname='actor_id' and atttypid='uuid'::regtype and not attisdropped)
    and exists(select 1 from pg_attribute where attrelid=c.oid and attname='request_id' and atttypid='uuid'::regtype and not attisdropped)
  loop
   execute format('select exists(select 1 from taskfold_private.%I where request_id=$1 and (actor_id=$2 %s))',entry.relname,case when entry.has_team then 'or team_id=$3' else '' end) into used using new.request_id,new.actor_id,team;
   if used then raise exception using errcode='PT409',message='This identity belongs to another saved operation';end if;
  end loop;
 end if;
 return new;
end$$;
do $$declare entry record;begin
 for entry in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='taskfold_private' and c.relkind='r'
  and exists(select 1 from pg_attribute where attrelid=c.oid and attname='actor_id' and atttypid='uuid'::regtype and not attisdropped)
  and exists(select 1 from pg_attribute where attrelid=c.oid and attname='request_id' and atttypid='uuid'::regtype and not attisdropped)
 loop execute format('create trigger child_restore_nonce before insert or update on taskfold_private.%I for each row execute function taskfold_private.guard_child_restore_nonce()',entry.relname);end loop;
end$$;

create function taskfold_private.child_restore_digest(value jsonb) returns text language sql immutable security invoker set search_path='' as $$select encode(extensions.digest(convert_to(value::text,'UTF8'),'sha256'),'hex')$$;
-- One forward cursor and a retained byte budget, not an unbounded aggregation.
create function taskfold_private.child_restore_snapshot(t public.tasks) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare header jsonb;p taskfold_private.child_task_projections;a taskfold_private.child_task_record_authority;r taskfold_private.child_task_records;
 parts text[]:='{}';part text;used bigint;count_rows integer:=0;reply jsonb;team uuid;
 rows_cursor no scroll cursor for select x.* from taskfold_private.child_task_records x where x.task_id=t.id order by x.node_key collate "C";
begin
 select * into p from taskfold_private.child_task_projections where task_id=t.id;
 select * into a from taskfold_private.child_task_record_authority where task_id=t.id;
 select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
 header:=jsonb_build_object('task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'workspace_id',team,'user_id',t.user_id,'is_heading',t.is_heading,
  'tree',coalesce(t.subtasks,'null'::jsonb),'sql_null',t.subtasks is null,'projection',case when p.task_id is null then null else to_jsonb(p) end,'authority',case when a.task_id is null then null else to_jsonb(a) end,'records','[]'::jsonb);
 used:=octet_length(header::text);if used>8000000 then raise exception using errcode='PT413',message='This current structure needs a larger-work restoration review';end if;
 open rows_cursor;loop fetch next from rows_cursor into r;exit when not found;
  count_rows:=count_rows+1;part:=to_jsonb(r)::text;used:=used+octet_length(part)+case when count_rows=1 then 0 else 2 end;
  if count_rows>1000 or used>8000000 then raise exception using errcode='PT413',message='This current structure needs a larger-work restoration review';end if;
  parts:=array_append(parts,part);
 end loop;close rows_cursor;
 reply:=jsonb_set(header,'{records}',('['||coalesce(array_to_string(parts,', '),'')||']')::jsonb);
 if octet_length(reply::text)<>used then raise exception using errcode='PT409',message='This structure could not be captured exactly';end if;
 return reply;
end$$;
create function taskfold_private.child_restore_history_counts(root_id uuid) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('root',(select count(*) from public.task_activity where task_id=root_id),'child',(select count(*) from public.task_node_activity where task_id=root_id))
$$;
create function taskfold_private.child_restore_root(root_id uuid,generation uuid,project uuid,workspace uuid) returns public.tasks
language plpgsql volatile security invoker set search_path='' as $$declare t public.tasks;team uuid;begin
 t:=taskfold_private.child_adoption_root(root_id,generation,true);
 select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
 if t.project_id is distinct from project or team is distinct from workspace then raise exception using errcode='42501',message='This restoration belongs to another task context';end if;
 if exists(select 1 from public.task_node_activity h where h.task_id=root_id and not taskfold_private.child_repair_history_visible(h)) then raise exception using errcode='42501',message='Current history needs a custody review';end if;
 return t;
end$$;

create function taskfold_private.review_child_restore(mode text,repair_request uuid,archive uuid,restoration uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();r taskfold_private.child_task_repairs;s taskfold_private.child_repair_restorations;t public.tasks;
 original jsonb;current_state jsonb;target jsonb;payload jsonb;enabled boolean;sql_null boolean;revision bigint;restore_key uuid;files jsonb:='[]';retained_bytes integer;availability text;
begin
 perform taskfold_private.team_actor();
 if mode is null or mode not in('restore','undo','redo') or repair_request is null or archive is null or (mode='restore')<>(restoration is null) then raise exception using errcode='22023',message='Choose an original restoration action';end if;
 if mode='restore' then
  original:=taskfold_private.discovered_child_repair_original(repair_request,archive);
  select * into r from taskfold_private.child_task_repairs where actor_id=actor and request_id=repair_request and archive_id=archive;
  t:=taskfold_private.child_restore_root(r.task_id,r.task_generation,r.project_id,r.workspace_id);
  target:=original->'original'->'root'->'subtasks';sql_null:=(original->'original'->>'subtasks_sql_null')::boolean;revision:=0;
  if target is null or original->'original'->'root'->>'user_id'<>t.user_id::text then raise exception using errcode='PT409',message='This original needs a restoration review';end if;
  if exists(select 1 from taskfold_private.child_repair_restorations where task_id=t.id and phase='restored') then raise exception using errcode='PT409',message='Resolve the existing older-structure restoration first';end if;
  select archive_restore_enabled and archive_restore_reversals_enabled into enabled from taskfold_private.child_task_record_config where singleton;
 else
  select * into s from taskfold_private.child_repair_restorations where actor_id=actor and restore_id=restoration and repair_request_id=repair_request and archive_id=archive for share nowait;
  if not found or s.phase<>(case when mode='undo' then 'restored' else 'undone' end) then raise exception using errcode='PT409',message='Review the latest restoration decision';end if;
  t:=taskfold_private.child_restore_root(s.task_id,s.task_generation,s.project_id,s.workspace_id);
  select p.payload into payload from taskfold_private.child_repair_restore_payloads p where p.actor_id=actor and p.restore_id=restoration;
  if payload is null or s.user_id<>t.user_id then raise exception using errcode='42501',message='The retained restoration is unavailable';end if;
  target:=case when mode='undo' then payload->'before'->'tree' else payload->'target' end;
  sql_null:=(case when mode='undo' then payload->'before'->>'sql_null' else payload->>'target_sql_null' end)::boolean;revision:=s.revision;restore_key:=s.restore_id;
  select archive_restore_reversals_enabled into enabled from taskfold_private.child_task_record_config where singleton;
 end if;
 current_state:=taskfold_private.child_restore_snapshot(t);
 if mode='restore' then
  files:=taskfold_private.team_task_file_inventory(t);
  retained_bytes:=octet_length(jsonb_build_object('before',current_state,'target',target,'target_sql_null',sql_null,'files',files)::text);
 else
  files:=payload->'files';perform taskfold_private.validate_child_restore_files(files);
  retained_bytes:=octet_length(payload::text);
 end if;
 availability:=case when not coalesce(enabled,false) then 'paused' when retained_bytes>8000000 then 'retention_limit' else 'ready' end;
 if mode='restore' and availability='ready' and (
  coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.actor_id=actor),0)+coalesce((select sum(p.bytes) from taskfold_private.child_repair_restore_payloads p where p.actor_id=actor),0)+retained_bytes>64000000
  or ((current_state->>'workspace_id') is not null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.team_id=(current_state->>'workspace_id')::uuid),0)+coalesce((select sum(p.bytes) from taskfold_private.child_repair_restore_payloads p where p.team_id=(current_state->>'workspace_id')::uuid),0)+retained_bytes>256000000)) then availability:='quota';end if;

 if mode<>'restore' and taskfold_private.child_restore_digest(current_state)<>s.current_digest then raise exception using errcode='PT409',message='Subtask work changed; keep its newer version';end if;
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',actor,'task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'workspace_id',current_state->'workspace_id',
  'repair_request_id',repair_request,'archive_id',archive,'archive_digest',case when mode='restore' then r.archive_digest else s.archive_digest end,'mode',mode,'restore_id',restore_key,'revision',revision,
  'review_digest',taskfold_private.child_restore_digest(jsonb_build_object('source',current_state,'files',files)),'enabled',availability='ready','availability',availability,'retention_bytes',retained_bytes,'file_count',jsonb_array_length(files),'current_source',current_state->'tree','current_sql_null',current_state->'sql_null','target_source',target,'target_sql_null',sql_null,
  '__history_counts',taskfold_private.child_restore_history_counts(t.id));
end$$;
create function public.taskfold_review_child_restore(_mode text,_repair uuid,_archive uuid,_restore uuid default null) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 reply:=taskfold_private.review_child_restore(_mode,_repair,_archive,_restore);
 if _mode='restore' then perform public.taskfold_child_repair_original(_repair,_archive);end if;
 if not exists(select 1 from public.tasks where id=(reply->>'task_id')::uuid and task_generation is not distinct from (reply->>'task_generation')::uuid)
 or (reply->'__history_counts'->>'root')::bigint<>(select count(*) from public.task_activity where task_id=(reply->>'task_id')::uuid)
 or (reply->'__history_counts'->>'child')::bigint<>(select count(*) from public.task_node_activity where task_id=(reply->>'task_id')::uuid) then raise exception using errcode='42501',message='Current task or history access changed';end if;
 return reply-'__history_counts';
end$$;

create function taskfold_private.commit_child_restore(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();q uuid;fingerprint text;old taskfold_private.child_repair_restore_requests;s taskfold_private.child_repair_restorations;
 t public.tasks;review jsonb;before_state jsonb;payload jsonb;target jsonb;sql_null boolean;restore_key uuid;next_revision bigint;
 team uuid;bytes integer;desired_projection jsonb;reply jsonb;after_state jsonb;files jsonb:='[]';entry jsonb;
begin
 perform taskfold_private.team_actor();
 if operation is null or operation not in('send','check','close') or jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>4096
  or b->'protocol' is distinct from '1'::jsonb or (b->'protocol')::text<>'1' or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','request_id','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest'))
  or jsonb_typeof(b->'revision') is distinct from 'number' or (b->'revision')::text!~'^(0|[1-9][0-9]{0,15})$' or (b->>'revision')::numeric>=9007199254740991
  or jsonb_typeof(b->'mode') is distinct from 'string' or b->>'mode' not in('restore','undo','redo')
  or jsonb_typeof(b->'archive_digest') is distinct from 'string' or (b->>'archive_digest')!~'^[a-f0-9]{64}$'
  or jsonb_typeof(b->'review_digest') is distinct from 'string' or (b->>'review_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the exact restoration request';end if;
 if taskfold_private.team_uuid(b,'account')<>actor then raise exception using errcode='42501',message='This request belongs to another account';end if;
 q:=taskfold_private.team_uuid(b,'request_id');perform taskfold_private.team_uuid(b,'task_id');perform taskfold_private.team_uuid(b,'repair_request_id');perform taskfold_private.team_uuid(b,'archive_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if b->'workspace_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'workspace_id');end if;
 if b->'restore_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'restore_id');end if;
 if (b->>'mode'='restore')<>(b->'restore_id'='null'::jsonb) or (b->>'mode'='restore')<>((b->>'revision')::bigint=0) then raise exception using errcode='22023',message='Review this restoration phase';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,73918));perform taskfold_private.team_actor();
 if not pg_try_advisory_xact_lock(hashtextextended(actor::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another restoration decision is finishing';end if;
 fingerprint:=taskfold_private.child_restore_digest(b);
 select * into old from taskfold_private.child_repair_restore_requests where actor_id=actor and request_id=q;
 if found then
  if old.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This restoration identity was already used';end if;
  return old.reply||jsonb_build_object('replayed',true);
 end if;
 reply:=b||jsonb_build_object('state',case when operation='close' then 'closed' else 'unknown' end,'replayed',false,'restoration_id',null,'next_revision',null,'phase',null,'after_digest',null);
 if operation='check' then return reply;end if;
 if (select count(*) from taskfold_private.child_repair_restore_requests where actor_id=actor and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many saved restoration decisions; try later';end if;
 if operation='close' then
  insert into taskfold_private.child_repair_restore_requests(actor_id,request_id,fingerprint,reply) values(actor,q,fingerprint,reply);return reply;
 end if;
 review:=taskfold_private.review_child_restore(b->>'mode',(b->>'repair_request_id')::uuid,(b->>'archive_id')::uuid,(b->>'restore_id')::uuid);
 if review->'enabled'<>'true'::jsonb then raise exception using errcode='PT503',message='This restoration action is paused';end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and archive_restore_reversals_enabled and (b->>'mode'<>'restore' or archive_restore_enabled) for share nowait;
 if not found then raise exception using errcode='PT503',message='This restoration action is paused';end if;
 if exists(select 1 from jsonb_each(review-'enabled'-'current_source'-'current_sql_null'-'target_source'-'target_sql_null'-'availability'-'retention_bytes'-'file_count'-'__history_counts') e where b->e.key is distinct from e.value) then raise exception using errcode='PT409',message='This structure changed; review it again';end if;
 t:=taskfold_private.child_restore_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,(b->>'project_id')::uuid,(b->>'workspace_id')::uuid);
 team:=(b->>'workspace_id')::uuid;before_state:=taskfold_private.child_restore_snapshot(t);target:=review->'target_source';sql_null:=(review->>'target_sql_null')::boolean;
 if b->>'mode'='restore' then
  files:=taskfold_private.team_task_file_inventory(t);
  restore_key:=q;next_revision:=1;payload:=jsonb_build_object('before',before_state,'target',target,'target_sql_null',sql_null,'files',files);
  bytes:=octet_length(payload::text);if bytes>8000000 then raise exception using errcode='PT413',message='These retained versions need a larger-work restoration review';end if;
  if team is not null and not pg_try_advisory_xact_lock(hashtextextended(team::text,73928)) then raise exception using errcode='55P03',message='Another workspace original is being retained';end if;
  if coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.actor_id=actor),0)+coalesce((select sum(p.bytes) from taskfold_private.child_repair_restore_payloads p where p.actor_id=actor),0)+bytes>64000000
   or (team is not null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.team_id=team),0)+coalesce((select sum(p.bytes) from taskfold_private.child_repair_restore_payloads p where p.team_id=team),0)+bytes>256000000) then raise exception using errcode='PT429',message='Retained-original storage is full; keep both versions unchanged';end if;
  insert into taskfold_private.child_repair_restorations(actor_id,restore_id,task_id,task_generation,project_id,workspace_id,user_id,repair_request_id,archive_id,archive_digest,phase,revision,current_digest)
   values(actor,q,t.id,t.task_generation,t.project_id,team,t.user_id,(b->>'repair_request_id')::uuid,(b->>'archive_id')::uuid,b->>'archive_digest','restored',1,b->>'review_digest');
  insert into taskfold_private.child_repair_restore_payloads(actor_id,restore_id,team_id,payload,bytes) values(actor,q,team,payload,bytes);
  for entry in select * from jsonb_array_elements(files) loop insert into taskfold_private.child_repair_restore_files values(actor,q,(entry->>'object_id')::uuid);end loop;
 else
  restore_key:=(b->>'restore_id')::uuid;
  select * into s from taskfold_private.child_repair_restorations where actor_id=actor and restore_id=restore_key for update nowait;
  select p.payload into payload from taskfold_private.child_repair_restore_payloads p where p.actor_id=actor and p.restore_id=restore_key;
  next_revision:=s.revision+1;
 end if;
 -- No incarnation is reused across a restoration boundary. Existing field,
 -- completion and transfer commands carry incarnations; topology writers also
 -- observe the monotonically increased structure revision. Authored fields and
 -- linked file/comment identities are not rewritten.
 if exists(select 1 from taskfold_private.child_task_records where task_id=t.id and revision>=9007199254740991)
 or exists(select 1 from taskfold_private.child_task_projections where task_id=t.id and (revision>=9007199254740991 or structure_revision>=9007199254740991)) then raise exception using errcode='PT409',message='This hierarchy needs a larger-work revision review';end if;
 delete from taskfold_private.child_task_record_authority where task_id=t.id;
 update taskfold_private.child_task_records set incarnation=gen_random_uuid(),revision=revision+1 where task_id=t.id;
 if b->>'mode'='undo' then
  desired_projection:=payload->'before'->'projection';
  if desired_projection<>'null'::jsonb then
   update taskfold_private.child_task_projections set source_tree=desired_projection->'source_tree',state=desired_projection->>'state',issue=desired_projection->>'issue',revision=revision+1,structure_revision=structure_revision+1 where task_id=t.id;
  end if;
 else
  update taskfold_private.child_task_projections set state='review',issue='projection_mismatch',revision=revision+1,structure_revision=structure_revision+1 where task_id=t.id;
 end if;
 insert into taskfold_private.child_repair_restore_scope values(txid_current(),t.id,t.task_generation,actor,taskfold_private.child_restore_digest(target),sql_null);
 if team is not null then insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,t.project_id,t.id,t.task_generation,actor,'patch',q);end if;
 update public.tasks set subtasks=case when sql_null then null::jsonb else target end where id=t.id returning * into t;
 if team is not null then delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=t.id;end if;
 delete from taskfold_private.child_repair_restore_scope where transaction_id=txid_current() and task_id=t.id;
 if (t.subtasks is null)<>sql_null or coalesce(t.subtasks,'null'::jsonb)::text collate "C" is distinct from target::text collate "C" then raise exception using errcode='PT409',message='This older structure could not be restored exactly';end if;
 if b->>'mode'='undo' and payload->'before'->'authority'<>'null'::jsonb then
  insert into taskfold_private.child_task_record_authority(task_id,task_generation,project_id,root_kind) values(t.id,t.task_generation,t.project_id,payload->'before'->'authority'->>'root_kind');
 end if;
 after_state:=taskfold_private.child_restore_snapshot(t);perform taskfold_private.team_actor();
 update taskfold_private.child_repair_restorations set phase=case when b->>'mode'='undo' then 'undone' else 'restored' end,revision=next_revision,current_digest=taskfold_private.child_restore_digest(after_state) where actor_id=actor and restore_id=restore_key;
 reply:=b||jsonb_build_object('state','applied','replayed',false,'restoration_id',restore_key,'next_revision',next_revision,'phase',case when b->>'mode'='undo' then 'undone' else 'restored' end,'after_digest',taskfold_private.child_restore_digest(after_state));
 insert into taskfold_private.child_repair_restore_requests(actor_id,request_id,team_id,fingerprint,reply) values(actor,q,team,fingerprint,reply);
 return reply||jsonb_build_object('__history_counts',taskfold_private.child_restore_history_counts(t.id));
end$$;
create function public.taskfold_restore_child_original(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 reply:=taskfold_private.commit_child_restore(_operation,_body);
 if reply ? '__history_counts' then
  if _body->>'mode'='restore' then perform public.taskfold_child_repair_original((_body->>'repair_request_id')::uuid,(_body->>'archive_id')::uuid);end if;
  if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid and task_generation is not distinct from (_body->>'task_generation')::uuid)
   or (reply->'__history_counts'->>'root')::bigint<>(select count(*) from public.task_activity where task_id=(_body->>'task_id')::uuid)
   or (reply->'__history_counts'->>'child')::bigint<>(select count(*) from public.task_node_activity where task_id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='Current task or history access changed';end if;
 end if;
 return reply-'__history_counts';
end$$;
revoke all on function taskfold_private.refresh_child_task_records(),taskfold_private.guard_restored_child_realm(),taskfold_private.purge_team_child_restore_payloads(),taskfold_private.guard_child_restore_nonce(),
 taskfold_private.guard_child_restore_file(),taskfold_private.guard_child_restore_object(),taskfold_private.validate_child_restore_files(jsonb),taskfold_private.guard_restored_child_content(),taskfold_private.guard_child_restore_original_budget(),taskfold_private.child_restore_digest(jsonb),taskfold_private.child_restore_snapshot(public.tasks),taskfold_private.child_restore_history_counts(uuid),taskfold_private.child_restore_root(uuid,uuid,uuid,uuid),
 taskfold_private.review_child_restore(text,uuid,uuid,uuid),taskfold_private.commit_child_restore(text,jsonb),public.taskfold_review_child_restore(text,uuid,uuid,uuid),public.taskfold_restore_child_original(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.review_child_restore(text,uuid,uuid,uuid),taskfold_private.commit_child_restore(text,jsonb),public.taskfold_review_child_restore(text,uuid,uuid,uuid),public.taskfold_restore_child_original(text,jsonb) to authenticated;
