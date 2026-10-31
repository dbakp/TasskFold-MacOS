-- Receipt-certified, all-or-nothing Undo for a mixed selection. Uses the same
-- disabled write gate and immutable outcome ledger as forward completion.
alter table taskfold_private.mixed_completion_batches add column undo_of uuid,add column reversed_by uuid;
create table taskfold_private.mixed_provisional_retirements (
 task_id uuid not null,generation uuid not null,primary key(task_id,generation),
 foreign key(task_id,generation) references taskfold_private.task_generations(task_id,generation) on delete cascade
);
alter table taskfold_private.mixed_provisional_retirements enable row level security;
revoke all on taskfold_private.mixed_provisional_retirements from public,anon,authenticated,service_role;
-- Only generations removed by a certified Undo may be recreated by a later
-- fresh completion. Actual user deletions retain their existing tombstones.
do $$declare definition text;old text:='and not exists(select 1 from taskfold_private.team_provisional_retirements r where r.task_id=h.task_id and r.generation=h.generation)';begin
 definition:=pg_get_functiondef('taskfold_private.apply_mixed_completion_root(jsonb,jsonb,jsonb)'::regprocedure);
 if strpos(definition,old)=0 then raise exception 'Mixed completion retirement guard changed';end if;
 execute replace(definition,old,old||' and not exists(select 1 from taskfold_private.mixed_provisional_retirements r where r.task_id=h.task_id and r.generation=h.generation)');
end$$;

