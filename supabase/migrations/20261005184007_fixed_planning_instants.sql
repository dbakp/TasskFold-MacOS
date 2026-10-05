-- Preserve a fixed instant, including both folds of an ambiguous DST local time.
alter table public.tasks add column scheduled_at timestamptz;
create or replace function taskfold_private.normalize_planned_instant()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare wall timestamp; begin
 if new.time_zone is not null and not exists(select 1 from pg_catalog.pg_timezone_names where name=new.time_zone) then raise exception 'Choose a valid time zone'; end if;
 if new.due_date is null or new.due_time is null or new.time_zone is null then
  new.scheduled_at := null;
 else
  wall := new.due_date + new.due_time;
  if tg_op='UPDATE' then
   if (new.due_date,new.due_time,new.time_zone) is distinct from (old.due_date,old.due_time,old.time_zone) and new.scheduled_at is not distinct from old.scheduled_at then new.scheduled_at := null; end if;
  end if;
  -- Explicit instants must agree with their local presentation. If an old client edits
  -- only date/time, rebuild the instant instead of leaving a stale canonical value.
  if new.scheduled_at is null or date_trunc('minute',new.scheduled_at at time zone new.time_zone) <> date_trunc('minute',wall) then
   new.scheduled_at := wall at time zone new.time_zone;
  end if;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.normalize_planned_instant() from public, anon, authenticated;
create trigger taskfold_normalize_planned_instant before insert or update on public.tasks
 for each row execute function taskfold_private.normalize_planned_instant();
create or replace function public.taskfold_patch_task(_id uuid, _base jsonb, _changes jsonb)
returns public.tasks language plpgsql security invoker set search_path = '' as $$
declare t public.tasks; merged jsonb; k text; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 merged := to_jsonb(t);
 for k in select jsonb_object_keys(_changes) loop
   if not k = any(allowed) then raise exception 'This task field cannot be edited'; end if;
   if not _base ? k then raise exception 'An edit baseline is required'; end if;
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(_base->k, _changes->k, merged->k), 'null'));
 end loop;
 t := jsonb_populate_record(t, merged);
 update public.tasks set title=t.title,description=t.description,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to,deadline_date=t.deadline_date,duration_minutes=t.duration_minutes,time_zone=t.time_zone,reminder_specs=t.reminder_specs,source_metadata=t.source_metadata,scheduled_at=t.scheduled_at where id=_id returning * into t;
 return t;
end $$;
revoke all on function public.taskfold_patch_task(uuid,jsonb,jsonb) from public, anon;
grant execute on function public.taskfold_patch_task(uuid,jsonb,jsonb) to authenticated;


create or replace function public.taskfold_import_todoist(_account text, _bundle jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
 u uuid := auth.uid(); kind text; item jsonb; row_data jsonb; source text; dest uuid;
 imported int; skipped int; result jsonb := '{}';
 p public.projects; s public.sections; l public.labels; t public.tasks;
 children int := 0; comments_count int := 0;
begin
 if u is null then raise exception 'Sign in to import'; end if;
 if _account is null or length(_account) not between 1 and 200 or jsonb_typeof(_bundle) is distinct from 'object' then raise exception 'Invalid import'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text || ':todoist:' || _account, 0));
 foreach kind in array array['projects','sections','labels','tasks'] loop
  if jsonb_typeof(_bundle->kind) is distinct from 'array' or jsonb_array_length(_bundle->kind) > 20000 then raise exception 'Invalid or oversized import collection'; end if;
  imported := 0; skipped := 0;
  for item in select value from jsonb_array_elements(_bundle->kind) loop
   source := item->>'source_id'; row_data := item->'record';
   if source is null or length(source) not between 1 and 200 or jsonb_typeof(row_data) is distinct from 'object' then raise exception 'Invalid source record'; end if;
   if exists(select 1 from public.import_sources where user_id=u and provider='todoist' and source_account=_account and import_sources.entity=kind and source_id=source) then
    skipped := skipped + 1; continue;
   end if;
   dest := (row_data->>'id')::uuid;
   if dest is null then raise exception 'Import record requires an ID'; end if;
   row_data := row_data || jsonb_build_object('user_id',u);
   case kind
   when 'projects' then
    p := jsonb_populate_record(null::public.projects, row_data);
    insert into public.projects(id,user_id,name,description,color,order_index,source_metadata)
     values(p.id,u,p.name,p.description,coalesce(p.color,'#3b82f6'),coalesce(p.order_index,0),coalesce(p.source_metadata,'{}'));
   when 'sections' then
    s := jsonb_populate_record(null::public.sections, row_data);
    if not exists(select 1 from public.projects where id=s.project_id and user_id=u) then raise exception 'Imported section requires an owned project'; end if;
    insert into public.sections(id,user_id,project_id,name,order_index) values(s.id,u,s.project_id,s.name,coalesce(s.order_index,0));
   when 'labels' then
    l := jsonb_populate_record(null::public.labels, row_data);
    insert into public.labels(id,user_id,name,color) values(l.id,u,l.name,coalesce(l.color,'#3b82f6'));
   when 'tasks' then
    t := jsonb_populate_record(null::public.tasks, row_data);
    if t.project_id is not null and not exists(select 1 from public.projects where id=t.project_id and user_id=u) then raise exception 'Imported task requires an owned project'; end if;
    if t.section_id is not null and not exists(select 1 from public.sections where id=t.section_id and project_id=t.project_id and user_id=u) then raise exception 'Imported section does not belong to task project'; end if;
    insert into public.tasks(id,user_id,title,description,completed,priority,due_date,due_time,project_id,section_id,labels,subtasks,reminders,attachments,comments,created_at,completed_at,recurrence_pattern,is_recurring,deadline_date,duration_minutes,time_zone,source_metadata,scheduled_at)
     values(t.id,u,t.title,t.description,coalesce(t.completed,false),coalesce(t.priority,4),t.due_date,t.due_time,t.project_id,t.section_id,coalesce(t.labels,'{}'),coalesce(t.subtasks,'[]'),coalesce(t.reminders,'{}'),coalesce(t.attachments,'[]'),coalesce(t.comments,'[]'),coalesce(t.created_at,now()),t.completed_at,t.recurrence_pattern,coalesce(t.is_recurring,false),t.deadline_date,t.duration_minutes,t.time_zone,coalesce(t.source_metadata,'{}'),t.scheduled_at);
    children := children + coalesce((item->>'subtask_count')::int,0);
    comments_count := comments_count + coalesce((item->>'comment_count')::int,0);
   end case;
   insert into public.import_sources(user_id,provider,source_account,entity,source_id,record_id) values(u,'todoist',_account,kind,source,dest);
   imported := imported + 1;
  end loop;
  result := result || jsonb_build_object(kind || 'Imported',imported,kind || 'Skipped',skipped);
 end loop;
 return result || jsonb_build_object('success',true,'subtasksImported',children,'commentsImported',comments_count);
end $$;
revoke all on function public.taskfold_import_todoist(text,jsonb) from public, anon;
grant execute on function public.taskfold_import_todoist(text,jsonb) to authenticated;
