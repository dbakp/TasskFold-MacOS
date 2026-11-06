-- Source-only same-team task moves with contents/access review and durable Undo.
-- Personal-project adoption and provider-bound file relocation remain separate.
-- No rollout flag, direct task policy or hosted configuration is enabled here.
alter table taskfold_private.team_task_edits drop constraint team_task_edits_operation_check;
alter table taskfold_private.team_task_edits add constraint team_task_edits_operation_check
 check(operation in('patch','create','delete','restore','move'));
create table taskfold_private.team_task_moves (
 team_id uuid not null,request_id uuid not null,actor_id uuid not null,
 task_id uuid not null,generation uuid not null,source_project uuid not null,destination_project uuid not null,
 action text not null check(action in('move','undo')),related_request uuid,reversed_by uuid,
 after_hash text not null,created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,request_id),foreign key(team_id,request_id) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
create index team_task_moves_actor_date on taskfold_private.team_task_moves(actor_id,created_at);
create table taskfold_private.team_task_move_undo (
 team_id uuid not null,request_id uuid not null,payload bytea not null,
 primary key(team_id,request_id),foreign key(team_id,request_id) references taskfold_private.team_conversation_keys(team_id,request_id) on delete cascade
);
create table taskfold_private.team_task_move_scope (
 transaction_id bigint not null,actor_id uuid not null,team_id uuid not null,task_id uuid not null,
 generation uuid not null,source_project uuid not null,destination_project uuid not null,old_hash text not null,new_hash text not null,
 primary key(transaction_id,task_id)
);
alter table taskfold_private.team_task_moves enable row level security;
alter table taskfold_private.team_task_move_undo enable row level security;
alter table taskfold_private.team_task_move_scope enable row level security;
revoke all on taskfold_private.team_task_moves,taskfold_private.team_task_move_undo,taskfold_private.team_task_move_scope from public,anon,authenticated,service_role;

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
 if t is not null and tg_op='UPDATE' then
  if tg_table_name='tasks' then
   if exists(select 1 from taskfold_private.team_task_move_scope s
   where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=t and s.task_id=old.id
    and s.generation=old.task_generation and new.id=old.id and new.task_generation=old.task_generation
    and old.project_id=s.source_project and new.project_id=s.destination_project
    and encode(extensions.digest(convert_to(to_jsonb(old)::text,'UTF8'),'sha256'),'hex')=s.old_hash
    and encode(extensions.digest(convert_to(to_jsonb(new)::text,'UTF8'),'sha256'),'hex')=s.new_hash) then return new;end if;
  elsif tg_table_name='task_comments' then
   if exists(select 1 from taskfold_private.team_task_move_scope s
   where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=t and s.task_id=old.task_id
    and s.generation=old.task_generation and old.project_id=s.source_project and new.project_id=s.destination_project
    and new.revision=old.revision+1
    and (to_jsonb(new)-array['project_id','revision'])=(to_jsonb(old)-array['project_id','revision'])) then return new;end if;
  end if;
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
create function taskfold_private.team_task_move_authorized(previous public.tasks, proposed public.tasks) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from taskfold_private.team_task_move_scope s
 where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.task_id=previous.id and s.generation=previous.task_generation
 and s.source_project=previous.project_id and s.destination_project=proposed.project_id
 and encode(extensions.digest(convert_to(to_jsonb(previous)::text,'UTF8'),'sha256'),'hex')=s.old_hash
 and encode(extensions.digest(convert_to(to_jsonb(proposed)::text,'UTF8'),'sha256'),'hex')=s.new_hash)
