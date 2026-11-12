-- Stream one historical row at a time, retaining only an admitted byte budget.
-- The cursor pins one snapshot: no second aggregation can race the preflight.
create index task_node_activity_task_sequence on public.task_node_activity(task_id,sequence);
create function taskfold_private.child_repair_original_bounded(t public.tasks,review_digest text,repair_digest text) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare header text;parts text[]:='{}';part text;used bigint;row_count integer:=0;original jsonb;h public.task_node_activity;
 history_cursor no scroll cursor for select a.* from public.task_node_activity a where a.task_id=t.id order by a.sequence;
begin
 header:=jsonb_build_object('protocol',1,'root',to_jsonb(t),'subtasks_sql_null',t.subtasks is null,
  'projection',null,'records','[]'::jsonb,'authority',null,'review_digest',review_digest,'repair_digest',repair_digest)::text;
 -- JSONB's canonical text uses two bytes between array elements. Object key
 -- ordering changes no byte lengths; the final exact check guards this contract.
 used:=octet_length(header)+octet_length(', "child_history": []');
 if used>8000000 then raise exception using errcode='PT413',message='This original needs a larger-work archive';end if;
 open history_cursor;
 loop
  fetch next from history_cursor into h;
  exit when not found;
  if not taskfold_private.child_repair_history_visible(h) then raise exception using errcode='42501',message='Original history is unavailable in this account';end if;
  part:=to_jsonb(h)::text;
  used:=used+octet_length(part)+case when row_count=0 then 0 else 2 end;
  if used>8000000 then raise exception using errcode='PT413',message='This original needs a larger-work archive';end if;
  parts:=array_append(parts,part);row_count:=row_count+1;
 end loop;
 close history_cursor;
 original:=(left(header,length(header)-1)||', "child_history": ['||coalesce(array_to_string(parts,', '),'')||']}')::jsonb;
 if octet_length(original::text)<>used or used>8000000 then raise exception using errcode='PT413',message='This original needs a larger-work archive';end if;
 return original;
end$$;
revoke all on function taskfold_private.child_repair_original_bounded(public.tasks,text,text) from public,anon,authenticated,service_role;

