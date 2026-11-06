-- Reviewed same-team transfers for opt-in record-authoritative roots.
-- Personal/cross-team adoption and normal rollout remain separate.
create function taskfold_private.child_record_move_index(tree jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare decoded jsonb;result jsonb;begin
 decoded:=taskfold_private.decode_child_task_tree(tree);
 if decoded->>'state'<>'ready' then raise exception using errcode='22023',message='Review this subtask layout before moving';end if;
 select coalesce(jsonb_object_agg(n->>'key',n->'fields'),'{}') into result from jsonb_array_elements(decoded->'nodes') n;
 return result;
end$$;
create function taskfold_private.child_record_move_clear(tree jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare item jsonb;result jsonb:='[]';begin
 if tree is null or tree='null'::jsonb then return tree;end if;
 -- Bounds/identity/container validation is performed by the move index before
 -- mutation. Recurse only actual arrays and preserve sparse/null containers.
 if jsonb_typeof(tree)<>'array' then raise exception using errcode='22023',message='Review this subtask layout before moving';end if;
 for item in select * from jsonb_array_elements(tree) loop
  item:=item-'assigned_to';
  if jsonb_typeof(item->'subtasks')='array' then item:=jsonb_set(item,'{subtasks}',taskfold_private.child_record_move_clear(item->'subtasks'));end if;
  result:=result||jsonb_build_array(item);
 end loop;return result;
end$$;
create or replace function taskfold_private.guard_child_record_scope() returns trigger
language plpgsql security definer set search_path='' as $$
declare a taskfold_private.child_task_record_authority;
begin
 select * into a from taskfold_private.child_task_record_authority where task_id=old.id;
 if not found or (new.task_generation is not distinct from old.task_generation and new.project_id is not distinct from old.project_id) then return new;end if;
 -- Only the existing actor/transaction/root/old-row/new-row-bound move scope
 -- authorizes transfer. No caller-set flag, SQL subject bypass or demotion.
 if new.task_generation is distinct from old.task_generation or a.task_generation is distinct from old.task_generation or a.project_id is distinct from old.project_id
  or not taskfold_private.team_task_move_authorized(old,new) then raise exception using errcode='PT409',message='Review this task before moving its subtasks to another project';end if;
 perform taskfold_private.prepare_child_record_tree(old.id,old.task_generation,new.subtasks);
 update taskfold_private.child_task_record_authority set project_id=new.project_id where task_id=old.id;
 return new;
end$$;
create or replace function taskfold_private.purge_child_structure_archives() returns trigger
language plpgsql security definer set search_path='' as $$begin
 -- A reviewed same-team move never republishes private deleted content. Its
 -- original receipt still binds source project/generation and current access;
 -- discovery/disposal remain actor-only, while root/account deletion cascades.
 if new.task_generation is not distinct from old.task_generation and taskfold_private.team_task_move_authorized(old,new) then return new;end if;
 delete from taskfold_private.child_task_structure_archives where task_id=new.id;
 return new;
end$$;
revoke all on function taskfold_private.child_record_move_index(jsonb),taskfold_private.child_record_move_clear(jsonb),taskfold_private.guard_child_record_scope(),taskfold_private.purge_child_structure_archives() from public,anon,authenticated,service_role;

-- The existing signed review, live roles, discussion custody and durable Undo
-- remain authoritative; only sparse traversal and private-archive policy change.
create or replace function taskfold_private.team_task_move(operation text,b jsonb) returns jsonb
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
  union select (n.value->>'assigned_to')::uuid from public.tasks root_task cross join lateral jsonb_each(taskfold_private.child_record_move_index(coalesce(root_task.subtasks,'[]'))) n where root_task.id=cmd.id and coalesce(n.value->>'assigned_to','')<>''
  union select original.assigned_to
  union select (n.value->>'assigned_to')::uuid from jsonb_each(taskfold_private.child_record_move_index(coalesce(original.subtasks,'[]'))) n where coalesce(n.value->>'assigned_to','')<>''
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
  select 1 from jsonb_each(taskfold_private.child_record_move_index(coalesce(t.subtasks,'[]'))) n where coalesce(n.value->>'assigned_to','')<>'' and not (n.value->>'assigned_to')::uuid=any(coalesce(people,'{}'))) then raise exception using errcode='PT409',message='Task assignments changed during review';end if;
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
  nodes=taskfold_private.child_record_move_index(coalesce(desired.subtasks,'[]'));
  if desired.assigned_to is not null then perform taskfold_private.team_task_member(desired.assigned_to,dest,desired.user_id);end if;
  for person in select (n.value->>'assigned_to')::uuid from jsonb_each(nodes) n where coalesce(n.value->>'assigned_to','')<>'' loop perform taskfold_private.team_task_member(person,dest,desired.user_id);end loop;
 else
  desired.section_id=null;desired.assigned_to=null;desired.subtasks=taskfold_private.child_record_move_clear(desired.subtasks);
 end if;
 nodes=taskfold_private.child_record_move_index(coalesce(t.subtasks,'[]'));
 cleared=case when t.assigned_to is not null and desired.assigned_to is null then 1 else 0 end+(select count(*) from jsonb_each(nodes) n where coalesce(n.value->>'assigned_to','')<>'' and coalesce(taskfold_private.child_record_move_index(coalesce(desired.subtasks,'[]'))->n.key->>'assigned_to','')='');
 restored=case when desired.assigned_to is not null and desired.assigned_to is distinct from t.assigned_to then 1 else 0 end+(select count(*) from jsonb_each(taskfold_private.child_record_move_index(coalesce(desired.subtasks,'[]'))) n where coalesce(n.value->>'assigned_to','')<>'' and coalesce(nodes->n.key->>'assigned_to','') is distinct from n.value->>'assigned_to');
 if reviewing then expires=to_char((clock_timestamp() at time zone 'UTC')+interval '30 minutes','YYYY-MM-DD"T"HH24:MI:SS"Z"');
 else
  expires=b->>'expires_at';
  if jsonb_typeof(b->'expires_at') is distinct from 'string' or expires !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
   or expires::timestamptz<=clock_timestamp() or expires::timestamptz>clock_timestamp()+interval '31 minutes' then raise exception using errcode='PT409',message='Review this task move again';end if;
 end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,team,id,generation,p,dest,related,state_hash,boundary->>'token',expires,to_jsonb(desired),'subtask_archive_policy_v1')::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 if reviewing then return jsonb_build_object('move_review_protocol',1,'account',a,'team_id',team,'task_id',id,'task_generation',generation,
  'source_project_id',p,'destination_project_id',dest,'related_request',related,'review_token',token,'expires_at',expires,
  'cleared_assignments',cleared,'restored_assignments',restored,'discussion_count',comments,'task',to_jsonb(t),
  'subtask_undo_policy','kept_private','subtask_undo_count',(select count(*) from taskfold_private.child_task_structure_archives ar where ar.task_id=id and ar.actor_id=a),
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

-- Preserve reviewed move Undo assignments while validating every actual child.
create or replace function taskfold_private.guard_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare child jsonb;
begin
 if tg_op='UPDATE' and new.user_id<>old.user_id then raise exception 'Task creator cannot be changed';end if;
 if tg_op='UPDATE' and new.project_id is distinct from old.project_id and not taskfold_private.team_task_move_authorized(old,new) then
  new.assigned_to:=null;new.subtasks:=taskfold_private.clear_assignee(new.subtasks,null);
 end if;
 if tg_op='INSERT' or new.assigned_to is distinct from old.assigned_to or new.project_id is distinct from old.project_id then
  perform taskfold_private.check_task_assignment(new.assigned_to::text,new.project_id,new.user_id);
 end if;
 if tg_op='INSERT' or new.subtasks is distinct from old.subtasks or new.project_id is distinct from old.project_id then
  for child in
   with recursive nodes(value) as (
    select value from jsonb_array_elements(case when jsonb_typeof(new.subtasks)='array' then new.subtasks else '[]'::jsonb end)
    union all
    select c.value from nodes cross join lateral jsonb_array_elements(case when jsonb_typeof(nodes.value->'subtasks')='array' then nodes.value->'subtasks' else '[]'::jsonb end) c(value)
   ) select value from nodes
  loop perform taskfold_private.check_task_assignment(child->>'assigned_to',new.project_id,new.user_id);end loop;
 end if;
 return new;
end $$;

-- Whole-project realm changes need a separate custody review for promoted
-- records and private deleted content. Never silently bypass that future review.
create function taskfold_private.guard_child_record_project_transfer() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if tg_op='UPDATE' and new.team_id is not distinct from old.team_id then return new;end if;
 if exists(select 1 from public.tasks t where t.project_id=new.project_id and
  (exists(select 1 from taskfold_private.child_task_record_authority a where a.task_id=t.id)
   or exists(select 1 from taskfold_private.child_task_structure_archives a where a.task_id=t.id))) then
  raise exception using errcode='PT409',message='Review subtask custody before transferring this project';end if;
 return new;
end$$;
create trigger a0_child_record_project_transfer before insert or update of team_id on taskfold_private.team_content_projects for each row execute function taskfold_private.guard_child_record_project_transfer();
revoke all on function taskfold_private.guard_child_record_project_transfer() from public,anon,authenticated,service_role;