$$;
revoke all on function taskfold_private.team_task_move_authorized(public.tasks,public.tasks) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_task_move_authorized(public.tasks,public.tasks) to authenticated,service_role;
CREATE OR REPLACE FUNCTION taskfold_private.guard_task()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare child jsonb; grandchild jsonb;
begin
 if tg_op = 'UPDATE' and new.user_id <> old.user_id then raise exception 'Task creator cannot be changed'; end if;
 if tg_op = 'UPDATE' and new.project_id is distinct from old.project_id and not taskfold_private.team_task_move_authorized(old,new) then
   new.assigned_to := null; new.subtasks := taskfold_private.clear_assignee(new.subtasks,null);
 end if;
 if tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to or new.project_id is distinct from old.project_id then
   perform taskfold_private.check_task_assignment(new.assigned_to::text,new.project_id,new.user_id);
 end if;
 if tg_op = 'INSERT' or new.subtasks is distinct from old.subtasks or new.project_id is distinct from old.project_id then
   for child in select * from jsonb_array_elements(coalesce(new.subtasks,'[]')) loop
     perform taskfold_private.check_task_assignment(child->>'assigned_to',new.project_id,new.user_id);
     for grandchild in select * from jsonb_array_elements(coalesce(child->'subtasks','[]')) loop
       perform taskfold_private.check_task_assignment(grandchild->>'assigned_to',new.project_id,new.user_id);
     end loop;
   end loop;
 end if;
 return new;
end $function$;



-- Content/revision proof deliberately excludes mention read state: moving/Undo
-- never rewrites read history. Comment revisions fence old edit callbacks.
create function taskfold_private.team_task_move_hash(t public.tasks) returns text
language sql volatile security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.hmac(convert_to(jsonb_build_array(taskfold_private.team_completion_task_hash(t),
  coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from public.task_comments c where c.task_id=t.id),'[]'),
  coalesce((select jsonb_agg(to_jsonb(m)-array['read_at','revision'] order by m.id) from public.task_mentions m join public.task_comments c on c.id=m.comment_id where c.task_id=t.id),'[]'))::text,'UTF8'),s.secret,'sha256'),'hex')
 from taskfold_private.automation_revision_secret s where singleton
$$;
create function taskfold_private.team_task_move_reply(m taskfold_private.team_task_moves,replayed boolean) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',auth.uid(),'team_id',m.team_id,'request_id',m.request_id,'operation',m.action,
 'task_id',m.task_id,'task_generation',m.generation,'source_project_id',m.source_project,'destination_project_id',m.destination_project,
 'related_request',m.related_request,'replayed',replayed,'task',(select to_jsonb(t) from public.tasks t where t.id=m.task_id and t.task_generation=m.generation and t.project_id=m.destination_project))
