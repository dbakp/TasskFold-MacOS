-- Undeployed, separately disabled candidate. Original receipts and Storage paths
-- stay immutable. Certified Undo alone renews the current audience generation.
alter table taskfold_private.audio_comment_config add column restoration_enabled boolean not null default false;
create table taskfold_private.audio_task_deletions (
 team_id uuid not null,request_id uuid not null,actor_id uuid not null,
 task_id uuid not null,generation uuid not null,project_id uuid not null,
 operations uuid[] not null,inventory jsonb,
 expires_at timestamptz not null default clock_timestamp()+interval '30 days',
 primary key(team_id,request_id),
 foreign key(team_id,request_id) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
alter table taskfold_private.audio_task_deletions enable row level security;
revoke all on taskfold_private.audio_task_deletions from public,anon,authenticated,service_role;
create table taskfold_private.audio_task_restore_scope (
 transaction_id bigint not null,actor_id uuid not null,team_id uuid not null,
 task_id uuid not null,old_generation uuid not null,new_generation uuid not null,
 project_id uuid not null,operations uuid[] not null,
 primary key(transaction_id,task_id)
);
alter table taskfold_private.audio_task_restore_scope enable row level security;
revoke all on taskfold_private.audio_task_restore_scope from public,anon,authenticated,service_role;

create function taskfold_private.record_audio_task_deletion(t public.tasks,team uuid,request uuid,b jsonb) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare inventory jsonb;operations uuid[];
begin
 if not coalesce((select restoration_enabled from taskfold_private.audio_comment_config where singleton),false) then
  if b ? 'audio_restoration_ack' then raise exception using errcode='PT503',message='Recording restoration is not enabled';end if;return;
 end if;
 inventory:=taskfold_private.team_task_audio_inventory(t);
 if jsonb_array_length(inventory)=0 then
  if b ? 'audio_restoration_ack' then raise exception using errcode='PT409',message='The recording inventory changed. Review deletion again';end if;return;
 end if;
 if b->'audio_restoration_ack' is distinct from jsonb_build_object('policy','published_restore_v1','count',jsonb_array_length(inventory),'retention_days',30) then
  raise exception using errcode='PT409',message='Review the recordings and 30-day restoration period before deleting';end if;
 if not exists(select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid()
  and s.team_id=team and s.project_id=t.project_id and s.task_id=t.id and s.generation=t.task_generation and s.operation='delete') then
  raise exception using errcode='42501',message='A certified deletion is required';end if;
 select array_agg((x->'publication'->>'operation_id')::uuid order by x->'publication'->>'operation_id') into operations from jsonb_array_elements(inventory) x;
 insert into taskfold_private.audio_task_deletions(team_id,request_id,actor_id,task_id,generation,project_id,operations,inventory)
 values(team,request,auth.uid(),t.id,t.task_generation,t.project_id,operations,inventory);
end$$;

create function taskfold_private.prepare_audio_task_restore(t public.tasks,old_generation uuid,team uuid,request uuid,b jsonb) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare d taskfold_private.audio_task_deletions;x jsonb;r taskfold_private.audio_comment_publications;c taskfold_private.audio_comment_custody;o storage.objects;
begin
 select * into d from taskfold_private.audio_task_deletions where team_id=team and request_id=request for update;
 if not found then
  if b ? 'audio_restoration_ack' then raise exception using errcode='PT409',message='This deletion has no recording restoration review';end if;return;
 end if;
 if not coalesce((select restoration_enabled from taskfold_private.audio_comment_config where singleton),false) then raise exception using errcode='PT503',message='Recording restoration is not enabled';end if;
 if d.actor_id<>auth.uid() or d.task_id<>t.id or d.generation<>old_generation or d.project_id<>t.project_id then
  raise exception using errcode='PT409',message='Review the original recordings and their restoration period';end if;
 if not exists(select 1 from taskfold_private.team_task_edit_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid()
  and s.team_id=team and s.project_id=t.project_id and s.task_id=t.id and s.generation=t.task_generation and s.operation='create') then
  raise exception using errcode='42501',message='A certified restoration is required';end if;
 if d.expires_at<=clock_timestamp() or d.inventory is null then
  -- Explicitly recover the task alone only after fenced physical cleanup. A
  -- missing ledger row, absence response or expired lease is never proof.
  if b->'audio_restoration_ack' is distinct from jsonb_build_object('policy','expired_recordings_omitted_v1','count',cardinality(d.operations),'retention_days',30)
   or (select count(*) from taskfold_private.audio_comment_publications where operation_id=any(d.operations) and state='purged')<>cardinality(d.operations) then
   raise exception using errcode='PT409',message='These recordings expired. Confirm recovery without them after cleanup';end if;
  delete from taskfold_private.audio_task_deletions where team_id=team and request_id=request;return;
 end if;
 if b->'audio_restoration_ack' is distinct from jsonb_build_object('policy','published_restore_v1','count',cardinality(d.operations),'retention_days',30) then
  raise exception using errcode='PT409',message='Review the original recordings and their restoration period';end if;
 if not taskfold_private.audio_bucket_ready() then raise exception using errcode='PT409',message='The recording store is unavailable';end if;
 -- Take publication locks before scopes or mutations. A cleanup claim, changed
 -- object, removed author or independent retirement is never restoration proof.
 for x in select value from jsonb_array_elements(d.inventory) order by value->'publication'->>'operation_id' loop
  select * into r from taskfold_private.audio_comment_publications where operation_id=(x->'publication'->>'operation_id')::uuid for update nowait;
  if not found or r.state<>'retired' or r.cleanup_after is distinct from d.expires_at
   or (to_jsonb(r)-array['state','caption','audio_descriptor','cleanup_after','last_cleanup_at']) is distinct from ((x->'publication')-array['state','caption','audio_descriptor','cleanup_after','last_cleanup_at'])
   or exists(select 1 from taskfold_private.audio_upload_attempts where operation_id=r.operation_id and state='open')
   or exists(select 1 from taskfold_private.audio_cleanup_claims where operation_id=r.operation_id) then
   raise exception using errcode='PT409',message='A recording changed or cleanup has started. Review restoration';end if;
  select * into c from taskfold_private.audio_comment_custody where operation_id=r.operation_id for update nowait;
  if not found or to_jsonb(c) is distinct from x->'custody' then raise exception using errcode='PT409',message='Recording custody changed after deletion';end if;
  select * into o from storage.objects where id=c.object_id and bucket_id='taskfold-audio-v1' and name=r.object_name for share nowait;
  if not found or to_jsonb(o) is distinct from x->'storage' then raise exception using errcode='PT409',message='A stored recording changed after deletion';end if;
 end loop;
 insert into taskfold_private.audio_task_restore_scope values(txid_current(),auth.uid(),team,t.id,old_generation,t.task_generation,t.project_id,d.operations);
 update taskfold_private.audio_comment_custody set task_generation=t.task_generation where operation_id=any(d.operations);
 for x in select value from jsonb_array_elements(d.inventory) loop
  update taskfold_private.audio_comment_publications set state='published',caption=x->'publication'->>'caption',audio_descriptor=x->'publication'->'audio_descriptor',cleanup_after=null
   where operation_id=(x->'publication'->>'operation_id')::uuid;
 end loop;
 delete from taskfold_private.audio_task_deletions where team_id=team and request_id=request;
exception when lock_not_available then raise exception using errcode='PT409',message='Recordings are busy. Review restoration again';
end$$;

-- Scope checks supplement, never replace, the existing actor/role/root/Undo hash.
do $patch$
declare d text;anchor text;begin
 d:=pg_get_functiondef('taskfold_private.team_task_lifecycle(text,jsonb)'::regprocedure);
 anchor:='''task_type_lifecycle_protocol''))';if strpos(d,anchor)=0 then raise exception 'Current lifecycle fields required';end if;
 d:=replace(d,anchor,'''task_type_lifecycle_protocol'',''audio_restoration_ack''))');
 anchor:='perform taskfold_private.record_task_file_deletion(row,team,q);';if strpos(d,anchor)=0 then raise exception 'Current file deletion required';end if;
 d:=replace(d,anchor,anchor||' perform taskfold_private.record_audio_task_deletion(row,team,q,b);');
 anchor:='insert into public.tasks select (desired).* returning * into row;';if strpos(d,anchor)=0 then raise exception 'Current lifecycle insert required';end if;
 d:=replace(d,anchor,'if action=''restore'' then perform taskfold_private.prepare_audio_task_restore(desired,original.generation,team,original.request_id,b);elsif b ? ''audio_restoration_ack'' then raise exception using errcode=''22023'',message=''Unexpected recording restoration review'';end if; '||anchor||' delete from taskfold_private.audio_task_restore_scope where transaction_id=txid_current() and task_id=cmd.id;');execute d;
 d:=pg_get_functiondef('taskfold_private.audio_task_custody()'::regprocedure);
 anchor:=' if tg_op=''UPDATE'' then';if strpos(d,anchor)=0 then raise exception 'Current audio task guard required';end if;
 d:=replace(d,anchor,$guard$
 if tg_op='DELETE' and coalesce((select restoration_enabled from taskfold_private.audio_comment_config where singleton),false)
  and exists(select 1 from taskfold_private.team_content_projects where project_id=old.project_id)
  and exists(select 1 from taskfold_private.audio_comment_publications where task_id=old.id and state in('pending','published')) then
  if not exists(select 1 from taskfold_private.audio_task_deletions d join taskfold_private.team_task_edit_scope s on s.team_id=d.team_id and s.actor_id=d.actor_id and s.task_id=d.task_id and s.generation=d.generation
   where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.operation='delete' and d.task_id=old.id and d.generation=old.task_generation and d.project_id=old.project_id and d.inventory is not null and d.expires_at>clock_timestamp()) then
   raise exception using errcode='PT409',message='Use reviewed deletion to preserve these recordings';end if;
  update taskfold_private.audio_comment_publications r set state='retired',caption=null,audio_descriptor=null,cleanup_after=d.expires_at
   from taskfold_private.audio_task_deletions d where d.task_id=old.id and d.generation=old.task_generation and d.actor_id=auth.uid() and r.operation_id=any(d.operations) and r.state='published';return old;
 end if;
$guard$||anchor);execute d;
 d:=pg_get_functiondef('taskfold_private.guard_audio_custody()'::regprocedure);
 anchor:=' if tg_op=''INSERT'' then';if strpos(d,anchor)=0 then raise exception 'Current audio binding guard required';end if;
 d:=replace(d,anchor,$guard$
 if tg_op='UPDATE' and new.operation_id=old.operation_id and new.object_id=old.object_id and new.team_id=old.team_id and new.task_id=old.task_id and new.project_id=old.project_id
  and new.task_generation is distinct from old.task_generation and exists(select 1 from taskfold_private.audio_task_restore_scope s join taskfold_private.team_task_edit_scope e
   on e.transaction_id=s.transaction_id and e.actor_id=s.actor_id and e.task_id=s.task_id and e.generation=s.new_generation and e.team_id=s.team_id and e.project_id=s.project_id and e.operation='create'
   where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=old.team_id and s.task_id=old.task_id and s.project_id=old.project_id
    and s.old_generation=old.task_generation and s.new_generation=new.task_generation and old.operation_id=any(s.operations)) then return new;end if;
$guard$||anchor);execute d;
 d:=pg_get_functiondef('taskfold_private.audio_bind_publication()'::regprocedure);
 anchor:=' if new.state<>''published''';if strpos(d,anchor)=0 then raise exception 'Current audio publisher binding required';end if;
 d:=replace(d,anchor,$guard$
 if tg_op='UPDATE' and old.state='retired' and new.state='published' and exists(select 1 from taskfold_private.audio_task_restore_scope s join taskfold_private.audio_comment_custody c
  on c.operation_id=any(s.operations) and c.task_id=s.task_id and c.task_generation=s.new_generation and c.project_id=s.project_id and c.team_id=s.team_id
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and c.operation_id=new.operation_id) then return new;end if;
$guard$||anchor);execute d;
 d:=pg_get_functiondef('taskfold_private.team_task_audio_inventory(public.tasks)'::regprocedure);
 anchor:=' or r.task_generation<>t.task_generation';if strpos(d,anchor)=0 then raise exception 'Current audio inventory required';end if;
 d:=replace(d,anchor,'');d:=replace(d,'Finish or stop pending recordings before moving this task','Finish or stop pending recordings before continuing');d:=replace(d,'Recordings are busy. Review this move again','Recordings are busy. Review this action again');execute d;
 -- Only obsolete private caption snapshots are pruned. Existing fenced workers
 -- still own actual object deletion and quota release after the retention date.
 d:=pg_get_functiondef('taskfold_private.audio_maintenance(text,jsonb)'::regprocedure);
 anchor:=' if action=''probe'' then';if strpos(d,anchor)=0 then raise exception 'Current upload recovery required';end if;
 execute replace(d,anchor,' update taskfold_private.audio_task_deletions set inventory=null where expires_at<=clock_timestamp() and inventory is not null;'||anchor);
