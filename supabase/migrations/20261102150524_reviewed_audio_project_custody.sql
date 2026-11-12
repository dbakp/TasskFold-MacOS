-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Undeployed candidate. Publication receipts and object paths remain immutable.
-- Only a signed, acknowledged same-team/project move changes live audience.
create table taskfold_private.audio_comment_custody (
 operation_id uuid primary key references taskfold_private.audio_comment_publications(operation_id) on delete cascade,
 object_id uuid not null unique,
 team_id uuid not null,
 task_id uuid not null,task_generation uuid not null,project_id uuid not null
);
create index audio_custody_task on taskfold_private.audio_comment_custody(task_id,task_generation,operation_id);
alter table taskfold_private.audio_comment_custody enable row level security;
revoke all on taskfold_private.audio_comment_custody from public,anon,authenticated,service_role;

create function taskfold_private.audio_bind_publication() returns trigger
language plpgsql security definer set search_path='' as $$
declare team uuid;asset storage.objects;
begin
 if new.state<>'published' or (tg_op='UPDATE' and old.state='published') then return new;end if;
 if not taskfold_private.is_team_content_task(new.task_id) then return new;end if;
 select c.team_id into team from public.tasks t join taskfold_private.team_content_tasks c on c.task_id=t.id and c.generation=t.task_generation and c.project_id=t.project_id
  where t.id=new.task_id and t.task_generation=new.task_generation and t.project_id=new.project_id for share of t,c;
 if not found or not taskfold_private.audio_bucket_ready() then raise exception using errcode='PT409',message='Review recording custody before publishing';end if;
 select * into asset from storage.objects where bucket_id='taskfold-audio-v1' and name=new.object_name for share;
 if not found or coalesce(to_jsonb(asset)->>'owner_id',to_jsonb(asset)->>'owner') is not null
  or asset.metadata->'size' is distinct from to_jsonb(new.byte_count) or asset.metadata->'mimetype' is distinct from '"audio/mp4"'::jsonb then
  raise exception using errcode='PT409',message='Verify this stored recording before publishing';end if;
 insert into taskfold_private.audio_comment_custody values(new.operation_id,asset.id,team,new.task_id,new.task_generation,new.project_id);
 return new;
end$$;
create trigger taskfold_bind_audio_publication after insert or update of state on taskfold_private.audio_comment_publications for each row execute function taskfold_private.audio_bind_publication();

create function taskfold_private.guard_audio_custody() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  if exists(select 1 from taskfold_private.audio_comment_publications r join public.tasks t on t.id=r.task_id and t.task_generation=r.task_generation and t.project_id=r.project_id
   join taskfold_private.team_content_tasks c on c.task_id=t.id and c.generation=t.task_generation and c.project_id=t.project_id
   join storage.objects o on o.id=new.object_id and o.bucket_id='taskfold-audio-v1' and o.name=r.object_name
   where r.operation_id=new.operation_id and r.state='published' and c.team_id=new.team_id and t.id=new.task_id and t.task_generation=new.task_generation and t.project_id=new.project_id) then return new;end if;
 elsif new.operation_id=old.operation_id and new.object_id=old.object_id and new.team_id=old.team_id and new.task_id=old.task_id and new.task_generation=old.task_generation then
  if new.project_id=old.project_id then return new;end if;
  if exists(select 1 from taskfold_private.team_task_move_scope s join public.tasks t on t.id=s.task_id and t.task_generation=s.generation
   join taskfold_private.team_content_projects p on p.project_id=new.project_id and p.team_id=old.team_id
   where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=old.team_id and s.task_id=old.task_id and s.generation=old.task_generation
    and s.source_project=old.project_id and s.destination_project=new.project_id and t.project_id=new.project_id
    and s.new_hash=encode(extensions.digest(convert_to(to_jsonb(t)::text,'UTF8'),'sha256'),'hex')) then return new;end if;
 end if;
 raise exception using errcode='42501',message='A reviewed recording transfer is required';
end$$;
create trigger guard_audio_custody before insert or update on taskfold_private.audio_comment_custody for each row execute function taskfold_private.guard_audio_custody();

