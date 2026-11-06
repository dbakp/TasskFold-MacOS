-- Atomic mixed completion/reopen, still behind the disabled mixed gate.
-- No normal client flag or hosted configuration is enabled by this candidate.
alter table taskfold_private.child_task_record_config add column mixed_completion_writes_enabled boolean not null default false;
create table taskfold_private.mixed_completion_batches (
 actor_id uuid not null references auth.users(id) on delete cascade,batch_id uuid not null,
 fingerprint text not null check(fingerprint~'^[0-9a-f]{64}$'),outcome text not null check(outcome in('applied','closed')),
 receipts jsonb not null default '[]' check(jsonb_typeof(receipts)='array' and octet_length(receipts::text)<=524288),
 created_at timestamptz not null default clock_timestamp(),primary key(actor_id,batch_id),
 check((outcome='closed' and receipts='[]'::jsonb) or (outcome='applied' and jsonb_array_length(receipts) between 1 and 32))
);
create index mixed_completion_batches_actor_day on taskfold_private.mixed_completion_batches(actor_id,created_at);
create table taskfold_private.mixed_completion_members (
 actor_id uuid not null,batch_id uuid not null,request_id uuid not null,ordinal integer not null check(ordinal between 0 and 31),
 kind text not null check(kind in('root','child')),task_id uuid not null,node_key text collate "C",
 primary key(actor_id,request_id),unique(actor_id,batch_id,ordinal),
 foreign key(actor_id,batch_id) references taskfold_private.mixed_completion_batches(actor_id,batch_id) on delete cascade,
 check((kind='root')=(node_key is null))
);
create table taskfold_private.mixed_completion_scope (
 transaction_id bigint not null,actor_id uuid not null,batch_id uuid not null,request_id uuid not null,
 original_batch_id uuid,original_request_id uuid,primary key(transaction_id,actor_id,request_id),
 check((original_batch_id is null)=(original_request_id is null))
);
alter table taskfold_private.mixed_completion_batches enable row level security;
alter table taskfold_private.mixed_completion_members enable row level security;
alter table taskfold_private.mixed_completion_scope enable row level security;
revoke all on taskfold_private.mixed_completion_batches,taskfold_private.mixed_completion_members,taskfold_private.mixed_completion_scope from public,anon,authenticated,service_role;

create function taskfold_private.completion_selection_task(id uuid,root_completion boolean) returns public.tasks
language plpgsql volatile security invoker set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();initial public.tasks;t public.tasks;team uuid;begin
 perform taskfold_private.team_actor();
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and mixed_completions_enabled for share;
 if not found then raise exception using errcode='PT503',message='Mixed task completion is not enabled';end if;
 select * into initial from public.tasks where tasks.id=completion_selection_task.id;
 if not found then raise exception using errcode='42501',message='A selected task is unavailable';end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=initial.project_id;
 if team is not null then
  perform 1 from taskfold_private.teams where teams.id=team and state='active' for share;
  if not found or coalesce(taskfold_private.team_project_role(a,initial.project_id),'') not in('manager','editor') then
   raise exception using errcode='42501',message='Editing access is required for every selected task';end if;
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is paused';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
  perform 1 from taskfold_private.team_content_projects where project_id=initial.project_id and team_id=team for share;
 elsif taskfold_private.is_team_content_task(id) or (initial.project_id is null and initial.user_id<>a)
  or (initial.project_id is not null and not coalesce(public.has_project_access(a,initial.project_id),false)) then
  raise exception using errcode='42501',message='A selected task is unavailable';end if;
 if initial.project_id is not null then
  perform 1 from public.projects where projects.id=initial.project_id and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='A selected project is archived or unavailable';end if;
 end if;
 select * into t from public.tasks where tasks.id=completion_selection_task.id for share nowait;
 if not found or t.task_generation is distinct from initial.task_generation or t.project_id is distinct from initial.project_id or t.user_id is distinct from initial.user_id then
  raise exception using errcode='PT409',message='A selected task moved or changed';end if;
 if root_completion and (t.task_generation is null or t.completion_version is null or t.completion_version not between 0 and 9007199254740990
  or t.completed is null or t.is_heading or (t.completed and t.completed_at is null) or (not t.completed and t.completed_at is not null)) then
  raise exception using errcode='PT409',message='Review a selected task completion';end if;
 if team is not null then
  if coalesce(taskfold_private.team_project_role(a,t.project_id),'') not in('manager','editor')
   or not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=t.id and c.generation=t.task_generation and c.team_id=team and c.project_id=t.project_id) then
   raise exception using errcode='42501',message='A selected team task is unavailable';end if;
 elsif t.project_id is not null and not coalesce(public.has_project_access(a,t.project_id),false) then
  raise exception using errcode='42501',message='Editing access changed';end if;
 if octet_length(to_jsonb(t)::text)>2000000 then raise exception using errcode='54000',message='This selected task is too large';end if;
 perform taskfold_private.team_actor();return t;
end$$;

create or replace function taskfold_private.completion_selection_root(id uuid) returns public.tasks
language sql volatile security invoker set search_path='' as $$select taskfold_private.completion_selection_task(id,true)$$;

