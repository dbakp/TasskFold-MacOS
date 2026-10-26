-- Child history follows the same stable creator custody and native-team read
-- boundary as parent activity. No actor, role, rollout or task-write grant changes.
-- Apply transactionally. Auth deletion takes Auth then task locks as well; drain
-- old writers before replacing cleanup/recording and declaring reliable coverage.
lock table auth.users in share row exclusive mode;
lock table public.tasks in share row exclusive mode;
alter table public.task_node_activity drop constraint task_node_activity_user_id_fkey;
alter table public.task_node_activity add constraint task_node_activity_user_id_fkey
 foreign key(user_id) references taskfold_private.content_identities(id) on delete restrict not valid;
alter table public.task_node_activity validate constraint task_node_activity_user_id_fkey;
alter policy task_node_activity_read on public.task_node_activity
 using(taskfold_private.is_team_content_task(task_id) or taskfold_private.can_read_task_activity(user_id,task_id,before_state,after_state));
create policy team_node_activity_native_read on public.task_node_activity as restrictive for select to authenticated
 using(not taskfold_private.is_team_content_task(task_id) or
  (taskfold_private.team_native_activity_read(task_id) and taskfold_private.team_native_activity_states_read(before_state,after_state)));

create or replace function taskfold_private.capture_task_node_activity()
returns trigger language plpgsql security definer set search_path='' as $$
declare caller uuid:=auth.uid();t public.tasks;prior jsonb:='{}';current_nodes jsonb:='{}';b jsonb;a jsonb;o jsonb;n jsonb;key text;kinds text[];instant timestamptz:=statement_timestamp();effective timestamptz;old_path text[];new_path text[];generation uuid;record_owner uuid;failed boolean:=false;
begin
 if tg_table_schema<>'public' or tg_table_name<>'tasks' then raise exception 'Invalid child activity source';end if;
 if tg_op='INSERT' then t:=new;else t:=old;end if;
 if not exists(select 1 from auth.users where id=t.user_id) and not taskfold_private.is_team_content_task(t.id) and not taskfold_private.is_team_content_project(t.project_id) then if tg_op='DELETE' then return old;else return new;end if;end if;
 if caller is not null and not exists(select 1 from auth.users where id=caller) then raise exception 'Activity actor is no longer available';end if;
 if tg_op='UPDATE' and old.subtasks is not distinct from new.subtasks and old.is_heading is not distinct from new.is_heading
  and old.project_id is not distinct from new.project_id and old.section_id is not distinct from new.section_id and old.task_generation is not distinct from new.task_generation then return new;end if;
 begin
  if tg_op<>'INSERT' then prior:=taskfold_private.node_activity_nodes(old);end if;
  if tg_op<>'DELETE' then current_nodes:=taskfold_private.node_activity_nodes(new);end if;
 exception when invalid_text_representation or datetime_field_overflow or invalid_datetime_format or numeric_value_out_of_range or raise_exception then failed:=true;
 end;
 if failed then
  b:='{}';a:='{}';
  if tg_op<>'INSERT' then b:=taskfold_private.activity_state(old);end if;
  if tg_op<>'DELETE' then a:=taskfold_private.activity_state(new);end if;
  insert into public.task_node_activity(user_id,task_id,task_generation,node_key,before_path,after_path,actor_id,effective_at,completion_version,type_before,type_after,work_before,work_after,kinds,before_state,after_state)
  values(case when tg_op='DELETE' then old.user_id else new.user_id end,t.id,t.task_generation,'','{}','{}',caller,instant,0,null,null,false,false,array['coverage_gap'],b,a);
  if tg_op='DELETE' then return old;else return new;end if;
 end if;
 for key in select k from (select jsonb_object_keys(prior) k union select jsonb_object_keys(current_nodes) k) x order by k loop
  o:=prior->key;n:=current_nodes->key;b:=coalesce(o->'state','{}');a:=coalesce(n->'state','{}');kinds:='{}';
  old_path:=array(select jsonb_array_elements_text(coalesce(o->'path','[]')));new_path:=array(select jsonb_array_elements_text(coalesce(n->'path','[]')));
  if o is null then kinds:=array['created'];elsif n is null then kinds:=array['deleted'];else
   if b->'completed' is distinct from a->'completed' then kinds:=array_append(kinds,case when a->'completed'='true'::jsonb then 'completed' else 'reopened' end);
   elsif b->'completed_at' is distinct from a->'completed_at' then kinds:=array_append(kinds,'completion_time');end if;
   if b->'project_id' is distinct from a->'project_id' or b->'section_id' is distinct from a->'section_id' or old_path<>new_path then kinds:=array_append(kinds,'moved');end if;
   if b-array['project_id','section_id','completed','completed_at','recurrence_parent_id'] is distinct from a-array['project_id','section_id','completed','completed_at','recurrence_parent_id'] then kinds:=array_append(kinds,'rescheduled');end if;
   if o->'type' is distinct from n->'type' then kinds:=array_append(kinds,'type_changed');elsif o->'work' is distinct from n->'work' then kinds:=array_append(kinds,'scope_changed');end if;
  end if;
  if cardinality(kinds)=0 then continue;end if;
  effective:=instant;if 'completed'=any(kinds) and a->>'completed_at' is not null then effective:=(a->>'completed_at')::timestamptz;end if;
  generation:=(coalesce(n,o)->>'generation')::uuid;record_owner:=case when n is null then old.user_id else new.user_id end;
  insert into public.task_node_activity(user_id,task_id,task_generation,node_key,before_path,after_path,actor_id,effective_at,completion_version,type_before,type_after,work_before,work_after,kinds,before_state,after_state)
   values(record_owner,t.id,generation,coalesce(n,o)->>'key',old_path,new_path,caller,effective,(coalesce(n,o)->>'revision')::bigint,o->>'type',n->>'type',coalesce((o->>'work')::boolean,false),coalesce((n->>'work')::boolean,false),kinds,b,a);
 end loop;
 if tg_op='DELETE' then return old;else return new;end if;
