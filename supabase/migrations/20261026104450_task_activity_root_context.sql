-- Optional bounded annotation on new root events. Existing rows remain null;
-- old event kinds, state documents, IDs, ordering and read permissions are unchanged.
alter table public.task_activity add column root_context jsonb;
alter table public.task_activity add constraint task_activity_root_context_bounded
 check(root_context is null or (jsonb_typeof(root_context)='object' and octet_length(root_context::text)<=2048)) not valid;
alter table public.task_activity validate constraint task_activity_root_context_bounded;

-- Preserve authorized foreign-key cascades; the private trigger has no callable writer API.
create or replace function taskfold_private.capture_task_activity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare caller uuid := auth.uid(); t public.tasks; b jsonb := '{}'; a jsonb := '{}'; kinds text[] := '{}'; instant timestamptz := statement_timestamp(); meta jsonb;
begin
 if tg_table_schema <> 'public' or tg_table_name <> 'tasks' then raise exception 'Invalid activity source'; end if;
 if tg_op = 'INSERT' then t := new; else t := old; end if;
 -- Cascading account deletion must not recreate data for an owner being removed.
 if not exists(select 1 from auth.users where id=t.user_id) and not taskfold_private.is_team_content_task(t.id) and not taskfold_private.is_team_content_project(t.project_id) then
  if tg_op = 'DELETE' then return old; else return new; end if;
 end if;
 -- Original DML/FK cascades retain table authorization. Rechecking the old project
 -- here would reject an authorized project deletion after that project disappeared.
 if caller is not null and not exists(select 1 from auth.users where id=caller) then
  raise exception 'Task activity actor is no longer available';
 end if;
 if tg_op <> 'INSERT' then b := taskfold_private.activity_state(old); end if;
 if tg_op <> 'DELETE' then a := taskfold_private.activity_state(new); t := new; end if;
 if tg_op = 'INSERT' then kinds := array['created'];
 elsif tg_op = 'DELETE' then kinds := array['deleted'];
 else
  if coalesce(old.completed,false) is distinct from coalesce(new.completed,false) then
   kinds := array_append(kinds,case when coalesce(new.completed,false) then 'completed' else 'reopened' end);
  elsif old.completed_at is distinct from new.completed_at then kinds := array_append(kinds,'completion_time'); end if;
  if old.project_id is distinct from new.project_id or old.section_id is distinct from new.section_id then kinds := array_append(kinds,'moved'); end if;
  if (b - array['project_id','section_id','completed','completed_at','recurrence_parent_id']) is distinct from (a - array['project_id','section_id','completed','completed_at','recurrence_parent_id']) then
   kinds := array_append(kinds,'rescheduled');
  end if;
 end if;
 -- Classify only the actual observed occurrence. Never backfill from today's task.
 meta := jsonb_build_object('version',1,'before_type',null,'after_type',null,'before_generation',null,'after_generation',null);
 if tg_op <> 'INSERT' then
  meta := meta || jsonb_build_object('before_type',case when coalesce(old.is_heading,false) then 'heading' else 'task' end,
    'before_generation',coalesce(old.task_generation,'00000000-0000-0000-0000-000000000000'::uuid));
 end if;
 if tg_op <> 'DELETE' then
  meta := meta || jsonb_build_object('after_type',case when coalesce(new.is_heading,false) then 'heading' else 'task' end,
    'after_generation',coalesce(new.task_generation,'00000000-0000-0000-0000-000000000000'::uuid));
 end if;
 if cardinality(kinds) > 0 then
  if 'completed' = any(kinds) and t.completed_at is not null then instant := t.completed_at; end if;
  insert into public.task_activity(user_id,task_id,actor_id,effective_at,completion_version,kinds,before_state,after_state,root_context)
   values(t.user_id,t.id,caller,instant,t.completion_version,kinds,b,a,meta);
 end if;
 if tg_op = 'DELETE' then return old; else return new; end if;
end $$;
revoke all on function taskfold_private.capture_task_activity() from public, anon, authenticated;