end$patch$;

-- Internal storage addressing is distinct from the live recipient generation.
-- The gateway strips storage_task_generation before returning any public receipt.
create or replace function taskfold_private.audio_live_receipt(r taskfold_private.audio_comment_publications,a uuid,p uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
 select taskfold_private.audio_receipt(r,a)||jsonb_build_object('target',jsonb_build_object('task_id',r.task_id,'task_generation',coalesce(c.task_generation,r.task_generation),'project_id',p))
  ||case when c.task_generation is distinct from r.task_generation and c.operation_id is not null then jsonb_build_object('storage_task_generation',r.task_generation) else '{}'::jsonb end
 from (select 1) one left join taskfold_private.audio_comment_custody c on c.operation_id=r.operation_id
$$;
do $patch$
declare d text;anchor text;begin
 d:=pg_get_functiondef('taskfold_private.audio_read_comment(uuid,uuid,jsonb)'::regprocedure);
 d:=replace(d,'p uuid;team uuid;','p uuid;team uuid;live_generation uuid;');
 d:=replace(d,'select project_id,team_id into p,team','select project_id,team_id,task_generation into p,team,live_generation');
 d:=replace(d,'then p:=original.project_id;','then p:=original.project_id;live_generation:=original.task_generation;');
 d:=replace(d,'audio_read_scope(a,original.task_id,original.task_generation,p)','audio_read_scope(a,original.task_id,live_generation,p)');
 d:=replace(d,'if p is distinct from original.project_id then','if p is distinct from original.project_id or live_generation is distinct from original.task_generation then');
 d:=replace(d,'and project_id=p for share','and project_id=p and task_generation=live_generation for share');execute d;
 d:=pg_get_functiondef('taskfold_private.audio_comment_page(uuid,uuid,jsonb)'::regprocedure);
 anchor:='where x.task_id=t and x.task_generation=g';if strpos(d,anchor)=0 then raise exception 'Current custody-aware seek required';end if;
 execute replace(d,anchor,'where x.task_id=t and coalesce(c.task_generation,x.task_generation)=g');
 d:=pg_get_functiondef('taskfold_private.audio_comment_command(text,uuid,uuid,jsonb)'::regprocedure);
 d:=replace(d,'live_project uuid;','live_project uuid; live_generation uuid;');
 d:=replace(d,'select project_id into live_project','select project_id,task_generation into live_project,live_generation');
 d:=replace(d,'then live_project:=original.project_id;','then live_project:=original.project_id;live_generation:=original.task_generation;');
 d:=replace(d,'audio_team_scope(a,original.task_id,original.task_generation,live_project,true)','audio_team_scope(a,original.task_id,live_generation,live_project,true)');execute d;
end$patch$;
revoke all on function taskfold_private.record_audio_task_deletion(public.tasks,uuid,uuid,jsonb),taskfold_private.prepare_audio_task_restore(public.tasks,uuid,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
