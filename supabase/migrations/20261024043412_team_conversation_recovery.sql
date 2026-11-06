-- Disabled candidate: task Undo preserves discussions without exposing a trash
-- reader or retaining plaintext in operation receipts. Recovery lasts 30 days.
alter table taskfold_private.team_task_edits add column conversation_state text not null default 'none'
 check(conversation_state in('none','ready','restored','expired'));
create table taskfold_private.team_conversation_keys (
 team_id uuid not null,request_id uuid not null,secret bytea not null check(octet_length(secret)=32),
 expires_at timestamptz not null default clock_timestamp()+interval '30 days',
 primary key(team_id,request_id),
 foreign key(team_id,request_id) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
create index team_conversation_keys_expiry on taskfold_private.team_conversation_keys(expires_at,team_id,request_id);
create table taskfold_private.team_conversation_archive (
 team_id uuid not null,request_id uuid not null,comment_id uuid not null,payload bytea not null,
 primary key(team_id,request_id,comment_id),
 foreign key(team_id,request_id) references taskfold_private.team_conversation_keys(team_id,request_id) on delete cascade
);
create table taskfold_private.team_conversation_ids (
 comment_id uuid primary key,team_id uuid not null references taskfold_private.teams(id) on delete restrict
);
create index team_conversation_ids_team on taskfold_private.team_conversation_ids(team_id);
create table taskfold_private.team_conversation_scope (
 transaction_id bigint not null,team_id uuid not null,request_id uuid not null,
 task_id uuid not null,generation uuid not null,project_id uuid not null,actor_id uuid not null,
 operation text not null check(operation in('archive','restore')),
 primary key(transaction_id,request_id,operation)
);
do $$declare n text;begin foreach n in array array['team_conversation_keys','team_conversation_archive','team_conversation_ids','team_conversation_scope'] loop
 execute format('alter table taskfold_private.%I enable row level security',n);
 execute format('revoke all on taskfold_private.%I from public,anon,authenticated,service_role',n);
end loop;end$$;

create function taskfold_private.team_conversation_id_guard() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from taskfold_private.team_conversation_ids where comment_id=new.id) then
  raise exception using errcode='PT409',message='Choose a new comment identity';end if;
 return new;
end$$;
create trigger aa_team_conversation_identity before insert on public.task_comments for each row execute function taskfold_private.team_conversation_id_guard();
revoke all on function taskfold_private.team_conversation_id_guard() from public,anon,authenticated,service_role;

