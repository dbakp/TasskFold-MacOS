-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Recovery remains available when new repair writes are paused. No content in discovery.
create function taskfold_private.child_repair_archives(after_request uuid,page_limit integer) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();rows jsonb:='[]';r taskfold_private.child_task_repairs;last_request uuid;more boolean:=false;n integer:=0;
begin
 perform taskfold_private.team_actor();
 if page_limit is null or page_limit<1 or page_limit>50 then raise exception using errcode='22023',message='Choose a smaller original-history page';end if;
 for r in select * from taskfold_private.child_task_repairs where actor_id=a and state='applied' and (after_request is null or request_id>after_request) order by request_id limit page_limit+1 loop
  n:=n+1;if n>page_limit then more:=true;exit;end if;
  rows:=rows||jsonb_build_array(jsonb_build_object('receipt',taskfold_private.child_repair_reply(r,false),'created_at',r.created_at,
   'content_retained',exists(select 1 from taskfold_private.child_task_repair_originals o where o.id=r.archive_id and o.request_id=r.request_id and o.task_id=r.task_id and o.task_generation is not distinct from r.task_generation and o.project_id is not distinct from r.project_id and o.team_id is not distinct from r.workspace_id and o.actor_id=a)));
  last_request:=r.request_id;
 end loop;
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',a,'entries',rows,'next',case when more then last_request else null end);
end$$;
create function public.taskfold_child_repair_archives(_after uuid default null,_limit integer default 50) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare reply jsonb;e jsonb;rows jsonb:='[]';name text;begin
 reply:=taskfold_private.child_repair_archives(_after,_limit);
 for e in select * from jsonb_array_elements(reply->'entries') loop
  -- This is the CURRENT title under current caller RLS, never an archived title.
  select t.title into name from public.tasks t where t.id=(e->'receipt'->>'task_id')::uuid and t.task_generation is not distinct from (e->'receipt'->>'task_generation')::uuid and t.project_id is not distinct from (e->'receipt'->>'project_id')::uuid;
  rows:=rows||jsonb_build_array(e||jsonb_build_object('current_title',left(name,512),'title_truncated',coalesce(char_length(name)>512,false)));
 end loop;
 return jsonb_set(reply,'{entries}',rows);
end$$;

-- The request body can be lost with a device. Immutable actor-bound receipts
-- still identify an original; this path grants export only, never replay/apply.
create function taskfold_private.discovered_child_repair_original(request uuid,archive uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();r taskfold_private.child_task_repairs;t public.tasks;team uuid;original jsonb;
begin
 perform taskfold_private.team_actor();
 select * into r from taskfold_private.child_task_repairs where actor_id=a and request_id=request and archive_id=archive and state='applied';
 if not found then raise exception using errcode='42501',message='This saved original is unavailable';end if;
 t:=taskfold_private.child_adoption_root(r.task_id,r.task_generation,false);
 select team_id into team from taskfold_private.team_content_projects where project_id=t.project_id;
 if t.project_id is distinct from r.project_id or team is distinct from r.workspace_id then raise exception using errcode='42501',message='This original belongs to another task context';end if;
 select o.original into original from taskfold_private.child_task_repair_originals o where o.id=archive and o.request_id=request and o.task_id=r.task_id
  and o.task_generation is not distinct from r.task_generation and o.project_id is not distinct from r.project_id and o.team_id is not distinct from r.workspace_id and (o.team_id is not null or (o.owner_id in(a,t.user_id) and o.original->'root'->>'user_id'=t.user_id::text));
 if original is null then raise exception using errcode='42501',message='This saved original is unavailable';end if;
 if octet_length(original::text)<>r.archive_bytes or encode(extensions.digest(convert_to(original::text,'UTF8'),'sha256'),'hex')<>r.archive_digest then raise exception using errcode='PT409',message='This saved original needs recovery review';end if;
 if jsonb_typeof(original->'child_history') is distinct from 'array' or (original ? 'root_history' and jsonb_typeof(original->'root_history') is distinct from 'array') then raise exception using errcode='PT409',message='This original needs history review';end if;
 if exists(select 1 from jsonb_array_elements(original->'child_history') e where not exists(select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e and taskfold_private.child_repair_history_visible(h)))
 or exists(select 1 from jsonb_array_elements(coalesce(original->'root_history','[]'::jsonb)) e where not exists(select 1 from public.task_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e
  and (taskfold_private.history_is_custodied('root',h.id) or taskfold_private.is_team_content_task(h.task_id) or taskfold_private.can_read_task_activity(h.user_id,h.task_id,h.before_state,h.after_state))
  and (case when taskfold_private.history_is_custodied('root',h.id) then taskfold_private.history_native_read('root',h.id,h.before_state,h.after_state,h.user_id)
   else not taskfold_private.is_team_content_task(h.task_id) or (taskfold_private.team_native_activity_read(h.task_id) and taskfold_private.team_native_activity_states_read(h.before_state,h.after_state)) end))) then raise exception using errcode='42501',message='Original history access changed';end if;
 perform taskfold_private.team_actor();
 return jsonb_build_object('protocol',1,'account',a,'request_id',r.request_id,'archive_id',r.archive_id,'archive_digest',r.archive_digest,'original',original);
end$$;
create function public.taskfold_child_repair_original(_request uuid,_archive uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$declare reply jsonb;begin
 reply:=taskfold_private.discovered_child_repair_original(_request,_archive);
 -- Current caller-RLS is authoritative even if future policies become stricter.
 if not exists(select 1 from public.tasks t where t.id=(reply->'original'->'root'->>'id')::uuid and t.task_generation is not distinct from (reply->'original'->'root'->>'task_generation')::uuid)
 or exists(select 1 from jsonb_array_elements(reply->'original'->'child_history') e where not exists(select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e))
 or exists(select 1 from jsonb_array_elements(coalesce(reply->'original'->'root_history','[]'::jsonb)) e where not exists(select 1 from public.task_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)=e)) then raise exception using errcode='42501',message='Original access changed';end if;
 return reply;
end$$;
revoke all on function taskfold_private.child_repair_archives(uuid,integer),taskfold_private.discovered_child_repair_original(uuid,uuid),public.taskfold_child_repair_archives(uuid,integer),public.taskfold_child_repair_original(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_repair_archives(uuid,integer),taskfold_private.discovered_child_repair_original(uuid,uuid),public.taskfold_child_repair_archives(uuid,integer),public.taskfold_child_repair_original(uuid,uuid) to authenticated;

commit;