$$;
create function taskfold_private.team_task_move(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;id uuid;generation uuid;p uuid;dest uuid;q uuid;related uuid;
 reviewing boolean;undoing boolean;boundary jsonb;token text;state_hash text;expires text;fingerprint text;key bytea;
 t public.tasks;desired public.tasks;original public.tasks;receipt taskfold_private.team_task_moves;prior taskfold_private.team_task_edits;
 origin taskfold_private.team_task_moves;source_project public.projects;destination_project public.projects;
 people uuid[];person uuid;nodes jsonb;item record;comments integer;cleared integer;restored integer;raw jsonb;payload bytea;
begin
 perform taskfold_private.team_actor();
 if operation is null or operation not in('review','move','review_undo','undo') then raise exception using errcode='22023',message='Choose a supported task move';end if;
 reviewing=operation in('review','review_undo');undoing=operation in('review_undo','undo');
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>16384
  or not b ?& array['team_id','task_id','task_generation','source_project_id','destination_project_id']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('team_id','task_id','task_generation','source_project_id','destination_project_id','undoes','request_id','expires_at','review_token'))
  or reviewing and b ?| array['request_id','expires_at','review_token']
  or not reviewing and not b ?& array['request_id','expires_at','review_token']
  or undoing is distinct from (b ? 'undoes') then raise exception using errcode='22023',message='Invalid task move';end if;
 team=taskfold_private.team_uuid(b,'team_id');id=taskfold_private.team_uuid(b,'task_id');generation=taskfold_private.team_uuid(b,'task_generation');
 p=taskfold_private.team_uuid(b,'source_project_id');dest=taskfold_private.team_uuid(b,'destination_project_id');
 if p=dest then raise exception using errcode='22023',message='Choose a different project';end if;
 if undoing then related=taskfold_private.team_uuid(b,'undoes');end if;
 if not reviewing then q=taskfold_private.team_uuid(b,'request_id');end if;
 -- Read permission before any recovery decryption, then hold all Auth participants
 -- before the workspace/team locks, matching role/account-removal lock order.
 if exists(select 1 from unnest(array[p,dest]) x where not exists(select 1 from taskfold_private.team_content_projects c where c.project_id=x and c.team_id=team)
  or coalesce(taskfold_private.team_project_role(a,x),'') not in('manager','editor')) then raise exception using errcode='42501',message='Editing access to both projects is required';end if;
 if undoing then
  select * into origin from taskfold_private.team_task_moves x where x.team_id=team and x.request_id=related and x.actor_id=a and x.task_id=id and x.generation=cmd.generation and x.source_project=dest and x.destination_project=p;
  if not found then raise exception using errcode='42501',message='Review the original task move';end if;
  select k.secret,u.payload into key,payload from taskfold_private.team_conversation_keys k join taskfold_private.team_task_move_undo u using(team_id,request_id)
   where k.team_id=team and k.request_id=related and k.expires_at>clock_timestamp();
  if found then original=jsonb_populate_record(null::public.tasks,extensions.pgp_sym_decrypt(payload,encode(key,'base64'))::jsonb);end if;
 end if;
 select array_agg(distinct u.person order by u.person) into people from (
  select c.author_id as person from public.task_comments c where c.task_id=cmd.id
  union select m.recipient_id from public.task_mentions m join public.task_comments c on c.id=m.comment_id where c.task_id=cmd.id
  union select root_task.assigned_to from public.tasks root_task where root_task.id=cmd.id
  union select (n.value->>'assigned_to')::uuid from public.tasks root_task cross join lateral jsonb_each(taskfold_private.automation_tree_index(coalesce(root_task.subtasks,'[]'))) n where root_task.id=cmd.id and coalesce(n.value->>'assigned_to','')<>''
  union select original.assigned_to
  union select (n.value->>'assigned_to')::uuid from jsonb_each(taskfold_private.automation_tree_index(coalesce(original.subtasks,'[]'))) n where coalesce(n.value->>'assigned_to','')<>''
 ) u where u.person is not null;
 if coalesce(cardinality(people),0)>2000 then raise exception using errcode='54000',message='This task has too many participants to review safely';end if;
 perform 1 from auth.users where users.id=any(coalesce(people,'{}')) order by users.id for share;
 boundary=taskfold_private.workspace_boundary();
 if not exists(select 1 from taskfold_private.teams where teams.id=team and state='active') then raise exception using errcode='PT503',message='This team is unavailable';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found or boundary->>'setup_paused'='true' then raise exception using errcode='PT503',message='Team task moves are not enabled';end if;
 perform 1 from taskfold_private.team_content_projects where project_id=any(array[p,dest]) order by project_id for share;
 perform 1 from public.projects where projects.id=any(array[p,dest]) order by projects.id for share;
 select * into source_project from public.projects where projects.id=p and not is_archived and not ancestor_archived;
 if not found then raise exception using errcode='PT409',message='The source project is unavailable';end if;
 select * into destination_project from public.projects where projects.id=dest and not is_archived and not ancestor_archived;
 if not found then raise exception using errcode='PT409',message='The destination project is unavailable';end if;
 if exists(select 1 from unnest(array[p,dest]) x where not exists(select 1 from taskfold_private.team_content_projects c where c.project_id=x and c.team_id=team)
  or coalesce(taskfold_private.team_project_role(a,x),'') not in('manager','editor')) then raise exception using errcode='42501',message='Project access changed';end if;
 if not reviewing then
  perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));
  select encode(extensions.hmac(convert_to(jsonb_build_array(a,operation,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
  if exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q) then raise exception using errcode='PT409',message='This action identity is already used';end if;
  select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;
  if found then
   if prior.operation<>'move' or prior.actor_id<>a or prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This action identity is already used';end if;
   select * into receipt from taskfold_private.team_task_moves where team_id=team and request_id=q;
   if not found then raise exception using errcode='PT409',message='This task move needs recovery';end if;
   return taskfold_private.team_task_move_reply(receipt,true);
  end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(id::text,78137));
 select * into t from public.tasks where tasks.id=cmd.id for update;
 if not found or t.project_id is distinct from p or t.task_generation is distinct from generation then raise exception using errcode='PT409',message='This task moved or was recreated';end if;
 if not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=cmd.id and c.generation=cmd.generation and c.team_id=team and c.project_id=p) then raise exception using errcode='42501',message='Task custody changed';end if;
 if octet_length(to_jsonb(t)::text)>128000 then raise exception using errcode='54000',message='This task is too large to move safely';end if;
 select count(*) into comments from public.task_comments where task_id=cmd.id;
 if comments>500 then raise exception using errcode='54000',message='This discussion is too large to move safely';end if;
 perform 1 from public.task_comments where task_id=cmd.id order by public.task_comments.id for update;
 perform 1 from public.task_mentions where comment_id in(select c.id from public.task_comments c where c.task_id=cmd.id) order by public.task_mentions.id for update;
 if exists(select 1 from public.task_comments c where c.task_id=cmd.id and (c.project_id<>p or c.task_generation<>generation or c.revision>=9007199254740991
  or c.author_id is not null and not c.author_id=any(coalesce(people,'{}'))))
  or exists(select 1 from public.task_mentions m join public.task_comments c on c.id=m.comment_id where c.task_id=cmd.id and not m.recipient_id=any(coalesce(people,'{}'))) then raise exception using errcode='PT409',message='The discussion changed during review';end if;
 if t.assigned_to is not null and not t.assigned_to=any(coalesce(people,'{}')) or exists(
  select 1 from jsonb_each(taskfold_private.automation_tree_index(coalesce(t.subtasks,'[]'))) n where coalesce(n.value->>'assigned_to','')<>'' and not (n.value->>'assigned_to')::uuid=any(coalesce(people,'{}'))) then raise exception using errcode='PT409',message='Task assignments changed during review';end if;
 -- Current Storage custody is per project, not per task. Never silently relocate
 -- a shared provider object or claim a new audience can access an old binding.
 if coalesce(jsonb_array_length(t.attachments),0)>0 and exists(select 1 from taskfold_private.team_content_files where project_id=p) then raise exception using errcode='PT409',message='These project-bound files need their own transfer review';end if;
 state_hash=taskfold_private.team_task_move_hash(t);
 desired=t;desired.project_id=dest;
 if undoing then
  -- Share the receipt-before-key lock used by recovery expiry and account purge.
  perform 1 from taskfold_private.team_task_edits where team_id=team and request_id=related for update;
  select * into origin from taskfold_private.team_task_moves where team_id=team and request_id=related for update;
  if origin.reversed_by is not null or original.id is null or origin.after_hash is distinct from state_hash
   or not exists(select 1 from taskfold_private.team_conversation_keys k where k.team_id=team and k.request_id=related and k.expires_at>clock_timestamp()) then raise exception using errcode='PT409',message='This task or discussion changed after the move';end if;
  desired.section_id=original.section_id;desired.assigned_to=original.assigned_to;desired.subtasks=original.subtasks;
  if desired.section_id is not null and not exists(select 1 from public.sections where sections.id=desired.section_id and project_id=dest) then raise exception using errcode='PT409',message='The original section is no longer available';end if;
  nodes=taskfold_private.automation_tree_index(coalesce(desired.subtasks,'[]'));
  if desired.assigned_to is not null then perform taskfold_private.team_task_member(desired.assigned_to,dest,desired.user_id);end if;
  for person in select (n.value->>'assigned_to')::uuid from jsonb_each(nodes) n where coalesce(n.value->>'assigned_to','')<>'' loop perform taskfold_private.team_task_member(person,dest,desired.user_id);end loop;
 else
  desired.section_id=null;desired.assigned_to=null;desired.subtasks=taskfold_private.clear_assignee(desired.subtasks,null);
 end if;
 nodes=taskfold_private.automation_tree_index(coalesce(t.subtasks,'[]'));
 cleared=case when t.assigned_to is not null and desired.assigned_to is null then 1 else 0 end+(select count(*) from jsonb_each(nodes) n where coalesce(n.value->>'assigned_to','')<>'' and coalesce(taskfold_private.automation_tree_index(coalesce(desired.subtasks,'[]'))->n.key->>'assigned_to','')='');
 restored=case when desired.assigned_to is not null and desired.assigned_to is distinct from t.assigned_to then 1 else 0 end+(select count(*) from jsonb_each(taskfold_private.automation_tree_index(coalesce(desired.subtasks,'[]'))) n where coalesce(n.value->>'assigned_to','')<>'' and coalesce(nodes->n.key->>'assigned_to','') is distinct from n.value->>'assigned_to');
 if reviewing then expires=to_char((clock_timestamp() at time zone 'UTC')+interval '30 minutes','YYYY-MM-DD"T"HH24:MI:SS"Z"');
 else
  expires=b->>'expires_at';
  if jsonb_typeof(b->'expires_at') is distinct from 'string' or expires !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
   or expires::timestamptz<=clock_timestamp() or expires::timestamptz>clock_timestamp()+interval '31 minutes' then raise exception using errcode='PT409',message='Review this task move again';end if;
 end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,team,id,generation,p,dest,related,state_hash,boundary->>'token',expires,to_jsonb(desired))::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 if reviewing then return jsonb_build_object('move_review_protocol',1,'account',a,'team_id',team,'task_id',id,'task_generation',generation,
  'source_project_id',p,'destination_project_id',dest,'related_request',related,'review_token',token,'expires_at',expires,
  'cleared_assignments',cleared,'restored_assignments',restored,'discussion_count',comments,'task',to_jsonb(t),
  'source_name',source_project.name,'destination_name',destination_project.name,
  'destination_visibility',(select visibility from taskfold_private.team_content_projects where project_id=dest));end if;
 if b->>'review_token' is distinct from token then raise exception using errcode='PT409',message='This task, discussion or project access changed after review';end if;
 perform pg_advisory_xact_lock(hashtextextended(a::text,25000653));
 if (select count(*) from taskfold_private.team_task_moves where actor_id=a and created_at>=date_trunc('day',clock_timestamp()))>=2000 then raise exception using errcode='PT429',message='The daily task move limit has been reached';end if;
 insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation,conversation_state) values(team,q,a,fingerprint,id,generation,'move','ready');
 key=extensions.gen_random_bytes(32);
 insert into taskfold_private.team_conversation_keys(team_id,request_id,secret) values(team,q,key);
 insert into taskfold_private.team_task_move_undo values(team,q,extensions.pgp_sym_encrypt(to_jsonb(t)::text,encode(key,'base64'),'cipher-algo=aes256,compress-algo=1'));
 insert into taskfold_private.team_task_move_scope values(txid_current(),a,team,id,generation,p,dest,
  encode(extensions.digest(convert_to(to_jsonb(t)::text,'UTF8'),'sha256'),'hex'),encode(extensions.digest(convert_to(to_jsonb(desired)::text,'UTF8'),'sha256'),'hex'));
 update public.tasks set project_id=desired.project_id,section_id=desired.section_id,assigned_to=desired.assigned_to,subtasks=desired.subtasks where tasks.id=cmd.id;
 update public.task_comments set project_id=dest,revision=revision+1 where task_id=cmd.id;
 delete from taskfold_private.team_task_move_scope where transaction_id=txid_current() and task_id=cmd.id;
 select * into t from public.tasks where tasks.id=cmd.id;
 insert into taskfold_private.team_task_moves(team_id,request_id,actor_id,task_id,generation,source_project,destination_project,action,related_request,after_hash)
  values(team,q,a,id,generation,p,dest,case when undoing then 'undo' else 'move' end,related,taskfold_private.team_task_move_hash(t)) returning * into receipt;
 if undoing then
  update taskfold_private.team_task_moves set reversed_by=q where team_id=team and request_id=related;
  delete from taskfold_private.team_conversation_keys where team_id=team and request_id=related;
  update taskfold_private.team_task_edits set conversation_state='restored' where team_id=team and request_id=related;
 end if;
 return taskfold_private.team_task_move_reply(receipt,false);
end$$;
create function public.taskfold_team_task_move(_operation text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$ select taskfold_private.team_task_move(_operation,_body) $$;
revoke all on function taskfold_private.team_task_move_hash(public.tasks),taskfold_private.team_task_move_reply(taskfold_private.team_task_moves,boolean) from public,anon,authenticated,service_role;
revoke all on function taskfold_private.team_task_move(text,jsonb),public.taskfold_team_task_move(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_task_move(text,jsonb),public.taskfold_team_task_move(text,jsonb) to authenticated;