-- The lifecycle already owns the root's FOR UPDATE lock and verified scope.
create function taskfold_private.archive_team_conversation(team uuid,p uuid,id uuid,generation uuid,q uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
<<save>>
declare c public.task_comments;key bytea:=extensions.gen_random_bytes(32);mentions jsonb;found_comments boolean:=false;
begin
 for c in select * from public.task_comments where task_id=archive_team_conversation.id order by public.task_comments.id for update loop
  if c.project_id is distinct from p or c.task_generation is distinct from generation then raise exception using errcode='PT409',message='Review the original discussion before deleting';end if;
  if not found_comments then
   insert into taskfold_private.team_conversation_keys(team_id,request_id,secret) values(team,q,key);
   insert into taskfold_private.team_conversation_scope values(txid_current(),team,q,id,generation,p,auth.uid(),'archive');
   found_comments=true;
  end if;
  -- A read action may hold a mention lock, but not a root lock. Capture its final
  -- state under comment-before-mention order, matching normal comment edits.
  perform 1 from public.task_mentions where comment_id=c.id order by public.task_mentions.id for update;
  select coalesce(jsonb_agg(to_jsonb(m) order by m.id),'[]'::jsonb) into mentions from public.task_mentions m where m.comment_id=c.id;
  insert into taskfold_private.team_conversation_ids values(c.id,team) on conflict(comment_id) do nothing;
  insert into taskfold_private.team_conversation_archive values(team,q,c.id,
   extensions.pgp_sym_encrypt(jsonb_build_object('comment',to_jsonb(c),'mentions',mentions)::text,encode(key,'base64'),'cipher-algo=aes256,compress-algo=1'));
 end loop;
 if found_comments then update taskfold_private.team_task_edits set conversation_state='ready' where team_id=team and request_id=q;end if;
end$$;

-- Called before taking the team lock. No client has EXECUTE: actor/project
-- authority and a matching successful deletion are verified by the lifecycle.
create function taskfold_private.hold_team_conversation_auth(team uuid,q uuid,a uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare k bytea;begin
 select secret into k from taskfold_private.team_conversation_keys c join taskfold_private.team_task_edits d using(team_id,request_id)
 where c.team_id=team and c.request_id=q and d.actor_id=a and d.operation='delete' and d.restored_request is null and c.expires_at>clock_timestamp();
 if not found then return;end if;
 perform 1 from auth.users where id in(
  with docs as materialized (
   select extensions.pgp_sym_decrypt(payload,encode(k,'base64'))::jsonb as doc from taskfold_private.team_conversation_archive where team_id=team and request_id=q
  ), participants as (
   select (doc->'comment'->>'author_id')::uuid as id from docs
   union select (m->>'recipient_id')::uuid from docs cross join lateral jsonb_array_elements(doc->'mentions') m
  ) select participants.id from participants where participants.id is not null
 ) order by id for share;
end$$;

create function taskfold_private.assert_team_conversation_undo(team uuid,q uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare state text;begin
 select conversation_state into state from taskfold_private.team_task_edits where team_id=team and request_id=q;
 if state='none' then return;end if;
 if state is distinct from 'ready' or not exists(select 1 from taskfold_private.team_conversation_keys where team_id=team and request_id=q and expires_at>clock_timestamp()) then
  raise exception using errcode='PT410',message='Discussion recovery has expired; your saved task remains on this device';end if;
end$$;

create function taskfold_private.restore_team_conversation(team uuid,q uuid,p uuid,id uuid,generation uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
<<restore>>
declare k bytea;doc jsonb;c public.task_comments;old_c public.task_comments;m public.task_mentions;item record;value jsonb;people uuid[];
begin
 perform taskfold_private.assert_team_conversation_undo(team,q);
 select secret into k from taskfold_private.team_conversation_keys where team_id=team and request_id=q;
 if not found then return;end if;
 insert into taskfold_private.team_conversation_scope values(txid_current(),team,q,id,generation,p,auth.uid(),'restore');
 for item in select * from taskfold_private.team_conversation_archive where team_id=team and request_id=q order by comment_id loop
  doc=extensions.pgp_sym_decrypt(item.payload,encode(k,'base64'))::jsonb;
  old_c=jsonb_populate_record(null::public.task_comments,doc->'comment');c=old_c;
  if old_c.id<>item.comment_id or old_c.task_id<>id or old_c.project_id<>p then raise exception using errcode='PT409',message='Discussion recovery needs review';end if;
  -- Fresh IDs fence old comment and mention callbacks. Preserve content, author,
  -- original time/read state and tombstones without replaying operation receipts.
  c.id=gen_random_uuid();c.task_generation=generation;c.revision=1;
  if c.author_id is not null and not exists(select 1 from auth.users where users.id=c.author_id) then c.author_id=null;end if;
  select coalesce(array_agg(distinct (e->>'recipient_id')::uuid order by (e->>'recipient_id')::uuid),'{}') into people
  from jsonb_array_elements(doc->'mentions') e where (e->>'recipient_id')::uuid=any(old_c.mention_ids)
   and taskfold_private.team_project_role((e->>'recipient_id')::uuid,p) is not null;
  c.mention_ids=people;
  insert into public.task_comments select (c).*;
  for value in select * from jsonb_array_elements(doc->'mentions') loop
   m=jsonb_populate_record(null::public.task_mentions,value);
   if m.recipient_id=any(people) then
    m.id=gen_random_uuid();m.comment_id=c.id;m.revision=1;
    insert into public.task_mentions select (m).*;
   end if;
  end loop;
 end loop;
 delete from taskfold_private.team_conversation_scope where transaction_id=txid_current() and request_id=q;
 delete from taskfold_private.team_conversation_keys where team_id=team and request_id=q;
 update taskfold_private.team_task_edits set conversation_state='restored' where team_id=team and request_id=q;
end$$;
revoke all on function taskfold_private.archive_team_conversation(uuid,uuid,uuid,uuid,uuid),taskfold_private.hold_team_conversation_auth(uuid,uuid,uuid),taskfold_private.assert_team_conversation_undo(uuid,uuid),taskfold_private.restore_team_conversation(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;

-- Bounded cleanup, receipt-before-key order. Restore and cleanup cannot both
-- consume a recovery copy. Runtime expiry is enforced even if cleanup is late.
create function taskfold_private.expire_team_conversations(batch_limit integer default 1000) returns integer
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare item record;removed integer:=0;begin
 if batch_limit is null or batch_limit not between 1 and 1000 then raise exception using errcode='22023',message='Invalid cleanup batch';end if;
 for item in select d.team_id,d.request_id from taskfold_private.team_conversation_keys k
  join taskfold_private.team_task_edits d using(team_id,request_id)
  where d.conversation_state='ready' and k.expires_at<=clock_timestamp()
  order by k.expires_at,d.team_id,d.request_id limit batch_limit for update of d skip locked loop
  delete from taskfold_private.team_conversation_keys where team_id=item.team_id and request_id=item.request_id and expires_at<=clock_timestamp();
  if found then update taskfold_private.team_task_edits set conversation_state='expired' where team_id=item.team_id and request_id=item.request_id;removed=removed+1;end if;
 end loop;
 return removed;
end$$;
revoke all on function taskfold_private.expire_team_conversations(integer) from public,anon,authenticated,service_role;

create function taskfold_private.purge_deleted_team_conversations() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.state='deleted' and old.state<>'deleted' then
  delete from taskfold_private.team_conversation_keys where team_id=old.id;
  update taskfold_private.team_task_edits set conversation_state='expired' where team_id=old.id and conversation_state='ready';
 end if;
 return new;
end$$;
create trigger aaa_team_conversation_purge before update on taskfold_private.teams for each row execute function taskfold_private.purge_deleted_team_conversations();
revoke all on function taskfold_private.purge_deleted_team_conversations() from public,anon,authenticated,service_role;

do $$begin if exists(select 1 from pg_extension where extname='pg_cron') then
 perform cron.schedule('taskfold-team-conversation-recovery','27 * * * *','select taskfold_private.expire_team_conversations(1000)');
end if;end$$;

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
 if t is not null and tg_table_name='task_comments' and tg_op in('INSERT','DELETE') then
  if tg_op='DELETE' and exists(select 1 from taskfold_private.team_conversation_scope c where c.transaction_id=txid_current() and c.team_id=t and c.actor_id=auth.uid()
   and c.operation='archive' and c.task_id=old.task_id and c.generation=old.task_generation and c.project_id=old.project_id) then return old;end if;
  if tg_op='INSERT' and exists(select 1 from taskfold_private.team_conversation_scope c where c.transaction_id=txid_current() and c.team_id=t and c.actor_id=auth.uid()
   and c.operation='restore' and c.task_id=new.task_id and c.generation=new.task_generation and c.project_id=new.project_id) then return new;end if;
 end if;
 if t is not null and not exists(select 1 from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t) then
  raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;



create or replace function taskfold_private.team_task_lifecycle(action text,b jsonb) returns jsonb
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
 if action='restore' then perform taskfold_private.hold_team_conversation_auth(team,restore_from,a);end if;
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
   if row.recurrence_parent_id is not null then select task_generation into parent_generation from public.tasks where tasks.id=row.recurrence_parent_id for key share;end if;
   hash=taskfold_private.team_task_restoration_hash(row);
   insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation,restoration_hash,parent_generation) values(team,q,a,fingerprint,id,generation,action,hash,parent_generation);
   perform taskfold_private.archive_team_conversation(team,p,id,generation,q);
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
   delete from taskfold_private.team_conversation_scope where transaction_id=txid_current() and request_id=q;
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
   perform taskfold_private.assert_team_conversation_undo(team,restore_from);
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
   perform taskfold_private.restore_team_conversation(team,restore_from,p,id,generation);
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