create function taskfold_private.undo_mixed_completion(b jsonb,closing boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<undo_op>>
declare a uuid:=auth.uid();batch uuid;source uuid;fingerprint text;prior taskfold_private.mixed_completion_batches;original taskfold_private.mixed_completion_batches;
 item jsonb;proof jsonb;child jsonb;receipt jsonb;next_proof jsonb;receipts jsonb:='[]';q uuid;old_q uuid;id uuid;team uuid;
 t public.tasks;after_root public.tasks;successor public.tasks;node taskfold_private.child_task_records;p taskfold_private.child_task_projections;
 roots uuid[]:='{}';locks uuid[]:='{}';projects uuid[]:='{}';teams uuid[]:='{}';people uuid[]:='{}';requests uuid[]:='{}';bytes bigint:=0;ordinal integer;
 before_state jsonb;state jsonb;next_state text;decoded jsonb;
begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>131072 or b->'protocol' is distinct from '1'::jsonb
  or not(b ?& array['protocol','account','batch_id','undo_of','items'])
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','batch_id','undo_of','items'))
  or jsonb_typeof(b->'items') is distinct from 'array' or jsonb_array_length(b->'items') not between 1 and 32 then
  raise exception using errcode='22023',message='Use the complete saved selection for Undo';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This selection belongs to another account';end if;
 batch:=taskfold_private.team_uuid(b,'batch_id');source:=taskfold_private.team_uuid(b,'undo_of');
 if batch=source then raise exception using errcode='22023',message='Undo needs its own original identity';end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.mixed_completion_batches where actor_id=a and batch_id=batch;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This Undo identity was already used';end if;
  if not closing and prior.outcome='closed' then raise exception using errcode='PT410',message='This saved Undo is closed';end if;
  return taskfold_private.mixed_completion_reply(prior,true);
 end if;
 select * into original from taskfold_private.mixed_completion_batches where actor_id=a and batch_id=source for update;
 if not found or original.outcome<>'applied' or original.undo_of is not null or jsonb_array_length(original.receipts)<>jsonb_array_length(b->'items') then
  raise exception using errcode='PT409',message='The complete original selection confirmation is required';end if;
 if (select count(*) from taskfold_private.mixed_completion_batches where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=128 then raise exception using errcode='PT429',message='Too many saved selection actions; try again later';end if;
 for item,ordinal in select x.value,x.ord::integer-1 from jsonb_array_elements(b->'items') with ordinality x(value,ord) loop
  proof:=original.receipts->ordinal;
  if item->'kind' is distinct from proof->'kind' then raise exception using errcode='22023',message='Keep every original selection member in order';end if;
  if item->>'kind'='root' then
   if not(item ?& array['kind','request_id','task_id']) or exists(select 1 from jsonb_object_keys(item) k where k not in('kind','request_id','task_id'))
    or item->'task_id' is distinct from proof->'task_id' then raise exception using errcode='22023',message='Keep the original parent action';end if;
   q:=taskfold_private.team_uuid(item,'request_id');id:=taskfold_private.team_uuid(item,'task_id');
  else
   if not(item ?& array['kind','command']) or exists(select 1 from jsonb_object_keys(item) k where k not in('kind','command')) then raise exception using errcode='22023',message='Keep the original child action';end if;
   child:=item->'command';perform taskfold_private.validate_child_completion_request(child,a);
   if child->>'action'<>'undo' or child->'undo_of' is distinct from proof->'receipt'->'request_id'
    or exists(select 1 from unnest(array['task_id','task_generation','project_id','node_key','incarnation']) k where child->k is distinct from proof->'receipt'->k) then raise exception using errcode='22023',message='Use the original child confirmation for Undo';end if;
   q:=taskfold_private.team_uuid(child,'request_id');id:=taskfold_private.team_uuid(child,'task_id');
  end if;
  if q=batch or q=source or q=any(requests) then raise exception using errcode='22023',message='Use a distinct identity for each Undo member';end if;
  requests:=array_append(requests,q);roots:=array_append(roots,id);
 end loop;
 for q in select x from unnest(requests) x order by x loop
  if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73920)) then raise exception using errcode='55P03',message='An Undo member is finishing';end if;
  if exists(select 1 from taskfold_private.mixed_completion_members where actor_id=a and request_id=q) or taskfold_private.mixed_completion_legacy_identity(a,q) then raise exception using errcode='PT409',message='An Undo member identity was already used';end if;
 end loop;
 if not closing then
  if original.reversed_by is not null then raise exception using errcode='PT409',message='This selection was already undone';end if;
  perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and mixed_completions_enabled and mixed_completion_writes_enabled for share nowait;
  if not found then raise exception using errcode='PT503',message='Mixed task completion is not enabled';end if;
  locks:=roots;
  for proof in select * from jsonb_array_elements(original.receipts) loop
   if proof->>'kind'='root' and proof->'successor'->'created'='true'::jsonb then locks:=array_append(locks,(proof->'successor'->>'id')::uuid);end if;
  end loop;
  for id in select distinct x from unnest(locks) x order by x loop
   select * into t from public.tasks where tasks.id=undo_op.id;
   if not found then
    if id=any(roots) then raise exception using errcode='PT409',message='An original task is unavailable';else continue;end if;
   end if;
   if not coalesce(taskfold_private.mixed_completion_can_edit(t),false) then raise exception using errcode='42501',message='Every Undo task needs current editing access';end if;
   bytes:=bytes+octet_length(to_jsonb(t)::text);if octet_length(to_jsonb(t)::text)>2000000 or bytes>8000000 then raise exception using errcode='54000',message='This selection is too large to undo together';end if;
   if t.project_id is not null then projects:=array_append(projects,t.project_id);end if;
   select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
   if team is not null then teams:=array_append(teams,team);end if;
   if t.assigned_to is not null then people:=array_append(people,t.assigned_to);end if;
   decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
   if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this Undo hierarchy';end if;
   select people||coalesce(array_agg(distinct person),'{}') into people from (select (x->'fields'->>'assigned_to')::uuid person from jsonb_array_elements(decoded->'nodes')x where coalesce(x->'fields'->>'assigned_to','')<>'')v;
  end loop;
  perform 1 from auth.users where users.id=any(people) order by users.id for share nowait;
  perform 1 from taskfold_private.teams where teams.id=any(undo_op.teams) order by teams.id for share nowait;
  perform 1 from taskfold_private.team_config where singleton for share nowait;
  perform 1 from taskfold_private.team_project_config where singleton for share nowait;
  perform 1 from taskfold_private.team_content_projects where project_id=any(undo_op.projects) order by project_id for share nowait;
  perform 1 from public.projects where projects.id=any(undo_op.projects) order by projects.id for share nowait;
  for q in select x from unnest(requests) x order by x loop
   if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73917)) or not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='An Undo member is busy';end if;
   for team in select distinct x from unnest(teams)x order by x loop
    if not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) then raise exception using errcode='55P03',message='An Undo member is busy';end if;
   end loop;
  end loop;
  for id in select distinct x from unnest(locks)x order by x loop
   if not pg_try_advisory_xact_lock(hashtextextended(id::text,78137)) then raise exception using errcode='55P03',message='An Undo task is busy';end if;
  end loop;
  perform 1 from public.tasks where tasks.id=any(locks) order by tasks.id for update nowait;
  for id in select distinct x from unnest(roots)x order by x loop t:=taskfold_private.completion_selection_task(id,false);end loop;
  for proof in select * from jsonb_array_elements(original.receipts) where value->>'kind'='root' loop
   t:=taskfold_private.completion_selection_task((proof->>'task_id')::uuid,true);
   if taskfold_private.completion_selection_root_baseline(t) is distinct from proof->'after' then raise exception using errcode='PT409',message='A selected parent changed after this action';end if;
   if proof->'successor'->'created'='true'::jsonb then
    select * into successor from public.tasks where tasks.id=(proof->'successor'->>'id')::uuid;
    if found and (successor.task_generation is distinct from (proof->'successor'->>'generation')::uuid
     or successor.project_id is distinct from t.project_id or not coalesce(taskfold_private.mixed_completion_can_edit(successor),false)
     or taskfold_private.team_completion_task_hash(successor) is distinct from proof->'successor'->>'hash'
     or exists(select 1 from public.task_comments where task_id=successor.id)
     or exists(select 1 from public.tasks where recurrence_parent_id=successor.id)) then
     raise exception using errcode='PT409',message='The new recurring occurrence changed; keep it and review this selection';end if;
   end if;
  end loop;
 end if;
 insert into taskfold_private.mixed_completion_batches(actor_id,batch_id,fingerprint,outcome,receipts,undo_of) values(a,batch,fingerprint,'closed','[]',source) returning * into prior;
 for item,ordinal in select x.value,x.ord::integer-1 from jsonb_array_elements(b->'items') with ordinality x(value,ord) loop
  proof:=original.receipts->ordinal;q:=requests[ordinal+1];old_q:=(proof->>'request_id')::uuid;id:=roots[ordinal+1];
  insert into taskfold_private.mixed_completion_members(actor_id,batch_id,request_id,ordinal,kind,task_id,node_key) values(a,batch,q,ordinal,item->>'kind',id,case when item->>'kind'='child' then item->'command'->>'node_key' else null end);
  if not closing then insert into taskfold_private.mixed_completion_scope(transaction_id,actor_id,batch_id,request_id,original_batch_id,original_request_id) values(txid_current(),a,batch,q,source,old_q);end if;
 end loop;
 if not closing then
  for item,ordinal in select x.value,x.ord::integer-1 from jsonb_array_elements(b->'items') with ordinality x(value,ord) loop
   proof:=original.receipts->ordinal;q:=requests[ordinal+1];id:=roots[ordinal+1];
   if item->>'kind'='child' then
    receipt:=jsonb_build_object('kind','child','request_id',q,'receipt',taskfold_private.complete_child_task(item->'command'));
   else
    select * into t from public.tasks where tasks.id=undo_op.id;before_state:=taskfold_private.completion_selection_root_baseline(t);next_state:='none';
    next_proof:=proof->'successor';
    if next_proof->'created'='true'::jsonb then
     select * into successor from public.tasks where tasks.id=(next_proof->>'id')::uuid;
     if found then
      select team_id into team from taskfold_private.team_content_projects where project_id=successor.project_id;
      if team is not null then insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,successor.project_id,successor.id,successor.task_generation,a,'delete',q);end if;
      delete from public.tasks where tasks.id=successor.id;
      if team is null then insert into taskfold_private.mixed_provisional_retirements(task_id,generation) values(successor.id,successor.task_generation) on conflict do nothing;
      else insert into taskfold_private.team_provisional_retirements(task_id,generation,team_id,project_id) values(successor.id,successor.task_generation,team,successor.project_id) on conflict do nothing;end if;
      if team is not null then delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=successor.id;end if;
      next_state:='removed';
     else next_state:='absent';end if;
    end if;
    select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
    if team is not null then insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,t.project_id,t.id,t.task_generation,a,'patch',q);end if;
    update public.tasks set completed=(proof->'before'->>'completed')::boolean,completed_at=(proof->'before'->>'completed_at')::timestamptz where tasks.id=undo_op.id returning * into after_root;
    if after_root.completed is distinct from (proof->'before'->>'completed')::boolean or after_root.completed_at is distinct from (proof->'before'->>'completed_at')::timestamptz
     or after_root.completion_version<>t.completion_version+1 or (to_jsonb(after_root)-array['completed','completed_at','completion_version','updated_at']) is distinct from (to_jsonb(t)-array['completed','completed_at','completion_version','updated_at']) then raise exception using errcode='PT409',message='This parent Undo could not be confirmed';end if;
    if team is not null then
     delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=t.id;
     insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,t.id,t.task_generation,'patch');
    end if;
    receipt:=jsonb_build_object('kind','root','request_id',q,'task_id',id,'task_generation',t.task_generation,'project_id',t.project_id,'action','undo','before',before_state,'after',taskfold_private.completion_selection_root_baseline(after_root),'successor',jsonb_build_object('state',next_state,'planned_id',next_proof->'planned_id','id',next_proof->'id','generation',next_proof->'generation','created',false,'hash',null));
   end if;
   receipts:=receipts||jsonb_build_array(receipt);
  end loop;
  perform taskfold_private.team_actor();
  for id in select distinct x from unnest(roots)x order by x loop
   select * into t from public.tasks where tasks.id=undo_op.id;
   if not found or not coalesce(taskfold_private.mixed_completion_can_edit(t),false) then raise exception using errcode='42501',message='Editing access changed';end if;
  end loop;
  update taskfold_private.mixed_completion_batches set outcome='applied',receipts=undo_op.receipts where actor_id=a and batch_id=batch returning * into prior;
  update taskfold_private.mixed_completion_batches set reversed_by=batch where actor_id=a and batch_id=source;
  delete from taskfold_private.mixed_completion_scope where transaction_id=txid_current() and actor_id=a and batch_id=batch;
 end if;
 return taskfold_private.mixed_completion_reply(prior,false);
end$$;
create function public.taskfold_undo_mixed_completion(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.undo_mixed_completion(_body,false)$$;
create or replace function public.taskfold_close_mixed_completion(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select case when _body ? 'undo_of' then taskfold_private.undo_mixed_completion(_body,true) else taskfold_private.mixed_completion(_body,true) end$$;
revoke all on function taskfold_private.undo_mixed_completion(jsonb,boolean),public.taskfold_undo_mixed_completion(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.undo_mixed_completion(jsonb,boolean),public.taskfold_undo_mixed_completion(jsonb) to authenticated;
