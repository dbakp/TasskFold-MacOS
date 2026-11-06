-- Disabled candidate. Recovery observes or retires one exact saved selection;
-- it never completes, reopens or deletes tasks as a side effect of cancellation.
create table taskfold_private.team_completion_batch_cancellations (
 team_id uuid not null, request_id uuid not null,
 primary key(team_id,request_id),
 foreign key(team_id,request_id) references taskfold_private.team_task_batches(team_id,request_id) on delete cascade
);
alter table taskfold_private.team_completion_batch_cancellations enable row level security;
revoke all on taskfold_private.team_completion_batch_cancellations from public,anon,authenticated,service_role;

create function taskfold_private.recover_team_completion_batch(mode text,action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare v_actor uuid:=auth.uid();v_team uuid;v_q uuid;v_ref uuid;v_item jsonb;v_id uuid;v_p uuid;v_g uuid;v_nonce uuid;v_member_ref uuid;v_uid uuid;
 v_ids uuid[]:='{}';v_nonces uuid[]:='{}';v_projects uuid[]:='{}';v_locks uuid[]:='{}';v_op text;v_state text;v_fingerprint text;
 v_team_row taskfold_private.teams;v_prior taskfold_private.team_task_batches;v_original taskfold_private.team_task_batches;
 v_link taskfold_private.team_task_batch_items;v_edit taskfold_private.team_task_edits;
 v_view jsonb;v_views jsonb:='[]';v_receipts jsonb:='[]';v_receipt jsonb;v_result jsonb;v_cancelled boolean:=false;
begin
 perform taskfold_private.team_actor();
 if mode is null or mode not in('review','cancel') or action is null or action not in('complete','undo')
  or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>2000000
  or not b ?& array['team_id','request_id','items'] or exists(select 1 from jsonb_object_keys(b) k where k not in('team_id','request_id','items','related_request'))
  or jsonb_typeof(b->'items') is distinct from 'array' or jsonb_array_length(b->'items') not between 1 and 100 then
  raise exception using errcode='22023',message='Include the complete saved selection';end if;
 v_team=taskfold_private.team_uuid(b,'team_id');v_q=taskfold_private.team_uuid(b,'request_id');
 if b ? 'related_request' then v_ref=taskfold_private.team_uuid(b,'related_request');end if;
 if v_q=v_ref or (action='undo' and v_ref is null) then raise exception using errcode='22023',message='Keep the original selection history';end if;
 v_op=case when action='undo' then 'undo_complete' else 'complete' end;
 for v_item in select value from jsonb_array_elements(b->'items') loop
  if jsonb_typeof(v_item)<>'object' or octet_length(v_item::text)>128000
   or not v_item ?& array['team_id','project_id','task_id','task_generation','request_id','record','completed_at','input_zone','next_generation','planned_next_id','series_id','series_generation','series_project_id']
   or exists(select 1 from jsonb_object_keys(v_item) k where k not in('team_id','project_id','task_id','task_generation','request_id','record','completed_at','input_zone','next_generation','planned_next_id','series_id','series_generation','series_project_id','undoes','redo_of'))
   or jsonb_typeof(v_item->'record') is distinct from 'object' then raise exception using errcode='22023',message='Include every original completion';end if;
  v_id=taskfold_private.team_uuid(v_item,'task_id');v_p=taskfold_private.team_uuid(v_item,'project_id');v_g=taskfold_private.team_uuid(v_item,'task_generation');v_nonce=taskfold_private.team_uuid(v_item,'request_id');
  if taskfold_private.team_uuid(v_item,'team_id')<>v_team or v_id=any(v_ids) or v_nonce=v_q or v_nonce=v_ref or v_nonce=any(v_nonces)
   or v_item->'record'->'id' is distinct from to_jsonb(v_id) or v_item->'record'->'project_id' is distinct from to_jsonb(v_p)
   or v_item->'record'->'task_generation' is distinct from to_jsonb(v_g) then raise exception using errcode='22023',message='Keep the original task and request identities';end if;
  v_member_ref=null;
  if v_ref is null then
   if v_item ? 'undoes' or v_item ? 'redo_of' then raise exception using errcode='22023',message='Keep the original selection history';end if;
  else
   v_member_ref=taskfold_private.team_uuid(v_item,case when action='undo' then 'undoes' else 'redo_of' end);
   if v_item ? (case when action='undo' then 'redo_of' else 'undoes' end) then raise exception using errcode='22023',message='Keep the original selection history';end if;
  end if;
  perform taskfold_private.team_uuid(v_item,'next_generation');perform taskfold_private.team_uuid(v_item,'series_generation');
  v_ids=array_append(v_ids,v_id);v_nonces=v_nonces||array[v_nonce,v_member_ref];
  v_projects=v_projects||array[v_p,taskfold_private.team_uuid(v_item,'series_project_id')];
  v_locks=v_locks||array[v_id,taskfold_private.team_uuid(v_item,'series_id')];
  if v_item->'planned_next_id'<>'null'::jsonb then v_locks=array_append(v_locks,taskfold_private.team_uuid(v_item,'planned_next_id'));end if;
 end loop;
 -- Use the completion writer's hierarchy: team/config, sorted projects,
 -- sorted group/member/history nonces, then sorted task identities and rows.
 select * into v_team_row from taskfold_private.teams t where t.id=v_team for share;
 perform taskfold_private.team_actor();
 if v_team_row.id is null or v_team_row.state<>'active' then raise exception using errcode='PT503',message='Team access is paused';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team access is paused';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team reading is not enabled';end if;
 for v_p in select distinct x from unnest(v_projects) x order by x loop
  if taskfold_private.team_project_role(v_actor,v_p) is null then raise exception using errcode='42501',message='Project access is required for the whole selection';end if;
  perform 1 from taskfold_private.team_content_projects p where p.project_id=v_p and p.team_id=v_team for share;
  if not found then raise exception using errcode='PT404',message='A selected project is unavailable';end if;
  perform 1 from public.projects p where p.id=v_p for share;
  if not found then raise exception using errcode='PT404',message='A selected project is unavailable';end if;
 end loop;
 for v_uid in select distinct x from unnest(v_nonces||array[v_q,v_ref]) x where x is not null order by x loop
  perform pg_advisory_xact_lock(hashtextextended(v_team::text||':'||v_uid::text,79241));
 end loop;
 select encode(extensions.hmac(convert_to(jsonb_build_array(v_actor,'completion-batch-v1',action,b)::text,'UTF8'),s.secret,'sha256'),'hex') into v_fingerprint from taskfold_private.automation_revision_secret s where singleton;
 select * into v_prior from taskfold_private.team_task_batches t where t.team_id=v_team and t.request_id=v_q;
 if found then
  if v_prior.actor_id<>v_actor or v_prior.operation<>v_op or v_prior.fingerprint<>v_fingerprint or v_prior.restores is distinct from v_ref then raise exception using errcode='PT409',message='This saved selection needs review';end if;
  select exists(select 1 from taskfold_private.team_completion_batch_cancellations t where t.team_id=v_team and t.request_id=v_q) into v_cancelled;
  if (select count(*) from taskfold_private.team_task_batch_items t where t.team_id=v_team and t.request_id=v_q)<>cardinality(v_ids) then raise exception using errcode='PT409',message='The saved selection receipt is incomplete';end if;
 elsif exists(select 1 from taskfold_private.team_task_edits t where t.team_id=v_team and t.request_id=v_q) then
  raise exception using errcode='PT409',message='This saved request belongs to another action';
 end if;
 if v_ref is not null then
  select * into v_original from taskfold_private.team_task_batches t where t.team_id=v_team and t.request_id=v_ref;
  if not found or v_original.actor_id<>v_actor or v_original.operation<>(case when action='undo' then 'complete' else 'undo_complete' end)
   or exists(select 1 from taskfold_private.team_completion_batch_cancellations t where t.team_id=v_team and t.request_id=v_ref)
   or (select count(*) from taskfold_private.team_task_batch_items t where t.team_id=v_team and t.request_id=v_ref)<>cardinality(v_ids) then raise exception using errcode='PT409',message='Keep the complete original selection history';end if;
 end if;
 for v_item in select value from jsonb_array_elements(b->'items') loop
  v_nonce=(v_item->>'request_id')::uuid;
  select * into v_edit from taskfold_private.team_task_edits e where e.team_id=v_team and e.request_id=v_nonce;
  if v_prior.request_id is null then
   if found or exists(select 1 from taskfold_private.team_task_batches t where t.team_id=v_team and t.request_id=v_nonce) then raise exception using errcode='PT409',message='A saved member belongs to another action';end if;
  else
   select * into v_link from taskfold_private.team_task_batch_items t where t.team_id=v_team and t.request_id=v_q and t.task_id=(v_item->>'task_id')::uuid;
   if v_link.operation_request is distinct from v_nonce or v_link.project_id is distinct from (v_item->>'project_id')::uuid or v_link.generation is distinct from (v_item->>'task_generation')::uuid
    or v_edit.batch_request_id is distinct from v_q then raise exception using errcode='PT409',message='The saved selection receipt is incomplete';end if;
   v_locks=array_append(v_locks,(select c.successor_id from taskfold_private.team_task_completions c where c.team_id=v_team and c.request_id=v_nonce));
  end if;
  if v_ref is not null and not exists(select 1 from taskfold_private.team_task_batch_items t where t.team_id=v_team and t.request_id=v_ref
   and t.task_id=(v_item->>'task_id')::uuid and t.project_id=(v_item->>'project_id')::uuid and t.generation=(v_item->>'task_generation')::uuid
   and t.operation_request=(v_item->>(case when action='undo' then 'undoes' else 'redo_of' end))::uuid) then raise exception using errcode='PT409',message='Keep every original member link';end if;
 end loop;
 for v_uid in select distinct x from unnest(v_locks) x where x is not null order by x loop perform pg_advisory_xact_lock(hashtextextended(v_uid::text,78137));end loop;
 perform 1 from public.tasks t where t.id=any(v_locks) order by t.id for share;
 v_state=case when v_cancelled then 'cancelled' when v_prior.request_id is not null then 'recorded' else 'unrecorded' end;
 for v_item in select value from jsonb_array_elements(b->'items') order by value->>'task_id' loop
  v_view=taskfold_private.review_team_completion(action,v_item);
  if v_view->>'state'<>v_state then raise exception using errcode='PT409',message='The saved selection receipt is incomplete';end if;
  v_views=v_views||jsonb_build_array(v_view);
  if v_state='recorded' then v_receipts=v_receipts||jsonb_build_array(v_view->'receipt');end if;
  -- Stop accumulating at the group budget, rather than building up to 100
  -- individually bounded observations before discovering an oversized result.
  if octet_length(v_views::text)+octet_length(v_receipts::text)>8000000 then raise exception using errcode='54000',message='The selection review is too large. Your saved work is unchanged';end if;
 end loop;
 if mode='cancel' and v_state='unrecorded' then
  insert into taskfold_private.team_task_batches(team_id,request_id,actor_id,operation,fingerprint,restores) values(v_team,v_q,v_actor,v_op,v_fingerprint,v_ref);
  v_views='[]';
  for v_item in select value from jsonb_array_elements(b->'items') order by value->>'task_id' loop
   v_view=taskfold_private.cancel_team_completion(action,v_item);
   if v_view->>'state'<>'cancelled' then raise exception using errcode='PT409',message='The saved selection changed during cancellation';end if;
   update taskfold_private.team_task_edits set batch_request_id=v_q where team_id=v_team and request_id=(v_item->>'request_id')::uuid;
   insert into taskfold_private.team_task_batch_items values(v_team,v_q,(v_item->>'task_id')::uuid,(v_item->>'project_id')::uuid,(v_item->>'task_generation')::uuid,(v_item->>'request_id')::uuid);
   v_views=v_views||jsonb_build_array(v_view);
   if octet_length(v_views::text)>8000000 then raise exception using errcode='54000',message='The selection review is too large. Your saved work is unchanged';end if;
  end loop;
  insert into taskfold_private.team_completion_batch_cancellations values(v_team,v_q);
  v_state='cancelled';
 end if;
 if v_state='recorded' then v_receipt=jsonb_build_object('batch_protocol',1,'account',v_actor,'team_id',v_team,'request_id',v_q,'operation',action,'related_request',v_ref,'items',v_receipts,'replayed',true);end if;
 v_result=jsonb_build_object('group_review_protocol',1,'account',v_actor,'team_id',v_team,'request_id',v_q,'operation',action,'related_request',v_ref,'state',v_state,'items',v_views,'receipt',v_receipt);
 if octet_length(v_result::text)>8000000 then raise exception using errcode='54000',message='The selection review is too large. Your saved work is unchanged';end if;
 return v_result;
exception when lock_not_available then raise exception using errcode='PT409',message='A selected task is busy. Retry the saved review';
end$$;
create function public.taskfold_review_team_completion_batch(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.recover_team_completion_batch('review',_action,_body)$$;
create function public.taskfold_cancel_team_completion_batch(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.recover_team_completion_batch('cancel',_action,_body)$$;
revoke all on function taskfold_private.recover_team_completion_batch(text,text,jsonb),public.taskfold_review_team_completion_batch(text,jsonb),public.taskfold_cancel_team_completion_batch(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.recover_team_completion_batch(text,text,jsonb),public.taskfold_review_team_completion_batch(text,jsonb),public.taskfold_cancel_team_completion_batch(text,jsonb) to authenticated;
