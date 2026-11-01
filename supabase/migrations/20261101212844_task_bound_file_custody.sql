-- Candidate only: task-bound attachment metadata follows the reviewed same-team
-- move. No Storage bytes/paths are changed; legacy project-only files stay closed.
alter table taskfold_private.team_content_files
 add column task_id uuid,
 add column task_generation uuid,
 add constraint team_file_task_pair check((task_id is null)=(task_generation is null));
create index team_content_files_task on taskfold_private.team_content_files(task_id,task_generation,object_id) where task_id is not null;

-- Inspect only known attachment locations. Typed references are immutable Storage
-- object identities, never URL parsing or a client assertion of ownership.
create function taskfold_private.task_file_references(document jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare stack jsonb[]:=array[document];doc jsonb;items jsonb;item jsonb;c jsonb;ids uuid[]:='{}';id uuid;legacy boolean:=false;nodes integer:=0;refs integer:=0;result jsonb;
begin
 if document is null or octet_length(document::text)>4194304 then raise exception using errcode='54000',message='Review these task files before moving';end if;
 while cardinality(stack)>0 loop
  doc:=stack[cardinality(stack)];stack:=stack[1:cardinality(stack)-1];nodes:=nodes+1;
  if nodes>1001 then raise exception using errcode='54000',message='Review these task files before moving';end if;
  if jsonb_typeof(doc)<>'object' then continue;end if;
  items:='[]';
  if jsonb_typeof(doc->'attachments')='array' then items:=doc->'attachments';
  elsif coalesce(doc->'attachments','null')<>'null'::jsonb then legacy:=true;end if;
  if jsonb_typeof(doc->'comments')='array' then
   for c in select * from jsonb_array_elements(doc->'comments') loop
    if coalesce(c->'attachment','null')<>'null'::jsonb then items:=items||jsonb_build_array(c->'attachment');end if;
   end loop;
  end if;
  for item in select * from jsonb_array_elements(items) loop
   refs:=refs+1;if refs>1024 then raise exception using errcode='54000',message='Review these task files before moving';end if;
   if item ? 'storage_object_id' then
    if jsonb_typeof(item->'storage_object_id') is distinct from 'string' or (item->>'storage_object_id') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then raise exception using errcode='22023',message='Review this stored attachment reference';end if;
    id:=(item->>'storage_object_id')::uuid;ids:=array_append(ids,id);
   elsif jsonb_typeof(item->'url')='string' and left(item->>'url',5)='data:' then null;
   else legacy:=true;end if;
  end loop;
  if jsonb_typeof(doc->'subtasks')='array' then
   for item in select * from jsonb_array_elements(doc->'subtasks') loop stack:=array_append(stack,item);end loop;
  end if;
 end loop;
 select coalesce(jsonb_agg(x::text order by x),'[]') into result from(select distinct unnest(ids) x)s;
 if jsonb_array_length(result)>256 then raise exception using errcode='54000',message='Review these task files before moving';end if;
 return jsonb_build_object('ids',result,'legacy',legacy);
end$$;

-- Root lock precedes sorted file/object locks. Busy content asks for fresh review
-- rather than waiting behind another root/file transaction with a stale snapshot.
create function taskfold_private.team_task_file_inventory(t public.tasks) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare refs jsonb;f taskfold_private.team_content_files;o storage.objects;b storage.buckets;result jsonb:='[]';
begin
 refs:=taskfold_private.task_file_references(to_jsonb(t));
 if (refs->>'legacy')::boolean and exists(select 1 from taskfold_private.team_content_files where project_id=t.project_id) then
  raise exception using errcode='PT409',message='These project-bound files need their own transfer review';end if;
 for f in select * from taskfold_private.team_content_files where task_id=t.id order by object_id for update nowait loop
  if f.task_generation is distinct from t.task_generation or f.project_id is distinct from t.project_id or not (refs->'ids' ? f.object_id::text) then
   raise exception using errcode='PT409',message='Finish or review this task’s attachment changes before moving';end if;
  select * into o from storage.objects where id=f.object_id for share nowait;
  if not found or o.bucket_id<>'task-attachments' then raise exception using errcode='PT409',message='A stored attachment is unavailable';end if;
  select * into b from storage.buckets where id=o.bucket_id for share nowait;
  if not found or b.public then raise exception using errcode='PT409',message='Stored attachments must remain private';end if;
  result:=result||jsonb_build_array(jsonb_build_object('object_id',f.object_id,'project_id',f.project_id,'task_id',f.task_id,'task_generation',f.task_generation,
   'bucket_id',o.bucket_id,'name',o.name,'owner',o.owner,'owner_id',o.owner_id,'metadata',to_jsonb(o)->'metadata','version',to_jsonb(o)->'version'));
 end loop;
 if jsonb_array_length(result)<>jsonb_array_length(refs->'ids') then raise exception using errcode='PT409',message='Review the ownership of these stored attachments';end if;
 return result;
exception when lock_not_available then raise exception using errcode='PT409',message='The stored files are busy. Review this move again';
end$$;

-- Certified deletion Undo renews the attachment incarnation atomically with
-- the existing task restoration. A replacement task cannot borrow old grants.
create table taskfold_private.team_task_file_restore_scope (
 transaction_id bigint not null,actor_id uuid not null,team_id uuid not null,
 task_id uuid not null,old_generation uuid not null,new_generation uuid not null,
 project_id uuid not null,objects uuid[] not null,
 primary key(transaction_id,task_id)
);
alter table taskfold_private.team_task_file_restore_scope enable row level security;
revoke all on taskfold_private.team_task_file_restore_scope from public,anon,authenticated,service_role;
create table taskfold_private.team_task_file_deletions (
 team_id uuid not null,request_id uuid not null,actor_id uuid not null,
 task_id uuid not null,generation uuid not null,project_id uuid not null,inventory_hash text not null,
 primary key(team_id,request_id),
 foreign key(team_id,request_id) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
alter table taskfold_private.team_task_file_deletions enable row level security;
revoke all on taskfold_private.team_task_file_deletions from public,anon,authenticated,service_role;
create function taskfold_private.record_task_file_deletion(t public.tasks,team uuid,request uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare inventory jsonb;
begin
 if not exists(select 1 from taskfold_private.team_content_files where task_id=t.id) then return;end if;
 if not exists(select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid()
   and s.team_id=team and s.project_id=t.project_id and s.task_id=t.id and s.generation=t.task_generation and s.operation='delete') then
  raise exception using errcode='42501',message='A certified task deletion is required';end if;
 inventory:=taskfold_private.team_task_file_inventory(t);
 insert into taskfold_private.team_task_file_deletions values(team,request,auth.uid(),t.id,t.task_generation,t.project_id,
  encode(extensions.digest(convert_to(inventory::text,'UTF8'),'sha256'),'hex'));
end$$;
revoke all on function taskfold_private.record_task_file_deletion(public.tasks,uuid,uuid) from public,anon,authenticated,service_role;
create function taskfold_private.prepare_task_file_restore(t public.tasks,old_generation uuid,team uuid,deleted_request uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare previous public.tasks;inventory jsonb;objects uuid[];
begin
 if not exists(select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid()
   and s.team_id=team and s.project_id=t.project_id and s.task_id=t.id and s.generation=t.task_generation and s.operation='create') then
  raise exception using errcode='42501',message='A certified task restoration is required';end if;
 if not exists(select 1 from taskfold_private.team_content_files where task_id=t.id) then return;end if;
 previous:=t;previous.task_generation:=old_generation;inventory:=taskfold_private.team_task_file_inventory(previous);
 if not exists(select 1 from taskfold_private.team_task_file_deletions d where d.team_id=team and d.request_id=deleted_request
   and d.actor_id=auth.uid() and d.task_id=t.id and d.generation=old_generation and d.project_id=t.project_id
   and d.inventory_hash=encode(extensions.digest(convert_to(inventory::text,'UTF8'),'sha256'),'hex')) then
  raise exception using errcode='PT409',message='The stored files changed after deletion. Review their restoration';end if;
 if jsonb_array_length(inventory)=0 then return;end if;
 select array_agg((f->>'object_id')::uuid order by f->>'object_id') into objects from jsonb_array_elements(inventory) f;
 insert into taskfold_private.team_task_file_restore_scope values(txid_current(),auth.uid(),team,t.id,old_generation,t.task_generation,t.project_id,objects);
 update taskfold_private.team_content_files f set task_generation=t.task_generation where f.task_id=t.id and f.task_generation=old_generation;
end$$;
revoke all on function taskfold_private.prepare_task_file_restore(public.tasks,uuid,uuid,uuid) from public,anon,authenticated,service_role;

-- The table remains private. Only a future trusted upload/admission path may
-- create a task binding; existing project-only custody is never guessed/upgraded.
do $migration$
declare d text;anchor text:=' if tg_op=''UPDATE'' and new is distinct from old then';begin
 d:=pg_get_functiondef('taskfold_private.guard_team_content_file()'::regprocedure);
 if strpos(d,'TASKFOLD_TASK_FILE_GUARD_V1')=0 then
  if strpos(d,anchor)=0 then raise exception 'Current file custody guard required';end if;
  d:=replace(d,anchor,$guard$
 -- TASKFOLD_TASK_FILE_GUARD_V1
 if tg_op='INSERT' and new.task_id is not null then
  if not exists(select 1 from public.tasks t join taskfold_private.team_content_tasks c on c.task_id=t.id and c.generation=t.task_generation and c.project_id=t.project_id
    where t.id=new.task_id and t.task_generation=new.task_generation and t.project_id=new.project_id) then
   raise exception using errcode='PT409',message='The attachment task or generation changed';end if;
 end if;
 if tg_op='UPDATE' and new is distinct from old and old.task_id is not null
    and new.object_id=old.object_id and new.task_id=old.task_id and new.project_id=old.project_id
    and new.task_generation is distinct from old.task_generation
    and exists(select 1 from taskfold_private.team_task_file_restore_scope r join taskfold_private.team_task_edit_scope e
      on e.transaction_id=r.transaction_id and e.task_id=r.task_id and e.actor_id=r.actor_id and e.generation=r.new_generation and e.operation='create'
      where r.transaction_id=txid_current() and r.actor_id=auth.uid() and r.task_id=old.task_id and r.old_generation=old.task_generation
        and r.new_generation=new.task_generation and r.project_id=old.project_id and old.object_id=any(r.objects)) then return new;end if;
 if tg_op='UPDATE' and new is distinct from old and old.task_id is not null
    and new.object_id=old.object_id and new.task_id=old.task_id and new.task_generation=old.task_generation then
  if exists(select 1 from taskfold_private.team_task_move_scope s join public.tasks t on t.id=s.task_id and t.task_generation=s.generation
    join taskfold_private.team_content_projects p on p.project_id=old.project_id and p.team_id=s.team_id
    join taskfold_private.team_content_projects q on q.project_id=new.project_id and q.team_id=s.team_id
    where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.task_id=old.task_id and s.generation=old.task_generation
      and s.source_project=old.project_id and s.destination_project=new.project_id and t.project_id=new.project_id
      and encode(extensions.digest(convert_to(to_jsonb(t)::text,'UTF8'),'sha256'),'hex')=s.new_hash) then return new;end if;
 end if;
$guard$||anchor);
  execute d;
 end if;
end$migration$;

create function taskfold_private.guard_task_file_reference() returns trigger
language plpgsql security definer set search_path='' as $$
declare id uuid;f taskfold_private.team_content_files;refs jsonb;
begin
 -- Ordinary personal roots retain their existing shape/size semantics.
 if not taskfold_private.is_team_content_project(new.project_id)
    and not exists(select 1 from taskfold_private.team_content_files where task_id=new.id) then return new;end if;
 refs:=taskfold_private.task_file_references(to_jsonb(new));
 for id in select value::uuid from jsonb_array_elements_text(refs->'ids') order by value loop
  select * into f from taskfold_private.team_content_files where object_id=id for update nowait;
  if not found or f.task_id is distinct from new.id or f.task_generation is distinct from new.task_generation then
   raise exception using errcode='PT409',message='This stored attachment belongs to another task or generation';end if;
  if f.project_id is distinct from new.project_id and (tg_op<>'UPDATE' or not taskfold_private.team_task_move_authorized(old,new)) then
   raise exception using errcode='PT409',message='Review this task’s stored files before moving';end if;
 end loop;
 return new;
exception when lock_not_available then raise exception using errcode='PT409',message='The stored files are busy. Try this edit again';
end$$;
create trigger taskfold_guard_task_file_reference before insert or update of attachments,comments,subtasks,project_id,task_generation on public.tasks for each row execute function taskfold_private.guard_task_file_reference();

create or replace function taskfold_private.team_native_file_read(o uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from taskfold_private.team_content_files f join storage.objects s on s.id=f.object_id
 join storage.buckets b on b.id=s.bucket_id and not b.public and b.id='task-attachments'
 where f.object_id=o and taskfold_private.team_native_project_read(f.project_id)
 and (f.task_id is null or exists(select 1 from public.tasks t where t.id=f.task_id and t.task_generation=f.task_generation and t.project_id=f.project_id)))
$$;

-- Extend the existing signed root/discussion hash with exact file custody and
-- Storage identity metadata. No service signature, ACL or caller-set GUC changes.
do $migration$
declare d text;anchor text:='jsonb_build_array(taskfold_private.team_completion_task_hash(t),';begin
 d:=pg_get_functiondef('taskfold_private.team_task_move_hash(public.tasks)'::regprocedure);
 if strpos(d,'TASKFOLD_TASK_FILE_HASH_V1')=0 then
  if strpos(d,anchor)=0 then raise exception 'Current signed task move hash required';end if;
  execute replace(d,anchor,'jsonb_build_array(/* TASKFOLD_TASK_FILE_HASH_V1 */ taskfold_private.team_task_file_inventory(t),taskfold_private.team_completion_task_hash(t),');
 end if;
 d:=pg_get_functiondef('taskfold_private.team_task_move(text,jsonb)'::regprocedure);
 if strpos(d,'TASKFOLD_TASK_FILE_MOVE_V1')=0 then
  anchor:='people uuid[];person uuid;nodes jsonb;item record;comments integer;cleared integer;restored integer;raw jsonb;payload bytea;';
  if strpos(d,anchor)=0 then raise exception 'Current reviewed child/task move required';end if;
  d:=replace(d,anchor,anchor||' stored_files jsonb;');
  anchor:=$anchor$if coalesce(jsonb_array_length(t.attachments),0)>0 and exists(select 1 from taskfold_private.team_content_files where project_id=p) then raise exception using errcode='PT409',message='These project-bound files need their own transfer review';end if;$anchor$;
  if strpos(d,anchor)=0 then raise exception 'Current legacy file refusal required';end if;
  d:=replace(d,anchor,'/* TASKFOLD_TASK_FILE_MOVE_V1 */ stored_files:=taskfold_private.team_task_file_inventory(t);');
  anchor:='''subtask_undo_policy'',''kept_private'',''subtask_undo_count''';
  if strpos(d,anchor)=0 then raise exception 'Current custody review required';end if;
  d:=replace(d,anchor,'''file_custody_policy'',''task_bound_v1'',''file_custody_count'',jsonb_array_length(stored_files),'||anchor);
  anchor:='update public.task_comments set project_id=dest,revision=revision+1 where task_id=cmd.id;';
  if strpos(d,anchor)=0 then raise exception 'Current discussion move required';end if;
  d:=replace(d,anchor,anchor||' update taskfold_private.team_content_files set project_id=dest where task_id=cmd.id and task_generation=cmd.generation;');
  execute d;
 end if;
end$migration$;
do $migration$
declare d text;anchor text:='insert into public.tasks select (desired).* returning * into row;';begin
 d:=pg_get_functiondef('taskfold_private.team_task_lifecycle(text,jsonb)'::regprocedure);
 if strpos(d,'TASKFOLD_TASK_FILE_RESTORE_V1')=0 then
  if strpos(d,anchor)=0 then raise exception 'Current certified task lifecycle required';end if;
  d:=replace(d,anchor,'/* TASKFOLD_TASK_FILE_RESTORE_V1 */ if action=''restore'' then perform taskfold_private.prepare_task_file_restore(desired,original.generation,team,original.request_id);end if; '
    ||anchor||' delete from taskfold_private.team_task_file_restore_scope where transaction_id=txid_current() and task_id=cmd.id;');
  anchor:='delete from public.tasks where tasks.id=cmd.id;';
  if strpos(d,anchor)=0 then raise exception 'Current certified task deletion required';end if;
  d:=replace(d,anchor,'perform taskfold_private.record_task_file_deletion(row,team,q); '||anchor);
  execute d;
 end if;
end$migration$;
revoke all on function taskfold_private.task_file_references(jsonb),taskfold_private.team_task_file_inventory(public.tasks),taskfold_private.guard_task_file_reference() from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
