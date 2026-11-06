-- Stage 2 read-only contract. Disabled by default, with no direct table grants.
create table taskfold_private.child_task_record_config(singleton boolean primary key default true check(singleton),reads_enabled boolean not null default false);
insert into taskfold_private.child_task_record_config default values;
alter table taskfold_private.child_task_record_config enable row level security;
revoke all on taskfold_private.child_task_record_config from public,anon,authenticated,service_role;
create function taskfold_private.read_child_task_records(root_id uuid,expected_generation uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();s uuid;t public.tasks%rowtype;p taskfold_private.child_task_projections%rowtype;
 records jsonb;actual jsonb;expected jsonb;reply jsonb;decoded jsonb;allowed boolean;
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child records are not enabled';end if;
 if a is null or not taskfold_private.team_native_actor_live() then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 s:=(auth.jwt()->>'session_id')::uuid;
 -- Prevent deletion/revocation of this actor/session during the accepted read.
 perform 1 from auth.users where id=a for share;
 if not found then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 perform 1 from auth.sessions where id=s and user_id=a and (not_after is null or not_after>clock_timestamp()) for share;
 if not found then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 select * into t from public.tasks where id=root_id and task_generation is not distinct from expected_generation for share;
 if not found then raise exception using errcode='42501',message='This task is unavailable';end if;
 if taskfold_private.is_team_content_task(t.id) or taskfold_private.is_team_content_project(t.project_id) then
  allowed:=taskfold_private.team_native_task_read(t.id,t.project_id);
 else allowed:=case when t.project_id is null then t.user_id=a else public.has_project_access(a,t.project_id) end;end if;
 if not coalesce(allowed,false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 select * into p from taskfold_private.child_task_projections where task_id=t.id;
 if not found or p.state<>'ready' or p.task_generation is distinct from t.task_generation or p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb) then
  raise exception using errcode='PT409',message='Review this child hierarchy before opening separate records';end if;
 decoded:=taskfold_private.decode_child_task_tree(p.source_tree);
 if decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy before opening separate records';end if;
 select coalesce(jsonb_agg(n order by n->>'key' collate "C"),'[]') into expected
  from jsonb_array_elements(decoded->'nodes') n;
 select coalesce(jsonb_agg(jsonb_build_object('key',r.node_key,'parent',r.parent_key,'position',r.sibling_order,'path',r.identity_path,
  'fields',r.fields,'children_kind',r.children_kind) order by r.node_key),'[]'),
  coalesce(jsonb_agg(to_jsonb(r)-'task_id' order by r.identity_path collate "C"),'[]') into actual,records
  from taskfold_private.child_task_records r where r.task_id=t.id;
 if actual<>expected then raise exception using errcode='PT409',message='Review this child hierarchy before opening separate records';end if;
 reply:=jsonb_build_object('protocol',1,'account',a,'task_id',t.id,'project_id',t.project_id,'task_generation',t.task_generation,'projection_revision',p.revision,
  'root_kind',case when p.source_tree='null'::jsonb then 'null' else 'array' end,'records',records);
 if octet_length(reply::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large to open as separate records';end if;
 -- Recheck volatile account/project admission after assembling the bounded data.
 if not taskfold_private.team_native_actor_live() or not exists(select 1 from auth.sessions where id=s and user_id=a and (not_after is null or not_after>clock_timestamp())) then raise exception using errcode='42501',message='Sign in again to open child records';end if;
 if taskfold_private.is_team_content_task(t.id) or taskfold_private.is_team_content_project(t.project_id) then
  allowed:=taskfold_private.team_native_task_read(t.id,t.project_id);
 else allowed:=case when t.project_id is null then t.user_id=a else public.has_project_access(a,t.project_id) end;end if;
 if not coalesce(allowed,false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 return reply;
end $$;
-- Invoker entry also applies the actual task SELECT policies, rather than
-- relying solely on the private helper's explicit personal/team admission.
create function public.taskfold_read_child_tasks(_id uuid,_generation uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.tasks where id=_id and task_generation is not distinct from _generation) then
  raise exception using errcode='42501',message='This task is unavailable';end if;
 return taskfold_private.read_child_task_records(_id,_generation);
end $$;
revoke all on function taskfold_private.read_child_task_records(uuid,uuid),public.taskfold_read_child_tasks(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.read_child_task_records(uuid,uuid),public.taskfold_read_child_tasks(uuid,uuid) to authenticated;
