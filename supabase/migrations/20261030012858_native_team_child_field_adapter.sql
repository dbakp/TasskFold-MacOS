-- Candidate: preserve sparse/null team child containers and bounded large roots.
-- Keep v1 requests/receipts and existing field/read gates; no ordinary rollout.
alter table taskfold_private.team_task_edits drop constraint team_task_edits_operation_check;
alter table taskfold_private.team_task_edits add constraint team_task_edits_operation_check
 check(operation in('patch','create','delete','restore','move','child_completion','child_structure','child_field'));

-- Reciprocal final-nonce checks for old team writers. They never wait while
-- holding a root behind a newer actor/decision lock; refusal rolls back DML.
create function taskfold_private.guard_child_field_team_identity() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT410',message='This original child request is closed';end if;
 if exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT409',message='This request identity was already used for a child edit';end if;
 return new;
end$$;
create trigger child_field_identity_team_edit before insert or update on taskfold_private.team_task_edits for each row execute function taskfold_private.guard_child_field_team_identity();
create trigger child_field_identity_team_batch before insert or update on taskfold_private.team_task_batches for each row execute function taskfold_private.guard_child_field_team_identity();
create function taskfold_private.guard_child_field_receipt_identity() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT410',message='This original child request is closed';end if;
 if exists(select 1 from taskfold_private.team_task_batches where actor_id=new.actor_id and request_id=new.request_id)
  or exists(select 1 from taskfold_private.team_task_edits where actor_id=new.actor_id and request_id=new.request_id
   and not(operation='child_field' and fingerprint=new.fingerprint and task_id=new.task_id and generation is not distinct from new.generation)) then raise exception using errcode='PT409',message='This identity belongs to another task action';end if;
 return new;
end$$;
create trigger child_field_identity_receipt before insert or update on taskfold_private.child_task_edit_receipts for each row execute function taskfold_private.guard_child_field_receipt_identity();
create function taskfold_private.guard_child_field_close_identity() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if not pg_try_advisory_xact_lock(hashtextextended(new.actor_id::text||':'||new.request_id::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.team_task_edits where actor_id=new.actor_id and request_id=new.request_id)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=new.actor_id and request_id=new.request_id) then raise exception using errcode='PT409',message='This identity belongs to another task action';end if;
 return new;
end$$;
create trigger child_field_identity_close before insert or update on taskfold_private.child_task_edit_closures for each row execute function taskfold_private.guard_child_field_close_identity();

-- This helper cannot prepare a write. Only an exact, admitted preparation in
-- this transaction can authorize its own field-only reconstruction.
create function taskfold_private.apply_prepared_team_child_field(b jsonb) returns void
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();q uuid;scope taskfold_private.child_task_edit_preparations;t public.tasks;team uuid;desired jsonb;fingerprint text;begin
 perform taskfold_private.team_actor();q:=taskfold_private.team_uuid(b,'request_id');
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into scope from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q and transaction_id=txid_current() for update;
 if not found or scope.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This child edit was not prepared';end if;
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child editing is not enabled';end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=scope.project_id;
 if team is null then raise exception using errcode='42501',message='This prepared team task is unavailable';end if;
 perform 1 from taskfold_private.teams where id=team and state='active' for share;
 if not found or coalesce(taskfold_private.team_project_role(a,scope.project_id),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team editing is paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
 perform 1 from public.projects where id=scope.project_id and not is_archived and not ancestor_archived for share;
 if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 if exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original child request is closed';end if;
 if exists(select 1 from taskfold_private.team_task_edits where (actor_id=a or team_id=team) and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where (actor_id=a or team_id=team) and request_id=q) then raise exception using errcode='PT409',message='This request identity belongs to another task action';end if;
 select * into t from public.tasks where id=scope.task_id for update;
 if not found or t.task_generation is distinct from scope.generation or t.project_id is distinct from scope.project_id
  or not exists(select 1 from taskfold_private.team_content_tasks where task_id=t.id and generation=t.task_generation and team_id=team) then raise exception using errcode='PT409',message='This team task changed';end if;
 perform taskfold_private.read_child_task_records(t.id,t.task_generation);
 desired:=taskfold_private.child_task_field_tree(t.subtasks,scope.node_key,b->'changes');
 if scope.after_hash<>encode(extensions.digest(convert_to(desired::text,'UTF8'),'sha256'),'hex') then raise exception using errcode='PT409',message='This prepared child edit changed';end if;
 insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
 values(txid_current(),team,t.project_id,t.id,t.task_generation,a,'patch',q);
 update public.tasks set subtasks=desired where id=t.id returning * into t;
 delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=t.id;
 if t.subtasks is distinct from desired then raise exception using errcode='PT409',message='This child edit could not be confirmed';end if;
 perform taskfold_private.read_child_task_records(t.id,t.task_generation);perform taskfold_private.team_actor();
 if coalesce(taskfold_private.team_project_role(a,t.project_id),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation)
 values(team,q,a,fingerprint,t.id,t.task_generation,'child_field');
end$$;
create or replace function public.taskfold_edit_child_task(_body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare plan jsonb;receipt jsonb;begin
 plan:=taskfold_private.child_task_edit_prepare(_body);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if plan->'replayed'='true'::jsonb then return plan->'receipt';end if;
 if plan->'team_id'='null'::jsonb then perform public.taskfold_patch_task((_body->>'task_id')::uuid,plan->'base',plan->'changes');
 else perform taskfold_private.apply_prepared_team_child_field(_body);end if;
 receipt:=taskfold_private.child_task_edit_finish(_body);
 if not exists(select 1 from public.tasks where id=(_body->>'task_id')::uuid) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return receipt;
end$$;
revoke all on function taskfold_private.guard_child_field_team_identity(),taskfold_private.guard_child_field_receipt_identity(),taskfold_private.guard_child_field_close_identity(),
 taskfold_private.apply_prepared_team_child_field(jsonb),public.taskfold_edit_child_task(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.apply_prepared_team_child_field(jsonb),public.taskfold_edit_child_task(jsonb) to authenticated;
