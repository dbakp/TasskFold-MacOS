-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Explicit completion after Undo. No hosted/client gate is enabled.
alter table taskfold_private.child_task_record_config add column archive_restore_finish_enabled boolean not null default false;
alter table taskfold_private.child_repair_restorations drop constraint child_repair_restorations_phase_check;
alter table taskfold_private.child_repair_restorations add constraint child_repair_restorations_phase_check check(phase in('restored','undone','finished','purged'));

create or replace function taskfold_private.review_child_restore(mode text,repair_request uuid,archive uuid,restoration uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();r taskfold_private.child_task_repairs;s taskfold_private.child_repair_restorations;t public.tasks;
 original jsonb;current_state jsonb;target jsonb;payload jsonb;enabled boolean;sql_null boolean;revision bigint;restore_key uuid;files jsonb:='[]';retained_bytes integer;availability text;
begin
 perform taskfold_private.team_actor();
 if mode is null or mode not in('restore','undo','redo','finish') or repair_request is null or archive is null or (mode='restore')<>(restoration is null) then raise exception using errcode='22023',message='Choose an original restoration action';end if;
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
  select case when mode='finish' then archive_restore_finish_enabled else archive_restore_reversals_enabled end into enabled from taskfold_private.child_task_record_config where singleton;
 end if;
 current_state:=taskfold_private.child_restore_snapshot(t);
 if mode='finish' then
  -- Finishing keeps today's editable work, including edits made after Undo.
  -- It never adopts the older malformed tree or removes live authored history.
  if s.workspace_id is null then
   if t.user_id<>actor then raise exception using errcode='42501',message='Only the storage owner can finish this recovery';end if;
  else
   perform 1 from taskfold_private.teams where id=s.workspace_id and state<>'deleted' for share nowait;
   if not found then raise exception using errcode='42501',message='This workspace is unavailable';end if;
   perform 1 from taskfold_private.team_members where team_id=s.workspace_id and user_id=actor for share nowait;
   if not found or coalesce(taskfold_private.team_role(s.workspace_id,actor),'') not in('owner','admin') then raise exception using errcode='42501',message='Workspace administration is required to finish retained recovery';end if;
  end if;
  target:=current_state->'tree';sql_null:=(current_state->>'sql_null')::boolean;
 end if;
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

 if mode in('undo','redo') and taskfold_private.child_restore_digest(current_state)<>s.current_digest then raise exception using errcode='PT409',message='Subtask work changed; keep its newer version';end if;
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',actor,'task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'workspace_id',current_state->'workspace_id',
  'repair_request_id',repair_request,'archive_id',archive,'archive_digest',case when mode='restore' then r.archive_digest else s.archive_digest end,'mode',mode,'restore_id',restore_key,'revision',revision,
  'review_digest',taskfold_private.child_restore_digest(jsonb_build_object('source',current_state,'files',files)),'enabled',availability='ready','availability',availability,'retention_bytes',retained_bytes,'file_count',jsonb_array_length(files),'current_source',current_state->'tree','current_sql_null',current_state->'sql_null','target_source',target,'target_sql_null',sql_null,
  '__history_counts',taskfold_private.child_restore_history_counts(t.id));
end$$;

create or replace function taskfold_private.commit_child_restore(operation text,b jsonb) returns jsonb
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
  or jsonb_typeof(b->'mode') is distinct from 'string' or b->>'mode' not in('restore','undo','redo','finish')
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
 perform 1 from taskfold_private.child_task_record_config where singleton and case when b->>'mode'='finish' then archive_restore_finish_enabled else archive_restore_reversals_enabled and (b->>'mode'<>'restore' or archive_restore_enabled) end for share nowait;
 if not found then raise exception using errcode='PT503',message='This restoration action is paused';end if;
 if exists(select 1 from jsonb_each(review-'enabled'-'current_source'-'current_sql_null'-'target_source'-'target_sql_null'-'availability'-'retention_bytes'-'file_count'-'__history_counts') e where b->e.key is distinct from e.value) then raise exception using errcode='PT409',message='This structure changed; review it again';end if;
 t:=taskfold_private.child_restore_root((b->>'task_id')::uuid,(b->>'task_generation')::uuid,(b->>'project_id')::uuid,(b->>'workspace_id')::uuid);
 team:=(b->>'workspace_id')::uuid;before_state:=taskfold_private.child_restore_snapshot(t);target:=review->'target_source';sql_null:=(review->>'target_sql_null')::boolean;
 if b->>'mode'='finish' then
  restore_key:=(b->>'restore_id')::uuid;
  select * into s from taskfold_private.child_repair_restorations where actor_id=actor and restore_id=restore_key for update nowait;
  if not found or s.phase<>'undone' or s.revision<>(b->>'revision')::bigint then raise exception using errcode='PT409',message='Review the latest recovery before finishing';end if;
  -- Remove only the inverse payload and its retention pins. Storage objects,
  -- the original repair archive, current records/projection/authority and task
  -- history are independent and are deliberately left byte-for-byte intact.
  delete from taskfold_private.child_repair_restore_payloads where actor_id=actor and restore_id=restore_key;
  if not found then raise exception using errcode='PT409',message='This retained recovery changed';end if;
  next_revision:=s.revision+1;
  after_state:=taskfold_private.child_restore_snapshot(t);perform taskfold_private.team_actor();
  update taskfold_private.child_repair_restorations set phase='finished',revision=next_revision,current_digest=taskfold_private.child_restore_digest(after_state) where actor_id=actor and restore_id=restore_key;
  reply:=b||jsonb_build_object('state','applied','replayed',false,'restoration_id',restore_key,'next_revision',next_revision,'phase','finished','after_digest',taskfold_private.child_restore_digest(after_state));
  insert into taskfold_private.child_repair_restore_requests(actor_id,request_id,team_id,fingerprint,reply) values(actor,q,team,fingerprint,reply);
  return reply||jsonb_build_object('__history_counts',taskfold_private.child_restore_history_counts(t.id));
 end if;
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

-- Existing invoker wrappers and least-privilege grants are retained by replacement.
revoke all on function taskfold_private.review_child_restore(text,uuid,uuid,uuid),taskfold_private.commit_child_restore(text,jsonb) from public,anon,service_role;
grant execute on function taskfold_private.review_child_restore(text,uuid,uuid,uuid),taskfold_private.commit_child_restore(text,jsonb) to authenticated;

commit;