create function taskfold_private.team_task_audio_inventory(t public.tasks) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare r taskfold_private.audio_comment_publications;c taskfold_private.audio_comment_custody;o storage.objects;items jsonb:='[]';
begin
 for r in select * from taskfold_private.audio_comment_publications where task_id=t.id and state in('pending','published') order by operation_id for update nowait loop
  if r.state='pending' then raise exception using errcode='PT409',message='Finish or stop pending recordings before moving this task';end if;
  select * into c from taskfold_private.audio_comment_custody where operation_id=r.operation_id for update nowait;
  if not found or c.task_id<>t.id or c.task_generation<>t.task_generation or c.project_id<>t.project_id or r.task_generation<>t.task_generation
   or not exists(select 1 from taskfold_private.team_content_projects p where p.project_id=t.project_id and p.team_id=c.team_id) then
   raise exception using errcode='PT409',message='These recordings need a separate custody review';end if;
  select * into o from storage.objects where id=c.object_id and bucket_id='taskfold-audio-v1' and name=r.object_name for share nowait;
  if not found or not taskfold_private.audio_bucket_ready() or coalesce(to_jsonb(o)->>'owner_id',to_jsonb(o)->>'owner') is not null
   or o.metadata->'size' is distinct from to_jsonb(r.byte_count) or o.metadata->'mimetype' is distinct from '"audio/mp4"'::jsonb then
   raise exception using errcode='PT409',message='A stored recording changed. Review its custody';end if;
  items:=items||jsonb_build_array(jsonb_build_object('publication',to_jsonb(r),'custody',to_jsonb(c),'storage',to_jsonb(o)));
  if jsonb_array_length(items)>20 then raise exception using errcode='54000',message='Too many recordings to review safely';end if;
 end loop;
 return items;
exception when lock_not_available then raise exception using errcode='PT409',message='Recordings are busy. Review this move again';
end$$;

