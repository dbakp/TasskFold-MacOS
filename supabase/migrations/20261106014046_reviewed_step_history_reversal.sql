-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Compose reviewed step history against a fresh structural read.
-- Exact inserted-record digests still refuse changed content or placement;
-- unrelated work and live container contents are preserved.
create or replace function taskfold_private.edit_child_step_batch(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
<<op>>
declare a uuid:=auth.uid();id uuid;q uuid;g uuid;p uuid;team uuid;initial public.tasks;t public.tasks;
 projection taskfold_private.child_task_projections;n taskfold_private.child_task_records;destination taskfold_private.child_task_records;
 prior taskfold_private.child_task_step_receipts;original taskfold_private.child_task_step_receipts;
 batch_nodes jsonb:='[]';step jsonb;digests jsonb:='{}';offset_value integer:=0;key text;parent text;mode text;undo_id uuid;fingerprint text;rev bigint;slot integer;container_kind text;
 decoded jsonb;extra_decoded jsonb;extra_tree jsonb:='[]';subtree jsonb;desired jsonb;inverse jsonb:='{}';
 recipients uuid[];current_recipients uuid[];replaying boolean;archive_size bigint;archive_count bigint;
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled and step_batches_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child structure editing is not enabled';end if;
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_step_request(b,a);
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');
 g:=case when b->'task_generation'='null'::jsonb then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null'::jsonb then null else taskfold_private.team_uuid(b,'project_id') end;
 mode:=b->>'action';rev:=(b->>'structure_revision')::bigint;key:=b->>'node_key';parent:=b->>'parent_key';slot:=(b->>'index')::integer;
 fingerprint:=encode(extensions.digest(convert_to('child-step-batch-v1:'||b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_step_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original structure action is closed';end if;
 if exists(select 1 from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q) then raise exception using errcode='PT409',message='This request identity belongs to another child action';end if;
 select * into prior from taskfold_private.child_task_step_receipts where actor_id=a and request_id=q;
 replaying:=found;
 if replaying and prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This structure identity was already used';end if;
 if not replaying then
  if mode='insert' then
   for step in select * from jsonb_array_elements(b->'steps') loop
    subtree:=taskfold_private.child_structure_fresh_node(step,false);
    extra_tree:=extra_tree||jsonb_build_array(subtree);
   end loop;
   key:=extra_tree->0->>'id';
  else
   undo_id:=taskfold_private.team_uuid(b,'undo_of');
   select * into original from taskfold_private.child_task_step_receipts where actor_id=a and request_id=undo_id;
   if not found or original.action<>'insert' or original.reversed_by is not null or original.task_id<>id or original.generation is distinct from g or original.project_id is distinct from p then raise exception using errcode='PT409',message='These steps can no longer be undone';end if;
   key:=original.node_key;batch_nodes:=original.nodes;
  end if;
 end if;
 select * into initial from public.tasks where tasks.id=op.id;
 if not found or initial.task_generation is distinct from g or initial.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if octet_length(coalesce(initial.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 decoded:=taskfold_private.decode_child_task_tree(initial.subtasks);extra_decoded:=taskfold_private.decode_child_task_tree(extra_tree);
 if decoded->>'state'<>'ready' or extra_decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 -- Lock all existing/new/restored recipients before team/project/root locks.
 select array_agg(distinct recipient order by recipient) into recipients from (
  select initial.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements((decoded->'nodes')||(extra_decoded->'nodes')) x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 perform 1 from auth.users where users.id=any(coalesce(recipients,'{}')) order by users.id for share;
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if team is not null then
  perform 1 from taskfold_private.teams where teams.id=team and state='active' for share;
  if not found or coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
  if not replaying and exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x where x->'fields'->'is_heading'='true'::jsonb) then
   perform 1 from taskfold_private.team_project_config where singleton and native_task_types_enabled for share;
   if not found then raise exception using errcode='PT503',message='Shared task types are not enabled';end if;
  end if;
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is paused';end if;
  perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 elsif taskfold_private.is_team_content_task(id) then raise exception using errcode='42501',message='This task is unavailable';
 elsif p is null then
  if initial.user_id<>a then raise exception using errcode='42501',message='This task is unavailable';end if;
 elsif not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if p is not null then
  perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73917));
 if team is not null then perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));end if;
 if (exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q)
  or (team is not null and (exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q) or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q)))) and not replaying then raise exception using errcode='PT409',message='This action identity was already used';end if;
 select * into t from public.tasks where tasks.id=op.id for update;
 if not found or t.task_generation is distinct from g or t.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 if replaying then return taskfold_private.child_step_receipt(prior,true);end if;
 if octet_length(coalesce(t.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 -- Verify stored records against the actual tree, not just a saved source hash.
 perform taskfold_private.read_child_task_records(id,g);
 select * into projection from taskfold_private.child_task_projections where task_id=id;
 if projection.structure_revision<>rev or projection.structure_revision>=9007199254740991 or projection.revision>=9007199254740991 then raise exception using errcode='PT409',message='The hierarchy changed; review this structure action';end if;
 decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
 select array_agg(distinct recipient order by recipient) into current_recipients from (
  select t.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 if not coalesce(current_recipients,'{}')<@coalesce(recipients,'{}') then raise exception using errcode='PT409',message='Assignments changed; review this structure action';end if;
 if mode='insert' then
  if t.completed or t.is_heading then raise exception using errcode='PT409',message='Choose an unfinished task';end if;
  if parent is null then
   container_kind:=case when coalesce(t.subtasks,'null'::jsonb)='null'::jsonb then 'null' else 'array' end;
   if t.title collate "C" is distinct from (b->>'source_title') collate "C" then raise exception using errcode='PT409',message='The task title changed; review the steps again';end if;
  else
   select * into destination from taskfold_private.child_task_records where task_id=id and node_key=parent;
   if not found or destination.incarnation is distinct from (b->>'parent_incarnation')::uuid or destination.revision<>(b->>'parent_revision')::bigint
    or destination.fields->>'title' collate "C" is distinct from (b->>'source_title') collate "C" or destination.fields->'completed'='true'::jsonb or destination.fields->'is_heading'='true'::jsonb then raise exception using errcode='PT409',message='The destination changed; review the steps again';end if;
   container_kind:=destination.children_kind;
  end if;
  if exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x join taskfold_private.child_task_records cr on cr.task_id=id and cr.node_key=x->>'key' collate "C") then raise exception using errcode='PT409',message='A new step identity is already used';end if;
  desired:=coalesce(t.subtasks,'null'::jsonb);
  for step in select * from jsonb_array_elements(extra_tree) loop
   desired:=taskfold_private.child_structure_insert(desired,parent,slot+offset_value,step);offset_value:=offset_value+1;
  end loop;
  inverse:=jsonb_build_object('parent_key',parent,'container_kind',container_kind);
 else
  if original.after_revision>rev then raise exception using errcode='PT409',message='Review the current hierarchy before Undo';end if;
  desired:=coalesce(t.subtasks,'null'::jsonb);
  for step in select * from jsonb_array_elements(original.nodes) loop
   if taskfold_private.child_structure_digest(id,step->>'node_key') is distinct from original.inverse->'digests'->>(step->>'node_key') then raise exception using errcode='PT409',message='An added step changed; keep its new work';end if;
   desired:=taskfold_private.child_structure_remove(desired,step->>'node_key');
  end loop;
  -- A later sibling addition is unrelated work. Restore a former null/absent
  -- container only when removing this batch leaves that container empty.
  if original.inverse->>'container_kind'='array'
   or (original.inverse->>'parent_key' is null and desired='[]'::jsonb)
   or (original.inverse->>'parent_key' is not null and not exists(
    select 1 from jsonb_array_elements(taskfold_private.decode_child_task_tree(desired)->'nodes') x
    where x->>'parent' collate "C"=original.inverse->>'parent_key' collate "C")) then
   desired:=taskfold_private.child_structure_restore_container(desired,original.inverse->>'parent_key',original.inverse->>'container_kind');
  end if;
 end if;
 if desired is not distinct from coalesce(t.subtasks,'null'::jsonb) then raise exception using errcode='22023',message='Choose a different child slot';end if;
 if octet_length(desired::text)>2000000 or taskfold_private.decode_child_task_tree(desired)->>'state'<>'ready' then raise exception using errcode='54000',message='The resulting hierarchy needs review or exceeds its limits';end if;
 if (select count(*) from taskfold_private.child_task_step_receipts where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many structure actions; try again later';end if;
 if team is not null then
  if not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=id and c.generation=g and c.team_id=team) then raise exception using errcode='PT409',message='This team task changed';end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,p,id,g,a,'patch',q);
 end if;
 desired:=taskfold_private.prepare_child_record_tree(op.id,g,desired);
 update public.tasks set subtasks=case when desired='null'::jsonb then null else desired end where tasks.id=op.id returning * into t;
 if team is not null then
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,g,'child_structure');
 end if;
 if coalesce(t.subtasks,'null'::jsonb)<>desired or not exists(select 1 from taskfold_private.child_task_projections where task_id=id and structure_revision=rev+1 and source_tree=desired) then raise exception using errcode='PT409',message='This structure action could not be confirmed';end if;
 perform taskfold_private.read_child_task_records(id,g);perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 if mode='insert' then
  for step in select * from jsonb_array_elements(extra_tree) loop
   select * into n from taskfold_private.child_task_records where task_id=id and node_key=step->>'id';
   if not found then raise exception using errcode='PT409',message='The added steps could not be confirmed';end if;
   batch_nodes:=batch_nodes||jsonb_build_array(jsonb_build_object('node_key',n.node_key,'incarnation',n.incarnation));
   digests:=digests||jsonb_build_object(n.node_key,taskfold_private.child_structure_digest(id,n.node_key));
  end loop;
  inverse:=inverse||jsonb_build_object('digests',digests);
 end if;
 insert into taskfold_private.child_task_step_receipts(actor_id,request_id,fingerprint,task_id,generation,project_id,action,undo_of,before_revision,after_revision,node_key,nodes,inverse)
 values(a,q,fingerprint,id,g,p,mode,undo_id,rev,rev+1,key,batch_nodes,inverse) returning * into prior;
 if mode='undo' then update taskfold_private.child_task_step_receipts set reversed_by=q where actor_id=a and request_id=undo_id;end if;
 return taskfold_private.child_step_receipt(prior,false);
end$$;

commit;