end $$;

create or replace function taskfold_private.remove_content_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from taskfold_private.teams where owner_id=old.id and state<>'deleted') then
  raise exception using errcode='PT409',message='Transfer or delete owned teams before removing your account';end if;
 -- Detach every surviving series child from a root that will actually disappear.
 update public.tasks child set recurrence_parent_id=null
 where child.recurrence_parent_id in(select root.id from public.tasks root where root.user_id=old.id
  and not taskfold_private.is_team_content_task(root.id))
 and (child.user_id<>old.id or taskfold_private.is_team_content_task(child.id));
 delete from public.tasks where user_id=old.id and not taskfold_private.is_team_content_task(id);
 delete from public.sections where user_id=old.id and not taskfold_private.is_team_content_project(project_id);
 delete from public.projects where user_id=old.id and not taskfold_private.is_team_content_project(id);
 delete from public.task_activity where user_id=old.id and not taskfold_private.is_team_content_task(task_id);
 delete from public.task_node_activity where user_id=old.id and not taskfold_private.is_team_content_task(task_id);
 delete from taskfold_private.task_generations where user_id=old.id and not taskfold_private.is_team_content_task(task_id);
 update taskfold_private.content_identities set removed_at=clock_timestamp() where id=old.id;
 return old;
end$$;

create or replace function taskfold_private.delete_team_content() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='deleted' and old.state<>'deleted' then
  delete from taskfold_private.team_content_file_removals r where r.team_id=old.id and not exists(select 1 from storage.objects where id=r.object_id);
  if exists(select 1 from taskfold_private.team_content_files f join taskfold_private.team_content_projects p on p.project_id=f.project_id where p.team_id=old.id) or exists(select 1 from taskfold_private.team_content_file_removals where team_id=old.id) then
   raise exception using errcode='PT409',message='Remove team files before deleting this team';end if;
  insert into taskfold_private.team_content_operations values(txid_current(),old.id);
  update public.tasks child set recurrence_parent_id=null where child.recurrence_parent_id in(
   select t.id from public.tasks t join taskfold_private.team_content_tasks c on c.task_id=t.id where c.team_id=old.id)
   and not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=child.id and c.team_id=old.id);
  delete from public.tasks where id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id);
  delete from public.projects where id in(select project_id from taskfold_private.team_content_projects where team_id=old.id);
  delete from public.task_activity where task_id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id);
  delete from public.task_node_activity where task_id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id);
  delete from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=old.id;
  -- Generation/custody tombstones contain UUIDs only and continue preventing replay.
 end if;
 return new;
end$$;

revoke all on function taskfold_private.capture_task_node_activity(),taskfold_private.remove_content_identity(),taskfold_private.delete_team_content()
 from public,anon,authenticated,service_role;

-- Earlier events remain intact, but an already-applied foundation could have lost
-- team events through Auth cascades. Do not certify that earlier interval.
update public.task_node_activity_epoch set recorded_from=greatest(recorded_from,clock_timestamp()) where id='current';