create function taskfold_private.mixed_completion_legacy_identity(a uuid,q uuid) returns boolean
language sql volatile security invoker set search_path='' as $$
 select exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.personal_task_move_preparations where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_transfers where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_adoptions where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.child_task_repairs where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
 or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q)
$$;
create function taskfold_private.guard_mixed_completion_identity() returns trigger
language plpgsql volatile security invoker set search_path='' as $$
declare d jsonb:=to_jsonb(new);a uuid;q uuid;refs uuid[];v text;begin
 a:=(d->>'actor_id')::uuid;q:=(d->>'request_id')::uuid;
 if a is null or q is null then return new;end if;
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73920)) then raise exception using errcode='55P03',message='This request identity is finishing';end if;refs:=array[q];
 foreach v in array array['undo_of','undoes','restores','related_request'] loop
  if coalesce(d->>v,'')<>'' then refs:=array_append(refs,(d->>v)::uuid);end if;
 end loop;
 if exists(select 1 from taskfold_private.mixed_completion_members m where m.actor_id=a and m.request_id=any(refs)
  and not exists(select 1 from taskfold_private.mixed_completion_scope s where s.transaction_id=txid_current() and s.actor_id=a
   and ((s.batch_id=m.batch_id and s.request_id=m.request_id) or (s.original_batch_id=m.batch_id and s.original_request_id=m.request_id)))) then
  raise exception using errcode='PT409',message='Review this original mixed selection together';end if;
 return new;
end$$;
do $$declare t text;begin
 foreach t in array array['child_task_edit_preparations','child_task_edit_receipts','child_task_edit_closures','child_task_completion_receipts','child_task_completion_closures',
 'child_task_structure_receipts','child_task_structure_closures','personal_task_move_preparations','child_task_transfers','child_task_adoptions','child_task_repairs','team_task_edits','team_task_batches'] loop
  execute format('create trigger mixed_selection_identity before insert or update on taskfold_private.%I for each row execute function taskfold_private.guard_mixed_completion_identity()',t);
 end loop;
end$$;