-- Only the existing exact root move scope admits this exception. Pending,
-- unbound/legacy, cross-team and generation-changing transitions still refuse.
do $patch$
declare d text;anchor text:=' if tg_op=''UPDATE'' then';begin
 d:=pg_get_functiondef('taskfold_private.audio_task_custody()'::regprocedure);
 if strpos(d,'TASKFOLD_REVIEWED_AUDIO_MOVE_V1')=0 then
  if strpos(d,anchor)=0 then raise exception 'Current audio custody guard required';end if;
  d:=replace(d,anchor,$guard$
 -- TASKFOLD_REVIEWED_AUDIO_MOVE_V1
 if tg_op='UPDATE' and new.project_id is distinct from old.project_id and new.id=old.id and new.task_generation=old.task_generation
  and new.user_id=old.user_id and coalesce(to_jsonb(new)->'is_heading','false'::jsonb) in('false'::jsonb,'null'::jsonb)
  and taskfold_private.team_task_move_authorized(old,new) then
  perform taskfold_private.team_task_audio_inventory(old);return new;
 end if;
$guard$||anchor);execute d;
 end if;
 d:=pg_get_functiondef('taskfold_private.team_task_move_hash(public.tasks)'::regprocedure);
 anchor:='jsonb_build_array(/* TASKFOLD_TASK_FILE_HASH_V1 */';
 if strpos(d,anchor)=0 then raise exception 'Current file-aware task hash required';end if;
 execute replace(d,'taskfold_private.team_task_move_hash(','taskfold_private.team_task_move_before_audio_hash(');
 revoke all on function taskfold_private.team_task_move_before_audio_hash(public.tasks) from public,anon,authenticated,service_role;
 d:=pg_get_functiondef('taskfold_private.team_task_move(text,jsonb)'::regprocedure);
 anchor:=' stored_files jsonb;';if strpos(d,anchor)=0 then raise exception 'Current file-aware move required';end if;
 d:=replace(d,anchor,anchor||' stored_audio jsonb;');
 d:=replace(d,'''undoes'',''request_id'',''expires_at'',''review_token''))','''undoes'',''request_id'',''expires_at'',''review_token'',''audio_custody_ack''))');
 d:=replace(d,'reviewing and b ?| array[''request_id'',''expires_at'',''review_token'']','reviewing and b ?| array[''request_id'',''expires_at'',''review_token'',''audio_custody_ack'']');
 anchor:='stored_files:=taskfold_private.team_task_file_inventory(t);';if strpos(d,anchor)=0 then raise exception 'Current file inventory required';end if;
 d:=replace(d,anchor,anchor||$ack$
 stored_audio:=taskfold_private.team_task_audio_inventory(t);
 if not reviewing then
  if jsonb_array_length(stored_audio)>0 then
   if b->'audio_custody_ack' is distinct from jsonb_build_object('policy','published_same_generation_v1','count',jsonb_array_length(stored_audio)) then
    raise exception using errcode='PT409',message='Review the recordings and destination audience before moving';end if;
  elsif b ? 'audio_custody_ack' then raise exception using errcode='PT409',message='The recording inventory changed. Review this move again';end if;
 end if;
$ack$);
 anchor:='''file_custody_policy'',''task_bound_v1''';if strpos(d,anchor)=0 then raise exception 'Current file review required';end if;
 d:=replace(d,anchor,'''audio_custody_policy'',''published_same_generation_v1'',''audio_custody_count'',jsonb_array_length(stored_audio),'||anchor);
 anchor:='update taskfold_private.team_content_files set project_id=dest where task_id=cmd.id and task_generation=cmd.generation;';
 if strpos(d,anchor)=0 then raise exception 'Current file move required';end if;
 d:=replace(d,anchor,anchor||' update taskfold_private.audio_comment_custody c set project_id=dest where c.task_id=cmd.id and c.task_generation=cmd.generation and exists(select 1 from taskfold_private.audio_comment_publications r where r.operation_id=c.operation_id and r.state=''published'');');
 execute d;
end$patch$;

-- Preserve old hashes for empty media inventories, including saved Undo.
create or replace function taskfold_private.team_task_move_hash(t public.tasks) returns text
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
declare base text;items jsonb;result text;
begin
 base:=taskfold_private.team_task_move_before_audio_hash(t);
 items:=taskfold_private.team_task_audio_inventory(t);
 if jsonb_array_length(items)=0 then return base;end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array('task_audio_custody_v1',base,items)::text,'UTF8'),s.secret,'sha256'),'hex') into result
  from taskfold_private.automation_revision_secret s where singleton;
 return result;
end$$;

-- Reader metadata reflects the current audience; the immutable sender receipt
-- and path continue to use the original ledger. Project moves keep generation.
-- Whole-project audience changes need a separate review. A real project
-- deletion may cascade its binding; the existing task guard retires its media.
create function taskfold_private.guard_audio_project_realm() returns trigger
language plpgsql security definer set search_path='' as $$
declare p uuid;
begin
 if tg_op='UPDATE' and new.team_id=old.team_id then return new;end if;
 p:=case when tg_op='DELETE' then old.project_id else new.project_id end;
 if tg_op='DELETE' and not exists(select 1 from public.projects where id=p) then return old;end if;
 if exists(select 1 from taskfold_private.audio_comment_publications r left join taskfold_private.audio_comment_custody c on c.operation_id=r.operation_id
  where r.state in('pending','published') and (coalesce(c.project_id,r.project_id)=p or exists(select 1 from public.tasks t where t.id=r.task_id and t.project_id=p))) then
  raise exception using errcode='PT409',message='Review recording custody before changing this project audience';end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;
create trigger a0_audio_project_realm before insert or update of team_id or delete on taskfold_private.team_content_projects for each row execute function taskfold_private.guard_audio_project_realm();
revoke all on function taskfold_private.guard_audio_project_realm() from public,anon,authenticated,service_role;

create function taskfold_private.audio_live_receipt(r taskfold_private.audio_comment_publications,a uuid,p uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
 select taskfold_private.audio_receipt(r,a)||jsonb_build_object('target',jsonb_build_object('task_id',r.task_id,'task_generation',r.task_generation,'project_id',p))
$$;
create or replace function taskfold_private.audio_read_comment(a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare id uuid;original taskfold_private.audio_comment_publications;r taskfold_private.audio_comment_publications;p uuid;team uuid;
begin
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 if not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) then return jsonb_build_object('status','disabled');end if;
 perform taskfold_private.audio_fields(b,array['comment_id']);id:=taskfold_private.audio_uuid(b,'comment_id');
 select * into original from taskfold_private.audio_comment_publications where comment_id=id;
 if not found then return jsonb_build_object('status','unavailable');end if;
 select project_id,team_id into p,team from taskfold_private.audio_comment_custody where operation_id=original.operation_id;
 if not found then p:=original.project_id;
 elsif not exists(select 1 from taskfold_private.team_content_projects where project_id=p and team_id=team) then return jsonb_build_object('status','unavailable');end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||original.task_id::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) or not coalesce(taskfold_private.audio_read_scope(a,original.task_id,original.task_generation,p),false) then return jsonb_build_object('status','unavailable');end if;
 if p is distinct from original.project_id then
  perform 1 from taskfold_private.audio_comment_custody where operation_id=original.operation_id and project_id=p for share;
  if not found then return jsonb_build_object('status','unavailable');end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-operation:'||original.operation_id::text,20261028));
 select * into r from taskfold_private.audio_comment_publications where operation_id=original.operation_id and comment_id=id and state='published' for share;
 if not found then return jsonb_build_object('status','unavailable');end if;
 return taskfold_private.audio_live_receipt(r,a,p);
end$$;

-- Preserve the existing strict page/cursor/role checks and seek order.
do $patch$
declare d text;anchor text;begin
 d:=pg_get_functiondef('taskfold_private.audio_comment_page(uuid,uuid,jsonb)'::regprocedure);
 anchor:='taskfold_private.audio_receipt(q,a)';if strpos(d,anchor)=0 then raise exception 'Current audio page required';end if;
 d:=replace(d,anchor,'taskfold_private.audio_live_receipt(q,a,p)');
 anchor:='select * from taskfold_private.audio_comment_publications where task_id=t and task_generation=g and project_id is not distinct from p and state=''published''';
 if strpos(d,anchor)=0 then raise exception 'Current seek page required';end if;
 d:=replace(d,anchor,'select x.* from taskfold_private.audio_comment_publications x left join taskfold_private.audio_comment_custody c on c.operation_id=x.operation_id where x.task_id=t and x.task_generation=g and coalesce(c.project_id,x.project_id) is not distinct from p and x.state=''published'' and (c.operation_id is null or exists(select 1 from taskfold_private.team_content_projects z where z.project_id=c.project_id and z.team_id=c.team_id))');
 -- Joined tables both contain operation identity, but the seek/order columns
 -- remain unambiguous (only the publication carries publication time/comment).
 execute d;
 d:=pg_get_functiondef('taskfold_private.audio_comment_command(text,uuid,uuid,jsonb)'::regprocedure);
 anchor:='role text;';if strpos(d,anchor)=0 then raise exception 'Current team audio command required';end if;
 d:=replace(d,anchor,anchor||' live_project uuid;');
 anchor:=' if action is distinct from ''remove'' then';
 if strpos(d,anchor)=0 then raise exception 'Current team audio dispatch required';end if;
 d:=replace(d,anchor,' if action=''list'' then return taskfold_private.audio_comment_page(a,s,jsonb_build_object(''target'',b,''after'',null))-''next'';end if;'||anchor);
 anchor:=' if not taskfold_private.is_team_content_project(original.project_id) then';
 if strpos(d,anchor)=0 then raise exception 'Current audio removal required';end if;
 d:=replace(d,anchor,' select project_id into live_project from taskfold_private.audio_comment_custody where operation_id=original.operation_id; if not found then live_project:=original.project_id;end if; if not taskfold_private.is_team_content_project(live_project) then');
 d:=replace(d,'audio_team_scope(a,original.task_id,original.task_generation,original.project_id,true)','audio_team_scope(a,original.task_id,original.task_generation,live_project,true)');
 d:=replace(d,'team_project_role(a,original.project_id)','team_project_role(a,live_project)');
 execute d;
end$patch$;
revoke all on function taskfold_private.audio_bind_publication(),taskfold_private.guard_audio_custody(),taskfold_private.team_task_audio_inventory(public.tasks),taskfold_private.audio_live_receipt(taskfold_private.audio_comment_publications,uuid,uuid),taskfold_private.audio_read_comment(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
notify pgrst,'reload schema';

commit;
