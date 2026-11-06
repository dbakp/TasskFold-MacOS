-- Root observations for the future atomic root/child completion executor.
-- Read/guard only: no completion write endpoint or rollout enablement here.
alter table taskfold_private.child_task_record_config add column mixed_completions_enabled boolean not null default false;

create function taskfold_private.completion_selection_root_baseline(t public.tasks) returns jsonb
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select jsonb_build_object('id',t.id,'user_id',t.user_id,'task_generation',t.task_generation,
 'project_id',t.project_id,'section_id',t.section_id,'completed',t.completed,'completed_at',t.completed_at,
 'completion_version',t.completion_version,'is_heading',t.is_heading,'is_recurring',t.is_recurring)
$$;
create function taskfold_private.completion_selection_root_hash(t public.tasks) returns text
language sql stable security invoker set search_path='' set timezone='UTC' as $$
 select encode(extensions.digest(convert_to(to_jsonb(t)::text,'UTF8'),'sha256'),'hex')
$$;

-- Only trusted private callers can use this helper. It checks live authority,
-- protects the source row, and rejects incomplete/ambiguous root identities.
create function taskfold_private.completion_selection_root(id uuid) returns public.tasks
language plpgsql volatile security invoker set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();initial public.tasks;t public.tasks;team uuid;begin
 perform taskfold_private.team_actor();
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and mixed_completions_enabled for share;
 if not found then raise exception using errcode='PT503',message='Mixed task completion is not enabled';end if;
 select * into initial from public.tasks where tasks.id=completion_selection_root.id;
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
 select * into t from public.tasks where tasks.id=completion_selection_root.id for share nowait;
 if not found or t.task_generation is distinct from initial.task_generation or t.project_id is distinct from initial.project_id or t.user_id is distinct from initial.user_id then
  raise exception using errcode='PT409',message='A selected task moved or changed';end if;
 if t.task_generation is null or t.completion_version is null or t.completion_version not between 0 and 9007199254740990
  or t.completed is null or t.is_heading or (t.completed and t.completed_at is null) or (not t.completed and t.completed_at is not null) then
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

create function taskfold_private.read_completion_selection_roots(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare a uuid:=auth.uid();ids uuid[]:='{}';v jsonb;id uuid;t public.tasks;observed jsonb:='{}';reply jsonb;begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>8192 or b->'protocol' is distinct from '1'::jsonb
  or not(b ?& array['protocol','account','task_ids']) or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','task_ids'))
  or jsonb_typeof(b->'task_ids') is distinct from 'array' then raise exception using errcode='22023',message='Review this selected task list';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This selection belongs to another account';end if;
 if jsonb_array_length(b->'task_ids') not between 1 and 32 then raise exception using errcode='22023',message='Select between 1 and 32 tasks';end if;
 for v in select * from jsonb_array_elements(b->'task_ids') loop
  id:=taskfold_private.team_uuid(jsonb_build_object('id',v),'id');
  if id=any(ids) then raise exception using errcode='22023',message='Each selected task must be unique';end if;ids:=array_append(ids,id);
 end loop;
 -- Stable lock order; the response separately retains the requested row order.
 for id in select x from unnest(ids) x order by x loop
  t:=taskfold_private.completion_selection_root(id);
  observed:=observed||jsonb_build_object(id::text,jsonb_build_object('task',to_jsonb(t),'baseline',taskfold_private.completion_selection_root_baseline(t),'source_hash',taskfold_private.completion_selection_root_hash(t)));
  if octet_length(observed::text)>4000000 then raise exception using errcode='54000',message='This selected task list is too large';end if;
 end loop;
 select jsonb_build_object('protocol',1,'account',a,'roots',jsonb_agg(observed->x.id::text order by x.ordinal)) into reply from unnest(ids) with ordinality x(id,ordinal);
 perform taskfold_private.team_actor();return reply;
end$$;

-- Private admission primitive for the future atomic executor, not a client RPC.
-- Validate all selected roots, including no-ops, before any task can be written.
-- Ordinary roots admit unrelated authored edits; recurring roots also bind the
-- entire exact server source because it may be copied into a successor.
create function taskfold_private.guard_completion_selection_roots(b jsonb) returns void
language plpgsql volatile security invoker set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();v jsonb;id uuid;ids uuid[]:='{}';observed jsonb:='{}';t public.tasks;begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>131072 or b->'protocol' is distinct from '1'::jsonb
  or not(b ?& array['protocol','account','roots']) or exists(select 1 from jsonb_object_keys(b) k where k not in('protocol','account','roots'))
  or jsonb_typeof(b->'roots') is distinct from 'array' then raise exception using errcode='22023',message='Review these saved task observations';end if;
 if taskfold_private.team_uuid(b,'account')<>a then raise exception using errcode='42501',message='This selection belongs to another account';end if;
 if jsonb_array_length(b->'roots') not between 1 and 32 then raise exception using errcode='22023',message='Select between 1 and 32 tasks';end if;
 for v in select * from jsonb_array_elements(b->'roots') loop
  if jsonb_typeof(v)<>'object' or not(v ?& array['task_id','baseline','source_hash'])
   or exists(select 1 from jsonb_object_keys(v) k where k not in('task_id','baseline','source_hash'))
   or jsonb_typeof(v->'baseline') is distinct from 'object' or jsonb_typeof(v->'source_hash') is distinct from 'string'
   or (v->>'source_hash')!~'^[0-9a-f]{64}$' then raise exception using errcode='22023',message='Review a saved task observation';end if;
  id:=taskfold_private.team_uuid(v,'task_id');
  if id=any(ids) then raise exception using errcode='22023',message='Each selected task must be unique';end if;
  ids:=array_append(ids,id);observed:=observed||jsonb_build_object(id::text,v);
 end loop;
 for id in select x from unnest(ids) x order by x loop
  t:=taskfold_private.completion_selection_root(id);v:=observed->id::text;
  if taskfold_private.completion_selection_root_baseline(t) is distinct from v->'baseline'
   or (t.is_recurring and taskfold_private.completion_selection_root_hash(t) is distinct from v->>'source_hash') then
   raise exception using errcode='PT409',message='A selected completion changed; review the whole selection';end if;
 end loop;
 perform taskfold_private.team_actor();
end$$;
create function public.taskfold_read_completion_selection_roots(_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.read_completion_selection_roots(_body)$$;
revoke all on function taskfold_private.completion_selection_root_baseline(public.tasks),taskfold_private.completion_selection_root_hash(public.tasks),
 taskfold_private.completion_selection_root(uuid),taskfold_private.guard_completion_selection_roots(jsonb),taskfold_private.read_completion_selection_roots(jsonb),
 public.taskfold_read_completion_selection_roots(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.read_completion_selection_roots(jsonb),public.taskfold_read_completion_selection_roots(jsonb) to authenticated;