create function taskfold_private.validate_mixed_completion(b jsonb,a uuid) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare v jsonb;c jsonb;g jsonb;q uuid;id uuid;target text;targets text[]:='{}';requests uuid[]:='{}';changed text[]:='{}';baseline jsonb;stamp timestamptz;mode text;begin
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>131072 or b->'protocol' is distinct from '1'::jsonb
  or not(b ?& array['protocol','account','batch_id','action','completed_at','input_zone','roots','children','items'])
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','batch_id','action','completed_at','input_zone','roots','children','items'))
  or jsonb_typeof(b->'roots') is distinct from 'array' or jsonb_typeof(b->'children') is distinct from 'array' or jsonb_typeof(b->'items') is distinct from 'array' then
  raise exception using errcode='22023',message='Review this saved mixed selection';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This selection belongs to another account';end if;
 perform taskfold_private.team_uuid(b,'batch_id');mode:=b->>'action';
 if jsonb_typeof(b->'action') is distinct from 'string' or mode not in('complete','reopen')
  or jsonb_array_length(b->'roots')+jsonb_array_length(b->'children') not between 1 and 32 or jsonb_array_length(b->'items') not between 1 and 32
  or jsonb_typeof(b->'completed_at') is distinct from 'string' or length(b->>'completed_at')>64
  or (b->>'completed_at')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.[0-9]+)?(Z|[+-]\d{2}:\d{2})$'
  or jsonb_typeof(b->'input_zone') is distinct from 'string' or length(b->>'input_zone')>128
  or not exists(select 1 from pg_timezone_names where name=b->>'input_zone') then raise exception using errcode='22023',message='Use one selection action and saved completion clock';end if;
 begin stamp:=(b->>'completed_at')::timestamptz;exception when others then raise exception using errcode='22023',message='Review the saved completion clock';end;
 if not isfinite(stamp) then raise exception using errcode='22023',message='Review the saved completion clock';end if;
 for g in select * from jsonb_array_elements(b->'roots') loop
  if jsonb_typeof(g)<>'object' or not(g ?& array['task_id','baseline','source_hash']) or exists(select 1 from jsonb_object_keys(g) k where k not in('task_id','baseline','source_hash'))
   or jsonb_typeof(g->'baseline') is distinct from 'object' or jsonb_typeof(g->'source_hash') is distinct from 'string' or (g->>'source_hash')!~'^[0-9a-f]{64}$' then raise exception using errcode='22023',message='Review a selected parent observation';end if;
  id:=taskfold_private.team_uuid(g,'task_id');baseline:=g->'baseline';
  if not(baseline ?& array['id','user_id','task_generation','project_id','section_id','completed','completed_at','completion_version','is_heading','is_recurring'])
   or exists(select 1 from jsonb_object_keys(baseline) k where k not in('id','user_id','task_generation','project_id','section_id','completed','completed_at','completion_version','is_heading','is_recurring'))
   or baseline->'id' is distinct from to_jsonb(id) or jsonb_typeof(baseline->'completed') is distinct from 'boolean'
   or baseline->'is_heading' not in('null'::jsonb,'false'::jsonb) or baseline->'is_recurring' not in('null'::jsonb,'true'::jsonb,'false'::jsonb)
   or jsonb_typeof(baseline->'completion_version') is distinct from 'number' or (baseline->>'completion_version')!~'^[0-9]{1,16}$'
   or (baseline->>'completion_version')::numeric not between 0 and 9007199254740990 then raise exception using errcode='22023',message='Review a selected parent baseline';end if;
  perform taskfold_private.team_uuid(baseline,'user_id');perform taskfold_private.team_uuid(baseline,'task_generation');
  if baseline->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(baseline,'project_id');end if;
  if baseline->'section_id'<>'null'::jsonb then perform taskfold_private.team_uuid(baseline,'section_id');end if;
  if baseline->'completed'='true'::jsonb then
   if jsonb_typeof(baseline->'completed_at') is distinct from 'string' or length(baseline->>'completed_at')>64 then raise exception using errcode='22023',message='Review a selected completion time';end if;
   begin stamp:=(baseline->>'completed_at')::timestamptz;exception when others then raise exception using errcode='22023',message='Review a selected completion time';end;
   if not isfinite(stamp) then raise exception using errcode='22023',message='Review a selected completion time';end if;
  elsif baseline->'completed_at'<>'null'::jsonb then raise exception using errcode='22023',message='Review a selected completion time';end if;
  target:=jsonb_build_array('root',id)::text;
  if target collate "C"=any(targets) then raise exception using errcode='22023',message='Select each task once';end if;targets:=array_append(targets,target);
 end loop;
 for g in select * from jsonb_array_elements(b->'children') loop
  if jsonb_typeof(g)<>'object' or not(g ?& array['task_id','task_generation','project_id','node_key','incarnation','revision','baseline'])
   or exists(select 1 from jsonb_object_keys(g) k where k not in('task_id','task_generation','project_id','node_key','incarnation','revision','baseline')) then raise exception using errcode='22023',message='Review a selected child observation';end if;
  c:=g||jsonb_build_object('protocol',1,'account',a,'request_id','00000000-0000-4000-8000-000000000001','action',case when g->'baseline'->'completed'='true'::jsonb then 'reopen' else 'complete' end);
  perform taskfold_private.validate_child_completion_request(c,a);
  target:=jsonb_build_array('child',g->'task_id',g->'node_key')::text;
  if target collate "C"=any(targets) then raise exception using errcode='22023',message='Select each subtask once';end if;targets:=array_append(targets,target);
 end loop;
 for v in select * from jsonb_array_elements(b->'items') loop
  if jsonb_typeof(v)<>'object' then raise exception using errcode='22023',message='Review this selection action';end if;
  if v->>'kind'='root' then
   if not(v ?& array['kind','request_id','task_id']) or exists(select 1 from jsonb_object_keys(v) k where k not in('kind','request_id','task_id')) then raise exception using errcode='22023',message='Review this parent action';end if;
   q:=taskfold_private.team_uuid(v,'request_id');id:=taskfold_private.team_uuid(v,'task_id');target:=jsonb_build_array('root',id)::text;
   select x into g from jsonb_array_elements(b->'roots') x where x->'task_id'=to_jsonb(id);
  elsif v->>'kind'='child' then
   if not(v ?& array['kind','command']) or exists(select 1 from jsonb_object_keys(v) k where k not in('kind','command')) then raise exception using errcode='22023',message='Review this child action';end if;
   c:=v->'command';perform taskfold_private.validate_child_completion_request(c,a);q:=taskfold_private.team_uuid(c,'request_id');
   if c->>'action'<>mode then raise exception using errcode='22023',message='Choose one selection action';end if;
   target:=jsonb_build_array('child',c->'task_id',c->'node_key')::text;
   select x into g from jsonb_array_elements(b->'children') x where x->'task_id'=c->'task_id' and x->'node_key'=c->'node_key';
   if g is distinct from c-array['protocol','account','request_id','action'] then raise exception using errcode='22023',message='Keep the selected child observation';end if;
  else raise exception using errcode='22023',message='Review this selection action kind';end if;
  if g is null or not(target collate "C"=any(targets)) or target collate "C"=any(changed) or q=any(requests) or q=taskfold_private.team_uuid(b,'batch_id')
   or coalesce((g->'baseline'->>'completed')::boolean,false)=(mode='complete') then raise exception using errcode='22023',message='Each changed selected task needs one distinct original request';end if;
  changed:=array_append(changed,target);requests:=array_append(requests,q);
 end loop;
 if exists(select 1 from (select 'root' kind,x from jsonb_array_elements(b->'roots') x union all select 'child',x from jsonb_array_elements(b->'children') x) z
  where coalesce((x->'baseline'->>'completed')::boolean,false)<>(mode='complete') and not(jsonb_build_array(kind,x->'task_id')::text collate "C"=any(changed))
   and (kind='root' or not(jsonb_build_array(kind,x->'task_id',x->'node_key')::text collate "C"=any(changed)))) then
  raise exception using errcode='22023',message='Keep every changed member of this selection';end if;
end$$;