-- Replace only the retired inner implementation. The current outer wrapper's
-- original-history authorization and the public caller-RLS wrapper stay intact.
create or replace function taskfold_private.commit_child_repair_before_history_access(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare actor uuid:=auth.uid();q uuid;root_id uuid;generation uuid;pid uuid;team uuid;fingerprint text;prior taskfold_private.child_task_repairs;
 t public.tasks;view jsonb;original jsonb;archive_id uuid;archive_digest text;archive_bytes integer;revision bigint;status text;current_workspace uuid;
begin
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(actor::text,73918));perform taskfold_private.team_actor();
 if operation is null or operation not in('send','check','close','original') or jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>70000
  or b->'protocol' is distinct from '1'::jsonb or not b ?& array['protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest','repair_digest','changes']
  or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','request_id','task_id','task_generation','project_id','workspace_id','review_digest','repair_digest','changes'))
  or jsonb_typeof(b->'changes') is distinct from 'array' or jsonb_array_length(b->'changes') not between 1 and 64 or octet_length((b->'changes')::text)>65536 then
  raise exception using errcode='22023',message='Review this saved repair request';end if;
 if taskfold_private.team_uuid(b,'account')<>actor then raise exception using errcode='42501',message='This repair belongs to another account';end if;
 q:=taskfold_private.team_uuid(b,'request_id');root_id:=taskfold_private.team_uuid(b,'task_id');
 if b->'task_generation'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'task_generation');end if;
 if b->'project_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'project_id');end if;
 if b->'workspace_id'<>'null'::jsonb then perform taskfold_private.team_uuid(b,'workspace_id');end if;
 if jsonb_typeof(b->'review_digest') is distinct from 'string' or (b->>'review_digest')!~'^[a-f0-9]{64}$'
  or jsonb_typeof(b->'repair_digest') is distinct from 'string' or (b->>'repair_digest')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Review the current repair proposal';end if;
 generation:=(b->>'task_generation')::uuid;pid:=(b->>'project_id')::uuid;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(actor::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing';end if;
 select * into prior from taskfold_private.child_task_repairs where actor_id=actor and request_id=q;
 if found then
  if prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This repair identity was already used';end if;
  if operation<>'original' then return taskfold_private.child_repair_reply(prior,true);end if;
  if prior.state<>'applied' then raise exception using errcode='PT409',message='This repair has no saved original';end if;
  -- Content recovery requires current access to the same root and realm. Only
  -- contentless receipt recovery survives deletion or access loss.
  t:=taskfold_private.child_adoption_root(root_id,generation,false);
  select team_id into current_workspace from taskfold_private.team_content_projects where project_id=t.project_id;
  if t.project_id is distinct from pid or current_workspace is distinct from prior.workspace_id then raise exception using errcode='42501',message='The original belongs to another task context';end if;
  select o.original into original from taskfold_private.child_task_repair_originals o where o.id=prior.archive_id
   and o.task_id=root_id and o.task_generation is not distinct from generation and o.project_id is not distinct from pid
   and o.team_id is not distinct from prior.workspace_id and (o.team_id is not null or o.owner_id=actor);
  if original is null then raise exception using errcode='42501',message='This original is unavailable';end if;
  if octet_length(original::text)<>prior.archive_bytes or encode(extensions.digest(convert_to(original::text,'UTF8'),'sha256'),'hex')<>prior.archive_digest then raise exception using errcode='PT409',message='This saved original needs recovery review';end if;
  perform taskfold_private.team_actor();
  return jsonb_build_object('protocol',1,'account',actor,'request_id',q,'archive_id',prior.archive_id,'archive_digest',prior.archive_digest,'original',original);
 end if;
 if operation='check' then return jsonb_build_object('protocol',1,'account',actor,'request_id',q,'state','unknown');end if;
 if operation='original' then raise exception using errcode='PT409',message='This repair has not saved an original';end if;
 if (select count(*) from taskfold_private.child_task_repairs where actor_id=actor and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many repair decisions; try later';end if;
 if operation='close' then
  -- Claimed workspace IDs must not reserve a different actor's team nonce.
  insert into taskfold_private.child_task_repairs(actor_id,request_id,fingerprint,state,task_id,task_generation,project_id,workspace_id,review_digest,repair_digest)
   values(actor,q,fingerprint,'closed',root_id,generation,pid,(b->>'workspace_id')::uuid,b->>'review_digest',b->>'repair_digest') returning * into prior;
  return taskfold_private.child_repair_reply(prior,false);
 end if;
 perform 1 from taskfold_private.child_task_record_config where singleton and repair_writes_enabled and repair_reviews_enabled and adoption_enabled
  and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Reviewed repairs are not enabled';end if;
 t:=taskfold_private.child_adoption_root(root_id,generation,true);
 view:=taskfold_private.preview_child_repair(b-'request_id'-'repair_digest');
 if view->>'repair_digest'<>b->>'repair_digest' or view->'proposal_valid'<>'true'::jsonb or view->'custody_blocker'<>'null'::jsonb then raise exception using errcode='PT409',message='This proposal needs another repair or custody review';end if;
 if taskfold_private.child_repair_history_conflict(t,b->'changes') then raise exception using errcode='PT409',message='These references need an explicit history custody review';end if;
 team:=(view->>'workspace_id')::uuid;
 if team is not null then
  if not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241)) then raise exception using errcode='55P03',message='Another workspace decision is finishing';end if;
  if not pg_try_advisory_xact_lock(hashtextextended(team::text,73928)) then raise exception using errcode='55P03',message='Another workspace original is being saved';end if;
 end if;
 original:=taskfold_private.child_repair_original_bounded(t,view->>'review_digest',view->>'repair_digest');
 archive_bytes:=octet_length(original::text);
 if archive_bytes>8000000 then raise exception using errcode='PT413',message='This original needs a larger-work archive';end if;
 if coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.actor_id=actor),0)+archive_bytes>64000000
  or (team is not null and coalesce((select sum(o.bytes) from taskfold_private.child_task_repair_originals o where o.team_id=team),0)+archive_bytes>256000000) then
  raise exception using errcode='PT429',message='Original storage is full; keep this task unchanged';end if;
 archive_id:=gen_random_uuid();archive_digest:=encode(extensions.digest(convert_to(original::text,'UTF8'),'sha256'),'hex');
 insert into taskfold_private.child_task_repair_originals(id,actor_id,owner_id,team_id,task_id,task_generation,project_id,request_id,original,bytes,digest)
  values(archive_id,actor,case when team is null then actor else null end,team,root_id,generation,pid,q,original,archive_bytes,archive_digest);
 -- The original exists before the first source write. Any trigger, authority,
 -- receipt or caller-RLS failure rolls back the archive and all derived writes.
 if team is not null then
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id)
   values(txid_current(),team,pid,root_id,generation,actor,'patch',q);
 end if;
 update public.tasks set subtasks=view->'proposed_tree' where id=root_id returning * into t;
 if team is not null then delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=root_id;end if;
 if t.subtasks is distinct from view->'proposed_tree' then raise exception using errcode='PT409',message='This repair could not be confirmed';end if;
 status:=taskfold_private.adopt_child_task_records(root_id,generation,t.subtasks);
 if status<>'ready' then raise exception using errcode='PT409',message='The repaired hierarchy is not ready';end if;
 select p.revision into revision from taskfold_private.child_task_projections p where p.task_id=root_id;
 if taskfold_private.promote_child_task_records(root_id,generation,pid,revision,t.subtasks)<>'records' then raise exception using errcode='PT409',message='The repaired hierarchy could not be adopted';end if;
 perform taskfold_private.team_actor();
 insert into taskfold_private.child_task_repairs(actor_id,request_id,fingerprint,state,task_id,task_generation,project_id,workspace_id,team_id,review_digest,repair_digest,archive_id,archive_digest,archive_bytes,node_count)
  values(actor,q,fingerprint,'applied',root_id,generation,pid,team,team,b->>'review_digest',b->>'repair_digest',archive_id,archive_digest,archive_bytes,(view->>'node_count')::integer) returning * into prior;
 return taskfold_private.child_repair_reply(prior,false);
end$$;
revoke all on function taskfold_private.commit_child_repair_before_history_access(text,jsonb) from public,anon,authenticated,service_role;
