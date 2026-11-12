-- Explicitly keep an older restored structure editable; no rollout is enabled.
alter table taskfold_private.child_task_record_config add column archive_restore_adoption_enabled boolean not null default false;
alter table taskfold_private.child_repair_restorations drop constraint child_repair_restorations_phase_check;
alter table taskfold_private.child_repair_restorations add constraint child_repair_restorations_phase_check check(phase in('restored','undone','finished','adopted','purged'));
alter table taskfold_private.child_repair_restorations add column adopted_actor_id uuid,add column adopted_request_id uuid,add column adopted_archive_id uuid;
create table taskfold_private.child_adoption_archive_files(
 archive_id uuid not null references taskfold_private.child_task_repair_originals(id) on delete cascade,
 object_id uuid not null references storage.objects(id) on delete restrict,primary key(archive_id,object_id)
);
create index child_adoption_archive_object on taskfold_private.child_adoption_archive_files(object_id);
alter table taskfold_private.child_adoption_archive_files enable row level security;
revoke all on taskfold_private.child_adoption_archive_files from public,anon,authenticated,service_role;
create function taskfold_private.require_child_adoption_custodian(t public.tasks,team uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$begin
 perform taskfold_private.team_actor();
 if team is null then
  if t.user_id is distinct from auth.uid() then raise exception using errcode='42501',message='The storage owner must review this retained version';end if;
 else
  perform 1 from taskfold_private.teams where id=team and state<>'deleted' for share nowait;
  if not found then raise exception using errcode='42501',message='This workspace is unavailable';end if;
  perform 1 from taskfold_private.team_members where team_id=team and user_id=auth.uid() for share nowait;
  if not found or coalesce(taskfold_private.team_role(team,auth.uid()),'') not in('owner','admin') then raise exception using errcode='42501',message='Workspace administration is required for this retained version';end if;
 end if;
end$$;
-- Never expose retained copies through an ordinary read. Only the bound choice
-- can use the separate current-custodian review, under the existing root lock.
create function taskfold_private.repair_child_copies(b jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare choice jsonb:=b->'changes'->0;review jsonb;binding jsonb;begin
 if not coalesce(choice ? 'restoration',false) then return taskfold_private.review_child_copies(b-array['changes','request_id','repair_digest']);end if;
 binding:=choice->'restoration';
 if choice->>'kind'<>'choose_copy' or choice->>'source'<>'task' or jsonb_typeof(choice->'mapping') is distinct from 'object'
  or jsonb_typeof(binding) is distinct from 'object' or binding-array['actor_id','restore_id','revision','digest']<>'{}'::jsonb
  or not binding ?& array['actor_id','restore_id','revision','digest'] then raise exception using errcode='22023',message='Review one restored task copy and its history';end if;
 review:=taskfold_private.review_restored_child_copies(b-array['changes','request_id','repair_digest'],taskfold_private.team_uuid(binding,'actor_id'),taskfold_private.team_uuid(binding,'restore_id'));
 if binding::text collate "C" is distinct from (review->'restoration')::text collate "C" or (binding->>'revision')::bigint>=9007199254740991 then raise exception using errcode='PT409',message='This restoration changed; review its current copies again';end if;
 return review->'copies';
end$$;
create function taskfold_private.retained_child_adoption(b jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare s taskfold_private.child_repair_restorations;p taskfold_private.child_repair_restore_payloads;files jsonb;t public.tasks;begin
 perform taskfold_private.repair_child_copies(b);
 select * into s from taskfold_private.child_repair_restorations where actor_id=(b->'changes'->0->'restoration'->>'actor_id')::uuid and restore_id=(b->'changes'->0->'restoration'->>'restore_id')::uuid for update nowait;
 select * into p from taskfold_private.child_repair_restore_payloads where actor_id=s.actor_id and restore_id=s.restore_id for update nowait;
 if p.payload is null or s.phase<>'restored' then raise exception using errcode='PT409',message='This retained version changed';end if;
 select * into t from public.tasks where id=s.task_id;
 select coalesce(jsonb_agg(value order by value->>'object_id'),'[]') into files from (
  select distinct value from jsonb_array_elements((p.payload->'files')||taskfold_private.team_task_file_inventory(t))
 ) f;
 if (select count(*)<>count(distinct e->>'object_id') from jsonb_array_elements(files) e) then raise exception using errcode='PT409',message='Review the retained file custody again';end if;
 perform taskfold_private.validate_child_restore_files(files);
 return jsonb_build_object('binding',b->'changes'->0->'restoration','restoration',to_jsonb(s),'payload',p.payload,'files',files);
end$$;
create function taskfold_private.pin_child_adoption(archive uuid,retained jsonb) returns void
language plpgsql volatile security invoker set search_path='' as $$begin
 perform taskfold_private.validate_child_restore_files(retained->'files');
 insert into taskfold_private.child_adoption_archive_files(archive_id,object_id) select archive,(e->>'object_id')::uuid from jsonb_array_elements(retained->'files') e;
end$$;
-- A before-UPDATE exemption requires the existing private mapped-mirror proof,
-- an applied matching receipt and exact immutable preimage, never a caller GUC.
create function taskfold_private.child_adoption_mirror(prior public.tasks,current_row public.tasks) returns boolean
language plpgsql volatile security invoker set search_path='' as $$
declare m taskfold_private.child_mapping_scope;o taskfold_private.child_task_repair_originals;r taskfold_private.child_task_repairs;s taskfold_private.child_repair_restorations;retained jsonb;begin
 select * into m from taskfold_private.child_mapping_scope where transaction_id=txid_current() and task_id=prior.id and actor_id=auth.uid();
 if not found or m.consumed then return false;end if;
 select * into o from taskfold_private.child_task_repair_originals where id=m.archive_id;
 select * into r from taskfold_private.child_task_repairs where actor_id=m.actor_id and request_id=m.request_id;
 retained:=o.original->'retained_restoration';
 if retained is null then return false;end if;
 select * into s from taskfold_private.child_repair_restorations where actor_id=(retained->'binding'->>'actor_id')::uuid and restore_id=(retained->'binding'->>'restore_id')::uuid;
 if s.phase is distinct from 'restored' or to_jsonb(s)::text collate "C" is distinct from (retained->'restoration')::text collate "C"
  or r.state is distinct from 'applied' or r.archive_id is distinct from o.id or r.task_id<>prior.id or r.task_generation is distinct from prior.task_generation
  or m.generation is distinct from prior.task_generation or current_row.task_generation is distinct from m.generation
  or o.original->'copy_choice'->'restoration' is distinct from retained->'binding' or o.original->'copy_choice'->>'source'<>'task'
  or (o.original->'root')::text collate "C" is distinct from to_jsonb(prior)::text collate "C"
  or (to_jsonb(current_row)-'subtasks')::text collate "C" is distinct from (to_jsonb(prior)-'subtasks')::text collate "C"
  or coalesce(current_row.subtasks,'null'::jsonb)::text collate "C" is distinct from m.proposed_tree::text collate "C"
  or o.original->'mapping_context' is distinct from m.context or o.digest<>taskfold_private.child_restore_digest(o.original) or o.bytes<>octet_length(o.original::text) then return false;end if;
 perform taskfold_private.require_child_adoption_custodian(prior,s.workspace_id);
 return true;
end$$;
create function taskfold_private.finish_child_adoption(b jsonb,reply jsonb) returns void
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare r taskfold_private.child_task_repairs;o taskfold_private.child_task_repair_originals;s taskfold_private.child_repair_restorations;p taskfold_private.child_repair_restore_payloads;t public.tasks;retained jsonb;begin
 perform taskfold_private.team_actor();
 select * into r from taskfold_private.child_task_repairs where actor_id=auth.uid() and request_id=(b->>'request_id')::uuid for update;
 if not found or r.state<>'applied' or r.fingerprint<>taskfold_private.child_restore_digest(b) or reply::text collate "C" is distinct from taskfold_private.child_repair_reply(r,false)::text collate "C" then raise exception using errcode='PT409',message='This adoption receipt could not be confirmed';end if;
 select * into o from taskfold_private.child_task_repair_originals where id=r.archive_id and actor_id=r.actor_id and request_id=r.request_id;
 retained:=o.original->'retained_restoration';
 if retained is null or retained->'binding' is distinct from b->'changes'->0->'restoration' or o.digest<>taskfold_private.child_restore_digest(o.original) or o.bytes<>octet_length(o.original::text)
  or exists(select 1 from taskfold_private.child_mapping_scope where transaction_id=txid_current() and task_id=r.task_id) then raise exception using errcode='PT409',message='The mapped mirror and retained version could not be confirmed';end if;
 t:=taskfold_private.child_restore_root(r.task_id,r.task_generation,r.project_id,r.workspace_id);perform taskfold_private.require_child_adoption_custodian(t,r.workspace_id);
 select * into s from taskfold_private.child_repair_restorations where actor_id=(retained->'binding'->>'actor_id')::uuid and restore_id=(retained->'binding'->>'restore_id')::uuid for update nowait;
 select * into p from taskfold_private.child_repair_restore_payloads where actor_id=s.actor_id and restore_id=s.restore_id for update nowait;
 if s.phase is distinct from 'restored' or to_jsonb(s)::text collate "C" is distinct from (retained->'restoration')::text collate "C" or p.payload::text collate "C" is distinct from (retained->'payload')::text collate "C" then raise exception using errcode='PT409',message='The retained inverse changed before adoption';end if;
 perform taskfold_private.validate_child_restore_files(retained->'files');
 if exists(select 1 from jsonb_array_elements(retained->'files') e where not exists(select 1 from taskfold_private.child_adoption_archive_files f where f.archive_id=o.id and f.object_id=(e->>'object_id')::uuid)) then raise exception using errcode='PT409',message='The retained files could not be protected';end if;
 delete from taskfold_private.child_repair_restore_payloads where actor_id=s.actor_id and restore_id=s.restore_id;
 update taskfold_private.child_repair_restorations set phase='adopted',revision=revision+1,current_digest=taskfold_private.child_restore_digest(taskfold_private.child_restore_snapshot(t)),adopted_actor_id=r.actor_id,adopted_request_id=r.request_id,adopted_archive_id=o.id where actor_id=s.actor_id and restore_id=s.restore_id;
 perform taskfold_private.team_actor();
end$$;
-- Staging cannot be committed by calling a private helper without completing the
-- caller-RLS mirror and adoption. This also covers versions with zero files.
create function taskfold_private.require_complete_child_adoption() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.original ? 'retained_restoration' and not exists(
  select 1 from taskfold_private.child_task_repair_originals o join taskfold_private.child_repair_restorations s on s.adopted_archive_id=o.id
  where o.id=new.id and s.phase='adopted' and s.adopted_actor_id=o.actor_id and s.adopted_request_id=o.request_id
   and s.actor_id=(o.original->'retained_restoration'->'binding'->>'actor_id')::uuid and s.restore_id=(o.original->'retained_restoration'->'binding'->>'restore_id')::uuid
   and not exists(select 1 from taskfold_private.child_repair_restore_payloads p where p.actor_id=s.actor_id and p.restore_id=s.restore_id)
 ) then raise exception using errcode='PT409',message='The complete older-version adoption must be confirmed';end if;return null;
end$$;
create constraint trigger child_adoption_complete after insert on taskfold_private.child_task_repair_originals deferrable initially deferred for each row execute function taskfold_private.require_complete_child_adoption();

do $update$ declare d text;begin
 select pg_get_functiondef('taskfold_private.preview_child_copy_choice(jsonb)'::regprocedure) into d;
 if strpos(d,$before$('kind','path','source','copy_digest','mapping','format_changes')$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.preview_child_copy_choice(jsonb)';end if;
 d:=replace(d,$before$('kind','path','source','copy_digest','mapping','format_changes')$before$,$after$('kind','path','source','copy_digest','mapping','format_changes','restoration')$after$);
 if strpos(d,$before$copies:=taskfold_private.review_child_copies(b-'changes');$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.preview_child_copy_choice(jsonb)';end if;
 d:=replace(d,$before$copies:=taskfold_private.review_child_copies(b-'changes');$before$,$after$copies:=taskfold_private.repair_child_copies(b);$after$);
 if strpos(d,$before$if exists(select 1 from taskfold_private.child_repair_restorations where task_id=root_id and phase='restored') then$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.preview_child_copy_choice(jsonb)';end if;
 d:=replace(d,$before$if exists(select 1 from taskfold_private.child_repair_restorations where task_id=root_id and phase='restored') then$before$,$after$if not(choice ? 'restoration') and exists(select 1 from taskfold_private.child_repair_restorations where task_id=root_id and phase='restored') then$after$);
 if strpos(d,$before$where singleton and mapping_reconciliation_enabled$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.preview_child_copy_choice(jsonb)';end if;
 d:=replace(d,$before$where singleton and mapping_reconciliation_enabled$before$,$after$where singleton and (not(choice ? 'restoration') or archive_restore_adoption_enabled) and mapping_reconciliation_enabled$after$);
 execute d;end $update$;

do $update$ declare d text;begin
 select pg_get_functiondef('taskfold_private.commit_child_repair(text,jsonb)'::regprocedure) into d;
 if strpos(d,$before$where singleton and mapping_reconciliation_enabled$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.commit_child_repair(text,jsonb)';end if;
 d:=replace(d,$before$where singleton and mapping_reconciliation_enabled$before$,$after$where singleton and (not(b->'changes'->0 ? 'restoration') or archive_restore_adoption_enabled) and mapping_reconciliation_enabled$after$);
 if strpos(d,$before$copies:=taskfold_private.review_child_copies(b-array['request_id','repair_digest','changes']);$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.commit_child_repair(text,jsonb)';end if;
 d:=replace(d,$before$copies:=taskfold_private.review_child_copies(b-array['request_id','repair_digest','changes']);$before$,$after$copies:=taskfold_private.repair_child_copies(b);$after$);
 if strpos(d,$before$if encode(sha256(convert_to(jsonb_build_object('choice',b-array['request_id','repair_digest']$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.commit_child_repair(text,jsonb)';end if;
 d:=replace(d,$before$if encode(sha256(convert_to(jsonb_build_object('choice',b-array['request_id','repair_digest']$before$,$after$if b->'changes'->0 ? 'restoration' then original:=original||jsonb_build_object('retained_restoration',taskfold_private.retained_child_adoption(b));end if;
 if encode(sha256(convert_to(jsonb_build_object('choice',b-array['request_id','repair_digest']$after$);
 if strpos(d,$before$-- Explicit retirement removes only current projection records.$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.commit_child_repair(text,jsonb)';end if;
 d:=replace(d,$before$-- Explicit retirement removes only current projection records.$before$,$after$if original ? 'retained_restoration' then perform taskfold_private.pin_child_adoption(archive_id,original->'retained_restoration');end if;
 -- Explicit retirement removes only current projection records.$after$);
 execute d;end $update$;

do $update$ declare d text;begin
 select pg_get_functiondef('taskfold_private.guard_restored_child_content()'::regprocedure) into d;
 if strpos(d,$before$'sha256'),'hex')) then$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.guard_restored_child_content()';end if;
 d:=replace(d,$before$'sha256'),'hex')) then$before$,$after$'sha256'),'hex')) and not taskfold_private.child_adoption_mirror(old,new) then$after$);
 execute d;end $update$;

do $update$ declare d text;begin
 select pg_get_functiondef('taskfold_private.guard_child_restore_file()'::regprocedure) into d;
 if strpos(d,$before$if exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.object_id)$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.guard_child_restore_file()';end if;
 d:=replace(d,$before$if exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.object_id)$before$,$after$if (exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.object_id) or exists(select 1 from taskfold_private.child_adoption_archive_files where object_id=old.object_id))$after$);
 execute d;end $update$;

do $update$ declare d text;begin
 select pg_get_functiondef('taskfold_private.guard_child_restore_object()'::regprocedure) into d;
 if strpos(d,$before$if exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.id)$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.guard_child_restore_object()';end if;
 d:=replace(d,$before$if exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.id)$before$,$after$if (exists(select 1 from taskfold_private.child_repair_restore_files where object_id=old.id) or exists(select 1 from taskfold_private.child_adoption_archive_files where object_id=old.id))$after$);
 execute d;end $update$;

do $update$ declare d text;begin
 select pg_get_functiondef('taskfold_private.commit_child_repair_before_mapping(text,jsonb)'::regprocedure) into d;
 if strpos(d,$before$if saved is null or octet_length(saved::text)$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.commit_child_repair_before_mapping(text,jsonb)';end if;
 d:=replace(d,$before$if saved is null or octet_length(saved::text)$before$,$after$if saved ? 'retained_restoration' then perform taskfold_private.require_child_adoption_custodian(t,team);end if;
  if saved is null or octet_length(saved::text)$after$);
 execute d;end $update$;

do $update$ declare d text;begin
 select pg_get_functiondef('taskfold_private.discovered_child_repair_original(uuid,uuid)'::regprocedure) into d;
 if strpos(d,$before$if original is null then$before$)=0 then raise exception 'Unexpected retained-adoption function version: taskfold_private.discovered_child_repair_original(uuid,uuid)';end if;
 d:=replace(d,$before$if original is null then$before$,$after$if original ? 'retained_restoration' then perform taskfold_private.require_child_adoption_custodian(t,team);end if;
 if original is null then$after$);
 execute d;end $update$;


-- Credit only the exact inverse moved into this new archive; other producers
-- and other actors' budgets retain the existing bounds.
create or replace function taskfold_private.guard_child_restore_original_budget() returns trigger
language plpgsql security invoker set search_path='' as $$
declare retained jsonb;command jsonb;credit_actor bigint:=0;credit_team bigint:=0;p taskfold_private.child_repair_restore_payloads;begin
 if new.actor_id is null then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended(new.actor_id::text,73918));
 if new.team_id is not null and not pg_try_advisory_xact_lock(hashtextextended(new.team_id::text,73928)) then raise exception using errcode='55P03',message='Another workspace original is being retained';end if;
 if new.original ? 'retained_restoration' then
  command:=jsonb_build_object('protocol',1,'account',new.actor_id,'task_id',new.task_id,'task_generation',new.task_generation,'project_id',new.project_id,'workspace_id',new.team_id,'review_digest',new.original->'review_digest','repair_digest',new.original->'repair_digest','request_id',new.request_id,'changes',jsonb_build_array(new.original->'copy_choice'));
  retained:=taskfold_private.retained_child_adoption(command);
  if new.original->'retained_restoration' is distinct from retained then raise exception using errcode='PT409',message='This retained inverse changed before its archive';end if;
  select * into p from taskfold_private.child_repair_restore_payloads where actor_id=(retained->'binding'->>'actor_id')::uuid and restore_id=(retained->'binding'->>'restore_id')::uuid;
  if p.actor_id=new.actor_id then credit_actor:=p.bytes;end if;
  if p.team_id is not distinct from new.team_id then credit_team:=p.bytes;end if;
 end if;
 if coalesce((select sum(bytes) from taskfold_private.child_task_repair_originals where actor_id=new.actor_id and id<>new.id),0)
   +coalesce((select sum(bytes) from taskfold_private.child_repair_restore_payloads where actor_id=new.actor_id),0)+new.bytes-credit_actor>64000000
 or (new.team_id is not null and coalesce((select sum(bytes) from taskfold_private.child_task_repair_originals where team_id=new.team_id and id<>new.id),0)
   +coalesce((select sum(bytes) from taskfold_private.child_repair_restore_payloads where team_id=new.team_id),0)+new.bytes-credit_team>256000000) then raise exception using errcode='PT429',message='Retained-original storage is full';end if;
 return new;
end$$;
alter function public.taskfold_repair_children(text,jsonb) rename to taskfold_repair_children_before_restored_adoption;
revoke all on function public.taskfold_repair_children_before_restored_adoption(text,jsonb) from public,anon,authenticated,service_role;
alter function public.taskfold_repair_children_before_restored_adoption(text,jsonb) set schema taskfold_private;
create function public.taskfold_repair_children(_operation text,_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare prior jsonb;reply jsonb;begin
 if not coalesce(_body->'changes'->0 ? 'restoration',false) then return taskfold_private.taskfold_repair_children_before_restored_adoption(_operation,_body);end if;
 prior:=taskfold_private.commit_child_repair('check',_body);
 reply:=taskfold_private.taskfold_repair_children_before_restored_adoption(_operation,_body);
 if _operation='send' and prior->>'state'='unknown' and reply->>'state'='applied' then perform taskfold_private.finish_child_adoption(_body,reply);end if;
 return reply;
end$$;
revoke all on function taskfold_private.require_child_adoption_custodian(public.tasks,uuid),taskfold_private.repair_child_copies(jsonb),taskfold_private.retained_child_adoption(jsonb),taskfold_private.pin_child_adoption(uuid,jsonb),taskfold_private.child_adoption_mirror(public.tasks,public.tasks),taskfold_private.finish_child_adoption(jsonb,jsonb),taskfold_private.require_complete_child_adoption(),public.taskfold_repair_children(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.finish_child_adoption(jsonb,jsonb),taskfold_private.taskfold_repair_children_before_restored_adoption(text,jsonb),public.taskfold_repair_children(text,jsonb) to authenticated;