create function taskfold_private.guard_mixed_completion_children(b jsonb) returns void
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
declare g jsonb;t public.tasks;p taskfold_private.child_task_projections;n taskfold_private.child_task_records;current_state jsonb;begin
 for g in select * from jsonb_array_elements(b->'children') loop
  t:=taskfold_private.completion_selection_task((g->>'task_id')::uuid,false);
  if g->'task_generation' is distinct from coalesce(to_jsonb(t.task_generation),'null'::jsonb)
   or g->'project_id' is distinct from coalesce(to_jsonb(t.project_id),'null'::jsonb) then raise exception using errcode='PT409',message='A selected child task moved or changed';end if;
  select * into p from taskfold_private.child_task_projections where task_id=t.id;
  if not found or p.state<>'ready' or p.task_generation is distinct from t.task_generation or p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb) then
   raise exception using errcode='PT409',message='Review a selected child hierarchy';end if;
  select * into n from taskfold_private.child_task_records where task_id=t.id and node_key=(g->>'node_key') collate "C";
  if not found or n.incarnation<>(g->>'incarnation')::uuid or n.revision<(g->>'revision')::bigint then
   raise exception using errcode='PT409',message='A selected child identity changed';end if;
  current_state:=taskfold_private.child_task_completion_state(n.fields);
  if current_state is distinct from g->'baseline' or (not(current_state ? 'taskfold_completion_v1') and n.revision<>(g->>'revision')::bigint) then
   raise exception using errcode='PT409',message='A selected child completion changed';end if;
 end loop;
end$$;

create function taskfold_private.mixed_completion_recipient(person uuid,p uuid,owner_id uuid,team uuid) returns boolean
language sql volatile security invoker set search_path='' as $$
 select person is null or (exists(select 1 from auth.users u where u.id=person and (u.banned_until is null or u.banned_until<=clock_timestamp()))
 and case when team is not null then coalesce(taskfold_private.team_project_role(person,p),'') in('manager','editor')
 when p is null then person=owner_id else coalesce(public.has_project_access(person,p),false) end)
$$;
create function taskfold_private.mixed_completion_successor_children(rows jsonb,p uuid,owner_id uuid,q uuid,team uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare n jsonb;r jsonb:='[]';person uuid;begin
 if jsonb_typeof(rows) is distinct from 'array' then return rows;end if;
 for n in select * from jsonb_array_elements(rows) loop
  if jsonb_typeof(n) is distinct from 'object' or jsonb_typeof(n->'id') is distinct from 'string' then raise exception using errcode='PT409',message='Review the next occurrence hierarchy';end if;
  n:=n||jsonb_build_object('taskfold_completion_v1',jsonb_build_object('epoch',taskfold_private.team_checklist_epoch(q,n->>'id'),'version',0));
  if coalesce(n->>'assigned_to','')<>'' then
   person:=taskfold_private.team_uuid(jsonb_build_object('id',n->'assigned_to'),'id');
   if not taskfold_private.mixed_completion_recipient(person,p,owner_id,team) then n:=n||'{"assigned_to":null}'::jsonb;end if;
  end if;
  if jsonb_typeof(n->'subtasks')='array' then n:=jsonb_set(n,'{subtasks}',taskfold_private.mixed_completion_successor_children(n->'subtasks',p,owner_id,q,team));end if;
  r:=r||jsonb_build_array(n);
 end loop;return r;
end$$;

-- Called only after the outer selection has locked/validated every member and
-- reserved every request. Parent writes run before child writes; a successor is
-- based on the captured source and never consumes a partially updated branch.
create function taskfold_private.apply_mixed_completion_root(b jsonb,item jsonb,plan jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
<<root_op>>
declare a uuid:=auth.uid();id uuid:=(item->>'task_id')::uuid;q uuid:=(item->>'request_id')::uuid;t public.tasks;after_root public.tasks;
 successor public.tasks;payload jsonb;before_state jsonb;team uuid;planned uuid;next_state text:='none';created boolean:=false;next_hash text;
begin
 if not exists(select 1 from taskfold_private.mixed_completion_scope s where s.transaction_id=txid_current() and s.actor_id=a and s.batch_id=(b->>'batch_id')::uuid and s.request_id=q) then
  raise exception using errcode='42501',message='Use the complete original mixed selection';end if;
 select * into t from public.tasks where tasks.id=root_op.id;
 before_state:=taskfold_private.completion_selection_root_baseline(t);
 select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
 if plan is not null and plan<>'null'::jsonb then
  planned:=(plan->>'id')::uuid;
  if planned=t.id or planned=coalesce(t.recurrence_parent_id,t.id) then raise exception using errcode='PT409',message='The next occurrence identity conflicts';end if;
  if (select count(*) from public.tasks x where x.id=planned or (x.recurrence_parent_id=coalesce(t.recurrence_parent_id,t.id) and x.due_date=(plan->>'due_date')::date))>1 then
   raise exception using errcode='PT409',message='Review the existing recurring occurrences';end if;
  select * into successor from public.tasks x where x.id=planned or (x.recurrence_parent_id=coalesce(t.recurrence_parent_id,t.id) and x.due_date=(plan->>'due_date')::date);
  if found then
   if successor.project_id is distinct from t.project_id or successor.recurrence_parent_id is distinct from coalesce(t.recurrence_parent_id,t.id)
    or successor.due_date is distinct from (plan->>'due_date')::date or successor.task_generation is null or successor.is_heading
    or (team is not null and not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=successor.id and c.generation=successor.task_generation and c.team_id=team and c.project_id=t.project_id))
    or (team is null and (taskfold_private.is_team_content_task(successor.id) or (t.project_id is null and successor.user_id<>a))) then raise exception using errcode='PT409',message='The recurring occurrence identity is unavailable';end if;
   next_state:='existing';
  elsif exists(select 1 from taskfold_private.task_generations h where h.task_id=planned and not exists(select 1 from taskfold_private.team_provisional_retirements r where r.task_id=h.task_id and r.generation=h.generation)) then
   next_state:='retired';
  else
   payload:=taskfold_private.automation_successor(to_jsonb(t),a,(b->>'completed_at')::timestamptz,b->>'input_zone',q,gen_random_uuid());
   if payload->'id' is distinct from to_jsonb(planned) then raise exception using errcode='PT409',message='Review the next occurrence plan';end if;
   payload:=jsonb_set(payload,'{subtasks}',taskfold_private.mixed_completion_successor_children(payload->'subtasks',t.project_id,a,q,team));
   if payload->'assigned_to'<>'null'::jsonb and not taskfold_private.mixed_completion_recipient((payload->>'assigned_to')::uuid,t.project_id,a,team) then payload:=payload||'{"assigned_to":null}'::jsonb;end if;
   successor:=jsonb_populate_record(null::public.tasks,payload);
   if octet_length(to_jsonb(successor)::text)>2000000 then raise exception using errcode='54000',message='The next occurrence is too large';end if;
   if team is not null then insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
    values(txid_current(),team,t.project_id,successor.id,successor.task_generation,a,'create',q);end if;
   insert into public.tasks select (successor).* returning * into successor;
   perform taskfold_private.adopt_child_task_records(successor.id,successor.task_generation,successor.subtasks);
   perform taskfold_private.read_child_task_records(successor.id,successor.task_generation);
   if team is not null then delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=successor.id;end if;
   next_state:='created';created:=true;
  end if;
  if successor.id is not null then next_hash:=taskfold_private.team_completion_task_hash(successor);end if;
 end if;
 if team is not null then insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
  values(txid_current(),team,t.project_id,t.id,t.task_generation,a,'patch',q);end if;
 update public.tasks set completed=(b->>'action'='complete'),completed_at=case when b->>'action'='complete' then (b->>'completed_at')::timestamptz else null end
  where tasks.id=t.id returning * into after_root;
 if team is not null then
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=t.id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation)
   values(team,q,a,encode(extensions.digest(convert_to(jsonb_build_array(b,item)::text,'UTF8'),'sha256'),'hex'),t.id,t.task_generation,'patch');
 end if;
 if after_root.completed is distinct from (b->>'action'='complete')
  or after_root.completed_at is distinct from (case when b->>'action'='complete' then (b->>'completed_at')::timestamptz else null end)
  or after_root.completion_version<>t.completion_version+1
  or (to_jsonb(after_root)-array['completed','completed_at','completion_version','updated_at']) is distinct from (to_jsonb(t)-array['completed','completed_at','completion_version','updated_at']) then
  raise exception using errcode='PT409',message='This parent completion could not be confirmed';end if;
 return jsonb_build_object('kind','root','request_id',q,'task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'action',b->'action',
 'before',before_state,'after',taskfold_private.completion_selection_root_baseline(after_root),
 'successor',jsonb_build_object('state',next_state,'planned_id',planned,'id',successor.id,'generation',successor.task_generation,'created',created,'hash',next_hash));
end$$;

create function taskfold_private.mixed_completion_reply(r taskfold_private.mixed_completion_batches,replayed boolean) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'batch_id',r.batch_id,'outcome',r.outcome,'replayed',replayed,'receipts',
 coalesce((select jsonb_agg((case when value->>'kind'='child' then jsonb_set(value,'{receipt,replayed}',to_jsonb(replayed)) else value end)||jsonb_build_object('replayed',replayed) order by ordinal)
 from jsonb_array_elements(r.receipts) with ordinality x(value,ordinal)),'[]'::jsonb))
$$;

-- The source fingerprint also freezes a separate series parent's identity.
-- It remains opaque to clients; ordinary/root-series hashes keep their format.
create or replace function taskfold_private.completion_selection_root_hash(t public.tasks) returns text
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.digest(convert_to(case when t.is_recurring and t.recurrence_parent_id is not null and t.recurrence_parent_id<>t.id then
 jsonb_build_array(to_jsonb(t),(select jsonb_build_object('id',p.id,'generation',p.task_generation,'project',p.project_id,'owner',p.user_id) from public.tasks p where p.id=t.recurrence_parent_id))::text
 else to_jsonb(t)::text end,'UTF8'),'sha256'),'hex')
$$;
create function taskfold_private.mixed_completion_can_edit(t public.tasks) returns boolean
language sql volatile security invoker set search_path='' as $$
 select case when taskfold_private.is_team_content_project(t.project_id) then
 exists(select 1 from taskfold_private.team_content_projects c join taskfold_private.teams x on x.id=c.team_id
 where c.project_id=t.project_id and x.state='active' and coalesce(taskfold_private.team_project_role(auth.uid(),t.project_id),'') in('manager','editor')
 and exists(select 1 from taskfold_private.team_content_tasks n where n.task_id=t.id and n.generation=t.task_generation and n.team_id=c.team_id and n.project_id=t.project_id))
 when taskfold_private.is_team_content_task(t.id) then false
 when t.project_id is null then t.user_id=auth.uid() else coalesce(public.has_project_access(auth.uid(),t.project_id),false) end
$$;

create function taskfold_private.mixed_completion(b jsonb,closing boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<mixed_op>>
declare a uuid:=auth.uid();batch uuid;fingerprint text;prior taskfold_private.mixed_completion_batches;
 item jsonb;v jsonb;g jsonb;t public.tasks;parent public.tasks;candidate public.tasks;fresh public.tasks;
 source_ids uuid[];lock_ids uuid[];project_ids uuid[]:='{}';team_ids uuid[]:='{}';recipient_ids uuid[]:='{}';extra_ids uuid[]:='{}';team uuid;parent_team uuid;id uuid;q uuid;sid uuid;planned uuid;
 observed jsonb:='{}';extras jsonb:='{}';plans jsonb:='{}';plan jsonb;decoded jsonb;bytes bigint:=0;created_bytes bigint:=0;proof jsonb;receipts jsonb:='[]';ordered jsonb:='{}';ordinal int;root_selected boolean;root_changing boolean;needs_tree boolean;
begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_mixed_completion(b,a);
 batch:=taskfold_private.team_uuid(b,'batch_id');fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 select * into prior from taskfold_private.mixed_completion_batches where actor_id=a and batch_id=batch;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This original selection identity was already used';end if;
  if not closing and prior.outcome='closed' then raise exception using errcode='PT410',message='This original mixed selection is closed';end if;
  return taskfold_private.mixed_completion_reply(prior,true);
 end if;
 if (select count(*) from taskfold_private.mixed_completion_batches where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=128 then
  raise exception using errcode='PT429',message='Too many saved selection actions; try again later';end if;
 -- Reserve fresh member identities, including on metadata-only closure. Older
 -- individual/child-only APIs cannot later adopt or reverse one member alone.
 for item in select x from jsonb_array_elements(b->'items') x order by coalesce(x->>'request_id',x->'command'->>'request_id') collate "C" loop
  q:=case when item->>'kind'='root' then (item->>'request_id')::uuid else (item->'command'->>'request_id')::uuid end;
  if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73920)) then raise exception using errcode='55P03',message='A member identity is finishing';end if;
  if exists(select 1 from taskfold_private.mixed_completion_members where actor_id=a and request_id=q) or taskfold_private.mixed_completion_legacy_identity(a,q) then
   raise exception using errcode='PT409',message='A member identity already belongs to another saved action';end if;
 end loop;
 if not closing then
  perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and mixed_completions_enabled and mixed_completion_writes_enabled for share;
  if not found then raise exception using errcode='PT503',message='Mixed task completion is not enabled';end if;
  select array_agg(distinct z.id order by z.id) into source_ids from (
   select (x->>'task_id')::uuid id from jsonb_array_elements(b->'roots') x union all select (x->>'task_id')::uuid from jsonb_array_elements(b->'children') x) z;
  lock_ids:=source_ids;
  foreach id in array source_ids loop
   select * into t from public.tasks where tasks.id=mixed_op.id;
   if not found or not coalesce(taskfold_private.mixed_completion_can_edit(t),false) then raise exception using errcode='42501',message='Every selected task needs current editing access';end if;
   root_selected:=exists(select 1 from jsonb_array_elements(b->'roots') x where x->'task_id'=to_jsonb(id));
   root_changing:=exists(select 1 from jsonb_array_elements(b->'items') x where x->>'kind'='root' and x->'task_id'=to_jsonb(id));
   needs_tree:=exists(select 1 from jsonb_array_elements(b->'children') x where x->'task_id'=to_jsonb(id)) or (root_changing and b->>'action'='complete' and coalesce(t.is_recurring,false));
   bytes:=bytes+octet_length(to_jsonb(t)::text);
   if octet_length(to_jsonb(t)::text)>2000000 or bytes>4000000 then raise exception using errcode='54000',message='Select fewer tasks or review this large source';end if;
   team:=null;select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
   if team is not null then team_ids:=array_append(team_ids,team);end if;
   if t.project_id is not null then project_ids:=array_append(project_ids,t.project_id);end if;
   if t.assigned_to is not null then recipient_ids:=array_append(recipient_ids,t.assigned_to);end if;
   if needs_tree then
    decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
    if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review a selected hierarchy before completing it';end if;
    select recipient_ids||coalesce(array_agg(distinct person),'{}') into recipient_ids from
     (select (x->'fields'->>'assigned_to')::uuid person from jsonb_array_elements(decoded->'nodes') x where coalesce(x->'fields'->>'assigned_to','')<>'') z;
   end if;
   observed:=observed||jsonb_build_object(id::text,jsonb_build_object('generation',t.task_generation,'project',t.project_id,'owner',t.user_id,'tree',case when needs_tree then t.subtasks else null end,'needs_tree',needs_tree));
   if root_changing and b->>'action'='complete' and t.is_recurring then
    if t.due_date is null or not taskfold_private.automation_recurrence_valid(t.recurrence_pattern) then raise exception using errcode='PT409',message='Review the repeat rule before completing this selection';end if;
    sid:=coalesce(t.recurrence_parent_id,t.id);
    if sid<>t.id then
     select * into parent from public.tasks where tasks.id=sid;
     if not found or parent.task_generation is null or not coalesce(taskfold_private.mixed_completion_can_edit(parent),false) then raise exception using errcode='PT409',message='The original repeating task is unavailable';end if;
     parent_team:=null;select team_id into parent_team from taskfold_private.team_content_projects where project_id=parent.project_id;
     if parent_team is distinct from team then raise exception using errcode='PT409',message='Review this repeating family scope';end if;
     lock_ids:=array_append(lock_ids,sid);extra_ids:=array_append(extra_ids,sid);
     extras:=extras||jsonb_build_object(sid::text,jsonb_build_object('generation',parent.task_generation,'project',parent.project_id,'owner',parent.user_id));
     if parent.project_id is not null then project_ids:=array_append(project_ids,parent.project_id);end if;
     if parent_team is not null then team_ids:=array_append(team_ids,parent_team);end if;
    end if;
    plan:=taskfold_private.automation_recurrence_plan(to_jsonb(t),(b->>'completed_at')::timestamptz,b->>'input_zone');
    plans:=plans||jsonb_build_object(id::text,plan);
    if plan is not null then
     planned:=(plan->>'id')::uuid;lock_ids:=array_append(lock_ids,planned);
     for candidate in select * from public.tasks x where x.id=planned or (x.recurrence_parent_id=sid and x.due_date=(plan->>'due_date')::date) loop
      if candidate.project_id is distinct from t.project_id or candidate.recurrence_parent_id is distinct from sid or candidate.due_date is distinct from (plan->>'due_date')::date
       or candidate.task_generation is null or not coalesce(taskfold_private.mixed_completion_can_edit(candidate),false) then raise exception using errcode='PT409',message='A recurring occurrence identity is unavailable';end if;
      lock_ids:=array_append(lock_ids,candidate.id);extra_ids:=array_append(extra_ids,candidate.id);
      extras:=extras||jsonb_build_object(candidate.id::text,jsonb_build_object('generation',candidate.task_generation,'project',candidate.project_id,'owner',candidate.user_id));
     end loop;
    end if;
   end if;
  end loop;
  -- All resource locks are acquired without waiting before any source write.
  perform 1 from auth.users where users.id=any(recipient_ids) order by users.id for share nowait;
  perform 1 from taskfold_private.teams where teams.id=any(team_ids) order by teams.id for share nowait;
  perform 1 from taskfold_private.team_config where singleton for share nowait;
  perform 1 from taskfold_private.team_project_config where singleton for share nowait;
  perform 1 from taskfold_private.team_content_projects where project_id=any(project_ids) order by project_id for share nowait;
  perform 1 from public.projects where projects.id=any(project_ids) order by projects.id for share nowait;
  for item in select x from jsonb_array_elements(b->'items') x order by coalesce(x->>'request_id',x->'command'->>'request_id') collate "C" loop
   q:=case when item->>'kind'='root' then (item->>'request_id')::uuid else (item->'command'->>'request_id')::uuid end;
   id:=case when item->>'kind'='root' then (item->>'task_id')::uuid else (item->'command'->>'task_id')::uuid end;
   if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73917)) or not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then
    raise exception using errcode='55P03',message='Another selected request is finishing';end if;
   team:=null;select c.team_id into team from public.tasks x join taskfold_private.team_content_projects c on c.project_id=x.project_id where x.id=mixed_op.id;
   if team is not null and not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) then raise exception using errcode='55P03',message='Another selected team action is finishing';end if;
  end loop;
  for id in select distinct x from unnest(lock_ids) x order by x loop
   if not pg_try_advisory_xact_lock(hashtextextended(id::text,78137)) then raise exception using errcode='55P03',message='A selected task or occurrence is changing';end if;
  end loop;
  perform 1 from public.tasks where tasks.id=any(lock_ids) order by tasks.id for update nowait;
  foreach id in array source_ids loop
   root_selected:=exists(select 1 from jsonb_array_elements(b->'roots') x where x->'task_id'=to_jsonb(id));
   fresh:=taskfold_private.completion_selection_task(id,root_selected);v:=observed->id::text;
   if v->'generation' is distinct from coalesce(to_jsonb(fresh.task_generation),'null'::jsonb) or v->'project' is distinct from coalesce(to_jsonb(fresh.project_id),'null'::jsonb)
    or v->'owner' is distinct from to_jsonb(fresh.user_id) or ((v->>'needs_tree')::boolean and v->'tree' is distinct from coalesce(to_jsonb(fresh.subtasks),'null'::jsonb)) then
    raise exception using errcode='PT409',message='A selected source changed before admission';end if;
  end loop;
  foreach id in array extra_ids loop
   select * into fresh from public.tasks where tasks.id=mixed_op.id;
   if not found or not coalesce(taskfold_private.mixed_completion_can_edit(fresh),false) or extras->id::text is distinct from jsonb_build_object('generation',fresh.task_generation,'project',fresh.project_id,'owner',fresh.user_id) then
    raise exception using errcode='PT409',message='A repeating family or occurrence changed';end if;
  end loop;
  if jsonb_array_length(b->'roots')>0 then perform taskfold_private.guard_completion_selection_roots(jsonb_build_object('protocol',1,'account',a,'roots',b->'roots'));end if;
  perform taskfold_private.guard_mixed_completion_children(b);
 end if;
 insert into taskfold_private.mixed_completion_batches(actor_id,batch_id,fingerprint,outcome,receipts) values(a,batch,fingerprint,'closed','[]') returning * into prior;
 for item,ordinal in select x.value,x.ord::int-1 from jsonb_array_elements(b->'items') with ordinality x(value,ord) loop
  q:=case when item->>'kind'='root' then (item->>'request_id')::uuid else (item->'command'->>'request_id')::uuid end;
  id:=case when item->>'kind'='root' then (item->>'task_id')::uuid else (item->'command'->>'task_id')::uuid end;
  insert into taskfold_private.mixed_completion_members(actor_id,batch_id,request_id,ordinal,kind,task_id,node_key)
   values(a,batch,q,ordinal,item->>'kind',id,case when item->>'kind'='child' then item->'command'->>'node_key' else null end);
  if not closing then insert into taskfold_private.mixed_completion_scope(transaction_id,actor_id,batch_id,request_id) values(txid_current(),a,batch,q);end if;
 end loop;
 if not closing then
  for item,ordinal in select x.value,x.ord::int-1 from jsonb_array_elements(b->'items') with ordinality x(value,ord) where x.value->>'kind'='root' loop
   proof:=taskfold_private.apply_mixed_completion_root(b,item,plans->(item->>'task_id'));
   if proof->'successor'->'created'='true'::jsonb then
    select created_bytes+octet_length(to_jsonb(x)::text) into created_bytes from public.tasks x where x.id=(proof->'successor'->>'id')::uuid;
    if created_bytes>4000000 then raise exception using errcode='54000',message='The next occurrences are too large for one selection';end if;
   end if;
   ordered:=ordered||jsonb_build_object(ordinal::text,proof);
  end loop;
  for item,ordinal in select x.value,x.ord::int-1 from jsonb_array_elements(b->'items') with ordinality x(value,ord) where x.value->>'kind'='child' loop
   proof:=taskfold_private.complete_child_task(item->'command');ordered:=ordered||jsonb_build_object(ordinal::text,jsonb_build_object('kind','child','request_id',proof->'request_id','receipt',proof));
  end loop;
  select jsonb_agg(value order by key::integer) into receipts from jsonb_each(ordered);
  perform taskfold_private.team_actor();
  foreach id in array source_ids loop
   select * into fresh from public.tasks where tasks.id=mixed_op.id;
   if not found or not coalesce(taskfold_private.mixed_completion_can_edit(fresh),false) then raise exception using errcode='42501',message='Editing access changed';end if;
  end loop;
  update taskfold_private.mixed_completion_batches set outcome='applied',receipts=mixed_op.receipts where actor_id=a and batch_id=batch returning * into prior;
  delete from taskfold_private.mixed_completion_scope where transaction_id=txid_current() and actor_id=a and batch_id=batch;
 end if;
 return taskfold_private.mixed_completion_reply(prior,false);
end$$;
create function public.taskfold_complete_mixed_tasks(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.mixed_completion(_body,false)$$;
create function public.taskfold_close_mixed_completion(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.mixed_completion(_body,true)$$;
revoke all on function taskfold_private.completion_selection_task(uuid,boolean),taskfold_private.mixed_completion_legacy_identity(uuid,uuid),
 taskfold_private.guard_mixed_completion_identity(),taskfold_private.validate_mixed_completion(jsonb,uuid),taskfold_private.guard_mixed_completion_children(jsonb),
 taskfold_private.mixed_completion_recipient(uuid,uuid,uuid,uuid),taskfold_private.mixed_completion_successor_children(jsonb,uuid,uuid,uuid,uuid),
 taskfold_private.apply_mixed_completion_root(jsonb,jsonb,jsonb),taskfold_private.mixed_completion_reply(taskfold_private.mixed_completion_batches,boolean),
 taskfold_private.mixed_completion_can_edit(public.tasks),taskfold_private.mixed_completion(jsonb,boolean),
 public.taskfold_complete_mixed_tasks(jsonb),public.taskfold_close_mixed_completion(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.mixed_completion(jsonb,boolean),public.taskfold_complete_mixed_tasks(jsonb),public.taskfold_close_mixed_completion(jsonb) to authenticated;
